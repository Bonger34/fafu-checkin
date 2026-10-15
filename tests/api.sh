# ============================================================
# api 层验收断言：token 提取、请求签名、HTTP 调用与网络注入点
#
# 四条口径（都只针对外部可观察的行为）：
#   1) 行为：token 按文件修改时间取最新那次登录；签名串是
#      base64(时间戳:随机数:MD5(密钥+签名URL+时间戳+随机数):token)；失败只看退出码；
#   2) 缝：全程序只有 http_post() 一处真正发起网络请求——断言里覆盖同名函数即可
#      注入响应体 / 失败 / 超时；真实命令行（含超时选项探测）与失败时报错正文的
#      转交（成功静默 / 失败转 stderr）在同一个缝上用替身 busybox 断言
#      （tests/mock/busybox 的 MOCK_WGET_DIR）；
#   3) 不变：调用点的请求路径、查询参数与请求头逐字钉住（静态断言）；
#   4) 诊断：一次调用写成诊断文件里恰好一行（状态码 / 正文 / 响应头白名单 / 耗时）。
#
# 断言直接加载真实的层文件（tests/harness.sh 的 TEST_LIB_FILES），不抽源码片段、不绑行号。
# ============================================================

AP_WORK="$T_WORK_ROOT/api"

# 夹具路径一律用**相对路径**（ap_run 会先 cd 到 $AP_WORK）：Windows 上的 D:/ 路径喂进
# 被测代码会变成残缺路径（见 tests/state.sh 的说明），而运行时用的是手机上的绝对路径。
AP_MODDIR="./mod"
AP_BB="./bin/bb"
AP_LD="./ld"
AP_WGDIR="./wget"

# 每个用例自备环境：替身 busybox + leveldb 替身目录 + wget 的五个控制文件。
# curl 替身由测试底座的 t_curl_stub 生成（放 ./bin，PATH 首位；控制文件就在本目录）：
# curl_code / curl_body 决定它回什么，curl_hdr / curl_stderr / curl_rc 决定响应头、
# 报错原文与退出码。
# 于是「curl 优先」与「wget 兜底」两条路径都能在这里跑出来（删掉 ./bin/curl 即走兜底）。
ap_setup() {
  rm -rf "$AP_WORK"
  mkdir -p "$AP_WORK/mod" "$AP_WORK/ld" "$AP_WORK/wget" "$AP_WORK/bin"
  t_bb_wrap "$AP_WORK/bin/bb" >/dev/null
  printf 'BusyBox v1.35.0 wget\n\t-T SEC\tNetwork timeout\n' > "$AP_WORK/wget/help"
  : > "$AP_WORK/wget/body"
  printf '0\n' > "$AP_WORK/wget/rc"
  : > "$AP_WORK/wget/stderr"
  : > "$AP_WORK/wget/hdr"                 # -S 形状的服务端响应（状态行 + 头行）；缺省「没吐」
  : > "$AP_WORK/wget/calls"
  printf '0\n' > "$AP_WORK/rand.seq"     # 随机数替身的序号：两次调用必须给出不同的值
  t_curl_stub "$AP_WORK/bin/curl" "$AP_WORK" >/dev/null
  # 默认走 wget 兜底：既有断言（命令行逐字比对等）钉的就是那条路。
  # 要测 curl 路径的用例自己删掉这个标记。
  : > "$AP_WORK/mod/.fafu_no_curl"
}

# 驱动脚本的公共前导：注入替身 busybox、token 目录与 wget 控制目录，再按加载顺序加载层。
ap_write_env() {
  cat > "$AP_WORK/_env.sh" <<ENV
PATH='./bin:/bin:/usr/bin'
T_ROOT='$T_ROOT'
T_WORK='$AP_WORK'
MODDIR='$AP_MODDIR'
BB_OVERRIDE='$AP_BB'
LD_DIR='$AP_LD'
MOCK_WGET_DIR='$AP_WGDIR'
MOCK_RANDOM_CTL='./rand.seq'
export MODDIR BB_OVERRIDE LD_DIR MOCK_WGET_DIR MOCK_RANDOM_CTL
for _f in $TEST_LIB_FILES; do . "\$T_ROOT/\$_f"; done
ENV
}

# 跑一个驱动脚本；用法：ap_run <名字>，主体从 stdin 读入（公共前导自动接在前面）。
# 驱动把结果打成 key=value 到 stdout（读 $AP_WORK/<名字>.out），不额外落文件。
ap_run() {
  local name rc
  name="$1"
  cat > "$AP_WORK/_body.sh"
  cp "$AP_WORK/_env.sh" "$AP_WORK/$name.sh"
  cat "$AP_WORK/_body.sh" >> "$AP_WORK/$name.sh"
  ( cd "$AP_WORK" && $(t_sh) "./$name.sh" ) > "$AP_WORK/$name.out" 2> "$AP_WORK/$name.err"
  rc=$?
  echo "$rc" > "$AP_WORK/$name.rc"
  if [ -s "$AP_WORK/$name.err" ]; then
    echo "  （驱动 $name 的 stderr）"
    sed 's/^/    /' "$AP_WORK/$name.err"
  fi
}

# 从驱动输出里取一行（形如 key=value）。键按整键匹配（^ 锚行首），
# 避免 ok_rc= 这类前缀行被当成 ok 命中。
ap_val() { # $1=文件 $2=键
  grep "^$2=" "$1" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '\r\n'
}

# 设文件修改时间：本机（Windows）的 sh 未必自带 touch，统一借随附 busybox 的 applet
ap_touch() { # $1=YYYYMMDDhhmm $2=文件
  local bb
  bb=$(t_find_busybox)
  if [ -n "$bb" ]; then
    "$bb" touch -t "$1" "$2"
  else
    touch -t "$1" "$2"
  fi
}

# leveldb 替身：四份「WebView 本地存储」，token 以 UTF-16LE 形态存放（夹 NUL）。
# **文件名顺序刻意与修改时间顺序相反**（000009 比 000007 旧）：只有真的按修改时间
# 排序才取得到最后那份；若哪天退回成按文件名 `ls`，这里会立刻报红。
# 中间两份分别放诱饵字段与「同一份文件里的两次登录」。
ap_make_leveldb() {
  rm -rf "$AP_WORK/ld" "$AP_WORK/ld-decoy"
  mkdir -p "$AP_WORK/ld" "$AP_WORK/ld-decoy"
  printf 'j\000"token":"2_0000000000000000000000000000AAAA"\000j' > "$AP_WORK/ld/000003.ldb"
  printf 'j\000"token":"2_1111111111111111111111111111BBBB"\000j' > "$AP_WORK/ld/000009.ldb"
  printf 'j\000"token":"not-a-token"\000"tokenName":"2_FFFF"\000j'   > "$AP_WORK/ld/000005.log"
  # 同一份文件里有两次登录记录：取最后一次（最新的那次免密登录）
  printf 'j\000"token":"2_2222222222222222222222222222CCCC"\000j\000"token":"2_3333333333333333333333333333DDDD"\000j' \
    > "$AP_WORK/ld/000007.ldb"
  ap_touch 200001010000 "$AP_WORK/ld/000003.ldb"
  ap_touch 201001010000 "$AP_WORK/ld/000009.ldb"
  ap_touch 202001010000 "$AP_WORK/ld/000005.log"
  ap_touch 202101010000 "$AP_WORK/ld/000007.ldb"
  # 只有诱饵的一份存储：合法 token 一个都没有
  printf 'j\000"token":"not-a-token"\000"tokenName":"2_FFFF"\000j' > "$AP_WORK/ld-decoy/CURRENT"
}

# ============================================================
# 一、token 提取
# ============================================================

ap_case_token() {
  local d
  ap_setup
  ap_make_leveldb
  ap_write_env
  ap_run token <<'DRIVER'
# 按修改时间倒序读，取最后一份文件里的最后一个 token
printf 'newest=%s\n' "$(get_token)"
# 最新那份被 leveldb 压实掉后，仍要能取到更早那次登录的 token（不是空、也不是诱饵）
rm -f ld/000007.ldb
printf 'fallback=%s\n' "$(get_token)"
# 目录不存在（应用没装 / 没登录过）：输出空且不报错——「有没有应用数据」由调用方判定。
# 换目录直接改 LD：它是本层在加载时由 LD_DIR 定下的全局，get_token 每次调用时读它
LD='./ld-none'
tok=$(get_token); rc=$?
printf 'nodir=[%s] rc=%s\n' "$tok" "$rc"
# 全是诱饵、没有合法 token：输出空（形状判定不放宽）
LD='./ld-decoy'
printf 'decoy=[%s]\n' "$(get_token)"
DRIVER

  d="$AP_WORK/token.out"
  t_eq "token 按修改时间取最新那份文件里的最后一个" "$(ap_val "$d" newest)" "2_3333333333333333333333333333DDDD"
  t_eq "最新那份不在时回退到更早一次登录（诱饵不算）" "$(ap_val "$d" fallback)" "2_1111111111111111111111111111BBBB"
  t_eq "应用数据目录不存在时输出空（不报错）" "$(ap_val "$d" nodir)" "[] rc=0"
  t_eq "只有诱饵时输出空（形状判定不放宽）" "$(ap_val "$d" decoy)" "[]"
}

# ============================================================
# 二、签名串构造
# ============================================================

ap_case_sign() {
  local d
  ap_setup
  ap_write_env
  ap_run sign <<'DRIVER'
U="$API/sign_in/student/my/page"
TK="2_ABCDEF0123456789ABCDEF0123456789"
a1=$(mk_auth "$U" "$TK")
a2=$(mk_auth "$U" "$TK")

# 解开 base64，逐段核对：时间戳:随机数:签名:token
raw=$(printf '%s' "$a1" | "$BB" base64 -d)
ts=$(printf '%s' "$raw" | cut -d: -f1)
nonce=$(printf '%s' "$raw" | cut -d: -f2)
hash=$(printf '%s' "$raw" | cut -d: -f3)
tok=$(printf '%s' "$raw" | cut -d: -f4)
# 按文档公式反算：MD5(密钥 + 签名URL + 时间戳 + 随机数)
exp=$(printf '%s' "${SECRET}${U}${ts}${nonce}" | "$BB" md5sum | cut -d' ' -f1)
# 换一个 URL 反算：签名里必须真的带着 URL（否则上面的巧合会掩盖缺项）
exp2=$(printf '%s' "${SECRET}${U}/x${ts}${nonce}" | "$BB" md5sum | cut -d' ' -f1)
# 容差 ±60 秒：签名时刻 ts 必然 ≤ 这里的 now（签名在前），故只是给「机器被压满时
# 这一段多进程开销」留余量。不能放宽到「当日零点」那种量级（差 4 万秒）——那会漏掉
# 「拿当天零点冒充当前时刻」这类真错。
now=$(now_s)

printf 'api_base=%s\n' "$API"
printf 'secret=%s\n' "$SECRET"
printf 'fields=%s\n' "$(printf '%s' "$raw" | "$BB" awk -F: '{print NF}')"
printf 'hash_ok=%s\n' "$([ "$hash" = "$exp" ] && echo yes || echo no)"
printf 'url_signed=%s\n' "$([ "$hash" != "$exp2" ] && echo yes || echo no)"
printf 'ts_num=%s\n' "$(printf '%s' "$ts" | "$BB" tr -dc '0-9' | "$BB" wc -c | "$BB" tr -dc '0-9')"
printf 'ts_now=%s\n' "$([ "$ts" -ge $((now - 60)) ] && [ "$ts" -le $((now + 60)) ] && echo yes || echo no)"
printf 'nonce=%s\n' "$nonce"
printf 'nonce_len=%s\n' "${#nonce}"
printf 'token=%s\n' "$tok"
printf 'nonce_bad=%s\n' "$(printf '%s' "$nonce" | "$BB" tr -d 'A-Za-z0-9' | "$BB" wc -c | "$BB" tr -dc '0-9')"
printf 'b64_bad=%s\n' "$(printf '%s' "$a1" | "$BB" tr -d 'A-Za-z0-9+/=' | "$BB" wc -c | "$BB" tr -dc '0-9')"
# 无换行：base64 默认会折行，输出给 --header 的必须是单行
printf 'lines=%s\n' "$(mk_auth "$U" "$TK" | "$BB" wc -l | "$BB" tr -dc '0-9')"
# 两次签名不能相同（随机数每次都换，否则签名可重放）
printf 'diff=%s\n' "$([ "$a1" != "$a2" ] && echo yes || echo no)"
DRIVER

  d="$AP_WORK/sign.out"
  t_eq "接口根地址未变（服务端按它校验签名）" "$(ap_val "$d" api_base)" "http://stuhtapi.fafu.edu.cn/health-api"
  t_eq "签名密钥未变（重新逆向才会动它）" "$(ap_val "$d" secret)" "AtPs2O1xEnhwkKDV"
  t_eq "签名串是「时间戳:随机数:签名:token」四段" "$(ap_val "$d" fields)" "4"
  t_eq "签名 = MD5(密钥 + 签名URL + 时间戳 + 随机数)" "$(ap_val "$d" hash_ok)" "yes"
  t_eq "签名里真的带了 URL" "$(ap_val "$d" url_signed)" "yes"
  t_eq "时间戳为纯数字" "$(ap_val "$d" ts_num)" "10"
  t_eq "时间戳取当前时刻（秒级）" "$(ap_val "$d" ts_now)" "yes"
  # 随机数是替身给的（本机没有 /dev/urandom），故这里只断言**契约**：
  # 16 位、只含字母数字、两次不同——不去比对替身的固定输出（那样改替身就假红）
  t_eq "随机数为 16 位" "$(ap_val "$d" nonce_len)" "16"
  t_eq "token 原样落在第四段" "$(ap_val "$d" token)" "2_ABCDEF0123456789ABCDEF0123456789"
  t_eq "随机数只含字母数字" "$(ap_val "$d" nonce_bad)" "0"
  t_eq "整串是合法 base64（无多余字符）" "$(ap_val "$d" b64_bad)" "0"
  t_eq "输出为单行（不带换行）" "$(ap_val "$d" lines)" "0"
  t_eq "两次签名的随机数不同" "$(ap_val "$d" diff)" "yes"
}

# ============================================================
# 三、网络注入点：覆盖 http_post 即可注入响应体 / 失败 / 超时
#
# 这一缝是「签到判定的各个分支能在离线状态下复现」的前提：调用方拿到的只有
# 「响应体 + 退出码」两样东西，本用例断言的就是这两样被原样交出去。
# ============================================================

ap_case_seam() {
  local d
  ap_setup
  ap_write_env
  ap_run seam <<'DRIVER'
# 注入替身：把「网络」换成文件内容与一个退出码
http_post() {
  printf '%s\t%s\n' "$1" "$2" >> calls.txt
  cat body.txt
  _c=$(cat rc.txt); return "$_c"
}
# 反算签名，验证参与签名的是哪一个 URL（$2 = 期望参与签名的 URL）
sig_of() {
  local d_raw d_ts d_nonce d_hash d_exp
  d_raw=$(printf '%s' "$1" | "$BB" base64 -d)
  d_ts=$(printf '%s' "$d_raw" | cut -d: -f1)
  d_nonce=$(printf '%s' "$d_raw" | cut -d: -f2)
  d_hash=$(printf '%s' "$d_raw" | cut -d: -f3)
  d_exp=$(printf '%s' "${SECRET}$2${d_ts}${d_nonce}" | "$BB" md5sum | cut -d' ' -f1)
  [ "$d_hash" = "$d_exp" ] && echo yes || echo no
}
TK="2_ABCDEF0123456789ABCDEF0123456789"
: > calls.txt

# ① 正常：响应体原样透传、返回 0
printf '%s' '{"records":[{"id":7,"signState":0}]}' > body.txt; printf '0' > rc.txt
resp=$(api "sign_in/student/my/page" "rows=3&pageNum=1" "$TK"); rc=$?
url=$(cut -f1 calls.txt | tail -n1)
printf 'ok_rc=%s\n' "$rc"
printf 'ok_body=%s\n' "$resp"
printf 'ok_url=%s\n' "$url"
printf 'ok_sig_url=%s\n' "$(sig_of "$(cut -f2 calls.txt | tail -n1)" "$API/sign_in/student/my/page")"

# ② 失败：非 0 退出码 + 空响应体（busybox wget 拿不到错误正文）
printf '' > body.txt; printf '1' > rc.txt
resp=$(api "sign_in/7/student/sign" "lng=119.243462&lat=26.088417" "$TK"); rc=$?
printf 'fail_rc=%s\n' "$rc"
printf 'fail_body=[%s]\n' "$resp"
printf 'fail_url=%s\n' "$(cut -f1 calls.txt | tail -n1)"
printf 'fail_sig_url=%s\n' "$(sig_of "$(cut -f2 calls.txt | tail -n1)" "$API/sign_in/7/student/sign")"

# ③ 超时：同样只是一个非 0 退出码，调用方无需区分（区分不出来）
printf '143' > rc.txt
api "sign_in/student/my/page" "rows=1&pageNum=1" "$TK" >/dev/null; rc=$?
printf 'timeout_rc=%s\n' "$rc"

# ④ 空查询串：URL 不带 "?"
api "sign_in/student/my/page" "" "$TK" >/dev/null
printf 'noquery_url=%s\n' "$(cut -f1 calls.txt | tail -n1)"

# ⑤ 不向调用方泄漏中间量（跨层隐式传值是禁止的：调用一个函数前不该猜它改了哪些全局）
ts=SENTINEL; nonce=SENTINEL; hash=SENTINEL; url=SENTINEL; auth=SENTINEL
mk_auth "$API/x" "$TK" >/dev/null
api "sign_in/student/my/page" "" "$TK" >/dev/null
printf 'leak=[%s|%s|%s|%s|%s]\n' "$ts" "$nonce" "$hash" "$url" "$auth"
DRIVER

  d="$AP_WORK/seam.out"
  t_eq "成功：返回 0" "$(ap_val "$d" ok_rc)" "0"
  t_eq "成功：响应体原样透传（不做解析）" "$(ap_val "$d" ok_body)" '{"records":[{"id":7,"signState":0}]}'
  t_eq "查询：URL 与既有调用点一致" "$(ap_val "$d" ok_url)" \
    "http://stuhtapi.fafu.edu.cn/health-api/sign_in/student/my/page?rows=3&pageNum=1"
  t_eq "查询：签名用的是不含查询串的 URL" "$(ap_val "$d" ok_sig_url)" "yes"
  t_eq "失败：退出码原样交给调用方（1）" "$(ap_val "$d" fail_rc)" "1"
  t_eq "失败：响应体为空（不伪造正文）" "$(ap_val "$d" fail_body)" "[]"
  t_eq "提交签到：URL 与既有调用点一致" "$(ap_val "$d" fail_url)" \
    "http://stuhtapi.fafu.edu.cn/health-api/sign_in/7/student/sign?lng=119.243462&lat=26.088417"
  t_eq "提交签到：签名 URL 同样不含查询串" "$(ap_val "$d" fail_sig_url)" "yes"
  t_eq "超时：退出码原样交给调用方（143）" "$(ap_val "$d" timeout_rc)" "143"
  t_eq "查询串为空时 URL 不带 ?" "$(ap_val "$d" noquery_url)" \
    "http://stuhtapi.fafu.edu.cn/health-api/sign_in/student/my/page"
  t_eq "不向调用方泄漏中间量（ts/nonce/hash/url/auth）" "$(ap_val "$d" leak)" \
    "[SENTINEL|SENTINEL|SENTINEL|SENTINEL|SENTINEL]"
}

# ============================================================
# 四、真实网络层交给系统执行的命令行（含 wget 超时选项的探测）
#
# 替身 busybox 把 wget 拦下来记录参数并给出响应；探测结果由 wget/help 的内容决定，
# 于是「支持 -T」与「不支持 -T」两条路径都能在这里跑出来。同一个替身顺带覆盖
# 「失败原因转交」：成功时 stderr 静默，失败时把 wget 的报错正文交给调用方。
# ============================================================

ap_case_wget_cmd() {
  local d
  ap_setup
  ap_write_env
  cat > "$AP_WORK/_wget_body.sh" <<'DRIVER'
: > wget/calls                          # 每次运行只留本次调用（两次运行共用这一份记录）
printf 'RESP-BODY-1' > wget/body
: > wget/stderr                         # 成功档：wget -q 是安静的
: > wget/hdr                            # 这一档工具没吐服务端响应（老构建 / 直接透传）
printf '7' > wget/rc
resp=$(http_post "http://host/health-api/x?q=1" "AUTH-VALUE"); rc=$?
printf 'rc=%s\n' "$rc"
printf 'body=%s\n' "$resp"
printf 'wget_t=[%s]\n' "$WGET_T"
printf 'cmd=%s\n' "$(cat wget/calls)"
printf 'calls=%s\n' "$(grep -c . wget/calls)"
printf 'ok_errlog=[%s]\n' "$(cat "$API_ERRLOG" 2>/dev/null)"
# 失败档：报错正文必须落到 API_ERRLOG 上，并由 api 在确认失败后转交出来
printf 'wget: server returned error: HTTP/1.1 503 Service Unavailable\n' > wget/stderr
: > wget/body
http_post "http://host/health-api/x?q=1" "AUTH-VALUE" >/dev/null
printf 'fail_errlog=%s\n' "$(cat "$API_ERRLOG" 2>/dev/null)"
resp=$(api "sign_in/7/student/sign" "lng=1&lat=2" "TOK" 2>ap.captured); rc=$?
printf 'api_rc=%s\n' "$rc"
printf 'api_stderr=%s\n' "$(cat ap.captured)"
DRIVER

  # ① 探测到 -T：命令行带上超时选项（参数逐个比对，边界不清的拼接串证明不了什么）
  ap_run wget_t < "$AP_WORK/_wget_body.sh"
  d="$AP_WORK/wget_t.out"
  t_eq "网络层退出码原样返回（7）" "$(ap_val "$d" rc)" "7"
  t_eq "响应体原样返回" "$(ap_val "$d" body)" "RESP-BODY-1"
  # 成功也留一行（旧行为是成功什么都不写）：这一档有正文但退出码非 0（wget 拿不到 4xx 的
  # 正文，替代品是它自己那句报错），故写 net rc= 与正文——「成功那次长什么样」从此有据可查。
  t_has "有正文的失败档：退出码与正文写在同一行" "$d" 'ok_errlog=[net rc=7 http=- body=RESP-BODY-1'
  t_has "失败时写退出码与 wget 的原始报错" "$d" \
    'fail_errlog=net rc=7 http=- err=wget: server returned error: HTTP/1.1 503 Service Unavailable'
  t_has "失败时 api 把整行转交出去（调用方读 stderr 即得）" "$d" \
    'api_stderr=net rc=7 http=- err=wget: server returned error: HTTP/1.1 503 Service Unavailable'
  t_eq "转交不吞掉返回码（仍是替身给的那个非 0 值）" "$(ap_val "$d" api_rc)" "7"
  t_eq "探测到 -T：超时选项就位" "$(ap_val "$d" wget_t)" "[-T 20]"
  t_eq "命令行与既有调用点逐字一致（含 -S 服务端响应、超时选项、请求头、POST 语义）" "$(ap_val "$d" cmd)" \
    'wget|-q|-S|-T|20|-O|-|--header=Authorization: AUTH-VALUE|--post-data=|http://host/health-api/x?q=1|'
  t_eq "一次调用只发一次请求" "$(ap_val "$d" calls)" "1"

  # ② 探测不到 -T：同一份代码必须自动省略，其余逐字不变
  printf 'BusyBox v1.35.0 wget（这个构建没启用超时选项）\n' > "$AP_WORK/wget/help"
  ap_run wget_not < "$AP_WORK/_wget_body.sh"
  d="$AP_WORK/wget_not.out"
  t_eq "探测不到 -T：超时选项为空" "$(ap_val "$d" wget_t)" "[]"
  t_eq "探测不到 -T：命令行自动省略（其余逐字不变）" "$(ap_val "$d" cmd)" \
    'wget|-q|-S|-O|-|--header=Authorization: AUTH-VALUE|--post-data=|http://host/health-api/x?q=1|'
  t_hasnt "探测不到 -T：命令行里不再出现 -T" "$d" "|-T|"

  # ③ curl 路径：正文与状态码必须能正确切分，失败时两样都进诊断文件。
  # 每个驱动都从 _env.sh 起跑（那里已把标记建好），故驱动自己删标记再显式指定工具。
  ap_run curl_path <<'DRIVER'
rm -f mod/.fafu_no_curl
CURL_BIN='./bin/curl'
printf '503\n' > curl_code
printf '%s' '{"timestamp":1,"status":503,"message":"Service Unavailable"}' > curl_body
: > curl_calls
resp=$(http_post "http://host/health-api/x?q=1" "AUTH-VALUE"); rc=$?
printf 'rc=%s\n' "$rc"
printf 'body=[%s]\n' "$resp"
printf 'errlog=[%s]\n' "$(cat "$API_ERRLOG" 2>/dev/null)"
printf 'calls=%s\n' "$(grep -c . curl_calls)"
printf 'argv=%s\n' "$(cat curl_calls)"
printf '200\n' > curl_code
printf '%s' '{"records":[{"id":7}]}' > curl_body
resp=$(http_post "http://host/health-api/x?q=1" "AUTH-VALUE"); rc=$?
printf 'ok_rc=%s\n' "$rc"
printf 'ok_body=[%s]\n' "$resp"
DRIVER
  d="$AP_WORK/curl_path.out"
  t_eq "curl 路径：状态码 503 判成失败" "$(ap_val "$d" rc)" "1"
  t_eq "curl 路径：失败响应体不作正常结果交出去" "$(ap_val "$d" body)" "[]"
  t_has "curl 路径：诊断文件里同时有状态码与正文" "$d" \
    'errlog=[http=503 body={"timestamp":1,"status":503,"message":"Service Unavailable"}'
  t_eq "curl 路径：成功返回 0" "$(ap_val "$d" ok_rc)" "0"
  # 断言「状态码那一行被剥掉」这件事本身，不去比对取值的尾字符——
  # printf 的收尾括号在不同 shell 下会落到同行的不同位置（$( ) 是否剥尾部换行），
  # 那种差异不是产品行为，钉它只会让断言在别的平台假红。
  t_eq "curl 路径：成功时调用方拿到的正文里不含附加的状态码行" \
    "$(grep -c '^ok_body=.*200' "$d" 2>/dev/null)" "0"
  t_has "curl 路径：成功时正文本身完整（响应体原样交出）" "$d" '{"records":[{"id":7}]}'
  t_eq "curl 路径：一次调用只发一次请求" "$(ap_val "$d" calls)" "1"
  t_has "curl 路径：带上 POST 与 Authorization 头" "$d" "|-X|POST|-H|Authorization: AUTH-VALUE|"

  # ④ wget 兜底：模块目录有 .fafu_no_curl 标记时回到 busybox wget
  # （标记在 ap_setup 里已建好，这条路径正是既有断言走的那条，这里只验证失败留痕）
  ap_run no_curl <<'DRIVER'
: > wget/calls
printf '7' > wget/rc
printf 'wget: server returned error: HTTP/1.1 401\n' > wget/stderr
CURL_BIN=''            # 上一个驱动删掉了标记文件，这里显式声明「本机没有 curl」
http_post "http://host/health-api/x?q=1" "AUTH-VALUE" >/dev/null; rc=$?
printf 'rc=%s\n' "$rc"
printf 'errlog=[%s]\n' "$(cat "$API_ERRLOG" 2>/dev/null)"
printf 'wget_calls=%s\n' "$(grep -c . wget/calls)"
DRIVER
  d="$AP_WORK/no_curl.out"
  t_eq "无 curl：回落到 wget 并原样返回退出码" "$(ap_val "$d" rc)" "7"
  t_eq "无 curl：一次调用只发一次请求" "$(ap_val "$d" wget_calls)" "1"
  t_has "无 curl：报错原文仍进诊断行" "$d" \
    "errlog=[net rc=7 http=- err=wget: server returned error: HTTP/1.1 401"

  # ⑤ 坏 curl：文件在、可执行，但一跑就失败（缺动态库的设备 curl 就是这样）。
  # 探测必须**认「能跑」而不是「文件在」**，否则每次请求都失败且看不出原因。
  ap_run bad_curl <<'DRIVER'
rm -f mod/.fafu_no_curl
printf '#!/bin/sh\nexit 1\n' > bin/curl
chmod +x bin/curl
: > wget/calls
printf '5' > wget/rc
printf 'wget: server returned error: HTTP/1.1 500\n' > wget/stderr
unset CURL_BIN
_curl_probe          # 重新探测：坏 curl 应被跳过
printf 'probed=[%s]\n' "$CURL_BIN"
http_post "http://host/health-api/x?q=1" "AUTH-VALUE" >/dev/null
printf 'rc=%s\n' "$?"
printf 'wget_calls=%s\n' "$(grep -c . wget/calls)"
DRIVER
  d="$AP_WORK/bad_curl.out"
  t_eq "坏 curl：探测结果为空（不认「文件在」）" "$(ap_val "$d" probed)" "[]"
  t_eq "坏 curl：请求交给 wget 兜底（不是让坏 curl 硬发）" "$(ap_val "$d" wget_calls)" "1"
  t_eq "坏 curl：返回码来自 wget" "$(ap_val "$d" rc)" "5"

  # ⑥ 探测与调用都要清掉 LD_LIBRARY_PATH：管理器的终端会往它里面塞自己的旧 libcrypto，
  # 动态链接器优先加载后，本该能跑的系统 curl 会因缺符号而起不来（清掉就能跑）。
  # 用替身观察「起跑时的该变量」——这不是命令行参数能看出来的东西，故由替身自己记。
  cat > "$AP_WORK/bin/curl" <<'CURLSTUB2'
#!/bin/sh
for _a in "$@"; do
  [ "$_a" = "--version" ] && { printf 'ver=[%s]\n' "${LD_LIBRARY_PATH:-<unset>}" >> curl_probe_env; exit 0; }
done
printf 'call=[%s]\n' "${LD_LIBRARY_PATH:-<unset>}" >> curl_call_env
printf 'ok\n'
CURLSTUB2
  chmod +x "$AP_WORK/bin/curl" 2>/dev/null
  ap_run clean_env <<'DRIVER'
rm -f mod/.fafu_no_curl curl_probe_env curl_call_env
unset CURL_BIN
LD_LIBRARY_PATH='/mt/old/lib'
export LD_LIBRARY_PATH
_curl_probe
printf 'probed=[%s]\n' "$CURL_BIN"
http_post "http://host/health-api/x?q=1" "AUTH" >/dev/null
DRIVER
  d="$AP_WORK/clean_env.out"
  # 期望值带上 printf 的方括号：断言取的是「文件里的那一行」（同本文件其它同类断言）
  t_eq "探测：替身真的被跑到（否则下面两条是空转）" "$(ap_val "$d" probed)" "[./bin/curl]"
  t_eq "探测时清掉了 LD_LIBRARY_PATH" "$(cat "$AP_WORK/curl_probe_env" 2>/dev/null | tr -d '\r\n')" "ver=[<unset>]"
  t_eq "调用时同样清掉（否则换个终端就退化）" "$(cat "$AP_WORK/curl_call_env" 2>/dev/null | tr -d '\r\n')" "call=[<unset>]"
}

# ============================================================
# 五、共享 curl 替身（测试底座 t_curl_stub 的自证）
#
# 这个替身是「注入一次网络调用的全部事实」的唯一入口：探测与 POST 两种调用都支持，
# 逐个参数落盘、能把响应头写进 `-D` 指定的落点、退出码可按需注入。
# 它自己也要被断言：否则「响应头注入」这类能力可能整段空转（跑通了却什么都没写）。
# ============================================================

ap_case_curl_stub() {
  local d
  ap_setup
  ap_write_env
  ap_run curl_stub <<'DRIVER'
rm -f mod/.fafu_no_curl
: > curl_dpaths
# 探测：--version 能被 _curl_probe 认下（认「能跑」而不是「文件在」）
unset CURL_BIN
_curl_probe
printf 'probed=[%s]\n' "$CURL_BIN"
# 一次 POST：响应头写进 -D 落点、落点被记下、逐个参数落盘、状态码仍附在正文之后
printf 'HTTP/1.1 200 OK\nDate: Mon, 13 Oct 2025 21:30:00 GMT\nServer: nginx\n\n' > curl_hdr
printf '%s' '{"ok":1}' > curl_body
printf '200\n' > curl_code
: > curl_calls
LD_LIBRARY_PATH= ./bin/curl -sS -X POST -H "Authorization: AUTH" -D ./hdr.out \
  -w '\n%{http_code}' "http://host/x" > direct.out 2> direct.err
printf 'direct_rc=%s\n' "$?"
printf 'landing=%s\n' "$(cat curl_dpaths)"
printf 'hdr_written=%s\n' "$(grep -c '^Date: Mon, 13 Oct 2025 21:30:00 GMT' ./hdr.out)"
printf 'code=%s\n' "$(tail -n1 direct.out)"
printf 'argv=%s\n' "$(cat curl_calls)"
# 退出码是注入的：连接层失败那一档全靠它（真实 curl 连不上时正文为空、状态码 000）
printf '000\n' > curl_code
printf '7\n' > curl_rc
printf 'curl: (7) Failed to connect\n' > curl_stderr
LD_LIBRARY_PATH= ./bin/curl -sS "http://host/x" >/dev/null 2> direct.err
printf 'rc_fail=%s\n' "$?"
printf 'stderr=%s\n' "$(cat direct.err)"
DRIVER
  d="$AP_WORK/curl_stub.out"
  t_eq "替身：探测能选中它（_curl_probe 认的是能跑）" "$(ap_val "$d" probed)" "[./bin/curl]"
  t_eq "替身：一次 POST 正常跑完" "$(ap_val "$d" direct_rc)" "0"
  t_eq "替身：-D 落点被记录（断言才知道响应头写到了哪）" "$(ap_val "$d" landing)" "./hdr.out"
  t_eq "替身：响应头真的写进了那个落点" "$(ap_val "$d" hdr_written)" "1"
  t_eq "替身：状态码仍附在正文之后（-w 的既有语义）" "$(ap_val "$d" code)" "200"
  t_has "替身：命令行逐个参数落盘（含 -D 与 -w）" "$d" '|-D|./hdr.out|'
  t_eq "替身：退出码按控制文件注入" "$(ap_val "$d" rc_fail)" "7"
  t_eq "替身：报错原文打到 stderr" "$(ap_val "$d" stderr)" "curl: (7) Failed to connect"
}

# ============================================================
# 六、curl 路径：一次调用留下的一行完整事实
#
# 这一缝钉住 API_ERRLOG 的单行协议（上层原样转交它，不自己拼 http= / body= / hdr=）：
# 状态码、正文、响应头白名单四项、耗时都在同一行里，成功那一档也留。
# 响应头由替身写进被测代码指定的 -D 落点（能注入才测得到解析这一段）。
# ============================================================

ap_case_curl_line() {
  local d
  ap_setup
  ap_write_env
  ap_run curl_line <<'DRIVER'
rm -f mod/.fafu_no_curl
CURL_BIN='./bin/curl'
# ① 四项白名单都给（服务端发的顺序与白名单顺序不同），另加两个不在白名单里的头
printf 'HTTP/1.1 200 OK\nDate: Mon, 13 Oct 2025 21:30:00 GMT\nContent-Type: application/json;charset=UTF-8\nContent-Length: 42\nServer: nginx\nX-Request-Id: 7f3a\nSet-Cookie: JSESSIONID=abc\n\n' > curl_hdr
printf '%s' '{"records":[]}' > curl_body
printf '200\n' > curl_code
: > curl_dpaths
resp=$(http_post "http://host/x" "AUTH"); rc=$?
printf 'ok_rc=%s\n' "$rc"
printf 'ok_body=[%s]\n' "$resp"
cat "$API_ERRLOG" > ok.line
printf 'ok_dpaths=%s\n' "$(grep -c . curl_dpaths)"
# ② 只给一项，另一项给了空值：空占位不能出现
printf 'HTTP/1.1 200 OK\r\nDate: Tue, 14 Oct 2025 09:00:00 GMT\r\nServer:\r\n\r\n' > curl_hdr
printf '503\n' > curl_code
printf '%s' '{"status":503}' > curl_body
http_post "http://host/x" "AUTH" >/dev/null; rc=$?
printf 'fail_rc=%s\n' "$rc"
cat "$API_ERRLOG" > fail.line
# ③ 一个白名单头都没给：整段 hdr= 不出现（也不留空占位）
: > curl_hdr
printf '201\n' > curl_code
printf '%s' '{"ok":1}' > curl_body
http_post "http://host/x" "AUTH" >/dev/null
cat "$API_ERRLOG" > nohdr.line
DRIVER
  d="$AP_WORK/curl_line.out"
  t_eq "curl 路径：成功返回 0" "$(ap_val "$d" ok_rc)" "0"
  t_eq "curl 路径：诊断行不混进交给调用方的正文" "$(ap_val "$d" ok_body)" '[{"records":[]}]'
  t_eq "curl 路径：这次调用确实向 curl 要了响应头（-D 落点）" "$(ap_val "$d" ok_dpaths)" "1"
  t_has "curl 路径：成功也留下整行（状态码 + 正文 + 响应头）" "$AP_WORK/ok.line" \
    'http=200 body={"records":[]} hdr={Date: Mon, 13 Oct 2025 21:30:00 GMT|Content-Length: 42|Content-Type: application/json;charset=UTF-8|Server: nginx}'
  t_lines "curl 路径：一次调用只留一行（值里不带换行）" "$AP_WORK/ok.line" 1
  t_hasnt "curl 路径：白名单之外的头不落日志（请求号）" "$AP_WORK/ok.line" "X-Request-Id"
  t_hasnt "curl 路径：白名单之外的头不落日志（Cookie）" "$AP_WORK/ok.line" "JSESSIONID"
  t_hasnt "curl 路径：状态行不混进 hdr= 段" "$AP_WORK/ok.line" "hdr={HTTP/1.1"
  t_eq "curl 路径：非 2xx 仍是失败" "$(ap_val "$d" fail_rc)" "1"
  t_has "curl 路径：失败同样给状态码与正文" "$AP_WORK/fail.line" \
    'http=503 body={"status":503}'
  t_has "curl 路径：服务端给了的那一项照写（顺序由白名单定）" "$AP_WORK/fail.line" \
    'hdr={Date: Tue, 14 Oct 2025 09:00:00 GMT}'
  t_hasnt "curl 路径：空值的头不写空占位" "$AP_WORK/fail.line" "Server:"
  t_has "curl 路径：四项全无时正文照旧完整" "$AP_WORK/nohdr.line" 'http=201 body={"ok":1}'
  t_hasnt "curl 路径：四项全无时整段 hdr= 不出现" "$AP_WORK/nohdr.line" "hdr="
}

# ============================================================
# 七、响应体上限：正常响应完整落盘，只有超过 2KB 才截断
#
# 截断是「事后读不到服务端那句话」的根源，所以两侧都要钉：边界内必须逐字完整，
# 越界时必须标明「这不是服务端只回了这么多」——标记与原始字节数在同一行里。
# ============================================================

ap_case_body_cap() {
  local d
  ap_setup
  ap_write_env
  ap_run body_cap <<'DRIVER'
rm -f mod/.fafu_no_curl
CURL_BIN='./bin/curl'
printf '200\n' > curl_code
# ① 200 字节（旧上限 300 之内）
"$BB" awk 'BEGIN{for(i=0;i<200;i++) printf "a"}' > curl_body
http_post "http://host/x" "AUTH" >/dev/null
cat "$API_ERRLOG" > small.line
# ② 500 字节：跨过旧上限（300）但仍在 2KB 之内，必须完整
"$BB" awk 'BEGIN{for(i=0;i<500;i++) printf "b"}' > curl_body
http_post "http://host/x" "AUTH" >/dev/null
cat "$API_ERRLOG" > mid.line
# ③ 正好 2KB：「超过 2KB 才截断」这句话里，它属于不截的那一侧
"$BB" awk 'BEGIN{for(i=0;i<2048;i++) printf "c"}' > curl_body
http_post "http://host/x" "AUTH" >/dev/null
cat "$API_ERRLOG" > exact.line
# ④ 2500 字节：截断，并给出原始字节数
"$BB" awk 'BEGIN{for(i=0;i<2500;i++) printf "d"}' > curl_body
http_post "http://host/x" "AUTH" >/dev/null
cat "$API_ERRLOG" > big.line
printf 'small=%s\n' "$(sed 's/.*body=//; s/ .*//' small.line | tr -d '\n' | "$BB" wc -c | tr -dc '0-9')"
printf 'mid=%s\n'   "$(sed 's/.*body=//; s/ .*//' mid.line   | tr -d '\n' | "$BB" wc -c | tr -dc '0-9')"
printf 'exact=%s\n' "$(sed 's/.*body=//; s/ .*//' exact.line | tr -d '\n' | "$BB" wc -c | tr -dc '0-9')"
printf 'big=%s\n'   "$(sed 's/.*body=//; s/ .*//' big.line   | tr -d '\n' | "$BB" wc -c | tr -dc '0-9')"
printf 'biglen=%s\n' "$(sed 's/.*bodylen=//; s/ .*//' big.line)"
printf 'bigmark=%s\n' "$(sed 's/.*trunc=//; s/ .*//' big.line)"
printf 'midmark=%s\n' "$(grep -c 'trunc=' mid.line)"
DRIVER
  d="$AP_WORK/body_cap.out"
  t_eq "200 字节：完整（不默认截断）" "$(ap_val "$d" small)" "200"
  t_eq "500 字节：完整（旧上限已不在）" "$(ap_val "$d" mid)" "500"
  t_eq "正好 2KB：仍在「不截断」那一侧" "$(ap_val "$d" exact)" "2048"
  t_eq "越界：正文只留前 2048 字节" "$(ap_val "$d" big)" "2048"
  t_eq "越界：同一行给出原始字节数" "$(ap_val "$d" biglen)" "2500"
  t_eq "越界：标明这一档被截断" "$(ap_val "$d" bigmark)" "1"
  t_eq "边界内：不带任何截断字段" "$(ap_val "$d" midmark)" "0"
  t_hasnt "边界内：正文里没有原始字节数字段" "$AP_WORK/mid.line" "bodylen="
}

# ============================================================
# 八、每次调用记耗时（毫秒优先，取不到退化为秒）
#
# 「窗口刚开那几秒」与「服务端一直不理我」只能靠耗时分开，故每一档都要带上它；
# 值里自带单位后缀——只给数字的话，事后分不出这一行是毫秒还是秒。
# **取哪一档由环境能力决定**（`date +%s%3N` 是 busybox 的可选特性，没编进去就退化为秒），
# 故真实调用那两条只钉「值 + 单位一定在」，单位规则由下面两条喂固定读数的断言钉死。
# ============================================================

ap_case_cost() {
  local d
  ap_setup
  ap_write_env
  ap_run cost <<'DRIVER'
rm -f mod/.fafu_no_curl
CURL_BIN='./bin/curl'
printf '200\n' > curl_code
printf '%s' '{"ok":1}' > curl_body
http_post "http://host/x" "AUTH" >/dev/null
cat "$API_ERRLOG" > ok.line
printf '503\n' > curl_code
printf '%s' '{"status":503}' > curl_body
http_post "http://host/x" "AUTH" >/dev/null
cat "$API_ERRLOG" > fail.line
# 单位判定：13 位读数（date +%s%3N）→ 毫秒；10 位读数 → 秒
_api_note 0 200 '{"ok":1}' "" "" 1791704215000 1791704215250
cat "$API_ERRLOG" > ms.line
_api_note 0 200 '{"ok":1}' "" "" 1791704215 1791704225
cat "$API_ERRLOG" > s.line
# %N 不可用那一档（Ubuntu 的 busybox-static 就没编 FEATURE_DATE_NANO）：
# 退到 /proc/uptime——两位小数＝10 毫秒精度，读数补零到 13 位，故单位仍是毫秒。
# 造两个读数（1000.00 → 1000.50）看差值是不是 500ms：补零的读数一旦被当成八进制，
# 这里要么报语法错、要么静默算错，都会立刻现形。
export MOCK_DATE_NO_NANO=1
API_UPTIME='./uptime'; export API_UPTIME
printf '1000.00 9.00\n' > uptime
a=$(_api_now)
printf '1000.50 9.00\n' > uptime
b=$(_api_now)
printf 'digits=%s\n' "${#a}"
printf 'cost=%s\n' "$(_api_cost "$a" "$b")"
DRIVER
  t_has_re "成功档带耗时（值 + 单位）" "$AP_WORK/ok.line" 'http=200 .* 耗时=[0-9]+(ms|s)'
  t_has_re "失败档同样带耗时（值 + 单位）" "$AP_WORK/fail.line" 'http=503 .* 耗时=[0-9]+(ms|s)'
  t_has "13 位读数：按毫秒算（两个读数差 250）" "$AP_WORK/ms.line" "耗时=250ms"
  t_has "取不到毫秒：退化为秒（两个读数差 10）" "$AP_WORK/s.line" "耗时=10s"
  d="$AP_WORK/cost.out"
  t_eq "没编 %N 时改用 uptime：读数仍是 13 位（毫秒档）" "$(ap_val "$d" digits)" "13"
  t_eq "没编 %N 时：差值按毫秒算（0.5 秒 = 500ms）" "$(ap_val "$d" cost)" "耗时=500ms"
}

# ============================================================
# 九、连接层失败：原始报错与退出码，不伪造状态码
#
# 「连不上」与「服务端拒绝」在旧日志里长得一样（都只有一个非 0 退出码），
# 这一档要能一眼分开：工具退出码 + 工具原话，且**不拿 -w 的 000 冒充状态码**。
# 正文拿不到时连 body= 都不写——空占位会被读成「服务端回了空正文」。
# ============================================================

ap_case_net_fail() {
  local d
  ap_setup
  ap_write_env
  ap_run net_fail <<'DRIVER'
rm -f mod/.fafu_no_curl
CURL_BIN='./bin/curl'
# ① 连不上：curl 退出码 7，没有状态码也没有正文（-w 这时给的是 000）
printf '000\n' > curl_code
: > curl_body
printf 'curl: (7) Failed to connect to stuhtapi.fafu.edu.cn port 80: Connection refused\n' > curl_stderr
printf '7\n' > curl_rc
http_post "http://host/x" "AUTH" >/dev/null; rc=$?
printf 'refused_rc=%s\n' "$rc"
cat "$API_ERRLOG" > refused.line
# ② 超时：退出码 28，报错原文照写；api 在确认失败后把整行转交出去
printf 'curl: (28) Operation timed out after 20000 milliseconds\n' > curl_stderr
printf '28\n' > curl_rc
api "sign_in/student/my/page" "rows=1&pageNum=1" "TOK" >/dev/null 2> relayed.txt; rc=$?
printf 'timeout_rc=%s\n' "$rc"
cat "$API_ERRLOG" > timeout.line
printf 'relayed=%s\n' "$(cat relayed.txt)"
# ③ 报错本身多行：只取首行，诊断文件仍只有一行
printf 'curl: (7) Failed to connect\ncurl: extra line that must not leak\n' > curl_stderr
printf '7\n' > curl_rc
http_post "http://host/x" "AUTH" >/dev/null
cat "$API_ERRLOG" > multiline.line
# ④ 超时前服务端已经吐了半截正文：拿到了就如实写，不假装拿不到
printf 'curl: (28) Operation timed out\n' > curl_stderr
printf '%s' '{"part":' > curl_body
http_post "http://host/x" "AUTH" >/dev/null
cat "$API_ERRLOG" > partial.line
DRIVER
  d="$AP_WORK/net_fail.out"
  t_eq "连不上：退出码原样返回（7）" "$(ap_val "$d" refused_rc)" "7"
  t_has "连不上：写 net rc= 与原始报错原文" "$AP_WORK/refused.line" \
    'net rc=7 http=- err=curl: (7) Failed to connect to stuhtapi.fafu.edu.cn port 80: Connection refused'
  t_hasnt "连不上：不拿 -w 的 000 冒充状态码" "$AP_WORK/refused.line" "http=000"
  t_hasnt "连不上：正文拿不到就不写 body=" "$AP_WORK/refused.line" "body="
  t_lines "连不上：诊断文件恰好一行" "$AP_WORK/refused.line" 1
  t_eq "超时：退出码原样返回（28）" "$(ap_val "$d" timeout_rc)" "28"
  t_has "超时：同一档形态，报错原文也在" "$AP_WORK/timeout.line" \
    'net rc=28 http=- err=curl: (28) Operation timed out after 20000 milliseconds'
  t_has "失败时 api 把整行转交出去（上层原样带上即可）" "$d" \
    'relayed=net rc=28 http=- err=curl: (28) Operation timed out after 20000 milliseconds'
  t_lines "报错多行：诊断文件仍只有一行" "$AP_WORK/multiline.line" 1
  t_hasnt "报错多行：第二行不漏进诊断行" "$AP_WORK/multiline.line" "must not leak"
  t_has "超时前拿到半截正文：如实写进 body=" "$AP_WORK/partial.line" 'body={"part":'
}

# ============================================================
# 十、wget 兜底路径：同一行事实，拿到什么写什么
#
# 没有可用 curl 的设备上，状态码与响应头来自 `wget -S`（busybox 把服务端响应——
# 状态行 + 缩进两格的头行——打到 stderr）。于是：
#   拿得到状态码 → 与 curl 同形（`http=<码>`），白名单四项照取自那段响应；
#   拿不到（老构建没吐 / 连不上） → 维持 `net rc=<退出码> http=-`，不拿退出码冒充状态码。
# 工具自己那句报错仍留在 `err=`：`-S` 之后它不再是 stderr 首行，故按 `wget:` 前缀取。
# ============================================================

ap_case_wget_line() {
  local d
  ap_setup
  ap_write_env
  ap_run wget_line <<'DRIVER'
CURL_BIN=''            # 显式声明「本机没有 curl」，走兜底路径
: > wget/calls
# ① 成功：-S 吐了状态行与四项头（缩进两格，与真机同形）
printf '  HTTP/1.1 200 OK\n  Date: Mon, 13 Oct 2025 21:30:00 GMT\n  Content-Length: 13\n  Content-Type: application/json;charset=UTF-8\n  Server: nginx\n' > wget/hdr
: > wget/stderr
printf 'RESP-BODY-1' > wget/body
printf '0' > wget/rc
resp=$(http_post "http://host/x?q=1" "AUTH"); rc=$?
printf 'ok_rc=%s\n' "$rc"
printf 'ok_body=[%s]\n' "$resp"
cat "$API_ERRLOG" > ok.line
# ② 工具没吐响应（这一档没有状态码、也没有响应头）：如实写 net rc=，整段 hdr= 不出现
: > wget/hdr
: > wget/body
printf '0' > wget/rc
http_post "http://host/x?q=1" "AUTH" >/dev/null
cat "$API_ERRLOG" > noresp.line
# ③ 服务端拒绝：真机 -S 在错误档只吐状态行（头行根本没读），工具那句原话仍在 stderr
printf '  HTTP/1.1 503 Service Unavailable\n' > wget/hdr
printf 'wget: server returned error: HTTP/1.1 503 Service Unavailable\n' > wget/stderr
printf '7' > wget/rc
http_post "http://host/x?q=1" "AUTH" >/dev/null; rc=$?
printf 'fail_rc=%s\n' "$rc"
cat "$API_ERRLOG" > fail.line
# ④ 连不上：没有状态行 → 维持 net rc= 那档，报错原文照写
: > wget/hdr
printf "wget: can't connect to remote host (127.0.0.1)\n" > wget/stderr
printf '1' > wget/rc
http_post "http://host/x?q=1" "AUTH" >/dev/null
cat "$API_ERRLOG" > refused.line
printf 'wget_calls=%s\n' "$(grep -c . wget/calls)"
DRIVER
  d="$AP_WORK/wget_line.out"
  t_eq "wget 路径：成功返回 0" "$(ap_val "$d" ok_rc)" "0"
  t_eq "wget 路径：正文原样交给调用方" "$(ap_val "$d" ok_body)" "[RESP-BODY-1]"
  t_has "wget 路径：-S 给得出状态码时就写 http=（与 curl 同形）" "$AP_WORK/ok.line" \
    'http=200 body=RESP-BODY-1'
  t_has "wget 路径：白名单四项取自 -S 那段响应（顺序固定）" "$AP_WORK/ok.line" \
    'hdr={Date: Mon, 13 Oct 2025 21:30:00 GMT|Content-Length: 13|Content-Type: application/json;charset=UTF-8|Server: nginx}'
  t_hasnt "wget 路径：状态行不混进 hdr= 段" "$AP_WORK/ok.line" "hdr={HTTP/"
  t_hasnt "wget 路径：没有报错就不写 err=" "$AP_WORK/ok.line" "err="
  t_has "wget 路径：工具没吐响应时没有状态码，如实写 net rc=" "$AP_WORK/noresp.line" \
    'net rc=0 http=- 耗时='
  t_hasnt "wget 路径：拿不到响应头就不写 hdr=（能力边界，不是服务端没给）" "$AP_WORK/noresp.line" "hdr="
  t_hasnt "wget 路径：正文拿不到就不写 body=" "$AP_WORK/noresp.line" "body="
  t_eq "wget 路径：拒绝档退出码原样返回（7）" "$(ap_val "$d" fail_rc)" "7"
  t_has "wget 路径：拒绝档给状态码，工具那句原话仍进 err=" "$AP_WORK/fail.line" \
    'http=503 body= err=wget: server returned error: HTTP/1.1 503 Service Unavailable'
  t_hasnt "wget 路径：状态行不被当成报错原文" "$AP_WORK/fail.line" "err=  HTTP/"
  t_has "wget 路径：连不上时维持 net rc= 那档（不伪造状态码）" "$AP_WORK/refused.line" \
    "net rc=1 http=- err=wget: can't connect to remote host (127.0.0.1)"
  t_hasnt "wget 路径：连不上时不写数字状态码" "$AP_WORK/refused.line" "http=1"
  t_eq "wget 路径：一次调用只发一次请求（四次调用四行记录）" "$(ap_val "$d" wget_calls)" "4"
}

# ============================================================
# 十一、诊断行的单行协议：值压平、每次调用只有一行
#
# 上层把这一行原样贴进日志（`事件名: 键=值 …`），故值里**不能**有换行或制表符：
# 否则一条事实被摊成多行，事后分不清哪一段属于哪一次调用；文件也不能累积历史行。
# ============================================================

ap_case_line_protocol() {
  local d
  ap_setup
  ap_write_env
  ap_run line_protocol <<'DRIVER'
rm -f mod/.fafu_no_curl
CURL_BIN='./bin/curl'
printf '200\n' > curl_code
# 正文里有制表符、换行、回车：进日志前都该被压掉
printf 'a\tb\nc\rd' > curl_body
http_post "http://host/x" "AUTH" >/dev/null
cat "$API_ERRLOG" > flat.line
printf 'lines=%s\n' "$(grep -c . flat.line)"
printf 'tabs=%s\n' "$(tr -dc "$(printf '\t')" < flat.line | wc -c | tr -dc '0-9')"
printf 'crs=%s\n'  "$(tr -dc '\r' < flat.line | wc -c | tr -dc '0-9')"
# 再调一次：后一次必须覆盖前一次（不累积、也不把过时内容当成本次的）
printf '%s' 'SECOND' > curl_body
http_post "http://host/x" "AUTH" >/dev/null
cat "$API_ERRLOG" > second.line
printf 'second_lines=%s\n' "$(grep -c . second.line)"
DRIVER
  d="$AP_WORK/line_protocol.out"
  t_has "正文里的换行与制表符被压平（值只剩一片）" "$AP_WORK/flat.line" "body=abcd"
  t_eq "压平后诊断文件仍是恰好一行" "$(ap_val "$d" lines)" "1"
  t_eq "值里没有制表符" "$(ap_val "$d" tabs)" "0"
  t_eq "值里没有回车" "$(ap_val "$d" crs)" "0"
  t_eq "第二次调用后只剩一行（先清空，不累积）" "$(ap_val "$d" second_lines)" "1"
  t_has "第二次调用的内容在文件里" "$AP_WORK/second.line" "body=SECOND"
  t_hasnt "第一次调用的内容不残留在文件里" "$AP_WORK/second.line" "body=abcd"
}

# ============================================================
# 十二、上层驱动拿真实诊断行（_api_note 接缝）
#
# 上层驱动既要控制「第几次调用返回什么」（覆盖 http_post，既有做法），又不想自己抄一份
# 字段格式（抄了就会与 api 层分叉）。接缝：把这次的事实交给 _api_note，由 api 层拼那一行。
# ============================================================

ap_case_note_seam() {
  local d
  ap_setup
  ap_write_env
  ap_run note_seam <<'DRIVER'
# 覆盖 http_post 控制应答，但**不拼格式**：那一行由 api 层写
http_post() {
  _n=$(cat seq.n 2>/dev/null); _n=$(( ${_n:-0} + 1 )); printf '%s' "$_n" > seq.n
  if [ "$_n" = "1" ]; then
    _api_note 0 400 '{"status":400,"message":"window closed"}' "" "" "$(_api_now)" "$(_api_now)"
    return 1
  fi
  _api_note 0 200 '{"code":0}' "" "" "$(_api_now)" "$(_api_now)"
  printf '%s' '{"code":0}'
  return 0
}
printf '0' > seq.n
api "sign_in/7/student/sign" "lng=1&lat=2" "TOK" >/dev/null 2> first.err; rc=$?
printf 'first_rc=%s\n' "$rc"
printf 'first=%s\n' "$(cat first.err)"
cat "$API_ERRLOG" > first.line
api "sign_in/7/student/sign" "lng=1&lat=2" "TOK" >/dev/null; rc=$?
printf 'second_rc=%s\n' "$rc"
cat "$API_ERRLOG" > second.line
DRIVER
  d="$AP_WORK/note_seam.out"
  t_eq "驱动替身：注入的失败档返回 1" "$(ap_val "$d" first_rc)" "1"
  t_has "驱动替身：失败档拿到 api 层写的整行" "$AP_WORK/first.line" \
    'http=400 body={"status":400,"message":"window closed"}'
  t_has "驱动替身：这一行同时被 api 转交到 stderr" "$d" \
    'first=http=400 body={"status":400,"message":"window closed"}'
  t_has "驱动替身：成功档同样是一整行" "$AP_WORK/second.line" 'http=200 body={"code":0}'
  t_eq "驱动替身：第二次调用后只剩一行" "$(grep -c . "$AP_WORK/second.line")" "1"
}

# ============================================================
# 十三、边界：单一网络入口与既有调用点（静态断言）
#
# 这里只用两类判据：**命令位**（行首缩进后的真实调用，注释里提到 wget 不算）与
# **产品数据**（调用的路径、查询参数）。不绑局部变量名与参数位次——名字是各层的
# 内部事，改个名不该制造假红灯。
# ============================================================

ap_case_boundary() {
  local src owners f n_api n_rc
  # 命令位的网络调用：工具名在 wget 那一支里是字面量，curl 那一支在变量里（`$CURL_BIN -sS`），
  # 故这条判据抓得到的是 wget 形态，curl 那一支另有一条判据（见下）。
  # 两条路径都把 stdout 收进变量（要拿它拼诊断行），前缀因此多一个 `body=$(`。
  net_pat='^[ ]*(body=\$\()?"?\$(CURL_BIN|BB)"? (wget|curl) '
  src="$AP_WORK/program.sh"
  mkdir -p "$AP_WORK"
  t_write_program "$src" || { _t_fail "无法拼出全程序文本"; return 0; }

  # 单一网络入口：命令位的网络调用全程序只有一处，且只有网络那一层持有它
  t_has_re "命令位的网络调用全程序只有一处" "$src" "$net_pat" 1
  owners=""
  for f in $TEST_LIB_FILES; do
    if grep -qE -e "$net_pat" "$T_ROOT/$f" 2>/dev/null; then owners="$owners ${f##*/}"; fi
  done
  t_eq "网络调用只在 api 层" "$(printf '%s\n' $owners | sort | tr '\n' ' ')" "api.sh "
  # curl 那一支的工具名在变量里、命令位前面还有一步清环境变量，上面那条正则看不见它：
  # 故单列一条，判据同样是「全程序命令位的这类调用只有一处，且只出现在网络层」——
  # 不切函数文本、也不绑引号与选项拼法（换个选项、挪个位置都不该制造假红灯）。
  curl_pat='^[ ]*(body=\$\()?(LD_LIBRARY_PATH=[ ]+)?"?\$CURL_BIN"?[ ]+-'
  t_has_re "命令位的 curl 调用全程序只有一处" "$src" "$curl_pat" 1
  owners=""
  for f in $TEST_LIB_FILES; do
    if grep -qE -e "$curl_pat" "$T_ROOT/$f" 2>/dev/null; then owners="$owners ${f##*/}"; fi
  done
  t_eq "curl 的调用也只在 api 层（不另开出口）" "$(printf '%s\n' $owners | sort | tr '\n' ' ')" "api.sh "

  # 既有调用点：请求路径与查询参数逐字钉住（比对的是产品数据，不是写法）
  t_has "查询任务：路径与参数不变" "$src" 'sign_in/student/my/page" "rows=3&pageNum=1'
  t_has "保活与手动排查：路径与参数不变" "$src" 'sign_in/student/my/page" "rows=1&pageNum=1'
  t_has "提交签到：路径与参数不变" "$src" 'sign_in/$rid/student/sign" "lng=$lng&lat=$lat'

  # 失败判定以退出码为准：每个调用点都在调完之后立刻取退出码。
  # （响应体的形状只用于判断「取到的是不是任务列表」，不是失败判据；签到层怎么分流
  # 由它自己的断言覆盖，这里只守住「退出码没有被丢掉」。）
  # 允许调用点把 stderr 重定向到文件或变量（失败原因留痕用的就是它），
  # 但**必须紧跟着取退出码**——否则调用方拿到的是别人的返回码。
  n_api=$(grep -cE -e '\$\(api "' "$src" 2>/dev/null)
  n_rc=$(grep -cE -e '\$\(api "[^"]*" "[^"]*" "[^"]*"( 2>[^)]*)?\); rc=\$\?' "$src" 2>/dev/null)
  t_ne "调用点数量不为零（否则下面的等式会空转）" "$n_api" "0"
  t_eq "每个 api 调用点都立刻取退出码" "$n_rc" "$n_api"

  # 设备侧的其余脚本（开机 / 操作按钮 / 安装 / 卸载）同样不该自己发请求
  owners=""
  for f in "$T_ROOT"/service.sh "$T_ROOT"/action.sh "$T_ROOT"/customize.sh "$T_ROOT"/uninstall.sh; do
    [ -f "$f" ] || continue
    if grep -qE -e "$net_pat" -e "$curl_pat" "$f" 2>/dev/null; then owners="$owners ${f##*/}"; fi
  done
  t_eq "开机/按钮/安装/卸载脚本都不发请求" "[$owners]" "[]"
}

# ---- 注册（顺序即执行顺序） ----

t_case "api · token 提取（按修改时间取最新）" ap_case_token
t_case "api · 签名串构造" ap_case_sign
t_case "api · 网络注入点（响应体 / 失败 / 超时）" ap_case_seam
t_case "api · 交给 wget 的命令行与超时探测" ap_case_wget_cmd
t_case "api · 共享 curl 替身（探测 / 注入响应头 / 记录命令行）" ap_case_curl_stub
t_case "api · curl 路径的一行完整事实（状态码 / 正文 / 响应头白名单）" ap_case_curl_line
t_case "api · 响应体上限（超过 2KB 才截断并给原始字节数）" ap_case_body_cap
t_case "api · 每次调用记耗时（毫秒优先，取不到退化为秒）" ap_case_cost
t_case "api · 连接层失败（原始报错与退出码，不伪造状态码）" ap_case_net_fail
t_case "api · wget 兜底路径的同一行事实（拿到什么写什么）" ap_case_wget_line
t_case "api · 单行协议（值压平 / 每次调用只有一行）" ap_case_line_protocol
t_case "api · 上层驱动拿真实诊断行（_api_note 接缝）" ap_case_note_seam
t_case "api · 单一网络入口与既有调用点" ap_case_boundary
