# ============================================================
# state 层 —— 运行时状态：服务开关、签到记录、保活统计、完成标记、通知标记、冷却基准
#
# 加载顺序：第 3 层。本层是模块目录内运行时文件的**唯一归属地**：其余层与入口只经
# 这里的函数访问，不自己读写这些文件。
# 对外提供：svc_is_disabled / svc_set、sign_get / sign_set、signin_resolved_today、
#   ka_counts / ka_ok_count / ka_fail_count / ka_last_time / ka_last_result / ka_is_today /
#   ka_note、done_marked / done_mark、notify_marked / notify_mark、nt_cooldown。
# 契约：文件名、字段名、字段顺序与内容格式对使用者可见——升级后不丢当日记录，不要改。
# 「按日滚动」的三处判定（保活统计、完成标记、通知的「一日一次」）都只在本层发生。
# ============================================================

STATE="$MODDIR/fafu-checkin.state"       # 服务开关（enabled / disabled）
STATUS="$MODDIR/fafu_checkin.status"     # 最近签到记录（动态描述用）
KASTAT="$MODDIR/fafu_keepalive.status"   # 保活统计（今日成功/失败、最近 token）
DONE="$MODDIR/.fafu_checkin_done"        # 当日签到完成标记
# 三个未签时点各自独立标记：共用标记会让先到的那个时点把后面的永久挡住
NFAIL="$MODDIR/.fafu_notify_fail"        # 当日「失败类通知」已发标记
NNOSIGN="$MODDIR/.fafu_notify_nosign"    # 22:00 未签提醒已发标记
NLATE="$MODDIR/.fafu_notify_late"        # 22:30 窗口切换提醒已发标记
NMISS="$MODDIR/.fafu_notify_miss"        # 23:00 最终未签提醒已发标记
NTLAST="$MODDIR/.fafu_notify_last"       # 打扰型通知的冷却基准（unix 秒）

# 事件名 → 标记文件。文件名与上面逐个对应，不要改（改了等于当天提醒重来一遍）。
# 事件名由调用方以字面量传入（notify_once 的四种事件），写错等于该类提醒静默失效。
_state_mark() { # $1=事件名 → 输出该事件的标记文件路径（未知事件输出空）
  case "$1" in
    fail) printf '%s' "$NFAIL" ;;
    nosign) printf '%s' "$NNOSIGN" ;;
    late) printf '%s' "$NLATE" ;;
    miss) printf '%s' "$NMISS" ;;
  esac
}

# 当日标记的通用判定：文件内容等于今天即视为「今天已经处理过」。
# 以 [ -f ] 为前置条件（文件不存在时内容读取为空，空 = 未标记，两者等价）。
_state_dated() { # $1=标记文件
  [ -f "$1" ] || return 1
  [ "$("$BB" cat "$1" 2>/dev/null)" = "$(today)" ]
}

# ---- 服务开关 ----
svc_is_disabled() {
  [ -f "$STATE" ] || return 1
  [ "$("$BB" cat "$STATE" 2>/dev/null)" = "disabled" ]
}

svc_set() { # $1=enabled|disabled
  # 用原子写：开关是「停用 = 不再有任何网络请求」的唯一依据，宁可保持旧值，
  # 也不要留下半截内容被读成「启用」
  printf '%s\n' "$1" | write_atomic "$STATE"
}

# ---- 签到记录（用于动态描述） ----
sign_get() { # $1=键名（sign_date / sign_time / sign_kind）
  kv_get "$STATUS" "$1"
}

sign_set() { # $1=日期 $2=时间(可空) $3=类型(normal/supplement/detected/leave)
  printf 'sign_date=%s\nsign_time=%s\nsign_kind=%s\n' "$1" "$2" "$3" | write_atomic "$STATUS"
}

# ---- 保活统计（记录每次保活结果，供日志与 status 查询） ----
# 对外只有语义读数：统计文件里有哪几个键是本层的实现细节，调用方不该知道。
_ka_get() { # $1=键名（date / ok / fail / last / last_result / token）
  kv_get "$KASTAT" "$1"
}

ka_counts() { # 输出「成功数 失败数」（都是今天的数）；跨日后归零（不写文件，仅读数）
  local d ok fail
  d=$(_ka_get date); ok=$(_ka_get ok); fail=$(_ka_get fail)
  if [ "$d" != "$(today)" ]; then ok=0; fail=0; fi
  printf '%s %s' "${ok:-0}" "${fail:-0}"
}

ka_ok_count() { set -- $(ka_counts); printf '%s' "$1"; }   # 今日成功数
ka_fail_count() { set -- $(ka_counts); printf '%s' "$2"; } # 今日失败数

# 最近一次保活：时间与结果各自为空时表示「还没有任何记录」
ka_last_time()   { _ka_get last; }         # 2026-10-03 21:30:14
ka_last_result() { _ka_get last_result; }  # ok / fail
ka_is_today() {                            # 最近一次记录是否属于今天
  [ "$(_ka_get date)" = "$(today)" ]
}

ka_note() { # $1=ok|fail；$2=本次使用的 token（可选，省略则沿用统计文件里的）
  local t ok fail tk
  t=$(today)
  ok=$(_ka_get ok); fail=$(_ka_get fail)
  [ "$(_ka_get date)" = "$t" ] || { ok=0; fail=0; }
  ok=${ok:-0}; fail=${fail:-0}
  case "$1" in
    ok)   ok=$((ok + 1)) ;;
    fail) fail=$((fail + 1)) ;;
  esac
  tk="${2:-$(_ka_get token)}"
  kv_set "$KASTAT" date "$t" ok "$ok" fail "$fail" last "$(now_full)" last_result "$1" token "$tk"
}

# ---- 当日是否已解决（主循环据此停止当日轮询） ----
# 「办完了」的四种类型：签到成功 / 补签成功 / 检测到已在 App 内签到 / 今日请假。
# 判据落在签到记录本身（今天的记录 + 白名单类型），不另立状态文件：
# 记录已经是当日状态的唯一真源，多一份标记就多一处会不同步的地方。
signin_resolved_today() {
  [ "$(sign_get sign_date)" = "$(today)" ] || return 1
  case "$(sign_get sign_kind)" in
    normal|supplement|detected|leave) return 0 ;;
  esac
  return 1
}

# ---- 当日签到完成标记（主循环在 run_once 返回 0 的那一轮写下它） ----
done_marked() { # 今天已完成签到
  _state_dated "$DONE"
}

done_mark() { # 记为今天已完成（只写日期，与旧格式一致）
  today | write_atomic "$DONE"
}

# ---- 通知标记 ----
notify_marked() { # $1=事件名：今天已发过该通知（发送失败不得落标记，否则整天不再提醒）
  local f
  f=$(_state_mark "$1")
  [ -n "$f" ] || return 1
  _state_dated "$f"
}

notify_mark() { # $1=事件名：记为今天已发（仅在真的发送成功之后调用）
  local f
  f=$(_state_mark "$1")
  [ -n "$f" ] || return 1
  printf '%s\n' "$(today)" | write_atomic "$f"
}

nt_cooldown() { # 无参=读冷却基准（unix 秒，缺失为 0）；$1=写入新的基准
  if [ $# -eq 0 ]; then
    local v
    v=$("$BB" cat "$NTLAST" 2>/dev/null | "$BB" tr -dc '0-9')
    printf '%s' "${v:-0}"
  else
    printf '%s\n' "$1" | write_atomic "$NTLAST"
  fi
}
