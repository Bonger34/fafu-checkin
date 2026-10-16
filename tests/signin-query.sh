# ============================================================
# signin 查询失败与任务变化：两种失败要能分开、任务变化只记一行（含跨日）
#
# 前导（夹具／替身／取值辅助）在 tests/_signin-common.sh，本文件只放用例。
# ============================================================
# ---- 共享前导（定义在 tests/_signin-common.sh；本文件自己 source）----
. "$T_ROOT/tests/_signin-common.sh"

# ============================================================
# 六·五、查询失败：参数与完整正文（两种失败要能分开）
#
# 一天只有一次现场，失败行要一次说清三件事：我们发了什么（查询参数 rows / pageNum）、
# 这次调用的事实（rc + api 层落下的那一行：状态码，或连接层的退出码与报错原文）、
# 服务端回了什么（**完整**正文——正文里那句 message 常常正好落在截断处）。
# 两种失败各走一次：① 调用失败（rc≠0，正文由 api 层落盘）；
# ② 应答了但正文不是任务列表（rc=0，这一档的正文由本层自己带上）。
# 驱动只挑「这一次调用的事实」，行仍由 api 层的 _api_note 拼（上层不自己拼 http= / body= / 耗时=）。
# ============================================================

sg_case_fetch_fail() {
  local d
  sg_setup fetch-fail
  sg_at 1200                                       # 20:00：查询失败与窗口判定无关，拨一个窗口外即可
  sg_body_long > "$SG_WORK/ctl/long.body"          # 长正文：尾部那一段在 200 字节之外
  printf '%s\n' '{"code":500,"message":"查询不到任务列表"}' > "$SG_WORK/ctl/norec.body"
  sg_run fetch_fail <<'DRIVER'
printf '0' > ctl/n.n
http_post() {
  _n=$(cat ctl/n.n); _n=$((_n + 1)); printf '%s' "$_n" > ctl/n.n
  printf '%s\n' "$1" >> ctl/api.calls
  if [ "$_n" -le 1 ]; then
    # ① 连接层失败：拿不到状态码，工具吐了报错原文，正文拿到了
    _api_note 7 "" "$(cat ctl/long.body)" "curl: (7) Failed to connect to stuhtapi.fafu.edu.cn port 80" "" "$(_api_now)" "$(_api_now)"
    return 7
  fi
  # ② 应答了（200），但正文里没有 records
  _api_note 0 200 "$(cat ctl/norec.body)" "" "" "$(_api_now)" "$(_api_now)"
  cat ctl/norec.body
  return 0
}
run_once; printf 'rc=%s\n' "$?"
printf 'url=%s\n'  "$(head -n 1 ctl/api.calls)"
printf 'n=%s\n'    "$(grep -c -e '查询异常:' -e '获取任务失败:' mod/fafu_checkin.log)"
printf 'first=%s\n'  "$(sed 's/^\[[^]]*\][ ]*//' mod/fafu_checkin.log | grep -F '查询异常:' | tail -n 1)"
printf 'second=%s\n' "$(sed 's/^\[[^]]*\][ ]*//' mod/fafu_checkin.log | grep -F '获取任务失败:' | tail -n 1)"
DRIVER
  d="$SG_WORK/fetch_fail.out"
  sg_val "$d" first  > "$SG_WORK/fetch_fail.first"
  sg_val "$d" second > "$SG_WORK/fetch_fail.second"
  t_eq "两轮查询都不成：返回 2（任务异常）" "$(sg_val "$d" rc)" "2"
  t_eq "查询失败：两条失败各记一行（首次 + 刷新 token 后重试）" "$(sg_val "$d" n)" "2"
  t_eq "查询参数与实际发出的请求同源（日志里的 params 不是另抄一份）" \
    "$(sg_val "$d" url)" \
    "http://stuhtapi.fafu.edu.cn/health-api/sign_in/student/my/page?rows=3&pageNum=1"
  # ① 调用失败：rc + api 层那一行（原样转交）+ 参数 + 完整正文
  t_has "调用失败：带 rc 与 api 层那一行（连接层退出码 / 不伪造状态码）" \
    "$SG_WORK/fetch_fail.first" "查询异常: rc=7 net rc=7 http=- body={"
  t_has "调用失败：工具报错原文也在" "$SG_WORK/fetch_fail.first" \
    "err=curl: (7) Failed to connect"
  t_has "调用失败：带查询参数" "$SG_WORK/fetch_fail.first" "params=rows=3&pageNum=1"
  t_has "调用失败：正文完整（尾部那一段没有被截掉）" "$SG_WORK/fetch_fail.first" \
    "正文的尾部也必须整段落进日志"
  # ② 应答了但没有任务列表：rc=0，正文由本层自己带上（这一档 api 层的正文可能没落盘）
  t_has "没有任务列表：rc 与状态码是这一档该有的样子" "$SG_WORK/fetch_fail.second" \
    "获取任务失败: rc=0 http=200 body={\"code\":500,\"message\":\"查询不到任务列表\"}"
  t_has "没有任务列表：带查询参数" "$SG_WORK/fetch_fail.second" "params=rows=3&pageNum=1"
  t_has "没有任务列表：正文由本层带上（resp=）" "$SG_WORK/fetch_fail.second" \
    "resp={\"code\":500,\"message\":\"查询不到任务列表\"}"
}

# ============================================================
# 六·六、任务变化：四元组真的变了才记一行
#
# 正常轮询每分钟一轮，任务数据几乎不变——若每轮都记，几百行里没有一行提供信息。
# 判据是任务号 / 签到状态 / 开始 / 截止四者任一与上一轮不同；**首次拿到任务也算变化**
# （旧的为空），跨日后快照失效、同样的任务因此又算「新任务」。
# 快照归 state 层管：这里只断言「日志里有没有那一行、前后值是什么」。
# ============================================================

sg_case_task_change() {
  local d bt dline
  sg_setup task-change
  sg_at 1200                                       # 20:00：任务还没开始，每轮都停在「不在签到时段」
  bt=$(( SG_EPOCH * 1000 + 1290 * 60000 ))
  dline=$(( SG_EPOCH * 1000 + 1380 * 60000 ))
  sg_body 1290 0 | sg_poison > "$SG_WORK/ctl/body.page"   # 未签；正文里回显了日志形状的字样
  sg_body 1290 1 | sg_poison > "$SG_WORK/ctl/body.seen"   # 同一个任务的签到状态改成 1
  printf '%s\n' "$SG_HDR_RAW" > "$SG_WORK/ctl/hdr" # 这一次服务端给了响应头四项
  printf 'page:0\npage:0\nseen:0\n' > "$SG_WORK/ctl/api.seq"
  sg_run task_change <<'DRIVER'
tlines() { grep -F '任务变化:' mod/fafu_checkin.log 2>/dev/null; }
plain()  { sed 's/^\[[^]]*\][ ]*//' mod/fafu_checkin.log; }
run_once >/dev/null 2>&1; printf 'rc1=%s\n' "$?"
printf 'n1=%s\n' "$(tlines | grep -c .)"
printf 'l1=%s\n' "$(grep -c . mod/fafu_checkin.log)"
run_once >/dev/null 2>&1; printf 'rc2=%s\n' "$?"
printf 'n2=%s\n' "$(tlines | grep -c .)"
printf 'l2=%s\n' "$(grep -c . mod/fafu_checkin.log)"
printf 'last2=%s\n' "$(plain | tail -n 1)"
run_once >/dev/null 2>&1; printf 'rc3=%s\n' "$?"
printf 'n3=%s\n' "$(tlines | grep -c .)"
printf 'first=%s\n' "$(tlines | head -n 1 | sed 's/^\[[^]]*\][ ]*//')"
printf 'third=%s\n' "$(tlines | tail -n 1 | sed 's/^\[[^]]*\][ ]*//')"
DRIVER
  d="$SG_WORK/task_change.out"
  t_eq "首次拿到任务记一行" "$(sg_val "$d" n1)" "1"
  t_eq "同一任务再查一轮：不记新的任务行" "$(sg_val "$d" n2)" "1"
  t_eq "同一任务再查一轮：只多出「不在签到时段」那一行（轮询不变啰嗦）" \
    "$(( $(sg_val "$d" l2) - $(sg_val "$d" l1) ))" "1"
  t_eq "同一任务再查一轮：末行仍是「不在签到时段」" "$(sg_val "$d" last2)" \
    "[晚查寝签到] 不在签到时段"
  t_eq "签到状态变了：再记一行" "$(sg_val "$d" n3)" "2"
  # 那一行末尾并排服务端的响应头：任务是何时出现的，与服务端认为现在几点（Date）同处一行
  t_eq "首次那一行的旧值为空（第一次拿到任务也算变化）" "$(sg_val "$d" first)" \
    "任务变化: id=→88123 state=→0 begin=→$bt 截止=→$dline $SG_HDR_LINE"
  t_eq "状态变化那一行给出前后四元组" "$(sg_val "$d" third)" \
    "任务变化: id=88123→88123 state=0→1 begin=$bt→$bt 截止=$dline→$dline $SG_HDR_LINE"
  # 三档返回码由判定决定，任务快照只写它自己那一个文件，不得改变它
  t_eq "首次那一轮仍是「不在时段」（返回 1）" "$(sg_val "$d" rc1)" "1"
  t_eq "第二轮仍返回 1（记不记快照与返回码无关）" "$(sg_val "$d" rc2)" "1"
  t_eq "第三轮状态改成已签到：按既有判定返回 0" "$(sg_val "$d" rc3)" "0"

  # 跨日：快照按日滚动 → 同样的任务在第二天算「新任务」，而不是「无变化」
  sg_setup task-change-next-day
  sg_at 1200
  sg_body 1290 0 > "$SG_WORK/ctl/body.page"
  printf 'page:0\n' > "$SG_WORK/ctl/api.seq"
  sg_run task_change_next <<'DRIVER'
run_once >/dev/null 2>&1
printf 'n1=%s\n' "$(grep -c -F '任务变化:' mod/fafu_checkin.log)"
# 拨到第二天（墙钟与 %s 一起拨）：任务数据一个字没改
printf '%s\n' '2026-10-02 20:00' > ctl/date
SG_NOW_S=$((SG_EPOCH + 86400 + 1200 * 60)); export SG_NOW_S
run_once >/dev/null 2>&1
printf 'n2=%s\n' "$(grep -c -F '任务变化:' mod/fafu_checkin.log)"
printf 'last=%s\n' "$(grep -F '任务变化:' mod/fafu_checkin.log | tail -n 1 | sed 's/^\[[^]]*\][ ]*//')"
printf 'today=%s\n' "$(today)"
DRIVER
  d="$SG_WORK/task_change_next.out"
  t_eq "跨日那一轮确实拨到了第二天" "$(sg_val "$d" today)" "2026-10-02"
  t_eq "跨日后同样的任务算「新任务」（再记一行）" "$(sg_val "$d" n2)" "2"
  # 这一档的替身没给响应头（sg_setup 把 ctl/hdr 清空了）：行尾就停在「截止」，
  # 不留空段、也不留一个空的 hdr=。
  t_eq "跨日后那一行的旧值为空（昨天的快照不是今天的比较基准）" "$(sg_val "$d" last)" \
    "任务变化: id=→88123 state=→0 begin=→$bt 截止=→$dline"
}

# ============================================================
# 六·七、查询失败的当日去重（默认档）
#
# 一晚上拿不到任务时，同一条失败每 60 / 240 秒会重复一次；默认档只在**原因**变化时再留一条。
# 原因 = rc + 这一次调用为什么失败（状态码 / 正文 / 报错原文）+ 本层那份正文；
# 响应头里的 Date 与耗时是「这一次调用的读数」而不是原因（服务端的钟每分钟都在走，
# 算进原因键就等于每条都算新原因，去重失效）。
# 断言只看日志文件名下有哪些行、各几行，以及默认档那一行是否仍带着完整诊断。
# ============================================================

sg_case_fetch_dedup() {
  local d
  sg_setup fetch-dedup
  sg_at 1200                                   # 20:00：查询失败与窗口判定无关
  sg_body_long > "$SG_WORK/ctl/long.body"
  sg_run fetch_dedup <<'DRIVER'
tier() { printf 'DEBUG=%s\n' "$1" > mod/fafu-checkin.conf; cfg_load; }
n1() { grep -c '查询异常:' mod/fafu_checkin.log; }
n2() { grep -c '获取任务失败:' mod/fafu_checkin.log; }
# 一轮 = 一次完整检查里的两次查询都失败（刷新 token 后重试仍失败）。
# 响应头里的 Date 每轮都不同：它是这一次调用的读数，不是原因。
round() {
  printf 'Date: %s\nContent-Length: 53\n' "$1" > ctl/hdr.cur
  http_post() {
    _api_note 0 200 "$(cat ctl/long.body)" "" ctl/hdr.cur "" ""
    printf '%s' "$(cat ctl/long.body)"
    return 0
  }
  run_once
}
tier 0
round 'Mon, 13 Oct 2025 21:30:00 GMT'; printf 'rc=%s\n' "$?"
round 'Mon, 13 Oct 2025 21:31:00 GMT'
round 'Mon, 13 Oct 2025 21:32:00 GMT'
printf 'same=%s\n' "$(n1)"
printf 'same_retry=%s\n' "$(n2)"
LC_ALL=C grep -aF -e '查询异常:' mod/fafu_checkin.log | head -n 1 > ctl/off.line
# 服务端那一次报错的原文变了 → 原因变了，再留一条
printf '%s\n' '{"timestamp":1759500000000,"status":500,"message":"另一个错"}' > ctl/long.body
round 'Mon, 13 Oct 2025 21:33:00 GMT'
printf 'body=%s\n' "$(n1)"
# 人主动按的子命令不受当日去重限制（真入口那条由 poll 套件验，这里验标记的语义）
FAFU_MANUAL=1
round 'Mon, 13 Oct 2025 21:34:00 GMT'
printf 'manual=%s\n' "$(n1)"
printf 'manual_retry=%s\n' "$(n2)"
FAFU_MANUAL=0
# 调试档：被降级的重复轮次逐条写回来（一条都没被吞掉）
tier 1
round 'Mon, 13 Oct 2025 21:35:00 GMT'
round 'Mon, 13 Oct 2025 21:36:00 GMT'
printf 'debug=%s\n' "$(n1)"
printf 'debug_retry=%s\n' "$(n2)"
DRIVER
  d="$SG_WORK/fetch_dedup.out"
  t_eq "每一轮都返回 2（取不到任务）" "$(sg_val "$d" rc)" "2"
  t_eq "同一种失败连续三轮：默认档只有首次那一条（响应头 Date 每轮不同，不算原因变化）" \
    "$(sg_val "$d" same)" "1"
  t_eq "同一条失败的两个失败点共用一个原因键：刷新后重试那一条不重复留" \
    "$(sg_val "$d" same_retry)" "0"
  t_eq "错误原文变了：默认档再留一条" "$(sg_val "$d" body)" "2"
  t_eq "人主动按的子命令不受当日去重限制" "$(sg_val "$d" manual)" "3"
  t_eq "人主动按的那一次把两个失败点都留下（不受当日去重限制）" \
    "$(sg_val "$d" manual_retry)" "1"
  t_eq "调试档：重复轮次逐条可见（两轮各一条写回来）" "$(sg_val "$d" debug)" "5"
  t_eq "调试档：同一条失败的两个失败点也逐条可见" "$(sg_val "$d" debug_retry)" "3"

  # 默认档那一行仍带着接口那次的完整诊断：状态码 + 完整正文 + 响应头 + 耗时 + 查询参数。
  # 去重只影响「写不写」，不影响「写什么」。
  t_has "默认档：失败行带状态码与完整正文" "$SG_WORK/ctl/off.line" \
    "查询异常: rc=0 http=200 body={\"timestamp\":1759500000000,\"status\":400"
  t_has "默认档：失败行带响应头那一整段（Date 也在）" "$SG_WORK/ctl/off.line" \
    "hdr={Date: Mon, 13 Oct 2025 21:30:00 GMT|Content-Length: 53}"
  t_has "默认档：失败行以耗时读数收尾" "$SG_WORK/ctl/off.line" "耗时=0s params=rows=3&pageNum=1"
}

# ============================================================
# 七、结构边界（静态）：四个函数各归其位、判定链与主循环的两条分支都还在
#
# 判据只用**能力名**与**调用形状**，不绑行号、也不绑局部变量名。
# ============================================================

sg_case_boundary() {
  local src f cap owner miss chain n_extract
  src="$SG_WORK/program.sh"
  t_write_program "$src" || { _t_fail "无法拼出全程序文本"; return 0; }

  miss=""
  for cap in $SG_CAPS; do
    owner=""
    for f in $TEST_LIB_FILES; do
      if grep -qE "^[ 	]*${cap%%:*}[ 	]*\(\)" "$T_ROOT/$f" 2>/dev/null; then owner="${f##*/}"; fi
    done
    [ "$owner" = "${cap##*:}.sh" ] || miss="$miss $cap→${owner:-无}"
  done
  t_eq "签到与提醒的能力都定义在 signin 层" "[$miss]" "[]"

  # 「取任务 / 解析 / 判定 / 提交」四步的定义顺序（= 依赖顺序，也是读代码的顺序）
  chain=""
  for f in $SG_CHAIN; do
    grep -qF "$f" "$T_ROOT/lib/signin.sh" 2>/dev/null || chain="$chain[$f]"
  done
  t_eq "run_once 依次调用取任务 / 解析 / 判定" "[$chain]" "[]"
  t_before "取任务在解析之前" "$T_ROOT/lib/signin.sh" 'signin_fetch()' 'signin_parse()'
  t_before "解析在判定之前" "$T_ROOT/lib/signin.sh" 'signin_parse()' 'signin_decide()'
  t_before "判定在提交并记录之前" "$T_ROOT/lib/signin.sh" 'signin_decide()' 'signin_submit()'
  # token 一路传到提交：少了它，提交会带着空 token 发出去。
  # 这里只看**调用点**有没有把 token 交出去（行为面由「token 一路传到提交」那条端到端断言守）。
  t_has "提交调用点带上了 token" "$T_ROOT/lib/signin.sh" \
    'signin_submit "$rid" "$name" "$dline" "$et" "$lng" "$lat" "$now" "$token"'

  # 字段取值只有一处（base 层的名字取字段）：再手写 grep -o 就等于字段名散了两份
  n_extract=$(grep -cE 'grep -o ' "$T_ROOT/lib/signin.sh" 2>/dev/null)
  t_eq "层内不再手写 grep -o 抽字段（统一走名字取字段）" "${n_extract:-0}" "0"
  t_has "截止字段取的是 supplementEndTime" "$T_ROOT/lib/signin.sh" 'json_first "$1" supplementEndTime'
  t_has "截止字段缺失时回退 endTime" "$T_ROOT/lib/signin.sh" 'json_first "$1" endTime'

  # 主循环的两条分支（返回码的用处所在）：0 → 写当日完成标记；2 → 4 分钟后重试。
  # 删掉任何一条，三档返回码就退化成「只有日志不同」。
  # 重试那一档的写法是「把本轮的休眠时长改成 240」，不是就地 continue——就地跳过会连
  # 同一轮里排在它后面的兜底提醒一起吞掉（那正是最该喊「任务还没发布」的情形）。
  t_has "主循环：返回 0 写当日完成标记" "$T_ROOT/fafu_checkin.sh" '[ $rc -eq 0 ] && done_mark'
  t_has "主循环：返回 2 改成本轮 4 分钟后重试" "$T_ROOT/fafu_checkin.sh" '[ $rc -eq 2 ] && rc_wait=240'
  t_has "主循环：休眠时长由本轮结论决定" "$T_ROOT/fafu_checkin.sh" 'sleep "$rc_wait"'
  # 兜底提醒必须排在那条「任务异常跳 4 分钟」之前：rc=2 就是「取不到任务」。
  t_before "主循环：兜底提醒排在任务异常跳档之前" "$T_ROOT/fafu_checkin.sh" \
    'signin_remind_notask' 'rc_wait=240'
  # 三档语义写在文件头：改判定顺序前先读到这里
  t_has "文件头写明「已解决」档" "$T_ROOT/lib/signin.sh" '0 = 已解决'
  t_has "文件头写明「可重试」档" "$T_ROOT/lib/signin.sh" '1 = 可重试'
  t_has "文件头写明「任务异常」档" "$T_ROOT/lib/signin.sh" '2 = 任务异常'
}

# ---- 注册（顺序即执行顺序）----
t_case "signin-query · 查询失败：参数与完整正文" sg_case_fetch_fail
t_case "signin-query · 查询失败当日去重（原因变了再留、手动命令不受限）" sg_case_fetch_dedup
t_case "signin-query · 任务变化：四元组变了才记一行（含跨日）" sg_case_task_change
t_case "signin-query · 判定链与主循环分支（静态）" sg_case_boundary
