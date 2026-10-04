# ============================================================
# signin 层 —— 签到决策：取任务 / 解析任务字段 / 判定该做什么 / 提交并记录
#
# 加载顺序：第 8 层（用 keepalive 的刷新流程处理失效 token）。
# 对外提供：run_once（主循环与 once 子命令都调它）、state_text。
# 三档返回码是主循环的动作依据，改这里会坏什么：
#   0 = 已解决（签到成功 / 已签到 / 已请假）→ 主循环写当日完成标记
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

# 取任务：输出**两行** —— 第 1 行本次使用的 token、第 2 行响应体。
# token 必须一起交出去：查询异常时本函数会刷新 token，随后提交要用刷新后的那一个
# （单独再取一次是另一条时间线，会用到过期的 token）。无应用数据返回 2；
# 查询异常时刷新 token 后重试一次，仍失败则通知「拿不到任务」并返回 2。
signin_fetch() { # $1=token → stdout=<token>\n<响应体>；返回码见文件头
  local tok resp rc newt fail
  fail=0
  tok="$1"
  if [ ! -d "$LD" ]; then
    log "未检测到应用数据（未安装或未登录）"; return 2
  fi
  # 查询异常：调用失败，或响应体里没有 records。判据写成「先取出布尔值再判」——
  # `! echo ... | grep -q ...` 在这条 busybox ash 链路上会判反。
  resp=$(api "sign_in/student/my/page" "rows=3&pageNum=1" "$tok"); rc=$?
  case "$resp" in
    *'"records"'*) fail=0 ;;
    *) fail=1 ;;
  esac
  if [ "$fail" = "1" ] || [ "$rc" != "0" ]; then
    log "查询异常(rc=$rc)，尝试刷新 token"
    newt=$(refresh_token "$tok"); [ -n "$newt" ] && tok="$newt"
    resp=$(api "sign_in/student/my/page" "rows=3&pageNum=1" "$tok"); rc=$?
    case "$resp" in
      *'"records"'*) fail=0 ;;
      *) fail=1 ;;
    esac
    if [ "$fail" = "1" ] || [ "$rc" != "0" ]; then
      log "获取任务失败: rc=$rc $(echo "$resp" | "$BB" head -c 120)"
      notify_once failtask
      return 2
    fi
  fi
  printf '%s\n%s' "$tok" "$resp"
}

# 解析任务字段：$1=响应体。字段名由接口决定，取法只有一处（base 层的 json_first）。
# **输出走调用方声明的 local**（调用方必须先 local 这六个名字）：$2..$7 依次是
# 任务号 / 名称 / 状态 / 开始 / 截止 / 主窗口截止 —— 用 eval 写回是为了让「解析」这一步
# 真的被复用：否则声明了四个函数，调用方还是得自己再解析一遍。
# 本层内部一律用 _sg_ 前缀的局部名：**不能**叫 rid/state/…，那会和输出变量同名，
# local 一影子化，eval 写回的就是自己（表现为判定拿到空状态、一路走错分支）。
# 四个必需字段（任务号 / 状态 / 开始 / 截止）缺一个就返回 1，调用方据此走「可重试」；
# 「截止」取 supplementEndTime，缺失时回退 endTime（补签时段的判定基准）。
signin_parse() { # $1=响应体 $2..$7=输出变量名；信息不完整返回 1
  local _sg_rid _sg_state _sg_bt _sg_dline
  _sg_rid=$(json_first "$1" id)
  _sg_state=$(json_first "$1" signState)
  _sg_bt=$(json_first "$1" beginTime)
  _sg_dline=$(json_first "$1" supplementEndTime)
  [ -n "$_sg_dline" ] || _sg_dline=$(json_first "$1" endTime)
  if [ -z "$_sg_rid" ] || [ -z "$_sg_state" ] || [ -z "$_sg_bt" ] || [ -z "$_sg_dline" ]; then
    log "暂无有效任务（信息不完整）"; return 1
  fi
  eval "$2=\$_sg_rid"; eval "$3=\$(json_first \"\$1\" name)"
  eval "$4=\$_sg_state"; eval "$5=\$_sg_bt"; eval "$6=\$_sg_dline"
  eval "$7=\$(json_first \"\$1\" endTime)"
}

# 判定该做什么：$1=响应体 $2=本次使用的 token，$3..$8=signin_parse 写好的字段。返回码见文件头。
# 判定顺序（改这里会坏什么）：
#   ① 状态非 0 且截止在 6 小时内 → 已签到 / 已请假：记录 + 通知 + 刷新描述，返回 0
#   ② 当前时间不在开始~截止之间 → 不在时段，返回 1
#   ③ 其余（窗口内未签）→ signin_submit 提交并记录，返回它的返回码
signin_decide() { # $1=响应体 $2=token $3=任务号 $4=名称 $5=状态 $6=开始 $7=截止 $8=主窗口截止
  local resp token now rid name state bt dline et lng lat stime sst
  resp="$1"; token="$2"
  rid="$3"; name="$4"; state="$5"; bt="$6"; dline="$7"; et="$8"
  now=$(( $(now_s) * 1000 ))

  if [ "$state" != "0" ] && [ $(( now - dline )) -lt 21600000 ]; then
    log "[$name] $(state_text "$state")"
    # 记录检测到的签到信息（仅当今天尚无记录时）
    if [ "$(sign_get sign_date)" != "$(today)" ]; then
      stime=""
      sst=$(json_first "$resp" signTime)
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
  lng=$(json_first "$resp" lng)
  lat=$(json_first "$resp" lat)
  [ -n "$lng" ] || lng=119.243462
  [ -n "$lat" ] || lat=26.088417

  signin_submit "$rid" "$name" "$dline" "$et" "$lng" "$lat" "$now" "$token"
}

# 提交并记录：$1=任务号 $2=名称 $3=补签截止 $4=主窗口截止 $5=经度 $6=纬度 $7=当前时间(毫秒)
# $8=token。提交失败当日仅首次通知（之后的重试只写日志），返回 1；
# 成功按「主窗口截止早于当前时间」区分主窗口签到与补签，返回 0。
signin_submit() {
  local rid name dline et lng lat now token resp rc newt td hm ok
  rid="$1"; name="$2"; dline="$3"; et="$4"
  lng="$5"; lat="$6"; now="$7"; token="$8"
  resp=$(api "sign_in/$rid/student/sign" "lng=$lng&lat=$lat" "$token"); rc=$?
  if [ "$rc" != "0" ]; then
    newt=$(refresh_token "$token"); [ -n "$newt" ] && token="$newt"
    resp=$(api "sign_in/$rid/student/sign" "lng=$lng&lat=$lat" "$token"); rc=$?
  fi
  # 「提交成功」的判据：调用成功，且响应体里**没有** timestamp（服务端用它报错）。
  # 这里用 case 而不是 `[ $rc -eq 0 ] && ! echo "$resp" | grep -q ...`：后者在这条
  # busybox ash 链路上会把两档判反，而 case 的每个分支只有一个出口。
  ok=1
  if [ "$rc" = "0" ]; then
    case "$resp" in
      *'"timestamp"'*) : ;;
      *) ok=0 ;;
    esac
  fi
  if [ "$ok" = "0" ]; then
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
  log "签到失败: rc=$rc $(echo "$resp" | "$BB" head -c 120)"
  notify_once failsign
  return 1
}

# 一次完整检查（主循环与 once 子命令都调它）：取任务 → 解析字段 → 判定该做什么。
# signin_fetch 交回「本次使用的 token + 响应体」两行：token 必须一路传到提交，
# 否则提交会带着空 token 发出去。字段解析只做一次，结果直接交给判定。
run_once() {
  local out rc tok resp rid name state bt dline et
  out=$(signin_fetch "$(get_token)"); rc=$?
  [ $rc -eq 0 ] || return $rc
  tok=$(printf '%s\n' "$out" | "$BB" head -n 1)
  resp=$(printf '%s\n' "$out" | "$BB" tail -n 1)
  signin_parse "$resp" rid name state bt dline et || return $?
  signin_decide "$resp" "$tok" "$rid" "$name" "$state" "$bt" "$dline" "$et"
}
