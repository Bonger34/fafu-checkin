#!/bin/sh
# ============================================================
# 守护进程脱离管理器 cgroup / 会话（#30）
#
# 事故：从配置页保存触发的重启由管理器的 WebUI shell 派生，守护进程继承的是管理器 App 的
# cgroup；页面 / 管理器一关，Android 会把整个 cgroup 一起回收，进程被 SIGKILL——日志里
# 连「守护进程已停止」都不会有。开机脚本 service.sh 由 init 拉起，不在 App 的 cgroup 里，
# 所以过去几个月一直好用。
#
# 观察面（不需要手机）：
#   1) cgroup：FAFU_CGROUP_ROOTS / FAFU_CGROUP_SELF 两个注入点指向夹具里的假树；
#      真实守护进程必须把自己的 PID 写进各层的 cgroup.procs。
#   2) 会话：真实入口 start 派生出的守护进程必须不在启动它的 shell 的会话里；
#      只有本机 ps 支持 `-o sid` 时才跑（Linux / CI），Windows 上跳过。
# ============================================================

DT_WORK="$T_WORK_ROOT/detach"

# 假 cgroup 树：v2 根 + 三条旁路，与 base 层的默认清单一一对应（顺序不重要）
DT_ROOTS='./cg/v2 ./cg/acct ./cg/cg2_bpf ./cg/memcg'

dt_setup() {
  rm -rf "$DT_WORK"
  mkdir -p "$DT_WORK/ctl"
  t_stage_module "$DT_WORK/mod" >/dev/null
  t_bb_wrap "$DT_WORK/bin/bb" >/dev/null
  # 通知关掉：入口的降权探测直接返回，夹具不碰本机的 su；主循环固定在 03:00（不在轮询范围）
  printf 'KEEPALIVE=0\nNOTIFY=0\nDEBUG=1\nPOLL_START=20:00\nPOLL_END=23:59\n' \
    > "$DT_WORK/mod/fafu-checkin.conf"
  printf '2026-10-01 03:00\n' > "$DT_WORK/ctl/date"
  mkdir -p "$DT_WORK/cg/v2" "$DT_WORK/cg/acct" "$DT_WORK/cg/cg2_bpf" "$DT_WORK/cg/memcg"
  : > "$DT_WORK/cg/v2/cgroup.procs"
  : > "$DT_WORK/cg/acct/cgroup.procs"
  : > "$DT_WORK/cg/cg2_bpf/cgroup.procs"
  : > "$DT_WORK/cg/memcg/cgroup.procs"
  # 管理器的 App cgroup：Android 的路径形如 `0::/apps/uid_10234/pid_4242`
  printf '0::/apps/uid_10234/pid_4242\n' > "$DT_WORK/cg/self"
}

# 不真等：测试 shell 里没有可依赖的 sleep，统一借真实 busybox
dt_sleep() { # $1=秒
  local bb
  bb=$(t_find_busybox)
  if [ -n "$bb" ]; then "$bb" sleep "$1"; else sleep "$1"; fi
}

# 断言注入：主循环第一次休眠就把服务置为停用，于是守护进程跑完一轮自行退出——
# 用例不必留下常驻进程，也仍然经过了「启动 → 写 PID / cgroup」这段被测代码。
dt_inject_exit_on_sleep() {
  cat >> "$DT_WORK/mod/lib/commands.sh" <<'INJECT'

sleep() { printf 'disabled\n' > ./mod/fafu-checkin.state; }
INJECT
}

# 让守护进程活久一点（会话断言要在它还活着时读 ps）；用例末尾按 PID 收尾。
dt_inject_long_sleep() {
  cat >> "$DT_WORK/mod/lib/commands.sh" <<'INJECT'

sleep() { "$BB" sleep 10; }
INJECT
}

# 直接跑守护主循环（FAFU_DAEMON=1 跳过 cmd_start）：从配置页启动后真正跑的就是这一段。
dt_run_daemon() {
  (
    cd "$DT_WORK" || exit 1
    PATH="$DT_WORK/bin:$PATH" BB_OVERRIDE='./bin/bb' MOCK_DATE_CTL='./ctl/date' \
      FAFU_DAEMON=1 FAFU_SU_MODE='' \
      FAFU_CGROUP_SELF='./cg/self' FAFU_CGROUP_ROOTS="$DT_ROOTS" \
      $(t_sh) ./mod/fafu_checkin.sh
  ) > "$DT_WORK/daemon.out" 2> "$DT_WORK/daemon.err" &
}

# 走真实启动路径（不设 FAFU_DAEMON）：cmd_start → 换会话派生 → 守护主循环。
dt_start_via_entry() {
  (
    cd "$DT_WORK" || exit 1
    PATH="$DT_WORK/bin:$PATH" BB_OVERRIDE='./bin/bb' MOCK_DATE_CTL='./ctl/date' \
      FAFU_CGROUP_SELF='./cg/self' FAFU_CGROUP_ROOTS="$DT_ROOTS" \
      $(t_sh) ./mod/fafu_checkin.sh start
  ) > "$DT_WORK/start.out" 2> "$DT_WORK/start.err"
}

# 日志里出现某段固定文案（最多等 10 秒）
dt_wait_log() { # $1=字面量
  local i=0
  while [ "$i" -lt 20 ]; do
    grep -qF "$1" "$DT_WORK/mod/fafu_checkin.log" 2>/dev/null && return 0
    dt_sleep 1
    i=$((i+1))
  done
  return 1
}

# 启动行里的 PID（守护进程自己写进 PID 文件的是同一个号）
dt_log_pid() {
  sed -n 's/.*服务启动 (PID \([0-9][0-9]*\)).*/\1/p' "$DT_WORK/mod/fafu_checkin.log" 2>/dev/null | tail -n 1
}

# 等守护进程自行收工：退出行出现、PID 文件被删掉，再留一秒让进程真正走完
# （A 组三个用例都用注入的 sleep 让它自己退出，用例之间不会互相占着工作目录）。
dt_wait_exit() {
  local i=0
  dt_wait_log '检测到服务已停用，守护进程退出' || return 1
  while [ "$i" -lt 10 ]; do
    [ -f "$DT_WORK/mod/.fafu_checkin.pid" ] || { dt_sleep 1; return 0; }
    dt_sleep 1
    i=$((i+1))
  done
  return 1
}

# PID 文件里的号（等它出现；最多 10 秒）
dt_wait_pid() {
  local i=0
  while [ "$i" -lt 20 ]; do
    if [ -s "$DT_WORK/mod/.fafu_checkin.pid" ]; then
      tr -dc '0-9' < "$DT_WORK/mod/.fafu_checkin.pid"
      return 0
    fi
    dt_sleep 1
    i=$((i+1))
  done
  return 1
}

# 假 cgroup 文件里的号（只留数字）
dt_cg() { tr -dc '0-9' < "$DT_WORK/cg/$1/cgroup.procs" 2>/dev/null; }

# 收尾：进程可能已经不在了（A 组会自行退出），杀不到不算失败
dt_kill() { # $1=pid
  [ -n "$1" ] && kill -9 "$1" 2>/dev/null
  return 0
}

# ============================================================
# 一、in app cgroup：守护进程必须把自己迁到各层 cgroup 的根
# ============================================================

dt_case_cgroup() {
  local pid log
  dt_setup
  dt_inject_exit_on_sleep
  dt_run_daemon
  dt_wait_exit
  log="$DT_WORK/mod/fafu_checkin.log"
  pid=$(dt_log_pid)

  t_ne "夹具：守护进程真的起来了（启动行带 PID）" "$pid" ""
  t_eq "cgroup v2 根：PID 写进了 cgroup.procs" "$(dt_cg v2)" "$pid"
  t_eq "cgroup acct 旁路：PID 也写进去了" "$(dt_cg acct)" "$pid"
  t_eq "cgroup cg2_bpf 旁路：PID 也写进去了" "$(dt_cg cg2_bpf)" "$pid"
  t_eq "cgroup memcg 旁路：PID 也写进去了" "$(dt_cg memcg)" "$pid"
  t_has "调试档：写下「已离开管理器 cgroup」" "$log" '已离开管理器 cgroup'
  t_eq "迁移成功时不写「未能离开」" "$(grep -acF -e '未能离开管理器 cgroup' "$log" 2>/dev/null)" "0"
}

# ============================================================
# 二、不在 app cgroup（开机脚本那条路径）：不写任何迁移日志
#
# 守护进程由 init / ksud 拉起时本来就不在 App 的 cgroup 里；这时不该白写一条
# 「未能离开」去吓人，也不该去动别的进程的 cgroup。
# ============================================================

dt_case_no_app_cgroup() {
  local pid log
  dt_setup
  printf '0::/\n' > "$DT_WORK/cg/self"
  dt_inject_exit_on_sleep
  dt_run_daemon
  dt_wait_exit
  log="$DT_WORK/mod/fafu_checkin.log"
  pid=$(dt_log_pid)

  t_ne "夹具：守护进程真的起来了" "$pid" ""
  t_eq "不在 App cgroup 时：一个 cgroup.procs 都不动" \
    "$(dt_cg v2)$(dt_cg acct)$(dt_cg cg2_bpf)$(dt_cg memcg)" ""
  t_eq "不在 App cgroup 时：不写迁移成功行" \
    "$(grep -acF -e '已离开管理器 cgroup' "$log" 2>/dev/null)" "0"
  t_eq "不在 App cgroup 时：也不写失败警告" \
    "$(grep -acF -e '未能离开管理器 cgroup' "$log" 2>/dev/null)" "0"
}

# ============================================================
# 三、迁不出去（cgroup.procs 不可写）：必须留下可读的原因，且守护进程照常跑
#
# 用「同名目录」让 cgroup.procs 不是普通文件：`[ -f ]` 不成立 = 这一层写不了。
# 真实设备上对应的是 SELinux / 只读挂载把写入挡掉。
# ============================================================

dt_case_escape_fails() {
  local pid log
  dt_setup
  rm -f "$DT_WORK/cg/v2/cgroup.procs"
  mkdir -p "$DT_WORK/cg/v2/cgroup.procs"
  dt_inject_exit_on_sleep
  dt_run_daemon
  dt_wait_exit
  log="$DT_WORK/mod/fafu_checkin.log"
  pid=$(dt_log_pid)

  t_ne "夹具：迁不出去时守护进程也照样起来了（失败不得影响主流程）" "$pid" ""
  t_has "迁不出去：日志留下可读的失败原因" "$log" '未能离开管理器 cgroup'
  t_eq "迁不出去：不谎报成功" \
    "$(grep -acF -e '已离开管理器 cgroup' "$log" 2>/dev/null)" "0"
}

# ============================================================
# 四、真实入口 start 派生：守护进程必须换一个会话
#
# 管理器关页面时收的是它自己的进程组；守护进程若还留在那个会话里，会被一起带走。
# `ps -o sid` 只有 Linux / CI 的 ps 支持，Windows 的 busybox ps 没有这个字段——跳过。
# ============================================================

dt_case_session() {
  local pid dsid ssid
  dt_setup
  # 先判工具：两条都具备才有意义（缺少时跳过，而不是假装通过）
  if ! ps -o sid= -p "$$" >/dev/null 2>&1; then
    t_skip "会话断言：本机 ps 不支持 -o sid（Linux / CI 上跑）"
    return 0
  fi
  if ! command -v setsid >/dev/null 2>&1; then
    t_skip "会话断言：本机没有 setsid，入口会走 nohup 回退（Linux / CI 上跑）"
    return 0
  fi
  dt_inject_long_sleep
  dt_start_via_entry
  pid=$(dt_wait_pid)
  t_ne "入口 start：守护进程起来了（PID 文件非空）" "$pid" ""

  dsid=$(ps -o sid= -p "$pid" 2>/dev/null | tr -d ' ')
  ssid=$(ps -o sid= -p "$$" 2>/dev/null | tr -d ' ')
  dt_kill "$pid"
  dt_sleep 1

  t_ne "会话：守护进程的会话号与启动者不同" "$dsid" "$ssid"
  t_eq "会话：守护进程就是新会话的首进程（sid = pid）" "$dsid" "$pid"
}

# ============================================================
# 注册
# ============================================================

t_case "daemon · 从管理器 cgroup 迁出（真守护进程）" dt_case_cgroup
t_case "daemon · 本来就不在 App cgroup 时不乱动" dt_case_no_app_cgroup
t_case "daemon · 迁不出去时留原因且不中断" dt_case_escape_fails
t_case "daemon · 入口 start 换新会话（Linux / CI）" dt_case_session
