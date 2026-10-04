# ============================================================
# commands 层验收断言：命令表驱动分发、降权探测先于分发、用法文本
#
# 五条口径（都只针对外部可观察的行为）：
#   1) 分发：表里的名字进哪个处理函数、退出码原样出来、不在表里的名字什么都不做；
#   2) 同源：表同时决定「分发到哪」与「探测哪些命令」（把处理函数钉成记录桩即可看出）；
#   3) 顺序：降权探测在任何处理函数之前完成（记录桩按时间顺序落盘，数先后即可）；
#   4) 用法：命令集合与顺序取自表；未知子命令打印用法并以非 0 退出；
#      加一行就是一个可用的子命令（临时改一份模块副本验证，不动仓库文件）。
#   5) 传参：子命令之后的参数原样交给处理函数（入口那一跳与分发那一跳各一条）。
#
# 断言直接加载真实的层文件（tests/harness.sh 的 TEST_LIB_FILES），不抽源码片段、不绑行号。
# ============================================================

CD_WORK="$T_WORK_ROOT/commands"

# 从工作目录回到仓库根的相对路径（含末尾斜杠）：工作目录是 $T_WORK_ROOT/commands，
# 而 $T_WORK_ROOT 就在仓库根的 tests/ 下，故往上两级即仓库根。
# 它是驱动脚本加载层文件的**兜底**：Windows 上 $T_ROOT 形如 D:/.../fafu-checkin，
# Linux 与随附 busybox 下可直接用，但 git-bash 只认 /d/... 形式
# （不兜底时 source 会静默找到别处的同名文件，断言全绿而其实没加载被测代码）。
CD_REL="../../"

# 每个用例自备环境：替身 busybox + 模块目录
cd_setup() {
  rm -rf "$CD_WORK"
  mkdir -p "$CD_WORK/mod"
  t_bb_wrap "$CD_WORK/bin/bb" >/dev/null
}

# 驱动脚本的公共前导：注入替身 busybox 与模块目录 → 加载真实层 → 加不加记录桩。
# $1=stub 时**按真实命令表**把每个处理函数换成记录桩（往 $CD_CALLS 追加一行）：
# 于是「表里写了哪一行」与「实际分派到谁」是同一份数据，断言不必另抄一份命令名单；
# 传别的（或省略）= 不顶替，用真实处理函数（要断言命令自己的输出时用）。
# 桩把收到的参数记在行尾（`args=[...]`，按空白拼成一列）——参数到没到处理函数因此可观察；
# 没收到参数时不记这一列，记录行与不带参数的格式逐字一致。
cd_write_env() {
  cat > "$CD_WORK/_env.sh" <<ENV
PATH='/bin:/usr/bin'
T_ROOT='$T_ROOT'
T_WORK='$CD_WORK'
MODDIR='./mod'
BB_OVERRIDE='./bin/bb'
CD_CALLS='./calls'
CD_RC=0
export MODDIR BB_OVERRIDE CD_CALLS CD_RC
# 层文件按**加载顺序**从仓库根加载。$T_ROOT 在 Windows 上形如 D:/.../fafu-checkin，
# Linux 与随附 busybox 下直接可用；git-bash 只认 /d/... 形式（否则 source 会静默找错文件），
# 故先试一个探针文件，不行再退回「从本工作目录往上数」的相对路径。
if [ -r "\$T_ROOT/lib/base.sh" ]; then CD_ROOT="\$T_ROOT"; else CD_ROOT='$CD_REL'; fi
for _f in $TEST_LIB_FILES; do . "\$CD_ROOT/\$_f"; done
: > "\$CD_CALLS"
probe_su() { printf 'probe %s\n' "\${1:-none}" >> "\$CD_CALLS"; SU_MODE="stub"; }
ENV
  if [ "${1:-stub}" = "stub" ]; then
    cat >> "$CD_WORK/_env.sh" <<'STUBS'
eval "$(cmd_specs | sed -n 's/^\([a-z]*\).*\(cmd_[a-z]*\).*$/\2() { printf \"call %s rc=%s\" \2 \"$CD_RC\" >> \"$CD_CALLS\"; [ $# -gt 0 ] \&\& printf \" args=[%s]\" \"$*\" >> \"$CD_CALLS\"; printf \"\\n\" >> \"$CD_CALLS\"; return \"$CD_RC\"; }/p')"
STUBS
  fi
}

# 跑一个驱动脚本；用法：cd_run <名字>，主体从 stdin 读入（公共前导自动接在前面）
cd_run() {
  local name rc
  name="$1"
  cat > "$CD_WORK/_body.sh"
  cp "$CD_WORK/_env.sh" "$CD_WORK/$name.sh"
  cat "$CD_WORK/_body.sh" >> "$CD_WORK/$name.sh"
  ( cd "$CD_WORK" && $(t_sh) "./$name.sh" ) > "$CD_WORK/$name.out" 2> "$CD_WORK/$name.err"
  rc=$?
  echo "$rc" > "$CD_WORK/$name.rc"
  if [ -s "$CD_WORK/$name.err" ]; then
    echo "  （驱动 $name 的 stderr）"
    sed 's/^/    /' "$CD_WORK/$name.err"
  fi
}

# 跑一个**不带记录桩**的驱动：用真实的处理函数（要断言命令自己的输出时用）
cd_run_real() {
  local name rc
  name="$1"
  cat > "$CD_WORK/_real_body.sh"
  { cat "$CD_WORK/_env.sh"; cat "$CD_WORK/_real_body.sh"; } > "$CD_WORK/$name.sh"
  ( cd "$CD_WORK" && $(t_sh) "./$name.sh" ) > "$CD_WORK/$name.out" 2> "$CD_WORK/$name.err"
  rc=$?
  echo "$rc" > "$CD_WORK/$name.rc"
  if [ -s "$CD_WORK/$name.err" ]; then
    echo "  （驱动 $name 的 stderr）"
    sed 's/^/    /' "$CD_WORK/$name.err"
  fi
}

# 从驱动输出里取一行（形如 key=value）
cd_val() { # $1=文件 $2=键
  sed -n "s/^$2=//p" "$1"
}

# 记录文件里的第几行是什么（1 起；没出现则为空）——「探测先于分发」按行号数先后
cd_line() { # $1=第几行
  sed -n "$1p" "$CD_WORK/calls" 2>/dev/null
}

# ============================================================
# 一、分发：表里的名字进对应的处理函数，退出码原样出来
# ============================================================

cd_case_dispatch() {
  local f
  cd_setup
  cd_write_env
  cd_run dispatch <<'DRIVER'
# 每条子命令单独跑一个子 shell：cmd_dispatch 命中后以 exit 收尾（那正是它的契约），
# 不隔一层的话第一条就把这个驱动脚本整个结束了。
cd_do() { # $1=子命令 → 跑一次分发并把退出码也记进记录文件
  ( cmd_dispatch "$1" )
  printf 'rc %s=%s\n' "$1" "$?" >> "$CD_CALLS"
}
CD_RC=0; export CD_RC
cd_do status
cd_do notify
cd_do stop
CD_RC=7; export CD_RC
cd_do once
DRIVER
  f="$CD_WORK/calls"
  t_has "分发：status 进 cmd_status" "$f" "call cmd_status rc=0"
  t_has "分发：notify 进 cmd_notify" "$f" "call cmd_notify rc=0"
  t_has "分发：stop 进 cmd_stop" "$f" "call cmd_stop rc=0"
  t_has "分发：once 进 cmd_once" "$f" "call cmd_once rc=7"
  t_has "退出码：处理函数返回 7，子命令也退 7" "$f" "rc once=7"
  t_has "退出码：处理函数返回 0，子命令也退 0" "$f" "rc stop=0"
  t_eq "四条子命令各分派一次（没有多跑、没有漏跑）" "$(grep -c '^call ' "$f")" "4"
}

# 命令自己的输出不被吞掉：分派这一步不接管道、也不套 $( ) 承接，
# 用真实处理函数跑一条最安全的子命令（stop：只读 PID 文件，不碰网络）
cd_case_dispatch_stdout() {
  cd_setup
  cd_write_env real
  cd_run_real stop_stdout <<'DRIVER'
cmd_dispatch stop
DRIVER
  t_has "分派不经 $() 承接：命令的输出直接进 stdout" "$CD_WORK/stop_stdout.out" "服务未在运行"
  t_eq "分派后进程以处理函数的返回码收尾" "$(cat "$CD_WORK/stop_stdout.rc")" "0"

  # 非 0 也要原样传出去（只有**捕获**输出时才容易把返回码丢掉，这里两种都跑一遍）
  cd_run_real stop_rc <<'DRIVER'
cmd_stop() { echo "处理函数说了话"; return 5; }
cmd_dispatch stop
DRIVER
  t_eq "处理函数返回 5：分派的退出码也是 5" "$(cat "$CD_WORK/stop_rc.rc")" "5"
  t_has "返回非 0 时输出也没被吞掉" "$CD_WORK/stop_rc.out" "处理函数说了话"
}

# 「立刻检查一次」的返回码就是 run_once 的返回码（三档都要原样传出去）
cd_case_once_rc() {
  cd_setup
  cd_write_env real
  cd_run_real once_rc <<'DRIVER'
{
  for _rc in 0 1 2; do
    run_once() { return "$_rc"; }
    ( cmd_once )
    printf 'once_%s=%s\n' "$_rc" "$?"
  done
} > "$T_WORK/once.out"
DRIVER
  t_eq "once：run_once 返回 0 时子命令退 0" "$(cd_val "$CD_WORK/once.out" once_0)" "0"
  t_eq "once：run_once 返回 1 时子命令退 1" "$(cd_val "$CD_WORK/once.out" once_1)" "1"
  t_eq "once：run_once 返回 2 时子命令退 2" "$(cd_val "$CD_WORK/once.out" once_2)" "2"
}

# 不在表里的名字：cmd_dispatch 什么都不做（start 与「不带子命令」由入口接手；
# 未知子命令在入口被 cmd_known 拦下，这里只证明它没被当成谁去执行）
cd_case_unknown() {
  cd_setup
  cd_write_env
  cd_run unknown <<'DRIVER'
{
  ( cmd_dispatch start ) >/dev/null 2>&1; printf 'start_rc=%s\n' "$?"
  ( cmd_dispatch "" ) >/dev/null 2>&1;     printf 'empty_rc=%s\n' "$?"
  ( cmd_dispatch bogus ) >/dev/null 2>&1;  printf 'bogus_rc=%s\n' "$?"
  printf 'calls=%s\n' "$(grep -c '^call' "$CD_CALLS")"
} > "$T_WORK/unknown.out"
DRIVER
  t_eq "start：不由命令表分发，正常返回" "$(cd_val "$CD_WORK/unknown.out" start_rc)" "0"
  t_eq "不带子命令：同上（入口按 start 处理）" "$(cd_val "$CD_WORK/unknown.out" empty_rc)" "0"
  t_eq "未知子命令：不由命令表分发" "$(cd_val "$CD_WORK/unknown.out" bogus_rc)" "0"
  t_eq "这三个都没触发任何处理函数" "$(cd_val "$CD_WORK/unknown.out" calls)" "0"
}

# ============================================================
# 二、一张表驱动三件事
# ============================================================

cd_case_table_single_source() {
  local f
  cd_setup
  cd_write_env
  cd_run table <<'DRIVER'
{
  # 表本身：九行，每行四列（名字 处理函数 探测 说明），说明非空
  printf 'rows=%s\n' "$(cmd_specs | grep -c .)"
  printf 'bad=%s\n'  "$(cmd_specs | awk 'NF != 4 || $4 == "" { n++ } END { print n + 0 }')"
  # 探测集合完全由表决定
  printf 'probed=%s\n' "$(cmd_specs | awk '$3 == 1 { printf "%s ", $1 }')"
  printf 'quiet=%s\n'  "$(cmd_specs | awk '$3 != 1 { printf "%s ", $1 }')"
  # 每行的前三列都必须合法：说明里允许有空格（「查看开关 / 服务 / token 状态」这类）。
  # 写坏一行会让用法文本或探测集合变形，故在这里钉住。
  printf 'cols=%s\n'   "$(cmd_specs | awk '{ if ($1 !~ /^[a-z]+$/ || $2 !~ /^cmd_[a-z_]+$/ || ($3 != 0 && $3 != 1) || $4 == "") bad++ } END { print bad + 0 }')"
} > "$T_WORK/table.out"
DRIVER
  f="$CD_WORK/table.out"
  t_eq "命令表：九行（九个手动排查子命令）" "$(cd_val "$f" rows)" "9"
  t_eq "命令表：每行前三列合法（名字 / cmd_ 处理函数 / 0|1）且说明非空" "$(cd_val "$f" cols)" "0"
  t_eq "需要降权探测的集合取自表" "$(cd_val "$f" probed)" "notify once refresh keepalive "
  t_eq "不需要探测的集合取自表" "$(cd_val "$f" quiet)" "stop status toggle enable disable "

  # 分派用的确实是表里的那一列（表里 keepalive 指向 cmd_keepalive，分派就调它）
  cd_run table_call <<'DRIVER'
{
  printf 'default=%s\n' "$(cmd_specs | awk '$1 == "keepalive" { print $2 }')"
  ( cmd_dispatch keepalive ) >/dev/null 2>&1
  printf 'calls=%s\n' "$(grep -c '^call cmd_keepalive' "$CD_CALLS")"
} > "$T_WORK/table_call.out"
DRIVER
  t_eq "表里 keepalive 的处理函数就是 cmd_keepalive" "$(cd_val "$CD_WORK/table_call.out" default)" "cmd_keepalive"
  t_eq "分派按表里的处理函数走（keepalive → cmd_keepalive）" "$(cd_val "$CD_WORK/table_call.out" calls)" "1"
}

# ============================================================
# 三、顺序：降权探测在任何处理函数之前完成
#
# 每条命令各跑一次、清一次记录，于是「记录的第一行」就是这次调用的第一个动作。
# ============================================================

cd_case_probe_first() {
  cd_setup
  cd_write_env
  cd_run order <<'DRIVER'
one() { # $1=子命令 → 单独跑一次（子 shell：命中即以 exit 收尾），记录这次调用的动作顺序
  : > "$CD_CALLS"
  ( cmd_dispatch "$1" ) >/dev/null 2>&1
  printf '%s: %s | %s\n' "$1" "$(sed -n '1p' "$CD_CALLS")" "$(sed -n '2p' "$CD_CALLS")" \
    >> "$T_WORK/order.txt"
}
for c in notify once refresh keepalive stop status toggle enable disable; do one "$c"; done
DRIVER
  # 需要探测的四条：第一行是探测、第二行才是处理函数
  t_eq "notify：先探测再分发" "$(sed -n 's/^notify: //p'  "$CD_WORK/order.txt")" "probe notify | call cmd_notify rc=0"
  t_eq "once：先探测再分发"   "$(sed -n 's/^once: //p'    "$CD_WORK/order.txt")" "probe once | call cmd_once rc=0"
  t_eq "refresh：先探测再分发" "$(sed -n 's/^refresh: //p' "$CD_WORK/order.txt")" "probe refresh | call cmd_refresh rc=0"
  t_eq "keepalive：先探测再分发" "$(sed -n 's/^keepalive: //p' "$CD_WORK/order.txt")" "probe keepalive | call cmd_keepalive rc=0"
  # 不需要探测的五条：第一个动作就是处理函数（没有多余的探测）
  t_eq "stop：不探测，直接分发"      "$(sed -n 's/^stop: //p'    "$CD_WORK/order.txt")" "call cmd_stop rc=0 | "
  t_eq "status：不探测，直接分发"    "$(sed -n 's/^status: //p'  "$CD_WORK/order.txt")" "call cmd_status rc=0 | "
  t_eq "toggle：不探测，直接分发"    "$(sed -n 's/^toggle: //p'  "$CD_WORK/order.txt")" "call cmd_toggle rc=0 | "
  t_eq "enable：不探测，直接分发"    "$(sed -n 's/^enable: //p'  "$CD_WORK/order.txt")" "call cmd_enable rc=0 | "
  t_eq "disable：不探测，直接分发"   "$(sed -n 's/^disable: //p' "$CD_WORK/order.txt")" "call cmd_disable rc=0 | "
}

# 入口在装配阶段已经探过（结果经 FAFU_SU_MODE 传进来）时，分发这一趟不该再探一次——
# 重复探测不只是白跑一次 su，还会让「探了几次」在不同路径下不一致，日志里数不清。
cd_case_probe_once() {
  cd_setup
  cd_write_env
  cd_run inherit <<'DRIVER'
{
  one() { # $1=子命令；$2=要预设的 FAFU_SU_MODE（空则模拟「入口没探到」）
    : > "$CD_CALLS"
    SU_MODE=""
    if [ -n "$2" ]; then FAFU_SU_MODE="$2"; export FAFU_SU_MODE; else unset FAFU_SU_MODE; fi
    ( cmd_dispatch "$1" ) >/dev/null 2>&1
    printf '%s=%s\n' "$1" "$(grep -c '^probe' "$CD_CALLS")"
  }
  one notify "/system/bin/su - shell -c"    # 入口探到了 → 分发不再探
  one notify ""                             # 入口没探到 → 分发兜底探一次
  one status "/system/bin/su - shell -c"    # 本就不需要探测的命令
} > "$T_WORK/inherit.out"
DRIVER
  t_eq "未继承时：分发仍会兜底探测（表里标 1 的命令）" "$(sed -n '2p' "$CD_WORK/inherit.out")" "notify=1"
  t_eq "已继承探测结果时：分发不再重复探测" "$(sed -n '1p' "$CD_WORK/inherit.out")" "notify=0"
  t_eq "未继承且表里标 0 的命令：不探测" "$(sed -n '3p' "$CD_WORK/inherit.out")" "status=0"
}

# ============================================================
# 四、用法文本：集合与顺序取自表；未知子命令打印用法并非 0 退出
# ============================================================

cd_case_usage() {
  local d
  cd_setup
  cd_write_env
  cd_run usage <<'DRIVER'
{
  printf 'list=%s\n' "$(dispatch_cmds)"
  # 用法文本里的自身路径随环境变（这里是驱动脚本名），比对时只看后半段
  printf 'usage=%s\n' "$(cmd_usage | sed 's/^用法: sh [^ ]* /用法: sh /')"
  cmd_usage >/dev/null; printf 'rc=%s\n' "$?"
  printf 'known_start=%s\n' "$(cmd_known start; echo $?)"
  printf 'known_empty=%s\n' "$(cmd_known ""; echo $?)"
  printf 'known_once=%s\n'  "$(cmd_known once; echo $?)"
  printf 'known_bogus=%s\n' "$(cmd_known bogus; echo $?)"
} > "$T_WORK/usage.out"
DRIVER
  d="$CD_WORK/usage.out"
  t_eq "清单：按表里的顺序列出九个命令" "$(cd_val "$d" list)" "stop status notify once refresh keepalive toggle enable disable "
  # 用法文本逐字钉住（集合来自表，start 写在说明里）
  t_eq "用法文本：逐字一致" "$(cd_val "$d" usage)" \
    "用法: sh [stop status notify once refresh keepalive toggle enable disable start]"
  t_eq "用法文本：返回非 0（用法即失败）" "$(cd_val "$d" rc)" "1"
  t_eq "cmd_known：start 认" "$(cd_val "$d" known_start)" "0"
  t_eq "cmd_known：不带子命令认" "$(cd_val "$d" known_empty)" "0"
  t_eq "cmd_known：表里的命令认" "$(cd_val "$d" known_once)" "0"
  t_ne "cmd_known：未知子命令不认" "$(cd_val "$d" known_bogus)" "0"
}

# ============================================================
# 五、加一个子命令 = 表里加一行（临时模块副本上验证，不动仓库文件）
#
# 判据：新名字出现在用法文本里、能分派到它的处理函数、其余部分没被动过。
# 三条都成立，就说明分发与用法确实只由那一行驱动，没有第三处要同步。
# ============================================================

cd_case_one_row() {
  local d rc tmp line cmd bb
  cd_setup
  d=$(t_stage_module "$CD_WORK/one")
  cmd='cdtmp'                       # 一个仓库里不存在的命令名
  line=$(grep -n 'stop      cmd_stop' "$d/lib/commands.sh" | head -n1 | cut -d: -f1)
  if [ -z "$line" ]; then
    _t_fail "临时用例：找不到命令表（层结构变了？）"
    return 0
  fi
  # 在表里插一行 + 给它一个最小处理函数，就是全部改动
  tmp="$CD_WORK/newrow.txt"
  printf '%s      cmd_%s      0 临时用例：只加了一行\n' "$cmd" "$cmd" > "$tmp"
  bb=$(t_find_busybox)
  "$bb" sed -i "${line}r $tmp" "$d/lib/commands.sh" 2>/dev/null || \
    sed -i "${line}r $tmp" "$d/lib/commands.sh"
  printf '\ncmd_%s() { echo "临时命令生效"; }\n' "$cmd" >> "$d/lib/commands.sh"

  ( cd "$d" && BB_OVERRIDE="$CD_WORK/bin/bb" $(t_sh) "./fafu_checkin.sh" "$cmd" ) \
    > "$CD_WORK/one.out" 2> "$CD_WORK/one.err"
  rc=$?
  ( cd "$d" && BB_OVERRIDE="$CD_WORK/bin/bb" $(t_sh) "./fafu_checkin.sh" bogus ) \
    > "$CD_WORK/one_usage.out" 2>&1

  t_eq "加一行：新子命令可执行且退出码为 0" "$rc" "0"
  t_has "加一行：真的进了新处理函数" "$CD_WORK/one.out" "临时命令生效"
  t_has "加一行：新名字出现在用法文本里" "$CD_WORK/one_usage.out" "$cmd"
  t_has "加一行：表的其余部分没被动过（stop 还在）" "$d/lib/commands.sh" "stop      cmd_stop"
}

# ============================================================
# 六、结构（静态）：入口只做装配 / 分发 / 后台化 / 主循环
# ============================================================

cd_case_entry_shape() {
  local entry
  entry="$T_ROOT/fafu_checkin.sh"
  # 入口不再自己列一遍命令：分派规则、用法文本、手动子命令的降权探测都在 commands 层
  t_hasnt "入口不再内联子命令 case 分支" "$entry" 'once)      run_once'
  t_hasnt "入口不再内联用法文本" "$entry" 'echo "用法: sh $SELF ['
  t_has "入口经 cmd_dispatch 分发" "$entry" 'cmd_dispatch "$CMD"'
  t_has "入口用 cmd_known 认子命令" "$entry" 'cmd_known "$CMD"'
  t_has "入口保留了后台化（nohup）" "$entry" 'nohup sh "$SELF" start'
  t_has "入口保留了单实例判定" "$entry" '已有实例(PID $oldpid)在运行，退出'
  t_has "入口保留了守护主循环" "$entry" 'while true; do'
  # 装配阶段的那一次探测（启动路径与手动子命令共用）：守护进程是入口派生出来再 exec
  # 自己的，它自己不探，所以这一次必须在派生**之前**发生，否则 daemon 会带着空的
  # SU_MODE 常驻、它发出的通知全部静默丢弃。
  # 锚点用带参数的调用形态（`probe_su "$CMD"`）：入口里这句是**顶格**写的，t_call 那种
  # 「前面留一个空格」的写法在这儿锚不到；带 $CMD 又能把注释里的函数名排掉。
  t_eq "静态锚点自证：入口里真的调了探测" \
    "$(grep -cF 'probe_su "$CMD"' "$entry")" "1"
  t_before "代码顺序：装配阶段的探测排在启动分支之前" "$entry" \
    'probe_su "$CMD"' '[ -z "$FAFU_DAEMON" ] && cmd_start'
  t_before "代码顺序：装配阶段的探测排在命令分发之前" "$entry" \
    'probe_su "$CMD"' 'cmd_dispatch "$CMD"'
}

# ============================================================
# 七、分发不依赖调用者的 fd：fd 3 关着时也要能拿到输出与退出码
# ============================================================

# 调用者的 fd 3 关着时也必须能用：fd 3 是调用者的环境事实，root shell（管理器的 WebUI /
# 交互终端）常常就是关着它 exec 出来的，而分发路径不依赖任何外部 fd。
# 驱动脚本先把 fd 3 关掉，再验输出仍然到得了 stdout、返回码仍然原样出来。
cd_case_dispatch_without_fd3() {
  cd_setup
  cd_write_env real
  cd_run_real no_fd3 <<'DRIVER'
exec 3>&-
cmd_stop() { echo "处理函数说了话"; return 5; }
cmd_dispatch stop
DRIVER
  t_has "fd 3 关闭：处理函数的输出仍进 stdout" "$CD_WORK/no_fd3.out" "处理函数说了话"
  t_eq "fd 3 关闭：返回码仍原样传出去" "$(cat "$CD_WORK/no_fd3.rc")" "5"
  t_hasnt "fd 3 关闭：没有 Bad file descriptor" "$CD_WORK/no_fd3.err" "Bad file descriptor"
}

# ============================================================
# 八、降权探测：启动路径与手动子命令共用同一次探测结果
# ============================================================

# 守护进程是入口 `nohup` 派生出来、再 exec 一次自己的后台进程；它继承的是入口的环境，
# 自己不再探（probe_su 里的 FAFU_SU_MODE 分支就是为这条继承链准备的）。所以那一次探测
# 必须发生在派生**之前**——否则 daemon 的 SU_MODE 为空，而空的 SU_MODE 会让 notify()
# 直接返回：自动签到那几条通知静默消失，日志里也没有任何报错。
#
# 判据是静态的：source 整个入口这条路走不通（入口里 `SELF="$0"` 是无条件赋值，source 时
# $0 是驱动脚本，入口会据此猜模块目录并因「缺少库层」退出），故这里钉**相对顺序**。
cd_case_probe_before_daemon() {
  local entry
  entry="$T_ROOT/fafu_checkin.sh"
  t_before "启动路径：装配阶段的探测排在守护进程派生之前" "$entry" \
    'probe_su "$CMD"' '[ -z "$FAFU_DAEMON" ] && cmd_start'
  # 继承那一半：探测函数认 FAFU_SU_MODE，daemon 才不必重复探测
  t_has "启动路径：探测结果可由 FAFU_SU_MODE 继承" "$T_ROOT/lib/notify.sh" 'FAFU_SU_MODE'
  t_has "启动路径：派生时把探测结果放进环境" "$entry" 'FAFU_SU_MODE="$SU_MODE"'
}



# ============================================================
# 九、分发传参：子命令之后的参数原样交给处理函数
#
# 契约一句话：`cmd_dispatch <子命令> <参数…>` 把它收到的其余参数**原样**（个数、顺序、
# 内容，含空格与 `键=值` 形态）转交处理函数——子命令名本身不算参数。
# 缝沿用既有的两条：驱动真实处理函数（参数到手没到、边界对不对）与记录桩（参数被记下来）。
# ============================================================

cd_case_dispatch_argv() {
  cd_setup
  cd_write_env real
  cd_run_real argv <<'DRIVER'
# 处理函数按「一个参数一对括号」回显：个数、顺序与边界（含空格的参数）都在这一行里
cmd_stop() {
  _argv=""
  for _a in "$@"; do _argv="$_argv[$_a]"; done
  printf 'argv=%s\n' "$_argv"
  return 0
}
cmd_dispatch stop 中文参数 两个词 键=值
DRIVER
  t_eq "传参：处理函数收到的参数逐字一致（个数 / 顺序 / 含空格的参数）" \
    "$(cd_val "$CD_WORK/argv.out" argv)" "[中文参数][两个词][键=值]"

  # 带参数时返回码也必须照旧走哨兵那条路
  cd_run_real argv_rc <<'DRIVER'
cmd_stop() {
  _argv=""
  for _a in "$@"; do _argv="$_argv[$_a]"; done
  printf 'argv=%s\n' "$_argv"
  return 7
}
cmd_dispatch stop alpha
DRIVER
  t_eq "传参：带参数的子命令，返回码仍原样传出" "$(cat "$CD_WORK/argv_rc.rc")" "7"
  t_has "传参：返回非 0 时输出也没被吞掉" "$CD_WORK/argv_rc.out" "argv=[alpha]"
}

# 入口那一跳也要原样传：`sh fafu_checkin.sh <子命令> <参数…>` 里的参数经分发到达处理函数。
# 入口已经把 $1 取成子命令名，转发时不能再把它算进参数——回显里多出一个 `[argvtmp]` 就会露出来。
cd_case_entry_argv() {
  local d bb line tmp
  cd_setup
  d=$(t_stage_module "$CD_WORK/entry")
  line=$(grep -n 'stop      cmd_stop' "$d/lib/commands.sh" | head -n1 | cut -d: -f1)
  if [ -z "$line" ]; then
    _t_fail "临时用例：找不到命令表（层结构变了？）"
    return 0
  fi
  # 只改临时副本：表里插入一行 + 给这一行写一个回显参数的处理函数
  tmp="$CD_WORK/entryrow.txt"
  printf 'argvtmp   cmd_argvtmp   0 临时用例：把收到的参数回显出来\n' > "$tmp"
  bb=$(t_find_busybox)
  "$bb" sed -i "${line}r $tmp" "$d/lib/commands.sh" 2>/dev/null || \
    sed -i "${line}r $tmp" "$d/lib/commands.sh"
  cat >> "$d/lib/commands.sh" <<'HANDLER'

cmd_argvtmp() {
  _argv=""
  for _a in "$@"; do _argv="$_argv[$_a]"; done
  printf 'argv=%s\n' "$_argv"
}
HANDLER

  ( cd "$d" && BB_OVERRIDE="$CD_WORK/bin/bb" $(t_sh) "./fafu_checkin.sh" argvtmp alpha "two words" ) \
    > "$CD_WORK/entry.out" 2>&1
  t_eq "入口传参：子命令之后的参数原样到达处理函数（子命令名不在其中）" \
    "$(cd_val "$CD_WORK/entry.out" argv)" "[alpha][two words]"
}

# 记录桩也要看得见参数——否则「参数到底到没到处理函数」在按表驱动的用例里无从观察。
# 桩把参数记成**行尾新加的一列**，且只在真有参数时才出现：不带参数的记录行与既有格式
# 逐字一致，既有断言（分发顺序那几条比的是整行）因此不受影响。
cd_case_stub_argv() {
  cd_setup
  cd_write_env
  cd_run stub_argv <<'DRIVER'
CD_RC=0; export CD_RC
( cmd_dispatch status )
( cmd_dispatch status alpha "two words" )
DRIVER
  t_eq "记录桩：不带参数时记录行保持既有格式" \
    "$(sed -n '1p' "$CD_WORK/calls")" "call cmd_status rc=0"
  t_eq "记录桩：参数作为行尾一列记下来" \
    "$(sed -n '2p' "$CD_WORK/calls")" "call cmd_status rc=0 args=[alpha two words]"
}

t_case "commands · 表驱动分发与退出码" cd_case_dispatch
t_case "commands · 分派不吞命令自己的输出" cd_case_dispatch_stdout
t_case "commands · once 的三档返回码" cd_case_once_rc
t_case "commands · 不在表里的名字不分发" cd_case_unknown
t_case "commands · 一张表驱动分发 / 探测 / 用法" cd_case_table_single_source
t_case "commands · 降权探测先于任何分发" cd_case_probe_first
t_case "commands · 已继承探测结果时不重复探测" cd_case_probe_once
t_case "commands · 用法文本与实际命令集合一致" cd_case_usage
t_case "commands · 新增子命令只需表里加一行" cd_case_one_row
t_case "commands · 入口只剩装配与调度（静态）" cd_case_entry_shape
t_case "commands · fd 3 关闭时分发仍可用" cd_case_dispatch_without_fd3
t_case "commands · 启动路径与手动子命令共用一次降权探测" cd_case_probe_before_daemon
t_case "commands · 子命令之后的参数原样交给处理函数" cd_case_dispatch_argv
t_case "commands · 入口把子命令之后的参数传进分发" cd_case_entry_argv
t_case "commands · 记录桩看得见处理函数收到的参数" cd_case_stub_argv
