# ============================================================
# 通知功能验收断言
#
# 分三层，都只针对「外部可观察的行为」：
#   A 静态断言：关键函数/调用点/条件是否还在，以及少数**相对顺序**不变量
#      （如降权探测必须排在子命令分发之前、开页预警必须排在 open_page 之前）；
#     面对的是「各层按加载顺序 + 入口」拼出的全程序文本（只读，不执行）；
#   B 函数级断言：source 真实的库，把降权写法指向记录函数，
#      断言最终交给系统执行的命令字符串；
#   C 文案与分支：真实 _msg_* / notify / notify_once 的产物与返回码。
#
# 覆盖不到的（只能上机目视确认）：su / cmd notification post 的真实送达、Doze 投递延迟。
# ============================================================

# 静态断言面对的文本：各层 + 入口，拼接顺序即加载顺序（相对顺序断言因此仍然成立）
NT_SRC=""
nt_src() {
  [ -n "$NT_SRC" ] && { printf '%s' "$NT_SRC"; return 0; }
  NT_SRC="$T_WORK_ROOT/program.sh"
  mkdir -p "$T_WORK_ROOT"
  if ! t_write_program "$NT_SRC"; then
    echo "无法拼出全程序文本（层清单见入口 fafu_checkin.sh 的 FAFU_LAYERS）" >&2
    exit 1
  fi
  printf '%s' "$NT_SRC"
}

# -- 供用例使用的临时目录与工具链（用例执行时才创建，避免 source 本文件就有副作用） --
nt_setup() {
  T_WORK="$T_WORK_ROOT/notify"
  rm -rf "$T_WORK"
  mkdir -p "$T_WORK"
  T_BB=$(t_find_busybox)
  t_bb_wrap "$T_WORK/bin/bb" >/dev/null
  if ! t_write_lib "$T_WORK/part.sh"; then
    echo "无法拼出被测库（见 tests/harness.sh 的 TEST_LIB_FILES）"
    exit 1
  fi
  NT_PART="$T_WORK/part.sh"
  NT_BB="$T_WORK/bin/bb"
}

# 生成驱动脚本的公共前导（环境 + 注入点），落到 $T_WORK/_env.sh 供各驱动 source。
# 约定：调用方先 \`cat > "$T_WORK/_env.sh"\`，再按自己的断言写主体，详见 nt_case_*。
# 这里集中三件事：把时间/降权/通知命令三个注入点接上、加载真实的库、把日期固定下来。
nt_write_env() {
  cat > "$T_WORK/_env.sh" <<ENV
PATH='/bin:/usr/bin'
T_ROOT='$T_ROOT'
T_WORK='$T_WORK'

# 注入点：时间走 $BB_OVERRIDE，降权写法走 SU_MODE，通知命令走 NOTIFY_CMD（本次未用到）
NOTIFY=1; NOTIFY_LEAD=5; NOTIFY_COOLDOWN=300
SU_BIN=/bin/true            # 降权探测先看 su 是否存在，这里给一个必然存在的替身

. '$NT_PART'                # 直接加载真实的库（不是从源码里抽片段再拼接）
SU_MODE=nt_cap              # 把降权写法指向记录函数，即可断言「最终交给系统执行的命令」
PL=20261001                 # 库顶层会用真实日期初始化 PL，这里改回固定值
ENV
}

# 跑一个驱动脚本；用法：nt_run <名字>，主体从 stdin 读入（公共前导自动接在前面）
nt_run() {
  cat > "$T_WORK/_body.sh"
  cp "$T_WORK/_env.sh" "$T_WORK/$1.sh"
  cat "$T_WORK/_body.sh" >> "$T_WORK/$1.sh"
  ( cd "$T_WORK" && $(t_sh) "./$1.sh" ) \
    > "$T_WORK/$1.out" 2> "$T_WORK/$1.err"
  if [ -s "$T_WORK/$1.err" ]; then
    echo "  （驱动 $1 的 stderr）"
    sed 's/^/    /' "$T_WORK/$1.err"
  fi
}

# ============================================================
# A. 静态断言（针对真实源码文本）
# ============================================================

nt_case_defs() {
  local f v
  TEST_SRC=$(nt_src)
  for f in probe_su notify notify_once notify_lead \
           _msg_sign _msg_supp _msg_seen _msg_leave \
           _msg_failsign _msg_failtask _msg_nosign _msg_late _msg_miss; do
    t_has "函数存在：$f()" "$TEST_SRC" "$f()"
  done
  for v in "SU_MODE=" "_NT_TITLE=" "_NT_TEXT=" "PL=" \
           "NOTIFY=" "NOTIFY_LEAD=" "NOTIFY_COOLDOWN=" "SU_BIN="; do
    t_has "已定义 $v" "$TEST_SRC" "$v"
  done
  # 通知标记与冷却基准的归属地是 state 层：notify 层只经它访问，不再持有文件路径
  t_hasnt "notify 层不再持有通知标记路径" "$TEST_SRC" 'NTLAST="$MODDIR'
  t_has "每日一次的判定经 state 层" "$TEST_SRC" 'notify_marked "$2" && return 0'
  t_has "发送成功后才经 state 层落标记" "$TEST_SRC" "$(t_call notify_mark '"$2"')"
}

nt_case_call_sites() {
  local t
  TEST_SRC=$(nt_src)
  for t in 'notify "fafu-sign-$PL"' 'notify "fafu-supp-$PL"' 'notify "fafu-leave-$PL"' \
           'notify "fafu-warn-$PL"' 'notify_once "fafu-failsign-$PL" fail' \
           'notify_once "fafu-failtask-$PL" fail' \
           'notify_once "fafu-t2200-$PL"  nosign' \
           'notify_once "fafu-t2230-$PL"  late' \
           'notify_once "fafu-miss-$PL"   miss'; do
    t_has "调用点：$t" "$TEST_SRC" "$t"
  done
  # 事件名写错等于当天提醒静默失效：四个事件名必须都在 state 层的映射表里。
  # 用正则容忍分支缩进（写死空格会让一次排版改动制造假红灯），但要求「事件名 → 变量」这个形状。
  for e in fail nosign late miss; do
    t_has_re "state 层把事件 $e 映射到标记文件" "$TEST_SRC" \
      "^[ ]*$e\\)[ ]*printf '%s' \"\\\$N"
  done
}

nt_case_warn_order() {
  TEST_SRC=$(nt_src)
  # 预警必须挂在「本次确实会打开打卡页」上：两种路径都在 open_page 之前。
  # 用函数体定位，不绑行号——重构时可以搬动代码，但不能改变这个相对顺序。
  t_has "P 条件一：屏幕已亮 + 探测可用" "$TEST_SRC" '[ "${WAS_ON:-0}" = "1" ] && [ -n "$SU_MODE" ]'
  t_before "开页预警排在 open_page 之前（静默路径也会预警）" "$TEST_SRC" \
    'fafu-warn-' "$(t_call open_page)"
  # 冷却基准必须落盘（refresh_token 在 $( ) 子 shell 里调用它，普通变量赋值会丢）；
  # 落盘的归属地是 state 层：这里断言的是「经状态层读写」而不是「自己写文件」
  t_has "冷却基准经 state 层读取" "$TEST_SRC" '$(nt_cooldown)'
  t_has "冷却基准经 state 层写回" "$TEST_SRC" 'nt_cooldown "$now_ts"'
  t_has "冷却基准的落盘实现只在 state 层" "$T_ROOT/lib/state.sh" 'NTLAST="$MODDIR/.fafu_notify_last"'
  t_hasnt "keepalive 层不再自己写冷却文件" "$T_ROOT/lib/keepalive.sh" '> "$NTLAST"'
  # 契约（设备实测后新增）：拿到新 token 就**提前**关页，让前台尽早回到用户手里。
  # 判据是「提前关页早于兜底唤醒」，用那句日志做锚点而不是注释行。
  t_before "拿到 token 即提前关页（早于兜底唤醒）" "$TEST_SRC" \
    "$(t_call close_page)" "静默刷新未成功，尝试唤醒屏幕重试"
  # 回归：绝不再有「回桌面」这类主动切换用户前台的兜底（注释里说明理由不算）
  _starts=""
  while IFS= read -r _ln; do
    case "$_ln" in
      *':#'*) : ;;               # 注释行不参与判定
      *) _starts="$_starts$_ln
" ;;
    esac
  done <<EOF
$(grep -nF -e 'am start' -- "$TEST_SRC" 2>/dev/null)
EOF
  case "$_starts" in
    *category.HOME*) _t_fail "已移除「回桌面兜底」：仍有切到桌面的 am start" ;;
    '')              _t_fail "已移除「回桌面兜底」：找不到任何 am start（开页实现没了？）" ;;
    *)               _t_pass "已移除「回桌面兜底」（am start 调用点 $(printf '%s' "$_starts" | grep -c .) 处）" ;;
  esac
  t_has "与冷却阈值比较" "$TEST_SRC" '-ge "$NOTIFY_COOLDOWN"'
  t_hasnt "旧的 _NT_LAST 变量已彻底移除" "$TEST_SRC" '_NT_LAST'
  t_has "提前量：延时由 notify_lead 决定" "$TEST_SRC" 'sleep "$(notify_lead)"'
  t_has "notify_lead：仅亮屏时返回正数" "$TEST_SRC" \
    'if [ "${WAS_ON:-0}" = "1" ] && [ "$NOTIFY_LEAD" -gt 0 ]'
}

nt_case_state_text() {
  TEST_SRC=$(nt_src)
  t_has "存在 state_text() 映射函数" "$TEST_SRC" 'state_text() {'
  t_has "映射：1 → 已签到" "$TEST_SRC" '1) echo "已签到" ;;'
  t_has "映射：2 → 已请假" "$TEST_SRC" '2) echo "已请假" ;;'
  t_has "映射：未知值也自解释" "$TEST_SRC" '*) echo "未知状态($1)" ;;'
  t_has "日志调用处已改用映射" "$TEST_SRC" 'log "[$name] $(state_text "$state")"'
  t_hasnt "裸状态码日志已彻底移除" "$TEST_SRC" '已签到(状态'
}

nt_case_time_points() {
  TEST_SRC=$(nt_src)
  t_before "22:00 起判定，23:00 分支在其后" "$TEST_SRC" \
    'if [ $now -ge 1320 ]' 'if [ $now -ge 1380 ]'
  t_has "22:30 分支" "$TEST_SRC" 'elif [ $now -ge 1350 ]'
  t_has "当日已解决（含请假）不提醒" "$TEST_SRC" \
    '[ "$sd" = "$(today)" ] && [ "$sk" != "" ]'
}

nt_case_probe_wiring() {
  TEST_SRC=$(nt_src)
  t_has "已注册 notify 子命令" "$TEST_SRC" 'notify)    cmd_notify; exit $?'
  t_has "存在 cmd_notify() 实现" "$TEST_SRC" 'cmd_notify() {'
  t_has "notify 也执行降权探测（否则 SU_MODE 为空）" "$TEST_SRC" \
    'once|refresh|keepalive|notify) probe_su'
  t_has "测试通知用独立 tag（不污染正常通知）" "$TEST_SRC" 'fafu-test-$PL'
  t_has "用法串已含 notify" "$TEST_SRC" 'stop|status|notify|once|refresh'
  t_has "探测前进：检查 su 可用性" "$TEST_SRC" 'command -v "$SU_BIN"'
  t_has "S1 回归：探测用 id -u 验证命令真的执行了" "$TEST_SRC" "'id -u'"
  t_has "S1 回归：校验身份真的降到了 shell" "$TEST_SRC" '[ "$u" = "2000" ]'
  t_has "S1 回归：候选含 KernelSU 可用写法" "$TEST_SRC" 'su shell /system/bin/sh -c'
  t_has "探测仅在这些子命令执行" "$TEST_SRC" 'start|""|once|refresh|keepalive|notify) probe_su'
  t_hasnt "status/stop 不触发探测（未误加）" "$TEST_SRC" 'status|stop|toggle)'
  # P0-A 回归：探测必须在子命令分发之前——各分支会直接 exit，否则探测成死代码
  t_before "P0-A 回归：探测排在分发之前" "$TEST_SRC" "$(t_call probe_su)" 'cmd_notify; exit'
  t_has "P0-B 回归：标题/正文已 export" "$TEST_SRC" 'export _NT_TITLE _NT_TEXT'
  t_has "S3 回归：先发送成功后才写标记" "$TEST_SRC" 'if notify "$1"; then'
  t_has "守护进程继承探测结果（不重复探测）" "$TEST_SRC" 'FAFU_SU_MODE'
  t_has "启动日志记录通知链路状态" "$TEST_SRC" 'notify=[${SU_MODE:-不可用}]'
  t_has "S7 回归：PL 在守护主循环内重算（跨日 tag 不滞留）" "$TEST_SRC" \
    'PL=$(today_tag)' 2
  t_has "S4 回归：拒绝用空文件覆盖 module.prop" "$TEST_SRC" '[ -s "$tmp" ]'
  # 四类通知标记的归属地是 state 层：文件名与事件映射都在那里，这里只钉住这条边界
  t_has "22:00 标记在 state 层" "$T_ROOT/lib/state.sh" 'NNOSIGN="$MODDIR/.fafu_notify_nosign"'
  t_has "22:30 标记在 state 层" "$T_ROOT/lib/state.sh" 'NLATE="$MODDIR/.fafu_notify_late"'
  t_has "23:00 标记在 state 层" "$T_ROOT/lib/state.sh" 'NMISS="$MODDIR/.fafu_notify_miss"'
  t_has "失败类标记在 state 层" "$T_ROOT/lib/state.sh" 'NFAIL="$MODDIR/.fafu_notify_fail"'
}

# ============================================================
# B. 函数级：真实 notify() 生成的最终命令
# ============================================================

nt_case_command() {
  nt_setup
  nt_write_env
  nt_run cmd <<DRIVER
nt_cap() { printf '%s\n' "\$1" >> "\$T_WORK/cmd.log"; }

_msg_sign;  notify "fafu-sign-\$PL"
_msg_leave; notify "fafu-leave-\$PL"
WAS_ON=1; lead_on=\$(notify_lead)
WAS_ON=0; lead_off=\$(notify_lead)
WAS_ON=1
# NOTIFY=0 时 notify / notify_once 必须零调用
NOTIFY=0; _msg_miss; notify "fafu-miss-\$PL"; NOTIFY=1
# 当日标记未写时才发；发送成功后标记落盘（标记的归属地是 state 层，这里只传事件名）
_msg_miss; notify_once "fafu-miss-\$PL" miss
_msg_miss; notify_once "fafu-miss-\$PL" miss
printf 'lead_on=%s\nlead_off=%s\n' "\$lead_on" "\$lead_off" > "\$T_WORK/lead.txt"
printf 'guard=%s\n' "\$(cat "\$MODDIR/.fafu_notify_miss")" > "\$T_WORK/guard.txt"
DRIVER

  t_lines "三条命令（2 条 notify + 1 条 once）" "$T_WORK/cmd.log" 3
  t_has "命令为 cmd notification post" "$T_WORK/cmd.log" 'notification post'
  t_has "tag 由 \$PL 展开（未延迟）" "$T_WORK/cmd.log" 'fafu-sign-20261001'
  t_has "请假 tag 正确" "$T_WORK/cmd.log" 'fafu-leave-20261001'
  t_has "未签 tag 正确" "$T_WORK/cmd.log" 'fafu-miss-20261001'
  t_has "标题保留给子 shell 展开" "$T_WORK/cmd.log" '$_NT_TITLE'
  t_has "正文回退写法保留" "$T_WORK/cmd.log" '${_NT_TEXT:-$_NT_TITLE}'
  t_has "使用 bigtext 样式" "$T_WORK/cmd.log" '-S bigtext'
  t_has "NOTIFY=0 不产生命令（miss 只出现 1 次，来自 once）" "$T_WORK/cmd.log" 'fafu-miss' 1
  t_eq "notify_lead：亮屏 = 5" "$(sed -n 's/^lead_on=//p' "$T_WORK/lead.txt")" 5
  t_eq "notify_lead：熄屏 = 0" "$(sed -n 's/^lead_off=//p' "$T_WORK/lead.txt")" 0
  t_eq "当日标记写为今天" "$(cat "$T_WORK/guard.txt")" "guard=$(t_today)"
}

# ============================================================
# C. 文案模板与发送失败分支（真实 _msg_* / notify_once）
# ============================================================

nt_case_templates() {
  nt_setup
  nt_write_env
  nt_run msg <<DRIVER
nt_cap() { printf '%s\n' "\$1" >> "\$T_WORK/msg.log"; }

# 逐条模板：先发模板函数、再取标题正文，断言的就是 notify 真正会用的那两个值
for m in sign supp seen leave failsign failtask nosign late miss; do
  _msg_\$m
  printf '%s\t%s\n' "\$_NT_TITLE" "\$_NT_TEXT" >> "\$T_WORK/msg.txt"
  notify "fafu-\$m-\$PL"
done
# 开页预警：正文里的提前量由 notify_lead 决定（屏幕已亮 = 5 秒）
WAS_ON=1
_NT_TITLE="🔄 正在刷新登录状态"
_NT_TEXT="\$(notify_lead) 秒后自动打开打卡页（用于刷新登录），完成后自动关闭，无需操作"
printf '%s\t%s\n' "\$_NT_TITLE" "\$_NT_TEXT" >> "\$T_WORK/msg.txt"
notify "fafu-warn-\$PL"

# 发送失败：notify_once 必须返回非 0，且不得落当日标记（否则一次瞬时失败=整天不再提醒）
printf '%s\n' '2026-10-01 20:00' > "\$T_WORK/clock"
rm -f "\$MODDIR/.fafu_notify_fail"
SU_MODE=false
if _msg_miss && notify_once "fafu-failsign-\$PL" fail; then
  echo 'once_rc=0' >> "\$T_WORK/msg.txt"
else
  echo 'once_rc=1' >> "\$T_WORK/msg.txt"
fi
if notify_marked fail; then
  echo 'guard=written' >> "\$T_WORK/msg.txt"
else
  echo 'guard=absent' >> "\$T_WORK/msg.txt"
fi
DRIVER

  t_lines "10 条文案模板全部生成" "$T_WORK/msg.txt" 12
  t_lines "10 条通知命令全部构造" "$T_WORK/msg.log" 10
  t_has "A1 标题" "$T_WORK/msg.txt" '✅ 查寝签到成功'
  t_has "A2 标题" "$T_WORK/msg.txt" '🕘 已补签'
  t_has "B 标题" "$T_WORK/msg.txt" '✅ 今日已签到'
  t_has "C 标题" "$T_WORK/msg.txt" '🏖 今日查寝已请假'
  t_has "D 标题" "$T_WORK/msg.txt" '⚠️ 查寝签到失败'
  t_has "E 标题" "$T_WORK/msg.txt" '⚠️ 拿不到查寝任务'
  t_has "F1 标题（22:00 还剩 30 分钟）" "$T_WORK/msg.txt" '⏰ 尚未签到，主窗口还剩 30 分钟'
  t_has "F2 标题（22:30 进入补签）" "$T_WORK/msg.txt" '⏰ 主窗口已过，进入补签时段'
  t_has "F3 标题（23:00 未能签到）" "$T_WORK/msg.txt" '❌ 今晚未能自动签到'
  t_has "P 标题" "$T_WORK/msg.txt" '🔄 正在刷新登录状态'
  t_has "P 正文含提前量（亮屏=5 秒）" "$T_WORK/msg.txt" '5 秒后自动打开打卡页'
  t_has "A1 tag" "$T_WORK/msg.log" 'fafu-sign-20261001'
  t_has "P tag" "$T_WORK/msg.log" 'fafu-warn-20261001'
  t_has "S3：发送失败时 notify_once 返回非 0" "$T_WORK/msg.txt" 'once_rc=1'
  t_has "S3：发送失败时不落当日标记（可再试）" "$T_WORK/msg.txt" 'guard=absent'
  # 文案不得出现任何分数/扣分字样（用户明确要求：不替用户判断补签的得失）。
  # 「30 分钟」里的「分」是时间单位，故只匹配真正的计分表述。
  if grep -qE '得分|扣分|计分|加分|满分|少得|[0-9] *分[^钟]' "$T_WORK/msg.txt" 2>/dev/null; then
    _t_fail "文案不含任何分数/扣分表述（出现了计分写法）"
  else
    _t_pass "文案不含任何分数/扣分表述"
  fi
}

# ============================================================
# D. 库加载缝：断言可以 source 真实的库（这是整套测试的地基）
# ============================================================

nt_case_lib_load() {
  nt_setup
  nt_write_env
  nt_run load <<DRIVER
# 库加载缝：断言真的能直接加载真实源码，且加载本身没有任何副作用
for f in probe_su notify notify_once notify_lead desc_text set_desc update_desc \
         get_token api refresh_token run_once keepalive_ping cmd_status state_text \
         svc_is_disabled svc_set sign_get sign_set ka_note ka_counts ka_ok_count \
         ka_fail_count ka_last_time ka_last_result ka_is_today \
         done_marked done_mark notify_marked notify_mark nt_cooldown; do
  command -v "\$f" >/dev/null 2>&1 || echo "missing:\$f"
done
DRIVER
  t_eq "加载后无缺失函数、无 stderr" "$(cat "$T_WORK/load.err")" ""
  # missing: 是打到 stdout 的：不查这一行的话，「函数改名了」会让这条断言空转
  t_eq "加载后无缺失函数（stdout 也无 missing:）" "$(grep -c '^missing:' "$T_WORK/load.out")" "0"
  t_hasnt "加载库不会自行跑起来（无输出）" "$T_WORK/load.out" '用法:'
}

# ============================================================
# E. mock 时间源本身
#
# mock 只在「找不到真实 busybox」时才报错退出（正常情况下它必须能承接 applet 调用）。
# 「找不到」这一支在 busybox ash 里测不出来——那里 `command -v busybox` 连清空 PATH
# 都会命中内建 applet；而 mock 由哪个 shell 跑取决于环境（CI 上是系统 sh）。
# 所以这里只断言两件与环境无关的事：报错分支确实写在源码里，且正常路径真的可用。
# ============================================================

nt_case_mock_guard() {
  nt_setup
  t_file "已生成 mock busybox 包装" "$NT_BB"
  t_has "包装里带上了真实 busybox 的路径" "$NT_BB" "BB_REAL='"
  t_has "mock 有「拿不到真实 busybox」的明确报错分支" "$T_ROOT/tests/mock/busybox" 'exit 127'
  t_has "报错里指出了出路" "$T_ROOT/tests/mock/busybox" 'TEST_BUSYBOX'

  # 正常路径：包装必须真的能取到日期（否则 mock 只是个会报错的摆设）
  _d=$("$NT_BB" date +%Y-%m-%d 2>/dev/null)
  t_eq "mock 包装可用：能取到日期（长度 10）" "${#_d}" 10
}


t_case "notify · A · 通知调用点齐全" nt_case_call_sites
t_case "notify · A · 预警条件、提前量与冷却" nt_case_warn_order
t_case "notify · A · 状态码译名" nt_case_state_text
t_case "notify · A · 时间点提醒与请假排除" nt_case_time_points
t_case "notify · A · 探测编排与降级" nt_case_probe_wiring
t_case "notify · B · 真实 notify 生成的命令" nt_case_command
t_case "notify · C · 文案模板与发送失败分支" nt_case_templates
t_case "notify · D · 库加载缝" nt_case_lib_load
t_case "notify · E · mock 时间源的兜底" nt_case_mock_guard
