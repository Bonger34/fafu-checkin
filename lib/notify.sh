# ============================================================
# notify 层 —— 通知：降权探测、文案表、发送、每日一次去重、打扰冷却
#
# 加载顺序：第 5 层。通知是纯增量能力：任何失败都不得影响签到主流程。
# 业务层只报**事件名**（sign / supp / seen / leave / failsign / failtask / nosign /
# late / miss），tag 与文案都由本层的两张表查出来；新增一条通知要动三处
# （事件表、tag 表、_msg_* 文案），但都只在这一个文件里，漏写会被断言报红。
# 对外提供：probe_su / notify_event / notify_once / notify_warn / notify_lead / tag_of。
# 配置：NOTIFY=0 关闭全部通知；NOTIFY_LEAD、NOTIFY_COOLDOWN 见下。
# 注入点（生产环境不设置）：SU_BIN、NOTIFY_CMD、FAFU_SU_MODE。
# ============================================================

# ---- 配置（可被模块目录内的 fafu-checkin.conf 覆盖） ----
NOTIFY="${NOTIFY:-1}"                      # 1=启用通知，0=完全关闭（零调用）
NOTIFY_LEAD="${NOTIFY_LEAD:-5}"            # 兜底唤醒前的预警提前量（秒）
NOTIFY_COOLDOWN="${NOTIFY_COOLDOWN:-300}"  # 同类打扰通知的最小间隔（秒）
SU_BIN="${SU_BIN:-/system/bin/su}"         # su 路径（可用环境变量覆盖，供 mock 测试注入）

SU_MODE=""                # 生效的降权写法，由 probe_su() 探测后写入
_NT_TITLE=""              # 通知标题（文案表设置）
_NT_TEXT=""               # 通知正文；留空则复用标题
# 事件名 → 文案模板名（tag 拼法见 tag_of）。写错名字等于该类提醒静默失效。
# 「当日首次失败」有两个事件名（failsign / failtask）：文案与 tag 各不同，但共用同一个
# 当日标记（_NT_MARK_* 都指向 state 层的 fail），一次失败之后同类提醒当天不再重复。
# 之所以要这张显式的表：模板名会出现在两处对外契约上（tag 后缀、state 层标记名），
# 让它跟着事件名走就等于把两处契约交给「函数名恰好相同」这种巧合。
_NT_TPL_sign=sign;         _NT_TPL_supp=supp;         _NT_TPL_seen=seen
_NT_TPL_leave=leave;       _NT_TPL_failsign=failsign; _NT_TPL_failtask=failtask
_NT_TPL_nosign=nosign;     _NT_TPL_late=late;         _NT_TPL_miss=miss
_NT_MARK_failsign=fail;    _NT_MARK_failtask=fail
_NT_MARK_nosign=nosign;    _NT_MARK_late=late;        _NT_MARK_miss=miss
# 落盘状态（每日标记、冷却基准）归 state 层：本层只经 notify_marked / notify_mark /
# nt_cooldown 访问。冷却基准必须落盘——refresh_token 总在 $( ) 子 shell 里被调用，
# 普通变量活不过那个子 shell，冷却会永远不生效。

# ---- tag 表：事件名 → 通知 tag 后缀（完整 tag = fafu-<后缀>-<当日 tag>） ----
# 默认后缀就是事件名本身，只有两个例外：seen 与 sign 同 tag（同为「已签到」，同日互相
# 覆盖不堆积），三个未签时点用 t2200 / t2230 / miss。这两个例外是**对外契约**，别顺手改。
# tag 里含日期，故整条策略是「按日滚动」：同事件次日覆盖前一天，通知栏条数恒有上限。
tag_of() { # $1=事件名 → 事件对应的 tag 后缀（未知事件输出空）
  case "$1" in
    seen)   echo sign ;;
    nosign) echo t2200 ;;
    late)   echo t2230 ;;
    sign|supp|leave|failsign|failtask|miss|warn|test) echo "$1" ;;
  esac
}

# ---- 降权身份探测（通知必须以 shell 身份发送） ----
# 不能用退出码判断可用性：KernelSU 的 su 用 Rust getopts 且默认 StopAtFirstFree，长度为 1 的
# `-` 会被当作 free 参数终止选项解析，于是 `su - shell -c CMD` 实际 exec 出交互式登录 shell、
# 把 CMD 丢掉，`</dev/null` 下立刻 EOF 退出 0 —— 只看退出码会记成「可用」，之后每条通知都变成
# 「rc=0 但什么都没发生」。故必须验证命令真的执行了、身份真的降到了 shell：`id -u` 读作 2000。
probe_su() {
  local c u su
  SU_MODE=""
  [ "$NOTIFY" = "1" ] || return 0
  # 父进程已探测过（守护进程由 start 派生）→ 直接继承，避免重复探测
  if [ -n "${FAFU_SU_MODE:-}" ]; then
    SU_MODE="$FAFU_SU_MODE"
    return 0
  fi
  # su 的实际位置由 PATH 解析（各 root 管理器放的位置不同），SU_BIN 只是回退与注入点
  su=$(command -v "$SU_BIN" 2>/dev/null)
  [ -n "$su" ] || su=$(command -v su 2>/dev/null)
  [ -n "$su" ] || { log "通知链路: 找不到 su（$SU_BIN），通知将静默跳过"; return 0; }
  # 候选写法逐条试：三种都是设备上见过的调用形状，哪种真的降权以 id 校验为准。
  # 命令名用解析出的**绝对路径**（同一条链路上的同一个二进制）：探测的注入点只有一处，
  # 测试要顶掉 su 时不必去猜 PATH 上哪个名字会被内建 applet 抢先命中。
  for c in "$su - shell -c" "$su shell -c" "$su shell /system/bin/sh -c"; do
    # timeout 防止 su 挂起拖死启动；但它未必存在，且超时本身可能是「冷启动慢」
    # 而非「真的不可用」，故用更宽松的超时重试一次，避免把可用链路误判为不可用
    if [ -n "$(command -v timeout 2>/dev/null)" ]; then
      u=$(timeout 2 $c 'id -u' </dev/null 2>/dev/null)
      [ "$u" = "2000" ] || u=$(timeout 5 $c 'id -u' </dev/null 2>/dev/null)
    else
      u=$($c 'id -u' </dev/null 2>/dev/null)
      [ "$u" = "2000" ] || u=$($c 'id -u' </dev/null 2>/dev/null)
    fi
    # 必须同时满足「有输出」且「uid=2000」——只验 rc 会被空执行骗过
    if [ "$u" = "2000" ]; then
      SU_MODE="$c"
      log "通知链路: 降权写法 [$c] 可用（id -u = 2000）"
      return 0
    fi
  done
  log "通知链路: 降权不可用（候选写法均未通过 id 校验），通知将静默跳过"
  return 0
}

# ---- 签到 / 通知文案模板（正文不含引号与命令替换，可安全直接展开） ----
_msg_sign()   { _NT_TITLE="✅ 查寝签到成功";      _NT_TEXT="$PL 已签到（晚查寝签到）"; }
_msg_supp()   { _NT_TITLE="🕘 已补签";            _NT_TEXT="$PL 补签成功"; }
_msg_seen()   { _NT_TITLE="✅ 今日已签到";        _NT_TEXT="$PL 已签到（晚查寝签到）"; }
_msg_leave()  { _NT_TITLE="🏖 今日查寝已请假";    _NT_TEXT="$PL 状态为请假，不会自动签到"; }
_msg_failsign() { _NT_TITLE="⚠️ 查寝签到失败";    _NT_TEXT="$PL 提交失败，仍在重试（22:59 前有效）"; }
_msg_failtask() { _NT_TITLE="⚠️ 拿不到查寝任务";  _NT_TEXT="$PL 无法获取任务，仍在重试"; }
_msg_nosign() { _NT_TITLE="⏰ 尚未签到，主窗口还剩 30 分钟"
                _NT_TEXT="$PL 22:00 还没签到，主窗口 22:30 关闭；现在可在 App 内手动签到"; }
_msg_late()   { _NT_TITLE="⏰ 主窗口已过，进入补签时段"
                _NT_TEXT="$PL 22:30 仍未签到，模块会继续自动重试，也可在 App 内手动补签"; }
_msg_miss()   { _NT_TITLE="❌ 今晚未能自动签到"
                _NT_TEXT="$PL 23:00 重试结束仍未签到，请手动处理"; }

# ---- 发送 ----
# cmd notification post 的能力被 AOSP 限死（改这里会坏什么）：通知 id 恒为 2020，只能靠
# tag 区分事件；channel 恒为 shell_cmd，重要性 / 声音 / 图标 / ongoing / 按钮均不可调。
nt_send() { # $1=完整命令串：交给降权 shell 执行；调用它的是 notify()
            # 独立一函数是为让断言能替换掉「执行」这一步，看到真正构造出的命令串
  $SU_MODE "$1" </dev/null >/dev/null 2>&1
}

notify() { # $1=tag；使用文案表设好的 _NT_TITLE / _NT_TEXT；返回发送是否成功
  local t
  [ "$NOTIFY" = "1" ] || return 0
  [ -n "$SU_MODE" ] || return 0
  [ -n "$1" ] || return 0
  # 命令交由 su 派生出的新 shell 执行，标题/正文必须 export 才能被子 shell 看到，
  # 否则实际发出的是空标题空正文（su 仍返回成功，属静默失效）
  export _NT_TITLE _NT_TEXT
  # $1（tag）在此处展开；$_NT_TITLE 等保留给子 shell 展开
  t="cmd notification post -t \"\$_NT_TITLE\" \"$1\" \"\${_NT_TEXT:-\$_NT_TITLE}\" -S bigtext"
  [ -n "$NOTIFY_CMD" ] && t="$NOTIFY_CMD"
  nt_send "$t"
}

notify_event() { # $1=事件名：取文案表里的模板 → 按 tag 表拼 tag → 发送（每次都发）；
  local nt_tpl   # 返回值恒为 0（发送失败不能影响调用它的签到主流程）
  nt_tpl=""
  eval "nt_tpl=\${_NT_TPL_$1:-}"
  [ -n "$nt_tpl" ] || return 0
  "_msg_$nt_tpl"
  notify "fafu-$(tag_of "$nt_tpl")-$PL"
  return 0
}

notify_once() { # $1=事件名（failsign / failtask / nosign / late / miss）；当日一次；
  local nt_tpl nt_mk  # 仅在**发送成功**时才写标记
  [ "$NOTIFY" = "1" ] || return 0
  [ -n "$SU_MODE" ] || return 0
  nt_tpl=""; nt_mk=""
  eval "nt_tpl=\${_NT_TPL_$1:-}"
  eval "nt_mk=\${_NT_MARK_$1:-}"
  [ -n "$nt_tpl" ] && [ -n "$nt_mk" ] || return 0
  notify_marked "$nt_mk" && return 0
  # 先发送、成功再落标记：否则一次瞬时失败会让这类提醒整天不再出现
  _msg_$nt_tpl
  if notify "fafu-$(tag_of "$nt_tpl")-$PL"; then
    notify_mark "$nt_mk"
    return 0
  fi
  return 1
}

notify_warn() { # 开页预警：屏幕已亮且本次确实会开页时调用；打扰型，受 NOTIFY_COOLDOWN 节流。
  local nt_now   # 返回值 = 「这次真的发了」——调用方据此决定要不要留出阅读时间
  [ "$NOTIFY" = "1" ] || return 1
  [ -n "$SU_MODE" ] || return 1
  # 一次刷新失败可能连锁触发多次 refresh_token，冷却用来避免连续弹同一条
  nt_now=$(now_s)
  [ $((nt_now - $(nt_cooldown))) -ge "$NOTIFY_COOLDOWN" ] || return 1
  nt_cooldown "$nt_now"
  _NT_TITLE="🔄 正在刷新登录状态"
  _NT_TEXT="$(notify_lead) 秒后自动打开打卡页（用于刷新登录），完成后自动关闭，无需操作"
  notify "fafu-$(tag_of warn)-$PL"
}

notify_lead() { # 输出预警提前量秒数；屏幕本来就黑时不延时（省下无意义的等待）
  if [ "${WAS_ON:-0}" = "1" ] && [ "$NOTIFY_LEAD" -gt 0 ] 2>/dev/null; then
    echo "$NOTIFY_LEAD"
  else
    echo 0
  fi
}
