#!/system/bin/sh
# ============================================================
# 数字FAFU 晚查寝自动签到 —— 入口脚本
#
# 本文件只做「装配与调度」：定位模块目录 → 加载配置 → 按序加载各层 →
# 命令分发 → 守护主循环；能力实现都在同目录的 lib/ 各层里（改一个功能
# 只需读一到两层）。层清单见下面的 FAFU_LAYERS：顺序即依赖方向，
# 少一层就写日志并以非 0 退出（半装是最难排查的失败模式，必须先响亮地失败）。
#
# 功能：
#   1) 自动签到：主窗口 21:30~22:30 每分钟检查，未签到自动提交；未成功时在补签时段（22:30~23:00）内继续重试
#   2) 白天保活 07:00~21:25：每 15 分钟轻量调用接口，保持会话不过期；
#      每次保活结果均写入日志与统计文件（status 可查看今日成功/失败数）；
#      调用失败时自动刷新：熄屏下静默进行；屏幕亮着时延后（避免打扰），
#      留待熄屏后静默刷新，或由 21:30 签到流程一并处理
#   3) 会话失效自动刷新：熄屏/锁屏下静默进行（屏幕不亮、不唤醒）
#   4) 刷新后自动清理页面（am stack remove）：拿到新 token 即移除打卡页，前台随即交还用户；
#      清理不彻底就让它留在后台，绝不主动切换用户的前台
#   5) 服务开关：一键启用/停用（操作按钮或命令），停用期间无任何网络请求
#   6) 动态描述：模块描述显示开关状态与签到日期时间（绝对日期，守护进程退出后信息不失真）
#   7) 全部系统命令 fd 加固（规避 KernelSU 下 SELinux 的 binder fd 限制）
#   8) 通知提醒：签到成功 / 补签成功 / 已签到 / 已请假 / 首次签到失败 / 首次获取任务失败 /
#      22:00·22:30·23:00 三次未签提醒 / 打开打卡页前的预警（仅屏幕已亮时发）。
#      通知以 shell 身份降权发送（root 身份发出的会被部分 ROM 静默丢弃）；
#      通知失败绝不影响签到主流程。
#      收不到通知时依次查：启动日志的 notify=[...]、系统设置里 Shell 的通知权限、
#      以及熄屏过久导致的 Doze 延迟投递。
#
# 用法：
#   sh fafu_checkin.sh [start|stop|status|notify|once|refresh|keepalive|toggle|enable|disable]
#     start      启动守护进程（若已停用则忽略）
#     stop       停止守护进程（不改变开关状态）
#     status     查看开关 / 服务 / token 状态
#     notify     发一条测试通知，确认通知链路是否真的能送到
#     once       立即检查一次并签到（幂等）
#     refresh    手动刷新 token（测试用）
#     keepalive  手动执行一次保活检查
#     toggle     切换服务开关（启用 ⇄ 停用）
#     enable     启用服务
#     disable    停用服务
#
#   日常使用无需手动触发通知：签到结果、三个未签时点、打开打卡页前的预警
#   都由守护进程自动发送。
#
# 配置文件（可选）：模块目录内 fafu-checkin.conf
#   KEEPALIVE=0     关闭白天保活（仅保留 21:30 自动签到）
#   NOTIFY=0        关闭全部通知
#   NOTIFY_LEAD=5   打卡页打开前的预警提前量（秒）；0 = 不加延时。仅屏幕已亮时生效
#
# 运行时文件（全部位于模块目录内，随模块卸载一并清除）：
#   日志 $MODDIR/fafu_checkin.log
#   进程 $MODDIR/.fafu_checkin.pid
#   标记 $MODDIR/.fafu_checkin_done
#   开关 $MODDIR/fafu-checkin.state
#   签到 $MODDIR/fafu_checkin.status
#   保活 $MODDIR/fafu_keepalive.status
#   通知 $MODDIR/.fafu_notify_fail      当日失败类通知已发
#        $MODDIR/.fafu_notify_nosign    22:00 未签提醒已发
#        $MODDIR/.fafu_notify_late      22:30 窗口切换提醒已发
#        $MODDIR/.fafu_notify_miss      23:00 最终未签提醒已发
#        $MODDIR/.fafu_notify_last      预警冷却基准（unix 秒）
#   除日志与 PID 文件外，上面这些运行时状态的读写都归 lib/state.sh（其余层只经它访问）
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

# ---- 子命令分发 ----
CMD="$1"
# 今日日期 tag（YYYYMMDD）：通知 tag 与「当日首次」判定都用它。
# 守护主循环每轮会重算一次——进程常驻，跨日后 tag 不应仍停在启动那天。
PL=$(today_tag)
# 通知降权探测：必须在分发之前执行——各通知类子命令都会在分支里直接 exit，
# 放在 case 之后会成为永远执行不到的死代码（曾踩过）。探测结果写入 $SU_MODE，
# 随后由守护进程经 FAFU_SU_MODE 继承。最长阻塞 1 秒。
case "$CMD" in
  start|""|once|refresh|keepalive|notify) probe_su ;;
esac
case "$CMD" in
  once)      run_once; exit $? ;;
  refresh)   cmd_refresh; exit 0 ;;
  keepalive) cmd_keepalive; exit 0 ;;
  notify)    cmd_notify; exit $? ;;
  status)    cmd_status; exit 0 ;;
  stop)      cmd_stop; exit 0 ;;
  toggle)    cmd_toggle; exit 0 ;;
  enable)    cmd_enable; exit 0 ;;
  disable)   cmd_disable; exit 0 ;;
  start|"")  : ;;
  *)         echo "用法: sh $SELF [start|stop|status|notify|once|refresh|keepalive|toggle|enable|disable]"; exit 1 ;;
esac

# ---- 启动守护进程（后台化 + 单实例） ----
if [ -z "$FAFU_DAEMON" ]; then
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
fi

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
