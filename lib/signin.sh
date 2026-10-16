# ============================================================
# signin 层 —— 签到决策：取任务 / 解析任务字段 / 判定该做什么 / 提交并记录 / 到期提醒
#
# 加载顺序：第 9 层（用 keepalive 的刷新流程处理失效 token）。
# 三档返回码是主循环的动作依据：
#   0 = 已解决（签到成功 / 已签到 / 已请假）→ 主循环写当日完成标记
#   1 = 可重试（不在时段、提交失败、任务信息不完整）→ 下一分钟再看
#   2 = 任务异常（无应用数据、取不到任务）→ 4 分钟后重试
# 提醒也在这里：三条截止提醒按任务数据推算，判定是纯函数（取数与发送分开）；
# 「任务未发布」那条兜底挂本地时钟，与轮询窗口无关。
# 配置与注入点：等待经 SLEEP_OVERRIDE 替身口（见 _sg_sleep）；兜底时刻读配置层的轮询范围止。
# ============================================================

state_text() { # $1=signState 数值或记录里的类型（sign_kind）→ 自解释的中文（日志、通知与状态输出都不该让读者去查状态码表）
  case "$1" in
    1|normal|supplement|detected) echo "已签到" ;;
    2|leave) echo "已请假" ;;
    *) echo "未知状态($1)" ;;
  esac
}

# ---- 等 App 数据就绪（只在「目录不在」这一处触发，正常情况零开销） ----
# 重启头几秒数据目录可能还不可读，干等下一轮（4 分钟）太浪费；等不到仍返回 2，
# 由主循环的 4 分钟接手（App 没装时这里必定等满）。次数与间隔是这里的实现细节，不进配置文件。
LD_WAIT_COUNT=10     # 最多重试几次
LD_WAIT_SEC=3        # 每次间隔（秒）→ 上限 30 秒
# 本层所有等待都经这一个替身口：SLEEP_OVERRIDE 非空时用 sh 显式跑它（不依赖替身文件的
# 执行位），默认走真 sleep。等 App 数据与短重试共用这一处，不各写一份。
_sg_sleep() { # $1=秒数
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
    _sg_sleep "$LD_WAIT_SEC"
    i=$((i + 1))
    if [ -d "$LD" ]; then
      log "应用数据已就绪（等了 $((i * LD_WAIT_SEC)) 秒）"
      return 0
    fi
  done
  return 1
}

# 日志行里 params= 那一格的来源；两处 api 调用点各自写的同值字面量，不读它。
SG_QUERY='rows=3&pageNum=1'

# 查询失败那一行：rc + api 层落下的那行事实（原样转交，本层不自己拼 http= / body=）
# + 查询参数 + 本层才拿得到的正文 —— 于是「调用失败」与「应答了却没有任务列表」分得开：
# 后一档的正文（响应里没有 records）只有本层手里有，故自己压平带上。
_sg_fetch_fail() { # $1=事件名 $2=rc $3=响应体
  local line
  line="$1: rc=$2 $(_api_err1 "$API_ERRLOG") params=$SG_QUERY"
  case "$2" in
    0) line="$line $(_api_field resp "$3")" ;;
  esac
  log "$line"
}

# 取任务：输出**两行**（第 1 行本次使用的 token、第 2 行响应体）。token 必须一起交出去：
# 查询异常时本函数会刷新它，随后提交要用刷新后的那一个，单独再取一次是另一条时间线。
# 无应用数据返回 2；查询异常时刷新 token 后重试一次，仍失败则通知并返回 2。
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
  # 判据写成「先取出布尔值再判」：`! echo ... | grep -q ...` 在这条 busybox ash 链路上会判反。
  resp=$(api "sign_in/student/my/page" "rows=3&pageNum=1" "$tok"); rc=$?
  case "$resp" in
    *'"records"'*) fail=0 ;;
    *) fail=1 ;;
  esac
  if [ "$fail" = "1" ] || [ "$rc" != "0" ]; then
    # 这两种失败修法不同、而一天只有一次现场：各自都要留全。
    _sg_fetch_fail "查询异常" "$rc" "$resp"
    newt=$(refresh_token "$tok" 1 "签到查询失败"); [ -n "$newt" ] && tok="$newt"
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

# 日志行上并排「服务端认为现在几点」（响应头里的 Date）的那一小段，由 api 层的只读
# 访问器给出（本层不自己拼 hdr=，格式只有一个真源）；拿不到时输出空，行尾不留空段。
_sg_hdrs() {
  local h
  h=$(_api_hdrs)
  [ -n "$h" ] && printf ' %s' "$h"
  return 0
}

# 任务四元组（任务号 / 签到状态 / 开始 / 截止）任一变了才记一行：正常轮询每分钟一轮
# 而数据几乎不变，每轮都记会让几百行日志没有一行提供信息；第一次拿到任务也算变化。
# 快照本身归 state 层管并按日滚动，故跨日后同样的任务又算「新任务」而不是「无变化」。
_sg_task_note() { # $1=任务号 $2=签到状态 $3=开始（毫秒） $4=截止（毫秒）
  local oid ost ob od
  oid=$(task_snap_get id); ost=$(task_snap_get state)
  ob=$(task_snap_get begin); od=$(task_snap_get dline)
  if [ "$oid" != "$1" ] || [ "$ost" != "$2" ] || [ "$ob" != "$3" ] || [ "$od" != "$4" ]; then
    # 末尾并排这一次查询的响应头：任务是何时出现的，与服务端认为现在几点同处一行
    log "任务变化: id=$oid→$1 state=$ost→$2 begin=$ob→$3 截止=$od→$4$(_sg_hdrs)"
    task_snap_set "$1" "$2" "$3" "$4"
  fi
}

# 解析任务字段：$1=响应体，$2..$7=调用方先 local 好的输出名（任务号 / 名称 / 状态 / 开始 /
# 截止 / 主窗口截止）；四个必需字段（任务号 / 状态 / 开始 / 截止）缺一返回 1，取法只有一处。
# 层内名一律 _sg_ 前缀：与输出变量同名会被 local 影子化，eval 写回的就是自己（判定拿到空状态）。
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

# 判定该做什么：$1=响应体 $2=本次使用的 token $3..$8=signin_parse 写好的字段；返回码见文件头。
# 判定顺序（改这里会坏什么）——① 状态非 0 且截止在 6 小时内：记录 + 通知 + 刷新描述，返回 0；
# ② 当前时间不在开始~截止之间：不在时段，返回 1；③ 其余：signin_submit 提交并记录，返回它的返回码。
signin_decide() { # $1=响应体 $2=token $3=任务号 $4=名称 $5=状态 $6=开始 $7=截止 $8=主窗口截止
  local resp token now rid name state bt dline et lng lat stime sst salt
  resp="$1"; token="$2"
  rid="$3"; name="$4"; state="$5"; bt="$6"; dline="$7"; et="$8"
  now=$(( $(now_s) * 1000 ))

  if [ "$state" != "0" ] && [ $(( now - dline )) -lt 21600000 ]; then
    log "[$name] $(state_text "$state")"
    if [ "$(sign_get sign_date)" != "$(today)" ]; then
      stime=""; salt=""
      sst=$(json_first "$resp" signTime)
      case "$sst" in
        ""|*[!0-9]*) : ;;   # 戳不可用（如请假记录本就没有签到时刻）：两个换算位都留空
        *)
          # 换算走 base 的纯算术（ms_to_hm），**不用 `date -d @`**：设备上那条路给错值
          # （真机 2026-10-13 探针：同一个戳给 17:09 / 09:09，正确值是 21:32 / 13:32）。
          # 两个换算位：本地 = 叠本机偏移；alt = 叠 0（即 UTC 视角）。
          stime=$(ms_to_hm "$sst" "$(tz_offset_s)")
          salt=$(ms_to_hm "$sst")
          ;;
      esac
      if [ "$state" = "2" ]; then
        sign_set "$(today)" "" "leave"
      else
        sign_set "$(today)" "$stime" "detected"
      fi
      log "时间核对: signTime=[$sst] → sign_time=[$stime] now=[$(now_full)] TZ=[${TZ:-未设}/$(tz_offset)] LDP=[${LD_LIBRARY_PATH:-未设}] alt=[$salt] $(_api_field 记录 "$resp")$(_sg_hdrs)"
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

  if [ "$now" -lt "$bt" ] || [ "$now" -gt "$dline" ]; then
    # 窗口内还没到时刻时每 60 秒重复一行、内容不变：按档位判据（频率 × 信息量）降级到
    # 调试档。文案一个字都不改——档位只决定写不写，不决定写什么。
    logd "[$name] 不在签到时段"; return 1
  fi

  # 定位参数按优先级取真值：① signInStudent 里的坐标（服务端记的就是这一对）
  # ② 任务顶层 lng/lat（只在不是 null 时才可用）③ 内置坐标兜底。
  # 取法见 _json_coord：取**最后一次**出现的合法数值，null / 空 / 非数值都当没取到。
  lng=$(_json_coord "$resp" lng)
  lat=$(_json_coord "$resp" lat)
  [ -n "$lng" ] || lng=119.243462
  [ -n "$lat" ] || lat=26.088417

  signin_submit "$rid" "$name" "$dline" "$et" "$lng" "$lat" "$now" "$token"
}

# ---- 失败原因留痕：借用 api 层落好的那份（本层不自己收 stderr） ----
# 提交失败时唯一能定性的一句话（HTTP 状态码 / 连接失败 / 超时）来自 api 层落好的那行诊断，
# 不把它写进日志，失败就只剩一个退出码。

# ---- 提交后的短重试 ----
# 窗口刚开的那几分钟服务端还没开始收（同一分钟内手动提交却能成功），等十几秒再试往往就过了。
# 只在**提交失败**后短等重来：「不在时段」那一档走不到这里，不会把窗口没开时的轮询催成高频。
# 次数与间隔是本层实现细节，不进配置文件；等待走 _sg_sleep 的替身口。
SG_RETRY_TIMES=2     # 提交失败后再试的次数
SG_RETRY_WAIT=15     # 每次之间等多久（秒）

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

# 一次提交尝试的痕迹：第几次 + 发出去的参数 + api 层那一行事实（原样转交，
# 本层不自己拼 http=/body=/hdr=/耗时=，格式只有一个真源）。
# **成功与失败同一形状**：两行逐字摆在一起就能看出差在哪；判定与返回码不看这几行。
_sg_try_log() { # $1=第几次 $2=任务号 $3=经度 $4=纬度
  log "提交尝试: try=$1 rid=$2 lng=$3 lat=$4 $(_api_err1 "$API_ERRLOG")"
}

# 提交并记录：$1=任务号 $2=名称 $3=补签截止 $4=主窗口截止 $5=经度 $6=纬度 $7=当前时间(毫秒)
# $8=token。提交失败当日仅首次通知（之后的重试只写日志），返回 1；
# 成功按「主窗口截止早于当前时间」区分主窗口签到与补签，返回 0。
signin_submit() {
  local rid name dline et lng lat now token resp rc newt td hm faildiag submit_facts retries attempt
  rid="$1"; name="$2"; dline="$3"; et="$4"
  lng="$5"; lat="$6"; now="$7"; token="$8"
  # ---- 首次提交（失败先刷新 token 再试一次：老 token 失效是常见档）----
  # 记痕排在**每次调用之后**：最后一次失败的尝试也有自己那一行，不靠末尾汇总代表它。
  attempt=1
  resp=$(api "sign_in/$rid/student/sign" "lng=$lng&lat=$lat" "$token"); rc=$?
  _sg_try_log "$attempt" "$rid" "$lng" "$lat"
  if [ "$rc" != "0" ]; then
    # 刷新那一行要说明触发原因：日志里出现刷新时，读的人得知道是谁触发的
    newt=$(refresh_token "$token" 1 "签到提交失败"); [ -n "$newt" ] && token="$newt"
    attempt=2
    resp=$(api "sign_in/$rid/student/sign" "lng=$lng&lat=$lat" "$token"); rc=$?
    _sg_try_log "$attempt" "$rid" "$lng" "$lat"
  fi
  # ---- 短重试 ----
  # 只在**确实提交失败**时重来：「不在时段」根本到不了这里，故不会把窗口外的轮询催成高频。
  retries=0
  while ! _sg_submit_ok "$rc" "$resp" && [ "$retries" -lt "$SG_RETRY_TIMES" ]; do
    retries=$((retries + 1))
    _sg_sleep "$SG_RETRY_WAIT"
    attempt=$((attempt + 1))
    resp=$(api "sign_in/$rid/student/sign" "lng=$lng&lat=$lat" "$token"); rc=$?
    _sg_try_log "$attempt" "$rid" "$lng" "$lat"
  done
  if _sg_submit_ok "$rc" "$resp"; then
    td=$(today); hm=$(now_hm)
    if [ "$retries" -gt 0 ]; then
      log "提交重试 $retries 次后成功 [$name]"
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
  # 末尾那行汇总把「发出去的参数」「试了几次」一次记全；服务端原文原样转交 api 层那一行。
  # 字段名 `try=` / `tries=` 是对外契约（日志的读法），故与内部变量名不同名。
  faildiag=$(_api_err1 "$API_ERRLOG")
  submit_facts="rid=$rid lng=$lng lat=$lat try=$attempt tries=$retries"
  log "签到失败: rc=$rc $submit_facts $faildiag"
  notify_once failsign
  return 1
}

# ---- 三条截止提醒：判定是纯函数，与取数、发送分开 ----

# 到点未办完：当前时刻落在 [锚点, 锚点+窗口) 之内 → 返回 0。
# 窗口是「这一档还成立」的时长——过了它再喊上一档的文案就是假话（三档锚点会同时满足）。
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
# 通知层只给标题；正文先拼成普通变量再赋给 _NT_TEXT——notify() 把它交给 su 派生的子
# shell 展开，正文里出现引号或命令替换会让引号失配：空正文发出去、rc 却仍是 0。
# 发一次就够：复用 notify_once 的「当日一次」标记，事件名与标记文件都不新建。
signin_remind_deadlines() { # $1=补签截止毫秒 $2=主窗口截止毫秒 $3=当前毫秒
  local dline et now t_close t_due t_sup t_lead off
  dline="$1"; et="$2"; now="$3"
  case "$dline$et$now" in ''|*[!0-9]*) return 0 ;; esac
  signin_resolved_today && return 0     # 当日已解决 → 一条都不发
  # 时区偏移判不出来（本机连时间源都拿不到）时，文案里的钟点算不出真值。此时**宁可不发**：
  # `signin_ms_hm` 会给空，拼出来就是「主窗口  关闭」这种缺了钟点的假话。
  off=$(tz_offset_s)
  [ -n "$off" ] || return 0
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

# 毫秒时间戳 → HH:MM（**本地钟点**，文案里给用户看的那个）：任务数据的钟点只在提醒文案
# 与状态里出现，换算只有这一处，缺值输出空（调用方据此不写钟点，而不是写假的 00:00）。
# 走 base 的纯算术 ms_to_hm + 本机偏移，**不用 `date -d @`——设备上那条路给错值**。
signin_ms_hm() { # $1=毫秒时间戳
  case "$1" in ''|*[!0-9]*) return 0 ;; esac
  ms_to_hm "$1" "$(tz_offset_s)"
}

# ---- 「任务未发布」兜底提醒：挂本地时钟，与轮询窗口无关 ----
# 数据驱动的三条在任务根本没发布时永远不会响，这条是唯一能覆盖它的东西。
# 目标时刻 = min(轮询范围止, 23:00)。
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
# signin_fetch 交回两行（token + 响应体）：token 必须一路传到提交，否则提交会带着空 token 发出去。
run_once() {
  local out rc tok resp rid name state bt dline et now_ms
  out=$(signin_fetch "$(get_token)"); rc=$?
  [ $rc -eq 0 ] || return $rc
  tok=$(printf '%s\n' "$out" | "$BB" head -n 1)
  resp=$(printf '%s\n' "$out" | "$BB" tail -n 1)
  signin_parse "$resp" rid name state bt dline et || return $?
  _sg_task_note "$rid" "$state" "$bt" "$dline"
  task_seen_mark    # 真的拿到了任务：兜底提醒据此不再打扰（任务没发布是另一回事）
  now_ms=$(( $(now_s) * 1000 ))
  signin_decide "$resp" "$tok" "$rid" "$name" "$state" "$bt" "$dline" "$et"; rc=$?
  # 提醒排在判定之后：这一轮要是签上了，当日状态已经变成已解决，提醒自然不再发
  signin_remind_deadlines "$dline" "$et" "$now_ms"
  return $rc
}
