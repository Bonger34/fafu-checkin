#!/system/bin/sh
# ============================================================
# 数字FAFU 晚查寝自动签到 —— 核心脚本
# 可独立运行，也可作为 KernelSU / Magisk 模块的一部分运行
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
#   sh fafu_checkin.sh [start|stop|status|once|refresh|keepalive|toggle|enable|disable]
#     start      启动守护进程（若已停用则忽略）
#     stop       停止守护进程（不改变开关状态）
#     status     查看开关 / 服务 / token 状态
#     once       立即检查一次并签到（幂等）
#     refresh    手动刷新 token（测试用）
#     keepalive  手动执行一次保活检查
#     toggle     切换服务开关（启用 ⇄ 停用）
#     enable     启用服务
#     disable    停用服务
#
#   通知无需命令触发，由守护进程自动发送；要手动验证通知能否送达，执行：
#     su -c sh /data/adb/modules/fafu-checkin/fafu_checkin.sh once
#   它会触发一次签到检查并按结果弹通知（21:30~22:59 会真正提交签到，其余时段
#   多为「已签到 / 已请假 / 拿不到任务」）。
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
# ============================================================

export PATH="/system/bin:/system/xbin:/data/adb/ksu/bin:/data/adb/magisk:$PATH"

# ---- 自身路径与模块目录 ----
SELF="$0"
case "$SELF" in
  /*) : ;;
  *) [ -f "$SELF" ] && SELF="$PWD/$SELF" ;;
esac
MODDIR="${SELF%/*}"
[ -f "$MODDIR/fafu_checkin.sh" ] || MODDIR="/data/adb/modules/fafu-checkin"
[ -f "$MODDIR/fafu_checkin.sh" ] || MODDIR="/data/adb/modules_update/fafu-checkin"
VER=$(grep -m1 '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)

# ---- busybox（KernelSU / Magisk / 系统） ----
BB=/data/adb/ksu/bin/busybox
[ -x "$BB" ] || BB=/data/adb/magisk/busybox
[ -x "$BB" ] || BB=busybox
BB="${BB_OVERRIDE:-$BB}"   # 允许测试注入替身（生产环境不设置）

# ---- ksud（KernelSU 用户空间工具；用于官方「动态描述」覆盖） ----
KSUD=/data/adb/ksu/bin/ksud
[ -x "$KSUD" ] || KSUD=/data/adb/ksud
[ -x "$KSUD" ] || KSUD=$(command -v ksud 2>/dev/null)
[ -x "$KSUD" ] || KSUD=""

# 探测 wget 是否支持 -T 超时选项（个别 busybox 构建未启用；不支持则自动省略）
WGET_T=""
case "$("$BB" wget --help 2>&1)" in
  *"-T"*) WGET_T="-T 20" ;;
esac

# ---- 常量 ----
SECRET="AtPs2O1xEnhwkKDV"
API="http://stuhtapi.fafu.edu.cn/health-api"
PKG="cn.edu.fafu.iportal"
PAGE="http://stuhealth.fafu.edu.cn/declarew/#/fafu/login"
LD="${LD_DIR:-/data/data/cn.edu.fafu.iportal/app_webview/Default/Local Storage/leveldb}"
# 运行时文件统一存放于模块目录内（不写入 /data/adb/ 根目录）
LOG="$MODDIR/fafu_checkin.log"
PIDF="$MODDIR/.fafu_checkin.pid"
DONE="$MODDIR/.fafu_checkin_done"
CONFIG="$MODDIR/fafu-checkin.conf"
MODID="fafu-checkin"
STATE="$MODDIR/fafu-checkin.state"
STATUS="$MODDIR/fafu_checkin.status"
KASTAT="$MODDIR/fafu_keepalive.status"

# ---- 可选配置（覆盖默认值） ----
[ -f "$CONFIG" ] && . "$CONFIG"
KEEPALIVE="${KEEPALIVE:-1}"
# ---- 通知相关配置 ----
NOTIFY="${NOTIFY:-1}"                  # 1=启用通知，0=完全关闭（零调用）
NOTIFY_LEAD="${NOTIFY_LEAD:-5}"        # 兜底唤醒前的预警提前量（秒）
NOTIFY_COOLDOWN="${NOTIFY_COOLDOWN:-300}"  # 同类打扰通知的最小间隔（秒）
SU_BIN="${SU_BIN:-/system/bin/su}"         # su 路径（可用环境变量覆盖，供 mock 测试注入）

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# ---- 降权身份探测（通知必须以 shell 身份发送） ----
# 不能用退出码判断可用性：KernelSU 的 su 用 Rust getopts 且默认 StopAtFirstFree，
# 长度为 1 的 `-` 会被当作 free 参数终止选项解析，于是 `su - shell -c CMD` 实际 exec
# 出交互式登录 shell、把 CMD 丢掉，`</dev/null` 下立刻 EOF 退出 0 —— 只看退出码就会
# 记成「可用」，之后每条通知都变成「rc=0 但什么都没发生」。故必须验证命令真的执行了、
# 且身份真的降到了 shell：读 `id -u` 的输出，要求等于 2000。
probe_su() {
  SU_MODE=""
  [ "$NOTIFY" = "1" ] || return 0
  # 父进程已探测过（守护进程由 start 派生）→ 直接继承，避免重复探测
  if [ -n "${FAFU_SU_MODE:-}" ]; then
    SU_MODE="$FAFU_SU_MODE"
    return 0
  fi
  [ -n "$(command -v "$SU_BIN" 2>/dev/null)" ] || { log "通知链路: 找不到 su（$SU_BIN），通知将静默跳过"; return 0; }
  for c in "su - shell -c" "su shell -c" "su shell /system/bin/sh -c"; do
    # timeout 防止 su 挂起拖死启动；但它未必存在，且超时本身可能是「冷启动慢」
    # 而非「真的不可用」，故用更宽松的超时重试一次，避免把可用链路误判为不可用
    if [ -n "$(command -v timeout 2>/dev/null)" ]; then
      u=$(timeout 2 $c 'id -u' </dev/null 2>/dev/null)
      [ "$u" = "2000" ] || u=$(timeout 5 $c 'id -u' </dev/null 2>/dev/null)
    else
      u=$($c 'id -u' </dev/null 2>/dev/null)
      [ "$u" = "2000" ] || u=$($c 'id -u' </dev/null 2>/dev/null)
    fi
    # 必须同时满足「有输出」且「uid=2000」——只验 rc 会被空执行骗过
    if [ "$u" = "2000" ]; then
      SU_MODE="$c"
      log "通知链路: 降权写法 [$c] 可用（id -u = 2000）"
      return 0
    fi
  done
  log "通知链路: 降权不可用（候选写法均未通过 id 校验），通知将静默跳过"
  return 0
}

rotate_log() { # 日志超过 256KB 时保留最近 1000 行（防止长期运行无限增长）
  [ -f "$LOG" ] || return 0
  sz=$("$BB" wc -c < "$LOG" 2>/dev/null | "$BB" tr -dc '0-9')
  [ -n "$sz" ] || return 0
  [ "$sz" -gt 262144 ] || return 0
  "$BB" tail -n 1000 "$LOG" > "$LOG.rot" 2>/dev/null || return 0
  "$BB" mv -f "$LOG.rot" "$LOG" 2>/dev/null
  log "日志已轮转（保留最近 1000 行）"
}

# ---- 服务开关 ----
is_disabled() {
  [ -f "$STATE" ] && [ "$("$BB" cat "$STATE" 2>/dev/null)" = "disabled" ]
}

# ---- 签到记录（用于动态描述） ----
status_get() { # $1=键名（sign_date / sign_time / sign_kind）
  [ -f "$STATUS" ] || return 0
  "$BB" grep -m1 "^$1=" "$STATUS" 2>/dev/null | "$BB" cut -d= -f2-
}

status_set() { # $1=日期 $2=时间(可空) $3=类型(normal/supplement/detected/leave)
  printf 'sign_date=%s\nsign_time=%s\nsign_kind=%s\n' "$1" "$2" "$3" > "$STATUS"
}

# ---- 保活统计（记录每次保活结果，供日志与 status 查询） ----
ka_state_get() { # $1=键名（date / ok / fail / last / last_result）
  [ -f "$KASTAT" ] || return 0
  "$BB" grep -m1 "^$1=" "$KASTAT" 2>/dev/null | "$BB" cut -d= -f2-
}

ka_record() { # $1=ok|fail；$2=本次使用的 token（可选，记录到统计文件）
  today=$("$BB" date +%Y-%m-%d)
  d=$(ka_state_get date); ok=$(ka_state_get ok); fail=$(ka_state_get fail)
  [ "$d" = "$today" ] || { ok=0; fail=0; }
  ok=${ok:-0}; fail=${fail:-0}
  case "$1" in
    ok)   ok=$((ok+1)) ;;
    fail) fail=$((fail+1)) ;;
  esac
  tk="${2:-$(ka_state_get token)}"
  printf 'date=%s\nok=%s\nfail=%s\nlast=%s\nlast_result=%s\ntoken=%s\n' \
    "$today" "$ok" "$fail" "$("$BB" date '+%Y-%m-%d %H:%M:%S')" "$1" "$tk" > "$KASTAT"
}

state_text() { # $1=signState 数值 → 自解释的中文（日志与通知都不该让读者去查状态码表）
  case "$1" in
    1) echo "已签到" ;;
    2) echo "已请假" ;;
    *) echo "未知状态($1)" ;;
  esac
}

# ---- 通知（纯增量能力：任何失败都不得影响签到主流程） ----
# 以 shell 身份降权发送；root 身份发出的通知会被部分 ROM 静默丢弃（rc=0 但不显示）。
# 三条硬约束（cmd notification post 的实现）：
#   1) 通知 id 恒为 2020，只能靠 tag 区分事件；同 tag 会覆盖（静默更新）
#   2) channel 恒为 shell_cmd，重要性 / 声音 / 图标均不可调
#   3) 不支持 ongoing / autoCancel / 按钮
# tag 用含日期的「按日滚动」，同事件次日覆盖前一天，通知栏条数恒有上限。
SU_MODE=""                # 生效的降权写法，由 probe_su() 探测后写入
_NT_TITLE=""              # 通知标题（调用方设置）
_NT_TEXT=""               # 通知正文；留空则复用标题（用于 P 预警）
# 打扰类通知的冷却基准落盘保存：refresh_token 总在 $( ) 子 shell 里被调用，
# 若把基准放在普通变量里，赋值会随子 shell 一起丢弃 → 冷却永远不生效
NTLAST="$MODDIR/.fafu_notify_last"
PL=$("$BB" date +%Y%m%d)  # 今日 YYYYMMDD，供 tag 与「当日首次」判定

# ---- 签到 / 通知文案模板（正文不含引号与命令替换，可安全直接展开） ----
_msg_sign()   { _NT_TITLE="✅ 查寝签到成功";      _NT_TEXT="$PL 已签到（晚查寝签到）"; }
_msg_supp()   { _NT_TITLE="🕘 已补签";            _NT_TEXT="$PL 补签成功"; }
_msg_seen()   { _NT_TITLE="✅ 今日已签到";        _NT_TEXT="$PL 已签到（晚查寝签到）"; }
_msg_leave()  { _NT_TITLE="🏖 今日查寝已请假";    _NT_TEXT="$PL 状态为请假，不会自动签到"; }
_msg_failsign() { _NT_TITLE="⚠️ 查寝签到失败";    _NT_TEXT="$PL 提交失败，仍在重试（22:59 前有效）"; }
_msg_failtask() { _NT_TITLE="⚠️ 拿不到查寝任务";  _NT_TEXT="$PL 无法获取任务，仍在重试"; }
_msg_nosign() { _NT_TITLE="⏰ 尚未签到，主窗口还剩 30 分钟"
                _NT_TEXT="$PL 22:00 还没签到，主窗口 22:30 关闭；现在可在 App 内手动签到"; }
_msg_late()   { _NT_TITLE="⏰ 主窗口已过，进入补签时段"
                _NT_TEXT="$PL 22:30 仍未签到，模块会继续自动重试，也可在 App 内手动补签"; }
_msg_miss()   { _NT_TITLE="❌ 今晚未能自动签到"
                _NT_TEXT="$PL 23:00 重试结束仍未签到，请手动处理"; }

notify() { # $1=tag；使用全局 _NT_TITLE / _NT_TEXT；返回发送是否成功
  [ "$NOTIFY" = "1" ] || return 0
  [ -n "$SU_MODE" ] || return 0
  [ -n "$1" ] || return 0
  # 命令交由 su 派生出的新 shell 执行，标题/正文必须 export 才能被子 shell 看到，
  # 否则实际发出的是空标题空正文（su 仍返回成功，属静默失效）
  export _NT_TITLE _NT_TEXT
  # $1（tag）在此处展开；$_NT_TITLE 等保留给子 shell 展开
  _ntc="cmd notification post -t \"\$_NT_TITLE\" \"$1\" \"\${_NT_TEXT:-\$_NT_TITLE}\" -S bigtext"
  [ -n "$NOTIFY_CMD" ] && _ntc="$NOTIFY_CMD"
  if $SU_MODE "$_ntc" </dev/null >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

notify_once() { # $1=tag $2=当日标记文件；仅在**发送成功**时才写标记
  [ "$NOTIFY" = "1" ] || return 0
  [ -n "$SU_MODE" ] || return 0
  [ "$("$BB" cat "$2" 2>/dev/null)" = "$("$BB" date +%Y-%m-%d)" ] && return 0
  # 先发送、成功再落标记：否则一次瞬时失败会让这类提醒整天不再出现
  if notify "$1"; then
    "$BB" date +%Y-%m-%d > "$2" 2>/dev/null
    return 0
  fi
  return 1
}

notify_lead() { # 输出预警提前量秒数；屏幕本来就黑时不延时（省下无意义的等待）
  if [ "${WAS_ON:-0}" = "1" ] && [ "$NOTIFY_LEAD" -gt 0 ] 2>/dev/null; then
    echo "$NOTIFY_LEAD"
  else
    echo 0
  fi
}

desc_text() { # 生成当前应显示的模块描述（使用绝对日期，守护进程退出后信息也不会失真）
  today=$("$BB" date +%Y-%m-%d)
  d=$(status_get sign_date)
  t=$(status_get sign_time)
  k=$(status_get sign_kind)
  if is_disabled; then
    if [ -n "$d" ]; then
      dd=${d#*-}
      if [ -n "$t" ]; then echo "⏸ 已停用 · 最近签到 $dd $t"; else echo "⏸ 已停用 · 最近签到 $dd"; fi
    else
      echo "⏸ 已停用 · 暂无签到记录"
    fi
  elif [ "$d" = "$today" ] && [ "$k" = "leave" ]; then
    echo "🟢 已启用 · 🏖 ${d#*-} 已请假"
  elif [ "$d" = "$today" ]; then
    if [ -n "$t" ]; then echo "🟢 已启用 · ✅ ${d#*-} 已签到 $t"; else echo "🟢 已启用 · ✅ ${d#*-} 已签到"; fi
  else
    echo "🟢 已启用 · ⏳ ${today#*-} 未签到"
  fi
}

set_desc() { # $1=描述文本；优先 KernelSU 官方覆盖，失败则改写 module.prop（Magisk）
  if [ -n "$KSUD" ]; then
    if KSU_MODULE="$MODID" "$KSUD" module config set override.description "$1" >/dev/null 2>&1; then
      return 0
    fi
  fi
  [ -f "$MODDIR/module.prop" ] || return 1
  tmp="$MODDIR/module.prop.tmp"
  "$BB" grep -v '^description=' "$MODDIR/module.prop" > "$tmp" 2>/dev/null
  # 校验：grep 失败会留下空文件，直接 mv 会把 module.prop 清空（模块元数据全丢）
  [ -s "$tmp" ] || { rm -f "$tmp" 2>/dev/null; return 1; }
  printf 'description=%s\n' "$1" >> "$tmp"
  "$BB" mv -f "$tmp" "$MODDIR/module.prop" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  "$BB" chmod 644 "$MODDIR/module.prop" 2>/dev/null
  return 0
}

update_desc() { # 计算描述并写入（内容变化时才写）
  new=$(desc_text)
  cur=""
  if [ -n "$KSUD" ]; then
    cur=$(KSU_MODULE="$MODID" "$KSUD" module config get override.description 2>/dev/null)
  fi
  if [ -z "$cur" ] && [ -f "$MODDIR/module.prop" ]; then
    cur=$("$BB" grep -m1 '^description=' "$MODDIR/module.prop" 2>/dev/null | "$BB" cut -d= -f2-)
  fi
  [ "$new" = "$cur" ] && return 0
  set_desc "$new"
}

get_token() {
  "$BB" ls -tr "$LD" 2>/dev/null | while IFS= read -r n; do
    "$BB" cat "$LD/$n" 2>/dev/null
  done | "$BB" tr -d '\000' | "$BB" grep -o '"token":"2_[0-9A-Fa-f]*"' \
       | "$BB" tail -n 1 | "$BB" cut -d'"' -f4
}

mk_auth() { # $1=sign_url $2=token
  ts=$("$BB" date +%s)
  nonce=$("$BB" head -c 24 /dev/urandom | "$BB" base64 | "$BB" tr -dc 'A-Za-z0-9' | "$BB" head -c 16)
  hash=$(printf '%s' "${SECRET}$1${ts}${nonce}" | "$BB" md5sum | "$BB" cut -d' ' -f1)
  printf '%s' "${ts}:${nonce}:${hash}:$2" | "$BB" base64 | "$BB" tr -d '\n'
}

api() { # $1=path $2=query $3=token → 输出响应体；返回 wget 退出码
  url="$API/$1"
  [ -n "$2" ] && url="$url?$2"
  auth=$(mk_auth "$API/$1" "$3")
  "$BB" wget -q $WGET_T -O - --header="Authorization: $auth" --post-data='' "$url" 2>/dev/null
}

screen_is_on() {
  _out=$(dumpsys power 2>/dev/null)
  [ -n "$_out" ] || return 0     # 检测失败时按“屏幕亮着”处理，避免误熄屏
  echo "$_out" | "$BB" grep -qE 'mWakefulness=Awake|Display Power: state=ON|mScreenState=ON'
}

act_count() {
  dumpsys activity activities 2>/dev/null \
    | "$BB" grep -oE 'ActivityRecord\{[^}]*cn\.edu\.fafu\.iportal[^}]*\}' \
    | "$BB" sort -u | "$BB" wc -l | "$BB" tr -dc '0-9'
}

app_task_ids() {
  dumpsys activity activities 2>/dev/null \
    | "$BB" grep -oE 'ActivityRecord\{[^}]*cn\.edu\.fafu\.iportal[^}]*\}' \
    | "$BB" grep -oE 't[0-9]+[ }]' | "$BB" tr -dc '0-9\n' \
    | "$BB" sort -u | "$BB" tr '\n' ' '
}

open_page() {
  am start --user 0 -n "$PKG/huawei.w3.ui.welcome.W3SplashScreenActivity" \
    -a com.huawei.works.action.shortcut -c android.shortcut.conversation \
    -d "$PAGE" --ei src 202 </dev/null >/dev/null 2>&1
}
# 说明：「把用户原来的 App 提回前台」这条路径已实测否定，故不再保留相关代码。

close_page() {
  # 移除打卡页所在任务，让页面退场；清理不彻底就让它留在后台，
  # 绝不主动切换用户的前台（曾经在这里用回桌面兜底，会把正在用手机的人直接甩到桌面）。
  # 注意：循环变量名不要用 t（会与调用方 refresh_token 的 token 变量冲突）
  ids=$(app_task_ids)
  for tid in $ids; do am stack remove "$tid" </dev/null >/dev/null 2>&1; done
  sleep 2
  C=$(act_count)
  if [ "$C" -gt 0 ]; then
    ids=$(app_task_ids)
    for tid in $ids; do am stack remove "$tid" </dev/null >/dev/null 2>&1; done
    sleep 2
    C=$(act_count)
  fi
  [ "$C" -gt 0 ] && log "页面移除未彻底(残留$C)，保留在后台（不再回桌面）"
  log "页面关闭检查: 残留活动=$C"
}

refresh_token() { # $1=旧token；$2=允许唤醒重试(1=是,0=否，默认1)；输出最新 token
  log "刷新 token（静默优先）"
  WAS_ON=0
  screen_is_on && WAS_ON=1
  # 开页预警：屏幕已亮时，本次确实会打开打卡页 → 先通知再开，别让页面毫无解释地跳出来。
  # （熄屏时不开预警：用户看不见，且静默开页本就不打扰。）
  # 冷却用于防突发：一次刷新失败可能连锁触发多次 refresh_token，避免连续弹同一条。
  if [ "${WAS_ON:-0}" = "1" ] && [ -n "$SU_MODE" ]; then
    now_s=$("$BB" date +%s)
    _last=$("$BB" cat "$NTLAST" 2>/dev/null | "$BB" tr -dc '0-9')
    [ -n "$_last" ] || _last=0
    if [ $((now_s - _last)) -ge "$NOTIFY_COOLDOWN" ]; then
      echo "$now_s" > "$NTLAST" 2>/dev/null
      _NT_TITLE="🔄 正在刷新登录状态"
      _NT_TEXT="$(notify_lead) 秒后自动打开打卡页（用于刷新登录），完成后自动关闭，无需操作"
      notify "fafu-warn-$PL"
      sleep "$(notify_lead)"   # 留出阅读时间；提前量由 NOTIFY_LEAD 配置，默认 5 秒
    fi
  fi
  # 阶段1：打开打卡页（熄屏/锁屏下屏幕不亮）
  open_page
  i=0; t=""
  while [ $i -lt 10 ]; do
    sleep 3
    t=$(get_token)
    [ -n "$t" ] && [ "$t" != "$1" ] && break
    i=$((i+1))
  done
  # 一到手就把页面移出前台：前台会自动回到用户原来的 App，尽量缩短中断时间。
  # 拿不到新 token 时不提前关页，保持与原先一致的兜底时序（走完阶段2再关）。
  if [ -n "$t" ] && [ "$t" != "$1" ]; then
    log "已取得新 token，提前移除打卡页（前台交还用户）"
    close_page
  fi
  # 阶段2：失败则唤醒屏幕重试（保活场景禁止，避免吵醒用户）
  if [ -z "$t" ] || [ "$t" = "$1" ]; then
    if [ "$2" != "0" ]; then
      log "静默刷新未成功，尝试唤醒屏幕重试"
      [ "$WAS_ON" = "1" ] || input keyevent 224 </dev/null >/dev/null 2>&1
      wm dismiss-keyguard </dev/null >/dev/null 2>&1
      i=0
      while [ $i -lt 20 ]; do
        sleep 3
        t=$(get_token)
        [ -n "$t" ] && [ "$t" != "$1" ] && break
        i=$((i+1))
      done
    fi
  fi
  if [ -n "$t" ] && [ "$t" != "$1" ]; then
    log "刷新成功: $1 → $t"
  else
    log "刷新未获得新 token（超时，仍为 $1）"
  fi
  close_page
  if [ "$WAS_ON" = "0" ]; then
    input keyevent 223 </dev/null >/dev/null 2>&1
    log "屏幕原为关闭，已恢复熄屏"
  else
    log "屏幕原本亮着，保持不熄屏"
  fi
  echo "$t"
}

run_once() {
  if [ ! -d "$LD" ]; then
    log "未检测到应用数据（未安装或未登录）"; return 2
  fi
  token=$(get_token)
  resp=$(api "sign_in/student/my/page" "rows=3&pageNum=1" "$token"); rc=$?
  if [ $rc -ne 0 ] || ! echo "$resp" | "$BB" grep -q '"records"'; then
    log "查询异常(rc=$rc)，尝试刷新 token"
    newt=$(refresh_token "$token")
    [ -n "$newt" ] && token=$newt
    resp=$(api "sign_in/student/my/page" "rows=3&pageNum=1" "$token"); rc=$?
    if [ $rc -ne 0 ] || ! echo "$resp" | "$BB" grep -q '"records"'; then
      log "获取任务失败: rc=$rc $(echo "$resp" | "$BB" head -c 120)"
      _msg_failtask
      notify_once "fafu-failtask-$PL" "$NFAIL"
      return 2
    fi
  fi

  rid=$(echo "$resp"  | "$BB" grep -o '"id":[0-9]*'          | "$BB" head -n 1 | "$BB" cut -d: -f2)
  name=$(echo "$resp" | "$BB" grep -o '"name":"[^"]*"'       | "$BB" head -n 1 | "$BB" cut -d'"' -f4)
  state=$(echo "$resp"| "$BB" grep -o '"signState":[0-9]*'   | "$BB" head -n 1 | "$BB" cut -d: -f2)
  bt=$(echo "$resp"   | "$BB" grep -o '"beginTime":[0-9]*'   | "$BB" head -n 1 | "$BB" cut -d: -f2)
  dline=$(echo "$resp" | "$BB" grep -o '"supplementEndTime":[0-9]*' | "$BB" head -n 1 | "$BB" cut -d: -f2)
  [ -n "$dline" ] || dline=$(echo "$resp" | "$BB" grep -o '"endTime":[0-9]*' | "$BB" head -n 1 | "$BB" cut -d: -f2)
  lng=$(echo "$resp"  | "$BB" grep -o '"lng":[0-9][0-9.]*'   | "$BB" head -n 1 | "$BB" cut -d: -f2)
  lat=$(echo "$resp"  | "$BB" grep -o '"lat":[0-9][0-9.]*'   | "$BB" head -n 1 | "$BB" cut -d: -f2)

  if [ -z "$rid" ] || [ -z "$state" ] || [ -z "$bt" ] || [ -z "$dline" ]; then
    log "暂无有效任务（信息不完整）"; return 1
  fi

  now=$(( $("$BB" date +%s) * 1000 ))

  # 已签到（且是近期任务）→ 完成
  if [ "$state" != "0" ] && [ $(( now - dline )) -lt 21600000 ]; then
    log "[$name] $(state_text "$state")"
    # 记录检测到的签到信息（仅当今天尚无记录时）
    d=$(status_get sign_date)
    if [ "$d" != "$("$BB" date +%Y-%m-%d)" ]; then
      stime=""
      sst=$(echo "$resp" | "$BB" grep -o '"signTime":[0-9]*' | "$BB" head -n 1 | "$BB" cut -d: -f2)
      case "$sst" in
        ""|*[!0-9]*) : ;;
        *) stime=$("$BB" date -d "@$((sst / 1000))" +%H:%M 2>/dev/null) ;;
      esac
      if [ "$state" = "2" ]; then
        status_set "$("$BB" date +%Y-%m-%d)" "" "leave"
      else
        status_set "$("$BB" date +%Y-%m-%d)" "$stime" "detected"
      fi
    fi
    update_desc
    # 检测到已签到 / 已请假 → 通知（每次检测到都发；同事件同 tag 覆盖，不会堆积）
    if [ "$state" = "2" ]; then
      _msg_leave
      notify "fafu-leave-$PL"
    else
      _msg_seen
      notify "fafu-sign-$PL"
    fi
    return 0
  fi

  # 时间窗口外 → 等待重试
  if [ "$now" -lt "$bt" ] || [ "$now" -gt "$dline" ]; then
    log "[$name] 不在签到时段"; return 1
  fi

  # 定位参数：沿用最近一次签到坐标（本任务不校验位置）
  [ -n "$lng" ] || lng=119.243462
  [ -n "$lat" ] || lat=26.088417

  resp2=$(api "sign_in/$rid/student/sign" "lng=$lng&lat=$lat" "$token"); rc=$?
  if [ $rc -ne 0 ]; then
    newt=$(refresh_token "$token")
    [ -n "$newt" ] && token=$newt
    resp2=$(api "sign_in/$rid/student/sign" "lng=$lng&lat=$lat" "$token"); rc=$?
  fi
  if [ $rc -eq 0 ] && ! echo "$resp2" | "$BB" grep -q '"timestamp"'; then
    et=$(echo "$resp" | "$BB" grep -o '"endTime":[0-9]*' | "$BB" head -n 1 | "$BB" cut -d: -f2)
    td=$("$BB" date +%Y-%m-%d); hm=$("$BB" date +%H:%M)
    if [ -n "$et" ] && [ "$now" -gt "$et" ]; then
      log "✅ 补签成功 [$name]"
      status_set "$td" "$hm" "supplement"
      _msg_supp
      notify "fafu-supp-$PL"
    else
      log "✅ 签到成功 [$name]"
      status_set "$td" "$hm" "normal"
      _msg_sign
      notify "fafu-sign-$PL"
    fi
    update_desc
    return 0
  fi
  # 签到提交失败：当日仅首次通知（之后的重试只写日志，避免刷屏）
  log "签到失败: rc=$rc $(echo "$resp2" | "$BB" head -c 120)"
  _msg_failsign
  notify_once "fafu-failsign-$PL" "$NFAIL"
  return 1
}

KA_LAST=0
KA_LAST_REFRESH=0
NFAIL="$MODDIR/.fafu_notify_fail"        # 当日「失败类通知」已发标记
# 三个未签时点各自独立标记：若共用标记，22:00 先发会让 22:30 / 23:00 永远发不出来，
# 而 23:00 那条「今晚未能自动签到」恰恰是本功能存在的理由
NNOSIGN="$MODDIR/.fafu_notify_nosign"    # 22:00 未签提醒已发标记
NLATE="$MODDIR/.fafu_notify_late"        # 22:30 窗口切换提醒已发标记
NMISS="$MODDIR/.fafu_notify_miss"        # 23:00 最终未签提醒已发标记

keepalive_ping() {
  tok=$(get_token)
  [ -n "$tok" ] || return 0
  resp=$(api "sign_in/student/my/page" "rows=1&pageNum=1" "$tok"); rc=$?
  if [ $rc -eq 0 ] && echo "$resp" | "$BB" grep -q '"records"'; then
    ka_record ok "$tok"
    log "保活: ✅ token 有效 $tok (今日 $(ka_state_get ok) 成功 / $(ka_state_get fail) 失败)"
    return 0
  fi
  # 调用未成功：可能 token 已失效，也可能只是网络异常（busybox wget 不输出错误正文，无法区分）
  ka_record fail "$tok"
  okc=$(ka_state_get ok); failc=$(ka_state_get fail)
  # 屏幕亮着时延后刷新：避免白天出现无解释的页面弹出，留待熄屏（静默刷新）或签到时段处理
  if screen_is_on; then
    log "保活: ❌ 调用失败 $tok (今日 $okc 成功 / $failc 失败) — 屏幕亮着，延后（熄屏或签到时段自动刷新）"
    return 0
  fi
  now2=$("$BB" date +%s)
  if [ $((now2 - KA_LAST_REFRESH)) -lt 1800 ]; then
    log "保活: ❌ 调用失败 $tok (今日 $okc 成功 / $failc 失败) — 刷新冷却中，稍后再试"
    return 0
  fi
  KA_LAST_REFRESH=$now2
  log "保活: ⚠️ 调用失败 $tok (今日 $okc 成功 / $failc 失败) — 尝试静默刷新"
  newt=$(refresh_token "$tok" 0)
  if [ -n "$newt" ] && [ "$newt" != "$tok" ]; then
    log "保活: ✅ 静默刷新成功 $tok → $newt"
  else
    log "保活: ❌ 静默刷新未成功（可能网络不可用），token 仍为 $tok"
  fi
  return 0
}

# ---- 子命令函数 ----

cmd_refresh() {
  log "===== 手动刷新测试 ====="
  old=$(get_token)
  new=$(refresh_token "$old")
  if [ -n "$new" ] && [ "$new" != "$old" ]; then
    log "✅ 刷新成功: $new"
    resp=$(api "sign_in/student/my/page" "rows=1&pageNum=1" "$new"); rc=$?
    if [ $rc -eq 0 ] && echo "$resp" | "$BB" grep -q '"records"'; then
      log "✅ 新 token 接口验证通过"
    else
      log "⚠️ 新 token 接口验证异常(rc=$rc): $(echo "$resp" | "$BB" head -c 120)"
    fi
  else
    log "❌ 刷新失败（未获得新 token）"
  fi
}

cmd_keepalive() {
  log "===== 手动保活检查 ====="
  tok=$(get_token)
  if [ -z "$tok" ]; then
    log "无 token"
  else
    resp=$(api "sign_in/student/my/page" "rows=1&pageNum=1" "$tok"); rc=$?
    if [ $rc -eq 0 ] && echo "$resp" | "$BB" grep -q '"records"'; then
      log "token 有效: $tok"
    else
      log "调用未成功（token 失效或网络异常），token=$tok"
    fi
  fi
}

cmd_status() {
  echo "====== 数字FAFU 晚查寝自动签到 ======"
  [ -n "$VER" ] && echo "版本: $VER"
  # 开关状态
  if is_disabled; then echo "开关: ⏸ 已停用"; else echo "开关: 🟢 已启用"; fi
  # 服务状态
  if [ -f "$PIDF" ]; then
    pid=$("$BB" cat "$PIDF" 2>/dev/null)
    if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
      echo "服务: 运行中 (PID $pid)"
    else
      echo "服务: 未运行"
    fi
  else
    echo "服务: 未运行"
  fi
  # 保活状态（最近一次结果 + 今日统计）
  ka_last=$(ka_state_get last)
  if [ -z "$ka_last" ]; then
    echo "保活: 暂无记录"
  else
    if [ "$(ka_state_get last_result)" = "ok" ]; then ka_mark="✅"; else ka_mark="❌"; fi
    if [ "$(ka_state_get date)" = "$("$BB" date +%Y-%m-%d)" ]; then
      echo "保活: 最近 $ka_last $ka_mark · 今日 $(ka_state_get ok) 成功 / $(ka_state_get fail) 失败"
    else
      echo "保活: 最近 $ka_last $ka_mark（今日暂无记录）"
    fi
  fi
  # 描述预览
  echo "描述: $(desc_text)"
  # token 状态
  tok=$(get_token)
  if [ -z "$tok" ]; then
    echo "token: 未找到（应用未安装或未登录过）"
  else
    resp=$(api "sign_in/student/my/page" "rows=1&pageNum=1" "$tok"); rc=$?
    if [ $rc -eq 0 ] && echo "$resp" | "$BB" grep -q '"records"'; then
      echo "token: 有效 $tok"
    else
      echo "token: 失效或网络异常 $tok"
    fi
  fi
  echo "最近日志:"
  "$BB" tail -n 6 "$LOG" 2>/dev/null
  # 顺带刷新一次动态描述（保证日期与状态最新）
  update_desc
}

cmd_stop() {
  if [ -f "$PIDF" ]; then
    pid=$("$BB" cat "$PIDF" 2>/dev/null)
    if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
      kill "$pid" 2>/dev/null
      sleep 1
      [ -d "/proc/$pid" ] && kill -9 "$pid" 2>/dev/null
      log "守护进程已停止 (PID $pid)"
      echo "已停止 (PID $pid)"
    else
      echo "服务未在运行（清理残留 PID 文件）"
    fi
    rm -f "$PIDF"
  else
    echo "服务未在运行"
  fi
}

cmd_enable() {
  echo "enabled" > "$STATE"
  log "===== 服务已启用（操作按钮/命令） ====="
  sh "$SELF" start </dev/null >/dev/null 2>&1
  update_desc
  echo "🟢 服务已启用"
  echo "再次点击操作按钮可停用"
}

cmd_disable() {
  echo "disabled" > "$STATE"
  log "===== 服务已停用（操作按钮/命令） ====="
  cmd_stop </dev/null >/dev/null 2>&1
  update_desc
  echo "⏸ 服务已停用"
  echo "再次点击操作按钮可启用"
}

cmd_toggle() {
  if is_disabled; then
    cmd_enable
  else
    cmd_disable
  fi
}

# ---- 子命令分发 ----
CMD="$1"
# 通知降权探测：必须在分发之前执行——各通知类子命令都会在分支里直接 exit，
# 放在 case 之后会成为永远执行不到的死代码（曾踩过）。最长阻塞 1 秒。
case "$CMD" in
  start|""|once|refresh|keepalive) probe_su ;;
esac
case "$CMD" in
  once)      run_once; exit $? ;;
  refresh)   cmd_refresh; exit 0 ;;
  keepalive) cmd_keepalive; exit 0 ;;
  status)    cmd_status; exit 0 ;;
  stop)      cmd_stop; exit 0 ;;
  toggle)    cmd_toggle; exit 0 ;;
  enable)    cmd_enable; exit 0 ;;
  disable)   cmd_disable; exit 0 ;;
  start|"")  : ;;
  *)         echo "用法: sh $SELF [start|stop|status|once|refresh|keepalive|toggle|enable|disable]"; exit 1 ;;
esac

# ---- 启动守护进程（后台化 + 单实例） ----
if [ -z "$FAFU_DAEMON" ]; then
  if is_disabled; then
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
  if is_disabled; then
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
  h=$("$BB" date +%H); m=$("$BB" date +%M)
  h=${h#0}; m=${m#0}; [ -z "$h" ] && h=0; [ -z "$m" ] && m=0
  now=$((h * 60 + m))
  PL=$("$BB" date +%Y%m%d)   # 每轮重算：守护进程常驻，跨日后 tag 不应仍停在启动那天
  # ---- 未签到提醒：22:00（还剩 30 分钟）/ 22:30（窗口已过，进入补签）/ 23:00（补签窗口关闭） ----
  # 依据签到状态文件判定：当日已解决（已签到/已补签/已检测/已请假）则一律不发，避免假警报
  if [ $now -ge 1320 ]; then
    sd=$(status_get sign_date); sk=$(status_get sign_kind)
    if [ "$sd" = "$("$BB" date +%Y-%m-%d)" ] && [ "$sk" != "" ]; then
      :   # 当日状态已解决（含请假）→ 不提醒
    else
      # 三个时点各自独立标记：越晚的时点信息越关键，不能被更早的那条挡住
      if [ $now -ge 1380 ]; then
        _msg_miss;   notify_once "fafu-miss-$PL"   "$NMISS"
      elif [ $now -ge 1350 ]; then
        _msg_late;   notify_once "fafu-t2230-$PL"  "$NLATE"
      else
        _msg_nosign; notify_once "fafu-t2200-$PL"  "$NNOSIGN"
      fi
    fi
  fi
  # ---- 主窗口 21:30~22:30；补签时段 22:30~23:00（失败重试，最后一次不晚于 22:59 发起） ----
  if [ $now -ge 1290 ] && [ $now -le 1379 ]; then
    if [ "$("$BB" cat "$DONE" 2>/dev/null)" != "$("$BB" date +%Y-%m-%d)" ]; then
      run_once; rc=$?
      [ $rc -eq 0 ] && "$BB" date +%Y-%m-%d > "$DONE"
      [ $rc -eq 2 ] && { sleep 240; continue; }
    fi
  elif [ "$KEEPALIVE" = "1" ] && [ $now -ge 420 ] && [ $now -lt 1285 ]; then
    # ---- 白天保活 07:00~21:25，每 15 分钟一次 ----
    now_s=$("$BB" date +%s)
    if [ $((now_s - KA_LAST)) -ge 900 ]; then
      KA_LAST=$now_s
      keepalive_ping
    fi
  fi
  sleep 60
done
