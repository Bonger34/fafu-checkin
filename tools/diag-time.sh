#!/system/bin/sh
# ============================================================
# 时区取证 —— 判定「模块描述里的签到时间」为什么和真实时间差了几小时
#
# 用法（设备上以 root 执行，**不要**套 su -c：已经是 root 就直接跑）：
#   sh /sdcard/Download/diag-time.sh
#
# 只读：不改模块、不发签到、不动配置。输出同时落盘一份到
# /sdcard/Download/fafu-tz-<时间戳>.txt（终端被回收也留得下）。
#
# 判读（三段输出对照着看）：
#   ① date +%z 不是 +0800            → 设备时区偏了
#   ② 原始戳「按本机时区」解释 ≠ 你的真实时刻 → 换算这一格就是描述写错的原因
#   ③ 第 1 段的 date 与你的真实时刻不符      → 整机时间偏（比时区错更严重）
# ============================================================
M="${M:-/data/adb/modules/fafu-checkin}"
OUT="/sdcard/Download/fafu-tz-$(date '+%Y%m%d-%H%M%S').txt"

# 打印一行并同时写证据文件（tee 不一定有，故写两处）
say() { echo "$@"; echo "$@" >> "$OUT"; }

say "==== 1. 设备当前时间与时区（模块一切本地时间都由它决定）===="
say "date      = $(date '+%Y-%m-%d %H:%M:%S')"
say "时区缩写   = $(date '+%Z')"
say "UTC 偏移   = $(date '+%z')"
say "epoch(秒) = $(date '+%s')"
say "同一 epoch 按 UTC 解释 = $(date -u '+%Y-%m-%d %H:%M:%S')"
say "props: persist.sys.timezone=$(getprop persist.sys.timezone 2>/dev/null)"
say "props: ro.product.locale=$(getprop ro.product.locale 2>/dev/null)"
say "自动时间: auto_time=$(settings get global auto_time 2>/dev/null) auto_time_zone=$(settings get global auto_time_zone 2>/dev/null)"

say ""
say "==== 2. 服务端任务数据里的原始毫秒戳（模块记时间读的就是它）===="
. "$M/lib/base.sh" 2>/dev/null
. "$M/lib/config.sh" 2>/dev/null
cfg_load 2>/dev/null
. "$M/lib/api.sh" 2>/dev/null
resp=$(api "sign_in/student/my/page" "rows=1&pageNum=1" "$(get_token)")
sst=$(printf '%s' "$resp" | "$BB" grep -oE '"signTime":[0-9]+' | head -n1 | cut -d: -f2)
if [ -z "$sst" ]; then
  say "（没取到 signTime：今天可能还没有签到记录，或查询失败）"
  say "响应体片段: $(printf '%s' "$resp" | "$BB" head -c 200)"
else
  say "signTime 原始值 = $sst   （毫秒；÷1000 = $((sst / 1000))）"
  say "  → 按本机时区解释 = $(date -d "@$((sst / 1000))" '+%Y-%m-%d %H:%M:%S')   ← 描述里那一格就是它"
  say "  → 按 UTC 解释     = $(date -u -d "@$((sst / 1000))" '+%Y-%m-%d %H:%M:%S')"
  say "  → 与现在相差      = $(( $(date '+%s') - sst / 1000 )) 秒（负 = 记录发生在过去）"
fi

say ""
say "==== 3. 模块自己记下来的签到时间（描述与 status 都读它）===="
say "sign_date=$(kv_get "$M/fafu_checkin.status" sign_date)"
say "sign_time=$(kv_get "$M/fafu_checkin.status" sign_time)"
say "sign_kind=$(kv_get "$M/fafu_checkin.status" sign_kind)"

say ""
say "==== 4. 日志尾部（模块自己的时间戳来源，与第 1 段对照）===="
"$BB" tail -n 8 "$M/fafu_checkin.log" 2>/dev/null | while IFS= read -r l; do say "$l"; done

echo ""
echo "证据文件：$OUT"
