#!/system/bin/sh
# ============================================================
# 数字FAFU 晚查寝自动签到 —— 操作按钮脚本
# 在 KernelSU / Magisk 管理器中点击模块「操作」按钮时执行：
#   显示运行状态 → 立即检查/补签一次 → 输出最近日志
# ============================================================

MODDIR=${0%/*}
[ -f "$MODDIR/fafu_checkin.sh" ] || MODDIR="/data/adb/modules/fafu-checkin"

sh "$MODDIR/fafu_checkin.sh" status
echo ""
echo "===== 执行一次检查 ====="
sh "$MODDIR/fafu_checkin.sh" once
echo ""
echo "===== 最近日志 ====="
tail -n 6 /data/adb/fafu_checkin.log 2>/dev/null
