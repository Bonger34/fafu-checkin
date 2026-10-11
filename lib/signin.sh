# ============================================================
# signin 层 —— 签到决策：取任务 / 解析任务字段 / 判定该做什么 / 提交并记录 / 到期提醒
#
# 加载顺序：第 9 层（用 keepalive 的刷新流程处理失效 token）。
# 对外提供：run_once（主循环与 once 子命令都调它）、state_text。
# 提醒也在这里：三条截止提醒按任务数据推算（signin_remind_deadlines），
# 「任务未发布」兜底挂本地时钟（signin_remind_notask）；判定是纯函数，取数与发送分开。
# 提交失败：每次尝试各留一行（第几次 + 发出去的参数 + api 层那一行事实），并短重试
# SG_RETRY_TIMES 次、每次隔 SG_RETRY_WAIT 秒（窗口刚开时服务端常还没开始收）。
# 三档返回码是主循环的动作依据，改这里会坏什么：
#   0 = 已解决（签到成功 / 已签到 / 已请假）→ 主循环写当日完成标记
#   1 = 可重试（不在时段、提交失败、任务信息不完整）→ 下一分钟再看
#   2 = 任务异常（无应用数据、取不到任务）→ 4 分钟后重试
# ============================================================

state_text() { # $1=signState 数值或记录里的类型（sign_kind）→ 自解释的中文（日志、通知与状态输出都不该让读者去查状态码表）
  case "$1" in
    1|normal|supplement|detected) echo "已签到" ;;
    2|leave) echo "已请假" ;;
    *) echo "未知状态($1)" ;;
  esac
}

# ---- 等 App 数据就绪（只在「目录不在」这一处触发，正常情况零开销） ----
# 重启后的头几秒，App 的数据目录可能还不可访问（凭证加密存储尚未就绪），而守护进程
# 那时可能已经完成启动并开始取任务了。此时干等下一轮（4 分钟）太浪费，代价也真实：
# 在轮询范围内会白跑好几次。故先短等一会儿再判——等到了就接着走，等不到仍按任务异常返回 2，
# 由主循环的 4 分钟兜底接手（那道兜底不能少：App 没装时这里必定等满）。
# 常量集中在文件头：等待次数与间隔是这里的实现细节，不进配置文件。
LD_WAIT_COUNT=10     # 最多重试几次
LD_WAIT_SEC=3        # 每次间隔（秒）→ 上限 30 秒
# 等待时实际调用的命令：默认是真 sleep。测试注入替身时用 sh 显式跑它——
# 那不依赖替身文件有没有执行位，断言就不必去 chmod。
_sg_wait_sleep() { # $1=秒数
  if [ -n "${SLEEP_OVERRIDE:-}" ]; then
    sh "$SLEEP_OVERRIDE" "$1"
  else
    sleep "$1"
  fi
}

_sg_wait_ld() { # 等到 $LD 可读为止；等到返回 0，等满返回 1
  local i
  [ -d "$LD" ] && return 0
  log "应用数据暂不可读（重启后就绪前的瞬时状态？），最多等 $((LD_WAIT_COUNT * LD_WAIT_SEC)) 秒"
  i=0
  while [ "$i" -lt "$LD_WAIT_COUNT" ]; do
    _sg_wait_sleep "$LD_WAIT_SEC"
    i=$((i + 1))
    if [ -d "$LD" ]; then
      log "应用数据已就绪（等了 $((i * LD_WAIT_SEC)) 秒）"
      return 0
    fi
  done
  return 1
}

# 查询参数：与下面两处 api 调用点同源（调用点是字面量，api 层的断言逐字钉着它）。
SG_QUERY='rows=3&pageNum=1'

# 查询失败那一行：rc + api 层落下的那一行事实（原样转交，本层不自己拼 http= / body=）
# + 查询参数，再加上本层才拿得到的正文。两种失败因此能分开：
#   ① 调用失败（rc≠0）：正文由 api 层落盘；
#   ② 应答了却没有任务列表（rc=0）：这一档的正文只有本层手里有，故自己压平带上。
_sg_fetch_fail() { # $1=事件名 $2=rc $3=响应体
  local line
  line="$1: rc=$2 $(_api_err1 "$API_ERRLOG") params=$SG_QUERY"
  case "$2" in
    0) line="$line resp=$(_api_flat "$3")" ;;
  esac
  log "$line"
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
    _sg_wait_ld || {
      # 文案说清「会重试」：写成「未安装或未登录」会把瞬时状态说成永久故障，排查时反而误导。
      log "未检测到应用数据（未安装、未登录，或重启后就绪前的瞬时状态）——稍后自动重试"
      return 2
    }
  fi
  # 查询异常：调用失败，或响应体里没有 records。判据写成「先取出布尔值再判」——
  # `! echo ... | grep -q ...` 在这条 busybox ash 链路上会判反。
  resp=$(api "sign_in/student/my/page" "rows=3&pageNum=1" "$tok"); rc=$?
  case "$resp" in
    *'"records"'*) fail=0 ;;
    *) fail=1 ;;
  esac
  if [ "$fail" = "1" ] || [ "$rc" != "0" ]; then
    # 查询失败也要留全：是「调用失败」还是「响应里没有 records」，两者的修法不同，
    # 而旧写法只记一个 rc，事后分不出（一天只有一次现场，值得多写这几个字节）。
    _sg_fetch_fail "查询异常" "$rc" "$resp"
    newt=$(refresh_token "$tok"); [ -n "$newt" ] && tok="$newt"
    resp=$(api "sign_in/student/my/page" "rows=3&pageNum=1" "$tok"); rc=$?
    case "$resp" in
      *'"records"'*) fail=0 ;;
      *) fail=1 ;;
    esac
    if [ "$fail" = "1" ] || [ "$rc" != "0" ]; then
      _sg_fetch_fail "获取任务失败" "$rc" "$resp"
      notify_once failtask
      return 2
    fi
  fi
  printf '%s\n%s' "$tok" "$resp"
}

# 任务四元组变了才记一行（第一次拿到任务也算变化，旧值为空）。
# 正常轮询每分钟一轮而任务数据几乎不变，每轮都记会让几百行日志里没有一行提供信息；
# 判据是**任务号 / 签到状态 / 开始 / 截止**任一与上一轮不同。快照本身归 state 层管
# 并按日滚动，故跨日后同样的任务又算「新任务」而不是「无变化」。
_sg_task_note() { # $1=任务号 $2=签到状态 $3=开始（毫秒） $4=截止（毫秒）
  local oid ost ob od
  oid=$(task_snap_get id); ost=$(task_snap_get state)
  ob=$(task_snap_get begin); od=$(task_snap_get dline)
  if [ "$oid" != "$1" ] || [ "$ost" != "$2" ] || [ "$ob" != "$3" ] || [ "$od" != "$4" ]; then
    log "任务变化: id=$oid→$1 state=$ost→$2 begin=$ob→$3 截止=$od→$4"
    task_snap_set "$1" "$2" "$3" "$4"
  fi
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
      # 时间核对：把「这一次换算用到的所有输入」一起记下来。
      # 只记 signTime 与结果不够——当两者对不上时，可能是时钟、时区、环境变量或
      # 取到的戳不对，四者都会给出同一个「对不上」的表象，故一并留下：
      # now=本机此刻（与日志行首时间戳必须一致）、TZ/LD_LIBRARY_PATH=换算时的环境、
      # 第二条 date 输出=另一种解释（对不上时能直接看出差在哪个偏移上）。
      # 末尾整条服务端记录（字段名以接口返回的为准，含签到时刻）：描述里的钟点若又不对，
      # 「服务端给了哪些字段、每个字段是什么」不必再靠推理。
      log "时间核对: signTime=[$sst] → sign_time=[$stime] now=[$(now_full)] TZ=[${TZ:-未设}] LDP=[${LD_LIBRARY_PATH:-未设}] alt=[$("$BB" date -u -d "@$((sst / 1000))" +%H:%M 2>/dev/null)] 记录=$(_api_flat "$resp")"
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

# ---- 失败原因留痕：借用 api 层落好的那份（本层不自己收 stderr） ----
# 提交失败时唯一能定性的一句话（HTTP 状态码 / 连接失败 / 超时）来自 wget 的报错正文，
# 由 api 层在失败时落进 API_ERRLOG 并转交。不把它写进日志，失败就只剩一个退出码。

# ---- 提交后的短重试 ----
# 依据是真机连续四天的记录：模块在 21:30~21:33 提交被拒，而同一分钟内手动提交就成功
# ——窗口刚开的那一小段里服务端还没开始收。主循环一分钟一轮，等于把这段窗口白丢。
# 只在**提交失败**后短等重来（「不在时段」那一档不走这里，否则窗口没开时会白催）。
# 等待次数与间隔是这里的实现细节，不进配置文件；sleep 走可注入替身（测试不真等）。
SG_RETRY_TIMES=2     # 提交失败后再试的次数
SG_RETRY_WAIT=15     # 每次之间等多久（秒）

_sg_retry_sleep() { # $1=秒数
  if [ -n "${SLEEP_OVERRIDE:-}" ]; then
    sh "$SLEEP_OVERRIDE" "$1"
  else
    sleep "$1"
  fi
}

# 提交成功的判据，首次与重试共用（复制成两份迟早分叉）：
# 调用成功，且响应体里**没有** timestamp（服务端用它报错）。用 case 而不是
# `[ ... ] && ! echo ... | grep -q ...`——后者在这条 busybox ash 链路上会判反。
_sg_submit_ok() { # $1=rc $2=响应体；成功返回 0
  [ "$1" = "0" ] || return 1
  case "$2" in
    *'"timestamp"'*) return 1 ;;
  esac
  return 0
}

# 一次提交尝试的痕迹：第几次、发出去的参数，后面接上 api 层那一行事实
# （状态码或连接层报错、完整正文、响应头白名单、耗时）。
# **成功与失败同一形状**——两行逐字摆在一起就能看出差在哪；判定与返回码不看这几行。
# api 层那一行原样转交，本层不自己拼 http=/body=/hdr=/耗时=（格式只有一个真源）。
_sg_try_log() { # $1=第几次 $2=任务号 $3=经度 $4=纬度
  log "提交尝试: try=$1 rid=$2 lng=$3 lat=$4 $(_api_err1 "$API_ERRLOG")"
}

# 提交并记录：$1=任务号 $2=名称 $3=补签截止 $4=主窗口截止 $5=经度 $6=纬度 $7=当前时间(毫秒)
# $8=token。提交失败当日仅首次通知（之后的重试只写日志），返回 1；
# 成功按「主窗口截止早于当前时间」区分主窗口签到与补签，返回 0。
signin_submit() {
  local rid name dline et lng lat now token resp rc newt td hm faildiag failwhat tries try
  rid="$1"; name="$2"; dline="$3"; et="$4"
  lng="$5"; lat="$6"; now="$7"; token="$8"
  # 提交成功 = 调用成功，且响应体里**没有** timestamp（服务端用它报错）。
  # 判定在 _sg_submit_ok 里（首次与重试共用一处，避免两处分叉）。
  # ---- 首次提交（失败先刷新 token 再试一次：老 token 失效是常见档）----
  # 记痕排在**每次调用之后**：于是最后一次失败的尝试也有自己的那一行，
  # 不必靠末尾那行汇总来代表它（汇总只补参数与次数）。
  try=1
  resp=$(api "sign_in/$rid/student/sign" "lng=$lng&lat=$lat" "$token"); rc=$?
  _sg_try_log "$try" "$rid" "$lng" "$lat"
  if [ "$rc" != "0" ]; then
    newt=$(refresh_token "$token"); [ -n "$newt" ] && token="$newt"
    try=2
    resp=$(api "sign_in/$rid/student/sign" "lng=$lng&lat=$lat" "$token"); rc=$?
    _sg_try_log "$try" "$rid" "$lng" "$lat"
  fi
  # ---- 短重试：窗口刚开时服务端常还没开始收，隔十几秒再试往往就过了 ----
  # 只在**确实提交失败**时重来；「不在时段」根本到不了这里，故不会把窗口外的
  # 轮询催成高频。次数与间隔都是常量，不进配置。
  tries=0
  while ! _sg_submit_ok "$rc" "$resp" && [ "$tries" -lt "$SG_RETRY_TIMES" ]; do
    tries=$((tries + 1))
    _sg_retry_sleep "$SG_RETRY_WAIT"
    try=$((try + 1))
    resp=$(api "sign_in/$rid/student/sign" "lng=$lng&lat=$lat" "$token"); rc=$?
    _sg_try_log "$try" "$rid" "$lng" "$lat"
  done
  if _sg_submit_ok "$rc" "$resp"; then
    td=$(today); hm=$(now_hm)
    if [ "$tries" -gt 0 ]; then
      log "提交重试 $tries 次后成功 [$name]"
    fi
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
  # 全部尝试都失败：末尾那行汇总仍把「发出去的参数」「试了几次」一次记全，
  # 服务端原文则原样转交 api 层那一行（它已含完整正文），这里不再另截一次。
  faildiag=$(_api_err1 "$API_ERRLOG")
  failwhat="rid=$rid lng=$lng lat=$lat try=$try tries=$tries"
  log "签到失败: rc=$rc $failwhat $faildiag"
  notify_once failsign
  return 1
}

# ---- 三条截止提醒：判定是纯函数（判定与取数分开，便于直接喂值断言） ----

# 到点未办完：当前时刻落在 [锚点, 锚点+窗口) 之内 → 返回 0。
# 窗口是「这一档还成立」的时长：过了它，时间线上已经换了下一档，再喊上一档的文案
# 就是假话（进程重启、轮询范围偏晚时，三档的锚点会同时满足）。
signin_remind_due() { # $1=锚点毫秒 $2=窗口毫秒 $3=当前毫秒
  local a w n
  a="$1"; w="$2"; n="$3"
  case "$a$w$n" in ''|*[!0-9]*) return 1 ;; esac
  [ "$w" -gt 0 ] || return 1
  [ "$n" -ge "$a" ] || return 1
  [ "$n" -lt $((a + w)) ]
}

# 预警提前量（分钟）：这一档的锚点相对主窗口截止往前挪多久，只有这一处说了算。
# 标题里那个「还剩 N 分钟」的 N 也由它推出来，避免同一个数在文案里再抄一份。
signin_remind_lead_min() { echo 30; }

# 主窗口截止前 `提前量` 那一档：锚点 = 主窗口截止往前挪提前量，窗口就是这一段。
signin_remind_30min() { # $1=主窗口截止毫秒 $2=当前毫秒
  local a lead
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  lead=$(signin_remind_lead_min)
  a=$(( $1 - lead * 60000 ))
  [ "$a" -gt 0 ] || return 1
  signin_remind_due "$a" $(( lead * 60000 )) "$2"
}

# ---- 三条截止提醒：正文由本层按任务数据拼好，经 _NT_TEXT 交给 notify 层 ----
#
# 通知层只给标题（模板里不再有任何钟点）；正文先拼成一个普通变量再赋给 _NT_TEXT——
# notify() 把它交给 su 派生的子 shell 展开，正文里出现引号或命令替换会让引号失配，
# 通知带着空正文发出去、rc 却仍是 0。
# 发一次就够：复用 notify_once 的「当日一次」标记，事件名与标记文件都不新建。
signin_remind_deadlines() { # $1=补签截止毫秒 $2=主窗口截止毫秒 $3=当前毫秒
  local dline et now t_close t_due t_sup t_lead
  dline="$1"; et="$2"; now="$3"
  case "$dline$et$now" in ''|*[!0-9]*) return 0 ;; esac
  signin_resolved_today && return 0     # 当日已解决 → 一条都不发
  # ① 主窗口还剩多少分钟：锚点就是主窗口截止，文案同时给出「连几点」与「几点关」。
  # 标题里那个数也由这里算出来（提前量是常量，写在标题里就成了会漂移的副本）。
  if signin_remind_30min "$et" "$now"; then
    t_lead=$(signin_remind_lead_min)
    t_due=$(signin_ms_hm $(( et - t_lead * 60000 )))
    t_close=$(signin_ms_hm "$et")
    _NT_LEAD_MIN="$t_lead"
    _NT_TEXT="$PL $t_due 还没签到，主窗口 $t_close 关闭；现在可在 App 内手动签到"
    notify_once nosign
  fi
  # ② 主窗口已过、进入补签：窗口就是补签时段本身（没有补签时段时不该喊「进入补签」）
  if signin_remind_due "$et" $(( dline - et )) "$now"; then
    t_close=$(signin_ms_hm "$et")
    _NT_TEXT="$PL $t_close 仍未签到，模块会继续自动重试，也可在 App 内手动补签"
    notify_once late
  fi
  # ③ 补签截止：最后一档，没有更晚的档来接管，故窗口给一天（当日去重保证只发一条）
  if signin_remind_due "$dline" 86400000 "$now"; then
    t_sup=$(signin_ms_hm "$dline")
    _NT_TEXT="$PL $t_sup 重试结束仍未签到，请手动处理"
    notify_once miss
  fi
  return 0
}

# 毫秒时间戳 → HH:MM：任务数据里的钟点只在文案里出现，换算只有这一处。
# 缺值输出空，调用方据此不写钟点（而不是写一个假的 00:00）。
signin_ms_hm() { # $1=毫秒时间戳
  case "$1" in ''|*[!0-9]*) return 0 ;; esac
  "$BB" date -d "@$(( $1 / 1000 ))" +%H:%M 2>/dev/null
}

# ---- 「任务未发布」兜底提醒：挂本地时钟，与轮询窗口无关 ----
# 数据驱动的三条在「任务根本没发布」时永远不会响，而那恰恰是最需要提醒的情形；
# 这条是唯一能覆盖它的东西。目标时刻 = min(轮询范围止, 23:00)，必然落在轮询范围内。
signin_notask_target() { # 输出兜底提醒的目标时刻 HH:MM
  local pe
  pe=$(cfg_poll_end)
  if [ "$(hm_minutes "$pe")" -gt "$(hm_minutes 23:00)" ]; then
    printf '%s' "23:00"
  else
    printf '%s' "$pe"
  fi
}

# 到点（>=）返回 0：时刻字符串零填充，字典序即时间序
signin_notask_due() { # $1=当前时刻 HH:MM
  case "$1" in [0-2][0-9]:[0-5][0-9]) : ;; *) return 1 ;; esac
  [ ! "$1" \< "$(signin_notask_target)" ]
}

# 到点且当日未取得任务 → 发一条（当日一次）。发送成功才落标记，故一次瞬时失败还能再试。
signin_remind_notask() { # $1=当前时刻 HH:MM
  signin_notask_due "$1" || return 0
  task_seen_marked && return 0
  _NT_TEXT="$PL 今晚还没查到查寝任务；若学校已发布，请手动打开 App 看一眼"
  notify_once nopub
}

# 一次完整检查（主循环与 once 子命令都调它）：取任务 → 解析字段 → 判定该做什么。
# signin_fetch 交回「本次使用的 token + 响应体」两行：token 必须一路传到提交，
# 否则提交会带着空 token 发出去。字段解析只做一次，结果直接交给判定。
run_once() {
  local out rc tok resp rid name state bt dline et now_ms
  out=$(signin_fetch "$(get_token)"); rc=$?
  [ $rc -eq 0 ] || return $rc
  tok=$(printf '%s\n' "$out" | "$BB" head -n 1)
  resp=$(printf '%s\n' "$out" | "$BB" tail -n 1)
  signin_parse "$resp" rid name state bt dline et || return $?
  # 任务四元组与上一轮不同才记一行（快照的读写都发生在拿到任务之后）
  _sg_task_note "$rid" "$state" "$bt" "$dline"
  task_seen_mark    # 真的拿到了任务：兜底提醒据此不再打扰（任务没发布是另一回事）
  now_ms=$(( $(now_s) * 1000 ))
  signin_decide "$resp" "$tok" "$rid" "$name" "$state" "$bt" "$dline" "$et"; rc=$?
  # 提醒排在判定之后：这一轮要是签上了，当日状态已经变成已解决，提醒自然不再发
  signin_remind_deadlines "$dline" "$et" "$now_ms"
  return $rc
}
