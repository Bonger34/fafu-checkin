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
# 而不是那一句报错。所以由 http_post 自己把工具的 stderr 落到旁路文件，
# api 在**确认失败**后才读它并把整行转交出去；成功时不读。
#
# 失败原因里必须同时有 **HTTP 状态码**与**响应体正文**：
# busybox wget 在 4xx/5xx 时把响应体整个丢掉（只留一句 `wget: server returned error:
# HTTP/1.1 401`，正文为空），而服务端的报错正文是结构化的
# （`{"status":400,"error":"…","message":"…","path":"…"}`）——只留状态码，
# 事后仍然分不出是「窗口未开」「参数被拒」还是别的。
#
# 这个文件是**单行诊断协议**的落点：每次网络调用先清空它，随后写入恰好一行
# （`http=<码> body=… hdr={…} 耗时=…`，连接层失败则是 `net rc=<退出码> http=- err=…`），
# 上层原样转交这一行，不自己拼这些字段。
API_ERRLOG="$MODDIR/.fafu_api.err"
# 响应头落点：curl 的 -D 直接写它，_api_hdr 再从里面挑白名单四项。
API_HDRLOG="$MODDIR/.fafu_api.hdr"
# 网络工具 stderr 的落点：原始报错（可能多行）先进这里，只有首行被压平进日志行；
# 与诊断文件分开，是为了让诊断文件始终只有一行。
API_RAWLOG="$MODDIR/.fafu_api.raw"
# 落日志的正文上限：正常响应几十~几百字节，只有超长响应才截断（并在同一行标明原始字节数）。
API_BODY_MAX=2048

# 取报错的第一行（状态码 + 正文片段都在这一行里）
_api_err1() { # $1=文件
  "$BB" head -n 1 "$1" 2>/dev/null | "$BB" tr -d '\r\n'
}

# 压平 + 上限：任何要进日志的值（正文 / 报错 / 响应头）都过这里——值内不得有换行或
# 制表符，否则一个值就能把「一行事实」摊成多行，事后分不清哪一段属于哪一次调用。
_api_flat() { # $1=原文 [$2=上限字节数，默认 $API_BODY_MAX]
  printf '%s' "$1" | "$BB" tr -d '\r\n\t' | "$BB" head -c "${2:-$API_BODY_MAX}"
}

# 从「正文 + -w 附加的状态码」里取出正文（去掉最后一行）
_api_payload() { # $1=响应体（带 -w 状态码行）
  printf '%s' "$1" | "$BB" sed '$d'
}

# 正文段：正常响应原样完整；超过上限时在同一行追加原始字节数与截断标记——
# 只写一个被截断的前缀，事后会把「截断」误读成「服务端只回了这么多」。
_api_body() { # $1=正文 → body=<正文>[ bodylen=<原始字节数> trunc=1]
  _api_field body "$1"
}

# 「字段名 + 压平 + 上限」的唯一实现：任何要整段落进日志的值都经它，
# 于是「标明原始字节数 + 标明被截断」这件事在正文、服务端记录等处口径一致。
# $1=字段名 $2=原文 → <字段名>=<压平值>[ <字段名>len=<原始字节数> <字段名>trunc=1]
_api_field() {
  local v n
  v=$(_api_flat "$2")
  n=$(printf '%s' "$2" | "$BB" wc -c | "$BB" tr -dc '0-9')
  if [ "${n:-0}" -gt "$API_BODY_MAX" ]; then
    printf '%s=%s %slen=%s %strunc=1' "$1" "$v" "$1" "$n" "$1"
  else
    printf '%s=%s' "$1" "$v"
  fi
}

# 从「正文 + -w 状态码」里取状态码（取不到时输出空）
_api_code1() { # $1=同上
  printf '%s' "$1" | "$BB" tail -n 1 | "$BB" tr -dc '0-9'
}

# 响应头白名单：只取这四项（整包头会把日志行淹掉）。服务端没给的头**不出现**
# （不写空占位），四项一个都没有时整段不输出。顺序按白名单固定，
# 于是同一份响应头每次落出的字面量都一样（断言与肉眼比对都不必猜顺序）。
API_HDR_KEYS="Date Content-Length Content-Type Server"

_api_hdr() { # $1=响应头原文（curl 的 -D 落点，或 wget -S 的那段 stderr）
  local k v out
  out=""
  for k in $API_HDR_KEYS; do
    # 行首允许有空白：wget -S 把服务端响应的每一行都缩进两格，curl -D 则顶格
    v=$(_api_flat "$("$BB" grep -i -m1 "^[[:space:]]*$k:" "$1" 2>/dev/null | "$BB" sed 's/^[^:]*:[ ]*//')")
    [ -n "$v" ] || continue
    if [ -n "$out" ]; then out="$out|$k: $v"; else out="$k: $v"; fi
  done
  [ -n "$out" ] && printf 'hdr={%s}' "$out"
  return 0
}

# 只读访问器：诊断行里的响应头那一段（`hdr={…}`，没有则输出空）。
# 上层要把「服务端认为现在几点」（Date）并排到自己的日志行上时接这一小段——
# **不许自己拼 hdr=**：这一段就是 api 层落下的那份字面量，格式仍只有一个真源。
_api_hdrs() { # [$1=诊断文件，缺省 $API_ERRLOG]
  _api_err1 "${1:-$API_ERRLOG}" | "$BB" sed -n 's/.*\(hdr={[^}]*}\).*/\1/p'
}

# 计时读数：毫秒优先（busybox 的 `date +%s%3N` 给得出 13 位数字），取不到退化为秒。
# **位数就是单位**：13 位=毫秒、其余=秒——`date` 不认 %3N 时会把 %3N 原样吐出来，
# 故这里只认数字并截到 13 / 10 位，_api_cost 才不会把杂字符算进差值。
_api_now() { # 无参 → 当前读数
  local t
  t=$("$BB" date +%s%3N 2>/dev/null | "$BB" tr -dc '0-9')
  case "$t" in
    ?????????????*) t=$(printf '%s' "$t" | "$BB" head -c 13) ;;
    *)              t=$(printf '%s' "$t" | "$BB" head -c 10) ;;
  esac
  printf '%s' "$t"
}

# 耗时字段：值自带单位后缀（ms / s）——只给数字的话，事后分不出单位。
_api_cost() { # $1=起始读数 $2=结束读数
  local unit
  if [ "${#1}" = "13" ] && [ "${#2}" = "13" ]; then unit=ms; else unit=s; fi
  printf '耗时=%s%s' "$(( ${2:-0} - ${1:-0} ))" "$unit"
}

# 一次调用的全部事实 → API_ERRLOG 里唯一的那一行（**格式的唯一拼装处**）。
# 落笔前先清空文件：于是「每次调用恰好一行」对真实调用与驱动替身都成立。
# 两档形态取决于「这次拿不拿得到状态码」：
#   拿得到（curl 路径，以及 wget 兜底吐了状态行时）：
#     `http=<码> body=… [err=…] [hdr={…}] 耗时=…`——成功与被拒同形，只差码；
#   拿不到（curl 连不上 / 超时，或 wget 没吐响应）：
#     `net rc=<退出码> http=- [body=…] [err=…] [hdr={…}] 耗时=…`
# 取值取不到的段**整段不出现**（不写空占位）。上层与驱动替身都调它，别自己拼这些字段。
_api_note() { # $1=工具退出码 $2=HTTP 状态码（空=这一档拿不到） $3=正文 $4=原始报错
              # $5=响应头原文所在文件（可空） $6=起始读数 $7=结束读数
  local line hdrs
  : > "$API_ERRLOG" 2>/dev/null
  if [ -n "$2" ]; then
    line="http=$2 $(_api_body "$3")"
  else
    line="net rc=$1 http=-"
    [ -n "$3" ] && line="$line $(_api_body "$3")"
  fi
  # 报错原文独立于「有没有状态码」：wget -S 可能既给得出状态码、又吐了工具那句报错。
  # 没吐报错就不写这一段（不写空占位）。
  [ -n "$4" ] && line="$line err=$(_api_flat "$4")"
  hdrs=""
  [ -n "$5" ] && hdrs=$(_api_hdr "$5")
  [ -n "$hdrs" ] && line="$line $hdrs"
  printf '%s %s\n' "$line" "$(_api_cost "$6" "$7")" >>"$API_ERRLOG"
}

# ---- curl 优先，busybox wget 兜底 ----
# 两个工具的能力差在「失败时能不能读到响应体」：curl 能（还给出 %{http_code}），
# wget 不能。探测只做一次，结果与工具路径都落在本层。
#
# 逐个候选试，**认「能跑」而不是「文件在」**：只看 [ -x ] 会把「存在但起不来」的
# 当成可用，于是每次请求都失败、又看不出原因。候选顺序：
#   ① PATH 上的（终端里常由管理器挂进来）
#   ② /data/adb/curl（模块外，升级不丢，想固定用某一份时放这里）
#   ③ 模块目录自带的 $MODDIR/curl
#   ④ 系统两个常见位置
#
# 探测与调用一律**清掉 LD_LIBRARY_PATH**（`LD_LIBRARY_PATH=` 前缀）：管理器的终端
# 会往它里面塞自己的旧 libcrypto，动态链接器优先加载后，系统 curl 会因找不到符号而
# 起不来（同一个 /system/bin/curl，清掉变量就能跑）。这个变量只影响查找路径，
# 清掉不会改变请求语义。
CURL_BIN="${CURL_BIN:-}"
_curl_probe() {
  local c
  for c in "$(command -v curl 2>/dev/null)" \
           /data/adb/curl \
           "$MODDIR/curl" \
           /system/bin/curl \
           /system/xbin/curl; do
    [ -n "$c" ] || continue
    [ -x "$c" ] || continue
    # 起不来（缺动态库等）的不算可用：--version 要真的退出 0
    LD_LIBRARY_PATH= "$c" --version >/dev/null 2>&1 || continue
    CURL_BIN="$c"
    return 0
  done
  return 1
}
# 已设 CURL_BIN 时以它为准（测试注入点：能分别走 curl 与 wget 两条路径）
if [ -n "$CURL_BIN" ]; then
  :
elif [ -e "$MODDIR/.fafu_no_curl" ]; then
  :                                        # 显式要求走 wget 兜底（排查用）
else
  _curl_probe || CURL_BIN=""
fi

# wget -S 那一段 stderr 里的状态码：首行形如 `  HTTP/1.1 503 Service Unavailable`（缩进两格）。
# 取不到（连不上 / 这个构建没吐响应）就输出空 → 调用方走 `net rc=` 那档，不拿退出码冒充状态码。
_api_wget_code() { # $1=wget 的 stderr 落点
  "$BB" sed -n 's/^[[:space:]]*HTTP\/[0-9.]*[[:space:]]*\([0-9][0-9][0-9]\).*/\1/p' "$1" 2>/dev/null \
    | "$BB" head -n 1
}

# wget 自己那句报错（形如 `wget: server returned error: HTTP/1.1 503 …` / `wget: can't connect …`）：
# 取第一个以 `wget:` 开头的行；它可能不在首行（-S 的状态行排在它前面）。没有则不写 err=。
_api_wget_err() { # $1=同上
  "$BB" grep -m1 '^wget:' "$1" 2>/dev/null | "$BB" head -n 1 | "$BB" tr -d '\r\n'
}

# 网络调用：全程序唯一的出口（$1=完整 URL $2=Authorization 头值）。
# 输出响应体，返回码沿用既有语义（0=成功，非 0=失败）——调用方只按它分流。
# curl 路径下「成功」的判据是 HTTP 状态码 2xx：4xx/5xx 也算失败，
# 否则服务端的报错正文会被当成正常响应体交给调用方。
http_post() {
  local rc code body payload t0 t1
  # 本次调用独占这个文件：起点先清空（落笔时 _api_note 还会再确认一次），
  # 于是「这次没留下任何原因」与「上次留下的原因」不会被混为一谈
  : > "$API_ERRLOG" 2>/dev/null
  if [ -n "$CURL_BIN" ]; then
    # -w 把状态码附在正文之后（同走 stdout），取最后一行当状态码、其余当正文：
    # 比「正文写文件再读回」少一次落盘，也不给 shell 变量塞整个正文的机会。
    # -D 把响应头落到旁路文件：日志行只留白名单四项，整包头放不下。
    # `LD_LIBRARY_PATH=` 前缀与探测同源：不清掉它，管理器的终端一进来就会让 curl 起不来。
    : > "$API_HDRLOG" 2>/dev/null
    : > "$API_RAWLOG" 2>/dev/null
    t0=$(_api_now)
    body=$(LD_LIBRARY_PATH= "$CURL_BIN" -sS -X POST -H "Authorization: $2" --max-time 20 \
             -D "$API_HDRLOG" -w '\n%{http_code}' "$1" 2>"$API_RAWLOG")
    rc=$?
    t1=$(_api_now)
    code=$(_api_code1 "$body")
    payload=$(_api_payload "$body")
    if [ "$rc" != "0" ]; then
      # 连不上 / 超时：如实写出原始报错与退出码，**不伪造状态码**
      # （-w 此时给的 000 不是服务端的状态码，故整段丢掉）
      _api_note "$rc" "" "$payload" "$(_api_err1 "$API_RAWLOG")" \
        "$API_HDRLOG" "$t0" "$t1"
      return "$rc"
    fi
    # 成功与失败都写整行：日后比对「成功那次与失败那次差在哪」时用得上
    _api_note "$rc" "$code" "$payload" "" "$API_HDRLOG" "$t0" "$t1"
    case "$code" in
      2*) printf '%s' "$payload"; return 0 ;;
      *)  return 1 ;;
    esac
  fi
  # 兜底：这台设备没有可用的 curl。busybox wget 拿不到 4xx 的正文，但 `-S`（显示服务端响应）
  # 会把状态行与响应头（每行缩进两格）打到 stderr —— 状态码与白名单四项就从落盘的 stderr 里取。
  # 取不到就照旧 `net rc=<退出码> http=-`：拿到什么写什么，拿不到的不写（不假装拿到）。
  # 报错原文不能再按「stderr 首行」取值：加了 -S 之后首行可能是状态行，故取含 `wget:` 的那一行。
  : > "$API_RAWLOG" 2>/dev/null
  t0=$(_api_now)
  body=$("$BB" wget -q -S $WGET_T -O - --header="Authorization: $2" --post-data='' "$1" \
    2>"$API_RAWLOG")
  rc=$?
  t1=$(_api_now)
  _api_note "$rc" "$(_api_wget_code "$API_RAWLOG")" "$body" "$(_api_wget_err "$API_RAWLOG")" \
    "$API_RAWLOG" "$t0" "$t1"
  printf '%s' "$body"
  return "$rc"
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
