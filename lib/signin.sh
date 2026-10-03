# ============================================================
# signin 层 —— 签到决策：取任务、解析字段、判定该做什么、提交并记录
#
# 加载顺序：第 8 层（用 keepalive 的刷新流程处理失效 token）。
# 返回码契约（主循环据此决定动作，改这里会坏什么）：
#   0 = 已解决（签到成功 / 已签到 / 已请假）
#   1 = 可重试（不在时段、提交失败、任务信息不完整）→ 下一分钟再看
#   2 = 任务异常（无应用数据、取不到任务）→ 4 分钟后重试
# ============================================================

state_text() { # $1=signState 数值 → 自解释的中文（日志与通知都不该让读者去查状态码表）
  case "$1" in
    1) echo "已签到" ;;
    2) echo "已请假" ;;
    *) echo "未知状态($1)" ;;
  esac
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
      notify_once failtask
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
    if [ "$(sign_get sign_date)" != "$(today)" ]; then
      stime=""
      sst=$(echo "$resp" | "$BB" grep -o '"signTime":[0-9]*' | "$BB" head -n 1 | "$BB" cut -d: -f2)
      case "$sst" in
        ""|*[!0-9]*) : ;;
        *) stime=$("$BB" date -d "@$((sst / 1000))" +%H:%M 2>/dev/null) ;;
      esac
      if [ "$state" = "2" ]; then
        sign_set "$(today)" "" "leave"
      else
        sign_set "$(today)" "$stime" "detected"
      fi
    fi
    update_desc
    # 检测到已签到 / 已请假 → 通知（每次检测到都发；同事件同 tag 覆盖，不会堆积）
    if [ "$state" = "2" ]; then
      notify_event leave
    else
      notify_event seen
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
    td=$(today); hm=$(now_hm)
    if [ -n "$et" ] && [ "$now" -gt "$et" ]; then
      log "✅ 补签成功 [$name]"
      sign_set "$td" "$hm" "supplement"
      notify_event supp
    else
      log "✅ 签到成功 [$name]"
      sign_set "$td" "$hm" "normal"
      notify_event sign
    fi
    update_desc
    return 0
  fi
  # 签到提交失败：当日仅首次通知（之后的重试只写日志，避免刷屏）
  log "签到失败: rc=$rc $(echo "$resp2" | "$BB" head -c 120)"
  notify_once failsign
  return 1
}
