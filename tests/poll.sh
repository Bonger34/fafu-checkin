#!/bin/sh
# ============================================================
# 入口主循环验收断言：轮询范围（配置）与「当日已解决即停轮询」
#
# 观察面：把模块拷成可独立运行的副本，在副本的 commands 层尾部接一段替身——
#   run_once 记下被调用的时刻；sleep 不真的等，按 ctl/plan 逐行拨钟，
#   计划走完就把服务置为停用，主循环按既有的「停用即退出」语义收尾。
# 时间仍走既有的拨钟缝（mock busybox + MOCK_DATE_CTL），不引入新的时间机制。
# 配置写在副本的 fafu-checkin.conf 里，故断言验的是「配置真的在起作用」。
# ============================================================

POLL_WORK=""
POLL_DATE='2026-10-01'

# 每个用例一份独立工作目录：模块副本 + mock 工具链 + 控制目录
poll_setup() { # $1=用例名
  local name
  name="$1"
  # 按需注入与墙钟上限**归位**：它们只由需要真实网络的用例设置，而变量活在用例文件的作用域里
  # ——不复位的话，后来每条用例都会带着上一条（端到端那条）留下的注入跑：值指向它自己工作
  # 目录里并不存在的 curl / ld / su，墙钟上限也跟着变成 300 秒。默认必须是「什么都没有」。
  POLL_LD_DIR=''
  POLL_CURL_BIN=''
  POLL_SU_MODE=''
  POLL_TIMEOUT=''
  POLL_WORK="$T_WORK_ROOT/poll-$name"
  rm -rf "$POLL_WORK"
  t_stage_module "$POLL_WORK/mod" >/dev/null
  mkdir -p "$POLL_WORK/ctl"
  t_bb_wrap "$POLL_WORK/bin/bb" >/dev/null
  : > "$POLL_WORK/ctl/once"
  : > "$POLL_WORK/ctl/sleeps"
  printf '1\n' > "$POLL_WORK/ctl/rc"
  poll_inject
}

# 主循环的两个观察点接在副本的 commands 层尾部（最后一层，覆盖 signin 层的定义）：
#   run_once —— 记下「被调用的时刻」；返回码由 ctl/rc 逐行给出，用完后沿用最后一行
#   sleep    —— 记下参数，按 ctl/plan 的下一行拨钟；计划走完就把服务置为停用
# 拨钟由 sleep 替身驱动，于是「范围内每分钟看一次」与「异常档跳到 4 分钟后」
# 都落在同一条时间线上，断言读到的时刻就是主循环当时看到的时刻。
poll_inject() {
  cat >> "$POLL_WORK/mod/lib/commands.sh" <<'INJECT'

# ---- 断言注入（只存在于断言的副本里）：主循环的观察面 ----
POLL_CALL=0
POLL_SLEEP=0
run_once() {
  printf '%s\n' "$(now_hm)" >> ./ctl/once
  POLL_CALL=$((POLL_CALL + 1))
  _POLL_RC=$(sed -n "${POLL_CALL}p" ./ctl/rc 2>/dev/null)
  [ -n "$_POLL_RC" ] || _POLL_RC=$(sed -n '$p' ./ctl/rc 2>/dev/null)
  # rc=0 = 当日已解决：真实那条链路会在这一档写下签到记录（signin 层的 sign_set），
  # 于是后一轮的当日状态判定为真、不再查看任务。替身照做，跨轮那条耦合才验得到。
  [ "$_POLL_RC" = "0" ] && sign_set "$(today)" "$(now_hm)" normal
  return "${_POLL_RC:-1}"
}
sleep() {
  printf '%s\n' "${1:-}" >> ./ctl/sleeps
  POLL_SLEEP=$((POLL_SLEEP + 1))
  # 轮数保险：计划没被读到（或注入只生效了一半）时最多转这么多轮就收工，
  # 否则真实的一分钟一 sleep 会让这条断言一直转下去。
  if [ "$POLL_SLEEP" -gt 30 ]; then
    printf 'disabled\n' > ./mod/fafu-checkin.state
    return 0
  fi
  _POLL_T=$(sed -n "$((POLL_SLEEP + 1))p" ./ctl/plan 2>/dev/null)
  if [ -n "$_POLL_T" ]; then
    printf '%s %s\n' "$(today)" "$_POLL_T" > ./ctl/date
  else
    printf 'disabled\n' > ./mod/fafu-checkin.state
  fi
  return 0
}
INJECT
}

# 兜底提醒的调用点观察面：只记「哪一刻被调到了」。判定（目标时刻、当日一次、
# 当日已取得任务就不发）在 tests/notify.sh 里用 nt_send 缝断言，这里不重复。
poll_inject_notask() {
  : > "$POLL_WORK/ctl/notask"
  cat >> "$POLL_WORK/mod/lib/commands.sh" <<'INJECT'

signin_remind_notask() { printf '%s\n' "$1" >> ./ctl/notask; }
INJECT
}

# 生效的配置文件（键=值；未提到的键由配置层取默认值）
poll_config() { printf '%s\n' "$1" > "$POLL_WORK/mod/fafu-checkin.conf"; }

# 计划：每行一个 HH:MM。第 1 行是起始时刻，第 N+1 行是第 N 次 sleep 之后的时刻。
# 计划用完 = 该收工了（sleep 替身把服务置为停用，主循环下一轮开头退出）。
poll_plan() {
  printf '%s\n' "$1" > "$POLL_WORK/ctl/plan"
  printf '%s %s\n' "$POLL_DATE" "$(sed -n 1p "$POLL_WORK/ctl/plan")" > "$POLL_WORK/ctl/date"
}

# run_once 的返回码序列（每行一个；用完后沿用最后一行）
poll_rc() { printf '%s\n' "$1" > "$POLL_WORK/ctl/rc"; }

# 预置当日签到记录（与 sign_set 写出的形状一致）
poll_status() { # $1=日期 $2=类型
  printf 'sign_date=%s\nsign_time=\nsign_kind=%s\n' "$1" "$2" > "$POLL_WORK/mod/fafu_checkin.status"
}

# 跑入口守护进程：FAFU_DAEMON=1 直接进主循环（跳过后台化），跑到计划用尽、服务被置停用为止。
# 外套一层墙钟上限：守护进程是**真的**守护进程，夹具万一没被注入进去，它会一直转下去。
poll_start() {
  local bb
  bb=$(t_find_busybox)
  (
    cd "$POLL_WORK" || exit 1
    export PATH="$POLL_WORK/bin:$PATH" BB_OVERRIDE='./bin/bb' \
      MOCK_DATE_CTL='./ctl/date' MOCK_WGET_DIR='./ctl' MOCK_DEVICE_DIR='./ctl' \
      MOCK_RANDOM_CTL='./ctl/rand' FAFU_DAEMON=1 SU_MODE=''
    # 三处按需注入（默认空 = 与前面几条用例完全一致）：token 目录、网络工具、降权写法。
    # 端到端那条用例要真实 run_once / keepalive_ping / notify，故只有它会给出这三样。
    LD_DIR="${POLL_LD_DIR:-}" CURL_BIN="${POLL_CURL_BIN:-}" FAFU_SU_MODE="${POLL_SU_MODE:-}"
    export LD_DIR CURL_BIN FAFU_SU_MODE
    if [ -n "$bb" ]; then
      "$bb" timeout "${POLL_TIMEOUT:-120}" sh './mod/fafu_checkin.sh'
    else
      sh './mod/fafu_checkin.sh'
    fi
  ) > "$POLL_WORK/entry.out" 2> "$POLL_WORK/entry.err"
  if [ -s "$POLL_WORK/entry.err" ]; then
    echo "  （守护进程的 stderr）"
    sed 's/^/    /' "$POLL_WORK/entry.err"
  fi
}

# 观察面读数：查看任务的次数 / 查看任务的时刻（| 分隔）/ sleep 的参数（| 分隔）
poll_calls() { grep -c . "$POLL_WORK/ctl/once" 2>/dev/null; }
poll_when()  { tr '\n' '|' < "$POLL_WORK/ctl/once"; }
poll_slept() { tr '\n' '|' < "$POLL_WORK/ctl/sleeps"; }

# ============================================================
# 一、轮询范围：范围内才查看任务（拨钟逐时点）
#
# 范围端点用**非默认**的配置值（19:30 / 22:15），并把边界前后各拨一分钟：
# 若实现里还留着默认值或写死的钟点，这条断言会立刻分叉。
# ============================================================

poll_case_window() {
  poll_setup window
  poll_config 'KEEPALIVE=0
POLL_START=19:30
POLL_END=22:15'
  poll_rc '1'
  # 范围起前一分钟 / 范围起 / 范围中 / 范围止 / 范围止后一分钟
  poll_plan '19:29
19:30
20:45
22:15
22:16'
  poll_start

  t_eq "范围内恰好查看三次（范围起 / 范围中 / 范围止）" "$(poll_calls)" "3"
  t_eq "查看任务的时刻正是范围内的三个时点" "$(poll_when)" "19:30|20:45|22:15|"
  t_eq "范围起前一分钟不查看任务" "$(grep -c '^19:29$' "$POLL_WORK/ctl/once")" "0"
  t_eq "范围止后一分钟不查看任务" "$(grep -c '^22:16$' "$POLL_WORK/ctl/once")" "0"
  t_eq "查看任务之间仍是一分钟一轮（每轮末尾照常 sleep 60）" \
    "$(poll_slept)" "60|60|60|60|60|"

  # 对照：范围换回默认值（20:00 / 23:59）后，同一批时点的结论随之改变。
  # 「19:30 与 19:29 都不查看」证明上面那三次查看确实是配置值决定的，
  # 而不是碰巧与默认值一致。
  poll_setup window-default
  poll_config 'KEEPALIVE=0'
  poll_rc '1'
  poll_plan '19:29
19:30
20:45'
  poll_start
  t_eq "对照：默认范围（20:00~23:59）下 19:30 还没到，不查看任务" "$(poll_when)" "20:45|"
}

# ============================================================
# 二、当日已解决即停轮询：四种「办完了」各自都能让当天不再查看任务
#
# 判据落在当日签到记录上（state 层的 signin_resolved_today），故这里预置记录文件。
# 时点都在轮询范围内：只要没停，就一定会看到调用。
# 两个对照（昨天的记录 / 今天有记录但类型为空）用来证明「零调用」既不是范围外造成的，
# 也不是判据恒真造成的。
# ============================================================

# 一个场景跑一遍入口，输出「查看任务的次数」
poll_resolved_case() { # $1=场景名 $2=记录日期 $3=记录类型
  poll_setup "$1"
  poll_config 'KEEPALIVE=0
POLL_START=19:30
POLL_END=22:15'
  poll_rc '1'
  poll_status "$2" "$3"
  poll_plan '19:45
20:30'
  poll_start
  poll_calls
}

poll_case_resolved() {
  local k
  for k in normal supplement detected leave; do
    t_eq "当日已解决（$k）：轮询范围内不再查看任务" \
      "$(poll_resolved_case "resolved-$k" "$POLL_DATE" "$k")" "0"
  done
  t_eq "对照：昨天的记录不算已解决，范围内照常查看任务（两个时点各一次）" \
    "$(poll_resolved_case resolved-stale '2026-09-30' normal)" "2"
  t_eq "对照：今天有记录但类型为空（没办完），范围内照常查看任务（两个时点各一次）" \
    "$(poll_resolved_case resolved-empty "$POLL_DATE" '')" "2"

  # 跨轮：上一轮办完（rc=0，记录随之写下）之后，后一轮不再查看任务——
  # 判定必须是每轮重读状态，而不是启动时算一次就定住。
  poll_setup resolved-after
  poll_config 'KEEPALIVE=0
POLL_START=19:30
POLL_END=22:15'
  poll_rc '0'
  poll_plan '19:45
20:30
20:45'
  poll_start
  t_eq "对照：上一轮办完后，后一轮不再查看任务（判定每轮重读状态）" "$(poll_when)" "19:45|"
}

# ============================================================
# 三、提交失败当日继续重试：rc=1 不写当日完成标记，下一分钟还在范围内就再看一次
#
# 重试一路持续到轮询范围止（22:15 那一刻仍会查看），一出范围就停。
# 同时钉住「失败不写当日完成标记」——写了就等于自己把当天判成办完了。
# ============================================================

poll_case_retry() {
  poll_setup retry
  poll_config 'KEEPALIVE=0
POLL_START=19:30
POLL_END=22:15'
  poll_rc '1'
  poll_plan '19:30
19:31
19:32
22:15
22:16'
  poll_start
  t_eq "提交失败后每次都在重试，直到范围止（含范围止那一刻）" \
    "$(poll_when)" "19:30|19:31|19:32|22:15|"
  t_eq "失败不写当日完成标记（写了自己就把当天判成办完了）" \
    "$([ -f "$POLL_WORK/mod/.fafu_checkin_done" ] && echo yes || echo no)" "no"
}

# ============================================================
# 四、任务异常档：rc=2 排到 4 分钟后，而不是常规的一分钟
#
# 走的是与失败档不同的那条分支，故单独一条用例：休眠参数与下一轮的时点一起看。
# ============================================================

poll_case_task_error() {
  poll_setup taskerr
  poll_config 'KEEPALIVE=0
POLL_START=19:30
POLL_END=22:15'
  poll_rc '2
1'
  poll_plan '19:30
19:34
19:35'
  poll_start
  t_eq "任务异常档：重试排在 4 分钟后（240），后续回到常规的一分钟（60）" \
    "$(poll_slept)" "240|60|60|"
  t_eq "任务异常档：4 分钟后照常查看任务，并继续往后走" \
    "$(poll_when)" "19:30|19:34|19:35|"
}

# ============================================================
# 五、静态：轮询范围与停轮询判据都来自配置层 / 状态层，写死的钟点已不在入口
#
# 主循环的两条返回码分支（0 → 写当日完成标记、2 → 四分钟后重试）由 tests/signin.sh
# 逐字钉住；这里只补「范围与判据都不再写死」这一面。
# ============================================================

poll_case_static() {
  local src
  src="$T_ROOT/fafu_checkin.sh"
  t_has "入口从配置层取轮询起点" "$src" 'cfg_poll_start'
  t_has "入口从配置层取轮询止点" "$src" 'cfg_poll_end'
  t_has "入口按当日是否已解决分流" "$src" 'signin_resolved_today'
  t_before "先判当日是否已解决，再决定要不要查看任务" "$src" \
    'signin_resolved_today' 'run_once'

  # 签到时段与三档未签提醒的写死钟点（当日第几分钟）都不该再出现在入口里
  t_hasnt "入口不再写死主窗口起点（21:30 = 1290）" "$src" '1290'
  t_hasnt "入口不再写死主窗口末 / 提醒第二档（22:30 = 1350）" "$src" '1350'
  t_hasnt "入口不再写死补签时段末（22:59 = 1379）" "$src" '1379'
  t_hasnt "入口不再写死提醒第一档（22:00 = 1320）" "$src" '1320'
  t_hasnt "入口不再写死提醒第三档（23:00 = 1380）" "$src" '1380'

  # 「任务未发布」兜底提醒：它挂本地时钟，但不新开一条不看时间的旁路，
  # 调用点就落在轮询范围内那一支里（行为面由下一节拨钟钉住）。
  t_has "入口在轮询范围内调兜底提醒" "$src" 'signin_remind_notask'
  t_before "兜底提醒排在查看任务之后（同一支，不是并列旁路）" "$src" \
    'run_once; rc=$?' 'signin_remind_notask'
}

# ============================================================
# 七、「任务未发布」兜底提醒的调用点：只在轮询范围内被调到
#
# 判定本身（目标时刻、当日一次、已取得任务就不发）由 tests/notify.sh 用 nt_send 缝断言；
# 这里只看主循环有没有在对的时刻把它调到——调用点没了，那条兜底在设备上根本不会发生。
# 范围端点前后各拨一分钟：范围外那一刻不调，正是「它没有脱离轮询分支」的证据。
# ============================================================

poll_case_notask_site() {
  poll_setup notask-site
  poll_config 'KEEPALIVE=0
POLL_START=19:30
POLL_END=22:15'
  poll_rc '1'
  poll_plan '19:29
19:30
22:15
22:16'
  poll_inject_notask
  poll_start
  t_eq "兜底提醒只在轮询范围内被调到（范围起点与止点各一次）" \
    "$(tr '\n' '|' < "$POLL_WORK/ctl/notask")" "19:30|22:15|"
  t_eq "范围外那两刻一次都没调到" \
    "$(grep -c '^19:29$\|^22:16$' "$POLL_WORK/ctl/notask")" "0"

  # 当日已解决：整支都不进，兜底提醒自然也不该被调到
  poll_setup notask-resolved
  poll_config 'KEEPALIVE=0
POLL_START=19:30
POLL_END=22:15'
  poll_rc '1'
  poll_status "$POLL_DATE" normal
  poll_plan '19:30
19:31'
  poll_inject_notask
  poll_start
  t_eq "当日已解决：兜底提醒一次都不调" \
    "$(grep -c . "$POLL_WORK/ctl/notask" 2>/dev/null)" "0"

  # 任务异常档（rc=2，即「取不到任务」）恰恰是最该喊这条兜底的情形：
  # 主循环因此不能在这一档上就地跳过本轮剩下的动作，只能把休眠时长放宽到 4 分钟。
  poll_setup notask-taskerr
  poll_config 'KEEPALIVE=0
POLL_START=19:30
POLL_END=22:15'
  poll_rc '2'
  poll_plan '22:15
22:19'
  poll_inject_notask
  poll_start
  t_eq "任务异常档：到了兜底时刻仍然把它调到（这一档不能跳过它）" \
    "$(tr '\n' '|' < "$POLL_WORK/ctl/notask")" "22:15|"
  t_eq "任务异常档：下一轮仍排在 4 分钟后" "$(poll_slept)" "240|60|"
}

# ============================================================
# 六、当日已解决只停「查看任务」，不停保活
#
# 两件事互不影响：签到办完了照样要继续刷新登录状态（token 是滑动过期）。
# 观察面：把 keepalive_ping 也换成记录桩，再看「范围内已解决」的那几轮里
# 保活有没有真的发生——只看 run_once 的断言抓不到这条。
# 保活时段取 00:00~23:59，于是拨钟的时点全部落在窗口内。
# ============================================================

poll_case_keepalive_on_resolved() {
  poll_setup keepalive-on-resolved
  poll_config 'KEEPALIVE=1
KA_START=00:00
KA_END=23:59
POLL_START=19:30
POLL_END=22:15'
  poll_status "$POLL_DATE" normal
  poll_plan '19:30
19:31
19:32
19:33'
  cat >> "$POLL_WORK/mod/lib/commands.sh" <<'INJECT'

# ka_due 让位给固定结论：真实那条按 15 分钟节流判，而这里的拨钟是分钟级、
# 且 KA_LAST 在进程里不跨轮推进，会把「到了保活分支」和「节流挡住」混成同一个读数。
ka_due() { return 0; }
keepalive_ping() { printf 'ping\n' >> ./ctl/ka; }
INJECT
  : > "$POLL_WORK/ctl/ka"
  poll_start
  t_eq "当日已解决：范围内一次都不查看任务" "$(poll_calls)" "0"
  t_ne "当日已解决：保活照常发生（签到办完不等于不用续期）" \
    "$(grep -c . "$POLL_WORK/ctl/ka" 2>/dev/null)" "0"
  t_eq "当日已解决：主循环仍在按一分钟一轮走" "$(poll_slept)" "60|60|60|60|"
}

# ============================================================
# 八、端到端回归：六类排障日志在真实调用次序下都出现
#
# 这一条跑的是**真实入口的守护主循环**：run_once / signin_fetch / signin_decide /
# signin_submit / keepalive_ping / notify 全是真实实现，只顶掉五类环境事实——
# 时间（拨钟文件 + 把 %s 对齐到同一份的 _now）、休眠（替身按计划拨钟并切换降权档）、
# 网络（真实 api 层 + 按调用序号喂事实的 curl 替身）、降权发送（替身 su）、
# 刷新流程（替身 refresh_token：它的三段时序由 tests/keepalive.sh 用真实实现覆盖，
# 而签到链路上每次查询异常都会触发它，真实采样要读几十遍 token 目录）。
# 一天只有一次现场，故这条时间线刻意把六类日志串在一起：
#   连接层查询失败 → 提交失败（两轮都失败，当日只通知一次）→ 提交成功 →
#   跨日检测到已签到 → 保活失败（网络类 / 登录态各一次）。
# 断言只读日志正文与状态文件产物，不断言行号，也不复制源码片段。
# ============================================================

POLL_E2E_D1='2026-10-01'
POLL_E2E_D2='2026-10-02'
POLL_E2E_E1=0        # 日 1 零点毫秒（夹具时间戳都相对它）
POLL_E2E_E2=0        # 日 2 零点毫秒（跨日那一轮用）
# 连接层失败的原始报错：curl 在真机上的原话，err= 段逐字取自它
POLL_E2E_CONN='curl: (7) Failed to connect to stuhtapi.fafu.edu.cn port 80: Connection refused'
# 响应头夹具：白名单四项齐全，落成的字面顺序就是 api 层固定的那一个
POLL_E2E_HDR='Date: Mon, 13 Oct 2025 21:30:00 GMT
Content-Length: 53
Content-Type: application/json;charset=UTF-8
Server: nginx'
# 同一份响应头在日志行里该落成的字面（`hdr={…}` 那一段，逐字比对用）
POLL_E2E_HDR_LINE='hdr={Date: Mon, 13 Oct 2025 21:30:00 GMT|Content-Length: 53|Content-Type: application/json;charset=UTF-8|Server: nginx}'
# 服务端拒绝这一次提交的正文（带 timestamp 即「调用成功但正文报错」那一档）
POLL_E2E_REJECT='{"timestamp":1759500000000,"status":500,"msg":"busy"}'

poll_e2e_epoch() { # 两天的零点毫秒（真实 busybox 取，期望值因此不依赖跑断言的机器时区）
  local bb d
  bb=$(t_find_busybox)
  [ -n "$bb" ] || bb="busybox"
  d=$("$bb" date -d "$POLL_E2E_D1 00:00:00" +%s 2>/dev/null | tr -dc '0-9')
  POLL_E2E_E1=$(( ${d:-0} * 1000 ))
  d=$("$bb" date -d "$POLL_E2E_D2 00:00:00" +%s 2>/dev/null | tr -dc '0-9')
  POLL_E2E_E2=$(( ${d:-0} * 1000 ))
}

# 任务响应体：$1=signState $2=开始（当日第几分钟）$3=补签截止（同）$4=零点毫秒 $5=signTime（分钟，可空）
poll_e2e_task() {
  local st b d base extra
  st="$1"; b="$2"; d="$3"; base="${4:-$POLL_E2E_E1}"
  extra=""
  [ -n "${5:-}" ] && extra=",\"signTime\":$(( base + $5 * 60000 ))"
  printf '{"records":[{"id":88123,"name":"晚查寝签到","beginTime":%s,"supplementEndTime":%s,"endTime":%s,"signInStudent":{"signState":%s},"lng":119.243462,"lat":26.088417%s}]}\n' \
    "$(( base + b * 60000 ))" "$(( base + d * 60000 ))" "$(( base + (b + 60) * 60000 ))" "$st" "$extra"
}

# 第 $1 次网络调用的事实：$2=工具退出码 $3=状态码（空=这一档拿不到）$4=正文 $5=报错 $6=响应头
poll_e2e_fact() {
  local d
  d="$POLL_WORK/ctl/facts/$1"
  mkdir -p "$d"
  printf '%s\n' "$2" > "$d/rc"
  printf '%s\n' "$3" > "$d/code"
  printf '%s' "$4" > "$d/body"
  printf '%s' "$5" > "$d/stderr"
  printf '%s' "$6" > "$d/hdr"
}

# 每天一行（`日期 时刻 降权档`）：第 1 行是启动时刻，第 N+1 行是第 N 轮末尾拨到的时刻。
# 降权档按轮切换，是为了让「当日一次」那条通知先成功一次（成功才落标记）。
poll_e2e_rounds() {
  printf '%s\n' \
    "$POLL_E2E_D1 19:30 fail" \
    "$POLL_E2E_D1 19:34 ok" \
    "$POLL_E2E_D1 19:35 fail" \
    "$POLL_E2E_D1 19:36 fail" \
    "$POLL_E2E_D1 19:37 fail" \
    "$POLL_E2E_D1 19:51 fail" \
    "$POLL_E2E_D2 19:30 fail" \
    "$POLL_E2E_D2 19:31 fail" > "$POLL_WORK/ctl/rounds"
  printf '%s 19:30\n' "$POLL_E2E_D1" > "$POLL_WORK/ctl/date"
  printf 'fail\n' > "$POLL_WORK/ctl/su.mode"
}

poll_e2e_setup() {
  local task0 task1
  POLL_WORK="$T_WORK_ROOT/poll-e2e-logs"
  rm -rf "$POLL_WORK"
  t_stage_module "$POLL_WORK/mod" >/dev/null
  mkdir -p "$POLL_WORK/ctl" "$POLL_WORK/bin" "$POLL_WORK/ld"
  t_bb_wrap "$POLL_WORK/bin/bb" >/dev/null
  : > "$POLL_WORK/ctl/sleeps"
  : > "$POLL_WORK/ctl/su.calls"
  : > "$POLL_WORK/ctl/refresh"
  : > "$POLL_WORK/ctl/calls"
  : > "$POLL_WORK/ctl/activity.txt"
  printf 'mWakefulness=Awake\n' > "$POLL_WORK/ctl/power.txt"   # 屏幕亮着：保活失败档走「延后」
  printf '0\n' > "$POLL_WORK/ctl/rc"                            # 设备命令的退出码
  printf '1\n' > "$POLL_WORK/ctl/rand"                          # 签名随机数的替身序号
  # token 来源：真实 get_token 读它（应用未安装在本机，故给一份最小的本地存储）
  printf 'j\000"token":"2_C0DE"\000j' > "$POLL_WORK/ld/000001.ldb"
  poll_e2e_epoch
  # poll_start 的三处按需注入：真实 run_once 要读 token 目录，网络与通知也要真的跑起来。
  # 这四个变量只有本条用例设置（poll_setup 会把它们复位，别的用例因此拿到的仍是空默认）
  POLL_LD_DIR='./ld'
  POLL_CURL_BIN='./bin/curl'
  POLL_SU_MODE='./bin/su - shell -c'
  POLL_TIMEOUT=300     # 这条用例要走八轮、十几次网络调用，120 秒的墙钟上限不够
  # 保活时段覆盖全天（拨钟跨度大），轮询范围覆盖两天的拨钟时点
  poll_config 'KEEPALIVE=1
KA_START=00:00
KA_END=23:59
POLL_START=19:00
POLL_END=22:15'
  # 网络事实按调用序号给：真替身负责「curl 怎么回」，分发器只决定这一次拿哪一份
  task0=$(poll_e2e_task 0 1160 1260 "$POLL_E2E_E1")
  task1=$(poll_e2e_task 1 1160 1260 "$POLL_E2E_E2" 1140)
  poll_e2e_fact 1 7 "" "" "$POLL_E2E_CONN" ""        # 查询失败（连接层）
  poll_e2e_fact 2 7 "" "" "$POLL_E2E_CONN" ""        # 刷新后重试仍失败
  poll_e2e_fact 3 7 "" "" "$POLL_E2E_CONN" ""        # 保活：网络类失败
  poll_e2e_fact 4 0 200 "$task0" "" "$POLL_E2E_HDR"  # 查询成功（窗口内未签）
  poll_e2e_fact 5 0 400 "$POLL_E2E_REJECT" "" "$POLL_E2E_HDR"   # 提交被拒
  poll_e2e_fact 6 0 400 "$POLL_E2E_REJECT" "" "$POLL_E2E_HDR"
  poll_e2e_fact 7 0 400 "$POLL_E2E_REJECT" "" "$POLL_E2E_HDR"
  poll_e2e_fact 8 0 400 "$POLL_E2E_REJECT" "" "$POLL_E2E_HDR"
  poll_e2e_fact 9 0 200 "$task0" "" "$POLL_E2E_HDR"  # 第二轮查询：任务没变，不该再记变化行
  poll_e2e_fact 10 0 400 "$POLL_E2E_REJECT" "" "$POLL_E2E_HDR"
  poll_e2e_fact 11 0 400 "$POLL_E2E_REJECT" "" "$POLL_E2E_HDR"
  poll_e2e_fact 12 0 400 "$POLL_E2E_REJECT" "" "$POLL_E2E_HDR"
  poll_e2e_fact 13 0 400 "$POLL_E2E_REJECT" "" "$POLL_E2E_HDR"
  poll_e2e_fact 14 0 200 "$task0" "" "$POLL_E2E_HDR"                      # 第三轮查询
  poll_e2e_fact 15 0 200 '{"code":0,"msg":"success"}' "" "$POLL_E2E_HDR"  # 提交成功
  poll_e2e_fact 16 0 200 '{"code":1,"message":"not login"}' "" "$POLL_E2E_HDR"  # 保活：登录态失效
  poll_e2e_fact 17 0 200 "$task1" "" "$POLL_E2E_HDR"                      # 跨日：服务端说已签到
  poll_e2e_fact 18 0 200 '{"records":[]}' "" "$POLL_E2E_HDR"              # 跨日保活：成功
  printf '0' > "$POLL_WORK/ctl/curl.n"
  poll_e2e_rounds
  poll_e2e_tools
  poll_e2e_inject
}

# 两个替身文件（都用带引号的 heredoc：内容不在写入时展开，全部留给运行时）：
#   bin/curl —— 分发器：按调用序号把 ctl/facts/<N>/ 的事实搬进真替身的控制文件再转交
#   bin/su   —— 降权替身：按 ctl/su.mode 决定这一次发得出去还是失败，并把命令串记下来
# 诊断行本身不在这两个替身里拼：格式仍是 api 层 _api_note 那一处写的。
poll_e2e_tools() {
  t_curl_stub "$POLL_WORK/bin/curl.real" "$POLL_WORK/ctl" >/dev/null
  cat > "$POLL_WORK/bin/curl" <<'E2E_CURL'
#!/bin/sh
# 由 tests/poll.sh 的 poll_e2e_tools 生成：按调用序号喂事实的 curl 分发器
for _a in "$@"; do
  [ "$_a" = "--version" ] && { echo "curl 8.0.0"; exit 0; }
done
_n=$(cat ctl/curl.n 2>/dev/null | tr -dc '0-9'); _n=$(( ${_n:-0} + 1 ))
printf '%s' "$_n" > ctl/curl.n
_d="ctl/facts/$_n"
[ -d "$_d" ] || _d=$(cat ctl/facts.last 2>/dev/null)
[ -n "$_d" ] && printf '%s' "$_d" > ctl/facts.last
for _k in code body hdr stderr rc; do
  [ -f "$_d/$_k" ] && cat "$_d/$_k" > "ctl/curl_$_k"
done
exec ./bin/curl.real "$@"
E2E_CURL
  cat > "$POLL_WORK/bin/su" <<'E2E_SU'
#!/bin/sh
# 由 tests/poll.sh 的 poll_e2e_tools 生成：降权替身（按 ctl/su.mode 决定成败）
printf '%s\n' "$*" >> ctl/su.calls
[ "$(cat ctl/su.mode 2>/dev/null)" = "ok" ] && exit 0
echo 'su: permission denied' >&2
exit 1
E2E_SU
  chmod +x "$POLL_WORK/bin/curl" "$POLL_WORK/bin/su" "$POLL_WORK/bin/curl.real" 2>/dev/null
}

poll_e2e_inject() {
  cat >> "$POLL_WORK/mod/lib/commands.sh" <<INJECT

# ---- 断言注入（只存在于断言的副本里）：真实主循环的时间与休眠替身 ----
E2E_ROUND=0
# 时间：%s 与拨钟文件对齐（只拨墙钟的话，窗口判定与快照仍读真实时间，时间线会分叉）
_now() {
  local _d _base
  case "\$1" in
    +%s)
      _d=\$(cat ctl/date 2>/dev/null)
      case "\${_d%% *}" in
        $POLL_E2E_D2) _base=$POLL_E2E_E2 ;;
        *)            _base=$POLL_E2E_E1 ;;
      esac
      printf '%s' "\$(( _base / 1000 + \$(hm_minutes "\${_d#* }") * 60 ))"
      ;;
    *) "\$BB" date "\$@" ;;
  esac
}
# 休眠：只把主循环那一跳（60 / 240 秒）当作一轮并拨钟；采样（3 秒）与提交短重试（15 秒）
# 属于轮内等待，拨钟会把时间线搅乱，故直接返回。
sleep() {
  case "\${1:-}" in 60|240) ;; *) return 0 ;; esac
  printf '%s\n' "\${1:-}" >> ctl/sleeps
  E2E_ROUND=\$((E2E_ROUND + 1))
  _r=\$(sed -n "\$((E2E_ROUND + 1))p" ctl/rounds 2>/dev/null)
  if [ -z "\$_r" ]; then printf 'disabled\n' > mod/fafu-checkin.state; return 0; fi
  set -- \$_r
  printf '%s %s\n' "\$1" "\$2" > ctl/date
  printf '%s\n' "\$3" > ctl/su.mode
  return 0
}
# 刷新流程：它的时序（三段、提前关页）由 keepalive 套件用真实实现覆盖；在签到链路上
# 它每次查询异常都会触发，而真实的采样循环要读几十遍 token 目录——那条路径与本票的
# 六类日志无关，留着只会让这条用例撞上墙钟上限。替身只记「发生过刷新」、不产出新 token。
refresh_token() { printf 'refresh\n' >> ctl/refresh; printf '%s' "\${E2E_NEWTOKEN:-}"; }
INJECT
}

# 日志正文（去掉行首时间戳）整份落盘，输出路径：行数类断言与逐字比对都读它
poll_e2e_log() {
  sed 's/^\[[^]]*\][ ]*//' "$POLL_WORK/mod/fafu_checkin.log" 2>/dev/null > "$POLL_WORK/log.txt"
  printf '%s' "$POLL_WORK/log.txt"
}

poll_case_e2e_logs() {
  local log bt1 dl1 bt2 dl2
  poll_e2e_setup
  poll_start

  # 防空转：主循环真的按计划跑完八轮，否则下面所有「日志里有某行」都可能只是没跑
  t_eq "主循环按计划走完八轮（每轮末尾一次休眠；首轮是任务异常档的 4 分钟）" \
    "$(poll_slept)" "240|60|60|60|60|60|60|60|"
  log=$(poll_e2e_log)
  t_file "日志非空" "$log"

  bt1=$(( POLL_E2E_E1 + 1160 * 60000 )); dl1=$(( POLL_E2E_E1 + 1260 * 60000 ))
  bt2=$(( POLL_E2E_E2 + 1160 * 60000 )); dl2=$(( POLL_E2E_E2 + 1260 * 60000 ))

  # ---- ② 查询失败行：连接层的退出码与原始报错 + 查询参数（两个失败点各一行）----
  t_has "查询失败：连接层退出码与工具原话进日志" "$log" \
    "查询异常: rc=7 net rc=7 http=- err=$POLL_E2E_CONN 耗时="
  t_has "查询失败：查询参数一起留下（分得清发出去的是什么）" "$log" \
    "params=rows=3&pageNum=1"
  t_has "刷新登录态后仍失败：第二个失败点也有自己的一行" "$log" \
    "获取任务失败: rc=7 net rc=7 http=- err=$POLL_E2E_CONN 耗时="

  # ---- ③ 任务变化行：首次拿到任务记一行；下一轮同样内容不记；跨日按日滚动重新算「新任务」----
  t_has "任务变化：第一次拿到任务记一行（四元组旧值为空）" "$log" \
    "任务变化: id=→88123 state=→0 begin=→$bt1 截止=→$dl1"
  # 这一行末尾并排服务端的响应头：任务是何时出现的，与服务端认为现在几点（Date）同处一行
  t_has "任务变化：与服务端响应头并排（Date 供时间对齐）" "$log" \
    "任务变化: id=→88123 state=→0 begin=→$bt1 截止=→$dl1 $POLL_E2E_HDR_LINE"
  t_has "任务变化：跨日后再拿到（按日滚动，旧值仍为空）且状态已是已签到" "$log" \
    "任务变化: id=→88123 state=→1 begin=→$bt2 截止=→$dl2"
  t_eq "任务变化只记两行（第二轮任务没变就不记，正常轮询不啰嗦）" \
    "$(LC_ALL=C grep -acF -e '任务变化' "$log")" "2"

  # ---- ① 提交尝试行：每次调用一行，成功与失败同一字段集 ----
  t_has "提交尝试（被拒）：发出去的任务号与坐标 + 状态码 + 完整正文 + 响应头四项 + 耗时" "$log" \
    "提交尝试: try=1 rid=88123 lng=119.243462 lat=26.088417 http=400 body=$POLL_E2E_REJECT hdr={Date: Mon, 13 Oct 2025 21:30:00 GMT|Content-Length: 53|Content-Type: application/json;charset=UTF-8|Server: nginx} 耗时="
  t_has "提交尝试（成功）：同一字段集，只差状态码与正文" "$log" \
    "提交尝试: try=1 rid=88123 lng=119.243462 lat=26.088417 http=200 body={\"code\":0,\"msg\":\"success\"} hdr={Date: Mon, 13 Oct 2025 21:30:00 GMT|Content-Length: 53|Content-Type: application/json;charset=UTF-8|Server: nginx} 耗时="
  t_has_re "提交尝试行以耗时读数结尾（值自带单位）" "$log" \
    'lat=26\.088417 (http=400|http=200) .*耗时=[0-9]+(ms|s)$'
  t_eq "每次提交调用各一行（9 次提交 + 两轮失败汇总，行数按真实调用数走）" \
    "$(LC_ALL=C grep -acF -e 'rid=88123 lng=119.243462' "$log")" "11"
  t_has "全部尝试都失败时另有一行汇总（试了几次 + 服务端原文）" "$log" \
    "签到失败: rc=1 rid=88123 lng=119.243462 lat=26.088417 try=4 tries=2 http=400 body=$POLL_E2E_REJECT"

  # ---- ④ 已签到记录行：服务端那条记录整条落盘，并排四种时间、两处环境与响应头 ----
  t_has "检测到已签到：整条服务端记录落进日志（含签到时刻）" "$log" \
    "记录={\"records\":[{\"id\":88123,"
  t_has "检测到已签到：签到时刻与本地此刻、时区、库路径并排" "$log" \
    "signTime=[$(( POLL_E2E_E2 + 1140 * 60000 ))]"
  t_has "检测到已签到：本地此刻就是拨钟到的那一刻（跨日的第二天）" "$log" \
    "now=[$POLL_E2E_D2 19:30:00] TZ=["
  # 服务端认为现在几点也要在同一行：本地 now= 与响应头 Date 并排，「偏差归谁」才不必推理
  t_has_re "检测到已签到：核对行末尾并排响应头（Date 供对齐）" "$log" \
    '^时间核对: signTime=\[.*\] → sign_time=\[.*\] now=\[.*\] TZ=\[.*\] LDP=\[.*\] alt=\[.*\] 记录=\{.*\} hdr=\{Date: Mon, 13 Oct 2025 21:30:00 GMT.*\}$'

  # ---- ⑤ 保活失败行：网络类与登录态失效各一行，一眼分得开 ----
  t_has "保活失败（网络类）：rc 与连接层原话 + 屏幕状态 + 所采取的动作" "$log" \
    "保活: ❌ 2_C0DE 调用失败 rc=7 screen=on net rc=7 http=- err=$POLL_E2E_CONN 耗时="
  t_has "保活失败（登录态）：rc=0 + 服务端状态码与正文（与上一行不同档）" "$log" \
    '保活: ❌ 2_C0DE 调用失败 rc=0 screen=on http=200 body={"code":1,"message":"not login"} hdr={Date: Mon, 13 Oct 2025 21:30:00 GMT|Content-Length: 53|Content-Type: application/json;charset=UTF-8|Server: nginx} 耗时='
  t_eq "两档各占一行，日志里分得清" \
    "$(LC_ALL=C grep -acF -e '调用失败 rc=' "$log")" "2"

  # ---- ⑥ 通知发送失败行：失败才记，且写清是哪个事件发不出去 ----
  t_has "通知发送失败：拿不到任务那条（含失败片段）" "$log" \
    "通知发送失败: event=failtask rc=1 err=su: permission denied"
  t_has "通知发送失败：签到成功那条（发送失败不影响签到主流程）" "$log" \
    "通知发送失败: event=sign rc=1 err=su: permission denied"
  t_has "通知发送失败：检测到已签到那条" "$log" \
    "通知发送失败: event=seen rc=1 err=su: permission denied"

  # ---- 不变式：当日一次通知（两轮都提交失败，只发出一条）----
  t_eq "提交失败两轮：当日只通知一条（成功才落标记，第二轮不再发）" \
    "$(LC_ALL=C grep -acF -e 'fafu-failsign-20261001' "$POLL_WORK/ctl/su.calls")" "1"
  t_eq "当日「失败类通知」标记落在第一天" \
    "$(cat "$POLL_WORK/mod/.fafu_notify_fail" 2>/dev/null)" "$POLL_E2E_D1"

  # ---- 不变式：按日滚动（完成标记 / 任务快照 / 保活统计）----
  t_eq "完成标记跟着最后一天走" \
    "$(cat "$POLL_WORK/mod/.fafu_checkin_done" 2>/dev/null)" "$POLL_E2E_D2"
  t_has "任务快照按日滚动：日期键是最后一天" "$POLL_WORK/mod/.fafu_task_snap" \
    "date=$POLL_E2E_D2"
  t_has "任务快照记下的是跨日那一轮的任务状态" "$POLL_WORK/mod/.fafu_task_snap" \
    "state=1"
  t_has "保活统计按日归零：跨日后的成功行读作 1 成功 / 0 失败" "$log" \
    "保活: ✅ 2_C0DE token 有效 (今日 1 成功 / 0 失败)"
  t_has "保活统计文件的日期键也跟到第二天" "$POLL_WORK/mod/fafu_keepalive.status" \
    "date=$POLL_E2E_D2"
}

# ---- 注册（顺序即执行顺序） ----

t_case "poll · 六类排障日志在真实调用次序下都出现（端到端）" poll_case_e2e_logs
t_case "poll · 轮询范围（拨钟逐时点）" poll_case_window
t_case "poll · 当日已解决即停轮询（四类）" poll_case_resolved
t_case "poll · 提交失败继续重试到范围止" poll_case_retry
t_case "poll · 任务异常四分钟后重试" poll_case_task_error
t_case "poll · 范围来自配置、钟点不再写死（静态）" poll_case_static
t_case "poll · 当日已解决只停查看任务、不停保活" poll_case_keepalive_on_resolved
t_case "poll · 兜底提醒的调用点只在轮询范围内" poll_case_notask_site
