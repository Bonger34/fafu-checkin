#!/system/bin/sh
# ============================================================
# 设备冒烟 —— 装一次后走完四条手动命令，并把往返证据落盘
#
# 用法（设备上以 root 执行：KernelSU / Magisk 管理器的 shell，或任一带 root 的终端）：
#   sh /sdcard/Download/device-smoke.sh
#
# 输出：边跑边写 /sdcard/Download/fafu-smoke-<时间戳>.txt（终端中途被回收也留得下已跑的部分）
# 配置：M=<模块目录>（默认 /data/adb/modules/fafu-checkin）；WAIT_KA=0 跳过保活等待
# ============================================================

M="${M:-/data/adb/modules/fafu-checkin}"
E="$M/fafu_checkin.sh"
LOG="$M/fafu_checkin.log"
OUT="/sdcard/Download/fafu-smoke-$(date '+%Y%m%d-%H%M%S').txt"
WAIT_KA="${WAIT_KA:-1000}"         # 等下一个保活节拍的上限（秒）：节拍间隔 15 分钟，
                                   # 脚本可能刚好在其后起跑，故留到 17 分钟才算超时
export M E WAIT_KA OUT

# 报告正文：单独一段，由外层用 `sh -c` 跑并把 stdout 边跑边 tee 进证据文件。
# 结论（失败项数）走 $OUT.rc 旁路文件：管道之后 $? 是 tee 的，拿不到本段的退出码。
BODY=$(cat <<'BODY'
FAILED=0; NOTES=0
say() { echo "$@"; }
sect() { echo ""; echo "==================== $* ===================="; }
ok() { say "  ✅ $*"; }
bad() { say "  ❌ $*"; FAILED=$((FAILED + 1)); }
note() { say "  ⚠️ $*"; NOTES=$((NOTES + 1)); }
# expect <文本> <正则> <说明>：文本为空只记提醒——「命令没输出」不等于「命令坏了」，
# 空输出是否算失败由调用点自己另判
expect() {
  case "$1" in
    "") note "$3：命令没有输出（该分支无 stdout，需看日志判定）" ;;
    *) if printf '%s\n' "$1" | grep -qE "$2"; then ok "$3"; else bad "$3（输出里没有匹配 /$2/）"; fi ;;
  esac
}
# forbid <文本> <正则> <说明>：出现即失败（明确的失败文案）
forbid() {
  case "$1" in
    "") ok "$3" ;;
    *) if printf '%s\n' "$1" | grep -qE "$2"; then bad "$3（出现了 /$2/）"; else ok "$3"; fi ;;
  esac
}
has() { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3（未出现：$2）" ;; esac; }
run() { # $1=命令名：把「时刻 + 退出码 + 输出」记进报告，输出留在 OUT_LAST
  CMD_TS=$(date '+%Y-%m-%d %H:%M:%S')
  OUT_LAST=$(sh "$E" "$1" 2>&1)
  CMD_RC=$?
  say "--- \$ sh fafu_checkin.sh $1   [rc=$CMD_RC, $CMD_TS]"
  say "$OUT_LAST"
}
ka_count() { grep -ac '保活' "$LOG" 2>/dev/null; }
# 现在几点（当日第几分钟）：只看当前时刻，不读模块的任何状态
smoke_now_minutes() { date '+%H %M' | { read -r h m; echo $((h * 60 + m)); }; }
desc_line() { printf '%s\n' "$1" | grep -a '^描述:' | head -n1; }
# 开关状态只从 `status` 的输出读（运行时状态文件只有 state 层与开机脚本碰，
# 冒烟脚本不该成为第三个读它的地方——同一个事实两个真源迟早会说法不一）
enabled_now() {
  case "$(desc_line "$(sh "$E" status 2>&1)")" in
    *"已启用"*) return 0 ;;
    *) return 1 ;;
  esac
}

if [ "$(id -u)" != "0" ]; then
  say "本脚本要在 root 下跑（模块目录 /data/adb 读不了）—— 请用带 root 的 shell 重跑。"
  echo "RESULT=1"
  exit 1
fi

sect "0 · 前置：模块目录与层文件"
say "模块目录: $M"
say "版本: $(sed -n 's/^version=//p' "$M/module.prop" 2>/dev/null)"
say "--- 目录内容"
ls -l "$M" 2>&1 | sed 's/^/    /'
say "--- 层文件与权限"
LS_OUT=$(ls -l "$M/lib" 2>&1)
say "$LS_OUT"
WANT=$(sed -n 's/^[ 	]*FAFU_LAYERS="\([^"]*\)".*$/\1/p' "$E" | head -n1 | wc -w | tr -d ' ')
N=$(ls "$M/lib" 2>/dev/null | wc -l | tr -d ' ')
if [ "$N" = "$WANT" ]; then ok "lib/ 里 $N 个层文件，与入口 FAFU_LAYERS 的 $WANT 个一致"
else bad "lib/ 里 $N 个层文件，入口声明了 $WANT 个"; fi
BADSYM=$(printf '%s\n' "$LS_OUT" | grep -c '^l')
if [ "$BADSYM" = "0" ]; then ok "lib/ 里没有符号链接"; else bad "lib/ 里有 $BADSYM 个符号链接"; fi
BADMODE=$(printf '%s\n' "$LS_OUT" | grep -c '^-rw-------')
if [ "$BADMODE" = "0" ]; then ok "层文件权限没有被收成 600"; else bad "有 $BADMODE 个层文件权限为 600"; fi

sect "1 · 启动与安装完整性"
LOG_ALL=$(cat "$LOG" 2>/dev/null)
has "$LOG_ALL" "服务启动" "日志里有启动行"
case "$LOG_ALL" in
  *"模块不完整"*) bad "日志里有「模块不完整」" ;;
  *) ok "日志里没有「模块不完整」" ;;
esac
case "$LOG_ALL" in
  *"缺少库层"*) bad "日志里有「缺少库层」" ;;
  *) ok "日志里没有「缺少库层」" ;;
esac
START_LINE=$(printf '%s\n' "$LOG_ALL" | grep -a '服务启动' | tail -n 1)
say "  最近一条启动行: $START_LINE"
case "$START_LINE" in
  *"notify=[不可用]"*)
    note "启动行里 notify=[不可用]：daemon 进程没拿到降权写法（由此进程发出的通知会静默跳过）" ;;
  *"notify=["*) ok "启动行带降权探测结果" ;;
  *) bad "启动行里没有 notify=[...] 字段" ;;
esac
PROBE_LINE=$(printf '%s\n' "$LOG_ALL" | grep -a '通知链路' | tail -n 1)
say "  最近一条探测日志: $PROBE_LINE"
case "$PROBE_LINE" in
  *"可用（id -u = 2000）"*) ok "降权探测成功过（手动命令路径）" ;;
  *"降权不可用"*) bad "降权探测失败：候选写法均未通过 id 校验" ;;
  *) note "日志里还没有降权探测记录" ;;
esac

sect "2 · 四条手动命令"
BEFORE_KA=$(ka_count)
run status
STATUS_OUT="$OUT_LAST"
has "$STATUS_OUT" "开关:" "status：有开关状态"
has "$STATUS_OUT" "服务:" "status：有服务状态"
has "$STATUS_OUT" "描述:" "status：有描述预览"
expect "$STATUS_OUT" "token: 有效" "status：token 可用"
forbid "$STATUS_OUT" "未找到（应用未安装或未登录过）" "status：没有落到「未找到 token」"

run notify
expect "$OUT_LAST" "已发送" "notify：通知已交给系统发送"
forbid "$OUT_LAST" "降权不可用" "notify：降权可用"
say "  ↑ 是否**真的到达**只能目视：通知栏要出现「🔔 通知测试」（rc=0 不作数）"

run once
# once 的输出有三种正常形态（且「已请假」/「不在时段」这类分支本来就只写日志）。
# 判定看的是「有没有明确的失败文案」，而不是「有没有输出」。
forbid "$OUT_LAST" "获取任务失败|签到失败|未检测到应用数据" "once：没有出现失败文案"
case "$OUT_LAST" in
  *"已签"*) ok "once：当日签到已了结" ;;
  "") note "once：无输出（该分支只写日志，签到状态以上面的 status 为准）" ;;
  *) note "once：输出为「$OUT_LAST」（命令跑通，当日状态不同）" ;;
esac

run toggle
TOGGLE_OUT="$OUT_LAST"
expect "$TOGGLE_OUT" "服务已(启用|停用)" "toggle：开关切换有回显"
if enabled_now; then  ok "toggle：开关已从「停用」切到「已启用」（原状态是停用）"
else
  note "toggle：开关现在是「已停用」——本次是从启用切过去的，下面会恢复"
fi

sect "3 · 恢复启用状态"
if enabled_now; then
  ok "开关已是「已启用」，无需恢复"
else
  run enable
  expect "$OUT_LAST" "服务已启用" "enable：已恢复启用"
fi
SAVE_OUT=$(sh "$E" status 2>&1)
has "$SAVE_OUT" "开关: 🟢 已启用" "收尾：开关是「已启用」"
expect "$SAVE_OUT" "服务: 运行中" "收尾：守护进程在跑"

sect "4 · 动态描述"
DESC_NOW=$(desc_line "$SAVE_OUT")
say "status 里的描述: ${DESC_NOW:-（无）}"
D_KSU=$(ksud module config get fafu-checkin override.description 2>/dev/null)
say "ksud override.description: ${D_KSU:-（空 / ksud 不在 PATH）}"
say "module.prop description:   $(sed -n 's/^description=//p' "$M/module.prop" 2>/dev/null)"
if [ -n "$D_KSU" ]; then
  DESC="$D_KSU"
  say "（判定以 ksud 覆盖值为准——管理器显示的就是它）"
else
  DESC="$DESC_NOW"
  say "（ksud 读不到，判定以 status 里的描述为准；module.prop 是被安装包固定的静态文案，"
  say "  只有 Magisk 回退路径才会改写它）"
fi
case "$DESC" in
  *"已启用"*|*"已停用"*) ok "描述里有开关状态" ;;
  *) bad "描述里没有开关状态：$DESC" ;;
esac
case "$DESC" in
  *"已签到"*|*"已请假"*|*"未签到"*) ok "描述里有签到日期时间" ;;
  *) note "描述里没有签到日期时间：$DESC" ;;
esac

sect "5 · 保活"
say "日志里最近一条保活: $(grep -a '保活' "$LOG" 2>/dev/null | tail -n 1)"
say "本轮 status 之前的保活记录数: $BEFORE_KA"
say "--- 手动保活一次（验链路，不替代 15 分钟节拍）"
run keepalive
expect "$OUT_LAST" "token 有效" "keepalive：token 可用"
AFTER_KA=$(ka_count)
say "现在的保活记录数: $AFTER_KA"
if [ "$AFTER_KA" -gt "$BEFORE_KA" ]; then
  ok "手动保活往日志里落了一条"
else
  note "手动保活没让保活记录数增加（看日志原文）"
fi
if [ "${WAIT_KA:-1000}" -gt 0 ]; then
  say "--- 等下一个 15 分钟节拍（上限 ${WAIT_KA}s；已存在的保活记录不算数）"
  WAITED=0
  HIT=0
  while [ "$WAITED" -lt "$WAIT_KA" ]; do
    sleep 30
    WAITED=$((WAITED + 30))
    if [ "$(ka_count)" -gt "$AFTER_KA" ]; then HIT=1; break; fi
  done
  if [ "$HIT" = "1" ]; then
    ok "第 $((WAITED / 60)) 分钟内出现新的保活记录：$(grep -a '保活' "$LOG" | tail -n 1)"
  elif [ "$(smoke_now_minutes)" -lt 420 ] || [ "$(smoke_now_minutes)" -ge 1285 ]; then
    note "不在保活窗口（07:00~21:25）内，等不到新节拍是设计使然"
  else
    # 窗口内等了整整一个节拍周期还没有新记录 = 保活没按节拍跑，这必须算失败
    bad "在保活窗口内等了 ${WAIT_KA}s 仍无新的保活记录"
  fi
else
  say "（WAIT_KA=0，跳过 15 分钟节拍等待）"
fi

sect "6 · 日志（最近 40 行）"
tail -n 40 "$LOG" 2>/dev/null | sed 's/^/    /'
say "    （完整日志：$LOG）"

sect "结果"
if [ "$FAILED" -eq 0 ]; then say "脚本侧：没有失败项（另有 $NOTES 条提醒）"; else say "脚本侧：$FAILED 项失败（另有 $NOTES 条提醒），见上面的 ❌"; fi
say "复核对象：$M（$(sed -n 's/^version=//p' "$M/module.prop" 2>/dev/null)）"
# 退出码走管道后拿不回来（管道的 $? 是 tee 的），故落一个旁路文件；它也不进报告正文
printf '%s\n' "$FAILED" > "$OUT.rc"
exit "$FAILED"
BODY
)
# 结论既进证据文件也进屏幕。报告**边跑边写**：`sh -c "$BODY" | tee -a "$OUT"` 是流式的，
# 于是终端中途被回收也留得下已经跑完的部分——攒到最后一次性写盘，出事就什么都不剩。
printf 'fafu-checkin 设备冒烟 · %s\n设备: %s / Android %s / SDK %s\n身份: uid=%s\n入口: %s\n\n' \
  "$(date '+%Y-%m-%d %H:%M:%S %Z')" \
  "$(getprop ro.product.model)" "$(getprop ro.build.version.release)" "$(getprop ro.build.version.sdk)" \
  "$(id -u)" "$E" | tee "$OUT"
sh -c "$BODY" 2>&1 | tee -a "$OUT"
RC=$(cat "$OUT.rc" 2>/dev/null)
[ -n "$RC" ] || RC=1
if [ "$RC" -eq 0 ]; then
  VERDICT="结论: 脚本侧没有失败项（通知到达与否仍需目视确认）"
else
  VERDICT="结论: 有 $RC 项失败（见报告里的 ❌）"
fi
printf '\n证据文件: %s\n%s\n' "$OUT" "$VERDICT" | tee -a "$OUT"
exit "$RC"
