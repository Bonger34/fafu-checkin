#!/system/bin/sh
# ============================================================
# 数字FAFU 晚查寝自动签到 —— 核心脚本 v1.0.0
# 可独立运行，也可作为 KernelSU / Magisk 模块的一部分运行
#
# 功能：
#   1) 自动签到：主窗口 21:30~22:30 每分钟检查，未签到自动提交；未成功时在补签时段（22:30~23:00）内继续重试
#   2) 白天保活 07:00~21:25：每 15 分钟轻量调用接口，保持会话不过期
#   3) 会话失效自动刷新：熄屏/锁屏下静默进行（屏幕不亮、不唤醒）
#   4) 刷新后自动清理页面（am stack remove，不留残留、不甩回桌面）
#   5) 全部系统命令 fd 加固（规避 KernelSU 下 SELinux 的 binder fd 限制）
#
# 用法：
#   sh fafu_checkin.sh [start|stop|status|once|refresh|keepalive]
#     start      启动守护进程（默认；后台运行、单实例）
#     stop       停止守护进程
#     status     查看运行状态与 token 状态
#     once       立即检查一次并签到（幂等）
#     refresh    手动刷新 token（测试用）
#     keepalive  手动执行一次保活检查
#
# 配置文件（可选）：/data/adb/fafu-checkin.conf
#   KEEPALIVE=0   关闭白天保活（仅保留 21:30 自动签到）
#
# 状态文件：
#   日志 /data/adb/fafu_checkin.log
#   锁   /data/adb/.fafu_checkin.pid
#   标记 /data/adb/.fafu_checkin_done
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
LOG="/data/adb/fafu_checkin.log"
PIDF="/data/adb/.fafu_checkin.pid"
DONE="/data/adb/.fafu_checkin_done"
CONFIG="/data/adb/fafu-checkin.conf"

# ---- 可选配置（覆盖默认值） ----
[ -f "$CONFIG" ] && . "$CONFIG"
KEEPALIVE="${KEEPALIVE:-1}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

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
    log "刷新成功: $t"
  else
    log "刷新未获得新 token（超时）"
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
    log "[$name] 已签到(状态$state)"; return 0
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
    if [ -n "$et" ] && [ "$now" -gt "$et" ]; then
      log "✅ 补签成功 [$name]"
    else
      log "✅ 签到成功 [$name]"
    fi
    return 0
  fi
  log "签到失败: rc=$rc $(echo "$resp2" | "$BB" head -c 120)"; return 1
}

KA_LAST=0
KA_LAST_REFRESH=0
KA_OK_DATE=""

keepalive_ping() {
  tok=$(get_token)
  [ -n "$tok" ] || return 0
  resp=$(api "sign_in/student/my/page" "rows=1&pageNum=1" "$tok"); rc=$?
  if [ $rc -eq 0 ] && echo "$resp" | "$BB" grep -q '"records"'; then
    if [ "$KA_OK_DATE" != "$("$BB" date +%Y-%m-%d)" ]; then
      KA_OK_DATE=$("$BB" date +%Y-%m-%d)
      log "保活正常: token 有效"
    fi
    return 0
  fi
  # 调用未成功：可能 token 已失效，也可能只是网络异常（busybox wget 不输出错误正文，无法区分）
  if screen_is_on; then
    log "保活: 调用未成功，屏幕亮着，稍后再试"
    return 0
  fi
  now2=$("$BB" date +%s)
  if [ $((now2 - KA_LAST_REFRESH)) -lt 1800 ]; then
    return 0
  fi
  KA_LAST_REFRESH=$now2
  log "保活: 调用未成功，尝试静默刷新"
  newt=$(refresh_token "$tok" 0)
  if [ -n "$newt" ] && [ "$newt" != "$tok" ]; then
    log "保活: 静默刷新成功 $newt"
  else
    log "保活: 静默刷新未成功（可能网络不可用）"
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
  # 旧脚本提示
  if [ -f /data/adb/service.d/fafu_checkin.sh ]; then
    echo "提示: 检测到旧独立脚本 /data/adb/service.d/fafu_checkin.sh，建议删除"
  fi
  # token 状态
  tok=$(get_token)
  if [ -z "$tok" ]; then
    echo "token: 未找到（应用未安装或未登录过）"
  else
    resp=$(api "sign_in/student/my/page" "rows=1&pageNum=1" "$tok"); rc=$?
    if [ $rc -eq 0 ] && echo "$resp" | "$BB" grep -q '"records"'; then
      echo "token: 有效"
    else
      echo "token: 失效或网络异常"
    fi
  fi
  echo "最近日志:"
  "$BB" tail -n 6 "$LOG" 2>/dev/null
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

# ---- 子命令分发 ----
CMD="$1"
case "$CMD" in
  once)      run_once; exit $? ;;
  refresh)   cmd_refresh; exit 0 ;;
  keepalive) cmd_keepalive; exit 0 ;;
  status)    cmd_status; exit 0 ;;
  stop)      cmd_stop; exit 0 ;;
  start|"")  : ;;
  *)         echo "用法: sh $SELF [start|stop|status|once|refresh|keepalive]"; exit 1 ;;
esac

# ---- 启动守护进程（后台化 + 单实例） ----
if [ -z "$FAFU_DAEMON" ]; then
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

while true; do
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
