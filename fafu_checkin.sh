#!/system/bin/sh
# ============================================================
# 数字FAFU 晚查寝自动签到 —— 入口脚本
#
# 只做装配与调度：定位模块目录 → 按序加载各层 → 加载配置 → 命令分发 → 守护主循环；
# 能力实现都在同目录的 lib/ 各层里。
#
# 用法：sh fafu_checkin.sh [子命令] [参数…]   # 不带子命令 = start（启动守护进程）
#   子命令清单、说明与用法文本同源于 lib/commands.sh 的命令表（未知子命令会打印用法）。
#   start 例外：守护进程的后台化与单实例判定在本文件（见 cmd_start）。
#
# 配置（可选）：模块目录内 fafu-checkin.conf，键与默认值登记在 lib/config.sh
#   KEEPALIVE=0  关闭白天保活（仅保留轮询范围内的自动签到）
#   NOTIFY=0     关闭全部通知
# ============================================================

export PATH="/system/bin:/system/xbin:/data/adb/ksu/bin:/data/adb/magisk:$PATH"

# ---- 定位自身与模块目录 ----
# 入口必须先知道自己在哪，才能找到同目录的 lib/（各层都在那里）
SELF="$0"
case "$SELF" in
  /*) : ;;
  *) [ -f "$SELF" ] && SELF="$PWD/$SELF" ;;
esac
MODDIR="${SELF%/*}"
[ -f "$MODDIR/fafu_checkin.sh" ] || MODDIR="/data/adb/modules/fafu-checkin"
[ -f "$MODDIR/fafu_checkin.sh" ] || MODDIR="/data/adb/modules_update/fafu-checkin"

# ---- 按序加载各层 ----
# 顺序即依赖方向：一层只能引用更早加载的层（tools/check-layer-order.sh 守着这条）。
# 注意 keepalive 必须排在 signin 之前——签到决策会调用刷新流程。
FAFU_LAYERS="base config state api device notify desc keepalive signin commands"
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

# ---- 加载配置（各层就位后调一次；配置文件缺失即全取默认值） ----
cfg_load

# ---- 子命令分发与守护进程启动 ----
# 命令表（分发规则、降权探测、用法文本）在 commands 层；表里的子命令在 cmd_dispatch
# 里就干完并退出，走到下面的只剩「不带子命令」与 `start`。
CMD="$1"
# 子命令之后的参数原样转交处理函数：先把子命令名从位置参数里摘掉，
# 下面转发时 $@ 才只剩参数（不会把子命令名算成一个）
[ $# -eq 0 ] || shift
cmd_known "$CMD" || { cmd_usage; exit 1; }
# 降权写法在这里探一次（探不探由 cmd_probe_needed 按命令表判）：启动路径必探——守护进程是
# 下面 cmd_start 派生出来的后台进程，它自己不再探（从 FAFU_SU_MODE 继承）。漏探则 daemon 的
# SU_MODE 为空，而空的 SU_MODE 会让 notify() 直接返回——自动签到那几条通知会静默消失且没有
# 任何报错。只读与配置写入类子命令不探（白等一次 su，且探测日志会落进它们自己交出的日志尾部）。
cmd_probe_needed "$CMD" && probe_su "$CMD"
cmd_dispatch "$CMD" "$@"

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

# 轮询范围在循环外取一次：它只决定「什么时候去查看今晚的任务」，
# 该不该签、能不能补签仍只由服务端任务数据决定（signin 层）。
POLL_START=$(cfg_poll_start)
POLL_END=$(cfg_poll_end)

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
  now=$(now_hm)
  PL=$(today_tag)   # 每轮重算：守护进程常驻，跨日后 tag 不应仍停在启动那天
  rc_wait=60        # 本轮的休眠时长：查看任务时可能被改短或被放宽（任务异常档 4 分钟）
  if [ ! "$now" \< "$POLL_START" ] && [ ! "$now" \> "$POLL_END" ]; then
    # ---- 轮询范围内：查看今晚的任务（该不该签由服务端任务数据决定）----
    # 时刻比较直接用 now_hm 的零填充字符串：字典序即时间序，不必换算分钟；
    # 两条否定合起来读作 POLL_START <= now <= POLL_END（test 没有 >= / <= 的写法）。
    # 当日已解决时不再查看——「今晚的事办完了就不再反复查询」。
    if ! signin_resolved_today; then
      run_once; rc=$?
      [ $rc -eq 0 ] && done_mark
      # 「任务未发布」兜底：到 min(轮询范围止, 本地 23 点) 仍未取得任务就喊一条。
      # 它挂本地时钟、不看任务数据，但目标时刻必然落在轮询范围内，故判定就在这里，
      # 不另开一条不看时间的旁路。当日已解决时同样一条都不发。
      # **它必须排在那条「任务异常就跳 4 分钟」之前**：rc=2 恰恰就是「取不到任务」——
      # 也就是最该喊这一条的情形，跳过去等于把兜底静默吞掉。
      signin_remind_notask "$now"
      # 任务异常（取不到任务）时下一轮排到 4 分钟后，与上面那条提醒互不相干
      [ $rc -eq 2 ] && rc_wait=240
    fi
  fi
  # ---- 白天保活：与「轮询范围内」并列，不受当日是否已解决影响 ----
  # 这两个条件都成立才保活：时段在配置里（窗口与节流都由 keepalive 层判定）；
  # 签到办完了照样要续期，且轮询范围与保活时段本就大面积重叠。
  if [ "$(cfg_keepalive)" = "1" ] && ka_in_window; then
    now_ts=$(now_s)
    if ka_due "$now_ts"; then
      KA_LAST=$now_ts
      keepalive_ping
    fi
  fi
  sleep "$rc_wait"
done
