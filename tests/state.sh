# ============================================================
# state 层 + 描述呈现（desc）验收断言
#
# 三条口径（都是「外部可观察的行为」）：
#   1) state 层是运行时文件的唯一读写者：断言只面对它的语义函数（开关、签到记录、
#      保活统计、完成标记、通知标记、冷却基准），不再往用例里传文件路径；
#   2) 文件契约：文件名、字段名、字段顺序、内容格式逐字节断言——升级后不丢当日记录
#      靠的就是这个；跨日归零同样在这里（拨钟到第二天再读，计数必须回到 0）；
#   3) desc 层：描述文案逐字比对（绝对日期），写入只经 KernelSU 覆盖或改写模块元数据，
#      且写入前的非空校验必须拦住「把 module.prop 清空」。
#
# 断言直接加载真实的层文件（tests/harness.sh 的 TEST_LIB_FILES），
# 不放源码片段、不绑行号：搬代码不该制造假红灯，行为变了才该红。
# ============================================================

ST_WORK="$T_WORK_ROOT/state"

# 模块目录、busybox 替身与时钟控制文件：**相对 $ST_WORK**（st_run 会先 cd 过去）。
# 见 st_write_env 的说明——本机绝对路径喂不进 sh。
ST_MODDIR="./mod"
ST_BB="./bin/bb"
ST_CLOCK="./clock"

# 每个用例自备环境：mock busybox（可拨钟）+ 一个模块目录 + 一份 module.prop。
# 时钟固定 2026-10-03 21:30，用例改 $ST_WORK/clock 即可跨日。
st_setup() {
  rm -rf "$ST_WORK"
  mkdir -p "$ST_WORK/mod"
  t_bb_wrap "$ST_WORK/bin/bb" >/dev/null
  printf '%s\n' '2026-10-03 21:30' > "$ST_WORK/clock"
  cat > "$ST_WORK/mod/module.prop" <<'PROP'
id=fafu-checkin
name=数字FAFU晚查寝自动签到
version=v1.2.0
versionCode=1200
author=Bonger
description=旧描述（待覆盖）
PROP
}

# 驱动脚本的公共前导：注入替身 busybox 与模块目录，再按加载顺序加载真实层文件。
# 路径一律用**相对路径**并配合 st_run 的 `cd`：Windows 上的 `D:/...` 在 sh 里不是合法路径
# （既没有根目录 /D，也会被当成分隔符切断），而运行时的目标是手机上的绝对路径，
# 所以这里刻意不把本机绝对路径喂进被测代码。
st_write_env() {
  cat > "$ST_WORK/_env.sh" <<ENV
PATH='/bin:/usr/bin'
T_ROOT='$T_ROOT'
T_WORK='$ST_WORK'
MODDIR='$ST_MODDIR'
BB_OVERRIDE='$ST_BB'
MOCK_DATE_CTL='$ST_CLOCK'
KSUD=''                     # 走非 KernelSU 回退路径（写入改写 module.prop）
export MODDIR BB_OVERRIDE MOCK_DATE_CTL KSUD
for _f in $TEST_LIB_FILES; do . "\$T_ROOT/\$_f"; done
ENV
}

# 跑一个驱动脚本；用法：st_run <名字>，主体从 stdin 读入（公共前导自动接在前面）。
# 关键：**在 $ST_WORK 里以相对路径**运行脚本，前导里的 MODDIR / BB_OVERRIDE 才是相对路径，
# 否则 Windows 上的 D:/ 绝对路径在 sh 里会被当成 /mod 这样的残缺路径。
st_run() {
  local name rc
  name="$1"
  cat > "$ST_WORK/_body.sh"
  cp "$ST_WORK/_env.sh" "$ST_WORK/$name.sh"
  cat "$ST_WORK/_body.sh" >> "$ST_WORK/$name.sh"
  ( cd "$ST_WORK" && $(t_sh) "./$name.sh" ) > "$ST_WORK/$name.out" 2> "$ST_WORK/$name.err"
  rc=$?
  echo "$rc" > "$ST_WORK/$name.rc"
  if [ -s "$ST_WORK/$name.err" ]; then
    echo "  （驱动 $name 的 stderr）"
    sed 's/^/    /' "$ST_WORK/$name.err"
  fi
}

# 从驱动输出里取一行（形如 key=value）。
# 用 cut 而不是 sed：sed 的替换串里 `&` 会展开成「整个匹配」，键名恰好含 & 时
# 或模式不匹配时会把整行原样吐回来，cut 没有这层语义。
st_val() { # $1=文件 $2=键
  grep "^$2=" "$1" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '\r\n'
}

# 某键在驱动输出里是否存在（用于区分「值为空」与「整行都没有」）
st_has_key() { # $1=文件 $2=键
  grep -q "^$2=" "$1" 2>/dev/null
}

# 夹具：把状态渲染成一行（读不到就输出 [缺失]），供 t_eq 直接比对
st_cat() { # $1=文件
  if [ -f "$1" ]; then cat "$1"; else printf '[缺失]'; fi
}

# ============================================================
# 一、开关状态
# ============================================================

st_case_switch() {
  local d
  st_setup
  st_write_env
  st_run sw <<'DRIVER'
{
  printf 'd0=%s\n'      "$(svc_is_disabled && echo yes || echo no)"
  printf 'f0=%s\n'      "$([ -f "$MODDIR/fafu-checkin.state" ] && echo yes || echo no)"
  svc_set disabled
  printf 'd1=%s\n'      "$(svc_is_disabled && echo yes || echo no)"
  printf 'fmt1=%s\n'    "$(cat "$MODDIR/fafu-checkin.state" | tr '\n' '|')"
  svc_set enabled
  printf 'd2=%s\n'      "$(svc_is_disabled && echo yes || echo no)"
  printf 'fmt2=%s\n'    "$(cat "$MODDIR/fafu-checkin.state" | tr '\n' '|')"
  printf 'tmpleft=%s\n' "$(ls "$MODDIR" | grep -c '\.tmp$')"
} > "$T_WORK/sw.txt"
DRIVER

  d="$ST_WORK/sw.txt"
  t_eq "开关缺省为启用（文件不存在也算启用）" "$(st_val "$d" d0)" "no"
  t_eq "开关缺省时不会顺手创建文件" "$(st_val "$d" f0)" "no"
  t_eq "停用后 svc_is_disabled 为真" "$(st_val "$d" d1)" "yes"
  t_eq "开关文件内容为 disabled + 换行（格式不变）" "$(st_val "$d" fmt1)" "disabled|"
  t_eq "启用后 svc_is_disabled 为假" "$(st_val "$d" d2)" "no"
  t_eq "开关文件内容为 enabled + 换行（格式不变）" "$(st_val "$d" fmt2)" "enabled|"
  t_eq "开关写入不留临时文件" "$(st_val "$d" tmpleft)" "0"
}

# ============================================================
# 二、签到记录（升级后不丢当日记录）
# ============================================================

st_case_sign() {
  local d
  st_setup
  st_write_env
  # 预置一份「旧版本写的」记录：字段名与顺序必须能被新代码原样读出来
  printf 'sign_date=2026-10-02\nsign_time=21:31\nsign_kind=normal\n' > "$ST_WORK/mod/fafu_checkin.status"
  st_run sign <<'DRIVER'
{
  printf 'old_date=%s\n' "$(sign_get sign_date)"
  printf 'old_time=%s\n' "$(sign_get sign_time)"
  printf 'old_kind=%s\n' "$(sign_get sign_kind)"
  printf 'missing=%s\n' "$(sign_get nope)"

  sign_set 2026-10-03 21:30 supplement
  printf 'new=%s\n'      "$(cat "$MODDIR/fafu_checkin.status" | tr '\n' '|')"
  printf 'new_date=%s\n' "$(sign_get sign_date)"

  # 请假记录的时间字段为空：那一行仍必须存在（顺序与字段名都不许少）
  sign_set 2026-10-03 "" leave
  printf 'leave=%s\n' "$(cat "$MODDIR/fafu_checkin.status" | tr '\n' '|')"
  printf 'tmpleft=%s\n' "$(ls "$MODDIR" | grep -c '\.tmp$')"
} > "$T_WORK/sign.txt"
DRIVER

  d="$ST_WORK/sign.txt"
  t_eq "旧文件：日期读得出" "$(st_val "$d" old_date)" "2026-10-02"
  t_eq "旧文件：时间读得出" "$(st_val "$d" old_time)" "21:31"
  t_eq "旧文件：类型读得出" "$(st_val "$d" old_kind)" "normal"
  t_eq "键不存在时为空" "$(st_val "$d" missing)" ""
  t_eq "签到记录：字段名与顺序不变" "$(st_val "$d" new)" "sign_date=2026-10-03|sign_time=21:30|sign_kind=supplement|"
  t_eq "签到记录：读回自己写的值" "$(st_val "$d" new_date)" "2026-10-03"
  t_eq "请假记录：空时间也保留 sign_time 行" "$(st_val "$d" leave)" "sign_date=2026-10-03|sign_time=|sign_kind=leave|"
  t_eq "签到记录写入不留临时文件" "$(st_val "$d" tmpleft)" "0"
}

# ============================================================
# 三、保活统计：每日计数 + 跨日归零
# ============================================================

st_case_keepalive_daily() {
  local d
  st_setup
  st_write_env
  st_run ka <<'DRIVER'
{
  printf 'empty=%s\n'    "$(ka_last_time)"
  printf 'c0=%s\n'       "$(ka_counts)"

  ka_note ok TOK1
  ka_note ok TOK1
  ka_note fail TOK2
  printf 'c1=%s\n'       "$(ka_counts)"
  printf 'ok1=%s\n'      "$(ka_ok_count)"
  printf 'fail1=%s\n'    "$(ka_fail_count)"
  printf 'last_result=%s\n' "$(ka_last_result)"
  printf 'is_today=%s\n' "$(ka_is_today && echo yes || echo no)"
  printf 'last_len=%s\n' "$(printf '%s' "$(ka_last_time)" | wc -c | tr -dc '0-9')"
  # 完整文件格式（字段名与顺序是契约）
  printf 'raw=%s\n' "$(cat "$MODDIR/fafu_keepalive.status" | tr '\n' '|')"

  # token 省略时沿用统计文件里的旧值（不清空）
  ka_note fail
  printf 'c2=%s\n'       "$(ka_counts)"
  printf 'raw2=%s\n' "$(cat "$MODDIR/fafu_keepalive.status" | tr '\n' '|')"

  # 跨日归零：拨到第二天，计数必须从头开始
  printf '%s\n' '2026-10-04 07:00' > "$MOCK_DATE_CTL"
  printf 'c3=%s\n'       "$(ka_counts)"
  printf 'is_today2=%s\n' "$(ka_is_today && echo yes || echo no)"
  ka_note ok TOK3
  printf 'c4=%s\n'       "$(ka_counts)"
  printf 'raw_after=%s\n' "$(cat "$MODDIR/fafu_keepalive.status" | tr '\n' '|')"
} > "$T_WORK/ka.txt"
DRIVER

  d="$ST_WORK/ka.txt"
  t_eq "无统计文件时没有最近记录" "$(st_val "$d" empty)" ""
  t_eq "无统计文件时今日计数为 0 0" "$(st_val "$d" c0)" "0 0"
  t_eq "累计今日成功/失败" "$(st_val "$d" c1)" "2 1"
  t_eq "今日成功数可单独读" "$(st_val "$d" ok1)" "2"
  t_eq "今日失败数可单独读" "$(st_val "$d" fail1)" "1"
  t_eq "记录最近一次结果为 fail" "$(st_val "$d" last_result)" "fail"
  t_eq "最近一次记录属于今天" "$(st_val "$d" is_today)" "yes"
  t_eq "最近时刻为 19 字符时间戳（格式不变）" "$(st_val "$d" last_len)" "19"
  t_eq "统计文件：字段名与顺序不变" "$(st_val "$d" raw)" \
    "date=2026-10-03|ok=2|fail=1|last=2026-10-03 21:30:00|last_result=fail|token=TOK2|"
  t_eq "同一天继续累加" "$(st_val "$d" c2)" "2 2"
  t_eq "省略 token 时沿用旧值（不清空）" "$(st_val "$d" raw2)" \
    "date=2026-10-03|ok=2|fail=2|last=2026-10-03 21:30:00|last_result=fail|token=TOK2|"
  t_eq "跨日后读取计数归零（不写文件）" "$(st_val "$d" c3)" "0 0"
  t_eq "跨日后最近记录不再属于今天" "$(st_val "$d" is_today2)" "no"
  t_eq "跨日后从 1 重新计数" "$(st_val "$d" c4)" "1 0"
  t_eq "跨日后统计文件重写为 1 成功 / 0 失败" "$(st_val "$d" raw_after)" \
    "date=2026-10-04|ok=1|fail=0|last=2026-10-04 07:00:00|last_result=ok|token=TOK3|"
}

# 保活统计文件格式只在「跨日」用例里比对（字段名与顺序是契约，见上一条用例）。
# 这里补两条：旧版本写的文件仍读得出；写入不留临时文件（原子写的产物形态）。
st_case_keepalive_format() {
  local d
  st_setup
  st_write_env
  # 预置一份「旧版本写的」统计：六个字段、顺序与旧版一致
  printf 'date=2026-10-03\nok=2\nfail=1\nlast=2026-10-03 08:15:30\nlast_result=fail\ntoken=OLDTOK\n' \
    > "$ST_WORK/mod/fafu_keepalive.status"
  st_run kafmt <<'DRIVER'
{
  printf 'counts=%s\n'   "$(ka_counts)"
  printf 'ok1=%s\n'      "$(ka_ok_count)"
  printf 'fail1=%s\n'    "$(ka_fail_count)"
  printf 'last=%s\n'     "$(ka_last_time)"
  printf 'result=%s\n'   "$(ka_last_result)"
  printf 'today=%s\n'    "$(ka_is_today && echo yes || echo no)"
  # 旧文件继续累加：沿用旧 token，不把 token 清空
  ka_note ok
  printf 'raw=%s\n'      "$(cat "$MODDIR/fafu_keepalive.status" | tr '\n' '|')"
  printf 'tmpleft=%s\n'  "$(ls "$MODDIR" | grep -c '\.tmp$')"
} > kafmt.txt
DRIVER
  d="$ST_WORK/kafmt.txt"
  t_eq "旧文件：今日计数读得出" "$(st_val "$d" counts)" "2 1"
  t_eq "旧文件：成功数可单独读" "$(st_val "$d" ok1)" "2"
  t_eq "旧文件：失败数可单独读" "$(st_val "$d" fail1)" "1"
  t_eq "旧文件：最近时刻读得出" "$(st_val "$d" last)" "2026-10-03 08:15:30"
  t_eq "旧文件：最近结果读得出" "$(st_val "$d" result)" "fail"
  t_eq "旧文件：判定最近记录属于今天" "$(st_val "$d" today)" "yes"
  t_eq "旧文件：继续累加且沿用旧 token" "$(st_val "$d" raw)" \
    "date=2026-10-03|ok=3|fail=1|last=2026-10-03 21:30:00|last_result=ok|token=OLDTOK|"
  t_eq "保活统计不含临时文件" "$(st_val "$d" tmpleft)" "0"
}

# ============================================================
# 四、当日完成标记（按日判定）
# ============================================================

st_case_done_mark() {
  local d
  st_setup
  st_write_env
  # 预置一份「旧版本写的」完成标记（昨天的日期）：今天既不能判成已完成，
  # 也不能因为读不懂格式而被迫重新签到
  printf '2026-10-02\n' > "$ST_WORK/mod/.fafu_checkin_done"
  st_run done <<'DRIVER'
{
  printf 'd0=%s\n'      "$(done_marked && echo yes || echo no)"
  printf 'kept=%s\n'    "$(cat "$MODDIR/.fafu_checkin_done" | tr '\n' '|')"
  done_mark
  printf 'd1=%s\n'      "$(done_marked && echo yes || echo no)"
  printf 'fmt=%s\n'     "$(cat "$MODDIR/.fafu_checkin_done" | tr '\n' '|')"
  # 跨日：昨天的完成标记不该挡住今天的签到
  printf '%s\n' '2026-10-04 07:00' > "$MOCK_DATE_CTL"
  printf 'd2=%s\n'      "$(done_marked && echo yes || echo no)"
  printf 'fmt_kept=%s\n' "$(cat "$MODDIR/.fafu_checkin_done" | tr '\n' '|')"
  done_mark
  printf 'fmt2=%s\n'    "$(cat "$MODDIR/.fafu_checkin_done" | tr '\n' '|')"
} > "$T_WORK/done.txt"
DRIVER

  d="$ST_WORK/done.txt"
  t_eq "旧文件：昨天的标记不成立（今天仍需签到）" "$(st_val "$d" d0)" "no"
  t_eq "旧文件：判定不修改标记内容" "$(st_val "$d" kept)" "2026-10-02|"
  t_eq "标记后判定为已完成" "$(st_val "$d" d1)" "yes"
  t_eq "完成标记内容为日期 + 换行（格式不变）" "$(st_val "$d" fmt)" "2026-10-03|"
  t_eq "跨日后当日完成标记不再成立" "$(st_val "$d" d2)" "no"
  t_eq "跨日判定不修改标记文件" "$(st_val "$d" fmt_kept)" "2026-10-03|"
  t_eq "跨日后可重新标记" "$(st_val "$d" fmt2)" "2026-10-04|"
}

# ============================================================
# 五、通知标记：四类事件各自的文件、跨日滚动
# ============================================================

st_case_notify_marks() {
  local d
  st_setup
  st_write_env
  # 预置一份「旧版本写的」标记（昨天的日期）：四类事件今天都必须重新可发
  printf '2026-10-02\n' > "$ST_WORK/mod/.fafu_notify_fail"
  printf '2026-10-02\n' > "$ST_WORK/mod/.fafu_notify_nosign"
  printf '2026-10-02\n' > "$ST_WORK/mod/.fafu_notify_late"
  printf '2026-10-02\n' > "$ST_WORK/mod/.fafu_notify_miss"
  st_run marks <<'DRIVER'
{
  # 旧标记（昨天）不该挡住今天
  for e in fail nosign late miss; do
    printf 'old_%s=%s\n' "$e" "$(notify_marked "$e" && echo yes || echo no)"
  done
  # 四个事件各自落到哪个文件（文件名格式不变）
  for e in fail nosign late miss; do
    notify_mark "$e"
    printf 'after_%s=%s\n'  "$e" "$(notify_marked "$e" && echo yes || echo no)"
  done
  printf 'files=%s\n' "$(ls -a "$MODDIR" | grep '^\.fafu_notify_' | tr '\n' ' ')"
  printf 'raw=%s\n'   "$(cat "$MODDIR/.fafu_notify_miss" | tr '\n' '|')"
  # 跨日：四类事件明天都能再发一次
  printf '%s\n' '2026-10-04 07:00' > "$MOCK_DATE_CTL"
  for e in fail nosign late miss; do
    printf 'next_%s=%s\n' "$e" "$(notify_marked "$e" && echo yes || echo no)"
  done
  printf 'tmpleft=%s\n' "$(ls "$MODDIR" | grep -c '\.tmp$')"
} > "$T_WORK/marks.txt"
DRIVER

  d="$ST_WORK/marks.txt"
  for e in fail nosign late miss; do
    t_eq "事件 $e：旧标记（昨天）不算已发" "$(st_val "$d" old_$e)" "no"
    t_eq "事件 $e：标记后为已发" "$(st_val "$d" after_$e)" "yes"
    t_eq "事件 $e：跨日后重新可发" "$(st_val "$d" next_$e)" "no"
  done
  t_eq "四类标记文件齐全（各自独立）" "$(st_val "$d" files)" ".fafu_notify_fail .fafu_notify_late .fafu_notify_miss .fafu_notify_nosign "
  t_eq "标记内容为日期 + 换行（格式不变）" "$(st_val "$d" raw)" "2026-10-03|"
  t_eq "通知标记不留临时文件" "$(st_val "$d" tmpleft)" "0"
}

# 每日一次去重：发送失败**不得**落标记（否则一次瞬时失败=整天不再提醒）
st_case_notify_once() {
  local d
  st_setup
  st_write_env
  st_run once <<'DRIVER'
# SU_MODE 是「降权写法可用」的注入点：不设它 notify / notify_once 会直接跳过（零调用），
# 这样断言就测不到去重与标记，故这里显式给一个值；真正执行的发送由下面的 nt_send 顶替
# （nt_send 是发送层上的缝，与 api 层的 http_post 同理）
SU_MODE=st_probe
nt_try() { printf '%s\n' "$1" >> tries.log; }
{
  # 发送失败：返回非 0，且不落标记
  nt_send() { nt_try "fail-call"; return 1; }
  if notify_once miss; then rc=0; else rc=1; fi
  printf 'rc_fail=%s\n'  "$rc"
  printf 'mark_fail=%s\n' "$(notify_marked miss && echo yes || echo no)"

  # 再试一次并成功：落标记
  nt_send() { nt_try "ok-call"; return 0; }
  if notify_once miss; then rc=0; else rc=1; fi
  printf 'rc_ok=%s\n'    "$rc"
  printf 'mark_ok=%s\n'  "$(notify_marked miss && echo yes || echo no)"

  # 当日已发：不再调用发送
  if notify_once miss; then rc=0; else rc=1; fi
  printf 'rc_dup=%s\n'   "$rc"
  printf 'calls=%s\n'    "$(wc -l < tries.log | tr -dc '0-9')"

  # NOTIFY=0：零发送、零标记
  NOTIFY=0
  if notify_once late; then rc=0; else rc=1; fi
  printf 'rc_off=%s\n'   "$rc"
  printf 'mark_off=%s\n' "$(notify_marked late && echo yes || echo no)"
  printf 'calls_off=%s\n' "$(wc -l < tries.log | tr -dc '0-9')"

  # 降权不可用（SU_MODE 为空）：同样零发送、零标记
  NOTIFY=1; SU_MODE=""
  if notify_once nosign; then rc=0; else rc=1; fi
  printf 'rc_nosu=%s\n'  "$rc"
  printf 'mark_nosu=%s\n' "$(notify_marked nosign && echo yes || echo no)"
  printf 'calls_nosu=%s\n' "$(wc -l < tries.log | tr -dc '0-9')"
} > "$T_WORK/once.txt"
DRIVER

  d="$ST_WORK/once.txt"
  t_eq "发送失败：返回非 0" "$(st_val "$d" rc_fail)" "1"
  t_eq "发送失败：不落当日标记（可再试）" "$(st_val "$d" mark_fail)" "no"
  t_eq "发送成功：返回 0" "$(st_val "$d" rc_ok)" "0"
  t_eq "发送成功：落当日标记" "$(st_val "$d" mark_ok)" "yes"
  t_eq "当日已发：返回 0（不重复打扰）" "$(st_val "$d" rc_dup)" "0"
  t_eq "当日已发：不再调用发送" "$(st_val "$d" calls)" "2"
  t_eq "NOTIFY=0：返回 0" "$(st_val "$d" rc_off)" "0"
  t_eq "NOTIFY=0：不落标记" "$(st_val "$d" mark_off)" "no"
  t_eq "NOTIFY=0：零调用" "$(st_val "$d" calls_off)" "2"
  t_eq "降权不可用：返回 0" "$(st_val "$d" rc_nosu)" "0"
  t_eq "降权不可用：不落标记" "$(st_val "$d" mark_nosu)" "no"
  t_eq "降权不可用：零调用" "$(st_val "$d" calls_nosu)" "2"
}

# 打扰型通知的冷却基准（落盘，必须在子 shell 里也生效）
st_case_cooldown() {
  local d
  st_setup
  st_write_env
  st_run cool <<'DRIVER'
{
  printf 'empty=%s\n'   "$(nt_cooldown)"
  nt_cooldown 1759500000
  printf 'read=%s\n'    "$(nt_cooldown)"
  printf 'raw=%s\n'     "$(cat "$MODDIR/.fafu_notify_last" | tr '\n' '|')"
  # 子 shell 里读得到（refresh_token 就是在 $( ) 里调用它的）
  printf 'sub=%s\n'     "$( (nt_cooldown) )"
  nt_cooldown 1759500300
  printf 'read2=%s\n'   "$(nt_cooldown)"
} > "$T_WORK/cool.txt"
DRIVER

  d="$ST_WORK/cool.txt"
  t_eq "无冷却文件时基准为 0" "$(st_val "$d" empty)" "0"
  t_eq "写入后可读回" "$(st_val "$d" read)" "1759500000"
  t_eq "冷却基准只含数字 + 换行" "$(st_val "$d" raw)" "1759500000|"
  t_eq "子 shell 里读得到（不是内存变量）" "$(st_val "$d" sub)" "1759500000"
  t_eq "可覆盖为新的基准" "$(st_val "$d" read2)" "1759500300"
}

# ============================================================
# 六、desc：描述文案与写入契约
# ============================================================

st_case_desc_text() {
  local d
  st_setup
  st_write_env
  st_run text <<'DRIVER'
{
  # 已启用 + 无记录
  printf 'e0=%s\n' "$(desc_text)"
  # 已启用 + 今天已签到（带时间）
  sign_set 2026-10-03 21:30 normal
  printf 'e1=%s\n' "$(desc_text)"
  # 已启用 + 今天已签到但无时间（检测到的记录）
  sign_set 2026-10-03 "" detected
  printf 'e2=%s\n' "$(desc_text)"
  # 已启用 + 今天已请假
  sign_set 2026-10-03 "" leave
  printf 'e3=%s\n' "$(desc_text)"
  # 已启用 + 上次签到是昨天（相对日期不失真：显示昨天那条记录）
  sign_set 2026-10-02 21:31 normal
  printf 'e4=%s\n' "$(desc_text)"
  # 已停用：三种情况
  svc_set disabled
  rm -f "$MODDIR/fafu_checkin.status"
  printf 'd1=%s\n' "$(desc_text)"
  sign_set 2026-10-02 21:31 normal
  printf 'd2=%s\n' "$(desc_text)"
  sign_set 2026-10-02 "" leave
  printf 'd3=%s\n' "$(desc_text)"
} > "$T_WORK/text.txt"
DRIVER

  d="$ST_WORK/text.txt"
  t_eq "已启用 + 无记录" "$(st_val "$d" e0)" "🟢 已启用 · ⏳ 10-03 未签到"
  t_eq "已启用 + 今日已签到（含时间）" "$(st_val "$d" e1)" "🟢 已启用 · ✅ 10-03 已签到 21:30"
  t_eq "已启用 + 今日已签到（无时间）" "$(st_val "$d" e2)" "🟢 已启用 · ✅ 10-03 已签到"
  t_eq "已启用 + 今日已请假" "$(st_val "$d" e3)" "🟢 已启用 · 🏖 10-03 已请假"
  t_eq "已启用 + 上次签到是昨天（绝对日期）" "$(st_val "$d" e4)" "🟢 已启用 · ⏳ 10-03 未签到"
  t_eq "已停用 + 无记录" "$(st_val "$d" d1)" "⏸ 已停用 · 暂无签到记录"
  t_eq "已停用 + 有记录（含时间）" "$(st_val "$d" d2)" "⏸ 已停用 · 最近签到 10-02 21:31"
  t_eq "已停用 + 有记录（无时间）" "$(st_val "$d" d3)" "⏸ 已停用 · 最近签到 10-02"
}

st_case_desc_write() {
  local d prop
  st_setup
  st_write_env
  prop="$ST_WORK/mod/module.prop"
  st_run write <<'DRIVER'
{
  # 内容变化才写：先写一次，再算一次（第二次不该动文件）
  update_desc
  printf 'rc1=%s\n'  "$?"
  cp "$MODDIR/module.prop" "$T_WORK/prop.1"
  printf 'desc1=%s\n' "$(grep -m1 '^description=' "$MODDIR/module.prop")"
  update_desc
  if cmp -s "$T_WORK/prop.1" "$MODDIR/module.prop"; then same=yes; else same=no; fi
  printf 'same=%s\n' "$same"

  # 状态变了（签到成功）→ 重新写入，且日期为绝对日期
  sign_set 2026-10-03 21:30 normal
  update_desc
  printf 'desc2=%s\n' "$(grep -m1 '^description=' "$MODDIR/module.prop")"
  printf 'lines=%s\n' "$(wc -l < "$MODDIR/module.prop" | tr -dc '0-9')"

  # 开关切换 → 描述跟着变
  svc_set disabled
  update_desc
  printf 'desc3=%s\n' "$(grep -m1 '^description=' "$MODDIR/module.prop")"

  # 内容与「当前生效描述」相同时不重复写入
  cp "$MODDIR/module.prop" "$T_WORK/prop.3"
  update_desc
  if cmp -s "$T_WORK/prop.3" "$MODDIR/module.prop"; then same3=yes; else same3=no; fi
  printf 'same3=%s\n' "$same3"
} > "$T_WORK/write.txt"
DRIVER

  d="$ST_WORK/write.txt"
  t_eq "改写模块元数据成功" "$(st_val "$d" rc1)" "0"
  t_eq "写入已启用 + 未签到描述" "$(st_val "$d" desc1)" "description=🟢 已启用 · ⏳ 10-03 未签到"
  t_eq "内容未变时不重复写入" "$(st_val "$d" same)" "yes"
  t_eq "签到后描述更新为绝对日期" "$(st_val "$d" desc2)" "description=🟢 已启用 · ✅ 10-03 已签到 21:30"
  t_eq "改写后仍保留其余元数据行（一行不多不少）" "$(st_val "$d" lines)" "6"
  t_eq "停用后描述跟着变" "$(st_val "$d" desc3)" "description=⏸ 已停用 · 最近签到 10-03 21:30"
  t_eq "描述与当前值相同时不重复写入" "$(st_val "$d" same3)" "yes"
  t_has "改写后模块名与版本仍在" "$prop" "name=数字FAFU晚查寝自动签到"
  t_has "改写后版本行仍在" "$prop" "version=v1.2.0"
  t_has "改写后 author 行仍在" "$prop" "author=Bonger"
  t_eq "改写不留临时文件" "$(ls "$ST_WORK/mod" | grep -c '\.tmp$')" "0"
  t_eq "description 行只有一条" "$(grep -c '^description=' "$prop")" "1"
}

# 写入前的非空校验：grep 失败（这里用一份只剩 description 行的元数据模拟）
# 会让临时文件为空，此时必须放弃写入——直接 mv 会把 module.prop 清空。
st_case_desc_guard() {
  local d prop before
  st_setup
  st_write_env
  prop="$ST_WORK/mod/module.prop"
  printf 'description=只有描述行\n' > "$prop"
  before=$(st_cat "$prop")
  st_run guard <<'DRIVER'
if update_desc; then rc=0; else rc=1; fi
printf 'rc=%s\n' "$rc"
DRIVER
  d="$ST_WORK/guard.out"
  t_eq "元数据只剩 description 时写入失败（返回非 0）" "$(st_val "$d" rc)" "1"
  t_eq "失败时模块元数据逐字节不变（没被清空）" "$(st_cat "$prop")" "$before"
  t_eq "失败时不留下临时文件" "$(ls "$ST_WORK/mod" | grep -c '\.tmp$')" "0"
}

# 描述触发点：调用点必须照旧刷新描述（结构变了，行为不许变）
st_case_desc_trigger() {
  local src hit n_sig n_cmd n_entry n_app
  src="$ST_WORK/program.sh"
  # 「整行就是个调用」的判据：缩进 + 函数名 + 行尾，既排除函数定义，也排除注释
  # 与用例自己写的这句（它们后面还有别的字）。行内最多一次，故按行计数即可。
  hit='^[ ]*update_desc$'
  mkdir -p "$ST_WORK"
  t_write_program "$src" || { _t_fail "无法拼出全程序文本"; return 0; }
  # 层内调用点：signin 两处（检测到已签到/请假、签到或补签成功）
  #             + commands 三处（启用 / 停用 / status 顺带刷新）
  n_sig=$(grep -cE -e "$hit" "$T_ROOT/lib/signin.sh")
  n_cmd=$(grep -cE -e "$hit" "$T_ROOT/lib/commands.sh")
  n_entry=$(grep -cE -e "$hit" "$T_ROOT/fafu_checkin.sh")
  n_app=$(grep -cE -e "$hit" "$src")
  t_eq "触发点：signin 层两处（检测到 + 签到成功）" "$n_sig" "2"
  t_eq "触发点：commands 层三处（启用 / 停用 / status）" "$n_cmd" "3"
  # 入口三处：启动落定、停用分支、守护循环里的定时自检
  t_eq "触发点：入口三处（启动 / 停用 / 定时自检）" "$n_entry" "3"
  t_eq "触发点：全程序共 8 处描述刷新" "$n_app" "8"
  t_before_re "触发点：守护循环里定时刷新排在日志轮转之前" "$src" \
    "$(t_call_re update_desc)" "$(t_call_re rotate_log)"
}

# ============================================================
# 七、收口边界：状态文件名只许出现在状态层与开机脚本里
# ============================================================

# 这条守的是「其余层不再直接读写这些文件」这条不变量：函数名可以被改名，
# 但**文件名**是契约，只要它出现在别的层的读写语句里，那条收口就已经破了。
# 判据只看「真正碰文件」的三种写法（重定向 / echo 写入 / 文件操作命令 + 路径），
# 于是：注释与用法文本（各层都有提到运行时文件）不算，
#       带引号的字符串（uninstall.sh 的删除清单，与模块目录一起被管理器整体移除）也不算。
# 允许的两个持有者：
#   lib/state.sh  —— 归属地本身
#   service.sh    —— 开机脚本，不加载库层，启动前只读一次开关文件
st_case_ownership() {
  local pat owners files
  pat='(^|[^"[:alnum:]_/])(>|>>|cat|grep|read|printf|rm|kill|mv|cp)[[:space:]]+"?\$(STATE|STATUS|KASTAT|DONE|NFAIL|NNOSIGN|NLATE|NMISS|NTLAST)"?'
  owners=""
  for f in "$T_ROOT"/*.sh "$T_ROOT"/lib/*.sh; do
    if grep -qE -e "$pat" "$f" 2>/dev/null; then
      owners="$owners ${f##*/}"
    fi
  done
  # 顺序不敏感：只比对「哪几个文件」
  t_eq "状态文件名只出现在 state 层与开机脚本里" \
    "$(printf '%s\n' $owners | sort | tr '\n' ' ')" \
    "service.sh state.sh "
  # 反向：两个持有者必须真的还在（否则上面的断言会因为「两边都没了」而空转）
  files=$(printf '%s\n' $owners | grep -c .)
  t_eq "持有状态文件名的文件恰好两个" "$files" "2"
  t_has "state 层持有服务开关文件名" "$T_ROOT/lib/state.sh" 'STATE="$MODDIR/fafu-checkin.state"'
  t_has "state 层持有签到记录文件名" "$T_ROOT/lib/state.sh" 'STATUS="$MODDIR/fafu_checkin.status"'
  t_has "state 层持有保活统计文件名" "$T_ROOT/lib/state.sh" 'KASTAT="$MODDIR/fafu_keepalive.status"'
  t_has "state 层持有完成标记文件名" "$T_ROOT/lib/state.sh" 'DONE="$MODDIR/.fafu_checkin_done"'
  t_has "state 层持有失败类通知标记文件名" "$T_ROOT/lib/state.sh" 'NFAIL="$MODDIR/.fafu_notify_fail"'
  t_has "state 层持有冷却基准文件名" "$T_ROOT/lib/state.sh" 'NTLAST="$MODDIR/.fafu_notify_last"'
  t_has "开机脚本仍读开关文件（豁免是有据的）" "$T_ROOT/service.sh" '[ -f "$STATE" ]'
}

# ---- 注册（顺序即执行顺序） ----

t_case "state · 开关状态" st_case_switch
t_case "state · 签到记录（含旧文件兼容）" st_case_sign
t_case "state · 保活统计与跨日归零" st_case_keepalive_daily
t_case "state · 保活统计文件格式" st_case_keepalive_format
t_case "state · 当日完成标记" st_case_done_mark
t_case "state · 通知标记与跨日滚动" st_case_notify_marks
t_case "state · 通知每日一次去重" st_case_notify_once
t_case "state · 打扰通知冷却基准" st_case_cooldown
t_case "desc · 描述文案" st_case_desc_text
t_case "desc · 写入契约" st_case_desc_write
t_case "desc · 写入前的非空校验" st_case_desc_guard
t_case "desc · 触发点" st_case_desc_trigger
t_case "state · 收口边界（状态文件名只许在此）" st_case_ownership
