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
    if [ -n "$bb" ]; then
      "$bb" timeout 120 sh './mod/fafu_checkin.sh'
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

# ---- 注册（顺序即执行顺序） ----

t_case "poll · 轮询范围（拨钟逐时点）" poll_case_window
t_case "poll · 当日已解决即停轮询（四类）" poll_case_resolved
t_case "poll · 提交失败继续重试到范围止" poll_case_retry
t_case "poll · 任务异常四分钟后重试" poll_case_task_error
t_case "poll · 范围来自配置、钟点不再写死（静态）" poll_case_static
t_case "poll · 当日已解决只停查看任务、不停保活" poll_case_keepalive_on_resolved
