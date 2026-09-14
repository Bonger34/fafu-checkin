#!/system/bin/sh
# ============================================================
# 数字FAFU 晚查寝自动签到 —— 开机启动脚本
# 以 late_start 服务模式运行（KernelSU / Magisk 通用）
# 等待系统启动完成后再拉起守护进程；若服务已被停用则跳过
# ============================================================

MODDIR=${0%/*}
[ -f "$MODDIR/fafu_checkin.sh" ] || MODDIR="/data/adb/modules/fafu-checkin"
STATE="$MODDIR/fafu-checkin.state"

(
  # 服务已被用户停用 → 不启动
  if [ -f "$STATE" ] && [ "$(cat "$STATE" 2>/dev/null)" = "disabled" ]; then
    exit 0
  fi
  # 等待系统启动完成（最长约 10 分钟）
  i=0
  while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ $i -lt 300 ]; do
    sleep 2
    i=$((i+1))
  done
  # 再等片刻，让网络与应用完成初始化
  sleep 15
  sh "$MODDIR/fafu_checkin.sh" start
) </dev/null >/dev/null 2>&1 &
