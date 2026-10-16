# ============================================================
# signin 各用例文件共用的前导：夹具、替身与取值辅助
#
# 由 signin*.sh 各自 source——别指望别的用例文件已经 source 过它：并行跑时每个
# 用例文件各自一个子进程。文件名以 _ 开头，总入口按这个前缀跳过、不当它用例文件。
#
# 缝只有两个（都在运行时既有注入点上）：时间走 _now 的替身（拨 EPOCH），网络走
# http_post（注入响应体／退出码）。夹具的时间字段是相对 EPOCH 的偏移。
# 覆盖不到（只能上机目视确认）：接口真实返回体的字段形态、补签时段的服务端行为。
# ============================================================

SG_WORK=""
SG_EPOCH=0             # 2026-10-01 00:00（本地时区的当日零点），由 sg_epoch 算出
SG_DATE='2026-10-01'   # 夹具日期；拨钟的墙钟与 %s 的 EPOCH 都从这一天出发

# 签到与提醒的能力都只有 signin 层定义（能力名 = 函数的唯一真源，改名会在这里报红）
SG_CAPS="state_text:signin run_once:signin signin_fetch:signin signin_parse:signin signin_decide:signin signin_submit:signin signin_ms_hm:signin signin_remind_due:signin signin_remind_30min:signin signin_remind_deadlines:signin signin_notask_target:signin signin_notask_due:signin signin_remind_notask:signin"
# 判定链用**调用形状**钉住，不绑函数体里的行号。
# 取任务那一环经两个变量名写回（不是 $( ) 取值）：命令替换会把这一步推进子 shell，而失败行的
# 当日去重状态是主 shell 的变量——子 shell 里记下的「今晚这条已经写过」出不了子 shell。
SG_CHAIN="signin_fetch \"\$(get_token)\"  signin_parse \"\$resp\"  signin_decide \"\$resp\" \"\$tok\""

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

# 同一毫秒戳按 UTC 的解释（HH:MM）：期望值用真实 busybox 现算——写死就成了把
# 「跑断言的这台机器的时区」烧进期望里，CI（UTC）与本机（UTC+8）会得出不同的值。
sg_utc_hm() { # $1=当日第几分钟（与夹具同源的偏移）
  local bb
  bb=$(t_find_busybox)
  [ -n "$bb" ] || bb="busybox"
  "$bb" date -u -d "@$(( SG_EPOCH + ${1:-0} * 60 ))" +%H:%M 2>/dev/null
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

# 一串 x（$1=字节数）：借随附 busybox 的 awk 生成，不依赖本机有没有 seq / yes
sg_pad() {
  local bb
  bb=$(t_find_busybox)
  [ -n "$bb" ] || bb="busybox"
  "$bb" awk -v n="${1:-2500}" 'BEGIN{for(i=0;i<n;i++) printf "x"}'
}

# 超长记录夹具：整条服务端记录超过 2KB（在既有字段之后再加一个长字段）。
# 末尾不留换行（sg_body 带的那个换行在这里被 $( ) 去掉）：交给日志的那个串因此与
# 文件字节数逐字节同长，断言可以拿文件大小当独立真值。
sg_body_seen_big() { # $1=填充字节数（默认 2500）
  local pad
  pad=$(sg_pad "${1:-2500}")
  printf '%s' "$(sg_body 1290 1 ",\"signTime\":$(( SG_EPOCH * 1000 + 1230 * 60000 )),\"pad\":\"$pad\"")"
}

# 三个时点各自指定的响应体：$1=任务开始分钟 $2=主窗口截止分钟 $3=补签截止分钟
# （sg_body 的三个时点是绑在一起的固定形状；提醒的锚点由任务数据推算，故要能分别摆）
sg_task_span() {
  printf '{"records":[{"id":88123,"name":"晚查寝签到","beginTime":%s,"supplementEndTime":%s,"endTime":%s,"signInStudent":{"signState":0},"lng":119.243462,"lat":26.088417}]}\n' \
    "$(( SG_EPOCH * 1000 + $1 * 60000 ))" \
    "$(( SG_EPOCH * 1000 + $3 * 60000 ))" \
    "$(( SG_EPOCH * 1000 + $2 * 60000 ))"
}

# 查询失败的夹具：长正文（>200 字节，尾部那句在旧写法的 head -c 200 之外）。
# 断言尾部那一句出现，就等于断言「正文完整落盘」而不是「前 200 字节落盘」。
sg_body_long() {
  printf '{"timestamp":1759500000000,"status":400,"error":"Bad Request","message":"窗口未开：服务端拒绝了这一次查询，正文里的这一句正是要看的那一句","path":"/health-api/sign_in/student/my/page","detail":"%s"}\n' \
    "正文的尾部也必须整段落进日志"
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
  # curl 替身：真实 api 层那条路线（sg_run_real）靠它注入「这一次网络调用的全部事实」
  t_curl_stub "$SG_WORK/bin/curl" "$SG_WORK/ctl" >/dev/null
  printf '200\n' > "$SG_WORK/ctl/http"   # 替身 http_post 记下的状态码（默认 2xx）
  : > "$SG_WORK/ctl/hdr"                 # 这一次的响应头原文（-D 落点形状）；缺省「没给头」
  # 夹具配置文件：本套件钉的是日志**文案**（含被降级的那些行），故夹具把调试档打开，
  # 断言测的仍是完整行为。由 sg_env 里的 cfg_load 读成生效值——与入口同一时序
  # （先落文件、再由配置层覆盖加载时那个默认值，写成环境变量会被默认值盖掉）。
  # 档位本身与默认档少写哪几行由 poll 套件那条真入口对照守着。
  printf 'DEBUG=1\n' > "$SG_WORK/mod/fafu-checkin.conf"
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
# 网络工具指向测试底座生成的 curl 替身：api 层在**加载时**读这个变量，
# 于是本机不去 PATH 上探测（路线 B 的驱动因此一定跑在真实 api 层上）
CURL_BIN='./bin/curl'
MOCK_DATE_CTL='./ctl/date'
# 网络替身的控制目录在 ctl/；设备命令替身目录同样给上（判到窗口内的用例会真去读屏幕状态）
MOCK_WGET_DIR='./ctl'
MOCK_DEVICE_DIR='./ctl'
MOCK_RANDOM_CTL='./ctl/rand'
MODDIR='./mod'
# token 目录：LD 只在 api 层加载时取一次，这里指向驱动的工作目录（一定存在），
# 于是「取不到 token」不会把判定链挡在门外；「没有应用数据」那一档由用例自己改 LD
LD_DIR='.'
# 等 App 数据就绪 / 提交失败后短重试 用的 sleep 替身。
# 默认给 `:`（不耗时）：等待的长度不是断言重点，次数与结果才是——否则每个提交失败的
# 用例都要真等 15 秒×2。要观察等待行为的用例自己覆盖它。
SLEEP_OVERRIDE="${SLEEP_OVERRIDE:-:}"
PL=20261001
NOTIFY=1
SU_MODE=""
SG_DATE='$SG_DATE'
SG_EPOCH=$SG_EPOCH
SG_NOW_S=$SG_NOW_S
export BB_OVERRIDE CURL_BIN MOCK_DATE_CTL MOCK_WGET_DIR MOCK_DEVICE_DIR MOCK_RANDOM_CTL
export MODDIR LD_DIR PL NOTIFY SU_MODE SLEEP_OVERRIDE
export SG_EPOCH SG_NOW_S
for _f in $TEST_LIB_FILES; do . "\$T_ROOT/\$_f"; done
# 与入口同一时序：各层就位之后再加载配置（夹具那份文件负责档位等生效值）
cfg_load

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
# 网络替身（路线 A）：按 ctl/api.seq 的第 N 行分派（形如「page:rc」「sign:0」），
# 行数不够时回落到上一个用过的档、再退到 ctl/api.default；响应体从 ctl/body.<app> 读。
# 计数必须落在**文件**上：api() 在 $( ) 里调 http_post，变量活在子 shell 里，
# 每次调用都会从第 1 行重新开始（整条序列因此只认第一行的分支，极难发现）。
# SG_API_MODE=real 时不定义它：那条路线让**真实 api 层**跑，事实由 curl 替身给。
if [ "\${SG_API_MODE:-stub}" != "real" ]; then
http_post() {
  _n=\$(cat ctl/seq.n 2>/dev/null); _n=\$(expr "\${_n:-0}" + 1)
  printf '%s' "\$_n" > ctl/seq.n
  # 记录 URL 与 Authorization 两样：token 有没有一路传到提交，就看这行里有没有它
  printf '%s | %s\n' "\$1" "\$2" >> ctl/api.calls
  _m=\$(sed -n "\${_n}p" ctl/api.seq 2>/dev/null)
  if [ -z "\$_m" ]; then
    _m=\$(cat ctl/last 2>/dev/null)
    [ -n "\$_m" ] || _m=\$(cat ctl/api.default 2>/dev/null)
  fi
  case "\$_m" in
    *:*) _app="\${_m%%:*}"; _rc="\${_m##*:}" ;;
    *)   _app=page; _rc=0 ;;
  esac
  printf '%s\n' "\$_m" > ctl/last
  _body=\$(cat "ctl/body.\$_app" 2>/dev/null)
  printf '%s' "\$_body"
  # 这一次调用的事实交由 api 层落笔（格式只有一处，替身不自己拼 http=/body=/耗时=）：
  # 失败档如实写工具退出码与报错原文，成功档写状态码（ctl/http，默认 2xx）。
  # 第五个参数是「这一次的响应头原文」所在文件（与 curl 的 -D 落点同形）：缺省那份是空的
  # → 没有 hdr=；用例要验「响应头与核对行并排」时往里写一份头。
  if [ "\${_rc:-0}" != "0" ]; then
    _api_note "\${_rc:-0}" "" "\$_body" "\$(cat ctl/wget.err 2>/dev/null)" ctl/hdr "" ""
  else
    _api_note 0 "\$(cat ctl/http 2>/dev/null)" "\$_body" "" ctl/hdr "" ""
  fi
  return "\${_rc:-0}"
}
fi
# 观察面：谁被通知了、描述刷没刷新、token 刷没刷新。
# 通知正文与降权链路由 tests/notify.sh 断言，这里只关心「业务层报了哪个事件名」。
notify_event() { printf '%s\n' "\$1" >> ctl/events; return 0; }
notify_once()  { printf '%s\n' "\$1" >> ctl/events; return 0; }
update_desc()  { printf 'desc\n' >> ctl/desc; return 0; }
# 刷新替身：默认顶掉真实刷新流程（三段时序是 keepalive 套件的地盘）。SG_REFRESH_MODE=real
# 时**不定义它**，于是真实 refresh_token 跑起来——要看它自己写的那几行日志时用那条路线。
if [ "${SG_REFRESH_MODE:-stub}" != "real" ]; then
refresh_token() { printf 'refresh\n' >> ctl/refresh; printf '%s' "\${SG_NEWTOKEN:-}"; }
fi
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

# 响应头夹具与它该落成的字面：白名单四项齐全，顺序就是 api 层固定的那一个。
# 用来钉「hdr={…} 真的写进了提交行」，而不是靠实现自己声明写了。
SG_HDR_RAW='Date: Mon, 13 Oct 2025 21:30:00 GMT
Content-Length: 53
Content-Type: application/json;charset=UTF-8
Server: nginx'
SG_HDR_LINE='hdr={Date: Mon, 13 Oct 2025 21:30:00 GMT|Content-Length: 53|Content-Type: application/json;charset=UTF-8|Server: nginx}'

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

# 同 sg_run，但走**路线 B**：不覆盖 http_post，让 api 层真实的那个跑起来。
# 这一次网络调用的事实由 curl 替身的控制文件决定（响应头解析、压平、耗时都是真实代码在写），
# 代价是替身对每次调用给同样的应答，做不出「第 N 次返回什么」那种序列。
sg_run_real() { # $1=名字；主体从 stdin 读入
  SG_API_MODE=real
  export SG_API_MODE
  sg_run "$1"
  unset SG_API_MODE
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
# 末尾的「时间核对」行不是业务文案（它是为排查记录钟点而加的旁证），故向前找第一行非它者：
# 这样几十处「日志文案不变」的断言不必各改一遍，也不会被那条核对行挤掉。
sg_log() {
  sed 's/^\[[^]]*\][ ]*//' "$SG_WORK/mod/fafu_checkin.log" 2>/dev/null \
    | grep -v '^时间核对:' | tail -n 1
}

# 按前缀在日志里找一行（明文去掉时间戳后）：给那些「不保证是最后一行」的核对类日志用。
sg_log_has() { # $1=文案前缀
  sed 's/^\[[^]]*\][ ]*//' "$SG_WORK/mod/fafu_checkin.log" 2>/dev/null | grep -F "$1" | tail -n 1
}

# 日志正文（去掉行首时间戳）整份落到 $SG_WORK/log.txt，并输出该路径。
# sg_log / sg_log_has 只看一行；要断言「日志里有哪几行、各几行」时用这一份。
sg_plain_log() {
  sed 's/^\[[^]]*\][ ]*//' "$SG_WORK/mod/fafu_checkin.log" 2>/dev/null > "$SG_WORK/log.txt"
  printf '%s' "$SG_WORK/log.txt"
}
