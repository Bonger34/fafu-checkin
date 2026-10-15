# ============================================================
# signin 提醒与失败原因：判定链静态断言、三条截止提醒各发一次、失败原因留在日志里
#
# 前导（夹具／替身／取值辅助）在 tests/_signin-common.sh，本文件只放用例。
# ============================================================
# ---- 共享前导（定义在 tests/_signin-common.sh；本文件自己 source）----
. "$T_ROOT/tests/_signin-common.sh"

# ============================================================
# 九、三条截止提醒的判定：纯函数，喂毫秒值即可断言
#
# 判定与取数分开：这一节只喂毫秒值，不碰网络、不碰通知、不读时钟。
# 「哪一刻真的发出去、正文里写的是哪几个钟点」由下一节（拨钟 + run_once）
# 与 notify 层的文案用例分别守。
# ============================================================

sg_case_remind_due() {
  local d
  sg_setup remind-due
  sg_run remind_due <<'DRIVER'
# 到点未办完：锚点 1000、窗口 600 → [1000, 1600)
due() { signin_remind_due "$1" "$2" "$3" && printf 'due' || printf 'no'; }
printf 'before=%s\n'   "$(due 1000 600 999)"
printf 'at=%s\n'       "$(due 1000 600 1000)"
printf 'inside=%s\n'   "$(due 1000 600 1599)"
printf 'edge=%s\n'     "$(due 1000 600 1600)"
printf 'zero=%s\n'     "$(due 1000 0 1000)"
printf 'neg=%s\n'      "$(due 1000 -1 1000)"
printf 'noanchor=%s\n' "$(due '' 600 5000)"
# 前 30 分钟那一档：锚点是「截止前 30 分钟」，窗口就是这 30 分钟 → [截止-1800000, 截止)
half() { signin_remind_30min "$1" "$2" && printf 'due' || printf 'no'; }
printf 'h_before=%s\n' "$(half 10000000 8199999)"
printf 'h_at=%s\n'     "$(half 10000000 8200000)"
printf 'h_last=%s\n'   "$(half 10000000 9999999)"
printf 'h_edge=%s\n'   "$(half 10000000 10000000)"
printf 'h_none=%s\n'   "$(half '' 8200000)"
DRIVER
  d="$SG_WORK/remind_due.out"
  t_eq "锚点前一刻：不到期" "$(sg_val "$d" before)" "no"
  t_eq "刚过锚点：到期" "$(sg_val "$d" at)" "due"
  t_eq "窗口内：到期" "$(sg_val "$d" inside)" "due"
  t_eq "窗口左闭右开（右边界那一刻交给下一档）" "$(sg_val "$d" edge)" "no"
  t_eq "窗口为 0：不到期（没有可喊的时间）" "$(sg_val "$d" zero)" "no"
  t_eq "窗口为负：不到期" "$(sg_val "$d" neg)" "no"
  t_eq "锚点缺失（任务没给该字段）：不到期" "$(sg_val "$d" noanchor)" "no"
  t_eq "前 30 分钟：截止前 30 分钟差 1 毫秒还不到期" "$(sg_val "$d" h_before)" "no"
  t_eq "前 30 分钟：正好落在截止前 30 分钟时到期" "$(sg_val "$d" h_at)" "due"
  t_eq "前 30 分钟：截止前 1 毫秒仍在档内" "$(sg_val "$d" h_last)" "due"
  t_eq "前 30 分钟：到了截止那一刻交给下一档" "$(sg_val "$d" h_edge)" "no"
  t_eq "前 30 分钟：截止缺失时不到期" "$(sg_val "$d" h_none)" "no"
}

# ============================================================
# 十、三条截止提醒真的发出去：拨钟到各档锚点，看业务层报了哪几个事件
#
# 任务数据用**非默认**钟点（主窗口 21:00~21:40、补签截止 22:10），于是三档锚点
# 分别是 21:10 / 21:40 / 22:10——与任何写死的钟点都对不上，实现里留着旧写法就会分叉。
# 提交一律失败（响应体带 timestamp），于是每一格都停在「可重试」档、当日不会变成已解决，
# 提醒才有机会发出来：这正是三条提醒存在的场景（自动签不上，喊人手动处理）。
# ============================================================

sg_case_remind_events() {
  local d
  sg_setup remind-events
  sg_task_span 1260 1300 1330 > "$SG_WORK/ctl/body.page"
  printf '%s\n' "$SG_SIGN_FAIL" > "$SG_WORK/ctl/body.sign"

  # 20:55：三档锚点都还没到
  sg_at 1255
  printf 'page:0\n' > "$SG_WORK/ctl/api.seq"
  sg_run remind_1255 <<'DRIVER'
run_once >/dev/null 2>&1
printf 'nosign=%s\n' "$(grep -c '^nosign$' ctl/events 2>/dev/null)"
printf 'late=%s\n'   "$(grep -c '^late$' ctl/events 2>/dev/null)"
printf 'miss=%s\n'   "$(grep -c '^miss$' ctl/events 2>/dev/null)"
DRIVER
  d="$SG_WORK/remind_1255.out"
  t_eq "20:55（第一档锚点 21:10 之前）：第一档不发" "$(sg_val "$d" nosign)" "0"
  t_eq "20:55：第二档不发" "$(sg_val "$d" late)" "0"
  t_eq "20:55：第三档不发" "$(sg_val "$d" miss)" "0"

  # 21:20：落在 [21:10, 21:40) → 只有第一档
  sg_at 1280
  printf 'page:0\nsign:0\n' > "$SG_WORK/ctl/api.seq"
  sg_run remind_1280 <<'DRIVER'
run_once >/dev/null 2>&1
printf 'rc=%s\n'     "$?"
printf 'nosign=%s\n' "$(grep -c '^nosign$' ctl/events 2>/dev/null)"
printf 'late=%s\n'   "$(grep -c '^late$' ctl/events 2>/dev/null)"
printf 'miss=%s\n'   "$(grep -c '^miss$' ctl/events 2>/dev/null)"
DRIVER
  d="$SG_WORK/remind_1280.out"
  t_eq "21:20（主窗口截止前 30 分钟内）：第一档发一次" "$(sg_val "$d" nosign)" "1"
  t_eq "21:20：第二档还没到" "$(sg_val "$d" late)" "0"
  t_eq "21:20：第三档还没到" "$(sg_val "$d" miss)" "0"

  # 21:45：落在 [21:40, 22:10) → 只有第二档
  sg_at 1305
  printf 'page:0\nsign:0\n' > "$SG_WORK/ctl/api.seq"
  sg_run remind_1305 <<'DRIVER'
run_once >/dev/null 2>&1
printf 'nosign=%s\n' "$(grep -c '^nosign$' ctl/events 2>/dev/null)"
printf 'late=%s\n'   "$(grep -c '^late$' ctl/events 2>/dev/null)"
printf 'miss=%s\n'   "$(grep -c '^miss$' ctl/events 2>/dev/null)"
DRIVER
  d="$SG_WORK/remind_1305.out"
  t_eq "21:45（过了主窗口截止）：第一档已过，不再发" "$(sg_val "$d" nosign)" "0"
  t_eq "21:45：第二档发一次" "$(sg_val "$d" late)" "1"
  t_eq "21:45：第三档还没到" "$(sg_val "$d" miss)" "0"

  # 22:15：过了补签截止 22:10 → 只有第三档
  sg_at 1335
  printf 'page:0\n' > "$SG_WORK/ctl/api.seq"
  sg_run remind_1335 <<'DRIVER'
run_once >/dev/null 2>&1
printf 'nosign=%s\n' "$(grep -c '^nosign$' ctl/events 2>/dev/null)"
printf 'late=%s\n'   "$(grep -c '^late$' ctl/events 2>/dev/null)"
printf 'miss=%s\n'   "$(grep -c '^miss$' ctl/events 2>/dev/null)"
DRIVER
  d="$SG_WORK/remind_1335.out"
  t_eq "22:15（过了补签截止）：第一档不再发" "$(sg_val "$d" nosign)" "0"
  t_eq "22:15：第二档已过，不再发" "$(sg_val "$d" late)" "0"
  t_eq "22:15：第三档发一次" "$(sg_val "$d" miss)" "1"

  # 当日已解决：同一批时刻一条提醒都不发；把记录去掉后同一时刻照常发（对照）
  sg_setup remind-resolved
  sg_task_span 1260 1300 1330 > "$SG_WORK/ctl/body.page"
  printf '%s\n' "$SG_SIGN_FAIL" > "$SG_WORK/ctl/body.sign"
  printf 'sign_date=%s\nsign_time=21:05\nsign_kind=normal\n' "$SG_DATE" > "$SG_WORK/mod/fafu_checkin.status"
  sg_at 1335
  printf 'page:0\n' > "$SG_WORK/ctl/api.seq"
  sg_run remind_resolved <<'DRIVER'
run_once >/dev/null 2>&1
printf 'events=%s\n' "$(tr '\n' ',' < ctl/events 2>/dev/null)"
DRIVER
  t_eq "当日已解决：过了补签截止也一条提醒都不发" \
    "$(sg_val "$SG_WORK/remind_resolved.out" events)" ""

  : > "$SG_WORK/mod/fafu_checkin.status"
  sg_run remind_resolved_ctl <<'DRIVER'
run_once >/dev/null 2>&1
printf 'miss=%s\n' "$(grep -c '^miss$' ctl/events 2>/dev/null)"
DRIVER
  t_eq "对照：同一时刻去掉当日记录后，第三档照常发" \
    "$(sg_val "$SG_WORK/remind_resolved_ctl.out" miss)" "1"
}

# ============================================================
# 十一、提交失败的原因必须留痕
#
# 失败日志不能只有「rc + 空正文」：busybox wget 失败时响应体为空，唯一的原因线索
# （wget 的报错正文）要是也丢了，事后就分不出「服务端拒绝」「连接失败」「超时」。
# 这一节把「原因能分清」钉成断言：同一种失败模式下，日志要能读出 HTTP 状态码。
# ============================================================

sg_case_fail_reason() {
  local d
  sg_setup fail-reason
  sg_at 1290                                  # 21:30，窗口刚开——提交失败最容易发生的一刻
  sg_body 1290 0 > "$SG_WORK/ctl/body.page"   # 服务端说：任务在窗口内、你还没签
  : > "$SG_WORK/ctl/body.sign"                # 失败档正文为空（busybox wget 拿不到错误正文）

  # ① 服务端拒绝：rc=1、正文空，原因只在 wget 的报错正文里
  printf 'wget: server returned error: HTTP/1.1 500 Internal Server Error\n' > "$SG_WORK/ctl/wget.err"
  printf 'sign:1\n' > "$SG_WORK/ctl/api.seq"
  sg_run fail_500 <<'DRIVER'
signin_submit 88123 "晚查寝签到" 1790866800000 1790865000000 119.243462 26.088417 1790861400000 TOK >/dev/null 2>&1
printf 'rc=%s\n' "$?"
DRIVER
  d="$SG_WORK/fail_500.out"
  t_eq "服务端拒绝：返回 1（下一分钟重试）" "$(sg_val "$d" rc)" "1"
  t_has "服务端拒绝：日志留住了 HTTP 状态码（这是唯一能定性的一处）" \
    "$SG_WORK/mod/fafu_checkin.log" "HTTP/1.1 500"

  # ② 换一个状态码：同一份代码要能分出是哪一个（403 与 500 不是一回事）
  sg_setup fail-reason-403
  sg_at 1290
  sg_body 1290 0 > "$SG_WORK/ctl/body.page"
  : > "$SG_WORK/ctl/body.sign"
  printf 'wget: server returned error: HTTP/1.1 403 Forbidden\n' > "$SG_WORK/ctl/wget.err"
  printf 'sign:1\n' > "$SG_WORK/ctl/api.seq"
  sg_run fail_403 <<'DRIVER'
signin_submit 88123 "晚查寝签到" 1790866800000 1790865000000 119.243462 26.088417 1790861400000 TOK >/dev/null 2>&1
printf 'rc=%s\n' "$?"
DRIVER
  t_has "另一个状态码：日志同样留痕（403 与 500 能分开）" \
    "$SG_WORK/mod/fafu_checkin.log" "HTTP/1.1 403"

  # ③ 超时：退出码与「服务端拒绝」不同（143 对 1），两者不该在日志里长得一样
  sg_setup fail-reason-timeout
  sg_at 1290
  sg_body 1290 0 > "$SG_WORK/ctl/body.page"
  : > "$SG_WORK/ctl/body.sign"
  printf 'wget: download timed out\n' > "$SG_WORK/ctl/wget.err"
  printf 'sign:143\n' > "$SG_WORK/ctl/api.seq"
  sg_run fail_timeout <<'DRIVER'
signin_submit 88123 "晚查寝签到" 1790866800000 1790865000000 119.243462 26.088417 1790861400000 TOK >/dev/null 2>&1
printf 'rc=%s\n' "$?"
DRIVER
  t_has "超时：日志里的退出码与「服务端拒绝」不同（143 ≠ 1）" \
    "$SG_WORK/mod/fafu_checkin.log" "签到失败: rc=143"
  t_has "超时：报错正文同样留痕" "$SG_WORK/mod/fafu_checkin.log" "download timed out"
}

# ============================================================
# 十二、提交尝试行的字段集：服务端拒绝 / 成功 / 连接层失败三档
#
# 这一节**不覆盖 http_post**（路线 B）：CURL_BIN 指向测试底座的 curl 替身，真实 api 层照跑，
# 于是状态码、完整正文、响应头白名单与耗时都是真实代码写下的。
# 直接驱动 signin_submit：一个驱动里只有提交调用，替身对每次调用给同样的应答就够。
# ============================================================

sg_case_attempt_lines() {
  local d f

  # ① 服务端拒绝（HTTP 400）：状态码与完整正文都在这一行
  sg_setup attempt-fail
  sg_at 1290
  printf '400\n' > "$SG_WORK/ctl/curl_code"
  printf '%s\n' "$SG_SIGN_FAIL" > "$SG_WORK/ctl/curl_body"
  printf '%s\n' "$SG_HDR_RAW" > "$SG_WORK/ctl/curl_hdr"
  # 提交失败也会触发一次刷新（老 token 失效是常见档）：那一行同样要说明触发原因，
  # 故这一档让真实 refresh_token 跑起来（采样等待与 token 来源换成替身）。
  SG_REFRESH_MODE=real
  export SG_REFRESH_MODE
  sg_run_real attempt_fail <<'DRIVER'
sleep() { :; }
get_token() { printf 'NEWTOKEN'; }
signin_submit 88123 "晚查寝签到" 1790866800000 1790865000000 119.243462 26.088417 1790861400000 TOK >/dev/null 2>&1
printf 'rc=%s\n' "$?"
printf 'attempts=%s\n' "$(grep -c '提交尝试:' mod/fafu_checkin.log)"
printf 'calls=%s\n'    "$(grep -c . ctl/curl_calls)"
DRIVER
  unset SG_REFRESH_MODE
  d="$SG_WORK/attempt_fail.out"
  f=$(sg_plain_log)
  t_eq "服务端拒绝：返回 1（下一分钟重试）" "$(sg_val "$d" rc)" "1"
  t_eq "服务端拒绝：每次尝试各留一行（行数 = 真实提交调用数）" \
    "$(sg_val "$d" attempts)" "$(sg_val "$d" calls)"
  t_has "失败行：第几次 + 发出去的任务号与坐标 + 服务端状态码 + 完整响应体" "$f" \
    "提交尝试: try=1 rid=88123 lng=119.243462 lat=26.088417 http=400 body=$SG_SIGN_FAIL"
  t_has "失败行：响应头就是白名单那四项、顺序固定" "$f" "$SG_HDR_LINE"
  t_has_re "失败行：响应头排在耗时之前，耗时收尾" "$f" \
    "^提交尝试: try=1 rid=88123 lng=119\.243462 lat=26\.088417 http=400 body=.* hdr=\{.*\} 耗时=[0-9]+(ms|s)$"
  t_has "全部失败：汇总行仍带 rc 与发出去的参数" "$f" \
    "签到失败: rc=1 rid=88123 lng=119.243462 lat=26.088417 "
  # 刷新那一行的触发原因要分清是哪条路来的：提交失败 ≠ 查询失败（用户故事 18）
  t_has "提交失败触发的刷新说明原因（签到提交失败）" "$SG_WORK/mod/fafu_checkin.log" \
    "刷新 token（静默优先） 触发原因=签到提交失败"

  # ② 提交成功：与失败行同一字段集（成功那次也带完整正文与响应头）
  sg_setup attempt-ok
  sg_at 1290
  printf '200\n' > "$SG_WORK/ctl/curl_code"
  printf '%s\n' "$SG_SIGN_OK" > "$SG_WORK/ctl/curl_body"
  printf '%s\n' "$SG_HDR_RAW" > "$SG_WORK/ctl/curl_hdr"
  sg_run_real attempt_ok <<'DRIVER'
signin_submit 88123 "晚查寝签到" 1790866800000 1790865000000 119.243462 26.088417 1790861400000 TOK >/dev/null 2>&1
printf 'rc=%s\n' "$?"
printf 'attempts=%s\n' "$(grep -c '提交尝试:' mod/fafu_checkin.log)"
printf 'calls=%s\n'    "$(grep -c . ctl/curl_calls)"
printf 'kind=%s\n'     "$(sed -n 's/^sign_kind=//p' mod/fafu_checkin.status)"
DRIVER
  d="$SG_WORK/attempt_ok.out"
  f=$(sg_plain_log)
  t_eq "提交成功：返回 0" "$(sg_val "$d" rc)" "0"
  t_eq "提交成功：记下的类型是 normal" "$(sg_val "$d" kind)" "normal"
  t_eq "提交成功：成功那次也恰好一行（行数 = 真实提交调用数）" \
    "$(sg_val "$d" attempts)" "$(sg_val "$d" calls)"
  t_has "成功行：与失败行同一段参数，只有状态码与正文不同" "$f" \
    "提交尝试: try=1 rid=88123 lng=119.243462 lat=26.088417 http=200 body=$SG_SIGN_OK"
  t_has "成功行：响应头就是白名单那四项、顺序固定" "$f" "$SG_HDR_LINE"
  t_has_re "成功行：与失败行同形（响应头 + 耗时收尾）" "$f" \
    "^提交尝试: try=1 rid=88123 lng=119\.243462 lat=26\.088417 http=200 body=.* hdr=\{.*\} 耗时=[0-9]+(ms|s)$"
  t_before "成功行排在业务结论之前（先有事实，再有结论）" "$f" "提交尝试: try=1" "✅ 签到成功"

  # ③ 连接层失败：如实写工具退出码与报错原文，不拿状态码占位
  sg_setup attempt-net
  sg_at 1290
  printf '000\n' > "$SG_WORK/ctl/curl_code"     # 真实 curl 连不上时 -w 也照吐 000
  printf 'curl: (7) Failed to connect to stuhtapi.fafu.edu.cn port 80: Connection refused\n' \
    > "$SG_WORK/ctl/curl_stderr"
  printf '7\n' > "$SG_WORK/ctl/curl_rc"
  sg_run_real attempt_net <<'DRIVER'
signin_submit 88123 "晚查寝签到" 1790866800000 1790865000000 119.243462 26.088417 1790861400000 TOK >/dev/null 2>&1
printf 'rc=%s\n' "$?"
printf 'attempts=%s\n' "$(grep -c '提交尝试:' mod/fafu_checkin.log)"
printf 'calls=%s\n'    "$(grep -c . ctl/curl_calls)"
DRIVER
  d="$SG_WORK/attempt_net.out"
  f=$(sg_plain_log)
  t_eq "连不上：返回 1（这一档仍可重试）" "$(sg_val "$d" rc)" "1"
  t_eq "连不上：每次尝试各留一行（行数 = 真实提交调用数）" \
    "$(sg_val "$d" attempts)" "$(sg_val "$d" calls)"
  t_has "连不上：如实写出退出码、这一档没有状态码、报错原文" "$f" \
    "提交尝试: try=1 rid=88123 lng=119.243462 lat=26.088417 net rc=7 http=- err=curl: (7) Failed to connect to stuhtapi.fafu.edu.cn port 80: Connection refused"
  t_eq "连不上：日志里没有任何数字状态码（不拿 000 冒充）" \
    "$(grep -c 'http=[0-9]' "$f" 2>/dev/null)" "0"
}

# ---- 注册（顺序即执行顺序）----
t_case "signin-remind · 截止提醒的判定（纯函数）" sg_case_remind_due
t_case "signin-remind · 三条截止提醒按任务数据各发一次" sg_case_remind_events
t_case "signin-remind · 提交失败的原因留在日志里（HTTP 状态码 / 超时）" sg_case_fail_reason
t_case "signin-remind · 提交尝试行的字段集（拒绝 / 成功 / 连接层失败）" sg_case_attempt_lines
