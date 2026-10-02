# ============================================================
# keepalive 层 —— 刷新 token 与白天保活
#
# 加载顺序：第 7 层（必须早于 signin：签到决策会调用 refresh_token）。
# 两条时序不变量（改这里会坏什么）：
#   1) 拿到新 token 就立刻移除打卡页，把前台尽早交还用户；
#      拿不到新 token 时不提前关页，保持与兜底唤醒一致的时序；
#   2) 保活场景禁止唤醒屏幕（[ 允许唤醒 ] = 0），避免白天吵醒用户。
# ============================================================

KEEPALIVE="${KEEPALIVE:-1}"   # 配置项：0 = 关闭白天保活（仅保留 21:30 自动签到）
KA_LAST=0                     # 保活节流基准（unix 秒）
KA_LAST_REFRESH=0             # 刷新冷却基准（unix 秒）

refresh_token() { # $1=旧token；$2=允许唤醒重试(1=是,0=否，默认1)；输出最新 token
  log "刷新 token（静默优先）"
  WAS_ON=0
  screen_is_on && WAS_ON=1
  # 开页预警：屏幕已亮时，本次确实会打开打卡页 → 先通知再开，别让页面毫无解释地跳出来。
  # （熄屏时不开预警：用户看不见，且静默开页本就不打扰。）
  # 冷却用于防突发：一次刷新失败可能连锁触发多次 refresh_token，避免连续弹同一条。
  if [ "${WAS_ON:-0}" = "1" ] && [ -n "$SU_MODE" ]; then
    now_ts=$("$BB" date +%s)
    _last=$("$BB" cat "$NTLAST" 2>/dev/null | "$BB" tr -dc '0-9')
    [ -n "$_last" ] || _last=0
    if [ $((now_ts - _last)) -ge "$NOTIFY_COOLDOWN" ]; then
      echo "$now_ts" > "$NTLAST" 2>/dev/null
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
  now_ts=$("$BB" date +%s)
  if [ $((now_ts - KA_LAST_REFRESH)) -lt 1800 ]; then
    log "保活: ❌ 调用失败 $tok (今日 $okc 成功 / $failc 失败) — 刷新冷却中，稍后再试"
    return 0
  fi
  KA_LAST_REFRESH=$now_ts
  log "保活: ⚠️ 调用失败 $tok (今日 $okc 成功 / $failc 失败) — 尝试静默刷新"
  newt=$(refresh_token "$tok" 0)
  if [ -n "$newt" ] && [ "$newt" != "$tok" ]; then
    log "保活: ✅ 静默刷新成功 $tok → $newt"
  else
    log "保活: ❌ 静默刷新未成功（可能网络不可用），token 仍为 $tok"
  fi
  return 0
}
