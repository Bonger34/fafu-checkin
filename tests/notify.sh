# ============================================================
# notify 层验收断言：降权探测、事件名 → tag/文案、发送、每日一次去重、打扰冷却
#
# 三条口径：
#   1) **只报事件名**：业务层说「发生了什么」（sign / supp / …），tag 拼法与文案都在
#      notify 层里查表；断言数的是「哪个事件产生了哪条命令、什么标题正文」；
#   2) **降权探测判的是身份**：替身 su 复现 `su - shell -c` 没执行命令、退出码却是 0
#      这条语义，断言要求探测读到 `id -u` 输出 2000 才认，并依次尝试三个候选写法；
#   3) **冷却基准必须落盘**：在 $( ) 子 shell 里发预警，再看基准是否真写到 state 层的文件上。
#
# 加载：直接 source 真实层文件（harness 的 TEST_LIB_FILES，顺序取自入口的 FAFU_LAYERS）。
# 观察面：覆写 nt_send 记下**最终构造出的命令串**；消息文案读 _NT_TITLE / _NT_TEXT。
# 覆盖不到（只能上机目视确认）：su / cmd notification post 的真实送达、Doze 投递延迟。
# ============================================================

# 事件名 → 期待的输出（tag 后缀）。「tag 格式与按日滚动不变」就钉在这张表上。
NT_TAGS="sign:sign supp:supp seen:sign leave:leave failsign:failsign failtask:failtask nosign:t2200 late:t2230 miss:miss warn:warn test:test"

# 工作目录与环境：每个驱动一份干净的，目录名带上驱动名，跑完留在 tests/.work/notify-<驱动>/。
# 必须按驱动分开：同一条用例里的多个驱动共用一个目录时，后一个会覆盖前一个留下的记录，
# 断言静默变成空转。
NT_WORK=""
nt_setup() { # $1=驱动名（决定工作目录）
  NT_WORK="$T_WORK_ROOT/notify-$1"
  rm -rf "$NT_WORK"
  mkdir -p "$NT_WORK/mod" "$NT_WORK/bin" "$NT_WORK/ctl/su" "$NT_WORK/dev"
  : > "$NT_WORK/ctl/su/calls"
  : > "$NT_WORK/ctl/su/sent"
  t_bb_wrap "$NT_WORK/bin/bb" >/dev/null
  nt_stub_write "$NT_WORK/bin/su"
  nt_env
}

# 降权链路的替身：**只顶掉 su 这个可执行文件**，probe_su 与 notify 都跑真实实现。
# 两条约束决定了它必须是文件、且必须挂在 $SU_BIN 上：su 是 busybox 的内建 applet，
# PATH 上的同名文件拦不到它；而路径里带空格时「把变量指向命令名」会因词分割执行失败。
#   探测：`su <arrangement> -c 'id -u'` → 记一行、输出 MOCK_SU_ID（默认 2000）
#         MOCK_SU_EMPTY=1 时**空手退出 0**（KernelSU 上 `-c` 落空、命令根本没跑）
#   发送：`su <arrangement> -c 'cmd notification post ...'` → 替身真的把它跑掉，
#         于是「最终交给系统执行的命令」在 ctl/su/sent 里留下一份（默认用例并不断言它）
nt_stub_write() { # $1=可执行文件路径
  cat <<STUB > "$1"
#!$(t_find_busybox) sh
# 由 tests/notify.sh 生成：降权链路替身（记录调用，按配置应答）
printf '%s\n' "\$*" >> ctl/su/calls
case "\$*" in
  *'id -u'*) : ;;
  *) printf '%s\n' "\$*" >> ctl/su/sent; sh -c "\$*" ;;
esac
[ -n "\${MOCK_SU_EMPTY:-}" ] && exit 0
printf '%s\n' "\${MOCK_SU_ID:-2000}"
STUB
  chmod +x "$1" 2>/dev/null || true
}

# 「按调用次数分档」的替身：前 4 次调用空手退出（命令没跑、rc 却是 0），第 5 次才真的
# 给出身份。用来验「候选依次尝试」——能通过校验的必然是第三个候选（每个候选试两次）。
# 它是**独立完整**的替身（不叠加在默认替身上）：叠加会让默认替身先输出 uid，
# 分档就永远轮不到。
nt_stub_seq() { # $1=可执行文件路径 $2=控制目录
  cat <<STUB > "$1"
#!$(t_find_busybox) sh
# 由 tests/notify.sh 生成：按调用次数分档的降权替身
n=\$(cat '$2/seq' 2>/dev/null); n=\$(( \${n:-0} + 1 )); printf '%s' "\$n" > '$2/seq'
printf '%s\n' "\$*" >> '$2/tried'
[ "\$n" -ge 5 ] || exit 0
echo 2000
STUB
  chmod +x "$1" 2>/dev/null || true
}

# 驱动脚本的公共前导：替身 busybox 排在 PATH 最前、模块目录、固定的当日 tag。
# 用「heredoc 直接重定向」而不是 `cat > file <<EOF`：后者让外部 cat 去读 stdin，
# 在把 stdin 挂在管道上的运行器里会一直等。
# $1=noprobe 时不自动探测（探测类用例自己控制调用次数）
nt_env() {
  cat <<ENV > "$NT_WORK/_env.sh"
PATH='./bin:/bin:/usr/bin'
T_ROOT='$T_ROOT'
T_WORK='$NT_WORK'
MODDIR='./mod'
BB_OVERRIDE='./bin/bb'
MOCK_DATE_CTL='./ctl/date'
# 设备命令替身的控制目录：tests/device.sh 的包装器与替身 busybox 按它应答。
# 只有时序用例会真去调设备命令，其余用例留着它也无害（那个目录是空的）
MOCK_DEVICE_DIR='$NT_WORK/dev'
export MODDIR BB_OVERRIDE MOCK_DATE_CTL MOCK_DEVICE_DIR
printf '2026-10-01 21:40\n' > "\$MOCK_DATE_CTL"
# 注入点：当日 tag、降权命令（绝对路径：探测里套了 timeout，
# 由它 fork 出去的命令取不到 shell 函数，必须落在文件上）。
# 通知开关与两个阈值由**配置层**给出（默认 1 / 5 / 300），本前导不设它们：
# 需要改值的用例在驱动里改（改完的值经 cfg_notify / cfg_notify_lead / cfg_notify_cooldown 读到）。
SU_BIN='$NT_WORK/bin/su'
PL=20261001
export SU_BIN PL
for _f in $TEST_LIB_FILES; do . "\$T_ROOT/\$_f"; done
ENV
  [ "$1" = "noprobe" ] || printf 'probe_su   # 与入口一致：先探一次，notify 才有 SU_MODE\n' >> "$NT_WORK/_env.sh"
}

# 跑一个驱动脚本；用法：nt_run <名字> [noprobe]，主体从 stdin 读入（前导自动接在前面）
nt_run() { # $1=名字 [$2=noprobe]
  local name
  name="$1"
  cat > "$NT_WORK/$name.body"
  nt_env "${2:-}"
  cat "$NT_WORK/_env.sh" "$NT_WORK/$name.body" > "$NT_WORK/$name.sh"
  ( cd "$NT_WORK" && $(t_sh) "./$name.sh" ) > "$NT_WORK/$name.out" 2> "$NT_WORK/$name.err"
  if [ -s "$NT_WORK/$name.err" ]; then
    echo "  （驱动 $name 的 stderr）"
    sed 's/^/    /' "$NT_WORK/$name.err"
  fi
}

# 从驱动输出里取一行（形如 key=value）
nt_val() { # $1=文件 $2=键
  sed -n "s/^$2=//p" "$1"
}

# ============================================================
# 一、降权探测：以「命令真的执行了、且身份降到 shell」为准
#
# 替身的两种应答分别对应设备上的两个真实结局：
#   MOCK_SU_EMPTY=1 —— `-c` 落空、命令根本没跑，但退出码是 0（KernelSU 的 su 就是这样）；
#   默认            —— 真的执行了，输出身份（2000 = shell）。
# 只看退出码的实现在第一种下会把链路误记成「可用」，这里的断言就会报红。
# ============================================================

nt_case_probe() {
  local d
  nt_setup probe
  nt_run probe noprobe <<'DRIVER'
printf 'ok=%s\n'    "$(probe_su; printf '%s' "$SU_MODE")"
printf 'calls=%s\n' "$(grep -c . ctl/su/calls)"
printf 'call1=%s\n' "$(head -n 1 ctl/su/calls)"
DRIVER
  d="$NT_WORK/probe.out"
  t_has "探测到 uid=2000：认定第一个候选写法可用" "$d" "ok=$NT_WORK/bin/su - shell -c"
  t_eq "可用即停止：只试了一个候选" "$(nt_val "$d" calls)" "1"
  t_has "探测真的执行了 id -u（不是只看退出码）" "$d" "-c id -u"

  # 只验退出码的实现会栽在这里：命令没执行（空的 id 输出），rc 却是 0。
  # 变量必须 export：命令最终由 timeout fork 出去，普通赋值进不了子进程
  nt_setup empty
  nt_run empty noprobe <<'DRIVER'
MOCK_SU_EMPTY=1
export MOCK_SU_EMPTY
printf 'skip=%s\n' "$(probe_su; printf '%s' "${SU_MODE:-EMPTY}")"
DRIVER
  t_eq "空手退出 0（命令没执行）→ 不认定可用" "$(nt_val "$NT_WORK/empty.out" skip)" "EMPTY"

  # 身份没降到 shell（uid 不是 2000）同样不算可用
  nt_setup rootid
  nt_run rootid noprobe <<'DRIVER'
MOCK_SU_ID=0
export MOCK_SU_ID
printf 'skip=%s\n' "$(probe_su; printf '%s' "${SU_MODE:-EMPTY}")"
DRIVER
  t_eq "输出 uid=0（没降权）→ 不认定可用" "$(nt_val "$NT_WORK/rootid.out" skip)" "EMPTY"

  # 通知开关关闭时不探测：零动作（连 su 都不碰）
  nt_setup off
  nt_run off noprobe <<'DRIVER'
NOTIFY=0
probe_su
printf 'mode=%s\n'  "$(printf '%s' "${SU_MODE:-EMPTY}")"
printf 'calls=%s\n' "$(grep -c . ctl/su/calls)"
DRIVER
  d="$NT_WORK/off.out"
  t_eq "NOTIFY=0：不探测" "$(nt_val "$d" mode)" "EMPTY"
  t_eq "NOTIFY=0：零调用" "$(nt_val "$d" calls)" "0"
}

# 候选依次尝试：替身按调用次数分档，前两个候选（各含一次宽松重试 = 前 4 次调用）
# 都空手退出，第 5 次才给出身份 —— 于是能通过校验的必然是第三个候选。
nt_case_probe_order() {
  local d
  nt_setup none
  nt_run none noprobe <<'DRIVER'
MOCK_SU_EMPTY=1
export MOCK_SU_EMPTY
probe_su
printf 'mode=%s\n'  "$(printf '%s' "${SU_MODE:-EMPTY}")"
printf 'calls=%s\n' "$(grep -c . ctl/su/calls)"
DRIVER
  d="$NT_WORK/none.out"
  t_eq "三个候选全空手退出 → SU_MODE 保持为空" "$(nt_val "$d" mode)" "EMPTY"
  # 每个候选都试了两次（宽松超时重试一次）：3 × 2 = 6
  t_eq "候选逐个试过（各含一次宽松重试）" "$(nt_val "$d" calls)" "6"

  nt_setup candrun
  nt_stub_seq "$NT_WORK/bin/su" "$NT_WORK/ctl/su"
  nt_run candrun noprobe <<'DRIVER'
rm -f ctl/su/seq ctl/su/tried
probe_su
printf 'mode=%s\n'     "$SU_MODE"
printf 'attempts=%s\n' "$(grep -c . ctl/su/tried)"
printf 'last=%s\n'     "$(tail -n 1 ctl/su/tried)"
DRIVER
  d="$NT_WORK/candrun.out"
  t_eq "候选依次尝试，直到某个通过身份校验" "$(nt_val "$d" mode)" "$NT_WORK/bin/su shell /system/bin/sh -c"
  t_eq "前两个候选都被试过（空手退出不算可用）" "$(nt_val "$d" attempts)" "5"
  t_eq "第三个候选是带 /system/bin/sh 的那种写法" "$(nt_val "$d" last)" "shell /system/bin/sh -c id -u"
}

# ============================================================
# 二、事件名 → tag 与文案：业务层只报事件名，映射表才是唯一真源
#
# 事件名清单直接从 notify 层的映射表里读出来（不在测试里另抄一份）：
# 表里加了事件却忘了文案，下面的断言会报红。
# ============================================================

nt_case_map() {
  local d tag
  nt_setup map
  nt_run map <<'DRIVER'
# 事件名清单从**真实源码的映射表**里读出来，逐个驱动
for m in $(grep -o '_NT_TPL_[A-Za-z0-9_][A-Za-z0-9_]*' "$T_ROOT/lib/notify.sh" | sort -u); do
  ev=${m#_NT_TPL_}
  _NT_TITLE=""; _NT_TEXT=""
  notify_event "$ev"
  printf '%s\t%s\t%s\n' "$ev" "$_NT_TITLE" "$_NT_TEXT" >> "$T_WORK/msg.txt"
done
DRIVER
  d="$NT_WORK/msg.txt"
  t_lines "九个业务事件的文案都取到了" "$d" 9
  # 判定用正则而不是写死制表符：文案表的「事件 ⇥ 标题 ⇥ 正文」逐字比对在这里，
  # 但不该因为排版（空格量）变化制造假红灯
  t_has_re "A1 标题" "$d" '^sign[	 ]+✅ 查寝签到成功'
  t_has_re "A2 标题" "$d" '^supp[	 ]+🕘 已补签'
  t_has_re "B 标题" "$d" '^seen[	 ]+✅ 今日已签到'
  t_has_re "C 标题" "$d" '^leave[	 ]+🏖 今日查寝已请假'
  t_has_re "D 标题" "$d" '^failsign[	 ]+⚠️ 查寝签到失败'
  t_has_re "E 标题" "$d" '^failtask[	 ]+⚠️ 拿不到查寝任务'
  t_has_re "F1 标题（22:00 还剩 30 分钟）" "$d" '^nosign[	 ]+⏰ 尚未签到，主窗口还剩 30 分钟'
  t_has_re "F2 标题（22:30 进入补签）" "$d" '^late[	 ]+⏰ 主窗口已过，进入补签时段'
  t_has_re "F3 标题（23:00 未能签到）" "$d" '^miss[	 ]+❌ 今晚未能自动签到'
  t_has "A1 正文含日期" "$d" "20261001 已签到（晚查寝签到）"
  t_has "F3 正文逐字不变" "$d" "20261001 23:00 重试结束仍未签到，请手动处理"
  # 文案不得出现任何分数/扣分字样（用户明确要求：不替用户判断补签的得失）。
  # 「30 分钟」里的「分」是时间单位，故只匹配真正的计分表述。
  if grep -qE '得分|扣分|计分|加分|满分|少得|[0-9] *分[^钟]' "$d" 2>/dev/null; then
    _t_fail "文案不含任何分数/扣分表述（出现了计分写法）"
  else
    _t_pass "文案不含任何分数/扣分表述"
  fi

  # tag 表：十个业务事件都拼得出 tag，且命令串逐字保留那三段（缺一个就是该类提醒静默失效）
  nt_setup tag
  nt_run tag <<'DRIVER'
nt_send() { printf '%s\n' "$1" >> "$T_WORK/tag.log"; }
for ev in sign supp seen leave failsign failtask nosign late miss; do
  notify_event "$ev"
done
DRIVER
  d="$NT_WORK/tag.log"
  t_lines "九个业务事件都拼出了 tag" "$d" 9
  for tag in $NT_TAGS; do
    case "${tag%%:*}" in
      warn|test) : ;;                 # 这两个没有文案模板，由各自的调用方驱动（见下）
      *) t_has "事件 ${tag%%:*} 的 tag 为 fafu-${tag##*:}-\$PL" "$d" "fafu-${tag##*:}-20261001" ;;
    esac
  done
  t_has "命令为 cmd notification post" "$d" 'notification post'
  t_has "使用 bigtext 样式" "$d" '-S bigtext'
  t_has "标题保留给子 shell 展开" "$d" '$_NT_TITLE'
  t_has "正文回退写法保留" "$d" '${_NT_TEXT:-$_NT_TITLE}'
  # sign 与 seen 用同一个 tag：同日重复检测到已签到时互相覆盖，通知栏不堆积；
  # 这两个 tag 相同是**对外契约**，不是巧合
  t_has "seen 与 sign 同 tag" "$d" "fafu-sign-20261001" 2

  # warn 与 test 的 tag 由各自的真实调用方驱动：它们不在业务事件表里，但同样要按日滚动。
  # 标题与正文直接取发送时的那两个变量（命令串里存的是给子 shell 展开的写法）
  nt_setup tagsrc
  nt_run tagsrc <<'DRIVER'
nt_send() { printf '%s\n' "$1" >> "$T_WORK/tag.log"; printf '%s\t%s\n' "$_NT_TITLE" "$_NT_TEXT" >> "$T_WORK/msg.log"; }
WAS_ON=1
notify_warn
cmd_notify >/dev/null 2>&1
DRIVER
  d="$NT_WORK/tag.log"
  t_has "预警（keepalive 调用方）的 tag" "$d" "fafu-warn-20261001"
  t_has "测试通知（notify 子命令）的 tag" "$d" "fafu-test-20261001"
  d="$NT_WORK/msg.log"
  t_has "预警标题" "$d" "🔄 正在刷新登录状态"
  t_has "预警正文含提前量" "$d" "5 秒后自动打开打卡页"
  t_has "测试通知的标题" "$d" "🔔 通知测试"
}

# ============================================================
# 三、每日一次：当日一次、发送失败不落标记（否则一次瞬时失败=整天不再提醒）
# ============================================================

nt_case_once() {
  local d
  nt_setup once
  nt_run once <<'DRIVER'
nt_send() { printf '%s\n' "$1" >> "$T_WORK/cmd.log"; }
printf 'first=%s\n'  "$(notify_once miss; echo $?)"
printf 'second=%s\n' "$(notify_once miss; echo $?)"
printf 'calls=%s\n'  "$(grep -c . "$T_WORK/cmd.log")"
# 发送失败：命令必然失败 → 返回非 0 且不落当日标记（下一次还能再试）
rm -f mod/.fafu_notify_miss
nt_send() { return 1; }
printf 'fail_rc=%s\n' "$(notify_once miss; echo $?)"
printf 'fail_mark=%s\n' "$(notify_marked miss && echo marked || echo no)"
# 未知事件名：不发送、不落标记（写错名字不该把标记烧掉）
nt_send() { printf '%s\n' "$1" >> "$T_WORK/cmd.log"; }
printf 'unknown=%s\n' "$(notify_once tsil; echo $?)"
printf 'unknown_mark=%s\n' "$(notify_marked tsil && echo marked || echo no)"
DRIVER
  d="$NT_WORK/once.out"
  t_eq "首次：发出去并返回 0" "$(nt_val "$d" first)" "0"
  t_eq "当日第二次：不再发（返回 0）" "$(nt_val "$d" second)" "0"
  t_eq "当日只发了一条命令" "$(nt_val "$d" calls)" "1"
  t_eq "发送失败：返回非 0" "$(nt_val "$d" fail_rc)" "1"
  t_eq "发送失败：不落当日标记（可再试）" "$(nt_val "$d" fail_mark)" "no"
  t_eq "未知事件名：不发送（返回 0）" "$(nt_val "$d" unknown)" "0"
  t_eq "未知事件名：不落标记" "$(nt_val "$d" unknown_mark)" "no"

  # 四个「当日一次」事件各自的标记：三个未签时点必须各有独立标记
  # （共用标记会让 22:00 那条把 23:00 那条永久挡住）；两个失败类共用同一个
  nt_setup marks
  nt_run marks <<'DRIVER'
nt_send() { printf '%s\n' "$1" >> "$T_WORK/cmd.log"; }
for e in failsign failtask nosign late miss; do
  printf 'sent_%s=%s\n' "$e" "$(notify_once "$e"; echo $?)"
done
printf 'markfile=%s\n' "$(ls -a mod | grep '^\.fafu_notify_' | tr '\n' ' ')"
for e in fail nosign late miss; do
  printf '%s=%s\n' "$e" "$(notify_marked "$e" && echo marked || echo no)"
done
DRIVER
  d="$NT_WORK/marks.out"
  t_eq "failsign 首次发送成功" "$(nt_val "$d" sent_failsign)" "0"
  t_eq "nosign 首次发送成功" "$(nt_val "$d" sent_nosign)" "0"
  t_eq "miss 首次发送成功" "$(nt_val "$d" sent_miss)" "0"
  for e in fail nosign late miss; do
    t_eq "$e 已落当日标记" "$(nt_val "$d" "$e")" "marked"
  done
  t_eq "失败类共用一个标记、三个时点各自独立" \
    "$(nt_val "$d" markfile)" ".fafu_notify_fail .fafu_notify_late .fafu_notify_miss .fafu_notify_nosign "
}

# ============================================================
# 四、打扰冷却：基准落盘、冷却窗口内不发
#
# 冷却是「与上一次的实际时间比较」，故夹具按**相对时间**算（提前若干秒）：
# 写死某个绝对时刻的测试会在那个时刻真的到来之后自己变红。
# ============================================================

nt_case_cooldown() {
  local d
  nt_setup warn
  nt_run warn <<DRIVER
nt_send() { printf '%s\n' "\$1" >> "\$T_WORK/cmd.log"; printf '%s\t%s\n' "\$_NT_TITLE" "\$_NT_TEXT" >> "\$T_WORK/msg.log"; }
WAS_ON=1
nt_cooldown "\$(( \$(now_s) - 600 ))"     # 上次打扰在 10 分钟前 → 早该放行
printf 'first=%s\n'  "\$( (notify_warn; echo \$?) )"
printf 'adv=%s\n'    "\$(( \$(nt_cooldown) - \$(now_s) ))"
printf 'calls=%s\n'  "\$(grep -c . "\$T_WORK/cmd.log")"
printf 'cmd=%s\n'    "\$(cat "\$T_WORK/cmd.log")"
printf 'second=%s\n' "\$( (notify_warn; echo \$?) )"
printf 'calls2=%s\n' "\$(grep -c . "\$T_WORK/cmd.log")"
WAS_ON=0
printf 'lead_dark=%s\n' "\$(notify_lead)"
DRIVER
  d="$NT_WORK/warn.out"
  t_eq "冷却已过期：预警发出去（返回 0）" "$(nt_val "$d" first)" "0"
  t_eq "预警发了一条命令" "$(nt_val "$d" calls)" "1"
  t_has "预警 tag" "$d" "fafu-warn-20261001"
  t_has "预警标题" "$NT_WORK/msg.log" "🔄 正在刷新登录状态"
  t_has "预警正文含提前量" "$NT_WORK/msg.log" "5 秒后自动打开打卡页"
  t_has_re "冷却基准被写到现在（不是回写旧值）" "$d" '^adv=-?[0-2]$'
  t_eq "冷却窗口内：不再发（返回非 0）" "$(nt_val "$d" second)" "1"
  t_eq "冷却窗口内：命令数没变" "$(nt_val "$d" calls2)" "1"
  t_eq "熄屏（WAS_ON=0）：提前量为 0" "$(nt_val "$d" lead_dark)" "0"
}

# 「这次到底发没发」的返回值：调用方（keepalive）据此决定要不要留出阅读时间。
# sleep 只能排在返回 0 的分支上，等价于「发了才等」——否则通知关闭 / 降权不可用 /
# 冷却期内的每次亮屏刷新都会白等 5 秒。
nt_case_warn_return() {
  local d
  nt_setup warnret
  nt_run warnret <<'DRIVER'
nt_send() { printf '%s\n' "$1" >> "$T_WORK/cmd.log"; }
WAS_ON=1
nt_cooldown 0
printf 'sent=%s\n'     "$( (notify_warn; echo $?) )"        # 冷却已过 → 发了 → 0
printf 'cooling=%s\n'  "$( (notify_warn; echo $?) )"        # 同一秒再调 → 冷却挡住 → 非 0
NOTIFY=0
nt_cooldown 0
printf 'off=%s\n'      "$( (notify_warn; echo $?) )"        # 通知关闭 → 非 0
NOTIFY=1; SU_MODE=""
nt_cooldown 0
printf 'nosu=%s\n'     "$( (notify_warn; echo $?) )"        # 降权不可用 → 非 0
printf 'calls=%s\n'    "$(grep -c . "$T_WORK/cmd.log")"
DRIVER
  d="$NT_WORK/warnret.out"
  t_eq "真发了 → 返回 0（调用方才 sleep）" "$(nt_val "$d" sent)" "0"
  t_eq "冷却挡住 → 非 0（不该白等）" "$(nt_val "$d" cooling)" "1"
  t_eq "通知关闭 → 非 0" "$(nt_val "$d" off)" "1"
  t_eq "降权不可用 → 非 0" "$(nt_val "$d" nosu)" "1"
  t_eq "四次调用只发出一条命令" "$(nt_val "$d" calls)" "1"
}

# 冷却基准的落盘：在**子 shell** 里发预警（refresh_token 就是这么调它的），
# 基准必须写到 state 层的文件上才可能在下次调用时还生效
nt_case_cooldown_persist() {
  local d
  nt_setup persist
  nt_run persist <<DRIVER
nt_send() { printf '%s\n' "\$1" >> "\$T_WORK/cmd.log"; }
WAS_ON=1
past="\$(( \$(now_s) - 600 ))"
nt_cooldown "\$past"
( notify_warn ) >/dev/null
printf 'file=%s\n'  "\$(cat mod/.fafu_notify_last | tr -d '\n')"
printf 'sub=%s\n'   "\$( (nt_cooldown) )"
printf 'stale=%s\n' "\$(( \$(nt_cooldown) - past ))"
printf 'again=%s\n' "\$( (notify_warn; echo \$?) )"
printf 'calls=%s\n' "\$(grep -c . "\$T_WORK/cmd.log")"
DRIVER
  d="$NT_WORK/persist.out"
  t_eq "基准在子 shell 里读得回（不是内存变量）" "$(nt_val "$d" sub)" "$(nt_val "$d" file)"
  t_has_re "基准被推进到现在（晚于上次打扰 600 秒）" "$d" '^stale=60[0-2]$'
  t_eq "紧接着的第二次预警被冷却挡住" "$(nt_val "$d" again)" "1"
  t_eq "冷却期内只发出过一条命令" "$(nt_val "$d" calls)" "1"
}

# 相对顺序不变量：**预警必须排在打开打卡页之前**。
# 用真实 refresh_token 跑（只替换 token 来源与 sleep），预警与设备命令一起按发生顺序
# 落进同一条 trace —— 数的是**实际调用顺序**，把被测对象整体 stub 掉时 trace 会塌成空。
nt_case_warn_order() {
  local d
  nt_setup dv
  # 这份工作目录里再放上设备命令替身（真机上 am / dumpsys 同样在 /system/bin 下）：
  # 前导里的 PATH='./bin:...' 正好命中 dv_tools 写的那些包装器。
  # DV_WORK 必须在 nt_setup 之后取——那之前 NT_WORK 还是上一条用例的目录
  DV_WORK="$NT_WORK"
  dv_tools
  nt_run order <<DRIVER
# 通知与设备命令落进**同一条时间线**：跨进程的先后只有共享一个记录文件才可比
nv="\$T_WORK/device-commands"
MOCK_DEVICE_LOG="\$nv"
export MOCK_DEVICE_LOG
nt_send() { printf 'notify %s\n' "\$1" >> "\$nv"; }
get_token() { echo NEW; }
sleep() { :; }
# 先自检设备命令替身接得住（接不住时下面的顺序断言会是空转）
am start -n a/b >/dev/null 2>&1
printf 'selftest=%s\n' "\$(grep -c 'device am' "\$nv")"
: > "\$nv"
refresh_token OLD >/dev/null
# 时间线逐行输出（t_before 比的是行号）：每行一个事件，先通知后开页就一目了然
printf 'timeline:\n'
cat "\$nv"
printf 'opens=%s\n' "\$(grep -c 'device am' "\$nv")"
DRIVER
  d="$NT_WORK/order.out"
  t_ne "设备命令替身接得住（自检）" "$(nt_val "$d" selftest)" "0"
  t_ne "开页确实发生了（否则下面的顺序断言是空转）" "$(nt_val "$d" opens)" "0"
  # 相对顺序不变量：**预警必须排在打开打卡页之前**。
  # 同一条时间线上先出现通知、后出现开页（device am），就是这个顺序的证据。
  # 每一行一个事件，故 t_before 比的行号就是真实先后。
  t_before "预警排在打开打卡页之前" "$d" 'notify cmd notification post' 'device am'
  t_has "时间线里有开页（device am）" "$d" 'device am'
}

# ============================================================
# 五、静默跳过：降权不可用 / 通知关闭时一律零调用
# ============================================================

nt_case_silent() {
  local d
  nt_setup silent
  nt_run silent <<'DRIVER'
nt_send() { printf '%s\n' "$1" >> "$T_WORK/cmd.log"; }
WAS_ON=1
nt_cooldown 0
# 降权不可用（SU_MODE 为空）→ 三条路径都零调用
SU_MODE=""
printf 'e=%s\n' "$(notify_event miss; echo $?)"
printf 'o=%s\n' "$(notify_once miss; echo $?)"
printf 'w=%s\n' "$(notify_warn; echo $?)"
printf 'calls=%s\n' "$(grep -c . "$T_WORK/cmd.log" 2>/dev/null || echo 0)"
printf 'mark=%s\n'  "$(notify_marked miss && echo marked || echo no)"
# 通知整体关闭 → 同样零调用
SU_MODE="su - shell -c"; NOTIFY=0
printf 'e_off=%s\n' "$(notify_event miss; echo $?)"
printf 'o_off=%s\n' "$(notify_once miss; echo $?)"
printf 'w_off=%s\n' "$(notify_warn; echo $?)"
printf 'calls_off=%s\n' "$(grep -c . "$T_WORK/cmd.log" 2>/dev/null || echo 0)"
DRIVER
  d="$NT_WORK/silent.out"
  t_eq "降权不可用：通知类事件静默跳过（返回 0）" "$(nt_val "$d" e)" "0"
  t_eq "降权不可用：当日一次的通知也静默跳过" "$(nt_val "$d" o)" "0"
  t_eq "降权不可用：预警报「没发」（非 0，调用方不该等）" "$(nt_val "$d" w)" "1"
  t_eq "降权不可用：一条命令都没有" "$(nt_val "$d" calls)" "0"
  t_eq "降权不可用：不落当日标记" "$(nt_val "$d" mark)" "no"
  t_eq "通知关闭：零调用（事件）" "$(nt_val "$d" e_off)" "0"
  t_eq "通知关闭：零调用（当日一次）" "$(nt_val "$d" o_off)" "0"
  t_eq "通知关闭：预警报「没发」（非 0）" "$(nt_val "$d" w_off)" "1"
  t_eq "通知关闭：命令总数仍为 0" "$(nt_val "$d" calls_off)" "0"
}

# ============================================================
# 六、能力收口（静态）：业务层不再自己拼 tag，也不再自己发通知
#
# 判据只用**能力名**与**命令位**，不绑行号、也不绑局部变量名——
# 谁改了调用方式、谁绕过了这一层，都会在这里报红。
# ============================================================

NT_CAPS="tag_of:notify probe_su:notify nt_send:notify notify:notify notify_event:notify notify_once:notify notify_warn:notify notify_lead:notify"
NT_LAYERS="signin keepalive commands"

nt_case_boundary() {
  local src f cap owner miss all
  NT_WORK="$T_WORK_ROOT/notify-boundary"
  mkdir -p "$NT_WORK"
  src="$NT_WORK/program.sh"
  t_write_program "$src" || { _t_fail "无法拼出全程序文本"; return 0; }

  # 通知的八个能力只有 notify 层定义（能力名 = 函数的唯一真源，改名会在这里报红）
  miss=""
  for cap in $NT_CAPS; do
    owner=""
    for f in $TEST_LIB_FILES; do
      if grep -qE "^[ 	]*${cap%%:*}[ 	]*\(\)" "$T_ROOT/$f" 2>/dev/null; then owner="${f##*/}"; fi
    done
    [ "$owner" = "${cap##*:}.sh" ] || miss="$miss $cap→${owner:-无}"
  done
  t_eq "通知能力全部定义在 notify 层" "[$miss]" "[]"

  # tag 只在 notify 层拼：业务层说事件名，进 notify 层的 tag 由 tag_of 拼出。
  # 唯一豁免是 commands 层的 notify 子命令（它发的就是测试通知，不属于业务事件表）
  all=""
  for f in $TEST_LIB_FILES; do
    if grep -qF 'fafu-$(tag_of' "$T_ROOT/$f" 2>/dev/null; then all="$all ${f##*/}"; fi
  done
  t_eq "tag 拼法只在 notify 层（外加测试通知）" "[$all]" "[ notify.sh commands.sh]"
  t_has "notify 层经 tag_of 拼 tag" "$T_ROOT/lib/notify.sh" 'fafu-$(tag_of'
  # 事件名（而不是 tag）才是业务层与 notify 层的接口
  for f in signin keepalive; do
    t_hasnt "$f 层只报事件名（不出现 tag 拼接）" "$T_ROOT/lib/$f.sh" 'tag_of'
  done

  # 发送命令逐字只有一处，且只在 notify 层（注释里提到它不算）
  all=""
  for f in $TEST_LIB_FILES; do
    if grep -qE '^[ 	]*t="cmd notification post' "$T_ROOT/$f" 2>/dev/null; then all="$all ${f##*/}"; fi
  done
  t_eq "命令位的 cmd notification post 只在 notify 层" "[$all]" "[ notify.sh]"

  # 打扰冷却只由 notify 层判定：冷却基准的**读写**只出现在 notify 层
  # （state 层只持有 nt_cooldown 的实现，它不参与「要不要发」的判断）
  all=""
  for f in $TEST_LIB_FILES fafu_checkin.sh; do
    if grep -qE 'nt_cooldown[ 	]' "$T_ROOT/$f" 2>/dev/null; then all="$all ${f##*/}"; fi
  done
  t_eq "冷却基准只由 notify 层读写，判定也在这一层" "[$all]" "[ notify.sh]"
  t_hasnt "keepalive 层不再自己判冷却" "$T_ROOT/lib/keepalive.sh" 'NOTIFY_COOLDOWN'
  t_hasnt "keepalive 层不再自己设文案" "$T_ROOT/lib/keepalive.sh" '_NT_TITLE'
  t_has "keepalive 层经 notify_warn 发预警" "$T_ROOT/lib/keepalive.sh" 'notify_warn'
  # 业务层不直接落标记：标记只由 notify 层在发送成功后写
  for f in signin keepalive; do
    t_hasnt "$f 层不直接落标记（经 notify 层）" "$T_ROOT/lib/$f.sh" 'notify_mark '
  done

  # 文案表：正文不含引号与命令替换（含了会破坏 su 的引号配对，是本功能最容易写错的地方）
  if grep -nE '^_msg_' "$T_ROOT/lib/notify.sh" 2>/dev/null | grep -qE "_NT_TEXT=.*['\`]"; then
    _t_fail "文案正文不含引号与命令替换（出现了引号或反引号）"
  else
    _t_pass "文案正文不含引号与命令替换"
  fi

  # 「降权探测必须在子命令分发之前」这条不变量的两条判据都在 tests/commands.sh：
  # 命令表那一趟探测（结构）与按时间顺序的记录（行为）。这里只看通知层自己的调用点还在。
  t_has "notify 层仍提供降权探测入口" "$T_ROOT/lib/notify.sh" 'probe_su() {'
}

# ============================================================
# 七、端到端形状（静态）：入口与各层的调用点仍然齐全
#
# 这一节盯的是「有没有人把调用点删掉」——调用点没了，上面所有函数级断言都还在跑，
# 但设备上那件事根本不会发生。判据只用被调用者与调用形状，不绑行号。
# ============================================================

nt_case_callsites() {
  local src miss c
  NT_WORK="$T_WORK_ROOT/notify-callsites"
  mkdir -p "$NT_WORK"
  src="$NT_WORK/program.sh"
  t_write_program "$src" || { _t_fail "无法拼出全程序文本"; return 0; }

  # 业务事件与预警的调用点：每个都必须还在。
  # 未签提醒三条（nosign / late / miss）的事件名、文案与去重机制仍在本层（上面刚验过），
  # 但它们的**调用点**要按任务数据推算时刻，随数据驱动版一起补回：
  # 在补齐之前，入口里不该再出现按写死钟点发的这三条（见 tests/poll.sh 的静态判据）。
  miss=""
  for c in 'notify_event sign'        'notify_event supp'     'notify_event seen' \
           'notify_event leave'       'notify_once failsign'  'notify_once failtask' \
           'notify_warn'              'tag_of test'; do
    grep -qF "$c" "$src" 2>/dev/null || miss="$miss [$c]"
  done
  t_eq "八个通知调用点齐全" "[$miss]" "[]"

  # 业务层不再自己发通知：signin / keepalive 里不出现底层发送与文案表
  t_hasnt "signin 层不直接调文案表" "$T_ROOT/lib/signin.sh" '_msg_'
  t_hasnt "signin 层不直接调底层发送" "$T_ROOT/lib/signin.sh" 'notify "fafu-'
  t_hasnt "keepalive 层不直接调底层发送" "$T_ROOT/lib/keepalive.sh" 'notify "fafu-'
  t_hasnt "入口不直接调底层发送" "$T_ROOT/fafu_checkin.sh" 'notify "fafu-'
}

# ---- 注册（顺序即执行顺序） ----

t_case "notify · 降权探测以身份为准" nt_case_probe
t_case "notify · 候选写法依次尝试与降级" nt_case_probe_order
t_case "notify · 事件名 → tag 与文案" nt_case_map
t_case "notify · 每日一次去重与失败不落标记" nt_case_once
t_case "notify · 打扰冷却窗口" nt_case_cooldown
t_case "notify · 冷却基准落盘（子 shell 内）" nt_case_cooldown_persist
t_case "notify · 预警返回值与调用方的等待" nt_case_warn_return
t_case "notify · 预警排在打开打卡页之前" nt_case_warn_order
t_case "notify · 静默跳过（降权不可用 / 通知关闭）" nt_case_silent
t_case "notify · 能力收口与相对顺序（静态）" nt_case_boundary
t_case "notify · 调用点齐全（静态）" nt_case_callsites
