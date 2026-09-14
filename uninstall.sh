#!/system/bin/sh
# ============================================================
# 数字FAFU 晚查寝自动签到 —— 卸载脚本
# 模块被卸载时执行：停止守护进程、关闭残留页面、清理模块生成的全部文件
# ============================================================

LOG="/data/adb/fafu_checkin.log"
PIDF="/data/adb/.fafu_checkin.pid"
DONE="/data/adb/.fafu_checkin_done"
CONF="/data/adb/fafu-checkin.conf"

# 1) 停止守护进程（先优雅终止，超时强杀）
if [ -f "$PIDF" ]; then
  pid=$(cat "$PIDF" 2>/dev/null)
  if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
    kill "$pid" 2>/dev/null
    i=0
    while [ -d "/proc/$pid" ] && [ $i -lt 3 ]; do
      sleep 1
      i=$((i+1))
    done
    [ -d "/proc/$pid" ] && kill -9 "$pid" 2>/dev/null
  fi
fi

# 兜底：按命令行特征再清理一次（PID 文件丢失等异常情况）
# 模式限定为“fafu_checkin.sh start”，避免误杀其他进程
if command -v pkill >/dev/null 2>&1; then
  pkill -f 'fafu_checkin\.sh start' 2>/dev/null
fi

# 2) 尽力关闭可能残留的签到页面（守护进程若在刷新过程中被终止）
if command -v dumpsys >/dev/null 2>&1 && command -v am >/dev/null 2>&1; then
  ids=$(dumpsys activity activities 2>/dev/null \
    | grep -oE 'ActivityRecord\{[^}]*cn\.edu\.fafu\.iportal[^}]*\}' \
    | grep -oE 't[0-9]+[ }]' | tr -dc '0-9\n' | sort -u)
  for tid in $ids; do
    am stack remove "$tid" </dev/null >/dev/null 2>&1
  done
fi

# 3) 清理模块运行期间生成的全部文件（日志 / 状态 / 标记 / 配置）
rm -f "$LOG" "$PIDF" "$DONE" "$CONF"
