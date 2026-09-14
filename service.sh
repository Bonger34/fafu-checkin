#!/system/bin/sh
# ============================================================
# 数字FAFU 晚查寝自动签到 —— 开机启动脚本
# 以 late_start 服务模式运行（KernelSU / Magisk 通用）
# 等待系统启动完成后再拉起守护进程，避免与开机流程抢资源
# ============================================================

MODDIR=${0%/*}
[ -f "$MODDIR/fafu_checkin.sh" ] || MODDIR="/data/adb/modules/fafu-checkin"

(
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
