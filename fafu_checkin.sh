#!/system/bin/sh
# ============================================================
# 数字FAFU 晚查寝自动签到 —— 核心脚本
# 可独立运行，也可作为 KernelSU / Magisk 模块的一部分运行
#
# 功能：
#   1) 自动签到：主窗口 21:30~22:30 每分钟检查，未签到自动提交；未成功时在补签时段（22:30~23:00）内继续重试
#   2) 白天保活 07:00~21:25：每 15 分钟轻量调用接口，保持会话不过期；
#      每次保活结果均写入日志与统计文件（status 可查看今日成功/失败数）；
#      调用失败时自动刷新（熄屏静默无感；亮屏会短暂出现页面数秒，30 分钟冷却）
#   3) 会话失效自动刷新：熄屏/锁屏下静默进行（屏幕不亮、不唤醒）
#   4) 刷新后自动清理页面（am stack remove，不留残留、不甩回桌面）
#   5) 服务开关：一键启用/停用（操作按钮或命令），停用期间无任何网络请求
#   6) 动态描述：模块描述显示开关状态与签到日期时间（绝对日期，守护进程退出后信息不失真）
#   7) 全部系统命令 fd 加固（规避 KernelSU 下 SELinux 的 binder fd 限制）
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
# 配置文件（可选）：模块目录内 fafu-checkin.conf
#   KEEPALIVE=0   关闭白天保活（仅保留 21:30 自动签到）
#
# 运行时文件（全部位于模块目录内，随模块卸载一并清除）：
#   日志 $MODDIR/fafu_checkin.log
#   进程 $MODDIR/.fafu_checkin.pid
#   标记 $MODDIR/.fafu_checkin_done
#   开关 $MODDIR/fafu-checkin.state
#   签到 $MODDIR/fafu_checkin.status
#   保活 $MODDIR/fafu_keepalive.status
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
LD="/data/data/cn.edu.fafu.iportal/app_webview/Default/Local Storage/leveldb"
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

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

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
  "$BB" grep -v '^description=' "$MODDIR/module.prop" > "$MODDIR/module.prop.tmp" 2>/dev/null
  printf 'description=%s\n' "$1" >> "$MODDIR/module.prop.tmp"
  mv -f "$MODDIR/module.prop.tmp" "$MODDIR/module.prop" 2>/dev/null
  chmod 644 "$MODDIR/module.prop" 2>/dev/null
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

close_page() {
  # 优先用 am stack remove 移除 App 任务；失败则回桌面兜底
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
  if [ "$C" -gt 0 ]; then
    log "任务移除未彻底(残留$C)，回桌面兜底"
    am start -a android.intent.action.MAIN -c android.intent.category.HOME </dev/null >/dev/null 2>&1
    sleep 2
    C=$(act_count)
  fi
  log "页面关闭检查: 残留活动=$C"
}

refresh_token() { # $1=旧token；$2=允许唤醒重试(1=是,0=否，默认1)；输出最新 token
  log "刷新 token（静默优先）"
  WAS_ON=0
  screen_is_on && WAS_ON=1
  # 阶段1：不亮屏直接启动（熄屏/锁屏下屏幕不亮）
  open_page
  i=0; t=""
  while [ $i -lt 10 ]; do
    sleep 3
    t=$(get_token)
    [ -n "$t" ] && [ "$t" != "$1" ] && break
    i=$((i+1))
  done
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
    log "[$name] 已签到(状态$state)"
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
    else
      log "✅ 签到成功 [$name]"
      status_set "$td" "$hm" "normal"
    fi
    update_desc
    return 0
  fi
  log "签到失败: rc=$rc $(echo "$resp2" | "$BB" head -c 120)"; return 1
}

KA_LAST=0
KA_LAST_REFRESH=0

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
  now2=$("$BB" date +%s)
  if [ $((now2 - KA_LAST_REFRESH)) -lt 1800 ]; then
    log "保活: ❌ 调用失败 $tok (今日 $okc 成功 / $failc 失败) — 刷新冷却中，稍后再试"
    return 0
  fi
  KA_LAST_REFRESH=$now2
  if screen_is_on; then
    ka_mode="刷新（亮屏）"
  else
    ka_mode="静默刷新"
  fi
  log "保活: ⚠️ 调用失败 $tok (今日 $okc 成功 / $failc 失败) — 尝试$ka_mode"
  newt=$(refresh_token "$tok" 0)
  if [ -n "$newt" ] && [ "$newt" != "$tok" ]; then
    log "保活: ✅ $ka_mode成功 $tok → $newt"
  else
    log "保活: ❌ $ka_mode未成功（可能网络不可用），token 仍为 $tok"
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
  export FAFU_DAEMON=1
  "$BB" nohup sh "$SELF" start </dev/null >/dev/null 2>&1 &
  echo "服务已启动"
  exit 0
fi

# ---- 守护主循环 ----
echo $$ > "$PIDF"
log "===== 服务启动 (PID $$) 版本=${VER:-未知} wget_timeout=[${WGET_T:-无}] ====="

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
