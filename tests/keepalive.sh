# ============================================================
# keepalive 层验收断言：保活窗口、刷新三段、保活四态
#
# 三条口径：
#   1) 窗口：保活时段 [07:00, 21:25]，六个时点逐点断言——守护循环 60 秒一跳，
#      边界错一分钟就是一整天的节拍错位；
#   2) 刷新三段（静默开页 → 唤醒重试 → 收尾）：两条时序不变量在这里被**跨段**钉住
#      （拿到新 token 就立刻移除打卡页、拿不到就不提前关页）；驱动只注入 token 来源与
#      sleep，open_page / close_page / screen_is_on 全跑真实实现，断言数的是它们实际
#      发出的 am / input / dumpsys 条数；
#   3) 保活策略：15 分钟节流、失败后 30 分钟刷新冷却、亮屏延后、熄屏静默刷新、不唤醒。
#
# 加载：直接 source 真实层文件；时间走「墙钟 + _now 替身」两条路——窗口判定读
# MOCK_DATE_CTL，节流与冷却读 _now 替身给的 %s。预警排在开页之前由 tests/notify.sh 守着。
# ============================================================

KA_WORK="$T_WORK_ROOT/keepalive"

# 夹具日期：拨钟的墙钟与 %s 的 EPOCH 都从这一天出发（同 tests/signin.sh）
KA_DATE='2026-10-01'
KA_EPOCH=0

# 路径一律用**相对路径**（驱动先 cd 到 $KA_WORK 再运行）：Windows 的 D:/ 喂进被测代码
# 会变成残缺路径（见 tests/state.sh 的说明），而运行时用的是手机上的绝对路径。
KA_MODDIR="./mod"
KA_BIN="./bin"
KA_BB="./bin/bb"
KA_DEV="./dev"
KA_CTL="./ctl"

# 清不掉的残留活动记录（与 tests/device.sh 同一份夹具）：每条记录里有两处任务号，
# 于是「关一次页」= 2 条记录 × 2 个任务号 × 2 轮 = 8 条 am stack remove、4 次 dumpsys。
# 关页次数因此可以从设备命令替身的记录里精确读出来。
KA_RECS_A='* ActivityRecord{aa11 t123 u0 cn.edu.fafu.iportal/xxx t42}'
KA_RECS_B='* ActivityRecord{bb22 t456 u0 cn.edu.fafu.iportal/yyy t7}'

# ---- 夹具日期与零点（真实 busybox 取，绕开 mock 时钟） ----
ka_epoch() {
  local bb
  bb=$(t_find_busybox)
  [ -n "$bb" ] || bb="busybox"
  KA_EPOCH=$("$bb" date -d "$KA_DATE 00:00:00" +%s 2>/dev/null | tr -dc '0-9')
  [ -n "$KA_EPOCH" ] || KA_EPOCH=0
}

# 拨钟到当日第 $1 分钟：墙钟（窗口判定）与 EPOCH（节流 / 冷却）一起对齐。
# 只改控制文件，驱动在运行时读它——同一条用例因此可以在一个进程里连拨几次。
ka_at() {
  local m h
  m=$((${1:-0}))
  h=$((m / 60)); m=$((m % 60))
  printf '%s %02d:%02d\n' "$KA_DATE" "$h" "$m" > "$KA_WORK/ctl/date"
}

# 每个用例自备工作目录：替身 busybox + 设备命令替身（am / input / wm / dumpsys）+ 模块目录。
# dv_tools 由 tests/device.sh 定义（用例文件名 device.sh 排在 keepalive.sh 之前）。
ka_setup() {
  KA_WORK="$T_WORK_ROOT/keepalive-$1"
  rm -rf "$KA_WORK"
  mkdir -p "$KA_WORK/mod" "$KA_WORK/bin" "$KA_WORK/dev" "$KA_WORK/ctl" "$KA_WORK/ld"
  t_bb_wrap "$KA_WORK/bin/bb" >/dev/null
  DV_WORK="$KA_WORK"
  dv_tools
  : > "$KA_WORK/ld/token"      # 空的 localStorage 文件 = 应用里没有 token
  printf '0\n' > "$KA_WORK/dev/rc"
  : > "$KA_WORK/dev/calls"
  : > "$KA_WORK/ctl/date"
  : > "$KA_WORK/ctl/events"
  : > "$KA_WORK/ctl/refresh"
  printf '1\n' > "$KA_WORK/ctl/rand"
  printf '%s\n' "$KA_RECS_A" "$KA_RECS_B" > "$KA_WORK/dev/activity.txt"
  ka_epoch
  ka_at 420        # 默认 07:00（保活时段起点）；每条用例自己决定要不要拨钟
}

# 驱动脚本的公共前导。两条注意：
#   ① 驱动主体先落临时文件再拼前导（主体从 stdin 读进来，`cat > x` 之后再追加会颠倒）；
#   ② 路径一律相对（驱动先 cd 进工作目录再运行）。
#
# heredoc 的结束符**不加引号**：顶层那些「写入时就该定下来」的值直接展开，
# 需要运行时才算的（\$BB、\$KA_NOW_S 等）写成 \$ 留给驱动。
ka_env() {
  cat > "$KA_WORK/_env.sh" <<ENV
PATH='$KA_BIN:/bin:/usr/bin'
BB_OVERRIDE='$KA_BB'
MOCK_DATE_CTL='$KA_CTL/date'
MOCK_DEVICE_DIR='$KA_DEV'
MOCK_RANDOM_CTL='$KA_CTL/rand'
MODDIR='$KA_MODDIR'
# token 目录：LD 只在 api 层加载时取一次。指向一个**只放少量文件**的目录，理由是
# get_token 会把整个目录列出来逐个读——指向工作目录（几十个文件）时，一轮刷新里的
# 三十多次采样会慢到让用例超时。目录里的内容由 ka_tokens 生成：
# 每个 token 一个文件，一个文件就是一个采样点，最后那个文件即最新 token。
LD_DIR='./ld'
PL=20261001
# 通知在保活用例里一律不参与：SU_MODE 为空即「降权不可用」，
# 通知类事件与预警都会静默跳过（开关与阈值本身由配置层给出，本前导不设）
SU_MODE=""
KA_DATE='$KA_DATE'
KA_EPOCH=$KA_EPOCH
KA_NOW_S=$KA_EPOCH
export BB_OVERRIDE MOCK_DATE_CTL MOCK_DEVICE_DIR MOCK_RANDOM_CTL
export MODDIR LD_DIR PL SU_MODE
export KA_DATE KA_EPOCH KA_NOW_S
for _f in $TEST_LIB_FILES; do . "\$T_ROOT/\$_f"; done

# 拔钟：墙钟由 mock 承接（窗口判定读它），%s 由这里的 EPOCH 替身承接（节流 / 冷却读它）
ka_at() {
  _m=\$((\${1:-0}))
  _h=\$((_m / 60)); _m=\$((_m % 60))
  printf '%s %02d:%02d\n' "\$KA_DATE" "\$_h" "\$_m" > ctl/date
  KA_NOW_S=\$((KA_EPOCH + \${1:-0} * 60))
}
_now() {
  [ "\$1" = "+%s" ] && { printf '%s' "\$KA_NOW_S"; return 0; }
  "\$BB" date "\$@"
}
# 一条用例里连拨几次钟：读一个不断增长的偏移（拨钟步长写死 1 分钟足够用）
ka_tick() {
  _n=\$(cat ctl/step 2>/dev/null); _n=\$(( \${_n:-420} + 1 ))
  printf '%s\n' "\$_n" > ctl/step
  ka_at "\$_n"
}
# 网络替身：退出码与响应体都由 ctl/ 下的文件给（用例自己写），并记录 URL 与 Authorization
# 两样——「本次刷新后用的是哪个 token」就看记录的 Authorization 里带的是谁。
http_post() {
  printf '%s | %s\n' "\$1" "\$2" >> ctl/api.calls
  cat ctl/body 2>/dev/null
  _rc=\$(cat ctl/rc 2>/dev/null | tr -dc '0-9')
  return "\${_rc:-0}"
}
# 观察面：哪些通知事件被报了、哪次刷新真的去开了页。
# 通知正文 / tag / 降权链路由 tests/notify.sh 断言，这里只关心「业务层报了哪个事件名」。
notify_event() { printf '%s\n' "\$1" >> ctl/events; return 0; }
notify_once()  { printf '%s\n' "\$1" >> ctl/events; return 0; }
# 保活里那条刷新同样走**真实 refresh_token**，token 来源就是 ld/ 里那串按序生长的文件
# （见 ka_tokens）：不 stub 被测对象，时序才数得准。
# 睡眠替身：本机不要真的等（轮询间隔与预警提前量都走它）
sleep() { :; }

# 把一串 token 写进 <目录>/：一个文件一个采样点，**mtime 递增**（get_token 用 ls -tr 按它
# 排序），于是第 N 次采样读到的就是第 N 个值 —— 与设备上「每次免密登录覆盖写入新 token」
# 同形。目录名由用例给：同一条用例里要表达「中途才换 token」时，靠切换 LD 指向另一份夹具
# （同一目录会被整份重建，表达不了「中途才变」）。
# 它是驱动侧的工具，故写进这段前导而不是用例文件里。
# 空串表示那个采样点还没拿到新 token（0 字节文件，不产出任何匹配）。
# 写入的内容**带上 2_ 前缀**（真实形态是 2_<32位十六进制>），于是调用方手里的
# 「旧 token」与 get_token 返回的是同一个串，比较才有意义。
#
# mtime 用递增的**日期**写死（touch -t），不靠真实时钟：一次刷新要 30 多个采样点，
# 每个都 sleep 一秒的话用例会慢到不可用。必须是「日期级」的步长（YYYYMMDD，一天一档）：
# 用 hhmm 当计步器会进位错位——+100 分钟在文本上只加了 1 小时，第 3 个文件反而比第 2 个
# 早（ld 里最后读到的反而仍是第 2 个值）。
# 采样点因此不必写满：同目录里后面的值天然比前面的新，够表达「第 N 次采样读到第 N 个值」。
ka_tokens() { # \$1=目录名（如 ld1） \$2…=采样值序列（"2_DEAD" / "2_BEEF" / ""）
  _d="\$1"
  shift
  _v=""
  _i=0
  rm -rf "\$_d"
  mkdir -p "\$_d"
  for _v in "\$@"; do
    _i=\$((_i + 1))
    if [ -n "\$_v" ]; then
      printf '"token":"%s"' "\$_v" > "\$_d/t\$_i"
    else
      : > "\$_d/t\$_i"
    fi
    touch -t "\$((202601010000 + _i * 10000))" "\$_d/t\$_i" 2>/dev/null
  done
}
ENV
}

# 跑一个驱动脚本；用法：ka_run <名字>，主体从 stdin 读入（公共前导自动接在前面）
ka_run() {
  local name
  name="$1"
  cat > "$KA_WORK/_body.sh"
  cp "$KA_WORK/_env.sh" "$KA_WORK/$name.sh"
  cat "$KA_WORK/_body.sh" >> "$KA_WORK/$name.sh"
  ( cd "$KA_WORK" && $(t_sh) "./$name.sh" ) > "$KA_WORK/$name.out" 2> "$KA_WORK/$name.err"
  if [ -s "$KA_WORK/$name.err" ]; then
    echo "  （驱动 $name 的 stderr）"
    sed 's/^/    /' "$KA_WORK/$name.err"
  fi
}

# 从驱动输出里取一行（形如 key=value）。用 cut 而不是 sed：sed 的替换串里 & 会展开成
# 整个匹配（键名恰好含 & 或模式不匹配时会把整行吐回来），cut 没有这层语义。
ka_val() { # $1=文件 $2=键
  grep "^$2=" "$1" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '\r\n'
}

# 日志里有多少行含某个**字面量**片段（用 -F 字面量 + LC_ALL=C 的字节匹配：
# 本机 zh_CN.UTF-8 下 busybox grep 匹配不上多字节字符，而 -F 字面量在字节层面
# 仍然可用；片段取纯 ASCII 的（如 ❌ 换成「失败」），跨机器最稳）。
# 用途：断言某条中文文案对应的**分支**真的走到了。
ka_log() { # $1=日志 $2=字面量片段
  local n
  n=$(LC_ALL=C grep -acF -e "$2" "$1" 2>/dev/null)
  n=$(printf '%s' "$n" | tr -dc '0-9')
  printf '%s' "${n:-0}"
}

# 把日志里含某个**字面量标记**的**近 $3 条**抓到 $1（默认取最后 4 条）。
# 中文文案的逐字断言打在这个小窗口上：窗口小，既够用也不会被历史行干扰。
ka_near() { # $1=输出文件 $2=字面量标记 $3=最多几条（默认 4）
  LC_ALL=C grep -aF -e "$2" "$KA_WORK/mod/fafu_checkin.log" 2>/dev/null \
    | tail -n "${3:-4}" > "$1" 2>/dev/null
}

# 设备命令替身的记录里，某个参数序列出现了几次
ka_dev() { # $1=形如 '|am|start|'
  grep -cF -e "$1" "$KA_WORK/dev/calls" 2>/dev/null
}

# 某个函数体里的**裸命令**调用次数（只取函数体：从 "<名>()" 行到下一个行首 } 为止）。
# 只认「行首缩进 + 函数名 + 行尾」这种不带参数的真实调用形状：注释里提到的名字
# （名后还有别的内容）、带参数的调用、以及以 $ 起头的变量替换都不算。
#
# 两个必须的写法（任一处写错都会让这条断言变成假的）：
#   ① 模式里的 [[:space:]] 是**字符类**；若把它放进双引号外的变量再拼进模式，当前目录
#      恰好有同名文件时会被 glob 展开成文件名，正则随之失效 → 先 set -f 关掉通配；
#   ② 局部变量不要叫 t：本用例的驱动里 t 另有含义，改名省得日后互相踩。
ka_calls() { # $1=函数名 $2…=目标名
  local seg _t _n
  seg="$KA_WORK/seg.txt"
  sed -n "/^$1()/,/^}/p" "$T_ROOT/lib/keepalive.sh" > "$seg"
  shift
  _n=0
  set -f
  for _t in "$@"; do
    _n=$((_n + $(grep -cE "^[[:space:]]+$_t[[:space:]]*$" "$seg" 2>/dev/null)))
  done
  set +f
  printf '%s' "$_n"
}

# 同上，但取的是**整段函数体文本**（供 t_has 做「带参数的命令确实在这一段里」这类断言）
ka_body() { # $1=函数名 → 输出该函数体
  sed -n "/^$1()/,/^}/p" "$T_ROOT/lib/keepalive.sh"
}

# ============================================================
# 一、保活窗口的四条边界（06:59 / 07:00 / 21:25 / 21:30）
#
# 守护循环每 60 秒跳一次，窗口与当前时刻是**分钟对齐**比较的：早一分钟会开始保活、
# 晚一分钟会整天空转，所以四条边界各钉一个点。
# ============================================================

ka_case_window() {
  local d
  ka_setup window
  ka_env
  ka_run window <<'DRIVER'
# 只替换时钟读数：窗口判定不碰网络与设备（它是纯判定），因此没有别的注入。
# 循环变量不能叫 _m：ka_at 内部也用它，赋值会把序号冲掉（键名只剩后两位）
for _wm in 419 420 1284 1285 1286 1290; do
  ka_at "$_wm"
  if ka_in_window; then _r=in; else _r=out; fi
  printf 'm%s=%s\n' "$_wm" "$_r"
done
printf 'min_at_1285=%s\n' "$(ka_at 1285; now_minutes)"
# 换一份配置（保活时段 08:00–20:00，走真实的配置文件与加载函数）：同一批边界随之平移
printf 'KA_START=08:00\nKA_END=20:00\n' > mod/fafu-checkin.conf
cfg_load
for _wm in 419 479 480 1199 1200; do
  ka_at "$_wm"
  if ka_in_window; then _r=in; else _r=out; fi
  printf 's%s=%s\n' "$_wm" "$_r"
done
DRIVER
  d="$KA_WORK/window.out"
  # 上界**不含**：默认时段 07:00~21:25 里那一分钟起就不再保活（判据必须写成 `-lt`，
  # 这条断言就是防止「顺手写成 -le」把每个夜里的接口调用多打一次）。
  t_eq "06:59 → 窗口外（还没到 07:00）" "$(ka_val "$d" m419)" "out"
  t_eq "07:00 → 窗口内（起点含）" "$(ka_val "$d" m420)" "in"
  t_eq "21:24 → 窗口内（上界的最后一分钟）" "$(ka_val "$d" m1284)" "in"
  t_eq "21:25 → 窗口外（上界不含）" "$(ka_val "$d" m1285)" "out"
  t_eq "21:26 → 窗口外" "$(ka_val "$d" m1286)" "out"
  t_eq "21:30 → 窗口外（交回签到时段）" "$(ka_val "$d" m1290)" "out"
  t_eq "窗口判定的基准是当日第几分钟（拨钟真的生效）" "$(ka_val "$d" min_at_1285)" "1285"
  # 配置化之后，同一批判定点必须跟着配置平移（喂的是真实的配置文件 + cfg_load）
  t_eq "换配置后 06:59 → 窗口外（新起点 08:00）" "$(ka_val "$d" s419)" "out"
  t_eq "换配置后 07:59 → 窗口外" "$(ka_val "$d" s479)" "out"
  t_eq "换配置后 08:00 → 窗口内（新起点含）" "$(ka_val "$d" s480)" "in"
  t_eq "换配置后 19:59 → 窗口内（新上界的最后一分钟）" "$(ka_val "$d" s1199)" "in"
  t_eq "换配置后 20:00 → 窗口外（新上界不含）" "$(ka_val "$d" s1200)" "out"
}

# ============================================================
# 二、刷新三段的两条时序不变量（跨段）
#
# 驱动只注入 token 来源与 sleep：open_page / close_page / screen_is_on 全跑真实实现，
# 它们发出的 am / input / dumpsys 由设备命令替身记录。于是「关页发生在第几次采样之后」
# 「唤醒与熄屏发生在哪一段」都可以被直接观察到。
# ============================================================

ka_case_refresh_phases() {
  local d
  ka_setup phases
  ka_env
  ka_run phases <<'DRIVER'
# token 来源就是 ld/ 里那串按序生长的文件（真实 get_token），本用例只注入 sleep。
# LD_DIR 只在 api 层加载时取一次，故换目录靠改 LD（api 层读的就是这个变量）。
removes() { grep -c '|am|stack|remove' dev/calls 2>/dev/null; }
opens()   { grep -c '|am|start|' dev/calls 2>/dev/null; }
dumps()   { grep -c '|dumpsys|activity|activities' dev/calls 2>/dev/null; }
wakes()   { grep -c '|input|keyevent|224' dev/calls 2>/dev/null; }
offs()    { grep -c '|input|keyevent|223' dev/calls 2>/dev/null; }
away()    { grep -c '|wm|dismiss-keyguard' dev/calls 2>/dev/null; }
# ---- ① 熄屏 + 静默轮询拿不到：唤醒重试期间 token 才变 ----
# 两份夹具：静默段读只含旧 token 的那份（ld1），唤醒重试段起改读含新 token 的（ld2）。
# 计数必须落在**文件**上：refresh_token 在 $( ) 子 shell 里跑，sleep 里改的变量连
# 同一段轮询都出不去（切换永远不发生，静默段看起来像"一采样就成功"）。
printf 'mWakefulness=Asleep\n' > dev/power.txt
ka_tokens ld1 2_DEAD
ka_tokens ld2 2_BEEF
LD='./ld1'
: > ctl/sleeps
sleep() {
  n=$(cat ctl/sleeps 2>/dev/null); n=$(( ${n:-0} + 1 )); printf '%s\n' "$n" > ctl/sleeps
  [ "$n" -ge 30 ] && LD='./ld2'
}
: > dev/calls
printf 'r1=%s\n' "$(refresh_token 2_DEAD 1)"
printf 'opens1=%s\n' "$(opens)"
printf 'removes1=%s\n' "$(removes)"
printf 'wake1=%s\n' "$(wakes)"
printf 'away1=%s\n' "$(away)"
printf 'off1=%s\n' "$(offs)"

# ---- ② 熄屏 + 第三次采样就拿到新 token：提前关页一次 + 收尾关页一次，全程不唤醒 ----
LD='./ld3'
ka_tokens ld3 2_DEAD 2_DEAD 2_BEEF
: > dev/calls
mark=$(grep -c . mod/fafu_checkin.log)
printf 'r2=%s\n' "$(refresh_token 2_DEAD 1)"
printf 'opens2=%s\n' "$(opens)"
printf 'removes2=%s\n' "$(removes)"
printf 'dumps2=%s\n' "$(dumps)"
printf 'wake2=%s\n' "$(wakes)"
printf 'off2=%s\n' "$(offs)"
# 日志断言只取 ASCII 片段（中文文案那半句由用例侧打在**本段窗口**上）：
# 本机 zh_CN.UTF-8 下 busybox grep 匹配不上中文，直接 grep 中文会得到 0 处。
tail -n +$((mark + 1)) mod/fafu_checkin.log > ctl/early.log 2>/dev/null
printf 'log2=%s\n' "$(grep -c 'token,' ctl/early.log)"
printf 'sec2=%s\n' "$(grep -c '页面关闭检查' ctl/early.log)"

# ---- ③ 亮屏 + 立刻拿到新 token：原为亮着 → 保持不熄屏，也不主动唤醒 ----
printf 'mWakefulness=Awake\n' > dev/power.txt
LD='./ld4'
ka_tokens ld4 2_DEAD 2_BEEF
: > dev/calls
mark=$(grep -c . mod/fafu_checkin.log)
printf 'r3=%s\n' "$(refresh_token 2_DEAD 1)"
printf 'wake3=%s\n' "$(wakes)"
printf 'off3=%s\n' "$(offs)"
printf 'log3=%s\n' "$(tail -n +$((mark + 1)) mod/fafu_checkin.log | grep -c '关闭检查')"
tail -n +$((mark + 1)) mod/fafu_checkin.log > ctl/rest.log 2>/dev/null
DRIVER
  d="$KA_WORK/phases.out"
  # ① 静默段整段拿不到（ld1 全是旧 token）→ 唤醒重试段（ld2）第一采样就拿到
  t_eq "① 唤醒重试才拿到新 token：返回它" "$(ka_val "$d" r1)" "2_BEEF"
  t_eq "① 确实进入了唤醒后重试（日志里有刷新未成功→唤醒的那一段）" \
    "$(ka_log "$KA_WORK/mod/fafu_checkin.log" '唤醒屏幕重试')" "1"
  t_eq "① 取不到新 token 时不提前关页（只关一次 = 8 条 am stack remove）" "$(ka_val "$d" removes1)" "8"
  t_eq "① 开页与关页走的是真实设备层（不是 stub）" "$(ka_val "$d" opens1)" "1"
  t_eq "① 唤醒重试真的按了唤醒键（从熄屏醒来）" "$(ka_val "$d" wake1)" "1"
  t_eq "① 唤醒后解了一次锁屏" "$(ka_val "$d" away1)" "1"
  t_eq "② 拿到新 token 后立即关页（提前关 + 收尾关 = 16 条）" "$(ka_val "$d" removes2)" "16"
  t_eq "② 关页读活动记录走的是真实实现（8 次 dumpsys）" "$(ka_val "$d" dumps2)" "8"
  t_eq "② 不再重复开页" "$(ka_val "$d" opens2)" "1"
  t_eq "② 第三次采样就拿到：返回新 token" "$(ka_val "$d" r2)" "2_BEEF"
  t_has "② 提前关页的日志文案不变" "$KA_WORK/ctl/early.log" "已取得新 token，提前移除打卡页（前台交还用户）"
  t_has "② 提前关页只在本段发生一次" "$KA_WORK/ctl/early.log" "已取得新 token，提前移除打卡页（前台交还用户）" "1"
  t_eq "② 屏幕原为关闭：收尾恢复熄屏" "$(ka_val "$d" off2)" "1"
  t_eq "② 熄屏路径不主动唤醒屏幕" "$(ka_val "$d" wake2)" "0"
  t_eq "③ 屏幕原本亮着：保持不熄屏" "$(ka_val "$d" off3)" "0"
  t_eq "③ 屏幕原本亮着也不主动唤醒（只有兜底重试才唤醒）" "$(ka_val "$d" wake3)" "0"
  t_eq "③ 亮屏收尾那一段真的发生（本段有刷新成功 + 收尾关页）" "$(ka_val "$d" log3)" "2"
  t_has "③ 亮屏收尾的日志文案不变" "$KA_WORK/ctl/rest.log" "屏幕原本亮着，保持不熄屏"
}

# ============================================================
# 三、保活四态：token 有效 / 亮屏延后 / 熄屏静默刷新 / 冷却中不再刷新
#
# 断言看的是**外部可观察的行为**：交给系统执行的命令、状态层产物、日志文案——
# 保活统计的读写只经 state 层（用例不碰文件格式）。
# ============================================================

ka_case_ping() {
  local d
  ka_setup ping
  ka_env
  ka_run ping <<'DRIVER'
# token 由 ld/ 里的采样点给出（真实 get_token）；保活里的静默刷新也是真实 refresh_token，
# 「刷新了几次」因此可以从采样点的消费情况看出来。
# 每个阶段换一个**独立的目录**（同目录下 ka_tokens 会整份重建，没法表达「中途才变」）。
LD='./ld1'
ka_tokens ld1 2_C0DE
printf '{"records":[]}\n' > ctl/body
printf '0\n' > ctl/rc

# ---- ① token 有效：只记一行统计，不动任何 token 采样点 ----
# LD 要在**父 shell** 里设：$( ) 里的赋值出不来（表现为 token 恒为空）
printf 'mWakefulness=Awake\n' > dev/power.txt
keepalive_ping
printf 'ok_ok=%s\n'  "$(ka_ok_count)"
printf 'ok_fail=%s\n' "$(ka_fail_count)"
printf 'ok_last=%s\n' "$(ka_last_result)"
printf 'ok_tok=%s\n' "$(get_token)"

# ---- ② 调用失败 + 亮屏：延后，不刷新（白天不无解释地弹页面）----
printf '1\n' > ctl/rc
keepalive_ping
printf 'on_fail=%s\n' "$(ka_fail_count)"
printf 'on_tok=%s\n' "$(get_token)"

# ---- ③ 调用失败 + 熄屏：静默刷新，冷却基准同时推进 ----
# 换成带新 token 的采样目录：刷新若真的发生，轮询会读到它
printf 'mWakefulness=Asleep\n' > dev/power.txt
LD='./ld2'
ka_tokens ld2 2_C0DE 2_DEAD 2_BEEF
keepalive_ping
printf 'off_fail=%s\n' "$(ka_fail_count)"
printf 'off_token=%s\n' "$(grep -c 'token=2_BEEF' mod/fafu_keepalive.status)"

# ---- ④ 同一秒内再次失败：30 分钟冷却挡住，不再刷新（采样点不会再被消费）----
# 冷却基准是保活自己的变量：它在 $( ) 子 shell 里被推进，跨调用留不住（现状如此，
# 本次只保证策略不变）。这里把上一轮推进后的基准摆回来，等价于"下一分钟又失败一次"。
# 判据只看「这轮有没有真的去刷新」——采样目录与上一轮是同一份，没法再当证据。
LD='./ld3'
ka_tokens ld3 2_C0DE 2_DEAD 2_BEEF
KA_LAST_REFRESH=$(now_s)
mark=$(grep -c . mod/fafu_checkin.log)
keepalive_ping
printf 'cold_fail=%s\n' "$(ka_fail_count)"
printf 'cold_refresh=%s\n' "$(tail -n +$((mark + 1)) mod/fafu_checkin.log | grep -c '尝试静默刷新')"
printf 'cold_seen=%s\n' "$(get_token)"
# 保活那几行日志抓成窗口：中文文案的逐字断言打在这个小窗口上（grep 匹配不上中文）
LC_ALL=C grep -aF -e '保活' mod/fafu_checkin.log > ctl/ka.log 2>/dev/null
DRIVER
  d="$KA_WORK/ping.out"
  t_eq "① token 有效：不刷新（采样点原封不动）" "$(ka_val "$d" ok_tok)" "2_C0DE"
  t_eq "① token 有效：记一次成功（经状态层）" "$(ka_val "$d" ok_ok)" "1"
  t_eq "① token 有效：失败数不变" "$(ka_val "$d" ok_fail)" "0"
  t_eq "① token 有效：最近结果为 ok" "$(ka_val "$d" ok_last)" "ok"
  t_eq "② 亮屏失败：延后，不刷新" "$(ka_val "$d" on_tok)" "2_C0DE"
  t_eq "② 亮屏失败：仍记一次失败" "$(ka_val "$d" on_fail)" "1"
  t_eq "③ 熄屏失败：失败计数累加" "$(ka_val "$d" off_fail)" "2"
  t_eq "③ 静默刷新成功后的 token 经状态层落盘" "$(ka_val "$d" off_token)" "1"
  t_eq "④ 冷却中：不再刷新（这轮没有去开页）" "$(ka_val "$d" cold_refresh)" "0"
  # 采样目录没被动过，读到的最新 token 仍是夹具里最后写下的那个
  t_eq "④ 冷却中：采样点没被消费（读到的仍是夹具最新值）" "$(ka_val "$d" cold_seen)" "2_BEEF"
  t_eq "④ 冷却中：失败仍照记" "$(ka_val "$d" cold_fail)" "3"
  t_eq "④ 冷却中给出可读的原因（那一行仍记了失败）" "$(ka_log "$KA_WORK/ctl/ka.log" '失败')" "4"
  # ③ 的静默刷新已把状态文件里的 token 换成新的（2_BEEF），故 ④ 这一轮读到的是它
  t_has "④ 冷却中的日志文案不变" "$KA_WORK/ctl/ka.log" "保活: ❌ 2_BEEF 调用失败 (今日 1 成功 / 3 失败) — 刷新冷却中，稍后再试"
}

# 保活统计与日志文案（对外契约）：成功 / 失败两条各自逐字断言。
# 统计的读写只经 state 层，日志文案里的数字取自同一处读数。
ka_case_stat_line() {
  local d
  ka_setup stat
  ka_env
  ka_run stat <<'DRIVER'
# 每段一份**单点**夹具：get_token 取的是时间最新的那份，一个快照就不必猜顺序
LD='./ld'
ka_tokens ld1 2_C0DE
LD='./ld1'
printf '{"records":[]}\n' > ctl/body
printf '0\n' > ctl/rc
printf 'mWakefulness=Awake\n' > dev/power.txt
keepalive_ping
printf '1\n' > ctl/rc
printf 'mWakefulness=Asleep\n' > dev/power.txt
LD='./ld2'
ka_tokens ld2 2_DEAD
keepalive_ping
DRIVER
  d="$KA_WORK/stat.out"
  # 日志里的中文文案不能直接 grep（见 ka_log 的说明）：先用 ASCII 标记把「保活」那两行
  # 抓成小窗口，再对窗口逐字比对——文案是使用者可见的对外契约，必须逐字。
  ka_near "$KA_WORK/ctl/ka.log" "保活" 5
  t_has "保活成功的日志文案（含今日成功/失败数）" "$KA_WORK/ctl/ka.log" \
    "保活: ✅ 2_C0DE token 有效 (今日 1 成功 / 0 失败)"
  t_has "保活失败的日志文案（不可区分网络异常，故只报调用失败）" "$KA_WORK/ctl/ka.log" \
    "保活: ⚠️ 2_DEAD 调用失败 (今日 1 成功 / 1 失败) — 尝试静默刷新"
}

# ============================================================
# 四、15 分钟节流（可拨钟）：到点即执行，节流窗内不动
#
# 节流基准 KA_LAST 是守护主循环里的一个变量（a 60 秒一跳的循环逐轮比较），
# 故这里比的是**判定本身**：基准为 0（刚起进程）必须立刻执行。
# ============================================================

ka_case_throttle() {
  local d
  ka_setup throttle
  ka_env
  ka_run throttle <<'DRIVER'
# 起点：07:00，基准为 0（守护进程刚起来）。
# 退出码必须先落变量再打印——`$(cmd; echo $?)` 里 $? 拿到的是 echo 自己的状态（恒 0）
ka_at 420
ka_due "$KA_NOW_S"; printf 'first=%s\n' "$?"
KA_LAST=$KA_NOW_S
printf 'last=%s\n' "$((KA_LAST - KA_EPOCH))"
# 07:14 → 距上次 14 分钟：节流窗内
ka_at 434
ka_due "$KA_NOW_S"; printf 'at14=%s\n' "$?"
# 07:15 → 距上次 15 分钟整：到点即执行
ka_at 435
ka_due "$KA_NOW_S"; printf 'at15=%s\n' "$?"
# 21:25 已出保活窗口（上界不含），但节流判定本身照旧成立
ka_at 1285
ka_in_window; printf 'inwin=%s\n' "$?"
ka_due "$KA_NOW_S"; printf 'due_at_end=%s\n' "$?"
DRIVER
  d="$KA_WORK/throttle.out"
  t_eq "从未保活过（基准 0）：立刻执行" "$(ka_val "$d" first)" "0"
  t_eq "基准落在拨钟时刻（07:00）" "$(ka_val "$d" last)" "25200"
  t_eq "距上次 14 分钟：节流窗内不动" "$(ka_val "$d" at14)" "1"
  t_eq "距上次 15 分钟整：到点即执行" "$(ka_val "$d" at15)" "0"
  t_eq "节流之外窗口仍成立且上界不含 21:25（两条判定各自独立）" "$(ka_val "$d" inwin)" "1"
  t_eq "同一时刻节流判定本身仍为「到期」" "$(ka_val "$d" due_at_end)" "0"
}

# ============================================================
# 五、静态边界：刷新流程确实是三段、保活策略只有一处、窗口判定来自 keepalive 层
# ============================================================

ka_case_boundary() {
  local src f n
  ka_setup boundary          # 先备好工作目录：ka_calls 的中间文件放在 KA_WORK 里
  src="$KA_WORK/program.sh"
  t_write_program "$src" || { _t_fail "无法拼出全程序文本"; return 0; }

  # 三段各自的函数定义都在 keepalive 层（改名会在这里报红）
  for f in refresh_silent refresh_wake refresh_finish; do
    t_has "刷新三段：$f 定义在 keepalive 层" "$T_ROOT/lib/keepalive.sh" "$f() {"
  done
  # 防空转守卫：下面一批「0 处」断言的前提是 ka_calls 真的抽到了函数体；
  # 抽不到时它会静默返回 0，那些断言就变成永远为真的摆设（最危险的方向是假绿）。
  # 抽不到就明确失败并退出本用例，与 tests/device.sh 对 t_write_program 的处理同形。
  for f in refresh_silent refresh_wake refresh_finish refresh_token; do
    [ -n "$(ka_body "$f")" ] || {
      _t_fail "抽不到 $f 的函数体（改名或定义写法变了），本用例的「0 处」断言不可信"
      return 0
    }
  done
  # 页面动作各归其段（判据按**函数体**取词，不绑行号，搬代码不会假红）：
  # 开页只在第一段；关页有两处——一处是 refresh_token 里「一拿到新 token 就提前移除
  # 打卡页」的时序动作，一处是第三段收尾的兜底关页；第二段（唤醒重试）不碰页面。
  t_eq "第一段负责开页" "$(ka_calls refresh_silent open_page)" "1"
  t_eq "第一段不碰页面清理" "$(ka_calls refresh_silent close_page)" "0"
  t_eq "第二段（唤醒重试）不开关页" "$(ka_calls refresh_wake open_page close_page)" "0"
  t_eq "第三段收尾关页" "$(ka_calls refresh_finish close_page)" "1"
  t_eq "第三段不重新开页" "$(ka_calls refresh_finish open_page)" "0"
  t_eq "提前关页挂在 refresh_token 上（拿到新 token 就地移除）" \
    "$(ka_calls refresh_token close_page)" "1"
  t_eq "refresh_token 不会再开一次页" "$(ka_calls refresh_token open_page)" "0"
  # 唤醒键与熄屏键都带参数，用「整段里出现这条命令」来判（同样不绑行号）
  ka_body refresh_finish > "$KA_WORK/seg.finish"
  t_has "第三段按原状态恢复屏幕（熄屏键）" "$KA_WORK/seg.finish" "input keyevent 223"
  ka_body refresh_wake > "$KA_WORK/seg.wake"
  t_has "第二段才发唤醒键" "$KA_WORK/seg.wake" "input keyevent 224"
  t_has "第二段解锁屏" "$KA_WORK/seg.wake" "wm dismiss-keyguard"
  # 页面动作的**命令位**（行首缩进后的调用；函数定义行以 `()` 结尾不会命中）共三处：
  # 开页一次、关页两次。用 -F 字面量数，避开本机 grep -E 的字符类不稳（见文件头）。
  n=$(grep -cF -e '  open_page' "$T_ROOT/lib/keepalive.sh")
  n=$((n + $(grep -cF -e '  close_page' "$T_ROOT/lib/keepalive.sh")))
  t_eq "全层的页面动作为三个命令位（开页 1 + 关页 2）" "${n:-0}" "3"

  # 保活时段判定只有一处，且在 keepalive 层：入口不再内联 420 / 1285 这两个魔数
  t_has "窗口判定收口在 keepalive 层" "$T_ROOT/lib/keepalive.sh" 'ka_in_window() {'
  t_hasnt "入口不再内联窗口下界魔数" "$T_ROOT/fafu_checkin.sh" '$now -ge 420'
  t_hasnt "入口不再内联窗口上界魔数" "$T_ROOT/fafu_checkin.sh" '$now -lt 1285'
  t_has "入口经 ka_due 判定该不该保活" "$T_ROOT/fafu_checkin.sh" 'ka_due'
  # 上界方向本身也是不变量（判据必须是 `-lt`）：顺手写成 `-le` 会让时段末那一分钟
  # 多出一次接口调用，而这种「只差一分钟」的漂移肉眼极难发现。
  t_has "窗口上界是「不含」" "$T_ROOT/lib/keepalive.sh" '[ "$m" -lt "$e" ]'
  # 时段钟点只许来自配置层：层里不再有写死的分钟数（420 / 1285 的搬家已完成）
  t_hasnt "窗口下界不再写死分钟数" "$T_ROOT/lib/keepalive.sh" '420'
  t_hasnt "窗口上界不再写死分钟数" "$T_ROOT/lib/keepalive.sh" '1285'
  t_has "窗口下界取自配置层" "$T_ROOT/lib/keepalive.sh" 'cfg_ka_start'
  t_has "窗口上界取自配置层" "$T_ROOT/lib/keepalive.sh" 'cfg_ka_end'

  # 保活场景禁止唤醒屏幕：保活调用刷新时显式传 0，且这条判据只有一处
  t_has "保活刷新显式禁止唤醒屏幕（第二参数 0）" "$T_ROOT/lib/keepalive.sh" 'refresh_token "$tok" 0'
}

# ---- 注册（顺序即执行顺序） ----

t_case "keepalive · 窗口边界（06:59 / 07:00 / 21:25 / 21:30）" ka_case_window
t_case "keepalive · 刷新三段的两条时序不变量" ka_case_refresh_phases
t_case "keepalive · 保活四态（有效 / 亮屏延后 / 熄屏静默 / 冷却）" ka_case_ping
t_case "keepalive · 保活统计与日志文案" ka_case_stat_line
t_case "keepalive · 15 分钟节流（拨钟）" ka_case_throttle
t_case "keepalive · 结构边界（静态）" ka_case_boundary
