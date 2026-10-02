# ============================================================
# api 层验收断言：token 提取、请求签名、HTTP 调用与网络注入点
#
# 三条口径（都只针对外部可观察的行为）：
#   1) 行为：token 按文件修改时间取最新那次登录；签名串是
#      base64(时间戳:随机数:MD5(密钥+签名URL+时间戳+随机数):token)；失败只看退出码；
#   2) 缝：全程序只有 http_post() 一处真正发起网络请求——断言里覆盖同名函数即可
#      注入响应体 / 失败 / 超时；真实命令行（含超时选项探测）与被丢弃的 stderr
#      在同一个缝上用替身 busybox 断言（tests/mock/busybox 的 MOCK_WGET_DIR）；
#   3) 不变：既有调用点的请求路径、查询参数、请求头与重构前逐字一致（静态断言）。
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

# 每个用例自备环境：替身 busybox + leveldb 替身目录 + wget 的四个控制文件。
# wget 控制文件：help 决定 -T 探测结果，body / rc / stderr 决定一次调用的产物。
ap_setup() {
  rm -rf "$AP_WORK"
  mkdir -p "$AP_WORK/mod" "$AP_WORK/ld" "$AP_WORK/wget"
  t_bb_wrap "$AP_WORK/bin/bb" >/dev/null
  printf 'BusyBox v1.35.0 wget\n\t-T SEC\tNetwork timeout\n' > "$AP_WORK/wget/help"
  : > "$AP_WORK/wget/body"
  printf '0\n' > "$AP_WORK/wget/rc"
  : > "$AP_WORK/wget/calls"
  printf '0\n' > "$AP_WORK/rand.seq"     # 随机数替身的序号：两次调用必须给出不同的值
}

# 驱动脚本的公共前导：注入替身 busybox、token 目录与 wget 控制目录，再按加载顺序加载层。
ap_write_env() {
  cat > "$AP_WORK/_env.sh" <<ENV
PATH='/bin:/usr/bin'
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

# 从驱动输出里取一行（形如 key=value）
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
now=$(now_s)

printf 'api_base=%s\n' "$API"
printf 'secret=%s\n' "$SECRET"
printf 'fields=%s\n' "$(printf '%s' "$raw" | "$BB" awk -F: '{print NF}')"
printf 'hash_ok=%s\n' "$([ "$hash" = "$exp" ] && echo yes || echo no)"
printf 'url_signed=%s\n' "$([ "$hash" != "$exp2" ] && echo yes || echo no)"
printf 'ts_num=%s\n' "$(printf '%s' "$ts" | "$BB" tr -dc '0-9' | "$BB" wc -c | "$BB" tr -dc '0-9')"
printf 'ts_now=%s\n' "$([ "$ts" -ge $((now - 5)) ] && [ "$ts" -le $((now + 5)) ] && echo yes || echo no)"
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
  t_eq "查询：URL 与重构前一致" "$(ap_val "$d" ok_url)" \
    "http://stuhtapi.fafu.edu.cn/health-api/sign_in/student/my/page?rows=3&pageNum=1"
  t_eq "查询：签名用的是不含查询串的 URL" "$(ap_val "$d" ok_sig_url)" "yes"
  t_eq "失败：退出码原样交给调用方（1）" "$(ap_val "$d" fail_rc)" "1"
  t_eq "失败：响应体为空（不伪造正文）" "$(ap_val "$d" fail_body)" "[]"
  t_eq "提交签到：URL 与重构前一致" "$(ap_val "$d" fail_url)" \
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
# 于是「支持 -T」与「不支持 -T」两条路径都能在这里跑出来。
# ============================================================

ap_case_wget_cmd() {
  local d
  ap_setup
  ap_write_env
  cat > "$AP_WORK/_wget_body.sh" <<'DRIVER'
: > wget/calls                          # 每次运行只留本次调用（两次运行共用这一份记录）
printf '%s' 'RESP-BODY-1' > wget/body
printf '7' > wget/rc
printf 'wget: 报错正文不该出现在调用方 stderr\n' > wget/stderr
resp=$(http_post "http://host/health-api/x?q=1" "AUTH-VALUE"); rc=$?
printf 'rc=%s\n' "$rc"
printf 'body=%s\n' "$resp"
printf 'wget_t=[%s]\n' "$WGET_T"
printf 'cmd=%s\n' "$(cat wget/calls)"
printf 'calls=%s\n' "$(grep -c . wget/calls)"
DRIVER

  # ① 探测到 -T：命令行带上超时选项（参数逐个比对，边界不清的拼接串证明不了什么）
  ap_run wget_t < "$AP_WORK/_wget_body.sh"
  d="$AP_WORK/wget_t.out"
  t_eq "网络层退出码原样返回（7）" "$(ap_val "$d" rc)" "7"
  t_eq "响应体原样返回" "$(ap_val "$d" body)" "RESP-BODY-1"
  t_eq "探测到 -T：超时选项就位" "$(ap_val "$d" wget_t)" "[-T 20]"
  t_eq "命令行与重构前逐字一致（含超时选项、请求头、POST 语义）" "$(ap_val "$d" cmd)" \
    'wget|-q|-T|20|-O|-|--header=Authorization: AUTH-VALUE|--post-data=|http://host/health-api/x?q=1|'
  t_eq "一次调用只发一次请求" "$(ap_val "$d" calls)" "1"
  t_hasnt "wget 的报错正文被 2>/dev/null 吞掉（不进调用方 stderr）" "$AP_WORK/wget_t.err" "报错正文"

  # ② 探测不到 -T：同一份代码必须自动省略，其余逐字不变
  printf 'BusyBox v1.35.0 wget（这个构建没启用超时选项）\n' > "$AP_WORK/wget/help"
  ap_run wget_not < "$AP_WORK/_wget_body.sh"
  d="$AP_WORK/wget_not.out"
  t_eq "探测不到 -T：超时选项为空" "$(ap_val "$d" wget_t)" "[]"
  t_eq "探测不到 -T：命令行自动省略（其余逐字不变）" "$(ap_val "$d" cmd)" \
    'wget|-q|-O|-|--header=Authorization: AUTH-VALUE|--post-data=|http://host/health-api/x?q=1|'
  t_hasnt "探测不到 -T：命令行里不再出现 -T" "$d" "|-T|"
}

# ============================================================
# 五、边界：单一网络入口与既有调用点（静态断言）
#
# 这里只用两类判据：**命令位**（行首缩进后的真实调用，注释里提到 wget 不算）与
# **产品数据**（调用的路径、查询参数）。不绑局部变量名与参数位次——名字是各层的
# 内部事，改个名不该制造假红灯（见开发文档 §5.1）。
# ============================================================

ap_case_boundary() {
  local src owners f n_api n_rc
  net_pat='^[ ]*"?\$BB"? (wget|curl) '
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

  # 既有调用点：请求路径与查询参数与重构前逐字一致（比对的是产品数据，不是写法）
  t_has "查询任务：路径与参数不变" "$src" 'sign_in/student/my/page" "rows=3&pageNum=1'
  t_has "保活与手动排查：路径与参数不变" "$src" 'sign_in/student/my/page" "rows=1&pageNum=1'
  t_has "提交签到：路径与参数不变" "$src" 'sign_in/$rid/student/sign" "lng=$lng&lat=$lat'

  # 失败判定以退出码为准：每个调用点都在调完之后立刻取退出码。
  # （响应体的形状只用于判断「取到的是不是任务列表」，不是失败判据——这是重构前的
  # 既有行为，签到层怎么分流由它自己的断言覆盖，这里只守住「退出码没有被丢掉」。）
  n_api=$(grep -cE -e '\$\(api "' "$src" 2>/dev/null)
  n_rc=$(grep -cE -e '\$\(api "[^"]*" "[^"]*" "[^"]*"\); rc=\$\?' "$src" 2>/dev/null)
  t_ne "调用点数量不为零（否则下面的等式会空转）" "$n_api" "0"
  t_eq "每个 api 调用点都立刻取退出码" "$n_rc" "$n_api"

  # 设备侧的其余脚本（开机 / 操作按钮 / 安装 / 卸载）同样不该自己发请求
  owners=""
  for f in "$T_ROOT"/service.sh "$T_ROOT"/action.sh "$T_ROOT"/customize.sh "$T_ROOT"/uninstall.sh; do
    [ -f "$f" ] || continue
    if grep -qE -e "$net_pat" "$f" 2>/dev/null; then owners="$owners ${f##*/}"; fi
  done
  t_eq "开机/按钮/安装/卸载脚本都不发请求" "[$owners]" "[]"
}

# ---- 注册（顺序即执行顺序） ----

t_case "api · token 提取（按修改时间取最新）" ap_case_token
t_case "api · 签名串构造" ap_case_sign
t_case "api · 网络注入点（响应体 / 失败 / 超时）" ap_case_seam
t_case "api · 交给 wget 的命令行与超时探测" ap_case_wget_cmd
t_case "api · 单一网络入口与既有调用点" ap_case_boundary
