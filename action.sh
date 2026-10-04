#!/system/bin/sh
# ============================================================
# 数字FAFU 晚查寝自动签到 —— 操作按钮
# 点击管理器的模块「操作」按钮时执行：切换服务开关（启用 ⇄ 停用）。
# ============================================================

MODDIR=${0%/*}
[ -f "$MODDIR/fafu_checkin.sh" ] || MODDIR="/data/adb/modules/fafu-checkin"

sh "$MODDIR/fafu_checkin.sh" toggle
