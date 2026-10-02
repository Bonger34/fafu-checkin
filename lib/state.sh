# ============================================================
# state 层 —— 运行时状态：服务开关、签到记录、保活统计、完成标记、通知标记
#
# 加载顺序：第 2 层。本层是模块目录内运行时文件的归属地（其余层经本层的函数访问；
# 入口主循环里的完成标记判定会在状态层收敛时一并收口）。
# 文件名称、字段名与字段顺序都是对使用者可见的契约：升级后不丢当日记录，不要改。
# ============================================================

STATE="$MODDIR/fafu-checkin.state"       # 服务开关（enabled / disabled）
STATUS="$MODDIR/fafu_checkin.status"     # 最近签到记录（动态描述用）
KASTAT="$MODDIR/fafu_keepalive.status"   # 保活统计（今日成功/失败、最近 token）
DONE="$MODDIR/.fafu_checkin_done"        # 当日签到完成标记
# 三个未签时点各自独立标记：若共用标记，22:00 先发会让 22:30 / 23:00 永远发不出来，
# 而 23:00 那条「今晚未能自动签到」恰恰是本功能存在的理由
NFAIL="$MODDIR/.fafu_notify_fail"        # 当日「失败类通知」已发标记
NNOSIGN="$MODDIR/.fafu_notify_nosign"    # 22:00 未签提醒已发标记
NLATE="$MODDIR/.fafu_notify_late"        # 22:30 窗口切换提醒已发标记
NMISS="$MODDIR/.fafu_notify_miss"        # 23:00 最终未签提醒已发标记

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
  _today=$("$BB" date +%Y-%m-%d)
  d=$(ka_state_get date); ok=$(ka_state_get ok); fail=$(ka_state_get fail)
  [ "$d" = "$_today" ] || { ok=0; fail=0; }
  ok=${ok:-0}; fail=${fail:-0}
  case "$1" in
    ok)   ok=$((ok+1)) ;;
    fail) fail=$((fail+1)) ;;
  esac
  tk="${2:-$(ka_state_get token)}"
  printf 'date=%s\nok=%s\nfail=%s\nlast=%s\nlast_result=%s\ntoken=%s\n' \
    "$_today" "$ok" "$fail" "$("$BB" date '+%Y-%m-%d %H:%M:%S')" "$1" "$tk" > "$KASTAT"
}
