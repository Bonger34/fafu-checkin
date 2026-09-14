#!/system/bin/sh
# ============================================================
# 数字FAFU 晚查寝自动签到 —— 安装脚本（KernelSU / Magisk 通用）
# 由安装器在模块解压后导入执行
# 可用函数：ui_print / abort / set_perm / set_perm_recursive
# ============================================================

MODPATH="${MODPATH:-$PWD}"

VER=$(grep -m1 '^version=' "$MODPATH/module.prop" 2>/dev/null | cut -d= -f2)

ui_print " "
ui_print "*******************************"
ui_print " 数字FAFU 晚查寝自动签到"
ui_print " 版本: ${VER:-未知}"
ui_print "*******************************"

# 运行环境提示
if [ "$KSU" = "true" ]; then
  ui_print "- 环境: KernelSU ${KSU_VER:-}"
else
  ui_print "- 环境: Magisk ${MAGISK_VER:-}"
fi

# 设置脚本可执行权限
for f in fafu_checkin.sh service.sh action.sh uninstall.sh; do
  [ -f "$MODPATH/$f" ] || continue
  if command -v set_perm >/dev/null 2>&1; then
    set_perm "$MODPATH/$f" 0 0 0755
  else
    chmod 755 "$MODPATH/$f"
  fi
done

ui_print " "
ui_print "- 安装完成，重启后自动运行"
ui_print "- 日志: /data/adb/fafu_checkin.log"
ui_print " "
