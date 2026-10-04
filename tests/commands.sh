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
  # 表本身：十行，每行四列（名字 处理函数 探测 说明），说明非空
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
  t_eq "命令表：十一行（十一个手动排查子命令）" "$(cd_val "$f" rows)" "11"
  t_eq "命令表：每行前三列合法（名字 / cmd_ 处理函数 / 0|1）且说明非空" "$(cd_val "$f" cols)" "0"
  t_eq "需要降权探测的集合取自表" "$(cd_val "$f" probed)" "notify once refresh keepalive "
  t_eq "不需要探测的集合取自表" "$(cd_val "$f" quiet)" "stop status toggle enable disable webstate setconfig "

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
for c in notify once refresh keepalive stop status toggle enable disable webstate setconfig; do one "$c"; done
DRIVER
  # 需要探测的四条：第一行是探测、第二行才是处理函数
  t_eq "notify：先探测再分发" "$(sed -n 's/^notify: //p'  "$CD_WORK/order.txt")" "probe notify | call cmd_notify rc=0"
  t_eq "once：先探测再分发"   "$(sed -n 's/^once: //p'    "$CD_WORK/order.txt")" "probe once | call cmd_once rc=0"
  t_eq "refresh：先探测再分发" "$(sed -n 's/^refresh: //p' "$CD_WORK/order.txt")" "probe refresh | call cmd_refresh rc=0"
  t_eq "keepalive：先探测再分发" "$(sed -n 's/^keepalive: //p' "$CD_WORK/order.txt")" "probe keepalive | call cmd_keepalive rc=0"
  # 不需要探测的七条：第一个动作就是处理函数（没有多余的探测）
  t_eq "stop：不探测，直接分发"      "$(sed -n 's/^stop: //p'    "$CD_WORK/order.txt")" "call cmd_stop rc=0 | "
  t_eq "status：不探测，直接分发"    "$(sed -n 's/^status: //p'  "$CD_WORK/order.txt")" "call cmd_status rc=0 | "
  t_eq "toggle：不探测，直接分发"    "$(sed -n 's/^toggle: //p'  "$CD_WORK/order.txt")" "call cmd_toggle rc=0 | "
  t_eq "enable：不探测，直接分发"    "$(sed -n 's/^enable: //p'  "$CD_WORK/order.txt")" "call cmd_enable rc=0 | "
  t_eq "disable：不探测，直接分发"   "$(sed -n 's/^disable: //p' "$CD_WORK/order.txt")" "call cmd_disable rc=0 | "
  t_eq "webstate：不探测，直接分发"  "$(sed -n 's/^webstate: //p' "$CD_WORK/order.txt")" "call cmd_webstate rc=0 | "
  t_eq "setconfig：不探测，直接分发" "$(sed -n 's/^setconfig: //p' "$CD_WORK/order.txt")" "call cmd_setconfig rc=0 | "
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
  t_eq "清单：按表里的顺序列出十一个命令" "$(cd_val "$d" list)" "stop status notify once refresh keepalive toggle enable disable webstate setconfig "
  # 用法文本逐字钉住（集合来自表，start 写在说明里）
  t_eq "用法文本：逐字一致" "$(cd_val "$d" usage)" \
    "用法: sh [stop status notify once refresh keepalive toggle enable disable webstate setconfig start]"
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

# ============================================================
# 十、webstate：页面可解析的只读状态输出
#
# 缝是最接近页面实际行为的那一跳：把模块拷成一份可独立运行的副本，在副本里预置运行时
# 状态文件与一份假 leveldb，然后 `sh ./fafu_checkin.sh webstate`。断言只看两样外部
# 行为：stdout 的每一行与返回码。
# 两处环境事实按既有注入点换掉：时钟（mock 时间源）、网络出口（api 层的 http_post）——
# 用例因此既不依赖当天日期，也不发起任何请求。
# ============================================================

WS_DIR="$CD_WORK/webstate"
WS_DATE='2026-10-03'                              # 拨好的墙钟日期（夹具里的「今天」）
WS_TOKEN='2_0123456789abcdef0123456789abcdef'     # 假 leveldb 里的凭证明文（只用于负向断言）

# 夹具：模块副本 + 控制目录（时钟 / 网络替身 / 假 leveldb）+ 一份关掉通知的配置。
# 关通知是有意的：装配阶段的降权探测会因它直接返回，用例既不等 su 超时，也不受
# 「本机有没有 su」影响，日志里也不会多出与 webstate 无关的一行。
ws_setup() {
  cd_setup
  t_stage_module "$WS_DIR" >/dev/null
  mkdir -p "$WS_DIR/ctl/ld"
  printf '%s 21:35\n' "$WS_DATE" > "$WS_DIR/ctl/date"
  printf '"token":"%s"' "$WS_TOKEN" > "$WS_DIR/ctl/ld/000001.log"
  printf '{"records":[{"id":1}]}' > "$WS_DIR/ctl/body"
  printf '0' > "$WS_DIR/ctl/rc"
  printf 'NOTIFY=0\n' > "$WS_DIR/fafu-checkin.conf"
  # 网络出口的替身：按控制文件应答，一个请求都不发出去
  cat >> "$WS_DIR/lib/api.sh" <<'OVR'

http_post() {
  cat ./ctl/body 2>/dev/null
  _ws_rc=$(cat ./ctl/rc 2>/dev/null | tr -dc '0-9')
  return "${_ws_rc:-0}"
}
OVR
}

# 预置运行时状态文件（路径与 state 层登记的一致，值由用例给）
ws_switch() { printf '%s\n' "$1" > "$WS_DIR/fafu-checkin.state"; }
ws_sign()   { printf 'sign_date=%s\nsign_time=%s\nsign_kind=%s\n' "$1" "$2" "$3" > "$WS_DIR/fafu_checkin.status"; }
ws_ka()     { printf 'date=%s\nok=%s\nfail=%s\nlast=%s\nlast_result=%s\ntoken=%s\n' \
                "$1" "$2" "$3" "$4" "$5" "$6" > "$WS_DIR/fafu_keepalive.status"; }
ws_log() { # 参数逐个作为一行写进日志文件
  : > "$WS_DIR/fafu_checkin.log"
  for row in "$@"; do printf '%s\n' "$row" >> "$WS_DIR/fafu_checkin.log"; done
}

# 在副本里跑一次真实的子命令。WS_LD 非空时覆盖 leveldb 目录（「取不到凭据」那一档用它）。
ws_run() { # $1=名字（输出文件的后缀）
  local name rc
  name="$1"
  (
    cd "$WS_DIR" || exit 1
    BB_OVERRIDE="$CD_WORK/bin/bb" MOCK_DATE_CTL='./ctl/date' LD_DIR="${WS_LD:-./ctl/ld}" \
      $(t_sh) ./fafu_checkin.sh webstate
  ) > "$CD_WORK/ws_$name.out" 2> "$CD_WORK/ws_$name.err"
  rc=$?
  echo "$rc" > "$CD_WORK/ws_$name.rc"
  if [ -s "$CD_WORK/ws_$name.err" ]; then
    echo "  （webstate $name 的 stderr）"
    sed 's/^/    /' "$CD_WORK/ws_$name.err"
  fi
}

# 输出里出现的键名（去重排序）：字段齐全与键名逐字一致都靠它
ws_keys() { grep -o '^[a-z_]*' "$1" | sort -u | tr '\n' ' '; }
WS_KEYS="ka_fail ka_last ka_last_result ka_ok log service sign_state sign_time token_state version "

# 输出里「既不是 键=值、也不是空行」的行数。空行要排除：分发路径会给任何以换行收尾的
# 输出补一个空行（status 子命令同样如此），那不是命令自己吐出来的东西。
ws_stray() { awk '!/^[a-z_]*=/ && NF > 0 { n++ } END { print n + 0 }' "$1"; }

cd_case_webstate_fields() {
  local f
  ws_setup
  ws_switch enabled
  ws_sign "$WS_DATE" 21:30 normal
  ws_ka "$WS_DATE" 3 2 "$WS_DATE 21:30:14" fail "$WS_TOKEN"
  ws_log "[$WS_DATE 21:20:00] 第 1 条" "[$WS_DATE 21:21:00] 第 2 条" "[$WS_DATE 21:22:00] 第 3 条" \
         "[$WS_DATE 21:23:00] 第 4 条" "[$WS_DATE 21:24:00] 第 5 条" "[$WS_DATE 21:25:00] 第 6 条" \
         "[$WS_DATE 21:26:00] 第 7 条" "[$WS_DATE 21:28:00] 第 8 条"
  ws_run fields
  f="$CD_WORK/ws_fields.out"

  t_eq "只读子命令：返回码恒为 0" "$(cat "$CD_WORK/ws_fields.rc")" "0"
  t_eq "服务开关：停用语义取反成 on" "$(cd_val "$f" service)" "on"
  t_eq "今日签到状态：中文文本" "$(cd_val "$f" sign_state)" "已签到"
  t_eq "今日签到时间" "$(cd_val "$f" sign_time)" "21:30"
  t_eq "今日保活成功数" "$(cd_val "$f" ka_ok)" "3"
  t_eq "今日保活失败数" "$(cd_val "$f" ka_fail)" "2"
  t_eq "最近一次保活时间：原样来自状态层" "$(cd_val "$f" ka_last)" "$WS_DATE 21:30:14"
  t_eq "最近一次保活结果" "$(cd_val "$f" ka_last_result)" "fail"
  t_eq "登录状态有效：只报有效性" "$(cd_val "$f" token_state)" "ok"
  t_eq "版本号来自模块元数据" "$(cd_val "$f" version)" "v1.2.1"
  t_eq "字段齐全且键名逐字一致" "$(ws_keys "$f")" "$WS_KEYS"
  t_eq "每行都是 键=值（没有别的输出混进来）" "$(ws_stray "$f")" "0"
  t_eq "多出来的只有分发路径补的那个空行" "$(grep -c '^$' "$f")" "1"

  t_eq "日志：按 status 子命令的口径只取最近 6 条" "$(grep -c '^log=' "$f")" "6"
  t_has "日志：含最近一条" "$f" "log=[$WS_DATE 21:28:00] 第 8 条"
  t_hasnt "日志：只取尾部，更早的不出现" "$f" "第 1 条"
  t_hasnt "日志：只取尾部，更早的不出现" "$f" "第 2 条"

  # 负向：凭证明文绝不出现在输出里（它只报有效性）
  t_hasnt "输出里不含登录凭证明文" "$f" "$WS_TOKEN"
  t_eq "输出里没有 token= 后跟 2_十六进制 的形态" \
    "$(grep -cE '(^|=)2_[0-9A-Fa-f]{32}' "$f")" "0"

  # 只读：跑一次不该写任何东西（status 子命令会顺带刷新描述，这里不许）
  t_eq "只读：模块描述原样没被刷新" \
    "$(grep -m1 '^description=' "$WS_DIR/module.prop")" \
    "$(grep -m1 '^description=' "$T_ROOT/module.prop")"
  t_eq "只读：签到记录文件逐字未变" "$(cat "$WS_DIR/fafu_checkin.status" | tr '\n' '|')" \
    "sign_date=$WS_DATE|sign_time=21:30|sign_kind=normal|"
  t_eq "只读：不留临时文件" "$(ls "$WS_DIR" | grep -c '\.tmp$')" "0"
}

cd_case_webstate_sign() {
  local f
  ws_setup
  ws_switch enabled
  ws_log "[$WS_DATE 21:20:00] 占位一行"

  # ① 今天主窗口签到成功
  ws_sign "$WS_DATE" 21:30 normal
  ws_run sign_normal
  f="$CD_WORK/ws_sign_normal.out"
  t_eq "今天已签到：状态是中文" "$(cd_val "$f" sign_state)" "已签到"
  t_eq "今天已签到：带上签到时间" "$(cd_val "$f" sign_time)" "21:30"

  # ② 今天补签成功
  ws_sign "$WS_DATE" 22:35 supplement
  ws_run sign_supp
  f="$CD_WORK/ws_sign_supp.out"
  t_eq "今天补签：状态也是已签到" "$(cd_val "$f" sign_state)" "已签到"
  t_eq "今天补签：时间是补签那一刻" "$(cd_val "$f" sign_time)" "22:35"

  # ③ 今天请假：没有签到时间
  ws_sign "$WS_DATE" "" leave
  ws_run sign_leave
  f="$CD_WORK/ws_sign_leave.out"
  t_eq "今天请假：状态显示为已请假" "$(cd_val "$f" sign_state)" "已请假"
  t_eq "今天请假：签到时间给空值" "$(cd_val "$f" sign_time)" ""

  # ④ 记录停在昨天：今天仍是未签到
  ws_sign 2026-10-02 21:31 normal
  ws_run sign_old
  f="$CD_WORK/ws_sign_old.out"
  t_eq "只有昨天的记录：状态给空值" "$(cd_val "$f" sign_state)" ""
  t_eq "只有昨天的记录：时间给空值" "$(cd_val "$f" sign_time)" ""

  # ⑤ 一条记录都没有：字段仍在，值为空，退出码照旧
  rm -f "$WS_DIR/fafu_checkin.status"
  ws_run sign_none
  f="$CD_WORK/ws_sign_none.out"
  t_eq "没有任何记录：状态为空" "$(cd_val "$f" sign_state)" ""
  t_eq "没有任何记录：时间为空" "$(cd_val "$f" sign_time)" ""
  t_eq "没有任何记录：返回码仍为 0" "$(cat "$CD_WORK/ws_sign_none.rc")" "0"
}

cd_case_webstate_token() {
  local f
  ws_setup
  ws_switch enabled
  ws_sign "$WS_DATE" 21:30 normal
  ws_ka "$WS_DATE" 1 0 "$WS_DATE 09:00:00" ok "$WS_TOKEN"
  ws_log "[$WS_DATE 21:20:00] 占位一行"

  # ① 取得到凭据且接口回得出任务 → ok
  ws_run token_ok
  f="$CD_WORK/ws_token_ok.out"
  t_eq "登录有效：只报 ok" "$(cd_val "$f" token_state)" "ok"
  t_hasnt "登录有效：输出里没有凭证明文" "$f" "$WS_TOKEN"

  # ② 接口调用失败（替身回非 0）→ fail
  printf '1' > "$WS_DIR/ctl/rc"
  ws_run token_fail
  f="$CD_WORK/ws_token_fail.out"
  t_eq "接口调用失败：报 fail" "$(cd_val "$f" token_state)" "fail"
  t_hasnt "接口调用失败：同样不输出凭证明文" "$f" "$WS_TOKEN"

  # ③ 调用成功但响应体里没有任务 → fail（与 status 子命令同一判据）
  printf '0' > "$WS_DIR/ctl/rc"
  printf '{"timestamp":1}' > "$WS_DIR/ctl/body"
  ws_run token_nobody
  f="$CD_WORK/ws_token_nobody.out"
  t_eq "响应体里没有任务：报 fail" "$(cd_val "$f" token_state)" "fail"

  # ④ 拿不到凭据（空的 leveldb 目录）→ none
  printf '{"records":[{"id":1}]}' > "$WS_DIR/ctl/body"
  WS_LD='./ctl/empty'
  ws_run token_none
  f="$CD_WORK/ws_token_none.out"
  t_eq "取不到凭据：报 none" "$(cd_val "$f" token_state)" "none"
  t_eq "取不到凭据：返回码仍为 0" "$(cat "$CD_WORK/ws_token_none.rc")" "0"
  WS_LD=''

  # ⑤ 停用 + 保活统计停在前一天：统计按日归零，最近一次仍取原值
  ws_switch disabled
  ws_ka 2026-10-02 5 4 "2026-10-02 21:30:14" ok "$WS_TOKEN"
  ws_run stale
  f="$CD_WORK/ws_stale.out"
  t_eq "停用时开关报 off" "$(cd_val "$f" service)" "off"
  t_eq "昨天的成功数：按日滚动归零" "$(cd_val "$f" ka_ok)" "0"
  t_eq "昨天的失败数：按日滚动归零" "$(cd_val "$f" ka_fail)" "0"
  t_eq "最近一次保活：仍取原值（不受归零影响）" "$(cd_val "$f" ka_last)" "2026-10-02 21:30:14"
  t_eq "最近一次结果：仍取原值" "$(cd_val "$f" ka_last_result)" "ok"

  # ⑥ 副本里什么都没有：字段仍齐全（给空值），返回码仍为 0
  rm -f "$WS_DIR/fafu-checkin.state" "$WS_DIR/fafu_checkin.status" \
        "$WS_DIR/fafu_keepalive.status" "$WS_DIR/fafu_checkin.log"
  ws_run bare
  f="$CD_WORK/ws_bare.out"
  t_eq "什么记录都没有：返回码仍为 0" "$(cat "$CD_WORK/ws_bare.rc")" "0"
  t_eq "什么记录都没有：键集合不变" "$(ws_keys "$f")" "$WS_KEYS"
  t_eq "什么记录都没有：开关按默认启用报 on" "$(cd_val "$f" service)" "on"
  t_eq "什么记录都没有：日志给一行空值" "$(grep -c '^log=' "$f")" "1"
  t_eq "什么记录都没有：日志那一行是空的" "$(cd_val "$f" log)" ""
  t_eq "什么记录都没有：每行仍是 键=值" "$(ws_stray "$f")" "0"
}

# ============================================================
# 十一、写入子命令 setconfig：配置写入的唯一校验闸门
#
# 缝：在**临时模块副本**上驱动真实入口与真实处理函数（不替换记录桩），断言 stdout
# 回显、返回码，以及副本里那份配置文件的逐字节内容。「一次给全量六项」是页面实际的
# 调用形态，故基准用例从它出发；部分给也必须能用。
# ============================================================

# 页面一次给全的六项（合法值）
CD_SIX="KEEPALIVE=1 POLL_START=20:00 POLL_END=23:59 NOTIFY=1 NOTIFY_LEAD=5 NOTIFY_COOLDOWN=300"

# 基准配置：八项全是非默认值；轮询止 20:00 让「起点单独改晚」有得可越。
# 全程只读**这一份文件**判定写入是否发生（生效值留在进程里，跨进程看的就是它）。
CD_BASE='KEEPALIVE=0
POLL_START=06:30
POLL_END=20:00
NOTIFY=0
NOTIFY_LEAD=0
NOTIFY_COOLDOWN=60
KA_START=09:00
KA_END=18:30'

# 在副本里跑一次真实入口的 setconfig；用法：cd_sc <副本> <前缀> [参数…]
cd_sc() {
  local d prefix
  d="$1"; prefix="$2"; shift 2
  ( cd "$d" && BB_OVERRIDE="$CD_WORK/bin/bb" $(t_sh) "./fafu_checkin.sh" setconfig "$@" ) \
    > "$CD_WORK/$prefix.out" 2> "$CD_WORK/$prefix.err"
  echo "$?" > "$CD_WORK/$prefix.rc"
}

# 模块副本 + 基准配置（每个用例自备一份，互不干扰）
cd_sc_mod() { # $1=子目录名
  local d
  d=$(t_stage_module "$CD_WORK/$1")
  printf '%s\n' "$CD_BASE" > "$d/fafu-checkin.conf"
  printf '%s' "$d"
}

cd_case_setconfig_ok() {
  local d k
  cd_setup
  d=$(cd_sc_mod ok)
  cd_sc "$d" ok $CD_SIX
  t_eq "setconfig：合法的六项写入成功（返回 0）" "$(cat "$CD_WORK/ok.rc")" "0"
  # 回显：页面按 key=value 逐行解析，故每项都要是刚写进去的那个值
  t_eq "setconfig：回显 KEEPALIVE"             "$(cd_val "$CD_WORK/ok.out" KEEPALIVE)" "1"
  t_eq "setconfig：回显 POLL_START"            "$(cd_val "$CD_WORK/ok.out" POLL_START)" "20:00"
  t_eq "setconfig：回显 POLL_END"              "$(cd_val "$CD_WORK/ok.out" POLL_END)" "23:59"
  t_eq "setconfig：回显 NOTIFY"                "$(cd_val "$CD_WORK/ok.out" NOTIFY)" "1"
  t_eq "setconfig：回显 NOTIFY_LEAD"           "$(cd_val "$CD_WORK/ok.out" NOTIFY_LEAD)" "5"
  t_eq "setconfig：回显 NOTIFY_COOLDOWN"       "$(cd_val "$CD_WORK/ok.out" NOTIFY_COOLDOWN)" "300"
  # 回显的是**全部键**的生效值（含页面没给、只由文件承载的保活时段）
  t_eq "setconfig：回显八行（全部登记键的生效值）" "$(grep -c . "$CD_WORK/ok.out")" "8"
  # 回显与落盘一致：页面据此确认「真的进去了」
  for k in KEEPALIVE POLL_START POLL_END NOTIFY NOTIFY_LEAD NOTIFY_COOLDOWN KA_START KA_END; do
    t_eq "setconfig：回显的 $k 与落盘文件一致" \
      "$(cd_val "$CD_WORK/ok.out" "$k")" "$(cd_val "$d/fafu-checkin.conf" "$k")"
  done
  # 落盘：按登记顺序整份重写，六项是新值、保活时段沿用当前生效值
  t_eq "setconfig：落盘按登记顺序整份重写" "$(cat "$d/fafu-checkin.conf" | tr '\n' '|')" \
    "KEEPALIVE=1|POLL_START=20:00|POLL_END=23:59|NOTIFY=1|NOTIFY_LEAD=5|NOTIFY_COOLDOWN=300|KA_START=09:00|KA_END=18:30|"
  t_eq "setconfig：写入成功时不打噪音" "$(wc -c < "$CD_WORK/ok.err" | tr -dc '0-9')" "0"
}

# 页面一次给全六项是调用约定，但闸门不该因此只在「给全」时才可用
cd_case_setconfig_partial() {
  local d
  cd_setup
  d=$(cd_sc_mod partial)
  cd_sc "$d" partial NOTIFY_COOLDOWN=600
  t_eq "setconfig：只给一项也能写（返回 0）" "$(cat "$CD_WORK/partial.rc")" "0"
  t_eq "setconfig：给了的项落盘" "$(cd_val "$d/fafu-checkin.conf" NOTIFY_COOLDOWN)" "600"
  t_eq "setconfig：没给的项沿用当前生效值" "$(cd_val "$d/fafu-checkin.conf" POLL_START)" "06:30"
  t_eq "setconfig：没给的项不退回默认值" "$(cd_val "$d/fafu-checkin.conf" KEEPALIVE)" "0"
  t_eq "setconfig：回显仍是全部键的生效值" "$(grep -c . "$CD_WORK/partial.out")" "8"
}

# 非法值逐类各一条：非 0 退出 + 可读原因 + 配置文件逐字节未变
cd_case_setconfig_reject() {
  local d n rc
  cd_setup
  d=$(cd_sc_mod reject)
  sc_bad() { # $1=样本名，其余=「键=值」参数
    n="$1"; shift
    cp "$d/fafu-checkin.conf" "$CD_WORK/$n.before"
    cd_sc "$d" "$n" "$@"
    rc=$(cat "$CD_WORK/$n.rc")
    t_ne "setconfig 拒绝（$n）：返回非 0" "$rc" "0"
    t_ne "setconfig 拒绝（$n）：给出可读原因" "$(cat "$CD_WORK/$n.err")" ""
    t_eq "setconfig 拒绝（$n）：配置文件逐字节未变" \
      "$(cat "$d/fafu-checkin.conf")" "$(cat "$CD_WORK/$n.before")"
  }
  sc_bad badtime   POLL_START=25:00
  sc_bad letters   POLL_START=ab:cd
  sc_bad midnight  POLL_START=23:00 POLL_END=01:00
  sc_bad pastend   POLL_START=21:00
  sc_bad leadalpha NOTIFY_LEAD=abc
  sc_bad leadover  NOTIFY_LEAD=99999
  sc_bad switch7   KEEPALIVE=7
  sc_bad unknown   FOO=1
  # 只接受登记表里的精确键名：同一批里合法与非法混着给，整批都不落盘
  sc_bad lowercase keepalive=1
  sc_bad mixed     POLL_START=05:00 KEEPALIVE=7
  t_has "setconfig 拒绝（时刻越界）：原因里点明键名" "$CD_WORK/badtime.err" "POLL_START"
  t_has "setconfig 拒绝（时刻越界）：原因里带上被拒的值" "$CD_WORK/badtime.err" "25:00"
  t_has "setconfig 拒绝（未知键）：原因里点明那个键" "$CD_WORK/unknown.err" "FOO"
  t_has "setconfig 拒绝（键名大小写不符）：原因里点明那个键" "$CD_WORK/lowercase.err" "keepalive"
  t_has "setconfig 拒绝（跨午夜）：原因里说清起止的约束" "$CD_WORK/midnight.err" "早于"
  # 参数形态本身有毛病：不成对与完全没给
  sc_bad nosep     POLL_START
  sc_bad noargs
  t_has "setconfig 拒绝（不成对）：原因里说清要写成 键=值" "$CD_WORK/nosep.err" "键=值"
  # 一路拒绝下来，合法的一组照旧写得进去（证明上面不是「一律拒绝」）
  cd_sc "$d" recover NOTIFY_COOLDOWN=120
  t_eq "setconfig：连拒之后合法的一组照旧写进去" "$(cat "$CD_WORK/recover.rc")" "0"
  t_eq "setconfig：合法写入的生效值落盘" "$(cd_val "$d/fafu-checkin.conf" NOTIFY_COOLDOWN)" "120"
}

# 重写策略：整份按登记键重写，手写注释与表外的键都不活过这一次
cd_case_setconfig_rewrite() {
  local d
  cd_setup
  d=$(t_stage_module "$CD_WORK/rewrite")
  cat > "$d/fafu-checkin.conf" <<'CONF'
# 手写的注释：重写后不该留下
POLL_START=06:30
POLL_END=20:00
FOO=bar
CONF
  cd_sc "$d" rewrite $CD_SIX
  t_eq "setconfig：写入成功（返回 0）" "$(cat "$CD_WORK/rewrite.rc")" "0"
  t_eq "setconfig：重写后恰好八行（登记键各一行）" "$(grep -c . "$d/fafu-checkin.conf")" "8"
  t_eq "setconfig：重写后没有注释行" "$(grep -c '^#' "$d/fafu-checkin.conf")" "0"
  t_eq "setconfig：重写后没有表外的键" "$(grep -c '^FOO=' "$d/fafu-checkin.conf")" "0"
  t_eq "setconfig：未提到的键补的是默认值" "$(cd_val "$d/fafu-checkin.conf" KA_END)" "21:25"
  t_eq "setconfig：重写后按登记顺序整份落盘" "$(cat "$d/fafu-checkin.conf" | tr '\n' '|')" \
    "KEEPALIVE=1|POLL_START=20:00|POLL_END=23:59|NOTIFY=1|NOTIFY_LEAD=5|NOTIFY_COOLDOWN=300|KA_START=07:00|KA_END=21:25|"
}

# 校验先于落盘：带 shell 元字符的值一个字节都不该进配置文件，更不该被执行
cd_case_setconfig_injection() {
  local d
  cd_setup
  d=$(cd_sc_mod inject)
  cp "$d/fafu-checkin.conf" "$CD_WORK/inject.before"
  cd_sc "$d" inject "POLL_START=20:00; touch hacked" POLL_END=23:00
  t_ne "setconfig 注入：返回非 0" "$(cat "$CD_WORK/inject.rc")" "0"
  t_eq "setconfig 注入：配置文件逐字节未变" \
    "$(cat "$d/fafu-checkin.conf")" "$(cat "$CD_WORK/inject.before")"
  t_eq "setconfig 注入：文件里没有注入的字样" "$(grep -c 'hacked' "$d/fafu-checkin.conf")" "0"
  t_eq "setconfig 注入：没有生成被注入命令碰过的文件" "$(ls "$d" | grep -c '^hacked$')" "0"
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
t_case "commands · webstate 输出页面可解析的状态" cd_case_webstate_fields
t_case "commands · webstate 的签到状态从记录里读" cd_case_webstate_sign
t_case "commands · webstate 的登录状态只报有效性" cd_case_webstate_token
t_case "commands · setconfig 写入合法值并回显生效值" cd_case_setconfig_ok
t_case "commands · setconfig 部分给也能用" cd_case_setconfig_partial
t_case "commands · setconfig 拒非法值且旧值不变" cd_case_setconfig_reject
t_case "commands · setconfig 重写后只留登记键" cd_case_setconfig_rewrite
t_case "commands · setconfig 不落未校验的内容" cd_case_setconfig_injection
