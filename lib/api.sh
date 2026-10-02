# ============================================================
# api 层 —— 接口：token 提取、请求签名、HTTP 调用
#
# 加载顺序：第 3 层。业务层不自己拼签名、也不直接调网络，一律经本层。
# 失败判定以 wget 退出码为准：busybox wget 拿不到错误响应正文（见开发文档 §3.2）。
# ============================================================

SECRET="AtPs2O1xEnhwkKDV"
API="http://stuhtapi.fafu.edu.cn/health-api"
LD="${LD_DIR:-/data/data/cn.edu.fafu.iportal/app_webview/Default/Local Storage/leveldb}"

get_token() { # 按修改时间倒序读 WebView 本地存储，取最后一个 token（最新的那次免密登录）
  "$BB" ls -tr "$LD" 2>/dev/null | while IFS= read -r n; do
    "$BB" cat "$LD/$n" 2>/dev/null
  done | "$BB" tr -d '\000' | "$BB" grep -o '"token":"2_[0-9A-Fa-f]*"' \
       | "$BB" tail -n 1 | "$BB" cut -d'"' -f4
}

mk_auth() { # $1=sign_url $2=token → base64(时间戳:随机数:签名:token)
  ts=$("$BB" date +%s)
  nonce=$("$BB" head -c 24 /dev/urandom | "$BB" base64 | "$BB" tr -dc 'A-Za-z0-9' | "$BB" head -c 16)
  hash=$(printf '%s' "${SECRET}$1${ts}${nonce}" | "$BB" md5sum | "$BB" cut -d' ' -f1)
  printf '%s' "${ts}:${nonce}:${hash}:$2" | "$BB" base64 | "$BB" tr -d '\n'
}

api() { # $1=path $2=query $3=token → 输出响应体；返回 wget 退出码
  url="$API/$1"
  [ -n "$2" ] && url="$url?$2"
  auth=$(mk_auth "$API/$1" "$3")
  "$BB" wget -q $WGET_T -O - --header="Authorization: $auth" --post-data='' "$url" 2>/dev/null
}
