# ============================================================
# keepalive 层 —— 刷新 token 与白天保活
#
# 加载顺序：第 7 层（必须早于 signin：签到决策会调用刷新流程）。
# 刷新流程按三段组织（静默开页等 token → 唤醒后重试 → 收尾恢复屏幕与清理页面），
# 两条时序不变量跨段成立（改这里会坏什么）：
#   1) 拿到新 token 就立刻移除打卡页，把前台尽早交还用户；
#      拿不到新 token 时不提前关页，保持与兜底唤醒一致的时序；
#   2) 保活场景禁止唤醒屏幕（refresh_token 的第二参数传 0），避免白天吵醒用户。
# 保活策略（窗口 [07:00, 21:25]、15 分钟节流、失败后 30 分钟刷新冷却、亮屏延后）
# 都在本层；窗口与节流是两个判定（ka_in_window / ka_due），入口只按它们的结论分流。
# ============================================================

KEEPALIVE="${KEEPALIVE:-1}"   # 配置项：0 = 关闭白天保活（仅保留 21:30 自动签到）
KA_LAST=0                     # 节流基准（unix 秒；由入口在主循环里推进，见 ka_due）
KA_LAST_REFRESH=0             # 刷新冷却基准（unix 秒）

# ---- 保活时段与节流 ----
# 保活时段 07:00 ~ 21:25（**上界不含**：21:25 起就不再保活，与签到时段留出间隔）。
# 判据是「当日第几分钟」，与守护循环的 60 秒一跳对齐。
ka_in_window() {
  local m
  m=$(now_minutes)
  [ "$m" -ge 420 ] && [ "$m" -lt 1285 ]
}

# 节流：距上次保活不足 15 分钟就不再敲接口。$1=当前 unix 秒。
# 只读基准、不改它——调用方是守护主循环，赋值得发生在循环体那一层才留得住。
ka_due() { # $1=当前 unix 秒
  [ $(( ${1:-0} - KA_LAST )) -ge 900 ]
}

# ---- 刷新三段 ----
# 等新 token 的采样循环：拿到（与上次不同）就返回它，否则输出空。
# 采样次数是这层的实现细节，调用方只关心「新的，还是没有」。
_ka_poll() { # $1=旧token $2=采样次数上限 → 输出新 token（没有则空）
  local _rp _rn
  _rp=""
  _rn=0
  while [ "$_rn" -lt "${2:-10}" ]; do
    sleep 3
    _rp=$(get_token)
    [ -n "$_rp" ] && [ "$_rp" != "$1" ] && break
    _rn=$((_rn + 1))
  done
  [ "$_rp" != "$1" ] && printf '%s' "$_rp"
}

# 第一段：静默开页等 token（熄屏 / 锁屏下屏幕不亮）。
# 熄屏时不开预警（用户看不见，且静默开页本就不打扰）；屏幕已亮时先通知再开页，
# 别让页面毫无解释地跳出来。冷却、通知开关、降权是否可用都由 notify_warn 判定：
# 它返回 0 = 这次真的发了通知，才需要留出阅读时间（没发还等，等于每次亮屏刷新都白等 5 秒）。
# 本段在 $( ) 子 shell 里跑，故屏幕原状态取调用方设好的 WAS_ON。
refresh_silent() { # $1=旧token → 输出本段拿到的 token（没有则空）
  log "刷新 token（静默优先）"
  if [ "${WAS_ON:-0}" = "1" ] && notify_warn; then
    sleep "$(notify_lead)"   # 留出阅读时间；提前量由 NOTIFY_LEAD 配置，默认 5 秒
  fi
  open_page
  _ka_poll "$1" 10
}

# 第二段：唤醒屏幕后重试（静默轮询拿不到时走这里；保活场景由调用方传 0 禁止）。
# 屏幕本来就亮着的人不该再被敲一下唤醒键——那一下只在原本没亮时才发。
refresh_wake() { # $1=旧token → 输出本段拿到的 token（没有则空）
  log "静默刷新未成功，尝试唤醒屏幕重试"
  [ "$WAS_ON" = "1" ] || input keyevent 224 </dev/null >/dev/null 2>&1
  wm dismiss-keyguard </dev/null >/dev/null 2>&1
  _ka_poll "$1" 20
}

# 第三段：收尾——移除打卡页，并把屏幕恢复成刷新前的样子（原为关闭则恢复熄屏）。
refresh_finish() { # （只做收尾，不产出 token）
  close_page
  if [ "$WAS_ON" = "0" ]; then
    input keyevent 223 </dev/null >/dev/null 2>&1
    log "屏幕原为关闭，已恢复熄屏"
  else
    log "屏幕原本亮着，保持不熄屏"
  fi
}

# 一次完整刷新：静默开页等 token → 拿不到且允许唤醒时重试 → 收尾。输出最新 token。
refresh_token() { # $1=旧token；$2=允许唤醒重试(1=是,0=否，默认1)
  local t
  WAS_ON=0
  screen_is_on && WAS_ON=1
  t=$(refresh_silent "$1")
  # 一到手就把页面移出前台：前台会自动回到用户原来的 App，尽量缩短中断时间。
  # 拿不到新 token 时不提前关页，保持与原先一致的兜底时序（走完第二段再一起关）。
  if [ -n "$t" ] && [ "$t" != "$1" ]; then
    log "已取得新 token，提前移除打卡页（前台交还用户）"
    close_page
  fi
  if [ -z "$t" ] || [ "$t" = "$1" ]; then
    [ "${2:-1}" != "0" ] && t=$(refresh_wake "$1")
  fi
  if [ -n "$t" ] && [ "$t" != "$1" ]; then
    log "刷新成功: $1 → $t"
  else
    log "刷新未获得新 token（超时，仍为 $1）"
    t="$1"   # 收尾与返回都按「没有新 token」处理
  fi
  refresh_finish
  echo "$t"
}

# ---- 白天保活 ----
# 统计只经 state 层的语义读数（本层不碰状态文件格式）；一行日志里带上「成功 / 失败」
# 两个数，日志与 status 因此永远对得上同一份读数。
#
# 一行日志的不变量：printf 的实参必须与 %s 一一对应（缺参时 busybox 会把整行错位）。
#
# 刷新冷却基准是进程内变量：它在 $( ) 子 shell 里被推进，跨调用留不住（现状如此，
# 冷却以单次调用为界；要跨调用生效必须像通知冷却那样落盘，属另一件事）。
ka_stat() { # $1=记号 ✅/❌/⚠️ $2=token $3=说明 $4=补充（无补充传空串）
  printf '保活: %s %s %s (今日 %s 成功 / %s 失败)%s' \
    "$1" "$2" "$3" "$(ka_ok_count)" "$(ka_fail_count)" "$4"
}

keepalive_ping() {
  tok=$(get_token)
  [ -n "$tok" ] || return 0
  resp=$(api "sign_in/student/my/page" "rows=1&pageNum=1" "$tok"); rc=$?
  if [ $rc -eq 0 ] && echo "$resp" | "$BB" grep -q '"records"'; then
    ka_note ok "$tok"
    log "$(ka_stat ✅ "$tok" "token 有效" "")"
    return 0
  fi
  # 调用未成功：可能 token 已失效，也可能只是网络异常（busybox wget 不输出错误正文，无法区分）
  ka_note fail "$tok"
  # 屏幕亮着时延后刷新：避免白天出现无解释的页面弹出，留待熄屏（静默刷新）或签到时段处理
  if screen_is_on; then
    log "$(ka_stat ❌ "$tok" "调用失败" " — 屏幕亮着，延后（熄屏或签到时段自动刷新）")"
    return 0
  fi
  now_ts=$(now_s)
  if [ $((now_ts - KA_LAST_REFRESH)) -lt 1800 ]; then
    log "$(ka_stat ❌ "$tok" "调用失败" " — 刷新冷却中，稍后再试")"
    return 0
  fi
  KA_LAST_REFRESH=$now_ts
  log "$(ka_stat ⚠️ "$tok" "调用失败" " — 尝试静默刷新")"
  newt=$(refresh_token "$tok" 0)
  if [ -n "$newt" ] && [ "$newt" != "$tok" ]; then
    log "保活: ✅ 静默刷新成功 $tok → $newt"
  else
    log "保活: ❌ 静默刷新未成功（可能网络不可用），token 仍为 $tok"
  fi
  return 0
}
