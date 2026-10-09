#!/system/bin/sh
# ============================================================
# 网络探针（只读取证，不改模块、不发签到、不动配置）
#
# 用法（设备上以 root 执行，不要套 su -c）：
#   sh /sdcard/Download/diag-net.sh
# 输出同时写 /sdcard/Download/fafu-net-<时间戳>.txt
#
# 目的：摸清这台设备上 busybox wget 在 HTTP 错误时的行为——
#   ① 4xx 时响应体能不能拿到（决定「服务端那句 msg」有没有救）
#   ② -o / -O 两个选项各写到哪里
#   ③ 一个必然 400 的请求，看退出码与产物
# ============================================================
M="${M:-/data/adb/modules/fafu-checkin}"
OUT="/sdcard/Download/fafu-net-$(date '+%Y%m%d-%H%M%S').txt"
W=/data/local/tmp/fafu-probe
mkdir -p "$W"; cd "$W" || exit 1

say() { echo "$@"; echo "$@" >> "$OUT"; }

. "$M/lib/base.sh" 2>/dev/null
say "busybox = $BB"
say "busybox version = $("$BB" 2>&1 | head -n1)"

say ""
say "==== 1. wget 的选项支持（-o / -O / -S）===="
"$BB" wget --help 2>&1 | "$BB" grep -iE '^\s*(-o|-O|-S|--post-data|--header|-T)' | while IFS= read -r l; do say "  $l"; done

say ""
say "==== 2. 必然 400 的请求：响应体去哪了 ===="
rm -f body.* hdr.*
U="http://stuhtapi.fafu.edu.cn/health-api/sign_in/1/student/sign?lng=1&lat=1"
# ① 原样（模块现在的用法）：stdout 只接响应体，stderr 分开
"$BB" wget -q -T 10 -O - --post-data='' "$U" > body.stdout 2> err.stdout
rc1=$?
say "① -O - rc=$rc1  stdout大小=$(wc -c < body.stdout | tr -dc '0-9')  stderr=[$(head -c 200 err.stdout | tr '\n' ' ')]"
say "   stdout首行=[$(head -n1 body.stdout | head -c 200)]"

# ② -o 文件：响应体是否落盘
"$BB" wget -q -T 10 -o body.o -O - --post-data='' "$U" > body.stdout2 2> err.stdout2
rc2=$?
say "② -o body.o rc=$rc2  body.o大小=$(wc -c < body.o 2>/dev/null | tr -dc '0-9')  stdout大小=$(wc -c < body.stdout2 | tr -dc '0-9')"
say "   body.o内容=[$(head -c 200 body.o 2>/dev/null | tr '\n' ' ')]"

# ③ 带 -S（打印响应头），看状态行是否可达
"$BB" wget -q -T 10 -S -O - --post-data='' "$U" > body.s 2> err.s
rc3=$?
say "③ -S rc=$rc3  stderr首行=[$(head -n1 err.s | head -c 200)]"
say "   stdout首行=[$(head -n1 body.s | head -c 200)]"

# ④ 同一个 URL 用 curl（如果设备上有）
if command -v curl >/dev/null 2>&1; then
  curl -s -o body.curl -w 'http=%{http_code}\n' --max-time 10 -X POST "$U" > curl.w 2>&1
  say "④ curl 可用：$(cat curl.w)  body=[$(head -c 200 body.curl | tr '\n' ' ')]"
else
  say "④ 设备上没有 curl"
fi

echo ""
echo "证据文件：$OUT"
