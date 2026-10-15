# ============================================================
# signin 判定与提交：返回码三档、四个判定分支、解析与坐标、提交与补签、失败处理
#
# 提交尝试行那条走真实 api 层 + curl 替身；token 一路传到提交也在这条线上。
# 前导（夹具／替身／取值辅助）在 tests/_signin-common.sh，本文件只放用例。
# ============================================================
# ---- 共享前导（定义在 tests/_signin-common.sh；本文件自己 source）----
. "$T_ROOT/tests/_signin-common.sh"

# ============================================================
# 一、时钟与夹具自证：断言里到处都是「EPOCH 偏移」，这一条保证偏移真的落在墙上时钟上
# ============================================================

sg_case_clock() {
  local d
  sg_setup clock
  sg_at 1290        # 21:30
  sg_run clock_at <<'DRIVER'
printf 'hm=%s\n'    "$(now_hm)"
printf 's=%s\n'     "$(now_s)"
printf 'min=%s\n'   "$(now_minutes)"
printf 'today=%s\n' "$(today)"
DRIVER
  d="$SG_WORK/clock_at.out"
  t_eq "拨钟后墙上时钟是 21:30" "$(sg_val "$d" hm)" "21:30"
  t_eq "拨钟后当天第几分钟是 1290" "$(sg_val "$d" min)" "1290"
  t_eq "拨钟后 %s 与零点对齐（判定读的就是它）" "$(sg_val "$d" s)" "$((SG_EPOCH + 1290 * 60))"
  t_eq "拨钟后当日日期是 2026-10-01" "$(sg_val "$d" today)" "$SG_DATE"
}

# ============================================================
# 二、三档返回码：成功 / 可重试 / 任务异常（拆分那个长函数时最容易改坏的地方）
# ============================================================

sg_case_codes() {
  local d
  # ① 已签到 → 0（已解决）
  sg_setup code0
  sg_at 1290
  sg_body_seen 1290 1200 > "$SG_WORK/ctl/body.page"
  printf 'page:0\n' > "$SG_WORK/ctl/api.seq"
  sg_run code0 <<'DRIVER'
run_once; printf 'rc=%s\n' "$?"
DRIVER
  t_eq "返回码 0：已解决（已签到）" "$(sg_val "$SG_WORK/code0.out" rc)" "0"

  # ② 不在时段 → 1（可重试）
  sg_setup code1
  sg_at 1200
  sg_body 1290 > "$SG_WORK/ctl/body.page"
  printf 'page:0\n' > "$SG_WORK/ctl/api.seq"
  sg_run code1 <<'DRIVER'
run_once; printf 'rc=%s\n' "$?"
DRIVER
  t_eq "返回码 1：可重试（不在时段）" "$(sg_val "$SG_WORK/code1.out" rc)" "1"

  # ③ 取不到任务 → 2（任务异常，主循环据此 4 分钟后重试）
  sg_setup code2
  sg_run code2 <<'DRIVER'
: > ctl/api.seq                       # 没有可用序列 → 回落到下面的默认分支
printf 'page:1\n' > ctl/api.default   # 每次查询都失败
run_once; printf 'rc=%s\n' "$?"
DRIVER
  t_eq "返回码 2：任务异常（取不到任务）" "$(sg_val "$SG_WORK/code2.out" rc)" "2"

  # ④ 没有应用数据 → 2（同样是任务异常）；这一档不发通知，故单开一份工作目录。
  # 装上 sleep 替身：默认实现会先等最多 30 秒再判（见 lib/signin.sh 的等待），
  # 真等满没有意义，替身把这一段跳掉而判定链一字不改
  sg_setup code2b
  sg_run code2b <<'DRIVER'
SLEEP_OVERRIDE=:
LD=./mod/definitely-not-there
run_once; printf 'rc=%s\n' "$?"
DRIVER
  t_eq "返回码 2：没有应用数据" "$(sg_val "$SG_WORK/code2b.out" rc)" "2"
  t_eq "无应用数据：一条通知都不发" "$(grep -c . "$SG_WORK/ctl/events" 2>/dev/null)" "0"
}

# 等 App 数据就绪：重启后的头几秒目录还不可读，这时应当短等一会儿再判，
# 而不是直接判成任务异常、白等主循环那 4 分钟。
# 观察面：等待真的发生了（替身被调用）、等到就接着走（rc=0），等不到仍有界地退回 2。
# 两边都用 sleep 替身：等待的长度由常量决定，它在断言里不是重点，次数与结果才是。
sg_case_wait_appdata() {
  # ① 等到：第 3 次探测时目录出现 → 本次照常取到任务（rc=0），且确实等过
  sg_setup wait_ok
  sg_at 1290
  sg_body 1290 0 > "$SG_WORK/ctl/body.page"
  printf 'page:0\n' > "$SG_WORK/ctl/api.seq"
  sg_run wait_ok <<'DRIVER'
mkdir -p ./probe
printf '0\n' > ./probe/n
# sleep 替身：记一次调用，并在第 3 次时把「App 数据目录」造出来
cat > ./probe/sleep <<'SHIM'
n=`cat ./probe/n`
n=$((n + 1))
printf '%s\n' "$n" > ./probe/n
[ "$n" -ge 3 ] && mkdir -p ./mod/appdata
exit 0
SHIM
SLEEP_OVERRIDE=./probe/sleep
export SLEEP_OVERRIDE
LD=./mod/appdata
run_once; printf 'rc=%s\n' "$?"
printf 'calls=%s\n' "$(cat ./probe/n 2>/dev/null)"
printf 'dir=%s\n' "$([ -d ./mod/appdata ] && echo yes || echo no)"
DRIVER
  t_eq "等到就绪：照常取到任务（rc=0）" "$(sg_val "$SG_WORK/wait_ok.out" rc)" "0"
  t_eq "等到就绪：确实等过（替身被调用，次数=目录出现的那一次）" "$(sg_val "$SG_WORK/wait_ok.out" calls)" "3"
  t_eq "等到就绪：此时目录已经在了" "$(sg_val "$SG_WORK/wait_ok.out" dir)" "yes"

  # ② 等不到：等满上限后仍按任务异常返回 2（主循环的 4 分钟兜底接手），且不发通知
  sg_setup wait_timeout
  sg_run wait_timeout <<'DRIVER'
mkdir -p ./probe
printf '0\n' > ./probe/n
# sleep 替身：只记调用次数，永远不造目录 —— 模拟「App 真的没装/数据一直读不到」
cat > ./probe/sleep <<'SHIM'
n=`cat ./probe/n`
printf '%s\n' "$((n + 1))" > ./probe/n
exit 0
SHIM
SLEEP_OVERRIDE=./probe/sleep
export SLEEP_OVERRIDE
LD=./mod/definitely-not-there
run_once; printf 'rc=%s\n' "$?"
printf 'calls=%s\n' "$(cat ./probe/n)"
DRIVER
  t_eq "等满上限：仍返回 2（有界，不会挂住）" "$(sg_val "$SG_WORK/wait_timeout.out" rc)" "2"
  t_eq "等满上限：等待次数就是上限（10 次）" "$(sg_val "$SG_WORK/wait_timeout.out" calls)" "10"
  t_eq "等满上限：一条通知都不发" "$(grep -c . "$SG_WORK/ctl/events" 2>/dev/null)" "0"
}

# ============================================================
# 三、四个判定分支：判定顺序逐条对应，分支动作逐条不变
# ============================================================

sg_case_branch_seen() {
  local d w
  sg_setup seen
  sg_at 1290                                            # 21:30
  sg_body_seen 1290 1230 > "$SG_WORK/ctl/body.page"      # signTime = 20:30
  printf '%s\n' "$SG_HDR_RAW" > "$SG_WORK/ctl/hdr"       # 这一次服务端给了响应头四项
  printf 'page:0\n' > "$SG_WORK/ctl/api.seq"
  sg_run br_seen <<'DRIVER'
run_once
printf 'rc=%s\n'     "$?"
printf 'events=%s\n' "$(tr '\n' ',' < ctl/events 2>/dev/null)"
printf 'desc=%s\n'   "$(grep -c . ctl/desc 2>/dev/null || echo 0)"
printf 'calls=%s\n'  "$(grep -c . ctl/api.calls 2>/dev/null || echo 0)"
printf 'signreq=%s\n' "$(grep -c 'student/sign' ctl/api.calls 2>/dev/null || echo 0)"
DRIVER
  d="$SG_WORK/br_seen.out"
  w="$SG_WORK/mod/fafu_checkin.status"
  t_eq "已签到：返回 0" "$(sg_val "$d" rc)" "0"
  t_eq "已签到：日志文案不变" "$(sg_log)" "[晚查寝签到] 已签到"
  t_eq "已签到：通知事件是 seen" "$(sg_val "$d" events)" "seen,"
  t_eq "已签到：记录下来的是 signTime 换算的时间" "$(sg_status sign_time)" "20:30"
  # 核对行同时留下原始戳与换算值：落库钟点若对不上，一行就能定位是哪一段错的。
  # 用 sg_log_has 而不是 sg_log——这行不保证是最后一行，别挤掉上面的「日志文案不变」；
  # 用 t_has 而不是 t_eq——加旁证字段不该让这条断言跟着改。
  t_has "已签到：日志里有原始戳与换算值的核对行" \
    "$SG_WORK/mod/fafu_checkin.log" "时间核对: signTime=[$(( SG_EPOCH * 1000 + 1230 * 60000 ))] → sign_time=[20:30]"
  # 那一行要能一次定性「记录里的钟点为什么不对」：服务端那条记录整条落盘（字段名以
  # 接口返回的为准），四种时间并排（本地此刻 / 原始毫秒戳 / 换算结果 / 同一戳按 UTC）。
  sg_log_has "时间核对:" > "$SG_WORK/seen.line"
  t_has "已签到：服务端记录整条落盘（任务号 / 名称）" "$SG_WORK/seen.line" \
    '"id":88123,"name":"晚查寝签到"'
  t_has "已签到：记录里的三个时点都在（开始 / 主窗口截止 / 补签截止）" "$SG_WORK/seen.line" \
    '"beginTime":'"$(( SG_EPOCH * 1000 + 1290 * 60000 ))"',"supplementEndTime":'"$(( SG_EPOCH * 1000 + 1380 * 60000 ))"',"endTime":'"$(( SG_EPOCH * 1000 + 1350 * 60000 ))"
  t_has "已签到：签到状态与坐标也在（整条记录，不是挑几个字段）" "$SG_WORK/seen.line" \
    '"signInStudent":{"signState":1},"lng":119.243462,"lat":26.088417'
  t_has "已签到：签到时刻（signTime）原样在记录里" "$SG_WORK/seen.line" \
    '"signTime":'"$(( SG_EPOCH * 1000 + 1230 * 60000 ))"
  t_has "已签到：本地此刻与记录同一行" "$SG_WORK/seen.line" "now=[$SG_DATE 21:30:00]"
  t_has "已签到：同一戳按 UTC 的解释同一行（换算分歧一眼可见）" "$SG_WORK/seen.line" \
    "alt=[$(sg_utc_hm 1230)]"
  t_has "已签到：时区与库路径变量作为环境旁证同一行" "$SG_WORK/seen.line" "TZ=["
  t_has "已签到：库路径变量也在同一行" "$SG_WORK/seen.line" "LDP=["
  # 服务端认为现在几点也要在同一行：本地 now= 与服务端 Date 并排，「时间偏差归谁」才不必推理
  t_has "已签到：服务端的响应头与核对行并排（Date 可供对齐）" "$SG_WORK/seen.line" "$SG_HDR_LINE"
  t_hasnt "已签到（记录在上限内）：不带任何截断字段" "$SG_WORK/seen.line" "记录trunc="
  t_eq "已签到：记录类型是 detected" "$(sg_status sign_kind)" "detected"
  t_eq "已签到：记录日期是今天" "$(sg_status sign_date)" "$SG_DATE"
  t_eq "已签到：刷新了模块描述" "$(sg_val "$d" desc)" "1"
  t_eq "已签到：只查一次任务（不再提交）" "$(sg_val "$d" calls)" "1"
  t_eq "已签到：没有任何提交请求" "$(sg_val "$d" signreq)" "0"
  t_file "已签到：签到记录文件确实生成" "$w"

  # 记录超过 2KB：与 api 层的 `body=` 同一口径——同一行里标明**原始字节数**与被我们截断。
  # 不标的话，事后会把「被我们截断」读成「服务端只回了这么多」（用户故事 20）。
  sg_setup seen-big
  sg_at 1290
  sg_body_seen_big > "$SG_WORK/ctl/body.page"
  printf 'page:0\n' > "$SG_WORK/ctl/api.seq"
  sg_run br_seen_big <<'DRIVER'
run_once
printf 'rc=%s\n' "$?"
sed 's/^\[[^]]*\][ ]*//' mod/fafu_checkin.log | grep -F '时间核对:' | tail -n 1 > ctl/big.line
# 三个读数都从那一行里取：记录段本身的长度 / 它声明的原始字节数 / 截断标记
printf 'flat=%s\n'  "$(sed 's/.*记录=//; s/ 记录len=.*//' ctl/big.line | tr -d '\n' | wc -c | tr -dc '0-9')"
printf 'len=%s\n'   "$(sed 's/.*记录len=//; s/ .*//' ctl/big.line)"
printf 'trunc=%s\n' "$(sed 's/.*记录trunc=//' ctl/big.line)"
# 真值取夹具文件本身的大小（不含末尾换行，与交给日志的那个串逐字节同长）
printf 'bytes=%s\n' "$(wc -c < ctl/body.page | tr -dc '0-9')"
DRIVER
  d="$SG_WORK/br_seen_big.out"
  t_eq "记录超限：仍按已签到结算（返回 0）" "$(sg_val "$d" rc)" "0"
  t_eq "记录超限：记录段只留上限那么多字节" "$(sg_val "$d" flat)" "2048"
  t_eq "记录超限：同一行给出原始字节数（就是夹具那份响应的大小）" \
    "$(sg_val "$d" len)" "$(sg_val "$d" bytes)"
  t_eq "记录超限：同一行标明这一档被截断" "$(sg_val "$d" trunc)" "1"
}

sg_case_branch_leave() {
  local d
  sg_setup leave
  sg_at 1290
  sg_body 1290 2 > "$SG_WORK/ctl/body.page"      # signState=2（已请假）
  printf 'page:0\n' > "$SG_WORK/ctl/api.seq"
  sg_run br_leave <<'DRIVER'
run_once
printf 'rc=%s\n'     "$?"
printf 'events=%s\n' "$(tr '\n' ',' < ctl/events 2>/dev/null)"
DRIVER
  d="$SG_WORK/br_leave.out"
  t_eq "已请假：返回 0（已解决，不再重试）" "$(sg_val "$d" rc)" "0"
  t_eq "已请假：通知事件是 leave" "$(sg_val "$d" events)" "leave,"
  t_eq "已请假：记录类型是 leave" "$(sg_status sign_kind)" "leave"
  t_eq "已请假：记录日期是今天" "$(sg_status sign_date)" "$SG_DATE"
  t_eq "已请假：不记录签到时间" "$(sg_status sign_time)" ""
  # 这一档的服务端记录里**没有** signTime（请假记录本来就没有签到时刻）。
  # 缺值就两个换算位都留空：一处空、一处有值（`alt=[00:00]`）会被读成「服务端说 00:00」，
  # 而那是 1970 年零点换算出来的假钟点——本文件的口径是缺值输出空，不造假值。
  sg_log_has "时间核对:" > "$SG_WORK/leave.line"
  t_has_re "已请假：没有 signTime 时两个换算位都留空" "$SG_WORK/leave.line" \
    '^时间核对: signTime=\[\] → sign_time=\[\] now=\[.*\] TZ=\[.*\] LDP=\[.*\] alt=\[\] 记录='
  t_hasnt "已请假：不拿「1970 年零点」冒充 UTC 换算值" "$SG_WORK/leave.line" "alt=[00:00]"
}

sg_case_branch_window() {
  local d
  sg_setup window
  sg_at 1290                                    # 21:30：主窗口刚开
  sg_body 1290 0 > "$SG_WORK/ctl/body.page"      # 未签，窗口 21:30~22:30
  printf '%s\n' "$SG_SEQ_OK" > "$SG_WORK/ctl/api.seq"
  printf '%s\n' "$SG_SIGN_OK" > "$SG_WORK/ctl/body.sign"
  sg_run br_window <<'DRIVER'
run_once; printf 'rc=%s\n' "$?"
printf 'hm=%s\n'     "$(now_hm)"
printf 'events=%s\n' "$(tr '\n' ',' < ctl/events 2>/dev/null)"
printf 'desc=%s\n'   "$(grep -c . ctl/desc 2>/dev/null || echo 0)"
printf 'signreq=%s\n' "$(grep -c 'sign_in/88123/student/sign?lng=119.243462&lat=26.088417' ctl/api.calls 2>/dev/null || echo 0)"
DRIVER
  d="$SG_WORK/br_window.out"
  t_eq "窗口内未签：返回 0" "$(sg_val "$d" rc)" "0"
  t_eq "主窗口提交：日志是「签到成功」" "$(sg_log)" "✅ 签到成功 [晚查寝签到]"
  t_eq "主窗口提交：记录类型是 normal" "$(sg_status sign_kind)" "normal"
  t_eq "主窗口提交：记录时间取当前时刻" "$(sg_status sign_time)" "$(sg_val "$d" hm)"
  t_eq "主窗口提交：记录日期是今天" "$(sg_status sign_date)" "$SG_DATE"
  t_eq "主窗口提交：通知事件是 sign（补签才是 supp）" "$(sg_val "$d" events)" "sign,"
  t_eq "主窗口提交：刷新了模块描述" "$(sg_val "$d" desc)" "1"
  t_eq "提交请求带任务号与坐标" "$(sg_val "$d" signreq)" "1"
}

sg_case_branch_outside() {
  local d
  sg_setup outside
  # 两个方向各验一次。注意接口给的窗口是 beginTime ~ supplementEndTime（补签截止），
  # 所以「不在时段」只有两种：**还没开始**，以及**补签截止也过了**。
  # 主窗口结束到补签截止之间仍会提交（那正是补签，见第四节），不能拿它当窗口外。
  sg_at 1200                                   # 20:00：还没开始
  sg_body 1290 0 > "$SG_WORK/ctl/body.page"
  printf 'page:0\n' > "$SG_WORK/ctl/api.seq"
  sg_run br_out <<'DRIVER'
run_once; printf 'rc=%s\n' "$?"
printf 'events=%s\n' "$(grep -c . ctl/events 2>/dev/null || echo 0)"
printf 'calls=%s\n'  "$(grep -c . ctl/api.calls 2>/dev/null || echo 0)"
DRIVER
  d="$SG_WORK/br_out.out"
  t_eq "还没开始：返回 1（下一分钟再看）" "$(sg_val "$d" rc)" "1"
  t_eq "还没开始：日志文案不变" "$(sg_log)" "[晚查寝签到] 不在签到时段"
  t_eq "还没开始：不发任何通知" "$(sg_val "$d" events)" "0"
  t_eq "还没开始：不提交（只有一次查询）" "$(sg_val "$d" calls)" "1"

  # 补签截止也过了：拨到 23:31（比夹具的 23:30 晚一分钟，也远离真实时间）
  sg_at 1411
  printf '%s\n' "$SG_SEQ_OK" > "$SG_WORK/ctl/api.seq"
  sg_run br_out2 <<'DRIVER'
run_once; printf 'rc=%s\n' "$?"
printf 'calls=%s\n' "$(grep -c . ctl/api.calls 2>/dev/null)"
DRIVER
  d="$SG_WORK/br_out2.out"
  t_eq "已过补签截止：返回 1" "$(sg_val "$d" rc)" "1"
  t_eq "已过补签截止：日志文案不变" "$(sg_log)" "[晚查寝签到] 不在签到时段"
  t_eq "已过补签截止：不提交" "$(sg_val "$d" calls)" "1"
}

# 信息不完整（缺必需字段）→ 可重试：接口在返回、只是字段没齐，不是「任务异常」
sg_case_parse_incomplete() {
  local d
  sg_setup incomplete
  sg_at 1290
  printf '{"records":[{"name":"晚查寝签到","signInStudent":{"signState":0}}]}\n' \
    > "$SG_WORK/ctl/body.page"
  printf 'page:0\n' > "$SG_WORK/ctl/api.seq"
  sg_run inc <<'DRIVER'
run_once; printf 'rc=%s\n' "$?"
DRIVER
  d="$SG_WORK/inc.out"
  t_eq "信息不完整：返回 1（可重试）" "$(sg_val "$d" rc)" "1"
  t_eq "信息不完整：日志文案不变" "$(sg_log)" "暂无有效任务（信息不完整）"
}

# 解析这一步的输出契约：字段由 signin_parse 写进调用方声明的 local，判定再按参数收下。
# 写成四个函数时最容易在这里出问题——写回目标与被写回的局部同名时 eval 会写给自己，
# 判定于是拿到空字段、一路走错分支。这条端到端钉住「字段确实传出去了」。
sg_case_parse_outputs() {
  local d
  sg_setup outputs
  sg_at 1290
  sg_body_seen 1290 1230 > "$SG_WORK/ctl/body.page"   # 已签到，signTime = 20:30
  printf '%s\n' "$SG_SEQ_OK" > "$SG_WORK/ctl/api.seq"
  sg_run outputs <<'DRIVER'
resp=$(cat ctl/body.page)
local_rid=""; signin_parse "$resp" local_rid x1 x2 x3 x4 x5 >/dev/null
printf 'rid=%s\n' "$local_rid"
signin_parse "$resp" a b c d e f >/dev/null; printf 'fields=%s|%s|%s|%s|%s\n' "$b" "$c" "$d" "$e" "$f"
# 与「整条链路」对照：同一条响应体走 run_once 应判成「已签到」
run_once; printf 'rc=%s\n' "$?"
DRIVER
  d="$SG_WORK/outputs.out"
  t_eq "解析：任务号写回了调用方的变量" "$(sg_val "$d" rid)" "88123"
  # 期望值必须与夹具同源（EPOCH + 偏移），不能写死绝对时间戳：
  # 写死就等于把「跑测试的机器的时区」烧进了断言，CI（UTC）与本机（UTC+8）会得出不同的值。
  t_eq "解析：名称 / 状态 / 开始 / 截止 / 主窗口截止 六项都写回" \
    "$(sg_val "$d" fields)" "晚查寝签到|1|$((SG_EPOCH * 1000 + 1290 * 60000))|$((SG_EPOCH * 1000 + 1380 * 60000))|$((SG_EPOCH * 1000 + 1350 * 60000))"
  t_eq "解析结果被判定用上了（判成「已签到」而不是走提交）" "$(sg_val "$d" rc)" "0"
  t_eq "解析结果被判定用上了（通知事件是 seen）" "$(sg_log)" "[晚查寝签到] 已签到"
}

# 缺少 supplementEndTime 时回退 endTime（补签截止的判定基准）
sg_case_parse_fallback() {
  local d
  sg_setup fallback
  sg_at 1349                       # 22:29：主窗口内
  printf '{"records":[{"id":7,"name":"晚查寝签到","beginTime":%s,"endTime":%s,"signInStudent":{"signState":0}}]}\n' \
    "$((SG_EPOCH * 1000 + 1290 * 60000))" "$((SG_EPOCH * 1000 + 1350 * 60000))" > "$SG_WORK/ctl/body.page"
  printf '%s\n' "$SG_SEQ_OK" > "$SG_WORK/ctl/api.seq"
  printf '%s\n' "$SG_SIGN_OK" > "$SG_WORK/ctl/body.sign"
  sg_run fb <<'DRIVER'
run_once; printf 'rc=%s\n' "$?"
DRIVER
  d="$SG_WORK/fb.out"
  t_eq "缺 supplementEndTime：回退 endTime 仍能判定（返回 0）" "$(sg_val "$d" rc)" "0"
  t_eq "回退得到的截止在主窗口内：记为 normal" "$(sg_status sign_kind)" "normal"
}

# 坐标缺失：回退到内置坐标（本任务不校验位置，但参数不能是空串）
sg_case_coords_fallback() {
  local d
  sg_setup coords
  sg_at 1290
  # 响应体里没有 lng / lat（接口在未定位时可能不给）
  printf '{"records":[{"id":9,"name":"晚查寝签到","beginTime":%s,"supplementEndTime":%s,"endTime":%s,"signInStudent":{"signState":0}}]}\n' \
    "$((SG_EPOCH * 1000 + 1290 * 60000))" "$((SG_EPOCH * 1000 + 1380 * 60000))" \
    "$((SG_EPOCH * 1000 + 1350 * 60000))" > "$SG_WORK/ctl/body.page"
  printf '%s\n' "$SG_SIGN_OK" > "$SG_WORK/ctl/body.sign"
  printf '%s\n' "$SG_SEQ_OK" > "$SG_WORK/ctl/api.seq"
  sg_run coords <<'DRIVER'
run_once; printf 'rc=%s\n' "$?"
printf 'coords=%s\n' "$(grep -c 'lng=119.243462&lat=26.088417' ctl/api.calls 2>/dev/null)"
DRIVER
  d="$SG_WORK/coords.out"
  t_eq "坐标缺失：回退后仍能提交成功" "$(sg_val "$d" rc)" "0"
  t_eq "坐标缺失：用的是内置坐标（不是空串、不是 null）" "$(sg_val "$d" coords)" "1"
  t_eq "坐标缺失：记为 normal" "$(sg_status sign_kind)" "normal"
}

# 坐标取值的优先级：signInStudent（最近一次签到的真实位置）＞ 任务顶层 ＞ 内置坐标。
# 真机 2026-10-12 的形状是「顶层 lng/lat 是 null、signInStudent 里是真坐标」——
# 按「取第一次出现」会拿到字符串 `null`，它非空、回退也不触发，于是请求里真的发出
# `lng=null&lat=null`，服务端回 400（Content-Length: 0）。本用例钉住修复后的优先级。
sg_case_coords_priority() {
  local d
  sg_setup coords-priority
  sg_at 1290
  # ① 真机形状：顶层 null，signInStudent 内是真坐标
  printf '{"records":[{"id":316929,"name":"晚查寝签到","beginTime":%s,"supplementEndTime":%s,"endTime":%s,"lng":null,"lat":null,"signInStudent":{"id":46721331,"signState":0,"lng":118.23577500,"lat":25.07802600}}]}\n' \
    "$((SG_EPOCH * 1000 + 1290 * 60000))" "$((SG_EPOCH * 1000 + 1380 * 60000))" \
    "$((SG_EPOCH * 1000 + 1350 * 60000))" > "$SG_WORK/ctl/body.page"
  printf '%s\n' "$SG_SIGN_OK" > "$SG_WORK/ctl/body.sign"
  printf '%s\n' "$SG_SEQ_OK" > "$SG_WORK/ctl/api.seq"
  sg_run coords_real <<'DRIVER'
run_once; printf 'rc=%s\n' "$?"
printf 'real=%s\n' "$(grep -c 'lng=118.23577500&lat=25.07802600' ctl/api.calls 2>/dev/null)"
printf 'nulllit=%s\n' "$(grep -c 'lng=null' ctl/api.calls 2>/dev/null || echo 0)"
DRIVER
  d="$SG_WORK/coords_real.out"
  t_eq "顶层是 null：提交仍成功" "$(sg_val "$d" rc)" "0"
  t_eq "顶层是 null：用的是 signInStudent 里的真实坐标" "$(sg_val "$d" real)" "1"
  t_eq "顶层是 null：绝不把字符串 null 发出去" "$(sg_val "$d" nulllit)" "0"

  # ② 顶层有真值、signInStudent 没有坐标 → 用顶层
  sg_setup coords-top
  sg_at 1290
  printf '{"records":[{"id":9,"name":"晚查寝签到","beginTime":%s,"supplementEndTime":%s,"endTime":%s,"lng":120.1,"lat":30.2,"signInStudent":{"signState":0}}]}\n' \
    "$((SG_EPOCH * 1000 + 1290 * 60000))" "$((SG_EPOCH * 1000 + 1380 * 60000))" \
    "$((SG_EPOCH * 1000 + 1350 * 60000))" > "$SG_WORK/ctl/body.page"
  printf '%s\n' "$SG_SIGN_OK" > "$SG_WORK/ctl/body.sign"
  printf '%s\n' "$SG_SEQ_OK" > "$SG_WORK/ctl/api.seq"
  sg_run coords_top <<'DRIVER'
run_once; printf 'rc=%s\n' "$?"
printf 'top=%s\n' "$(grep -c 'lng=120.1&lat=30.2' ctl/api.calls 2>/dev/null)"
DRIVER
  d="$SG_WORK/coords_top.out"
  t_eq "signInStudent 无坐标：退回顶层真值" "$(sg_val "$d" top)" "1"
}

# ============================================================
# 三·五、token 一路传到提交（端到端：真实的 get_token → 提交）
#
# 这条钉的是「拆函数最容易踩的坑」：token 原本是各函数共享的变量，拆开后必须靠参数
# 一路带下去。断言不看源码怎么写，只看**交给系统的请求头**里有没有它
# （Authorization = base64(ts:nonce:hash:token)，故解一次 base64 再取尾段）。
# ============================================================

sg_case_token_chain() {
  local d
  sg_setup chain
  sg_at 1290
  # 真实的 token 来源：api 层的 get_token 按修改时间倒序读这个目录，取最后一个。
  # token 字面量必须是 get_token 认得的那种形态（2_ + 十六进制），否则它取到空串，
  # 这条断言就退化成「空 token 也是空 token」
  mkdir -p "$SG_WORK/mod/tok"
  printf '{"token":"2_AA11BB22"}\n' > "$SG_WORK/mod/tok/a.ldb"
  printf '{"token":"2_CC33DD44"}\n' > "$SG_WORK/mod/tok/b.ldb"
  sg_body 1290 0 > "$SG_WORK/ctl/body.page"
  printf '%s\n' "$SG_SIGN_OK" > "$SG_WORK/ctl/body.sign"
  printf '%s\n' "$SG_SEQ_OK" > "$SG_WORK/ctl/api.seq"
  sg_run chain <<'DRIVER'
LD=./mod/tok
run_once; printf 'rc=%s\n' "$?"
# 逐条从请求头里取出 token 段。Authorization = base64(ts:nonce:hash:token)，
# 故解 base64 后按 ':' 切四段取第四段 —— 切分交给 read 的 IFS，不手写字符串裁剪
i=0
while IFS= read -r line; do
  i=$((i + 1))
  hdr=$(printf '%s' "$line" | cut -d'|' -f2 | sed 's/^ //; s/ $//')
  printf '%s' "$hdr" | "$BB" base64 -d 2>/dev/null > ctl/auth.raw
  IFS=: read -r _ts _nonce _hash tok4 _rest < ctl/auth.raw
  printf 'tok%s=%s\n' "$i" "$tok4"
done < ctl/api.calls
DRIVER
  d="$SG_WORK/chain.out"
  t_eq "端到端：返回 0（提交成功）" "$(sg_val "$d" rc)" "0"
  # 不断言「用的是一号还是二号」：两个夹具文件的修改时间可能落在同一秒，
  # ls -tr 的先后就不稳定。断言「取到了合法 token」与「同一条链路上
  # 查询和提交用的是同一个」——这两条才是拆函数会改坏的东西。
  t_has "查询带上了真实的 token（不是空串）" "$d" "tok1=2_"
  t_eq "提交带上的是同一个 token（空 token 在真机上是 401）" \
    "$(sg_val "$d" tok2)" "$(sg_val "$d" tok1)"
  t_eq "提交的 token 就是刚取到的那一个（非空即证明参数一路传到了提交）" \
    "$(sg_val "$d" tok2 | cut -c1-2)" "2_"
}

# ============================================================
# 四、提交并记录：主窗口 / 补签 / 提交失败当日仅首次通知
# ============================================================

sg_case_submit_supplement() {
  local d
  sg_setup supplement
  sg_at 1355                       # 22:35：主窗口（22:30）已过、补签截止（23:00）之前
  sg_body 1290 0 > "$SG_WORK/ctl/body.page"
  printf '%s\n' "$SG_SEQ_OK" > "$SG_WORK/ctl/api.seq"
  printf '%s\n' "$SG_SIGN_OK" > "$SG_WORK/ctl/body.sign"
  sg_run supp <<'DRIVER'
run_once; printf 'rc=%s\n' "$?"
printf 'hm=%s\n'     "$(now_hm)"
printf 'events=%s\n' "$(tr '\n' ',' < ctl/events 2>/dev/null)"
DRIVER
  d="$SG_WORK/supp.out"
  t_eq "补签：返回 0" "$(sg_val "$d" rc)" "0"
  t_eq "补签：日志是「补签成功」" "$(sg_log)" "✅ 补签成功 [晚查寝签到]"
  t_eq "补签：记录类型是 supplement" "$(sg_status sign_kind)" "supplement"
  t_eq "补签：记录时间取当前时刻" "$(sg_status sign_time)" "$(sg_val "$d" hm)"
  t_eq "补签：通知事件是 supp（与主窗口的 sign 区分）" "$(sg_val "$d" events)" "supp,"
}

sg_case_submit_failed() {
  local d f
  sg_setup failed
  sg_at 1290
  sg_body 1290 0 > "$SG_WORK/ctl/body.page"
  # 服务端拒绝：请求发出去了、响应体里带 timestamp（那是服务端报错的标志）。
  # 调用本身非 0 那条路径在第十一节。
  printf '%s\n' "$SG_SEQ_OK" > "$SG_WORK/ctl/api.seq"
  printf '%s\n' "$SG_SIGN_FAIL" > "$SG_WORK/ctl/body.sign"
  sg_run failed <<'DRIVER'
run_once; printf 'rc=%s\n' "$?"
printf 'events=%s\n'   "$(tr '\n' ',' < ctl/events 2>/dev/null)"
printf 'desc=%s\n'     "$(grep -c . ctl/desc 2>/dev/null || echo 0)"
printf 'attempts=%s\n' "$(grep -c '提交尝试:' mod/fafu_checkin.log)"
printf 'signs=%s\n'    "$(grep -c 'student/sign' ctl/api.calls 2>/dev/null)"
DRIVER
  d="$SG_WORK/failed.out"
  f=$(sg_plain_log)
  t_eq "提交失败：返回 1（下一分钟重试）" "$(sg_val "$d" rc)" "1"
  # 每一次尝试各一行：最后一次失败的那次也有自己的行，不靠汇总行代表它
  t_eq "提交失败：每次尝试各留一行（行数 = 真实提交调用数）" \
    "$(sg_val "$d" attempts)" "$(sg_val "$d" signs)"
  # 参数也要留痕：400 一类的「请求不合法」只能靠发出去的 rid/坐标来判
  t_has "提交失败：尝试行带第几次、任务号、坐标、状态码与完整正文" "$f" \
    "提交尝试: try=1 rid=88123 lng=119.243462 lat=26.088417 http=200 body=$SG_SIGN_FAIL"
  t_has_re "提交失败：尝试行以耗时收尾" "$f" "^提交尝试: .* 耗时=[0-9]+(ms|s)$"
  # 全部失败：末尾那行汇总仍给出参数、尝试次数与服务端原文
  t_has "提交失败：汇总行仍带 rc 与发出去的参数" "$f" \
    "签到失败: rc=0 rid=88123 lng=119.243462 lat=26.088417 "
  t_has_re "提交失败：汇总行给出尝试次数" "$f" "^签到失败: .* try=[0-9]+ tries=[0-9]+ "
  t_has_re "提交失败：汇总行带上服务端原文" "$f" '^签到失败: .*body=\{"timestamp"'
  t_eq "提交失败：通知事件是 failsign" "$(sg_val "$d" events)" "failsign,"
  t_eq "提交失败：不写签到记录" "$(sg_status sign_kind)" ""
  t_eq "提交失败：不刷新描述（没有成功可言）" "$(sg_val "$d" desc)" "0"
}

# 「提交失败当日仅首次通知」：这是跨层不变式——signin 层每轮只报事件名，去重靠 notify 层的
# 当日标记。两轮都提交失败时，第二轮必须仍被判成「今天已发过」。
# 一轮里的短重试会打好几次提交，故断言按**轮**计数（事件名两行、真正发出一次）。
sg_case_submit_failed_once() {
  local d
  sg_setup failed-once
  sg_at 1291
  sg_body 1290 0 > "$SG_WORK/ctl/body.page"
  printf '%s\n' "$SG_SIGN_FAIL" > "$SG_WORK/ctl/body.sign"
  sg_run failed_once <<'DRIVER'
# notify_once 换成真实的当日去重：先记下 signin 层报的事件名，再按标记决定发不发
notify_once() {
  printf '%s\n' "$1" >> ctl/events
  case "$1" in
    failsign) f=./mod/.fafu_notify_fail ;;
    *)        f=./mod/.fafu_notify_other ;;
  esac
  if [ -f "$f" ]; then printf '%s skipped\n' "$1" >> ctl/dup
  else printf '%s sent\n' "$1" >> ctl/dup; date +%Y-%m-%d > "$f"; fi
  return 0
}
# 两轮都提交失败：每轮开始都把替身序列复位（序列是「这一个驱动内的第 N 次调用」）
printf 'page:0\nsign:0\n' > ctl/api.seq
printf '0' > ctl/seq.n
run_once; printf 'rc1=%s\n' "$?"
printf 'page:0\nsign:0\n' > ctl/api.seq
printf '0' > ctl/seq.n
run_once; printf 'rc2=%s\n' "$?"
printf 'failsign=%s\n' "$(grep -c '^failsign$' ctl/events 2>/dev/null)"
printf 'sent=%s\n'     "$(grep -c ' sent$' ctl/dup 2>/dev/null)"
printf 'skipped=%s\n'  "$(grep -c ' skipped$' ctl/dup 2>/dev/null)"
DRIVER
  d="$SG_WORK/failed_once.out"
  t_eq "两轮都失败：两轮都返回 1" "$(sg_val "$d" rc1),$(sg_val "$d" rc2)" "1,1"
  t_eq "两轮都失败：signin 层两轮都报同一事件名" "$(sg_val "$d" failsign)" "2"
  t_eq "当日仅首次通知：当日真的只发出一条" "$(sg_val "$d" sent)" "1"
  t_eq "当日仅首次通知：第二轮因落过标记被判成已发过" "$(sg_val "$d" skipped)" "1"
}

# ---- 注册（顺序即执行顺序）----
t_case "signin-submit · 时钟与夹具自证" sg_case_clock
t_case "signin-submit · 三档返回码（成功 / 可重试 / 任务异常）" sg_case_codes
t_case "signin-submit · 等 App 数据就绪（等到就用，等不到有界退回）" sg_case_wait_appdata
t_case "signin-submit · 分支：已签到（记录 + 通知）" sg_case_branch_seen
t_case "signin-submit · 分支：已请假（记录 + 通知）" sg_case_branch_leave
t_case "signin-submit · 分支：窗口内提交（normal）" sg_case_branch_window
t_case "signin-submit · 分支：不在时段（可重试）" sg_case_branch_outside
t_case "signin-submit · 任务信息不完整（可重试）" sg_case_parse_incomplete
t_case "signin-submit · 解析写回调用方字段（端到端）" sg_case_parse_outputs
t_case "signin-submit · 截止字段回退 endTime" sg_case_parse_fallback
t_case "signin-submit · 坐标缺失回退内置坐标" sg_case_coords_fallback
t_case "signin-submit · 坐标取值优先级（signInStudent ＞ 顶层 ＞ 内置）" sg_case_coords_priority
t_case "signin-submit · token 一路传到提交（端到端）" sg_case_token_chain
t_case "signin-submit · 提交：补签（supplement）" sg_case_submit_supplement
t_case "signin-submit · 提交失败：尝试行与汇总行" sg_case_submit_failed
t_case "signin-submit · 提交失败当日仅首次通知（跨轮）" sg_case_submit_failed_once
