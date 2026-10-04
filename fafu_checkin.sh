#!/system/bin/sh
# ============================================================
# 数字FAFU 晚查寝自动签到 —— 入口脚本
#
# 只做装配与调度：定位模块目录 → 加载配置 → 按序加载各层 → 命令分发 → 守护主循环；
# 能力实现都在同目录的 lib/ 各层里。
#
# 用法：sh fafu_checkin.sh [子命令]      # 不带子命令 = start（启动守护进程）
#   子命令清单、说明与用法文本同源于 lib/commands.sh 的命令表（未知子命令会打印用法）。
#   start 例外：守护进程的后台化与单实例判定在本文件（见 cmd_start）。
#
# 配置（可选）：模块目录内 fafu-checkin.conf
#   KEEPALIVE=0     关闭白天保活（仅保留 21:30 自动签到）
#   NOTIFY=0        关闭全部通知
#   NOTIFY_LEAD=5   打卡页打开前的预警提前量（秒）；0 = 不加延时，仅屏幕已亮时生效
# ============================================================

export PATH="/system/bin:/system/xbin:/data/adb/ksu/bin:/data/adb/magisk:$PATH"

# ---- 定位自身与模块目录 ----
# 入口必须先知道自己在哪，才能找到同目录的 lib/（各层与配置文件都在那里）
SELF="$0"
case "$SELF" in
  /*) : ;;
  *) [ -f "$SELF" ] && SELF="$PWD/$SELF" ;;
esac
MODDIR="${SELF%/*}"
[ -f "$MODDIR/fafu_checkin.sh" ] || MODDIR="/data/adb/modules/fafu-checkin"
[ -f "$MODDIR/fafu_checkin.sh" ] || MODDIR="/data/adb/modules_update/fafu-checkin"

# ---- 加载可选配置（覆盖各层的默认值） ----
CONFIG="$MODDIR/fafu-checkin.conf"
[ -f "$CONFIG" ] && . "$CONFIG"

# ---- 按序加载各层 ----
# 顺序即依赖方向：一层只能引用更早加载的层（tools/check-layer-order.sh 守着这条）。
# 注意 keepalive 必须排在 signin 之前——签到决策会调用刷新流程。
FAFU_LAYERS="base state api device notify desc keepalive signin commands"
LIBDIR="$MODDIR/lib"
# 库层缺失时 base 还没加载，这条失败日志的路径只能就地取（与 base 层里的那处一致）
LOG="$MODDIR/fafu_checkin.log"
for _layer in $FAFU_LAYERS; do
  if [ ! -r "$LIBDIR/$_layer.sh" ]; then
    _err="[$(date '+%Y-%m-%d %H:%M:%S')] 模块不完整：缺少库层 $LIBDIR/$_layer.sh，请重新安装模块"
    echo "$_err" >> "$LOG" 2>/dev/null
    echo "$_err" >&2
    exit 1
  fi
  . "$LIBDIR/$_layer.sh"
done
unset _layer _err

# ---- 子命令分发与守护进程启动 ----
# 命令表（分发规则、降权探测、用法文本）在 commands 层；表里的子命令在 cmd_dispatch
# 里就干完并退出，走到下面的只剩「不带子命令」与 `start`。
CMD="$1"
cmd_known "$CMD" || { cmd_usage; exit 1; }
cmd_dispatch "$CMD"

# 后台化 + 单实例：不是自己重启出来的（FAFU_DAEMON 空）= 命令行上确实要启动守护进程
cmd_start() {
  local oldpid
  if svc_is_disabled; then
    echo "服务已停用（可点击操作按钮或运行 enable 启用）"
    update_desc
    exit 0
  fi
  if [ -f "$PIDF" ]; then
    oldpid=$("$BB" cat "$PIDF" 2>/dev/null)
    if [ -n "$oldpid" ] && [ -d "/proc/$oldpid" ] && \
       "$BB" grep -qa 'fafu_checkin' "/proc/$oldpid/cmdline" 2>/dev/null; then
      log "已有实例(PID $oldpid)在运行，退出"
      echo "服务已在运行 (PID $oldpid)"
      exit 0
    fi
  fi
  export FAFU_DAEMON=1 FAFU_SU_MODE="$SU_MODE"   # 探测结果随环境传给守护进程
  "$BB" nohup sh "$SELF" start </dev/null >/dev/null 2>&1 &
  echo "服务已启动"
  exit 0
}

[ -z "$FAFU_DAEMON" ] && cmd_start

# ---- 守护主循环 ----
echo $$ > "$PIDF"
log "===== 服务启动 (PID $$) 版本=${VER:-未知} wget_timeout=[${WGET_T:-无}] notify=[${SU_MODE:-不可用}] ====="

DESC_TICK=0
ROT_TICK=0
while true; do
  # 已被停用 → 刷新描述后退出（保持“停用 = 无进程”语义）
  if svc_is_disabled; then
    log "检测到服务已停用，守护进程退出"
    update_desc
    rm -f "$PIDF"
    exit 0
  fi
  # 描述定时刷新（每约 10 分钟一次；内容变化时才写入）
  if [ $DESC_TICK -le 0 ]; then
    update_desc
    DESC_TICK=10
  fi
  DESC_TICK=$((DESC_TICK-1))
  # 日志轮转（每小时检查一次）
  if [ $ROT_TICK -le 0 ]; then
    rotate_log
    ROT_TICK=60
  fi
  ROT_TICK=$((ROT_TICK-1))
  now=$(now_minutes)
  PL=$(today_tag)   # 每轮重算：守护进程常驻，跨日后 tag 不应仍停在启动那天
  # ---- 未签到提醒：22:00（还剩 30 分钟）/ 22:30（窗口已过，进入补签）/ 23:00（补签窗口关闭） ----
  # 依据签到状态文件判定：当日已解决（已签到/已补签/已检测/已请假）则一律不发，避免假警报
  if [ $now -ge 1320 ]; then
    sd=$(sign_get sign_date); sk=$(sign_get sign_kind)
    if [ "$sd" = "$(today)" ] && [ "$sk" != "" ]; then
      :   # 当日状态已解决（含请假）→ 不提醒
    else
      # 三个时点各自独立标记：越晚的时点信息越关键，不能被更早的那条挡住
      if [ $now -ge 1380 ]; then
        notify_once miss
      elif [ $now -ge 1350 ]; then
        notify_once late
      else
        notify_once nosign
      fi
    fi
  fi
  # ---- 主窗口 21:30~22:30；补签时段 22:30~23:00（失败重试，最后一次不晚于 22:59 发起） ----
  if [ $now -ge 1290 ] && [ $now -le 1379 ]; then
    if ! done_marked; then
      run_once; rc=$?
      [ $rc -eq 0 ] && done_mark
      [ $rc -eq 2 ] && { sleep 240; continue; }
    fi
  elif [ "$KEEPALIVE" = "1" ] && ka_in_window; then
    # ---- 白天保活 07:00~21:25，每 15 分钟一次（窗口与节流都由 keepalive 层判定）----
    now_ts=$(now_s)
    if ka_due "$now_ts"; then
      KA_LAST=$now_ts
      keepalive_ping
    fi
  fi
  sleep 60
done
