# ============================================================
# notify 层 —— 通知：降权探测、文案表、发送、每日一次去重、打扰冷却
#
# 加载顺序：第 5 层。通知是纯增量能力：任何失败都不得影响签到主流程。
# 三条硬约束（cmd notification post 的实现，改这里会坏什么）：
#   1) 通知 id 恒为 2020，只能靠 tag 区分事件；同 tag 会覆盖（静默更新）
#   2) channel 恒为 shell_cmd，重要性 / 声音 / 图标均不可调
#   3) 不支持 ongoing / autoCancel / 按钮
# tag 用含日期的「按日滚动」，同事件次日覆盖前一天，通知栏条数恒有上限。
# ============================================================

# ---- 配置（可被模块目录内的 fafu-checkin.conf 覆盖） ----
NOTIFY="${NOTIFY:-1}"                      # 1=启用通知，0=完全关闭（零调用）
NOTIFY_LEAD="${NOTIFY_LEAD:-5}"            # 兜底唤醒前的预警提前量（秒）
NOTIFY_COOLDOWN="${NOTIFY_COOLDOWN:-300}"  # 同类打扰通知的最小间隔（秒）
SU_BIN="${SU_BIN:-/system/bin/su}"         # su 路径（可用环境变量覆盖，供 mock 测试注入）

SU_MODE=""                # 生效的降权写法，由 probe_su() 探测后写入
_NT_TITLE=""              # 通知标题（调用方设置）
_NT_TEXT=""               # 通知正文；留空则复用标题（用于 P 预警）
# 通知的落盘状态（每日标记、冷却基准）由 state 层持有：本层只经
# notify_marked / notify_mark / nt_cooldown 访问，不自己碰那些文件。
# 冷却基准必须落盘：refresh_token 总在 $( ) 子 shell 里被调用，
# 若把基准放在普通变量里，赋值会随子 shell 一起丢弃 → 冷却永远不生效

# ---- 降权身份探测（通知必须以 shell 身份发送） ----
# 不能用退出码判断可用性：KernelSU 的 su 用 Rust getopts 且默认 StopAtFirstFree，
# 长度为 1 的 `-` 会被当作 free 参数终止选项解析，于是 `su - shell -c CMD` 实际 exec
# 出交互式登录 shell、把 CMD 丢掉，`</dev/null` 下立刻 EOF 退出 0 —— 只看退出码就会
# 记成「可用」，之后每条通知都变成「rc=0 但什么都没发生」。故必须验证命令真的执行了、
# 且身份真的降到了 shell：读 `id -u` 的输出，要求等于 2000。
probe_su() {
  SU_MODE=""
  [ "$NOTIFY" = "1" ] || return 0
  # 父进程已探测过（守护进程由 start 派生）→ 直接继承，避免重复探测
  if [ -n "${FAFU_SU_MODE:-}" ]; then
    SU_MODE="$FAFU_SU_MODE"
    return 0
  fi
  [ -n "$(command -v "$SU_BIN" 2>/dev/null)" ] || { log "通知链路: 找不到 su（$SU_BIN），通知将静默跳过"; return 0; }
  for c in "su - shell -c" "su shell -c" "su shell /system/bin/sh -c"; do
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

notify() { # $1=tag；使用全局 _NT_TITLE / _NT_TEXT；返回发送是否成功
  [ "$NOTIFY" = "1" ] || return 0
  [ -n "$SU_MODE" ] || return 0
  [ -n "$1" ] || return 0
  # 命令交由 su 派生出的新 shell 执行，标题/正文必须 export 才能被子 shell 看到，
  # 否则实际发出的是空标题空正文（su 仍返回成功，属静默失效）
  export _NT_TITLE _NT_TEXT
  # $1（tag）在此处展开；$_NT_TITLE 等保留给子 shell 展开
  _ntc="cmd notification post -t \"\$_NT_TITLE\" \"$1\" \"\${_NT_TEXT:-\$_NT_TITLE}\" -S bigtext"
  [ -n "$NOTIFY_CMD" ] && _ntc="$NOTIFY_CMD"
  if $SU_MODE "$_ntc" </dev/null >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

notify_once() { # $1=tag $2=事件名（fail / nosign / late / miss）；仅在**发送成功**时才写标记
  [ "$NOTIFY" = "1" ] || return 0
  [ -n "$SU_MODE" ] || return 0
  notify_marked "$2" && return 0
  # 先发送、成功再落标记：否则一次瞬时失败会让这类提醒整天不再出现
  if notify "$1"; then
    notify_mark "$2"
    return 0
  fi
  return 1
}

notify_lead() { # 输出预警提前量秒数；屏幕本来就黑时不延时（省下无意义的等待）
  if [ "${WAS_ON:-0}" = "1" ] && [ "$NOTIFY_LEAD" -gt 0 ] 2>/dev/null; then
    echo "$NOTIFY_LEAD"
  else
    echo 0
  fi
}
