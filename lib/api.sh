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

# ---- 失败原因留痕（本层最靠近网络工具，故由本层收集） ----
# 为什么不让调用方重定向 stderr 去收：**api 函数体内的任何 stderr 都会被收进去**——
# shell 的 `set -x` 追踪、子命令的提示行都会混进来，首行因此可能是 `+ local url`
# 而不是那一句报错。所以由 http_post 自己落文件，api 在**确认失败**后才读它并转交；
# 成功时不读也不写，没有过时内容的问题。
#
# 失败原因里必须同时有 **HTTP 状态码**与**响应体正文**：
# busybox wget 在 4xx/5xx 时把响应体整个丢掉（只留一句 `wget: server returned error:
# HTTP/1.1 401`，正文为空），而服务端的报错正文是结构化的
# （`{"status":400,"error":"…","message":"…","path":"…"}`）——只留状态码，
# 事后仍然分不出是「窗口未开」「参数被拒」还是别的。
API_ERRLOG="$MODDIR/.fafu_api.err"

# 取报错的第一行（状态码 + 正文片段都在这一行里）
_api_err1() { # $1=文件
  "$BB" head -n 1 "$1" 2>/dev/null | "$BB" tr -d '\r\n'
}

# 响应体压成一行、截断，供日志与失败原因用（正文里可能有换行与制表符）
_api_resp1() { # $1=响应体
  printf '%s' "$1" | "$BB" sed '$d' | "$BB" tr -d '\r\n' | "$BB" head -c 200
}

# ---- curl 优先，busybox wget 兜底 ----
# 两个工具的能力差在「失败时能不能读到响应体」：curl 能（还给出 %{http_code}），
# wget 不能。探测只做一次，结果与工具路径都落在本层。
# PATH 在守护进程里未必完整（开机自启时的环境），故显式补两个系统路径。
CURL_BIN="${CURL_BIN:-}"
_curl_probe() {
  local c
  c=$(command -v curl 2>/dev/null)
  [ -n "$c" ] || c=/system/bin/curl
  [ -x "$c" ] || c=/system/xbin/curl
  [ -x "$c" ] || return 1
  "$c" --version >/dev/null 2>&1 || return 1
  CURL_BIN="$c"
  return 0
}
# 已设 CURL_BIN 时以它为准（测试注入点：能分别走 curl 与 wget 两条路径）
if [ -n "$CURL_BIN" ]; then
  :
elif [ -e "$MODDIR/.fafu_no_curl" ]; then
  :                                        # 显式要求走 wget 兜底（排查用）
else
  _curl_probe || CURL_BIN=""
fi

# 网络调用：全程序唯一的出口（$1=完整 URL $2=Authorization 头值）。
# 输出响应体，返回码沿用既有语义（0=成功，非 0=失败）——调用方只按它分流。
# curl 路径下「成功」的判据是 HTTP 状态码 2xx：4xx/5xx 也算失败，
# 否则服务端的报错正文会被当成正常响应体交给调用方。
http_post() {
  local rc code body
  # 先清空：这次若没吐出原因，文件里不会留着上一次的当成本次的原因
  : > "$API_ERRLOG" 2>/dev/null
  if [ -n "$CURL_BIN" ]; then
    # -w 把状态码附在正文之后（同走 stdout），取最后一行当状态码、其余当正文：
    # 比「正文写文件再读回」少一次落盘，也不给 shell 变量塞整个正文的机会。
    body=$("$CURL_BIN" -sS -X POST -H "Authorization: $2" --max-time 20 \
             -w '\n%{http_code}' "$1" 2>>"$API_ERRLOG")
    rc=$?
    code=$(printf '%s' "$body" | "$BB" tail -n 1 | "$BB" tr -dc '0-9')
    if [ "$rc" != "0" ]; then
      printf 'curl rc=%s %s\n' "$rc" "$(_api_err1 "$API_ERRLOG")" >>"$API_ERRLOG"
      return "$rc"
    fi
    case "$code" in
      2*) printf '%s' "$body" | "$BB" sed '$d' ;;
      *)
        printf 'http=%s %s\n' "$code" "$(_api_resp1 "$body")" >>"$API_ERRLOG"
        return 1
        ;;
    esac
    return 0
  fi
  # 兜底：这台设备没有可用的 curl（正文拿不到，但状态码仍在报错里）
  "$BB" wget -q $WGET_T -O - --header="Authorization: $2" --post-data='' "$1" \
    2>>"$API_ERRLOG"
}

api() { # $1=path $2=查询串（可空） $3=token → 输出响应体；返回码见上
  local url rc
  url="$API/$1"
  [ -n "$2" ] && url="$url?$2"
  http_post "$url" "$(mk_auth "$API/$1" "$3")"   # 签名 URL 不含查询串
  rc=$?
  # 失败才转交原因，且**不改变返回码语义**
  if [ "$rc" != "0" ]; then
    "$BB" printf '%s\n' "$(_api_err1 "$API_ERRLOG")" >&2
  fi
  return "$rc"
}
