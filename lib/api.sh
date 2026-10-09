# ============================================================
# api 层 —— 接口：token 提取、请求签名、HTTP 调用
#
# 加载顺序：第 4 层。业务层不自己拼签名、也不直接调网络，一律经 api()；
# 全程序只有 http_post() 一处真正发起网络请求。
# 失败判定以 wget 退出码为准：busybox wget 拿不到错误响应正文。
# 对外提供：get_token / mk_auth / api / http_post。
# 配置 / 注入点（生产环境不设置）：LD_DIR=token 目录，BB_OVERRIDE=busybox 替身。
# ============================================================

SECRET="AtPs2O1xEnhwkKDV"
API="http://stuhtapi.fafu.edu.cn/health-api"
LD="${LD_DIR:-/data/data/cn.edu.fafu.iportal/app_webview/Default/Local Storage/leveldb}"

# 探测 wget 是否支持 -T 超时选项（个别 busybox 构建未启用；不支持则自动省略）。
# 与网络调用同层：改超时、加请求头、换实现都只动本层。
WGET_T=""
case "$("$BB" wget --help 2>&1)" in
  *"-T"*) WGET_T="-T 20" ;;
esac

get_token() { # 按修改时间倒序读 WebView 本地存储，取最后一个 token（最新的那次免密登录）
  local n
  "$BB" ls -tr "$LD" 2>/dev/null | while IFS= read -r n; do
    "$BB" cat "$LD/$n" 2>/dev/null
  done | "$BB" tr -d '\000' | "$BB" grep -o '"token":"2_[0-9A-Fa-f]*"' \
       | "$BB" tail -n 1 | "$BB" cut -d'"' -f4
}

mk_auth() { # $1=签名 URL（不含查询串） $2=token → base64(时间戳:随机数:签名:token)
  local ts nonce hash
  ts=$(now_s)
  nonce=$("$BB" head -c 24 /dev/urandom | "$BB" base64 | "$BB" tr -dc 'A-Za-z0-9' | "$BB" head -c 16)
  hash=$(printf '%s' "${SECRET}$1${ts}${nonce}" | "$BB" md5sum | "$BB" cut -d' ' -f1)
  printf '%s' "${ts}:${nonce}:${hash}:$2" | "$BB" base64 | "$BB" tr -d '\n'
}

# ---- 失败原因留痕（本层最靠近 wget，故由本层收集） ----
# 为什么不让调用方重定向 stderr 去收：**api 函数体内的任何 stderr 都会被收进去**——
# shell 的 `set -x` 追踪、子命令的提示行都会混进来，首行因此可能是 `+ local url`
# 而不是那一句报错。所以由 http_post 自己落文件，api 在**确认失败**后才读它并转交；
# 成功时不读也不写，没有过时内容的问题。
API_ERRLOG="$MODDIR/.fafu_api.err"

# 取报错正文的第一行（wget 的报错是一行，可能夹着 busybox 的多余提示行）
_api_err1() { # $1=文件
  "$BB" head -n 1 "$1" 2>/dev/null | "$BB" tr -d '\r\n'
}

# 网络调用：全程序唯一的出口（$1=完整 URL $2=Authorization 头值）。
# 输出响应体，返回 wget 退出码——调用方据此判定失败，不要去 grep 响应体。
# 失败时报错正文落到 API_ERRLOG（由 api 转交，见下）：wget 失败时响应体为空，
# **唯一的原因线索就是这句报错**（形如 `wget: server returned error: HTTP/1.1 500 ...`），
# 丢了它，日志里就只剩一个退出码，事后分不出是哪一类失败。
http_post() {
  # 先清空：万一这次失败没吐出报错，文件里不会留着上一次的报错被当成这次的原因
  : > "$API_ERRLOG" 2>/dev/null
  "$BB" wget -q $WGET_T -O - --header="Authorization: $2" --post-data='' "$1" \
    2>>"$API_ERRLOG"
}

api() { # $1=path $2=查询串（可空） $3=token → 输出响应体；返回 wget 退出码
  local url rc
  url="$API/$1"
  [ -n "$2" ] && url="$url?$2"
  http_post "$url" "$(mk_auth "$API/$1" "$3")"   # 签名 URL 不含查询串
  rc=$?
  # 失败才转交原因，且**不改变返回码语义**：调用方拿到的仍是 wget 的退出码
  if [ "$rc" != "0" ]; then
    "$BB" printf '%s\n' "$(_api_err1 "$API_ERRLOG")" >&2
  fi
  return "$rc"
}
