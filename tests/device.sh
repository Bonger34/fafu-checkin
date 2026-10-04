# ============================================================
# device 层验收断言：屏幕状态判定、前端任务枚举、打开 / 移除打卡页
#
# 三条口径：
#   1) 行为：屏幕判定失败按「亮屏」处理；任务枚举只认自己包的活动记录；
#      close_page 的清理不彻底只留日志、绝不做任何「切前台」的动作；
#   2) 缝：设备命令（am / input / wm / dumpsys）在测试里用**同名可执行文件**顶掉——
#      dv_setup 把四个包装器放进 $DV_WORK/bin 并排到 PATH 最前，包装器再调
#      tests/mock/busybox 的对应 applet（它记录命令行并注入输出）；
#      refresh_token 的时序由注入 get_token 驱动（连续调用返回「旧 → 新」）；
#   3) 不变：两条时序——「取不到新 token 时不提前关页」「拿到新 token 后
#      立即移除页面」；设备命令的 fd 加固（`</dev/null >/dev/null 2>&1`，不接管道）。
#
# 断言直接加载真实的层文件（tests/harness.sh 的 TEST_LIB_FILES），不抽源码片段、不绑行号。
# ============================================================

DV_WORK="$T_WORK_ROOT/device"

# 夹具路径一律用**相对路径**（驱动先 cd 到 $DV_WORK 再运行）：Windows 的 D:/ 路径喂进
# 被测代码会变成残缺路径（见 tests/state.sh 的说明），而运行时用的是手机上的绝对路径。
DV_MODDIR="./mod"
DV_BIN="./bin"
DV_BB="./bin/bb"
DV_DEV="./dev"

# 本次改动要收口的四项能力：能力名 → 必须持有它的层
DV_CAPS="screen_is_on:device app_task_ids:device act_count:device open_page:device close_page:device"

# 无头活动记录：这些行里的任务号就是 app_task_ids / act_count 要输出的东西。
# 一条记录里有两处「t<数字>」，都要取到（见下面 dv_case_tasks 的说明）
DV_RECS_A='* ActivityRecord{aa11 t123 u0 cn.edu.fafu.iportal/xxx t42}'
DV_RECS_B='* ActivityRecord{bb22 t456 u0 cn.edu.fafu.iportal/yyy t7}'

# 每处系统命令调用都必须自带的加固尾巴（由 mock 的 fd 见证一起守住）
DV_HARDEN='</dev/null >/dev/null 2>&1'

# 设备命令替身需要的 PATH 包装器：真机上它们都在 /system/bin 下（不是 busybox applet），
# 所以顶掉它们必须在 PATH 上放同名文件，而不是覆盖同名 shell 函数。
#
# 两层兜底（两种环境各自需要其中一层）：
#   1) `#!$bb sh` 起头：Windows 上「可执行」要求存在解释器，只有 busybox 认这个 shebang；
#      没有它时 PATH 上的 dumpsys 会**静默变成 no-op**（断言全部空转，最难发现的一种失败）。
#   2) 末尾再按「显式解释器」跑一遍：CI 的 /bin/sh 与本地多套一个 busybox .exe 时都能落地。
dv_tools() {
  local t bb real
  bb=$(t_find_busybox)
  [ -n "$bb" ] || bb="busybox"
  case "$bb" in
    *.exe|*.EXE) real="$bb sh \"\$0\" \"\$@\"" ;;
    *)           real="$bb \"\$0\" \"\$@\"" ;;
  esac
  mkdir -p "$DV_WORK/bin"
  for t in am input wm dumpsys; do
    {
      echo "#!$bb sh"
      echo '# 由 tests/device.sh 生成：设备命令替身（记录命令行与 fd 见证，并注入输出）'
      echo "BB_REAL='$bb'"
      echo "MOCK_DIR='$T_ROOT/tests/mock'"
      echo 'export BB_REAL'
      echo "if [ -x \"\$MOCK_DIR/busybox\" ]; then exec \"\$MOCK_DIR/busybox\" $t \"\$@\"; fi"
      echo "$real"
    } > "$DV_WORK/bin/$t"
    chmod +x "$DV_WORK/bin/$t" 2>/dev/null || true
  done
}

dv_setup() {
  rm -rf "$DV_WORK"
  mkdir -p "$DV_WORK/mod" "$DV_WORK/dev"
  t_bb_wrap "$DV_WORK/bin/bb" >/dev/null
  dv_tools
  printf '0\n' > "$DV_WORK/dev/rc"
  : > "$DV_WORK/dev/calls"
}

# 驱动脚本的公共前导：替身 busybox + 设备命令在 PATH 最前 + 模块目录，再按加载顺序加载层
dv_write_env() {
  cat > "$DV_WORK/_env.sh" <<ENV
PATH='$DV_BIN:/bin:/usr/bin'
T_ROOT='$T_ROOT'
MODDIR='$DV_MODDIR'
BB_OVERRIDE='$DV_BB'
MOCK_DEVICE_DIR='$DV_DEV'
export MODDIR BB_OVERRIDE MOCK_DEVICE_DIR
for _f in $TEST_LIB_FILES; do . "\$T_ROOT/\$_f"; done
ENV
}

# 跑一个驱动脚本；用法：dv_run <名字>，主体从 stdin 读入（公共前导自动接在前面）
dv_run() {
  local name rc
  name="$1"
  cat > "$DV_WORK/_body.sh"
  cp "$DV_WORK/_env.sh" "$DV_WORK/$name.sh"
  cat "$DV_WORK/_body.sh" >> "$DV_WORK/$name.sh"
  ( cd "$DV_WORK" && $(t_sh) "./$name.sh" ) > "$DV_WORK/$name.out" 2> "$DV_WORK/$name.err"
  rc=$?
  echo "$rc" > "$DV_WORK/$name.rc"
  if [ -s "$DV_WORK/$name.err" ]; then
    echo "  （驱动 $name 的 stderr）"
    sed 's/^/    /' "$DV_WORK/$name.err"
  fi
}

# 从驱动输出里取一行（形如 key=value）
dv_val() { # $1=文件 $2=键
  sed -n "s/^$2=//p" "$1"
}

# 每个用例开头清一次记录（设备替身、路径与环境在各用例间复用）
dv_reset() {
  : > "$DV_WORK/dev/calls"
  printf '0\n' > "$DV_WORK/dev/rc"
}

# ---- fd 见证（一个短名，断言里读起来才不至于满屏符号）----
# dv_bad_fd：记录里出现过 `file` 见证 = 设备命令的某个 fd 被接到了**普通文件**
dv_bad_fd() { grep -c '^file|' "$DV_WORK/dev/calls" 2>/dev/null; }

# ============================================================
# 一、屏幕状态判定：设备输出的解析 + 检测失败按「亮屏」处理
# ============================================================

dv_case_screen() {
  dv_setup
  dv_write_env
  # 唤醒值的三种写法（ROM 换代改过字段名，三种都要认）——三条断言各用一份夹具
  printf 'mWakefulness=Awake\n' > "$DV_WORK/dev/power.txt"
  dv_run screen <<'DRIVER'
# 设备输出经替身注入；替身没给出夹具文件时输出为空 = 检测失败
printf 'awake=%s\n' "$(screen_is_on && echo yes || echo no)"
printf 'power_calls=%s\n' "$(grep -c '|dumpsys|power' dev/calls)"
DRIVER

  printf 'Display Power: state=ON\n' > "$DV_WORK/dev/power.txt"
  dv_run screen2 <<'DRIVER'
printf 'onfield=%s\n' "$(screen_is_on && echo yes || echo no)"
DRIVER

  printf 'mWakefulness=Asleep\n' > "$DV_WORK/dev/power.txt"
  dv_run screen3 <<'DRIVER'
printf 'asleep=%s\n' "$(screen_is_on && echo yes || echo no)"
DRIVER

  # 设备查不到屏幕状态（命令不存在 / 无输出）→ 检测失败，必须按「亮屏」处理
  rm -f "$DV_WORK/dev/power.txt"
  dv_run screen4 <<'DRIVER'
printf 'nocmd=%s\n' "$(screen_is_on && echo yes || echo no)"
DRIVER

  t_eq "mWakefulness=Awake → 亮屏" "$(dv_val "$DV_WORK/screen.out" awake)" "yes"
  t_eq "Display Power: state=ON → 亮屏（旧字段仍认）" "$(dv_val "$DV_WORK/screen2.out" onfield)" "yes"
  t_eq "mWakefulness=Asleep（无 ON 字段）→ 熄屏" "$(dv_val "$DV_WORK/screen3.out" asleep)" "no"
  t_eq "屏幕状态完全取不到（检测失败）→ 按亮屏处理" "$(dv_val "$DV_WORK/screen4.out" nocmd)" "yes"
  t_eq "屏幕判定确实读了 dumpsys power（上面几条不是空转）" "$(dv_val "$DV_WORK/screen.out" power_calls)" "1"
  t_eq "dumpsys 自身不接到普通文件（fd 加固的负向守卫）" "$(dv_bad_fd)" "0"
}

# ============================================================
# 二、前端任务枚举：只认自己包的活动记录，同行多条也算
# ============================================================

dv_case_tasks() {
  local d
  dv_setup
  dv_write_env
  # 同一行并排两条记录 + 三行重复 + 无关包 + 缺 u0 段：都要被正确处理
  {
    printf '%s %s\n' "$DV_RECS_A" "$DV_RECS_B"
    printf '%s\n' "$DV_RECS_A" "$DV_RECS_B" "$DV_RECS_A"
    printf '  ResumedActivity: ActivityRecord{cc33 t42 u0 com.android.launcher3/.Launcher t8}\n'
    printf '  * ActivityRecord{dd44 u0 cn.edu.fafu.iportal/.NoTaskSeg}\n'
  } > "$DV_WORK/dev/activity.txt"
  dv_run tasks <<'DRIVER'
printf 'ids=%s\n'  "$(app_task_ids)"
printf 'n=%s\n'    "$(act_count)"
DRIVER

  # 同一批夹具只留唯一一条记录
  dv_reset
  printf '%s\n' "$DV_RECS_A" > "$DV_WORK/dev/activity.txt"
  dv_run tasks2 <<'DRIVER'
printf 'ids=%s\n' "$(app_task_ids)"
printf 'n=%s\n'   "$(act_count)"
DRIVER

  dv_reset
  : > "$DV_WORK/dev/activity.txt"
  dv_run tasks3 <<'DRIVER'
printf 'ids=%s\n' "$(app_task_ids)"
printf 'n=%s\n'   "$(act_count)"
DRIVER

  d="$DV_WORK/tasks.out"
  # 任务号有两处来源，取到的是同一个号：记录里 "u0 " 之后的，以及记录
  # 末尾 "}" 之前那个；同一行并排两条记录也都要取到。去重后升序、空格分隔、结尾带空格。
  t_eq "任务号：并排两条记录 + 两处来源都取到（去重升序）" "$(dv_val "$d" ids)" "123 42 456 7 "
  # 活动数按「去重后的记录条数」算：种子两行 + 并排那行 + 重复两行 → 3 条唯一记录
  # （无关包的记录不算，缺 u0 段的也算一条——它确实是打卡页的活动）
  t_eq "活动数：重复记录去重后计数" "$(dv_val "$d" n)" "3"
  t_eq "唯一一条记录时任务号正确" "$(dv_val "$DV_WORK/tasks2.out" ids)" "123 42 "
  t_eq "唯一一条记录时计数为 1" "$(dv_val "$DV_WORK/tasks2.out" n)" "1"
  # 无关包（launcher）的活动记录必须被忽略：算进去就意味着会把用户的其它 App 当打卡页清理
  t_eq "无关包不计数（数多了会误删用户其它 App 的任务）" "$(dv_val "$d" n)" "3"
  t_eq "无关包的任务号也不出现" "$(dv_val "$d" ids)" "123 42 456 7 "
  t_eq "没有记录时计数为 0" "$(dv_val "$DV_WORK/tasks3.out" n)" "0"
  t_eq "没有记录时任务号为空" "$(dv_val "$DV_WORK/tasks3.out" ids)" ""
}

# ============================================================
# 三、打开打卡页 / 移除打卡页：命令行 + 残留只留日志
# ============================================================

dv_case_pages() {
  local d
  dv_setup
  dv_write_env
  # activity.txt 一直空着 = 页面的任务不残留
  : > "$DV_WORK/dev/activity.txt"
  dv_run pages <<'DRIVER'
open_page
echo "open_rc=$?"
close_page
printf 'log=%s\n' "$(tail -n 1 "$LOG")"
printf 'calls=%s\n' "$(tr '\n' '@' < dev/calls)"
DRIVER

  d="$DV_WORK/pages.out"
  t_eq "open_page 正常返回" "$(dv_val "$d" open_rc)" "0"
  t_has "交给系统的开页命令行逐字一致" "$d" \
    "calls=-|am|start|--user|0|-n|cn.edu.fafu.iportal/huawei.w3.ui.welcome.W3SplashScreenActivity|-a|com.huawei.works.action.shortcut|-c|android.shortcut.conversation|-d|http://stuhealth.fafu.edu.cn/declarew/#/fafu/login|--ei|src|202"
  t_eq "页面无残留时的收尾日志不变" "$(dv_val "$d" log)" "[$(dv_val "$d" log | cut -c2-20)] 页面关闭检查: 残留活动=0"
  t_has "开页用 am start" "$DV_WORK/dev/calls" "-|am|start|--user|0|-n|cn.edu.fafu.iportal/"
  # 两个子命令都要原样透传：只写 activity（丢掉 activities）时本条会报红——
  # 那种写法在真机上打印的是服务概览，没有 ActivityRecord 可解析
  t_has "任务枚举用 dumpsys activity activities（子命令不许丢）" "$DV_WORK/dev/calls" \
    "-|dumpsys|activity|activities"
  t_eq "设备命令不接到普通文件（fd 加固的负向守卫）" "$(dv_bad_fd)" "0"
}

# ============================================================
# 四、清理不彻底：留在后台，绝不主动切换用户的前台
# ============================================================

dv_case_close_residual() {
  local d
  dv_setup
  dv_write_env
  # 活动记录一直存在 = 任务清不掉（设备上 am stack remove 留下的不可见残留就是这样）
  printf '%s\n' "$DV_RECS_A" > "$DV_WORK/dev/activity.txt"
  dv_run close <<'DRIVER'
close_page
printf 'log_last=%s\n'  "$(tail -n 1 "$LOG")"
printf 'log_prev=%s\n'  "$(tail -n 2 "$LOG" | head -n 1)"
printf 'removes=%s\n'   "$(grep -c '|am|stack|remove|' dev/calls)"
printf 'starts=%s\n'    "$(grep -c '|am|start|' dev/calls)"
printf 'other_am=%s\n'  "$(grep '|am|' dev/calls | grep -vc 'stack|remove')"
DRIVER

  d="$DV_WORK/close.out"
  t_eq "清理不彻底：只记一行「保留在后台」" "$(dv_val "$d" log_prev)" \
    "[$(dv_val "$d" log_prev | cut -c2-20)] 页面移除未彻底(残留1)，保留在后台（不再回桌面）"
  t_eq "收尾日志仍报残留数" "$(dv_val "$d" log_last)" \
    "[$(dv_val "$d" log_last | cut -c2-20)] 页面关闭检查: 残留活动=1"
  t_eq "清不掉时重试一轮（两条记录 × 两轮 = 4 次 am stack remove）" "$(dv_val "$d" removes)" "4"
  t_eq "绝不主动切换用户前台（清理期没有任何 am start）" "$(dv_val "$d" starts)" "0"
  t_eq "清理期没有第二种 am 动作" "$(dv_val "$d" other_am)" "0"
  t_eq "am stack remove 也不接到普通文件" "$(dv_bad_fd)" "0"
}

# 设备替身兜不住 `am start` 中间那次启动时，这里会直接报红（而不是静默空跑）
dv_case_seam_liveness() {
  local d
  dv_setup
  dv_write_env
  printf 'mWakefulness=Awake\n' > "$DV_WORK/dev/power.txt"
  printf '%s\n' "$DV_RECS_A" > "$DV_WORK/dev/activity.txt"
  dv_run alive <<'DRIVER'
screen_is_on >/dev/null
app_task_ids >/dev/null
act_count >/dev/null
open_page
close_page >/dev/null
printf 'dump=%s\n' "$(grep -c '|dumpsys|' dev/calls)"
printf 'am=%s\n'   "$(grep -c '|am|' dev/calls)"
DRIVER

  d="$DV_WORK/alive.out"
  t_ne "设备命令替身真的被调用（否则上面的断言全是空转）" "$(dv_val "$d" dump)" "0"
  t_ne "am 替身真的被调用" "$(dv_val "$d" am)" "0"
}

# ============================================================
# 五、两条时序不变量（refresh_token 与设备层的关系）
#
# ① 取不到新 token 时不提前关页——保持与兜底唤醒一致的时序（走完阶段 2 再关）；
# ② 拿到新 token 后立即移除页面——把抢占前台的窗口压到登录所需的那几秒。
#
# 驱动里**只注入 token 来源与 sleep**：open_page / close_page / screen_is_on 都跑**真实实现**，
# 它们发出的 am / dumpsys 由设备命令替身记录。于是「关页发生在第几次采样之后」可以被直接
# 观察到，而不是靠 stub 出来的两行 echo 自证——把被测对象整个换掉，断言就只剩空转了。
#
# 统计口径：每段在**取到返回值之后**数一次记录文件。关页自己也是被观察的行为，
# 中途快照会读到它正在写的半截记录（快照因此少了后面几条），所以只在段末计数。
# ============================================================

dv_case_timing() {
  local d
  dv_setup
  dv_write_env
  # 夹具是**清不掉**的两条活动记录（设备上 am stack remove 留下的不可见残留就是这样）：
  # 于是每次 close_page 必定走满两轮。命令行条数因此可精确预期——
  # 每条记录里有两处任务号（`u0 ` 之后与记录末尾 `}` 之前，与原正则一致），
  # 所以一次关页 = 2 条记录 × 2 个任务号 × 2 轮 = 8 条 am stack remove、4 次 dumpsys。
  printf '%s\n' "$DV_RECS_A" "$DV_RECS_B" > "$DV_WORK/dev/activity.txt"
  # ① 的序列：11 次轮询 + 21 次唤醒重试都给旧 token（比采样上限还多，保证真的走完两条路径）
  {
    i=0
    while [ $i -lt 32 ]; do echo 'OLD'; i=$((i+1)); done
  } > "$DV_WORK/tok.seq"
  dv_run timing <<'DRIVER'
# 只注入两处：token 来源（每次取序号文件里的第 N 行）与 sleep（本机不要真的等）
get_token() {
  n=$(cat tok.n 2>/dev/null); n=$(( ${n:-0} + 1 )); printf '%s\n' "$n" > tok.n
  sed -n "${n}p" tok.seq
}
sleep() { :; }
# 只数「移除任务」这一类：每调用一次 close_page 就发两条（夹具里两条活动记录）
removes() { grep -c '|am|stack|remove' dev/calls 2>/dev/null; }
: > tok.n

# ① 全程只有旧 token：轮询 30 秒（11 次）拿不到，允许唤醒重试，再等 60 秒（21 次采样）
: > dev/calls
printf 'tok1=%s\n'    "$(refresh_token OLD 1)"
printf 'polls1=%s\n'  "$(cat tok.n)"
printf 'rem1=%s\n'    "$(removes)"
printf 'start1=%s\n'  "$(grep -c '|am|start|' dev/calls)"

# ② 头四次采样仍是旧 token，第 5 次拿到新的（先清记录文件，否则数到的是两段之和）
printf 'OLD\nOLD\nOLD\nOLD\nNEW\n' > tok.seq
: > tok.n
: > dev/calls
printf 'tok2=%s\n'    "$(refresh_token OLD 1)"
printf 'polls2=%s\n'  "$(cat tok.n)"
printf 'rem2=%s\n'    "$(removes)"
printf 'start2=%s\n'  "$(grep -c '|am|start|' dev/calls)"
printf 'dump2=%s\n'   "$(grep -c '|dumpsys|activity|activities' dev/calls)"
DRIVER

  d="$DV_WORK/timing.out"
  t_eq "① 始终拿不到新 token：返回旧 token" "$(dv_val "$d" tok1)" "OLD"
  # 采样次数：轮询 11 次 + 唤醒重试 21 次，减去最后那次「跳出循环不计 i」→ 30
  t_eq "① 两条采样路径都被走到（11 + 21 - 1 次采样）" "$(dv_val "$d" polls1)" "30"
  t_has "① 确实进入了兜底唤醒重试" "$DV_WORK/mod/fafu_checkin.log" "尝试唤醒屏幕重试"
  # ① 只用真实 close_page 关一次页（清不掉的夹具 → 每关一次 8 条命令）：
  #    轮询期间若提前关页，这里会变成 16
  t_eq "① 取不到新 token 时不提前关页（只关一次 = 8 条 am stack remove）" "$(dv_val "$d" rem1)" "8"
  t_eq "① 开页与任务枚举走的是真实设备层（不是 stub）" "$(dv_val "$d" start1)" "1"
  # ② 第 5 次采样就拿到新 token：提前关一次 + 收尾关一次 = 16 条 am stack remove
  t_eq "② 拿到新 token 后立即关页（提前关 + 收尾关 = 16 条）" "$(dv_val "$d" rem2)" "16"
  t_eq "② 拿到新 token 后不再重复开页" "$(dv_val "$d" start2)" "1"
  # ② 关页要走真实实现：每次 close_page 读四轮活动记录（app_task_ids + act_count 各两轮），
  # 提前关与收尾关各一次 → 8 次；把 close_page 换成 stub 时这里会塌成 0
  t_eq "② 关页读活动记录走的是真实实现（8 次 dumpsys）" "$(dv_val "$d" dump2)" "8"
  t_eq "② 拿到新 token 后不再进入兜底唤醒重试" "$(dv_val "$d" polls2)" "5"
  t_eq "② 拿到新 token：返回新 token" "$(dv_val "$d" tok2)" "NEW"
}

# ============================================================
# 六、边界（静态）：四项能力收口到设备层、fd 加固逐处一致
#
# 判据只用**命令位**与**能力名**，不绑局部变量名与参数位次——名字是各层的内部事。
# ============================================================

dv_case_boundary() {
  local src f cap owner miss all bad n_am n_dump n_sys
  src="$DV_WORK/program.sh"
  mkdir -p "$DV_WORK"
  t_write_program "$src" || { _t_fail "无法拼出全程序文本"; return 0; }

  # 四项能力只有设备层定义（能力名 = 函数的唯一真源，改名会在这里报红）
  miss=""
  for cap in $DV_CAPS; do
    owner=""
    for f in $TEST_LIB_FILES; do
      if grep -qE "^[ 	]*${cap%%:*}[ 	]*\(\)" "$T_ROOT/$f" 2>/dev/null; then owner="${f##*/}"; fi
    done
    [ "$owner" = "${cap##*:}.sh" ] || miss="$miss $cap→${owner:-无}"
  done
  t_eq "四项能力都定义在设备层" "[$miss]" "[]"

  # 改设备行为只该读一层：命令位的 dumpsys / am 只出现在设备层
  all=""
  for f in $TEST_LIB_FILES; do
    if grep -qE '^[ 	]*(dumpsys|am)[ 	]' "$T_ROOT/$f" 2>/dev/null; then all="$all ${f##*/}"; fi
  done
  t_eq "命令位的 dumpsys / am 只在设备层" "[$all]" "[ device.sh]"

  # fd 加固逐处一致（判据只用「命令位」的正则，不绑行首缩进——
  # `for tid in $ids; do am stack remove …; done` 里的 am 同样是命令位，行首判据会漏掉它）：
  #   ① am 的命令位恰好 3 处（开页 1 + 循环里 2）；
  #   ② dumpsys 的命令位恰好 1 处（_dumpsys 里那一处，子命令按原样透传）；
  #   ③ dumpsys 那一处带 `</dev/null`——它的 stdout 是调用方要的内容，不做 >/dev/null。
  n_am=$(grep -cE 'do[ 	]+am[ 	]|^[ 	]*am[ 	]' "$T_ROOT/lib/device.sh" 2>/dev/null)
  t_eq "am 命令位共 3 处（开页 1 + 移除任务 2）" "${n_am:-0}" "3"
  n_dump=$(grep -cE '^[ 	]*dumpsys[ 	]' "$T_ROOT/lib/device.sh" 2>/dev/null)
  t_eq "dumpsys 命令位只出现一次（_dumpsys 那一处）" "${n_dump:-0}" "1"
  bad=$(grep -nE '^[ 	]*dumpsys[ 	]' "$T_ROOT/lib/device.sh" 2>/dev/null \
        | grep -vcF -e '</dev/null')
  t_eq "设备层的 dumpsys 命令逐处带 </dev/null（stdin 加固）" "${bad:-0}" "0"
  # 子命令按原样透传：只写 "$1" 时 `dumpsys activity activities` 会退化成 `dumpsys activity`
  t_has "dumpsys 的参数原样透传（不丢第二个子命令）" "$T_ROOT/lib/device.sh" 'dumpsys "$@"'
  # am 的加固是「结尾那一段」——去掉 >/dev/null 2>&1 或去掉 </dev/null 都会在这里报红
  t_has "am 开页命令以 $DV_HARDEN 收尾" "$T_ROOT/lib/device.sh" \
    "-d \"\$PAGE\" --ei src 202 $DV_HARDEN"
  t_has "am 移除任务以 $DV_HARDEN 收尾" "$T_ROOT/lib/device.sh" \
    "am stack remove \"\$tid\" $DV_HARDEN"

  # 系统命令不止 am / dumpsys：唤醒与熄屏用的 input / wm 也必须逐处加固（验收项的第 3 条），
  # 它们的调用点在 keepalive 层——这条判据跨层守住「加固一致」这件事本身。
  n_sys=$(grep -cE '^[ 	]*(input|wm)[ 	]' "$src" 2>/dev/null)
  bad=$(grep -nE '^[ 	]*(input|wm)[ 	]' "$src" 2>/dev/null \
        | grep -vcF -e "$DV_HARDEN")
  t_eq "input / wm 调用逐处带 $DV_HARDEN" "${bad:-0}" "0"
  t_eq "input / wm 调用确实存在（上面那条不是空转）" "${n_sys:-0}" "2"

  # 变量承接是「不接管道」的实现手段：dumpsys 的输出只能进变量
  t_has "dumpsys 输出进变量而不是就地接管道" "$T_ROOT/lib/device.sh" '_dumpsys() {'
  t_has "调用点同样只做命令替换" "$T_ROOT/lib/device.sh" 'out=$(_dumpsys power)'
}

# ---- 注册（顺序即执行顺序） ----

t_case "device · 屏幕状态判定（失败按亮屏处理）" dv_case_screen
t_case "device · 前端任务枚举" dv_case_tasks
t_case "device · 打开 / 移除打卡页" dv_case_pages
t_case "device · 清理不彻底留在后台" dv_case_close_residual
t_case "device · 设备命令替身存活（防断言空转）" dv_case_seam_liveness
t_case "device · 两条时序不变量（提前关页 / 不提前关页）" dv_case_timing
t_case "device · 能力收口与 fd 加固（静态）" dv_case_boundary