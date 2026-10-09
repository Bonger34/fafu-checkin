# ============================================================
# signin 层验收断言：三档返回码、四个判定分支、窗口边界、提交并记录
#
# 三条口径：
#   1) **只断言外部行为**：返回码、状态文件的最终内容、发给 notify 层的**事件名**、
#      日志正文，以及「某个时刻会发生什么」；
#   2) **缝只有两个**（都在运行时既有注入点上）：时间走 `_now` 的替身（拨 EPOCH），
#      网络走 `http_post`（注入响应体 / 退出码）；设备命令不需要缝；
#   3) **边界逐分钟**：窗口判定的基准是「当前时刻（毫秒）」，断言把 EPOCH 拨到
#      21:29 / 21:30 / 22:30 / 22:59 / 23:00 各跑一次 signin_decide，每个时点只比一侧。
#
# 夹具的时间字段是**相对 EPOCH 的偏移**（EPOCH±偏移，读起来就是「开始前 1 分钟」）。
# 加载：直接 source 真实层文件（harness 的 TEST_LIB_FILES，顺序取自入口的 FAFU_LAYERS）。
# 覆盖不到（只能上机目视确认）：接口真实返回体的字段形态、补签时段的服务端行为。
# ============================================================

SG_WORK=""
SG_EPOCH=0             # 2026-10-01 00:00（本地时区的当日零点），由 sg_epoch 算出
SG_DATE='2026-10-01'   # 夹具日期；拨钟的墙钟与 %s 的 EPOCH 都从这一天出发

# 签到与提醒的能力都只有 signin 层定义（能力名 = 函数的唯一真源，改名会在这里报红）
SG_CAPS="state_text:signin run_once:signin signin_fetch:signin signin_parse:signin signin_decide:signin signin_submit:signin signin_ms_hm:signin signin_remind_due:signin signin_remind_30min:signin signin_remind_deadlines:signin signin_notask_target:signin signin_notask_due:signin signin_remind_notask:signin"
# 判定链用**调用形状**钉住，不绑函数体里的行号
SG_CHAIN="out=\$(signin_fetch  signin_parse \"\$resp\"  signin_decide \"\$resp\" \"\$tok\""

# ---- 时钟：把 EPOCH 拨到当日第 $1 分钟 ----
# 零点用真实 busybox 取（绕开 mock），之后每次只改偏移。
# MOCK_DATE_CTL 只影响 %H:%M / %Y-%m-%d 这类展示格式（mock 只认「日期 时间」两个字段，
# 没有秒位），%s 由驱动里的 _now 替身接管 —— 两者都从同一个 EPOCH 出发，不会互相打架。
sg_epoch() {
  local bb
  bb=$(t_find_busybox)
  [ -n "$bb" ] || bb="busybox"
  SG_EPOCH=$("$bb" date -d "$SG_DATE 00:00:00" +%s 2>/dev/null | tr -dc '0-9')
  [ -n "$SG_EPOCH" ] || SG_EPOCH=0
}

# 拨钟到当日第 $1 分钟：墙钟（mock）与 EPOCH（_now 替身）一起对齐
sg_at() {
  local m h
  m=$((${1:-0}))
  h=$((m / 60)); m=$((m % 60))
  printf '%s %02d:%02d\n' "$SG_DATE" "$h" "$m" > "$SG_WORK/ctl/date"
  SG_NOW_S=$((SG_EPOCH + ${1:-0} * 60))
  export SG_NOW_S
}

# ---- 夹具：接口响应体 ----
# 字段形态照抄接口的真实响应（毫秒时间戳、signInStudent.signState），只留决策要读的字段，
# 顺序也与真实响应一致（顶层 id/name/时间/lng/lat，signState 在嵌套对象里）。
# $1=任务开始的分钟偏移 $2=signState $3=补充字段（形如 ,"signTime":123）
# 三个时点照设备上的真实形状取：主窗口 = 开始 ~ 开始+60、补签截止 = 开始+90。
# 于是一天里的关键时刻正好落在夹具的边上：21:29 窗口外 / 21:30 开始 / 22:30 主窗口末 /
# 22:59 补签时段内 / 23:00 补签截止（判定用 -gt，整点仍算窗口内 → 23:01 才出窗口）。
sg_body() {
  local st bt end sup
  st=${2:-0}
  bt=$(( SG_EPOCH * 1000 + ${1:-0} * 60000 ))   # 接口给的是毫秒时间戳
  end=$(( bt + 3600000 ))                       # 主窗口 60 分钟
  sup=$(( bt + 5400000 ))                       # 补签截止 = 开始 + 90 分钟
  printf '{"records":[{"id":88123,"name":"晚查寝签到","beginTime":%s,"supplementEndTime":%s,"endTime":%s,"signInStudent":{"signState":%s},"lng":119.243462,"lat":26.088417%s}]}\n' \
    "$bt" "$sup" "$end" "$st" "${3:-}"
}

# 已签到的夹具：signTime 落在 EPOCH+$2 分钟（断言据此验「记录的时间由 signTime 换算」）
sg_body_seen() { # $1=任务开始偏移 $2=signTime 偏移
  sg_body "$1" 1 ",\"signTime\":$(( SG_EPOCH * 1000 + ${2:-0} * 60000 ))"
}

# 三个时点各自指定的响应体：$1=任务开始分钟 $2=主窗口截止分钟 $3=补签截止分钟
# （sg_body 的三个时点是绑在一起的固定形状；提醒的锚点由任务数据推算，故要能分别摆）
sg_task_span() {
  printf '{"records":[{"id":88123,"name":"晚查寝签到","beginTime":%s,"supplementEndTime":%s,"endTime":%s,"signInStudent":{"signState":0},"lng":119.243462,"lat":26.088417}]}\n' \
    "$(( SG_EPOCH * 1000 + $1 * 60000 ))" \
    "$(( SG_EPOCH * 1000 + $3 * 60000 ))" \
    "$(( SG_EPOCH * 1000 + $2 * 60000 ))"
}

# ---- 工作目录与环境 ----
sg_setup() { # $1=驱动名（决定工作目录）
  SG_WORK="$T_WORK_ROOT/signin-$1"
  rm -rf "$SG_WORK"
  mkdir -p "$SG_WORK/mod" "$SG_WORK/bin" "$SG_WORK/ctl"
  : > "$SG_WORK/ctl/calls"
  : > "$SG_WORK/ctl/events"      # 通知事件的观察面：先建好，断言才读得到「零通知」
  printf '0\n' > "$SG_WORK/ctl/rc"
  printf '0\n' > "$SG_WORK/ctl/rand"   # 签名随机数的替身序号（本机没有 /dev/urandom）
  t_bb_wrap "$SG_WORK/bin/bb" >/dev/null
  sg_epoch
  sg_at 1411        # 默认 23:31（窗口外）；每条用例都会显式拨钟
}

# 驱动脚本的公共前导。两条注意：
#   ① 驱动主体先落临时文件再拼前导（主体是从 stdin 读进来的，`cat > x` 之后再追加会颠倒）；
#   ② 路径一律相对（驱动先 cd 进工作目录再运行）——Windows 的 D:/ 喂进被测代码会残缺。
#
# 这里的 heredoc 用**不带引号**的 ENV 作结束符（定界符本身不加引号）：
# 顶层那些「写入时就该定下来」的值（T_ROOT / 层清单）直接展开；
# 需要在运行时才算的（$BB、$SG_NOW_S 等）写成 \$ 留给驱动。
sg_env() {
  cat > "$SG_WORK/_env.sh" <<ENV
PATH='./bin:/bin:/usr/bin'
BB_OVERRIDE='./bin/bb'
MOCK_DATE_CTL='./ctl/date'
# 网络替身的控制目录在 ctl/；设备命令替身目录同样给上（判到窗口内的用例会真去读屏幕状态）
MOCK_WGET_DIR='./ctl'
MOCK_DEVICE_DIR='./ctl'
MOCK_RANDOM_CTL='./ctl/rand'
MODDIR='./mod'
# token 目录：LD 只在 api 层加载时取一次，这里指向驱动的工作目录（一定存在），
# 于是「取不到 token」不会把判定链挡在门外；「没有应用数据」那一档由用例自己改 LD
LD_DIR='.'
# 等 App 数据就绪时用的 sleep 替身（等待本身要断言的用例自己换掉它：真等 30 秒没有意义）
SLEEP_OVERRIDE="${SLEEP_OVERRIDE:-}"
PL=20261001
NOTIFY=1
SU_MODE=""
SG_DATE='$SG_DATE'
SG_EPOCH=$SG_EPOCH
SG_NOW_S=$SG_NOW_S
export BB_OVERRIDE MOCK_DATE_CTL MOCK_WGET_DIR MOCK_DEVICE_DIR MOCK_RANDOM_CTL
export MODDIR LD_DIR PL NOTIFY SU_MODE SLEEP_OVERRIDE
export SG_EPOCH SG_NOW_S
for _f in $TEST_LIB_FILES; do . "\$T_ROOT/\$_f"; done

# 拔钟：墙钟由 mock 承接，%s 由这里的 EPOCH 承接（签到判定读的就是它）
sg_at() {
  _m=\$((\${1:-0}))
  _h=\$((_m / 60)); _m=\$((_m % 60))
  printf '%s %02d:%02d\n' "\$SG_DATE" "\$_h" "\$_m" > ctl/date
  SG_NOW_S=\$((SG_EPOCH + \${1:-0} * 60))
  export SG_NOW_S
}
_now() {
  [ "\$1" = "+%s" ] && { printf '%s' "\$SG_NOW_S"; return 0; }
  "\$BB" date "\$@"
}
# 网络替身：按 ctl/api.seq 的第 N 行分派（形如「page:rc」「sign:0」），
# 行数不够时回落到 ctl/api.default；响应体从 ctl/body.<app> 读，由驱动自己写。
# 计数必须落在**文件**上：api() 在 $( ) 里调 http_post，变量活在子 shell 里，
# 每次调用都会从第 1 行重新开始（整条序列因此只认第一行的分支，极难发现）。
http_post() {
  _n=\$(cat ctl/seq.n 2>/dev/null); _n=\$(expr "\${_n:-0}" + 1)
  printf '%s' "\$_n" > ctl/seq.n
  # 记录 URL 与 Authorization 两样：token 有没有一路传到提交，就看这行里有没有它
  printf '%s | %s\n' "\$1" "\$2" >> ctl/api.calls
  _m=\$(sed -n "\${_n}p" ctl/api.seq 2>/dev/null)
  # 序列用完 → 先按「上一个用过的档」继续应答（同一类请求的响应体是一样的），
  # 再退到 ctl/api.default（那是「整条链路都不通」的用例用的）
  if [ -z "\$_m" ]; then
    _m=\$(cat ctl/last 2>/dev/null)
    [ -n "\$_m" ] || _m=\$(cat ctl/api.default 2>/dev/null)
  fi
  case "\$_m" in
    *:*) _app="\${_m%%:*}"; _rc="\${_m##*:}" ;;
    *)   _app=page; _rc=0 ;;
  esac
  printf '%s\n' "\$_m" > ctl/last
  cat "ctl/body.\$_app" 2>/dev/null
  # 失败档：像真实 wget 那样给出一句报错，但要落在 api 层的 API_ERRLOG 上——
  # 真机上那句报错是 wget 直接写进这个文件的（api 层读它才拿得到失败原因），
  # 打到 stderr 不等于它会被读到（调用链上没人收 stderr）。
  # 成功档一个字都不吐：真实 wget 成功时也是安静的。
  if [ "\${_rc:-0}" != "0" ]; then
    [ -n "\${API_ERRLOG:-}" ] && cat ctl/wget.err > "\$API_ERRLOG" 2>/dev/null
  fi
  return "\${_rc:-0}"
}
# 观察面：谁被通知了、描述刷没刷新、token 刷没刷新。
# 通知正文与降权链路由 tests/notify.sh 断言，这里只关心「业务层报了哪个事件名」。
notify_event() { printf '%s\n' "\$1" >> ctl/events; return 0; }
notify_once()  { printf '%s\n' "\$1" >> ctl/events; return 0; }
update_desc()  { printf 'desc\n' >> ctl/desc; return 0; }
refresh_token() { printf 'refresh\n' >> ctl/refresh; printf '%s' "\${SG_NEWTOKEN:-}"; }
ENV
}

# 一条「查任务成功 + 提交成功」的序列，也是各用例的默认响应。提交那一档写两行：
# 提交响应里没有 timestamp 时会带着（可能刷新的）token 重试一次，序列只写一行的话
# 第二次提交会落到别的分支上。序列用完时替身按「上一个用过的档」继续应答，
# 所以顺序不是敏感信息——**调用次数**才是。
SG_SEQ_OK='page:0
sign:0
sign:0'
SG_SEQ_LAST='sign:0'

# 提交成功的响应体：服务端用它报错时才会带 timestamp，所以成功体里**没有**它。
# 这条是提交判据的方向标——写反了整套断言会跟着一起反过来。
SG_SIGN_OK='{"code":0,"msg":"success"}'
# 提交失败的响应体：带 timestamp
SG_SIGN_FAIL='{"timestamp":1759500000000,"status":500,"msg":"busy"}'

sg_run() { # $1=名字；主体从 stdin 读入
  local name
  name="$1"
  cat > "$SG_WORK/$name.body"
  sg_env
  cat "$SG_WORK/_env.sh" "$SG_WORK/$name.body" > "$SG_WORK/$name.sh"
  # 每次驱动都从序列第 1 行开始（序列是「这一个驱动内的第 N 次网络调用」，不是全局计数）；
  # 命令行记录、通知事件与回落分支也一起清空——否则上个驱动留下的东西会被算进这一个
  # 驱动，断言就静默变成「看着在跑、实际测的是别的驱动」（这一段不能删）。
  printf '0' > "$SG_WORK/ctl/seq.n"
  : > "$SG_WORK/ctl/api.calls"
  : > "$SG_WORK/ctl/events"
  : > "$SG_WORK/ctl/api.default"
  printf '%s\n' "$SG_SEQ_LAST" > "$SG_WORK/ctl/last"
  ( cd "$SG_WORK" && $(t_sh) "./$name.sh" ) > "$SG_WORK/$name.out" 2> "$SG_WORK/$name.err"
  if [ -s "$SG_WORK/$name.err" ]; then
    echo "  （驱动 $name 的 stderr）"
    sed 's/^/    /' "$SG_WORK/$name.err"
  fi
}

# 从驱动输出里取一行（形如 key=value）
sg_val() { # $1=文件 $2=键
  sed -n "s/^$2=//p" "$1"
}

# 状态文件的某个字段（未写入时为空串）
sg_status() { # $1=键
  sed -n "s/^$1=//p" "$SG_WORK/mod/fafu_checkin.status" 2>/dev/null
}

# 日志正文：去掉行首的 [2026-10-01 21:30:00] 时间戳，只比对文案本身。
# 用行首锚点而不是固定列宽：换日期格式、换时区都不会让断言假红。
sg_log() {
  tail -n 1 "$SG_WORK/mod/fafu_checkin.log" 2>/dev/null | sed 's/^\[[^]]*\][ ]*//'
}

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
  t_eq "已签到：记录类型是 detected" "$(sg_status sign_kind)" "detected"
  t_eq "已签到：记录日期是今天" "$(sg_status sign_date)" "$SG_DATE"
  t_eq "已签到：刷新了模块描述" "$(sg_val "$d" desc)" "1"
  t_eq "已签到：只查一次任务（不再提交）" "$(sg_val "$d" calls)" "1"
  t_eq "已签到：没有任何提交请求" "$(sg_val "$d" signreq)" "0"
  t_file "已签到：签到记录文件确实生成" "$w"
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
  local d
  sg_setup failed
  sg_at 1290
  sg_body 1290 0 > "$SG_WORK/ctl/body.page"
  # 服务端拒绝：请求发出去了、响应体里带 timestamp（那是服务端报错的标志）。
  # 网络失败那条路径在第六节（调用本身非 0）。
  printf '%s\n' "$SG_SEQ_OK" > "$SG_WORK/ctl/api.seq"
  printf '%s\n' "$SG_SIGN_FAIL" > "$SG_WORK/ctl/body.sign"
  sg_run failed <<'DRIVER'
run_once; printf 'rc=%s\n' "$?"
printf 'events=%s\n' "$(tr '\n' ',' < ctl/events 2>/dev/null)"
printf 'desc=%s\n'   "$(grep -c . ctl/desc 2>/dev/null || echo 0)"
DRIVER
  d="$SG_WORK/failed.out"
  t_eq "提交失败：返回 1（下一分钟重试）" "$(sg_val "$d" rc)" "1"
  t_has "提交失败：日志带 rc 与响应体片段" "$SG_WORK/mod/fafu_checkin.log" "签到失败: rc=0 $SG_SIGN_FAIL"
  t_eq "提交失败：通知事件是 failsign" "$(sg_val "$d" events)" "failsign,"
  t_eq "提交失败：不写签到记录" "$(sg_status sign_kind)" ""
  t_eq "提交失败：不刷新描述（没有成功可言）" "$(sg_val "$d" desc)" "0"

  # 「当日仅首次通知」：signin 层每次都只报事件名，去重交给 notify 层的当日标记。
  # 这里把 notify_once 换成真实的去重逻辑，连着跑两轮，验第二轮确实被判成「今天已发过」。
  # 单开一份工作目录：同一目录里的产物会被下一轮覆盖，断言就静默空转了。
  sg_setup failed2
  sg_at 1291
  sg_body 1290 0 > "$SG_WORK/ctl/body.page"
  # 两轮各自的「查任务 + 提交」：顺序是 page, sign, page, sign
  printf 'page:0\nsign:0\npage:0\nsign:0\n' > "$SG_WORK/ctl/api.seq"
  printf '%s\n' "$SG_SIGN_FAIL" > "$SG_WORK/ctl/body.sign"
  sg_run failed2 <<'DRIVER'
notify_once() {
  if notify_marked fail; then printf 'skipped\n' >> ctl/dup
  else printf 'sent\n' >> ctl/dup; notify_mark fail; fi
  return 0
}
run_once; printf 'rc1=%s\n' "$?"
run_once; printf 'rc2=%s\n' "$?"
DRIVER
  t_eq "首次失败：签到层报的事件确实被发出去（标记随之落地）" \
    "$(sed -n 1p "$SG_WORK/ctl/dup")" "sent"
  t_eq "第二次重试：签到层仍报同一事件名，但当日不再发" \
    "$(sed -n 2p "$SG_WORK/ctl/dup")" "skipped"
}

# ============================================================
# 五、窗口边界：21:29 / 21:30 / 22:30 / 22:59 / 23:00(+1)
#
# 判定把「当前时刻（毫秒）」与接口给的 beginTime / supplementEndTime 比较，
# 故边界直接用**判定函数的返回码**观察：0 = 提交（窗口内），1 = 不在时段（窗口外）。
# 夹具是 21:30~22:30 + 补签截止 23:00，于是五个时点各只跨过一条边。
# 注意补签截止的判据是 `-gt`（严格大于）：整点那一刻仍在窗口内，23:01 才出窗口 ——
# 这正是「最后一次不晚于 22:59 发起」那条口径能成立的原因，别顺手改成 -ge。
# 这一节直接调 signin_decide（判定的边界是它自己的事），所以驱动里只有提交调用，
# 序列只需覆盖 sign 那一档。
# ============================================================

sg_case_boundaries() {
  local d
  sg_setup boundary
  sg_body 1290 0 > "$SG_WORK/ctl/body.page"
  printf 'sign:0\n' > "$SG_WORK/ctl/api.seq"
  printf '%s\n' "$SG_SIGN_OK" > "$SG_WORK/ctl/body.sign"
  sg_run boundaries <<'DRIVER'
: > ctl/bounds
# 判定的边界是它自己的事，故直接调 signin_parse / signin_decide（不经 run_once）：
# 这一节因此只有提交调用，序列只需覆盖 sign 那一档。
# 注意两个函数的形状：解析把字段写进调用方声明的 local，判定再按参数收下它们。
one() { # $1=当日第几分钟 → stdout=判定返回码
  local resp rid name state bt dline et rc
  sg_at "$1"
  resp=$(cat ctl/body.page)
  signin_parse "$resp" rid name state bt dline et >/dev/null || { printf 'parse-fail'; return 0; }
  signin_decide "$resp" TOK "$rid" "$name" "$state" "$bt" "$dline" "$et" >/dev/null 2>&1; rc=$?
  printf '%s' "$rc"
}
for m in 1289 1290 1350 1379 1380 1381; do
  printf '%s=%s\n' "$m" "$(one $m)" >> ctl/bounds
done
printf 'bounds=%s\n' "$(tr '\n' ',' < ctl/bounds)"
DRIVER
  d="$SG_WORK/boundaries.out"
  t_eq "六个时点都被判定到（没有中途退出）" \
    "$(grep -c '=' "$SG_WORK/ctl/bounds")" "6"
  t_has "21:29 → 窗口外（可重试）" "$d" "1289=1,"
  t_has "21:30 → 进入窗口（提交）" "$d" "1290=0,"
  t_has "22:30 → 主窗口最后一分钟仍在窗口内" "$d" "1350=0,"
  t_has "22:59 → 补签时段内仍提交" "$d" "1379=0,"
  t_has "23:00 整点仍在窗口内（判据是严格大于）" "$d" "1380=0,"
  t_has "23:01 → 已过补签截止，窗口外" "$d" "1381=1,"
}

# ============================================================
# 六、token 失效：查询异常 → 刷新后重试；重试仍失败 → 任务异常
# ============================================================

sg_case_token_refresh() {
  local d
  sg_setup refresh
  sg_at 1290
  sg_body 1290 0 > "$SG_WORK/ctl/body.page"
  # ① 第一次查询失败 → 刷新 → 第二次成功 → 照常走完判定与提交
  printf '%s\n' "$SG_SIGN_OK" > "$SG_WORK/ctl/body.sign"
  sg_run refetch <<'DRIVER'
SG_NEWTOKEN=NEWTOKEN
printf 'page:1\npage:0\nsign:0\n' > ctl/api.seq
refresh_token() { printf 'refresh\n' >> ctl/refresh; printf '%s' "$SG_NEWTOKEN"; }
run_once; printf 'rc=%s\n' "$?"
printf 'refresh=%s\n' "$(grep -c . ctl/refresh 2>/dev/null || echo 0)"
printf 'calls=%s\n'   "$(grep -c . ctl/api.calls 2>/dev/null || echo 0)"
DRIVER
  d="$SG_WORK/refetch.out"
  t_eq "查询异常后刷新 token 重试成功：返回 0" "$(sg_val "$d" rc)" "0"
  t_eq "查询异常确实触发了刷新" "$(sg_val "$d" refresh)" "1"
  t_eq "刷新后重试：三次网络调用（查询失败 + 查询成功 + 提交）" "$(sg_val "$d" calls)" "3"

  # ② 刷新后仍失败 → 任务异常（返回 2），并报「拿不到任务」
  sg_run refail <<'DRIVER'
SG_NEWTOKEN=NEWTOKEN
printf 'page:1\npage:1\n' > ctl/api.seq
refresh_token() { printf '%s' "$SG_NEWTOKEN"; }
run_once; printf 'rc=%s\n' "$?"
printf 'events=%s\n' "$(tr '\n' ',' < ctl/events 2>/dev/null)"
DRIVER
  d="$SG_WORK/refail.out"
  t_eq "刷新后仍拿不到任务：返回 2（任务异常）" "$(sg_val "$d" rc)" "2"
  t_eq "拿不到任务：通知事件是 failtask" "$(sg_val "$d" events)" "failtask,"
  t_has "拿不到任务：日志带 rc" "$SG_WORK/mod/fafu_checkin.log" "获取任务失败: rc=1"
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

# ---- 注册（顺序即执行顺序） ----

t_case "signin · 时钟与夹具自证" sg_case_clock
t_case "signin · 三档返回码（成功 / 可重试 / 任务异常）" sg_case_codes
t_case "signin · 等 App 数据就绪（等到就用，等不到有界退回）" sg_case_wait_appdata
t_case "signin · 分支：已签到（记录 + 通知）" sg_case_branch_seen
t_case "signin · 分支：已请假（记录 + 通知）" sg_case_branch_leave
t_case "signin · 分支：窗口内提交（normal）" sg_case_branch_window
t_case "signin · 分支：不在时段（可重试）" sg_case_branch_outside
t_case "signin · 任务信息不完整（可重试）" sg_case_parse_incomplete
t_case "signin · 解析写回调用方字段（端到端）" sg_case_parse_outputs
t_case "signin · 截止字段回退 endTime" sg_case_parse_fallback
t_case "signin · 坐标缺失回退内置坐标" sg_case_coords_fallback
t_case "signin · token 一路传到提交（端到端）" sg_case_token_chain
t_case "signin · 提交：补签（supplement）" sg_case_submit_supplement
t_case "signin · 提交失败当日仅首次通知" sg_case_submit_failed
t_case "signin · 窗口边界（21:29 / 21:30 / 22:30 / 22:59 / 23:00）" sg_case_boundaries
t_case "signin · token 失效后刷新重试" sg_case_token_refresh
t_case "signin · 判定链与主循环分支（静态）" sg_case_boundary
t_case "signin · 截止提醒的判定（纯函数）" sg_case_remind_due
t_case "signin · 三条截止提醒按任务数据各发一次" sg_case_remind_events
t_case "signin · 提交失败的原因留在日志里（HTTP 状态码 / 超时）" sg_case_fail_reason
