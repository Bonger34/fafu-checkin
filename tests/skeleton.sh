# ============================================================
# 骨架验收断言：base 层原语、入口装配、打包管道
#
# 三块都只针对「外部可观察的行为」：
#   base 原语：函数的输出、落盘内容、轮转后的行数（含拨钟与「空内容不覆盖」）；
#   入口：缺一层时写模块日志并以非 0 退出；层齐时能装配起来跑通子命令分发；
#   打包：产物里确实有每个层文件与页面入口、少一个就构建失败（本机没有 zip/unzip 时跳过该项）；
#   页面：入口文件在源树里、文本零外部 URL，另有反向样本自证这条判据真的会失败。
#
# 层清单不在这里重复维护：harness 从入口的 FAFU_LAYERS 读出来放进 TEST_LIB_FILES。
# ============================================================

SK_WORK="$T_WORK_ROOT/skeleton"

# 每个用例自备环境：mock busybox 包装（拨钟与替身） + 一个空的模块目录
sk_setup() {
  rm -rf "$SK_WORK"
  mkdir -p "$SK_WORK/mod"
  t_bb_wrap "$SK_WORK/bin/bb" >/dev/null
}

# 驱动脚本的公共前导：注入替身 busybox 与模块目录，再按加载顺序 source 真实层文件。
# 调用方先 sk_write_env，再用 sk_run 跑主体。
sk_write_env() {
  cat > "$SK_WORK/_env.sh" <<ENV
PATH='/bin:/usr/bin'
T_ROOT='$T_ROOT'
T_WORK='$SK_WORK'
MODDIR='$SK_WORK/mod'
BB_OVERRIDE='$SK_WORK/bin/bb'
export MODDIR BB_OVERRIDE
for _f in $TEST_LIB_FILES; do . "\$T_ROOT/\$_f"; done
ENV
}

# 跑一个驱动脚本；用法：sk_run <名字>，主体从 stdin 读入（公共前导自动接在前面）
sk_run() {
  local name rc
  name="$1"
  cat > "$SK_WORK/_body.sh"
  cp "$SK_WORK/_env.sh" "$SK_WORK/$name.sh"
  cat "$SK_WORK/_body.sh" >> "$SK_WORK/$name.sh"
  ( cd "$SK_WORK" && $(t_sh) "./$name.sh" ) > "$SK_WORK/$name.out" 2> "$SK_WORK/$name.err"
  rc=$?
  echo "$rc" > "$SK_WORK/$name.rc"
  if [ -s "$SK_WORK/$name.err" ]; then
    echo "  （驱动 $name 的 stderr）"
    sed 's/^/    /' "$SK_WORK/$name.err"
  fi
}

# 把模块拷成一份**可独立运行**的副本（入口 + 层 + 元数据）。
# 实现在 harness 里（tests/commands.sh 的「临时模块」用例也用同一份）。
sk_stage_module() { # $1=目标目录
  t_stage_module "$1"
}

# 从驱动输出里取一行（形如 key=value）
sk_val() { # $1=文件 $2=键
  sed -n "s/^$2=//p" "$1"
}

# ============================================================
# base 层原语
# ============================================================

sk_case_base_primitives() {
  local f tzfd
  sk_setup
  sk_write_env
  sk_run prim <<'DRIVER'
f="$T_WORK/mod/kv.txt"
kv_set "$f" sign_date 2026-10-03 sign_time 21:30 sign_kind normal

J='{"records":[{"id":123,"name":"晚查寝签到","signState":0,"beginTime":1759400000000,"signTime":"2026-10-03 21:30:00"}],"total":1}'

{
  printf 'get=%s\n'      "$(kv_get "$f" sign_time)"
  printf 'absent=[%s]\n' "$(kv_get "$f" nope)"
  printf 'nofile=[%s]\n' "$(kv_get "$T_WORK/mod/none.txt" x)"
  printf 'order=%s\n'    "$(cat "$f" | tr '\n' '|')"

  printf 'id=%s\n'        "$(json_first "$J" id)"
  printf 'name=%s\n'      "$(json_first "$J" name)"
  printf 'state=%s\n'     "$(json_first "$J" signState)"
  printf 'time=%s\n'      "$(json_first "$J" signTime)"
  printf 'jtabsent=[%s]\n' "$(json_first "$J" nope)"

  # 坐标取值：真机上顶层 lng/lat 是 null、真值在 signInStudent 里（且真值在后面）。
  # 单独钉住三件事：取最后一份合法数值、null 不算值、非数值形状一律当没取到。
  C1='{"records":[{"id":1,"lng":null,"lat":null,"signInStudent":{"signState":0,"lng":118.23577500,"lat":25.07802600}}]}'
  printf 'coord1=%s,%s\n'  "$(_json_coord "$C1" lng)" "$(_json_coord "$C1" lat)"
  # signInStudent 里若嵌了别的对象（块切法会在第一个 } 处截断、把坐标切没），这里仍要取到：
  # 这是「不靠对象块形状取值」的理由，也是这个陷阱的守卫。
  C2='{"records":[{"id":1,"lng":null,"lat":null,"signInStudent":{"class":{"id":7},"lng":118.5,"lat":25.5}}]}'
  printf 'nested=%s,%s\n'  "$(_json_coord "$C2" lng)" "$(_json_coord "$C2" lat)"
  # 带空格的写法（接口给过 `"lng": 118.2`）也要取到数值本身
  printf 'space=%s,%s\n'   "$(_json_coord '{"lng": 120.1,"lat": 30.2}' lng)" "$(_json_coord '{"lng": 120.1,"lat": 30.2}' lat)"
  # 两份都是 null / 形状不合法 → 空（调用方据此回退内置坐标）
  printf 'allnull=[%s]\n'  "$(_json_coord '{"lng":null,"lat":null}' lng)"
  printf 'junk=[%s]\n'     "$(_json_coord '{"lng":"abc"}' lng)"
  # _json_last 与 json_first 的方向必须相反（同一个键出现两次时）
  J2='{"lng":null,"signInStudent":{"lng":118.5}}'
  printf 'last=%s\n'       "$(_json_last "$J2" lng)"
  # 时区偏移：「时间核对」行末尾那个判据靠它，**绝不能是空**（空会让 TZ=[…] 退化成
  # [未设/]，读的人分不清「没取到偏移」与「偏移为零」）。
  # 形状判据故意不写 `[+-]`：ash 把那个当区间，`--` 会被判成合法偏移——正是要拦住的哨兵值。
  # 所以这里写 `[+][0-9]…|[-][0-9]…`，与 base 里保持一致。
  printf 'tz=[%s]\n'       "$(tz_offset)"
  printf 'tzshape=%s\n'    "$(case "$(tz_offset)" in [+][0-9][0-9][0-9][0-9]|[-][0-9][0-9][0-9][0-9]) echo ok ;; *) echo bad ;; esac)"
  # 偏移秒数 + 纯粹算术换算：真机上 `date -d @<戳>` 给错值（2026-10-13 探针：同一个戳
  # 给 17:09 / 09:09，正确值 21:32 / 13:32），所以这条路必须自己算。这里钉住：
  #   · 设备那个 epoch 在 +0800 下是 21:32、在 UTC 视角下是 13:32（就是真机错的那两个数）
  #   · 非整点偏移（+0545）与负偏移（-0500）都对——这两个是「自己算」最容易写错的边界
  #   · 缺值给空，调用方据此不写钟点（而不是写个假的 00:00）
  printf 'devlocal=%s\n'   "$(ms_to_hm 1791811959000 28800)"
  printf 'devutc=%s\n'     "$(ms_to_hm 1791811959000)"
  printf 'half=%s\n'       "$(ms_to_hm 1791811959000 19800)"
  printf 'neg=%s\n'        "$(ms_to_hm 1791811959000 -18000)"
  printf 'epoch0=%s\n'     "$(ms_to_hm 0 28800)"
  printf 'crossday=%s\n'   "$(ms_to_hm 86400000 28800)"
  printf 'empty=[%s]\n'    "$(ms_to_hm '')"
  printf 'nooff=[%s]\n'    "$(ms_to_hm 1791811959000 "")"
  printf 'offsets=%s\n'    "$(tz_offset_s)"

  # 原子写：内容落盘且不留临时文件；空内容不覆盖已有内容（别把状态清空）
  printf 'atom\n' | write_atomic "$T_WORK/mod/atom.txt"
  printf 'atom=%s\n' "$(cat "$T_WORK/mod/atom.txt")"
  printf '' | write_atomic "$T_WORK/mod/atom.txt"
  printf 'kept=%s\n' "$(cat "$T_WORK/mod/atom.txt")"
  printf 'tmpleft=%s\n' "$(ls "$T_WORK/mod" | grep -c '\.tmp$')"
} > "$T_WORK/prim.txt"
DRIVER

  # 偏移的解析**不能依赖跑测机器的时区**（CI 是 UTC、开发机常常 +0800，同一断言两边
  # 结果不同就是假红/假绿）。mock 必须能被 `"$BB" date +%z` 这样**当命令跑**：
  #   · 直接 exec tests/mock/busybox → 本机没有可执行位，Permission denied，然后**静默
  #     透传给真实 date**，断言就成了「看着在跑、其实没测到东西」；
  #   · 把 BB 设成「busybox sh mock」这种多词命令 → `"$BB"` 是加引号的，不会词分割；
  #   · 包一层 `#!/bin/sh`（harness 的 t_bb_wrap 那样）→ 本机 exec 不了。
  # 唯一两边都成立的：包一层，其 shebang 直接是**真实 busybox + sh applet**
  # （`#!<busybox> sh`），由它去读 mock。bb_real 要写成 POSIX 路径（`#!D:\…` 不认）。
  sksh=$(t_sh)                      # 形如 `<busybox>.exe sh`，用于跑生成的驱动
  bb_real=$(find_busybox)
  case "$bb_real" in
    */*:/*) bb_real=$(printf '%s' "$bb_real" | sed 's|^\([A-Za-z]\):|/\1|') ;;   # D:/… → /d/…
  esac
  {
    printf '#!%s sh\n' "$bb_real"
    printf '%s "$@"\n' "$T_ROOT/tests/mock/busybox"
  } > "$SK_WORK/bbz"
  chmod +x "$SK_WORK/bbz" 2>/dev/null
  {
    echo ". '$SK_WORK/_env.sh'"
    echo "BB='$SK_WORK/bbz'"
    echo 'printf "tz_a=%s\n"     "$(MOCK_TZ=+0545 tz_offset_s)"'
    echo 'printf "tz_zero=%s\n"  "$(MOCK_TZ=+0000 tz_offset_s)"'
    echo 'printf "tz_neg=%s\n"   "$(MOCK_TZ=-0530 tz_offset_s)"'
    echo 'printf "tz_bad=%s\n"   "$(MOCK_TZ=-- MOCK_EPOCH_LOCAL=1000000 tz_offset_s)"'
    echo '# 偏移判不出来时 tz_offset 仍要给得出东西（日志的 TZ=[…] 段靠它）；'
    echo '# 这里两个读数取同一个值，于是「算出来的偏移」是 0——tz_offset 会输出 +0，'
    echo '# 而 tz_offset_s 必须与「合法的 +0000」区分开：判不出来的那档给空。'
    echo 'printf "tz_off_bad=%s\n" "$(MOCK_TZ=-- MOCK_EPOCH_LOCAL=1000000 tz_offset)"'
    echo '# 退化路径：%z 判不出来、两个读数由 MOCK_EPOCH_* 给出 → 差值 6 小时'
    echo 'printf "tz_fb=%s\n"    "$(MOCK_TZ=-- MOCK_EPOCH_LOCAL=1000000 MOCK_EPOCH_UTC=978400 tz_offset)"'
    echo 'printf "tz_fbs=%s\n"   "$(MOCK_TZ=-- MOCK_EPOCH_LOCAL=1000000 MOCK_EPOCH_UTC=978400 tz_offset_s)"'
  } > "$SK_WORK/tzd.sh"
  # 输出读进变量、**不落 .work 下的文件**：那些文件会被后面的用例（sk_setup）清掉，
  # 断言就会读成空——「测试看着在跑、其实读到空」比测试失败更坏。
  tzout=$($sksh "$SK_WORK/tzd.sh" 2>&1)

  f="$SK_WORK/prim.txt"
  t_eq "kv_get 按键取值" "$(sk_val "$f" get)" "21:30"
  t_eq "kv_get 键不存在时为空" "$(sk_val "$f" absent)" "[]"
  t_eq "kv_get 文件不存在时为空" "$(sk_val "$f" nofile)" "[]"
  t_eq "kv_set 按传入顺序写成「键=值」行" "$(sk_val "$f" order)" "sign_date=2026-10-03|sign_time=21:30|sign_kind=normal|"
  t_eq "json_first 取数字字段" "$(sk_val "$f" id)" "123"
  t_eq "json_first 取中文字符串字段（去引号）" "$(sk_val "$f" name)" "晚查寝签到"
  t_eq "json_first 取 signState" "$(sk_val "$f" state)" "0"
  t_eq "json_first 取含冒号的字符串字段" "$(sk_val "$f" time)" "2026-10-03 21:30:00"
  t_eq "json_first 字段不存在时为空" "$(sk_val "$f" jtabsent)" "[]"
  t_eq "坐标：顶层是 null 时取到 signInStudent 里的真值" "$(sk_val "$f" coord1)" "118.23577500,25.07802600"
  t_eq "坐标：signInStudent 内嵌对象也不截断（不靠块形状取值）" "$(sk_val "$f" nested)" "118.5,25.5"
  t_eq "坐标：冒号后有空格也能取到" "$(sk_val "$f" space)" "120.1,30.2"
  t_eq "坐标：两份都是 null 时为空" "$(sk_val "$f" allnull)" "[]"
  t_eq "坐标：非数值形状当没取到" "$(sk_val "$f" junk)" "[]"
  t_eq "_json_last 取最后一次出现（与 json_first 相反）" "$(sk_val "$f" last)" "118.5"
  t_eq "tz_offset 输出 [+-]???? 形状的偏移（不能为空）" "$(sk_val "$f" tzshape)" "ok"
  t_eq "tz_offset_s 把 +0800 解成秒数" "$(sk_val "$f" offsets)" "28800"
  # 解析与跑测机器的时区无关：三种输入用替身钉死。CI 跑在 UTC 上（%z = +0000），
  # 所以「零偏移」必须是 0 而不是空——把它当成「判不出来」就把合法值丢了。
  # 诊断行留在上面那张 tzout 里（第一项断言的「实际值」就是它，不必另开用例）
  t_eq "tz_offset_s：整点带分钟 +0545" "$(printf '%s\n' "$tzout" | sed -n 's/^tz_a=//p')" "20700"
  t_eq "tz_offset_s：合法零偏移（UTC runner 上的 %z）解成 0" "$(printf '%s\n' "$tzout" | sed -n 's/^tz_zero=//p')" "0"
  t_eq "tz_offset_s：负偏移 -0530" "$(printf '%s\n' "$tzout" | sed -n 's/^tz_neg=//p')" "-19800"
  t_eq "tz_offset_s：偏移判不出来时给空（与零偏移区分开）" "$(printf '%s\n' "$tzout" | sed -n 's/^tz_bad=//p')" ""
  # 偏移判不出来时 `tz_offset` 仍不输出空（日志的 TZ 段要有东西），但交出去的是 `--(旁证)`
  # 这种**不能当偏移用**的写法：差值只作肉眼判断，绝不参与换算。
  t_eq "tz_offset：判不出来时给 --(旁证)，不给一个可当偏移的值" "$(printf '%s\n' "$tzout" | sed -n 's/^tz_off_bad=//p')" "--(+0)"
  t_eq "退化路径：差值算出来也只作旁证（+6 小时）" "$(printf '%s\n' "$tzout" | sed -n 's/^tz_fb=//p')" "--(+6)"
  t_eq "旁证写法不会被当成偏移解成秒数" "$(printf '%s\n' "$tzout" | sed -n 's/^tz_fbs=//p')" ""
  t_eq "ms_to_hm：真机那个戳在本机偏移下是 21:32（设备 date 给的是 17:09）" "$(sk_val "$f" devlocal)" "21:32"
  t_eq "ms_to_hm：同一戳的 UTC 视角是 13:32（设备 date -u 给的是 09:09）" "$(sk_val "$f" devutc)" "13:32"
  t_eq "ms_to_hm：非整点偏移 +0545" "$(sk_val "$f" half)" "19:02"
  t_eq "ms_to_hm：负偏移 -0500" "$(sk_val "$f" neg)" "08:32"
  t_eq "ms_to_hm：epoch 0 在 +0800 下是 08:00" "$(sk_val "$f" epoch0)" "08:00"
  t_eq "ms_to_hm：跨日取模（第 86400 秒回到 08:00）" "$(sk_val "$f" crossday)" "08:00"
  t_eq "ms_to_hm：缺值给空（调用方据此不写钟点）" "$(sk_val "$f" empty)" "[]"
  # 「偏移判不出来」必须与「按 UTC 算」区分开：前者输出空（宁可不写钟点），后者是第二参省略
  t_eq "ms_to_hm：偏移显式给空时不写钟点（不是按 UTC 硬算）" "$(sk_val "$f" nooff)" "[]"
  t_eq "write_atomic 写入内容" "$(sk_val "$f" atom)" "atom"
  t_eq "write_atomic 拒绝用空内容覆盖已有内容" "$(sk_val "$f" kept)" "atom"
  t_eq "写入与轮转都不留临时文件" "$(sk_val "$f" tmpleft)" "0"
}

sk_case_base_clock() {
  local f ln
  sk_setup
  sk_write_env
  printf '%s\n' '2026-10-01 22:05' > "$SK_WORK/clock"
  sk_run clock <<'DRIVER'
MOCK_DATE_CTL="$T_WORK/clock"
export MOCK_DATE_CTL
{
  printf 'today=%s\n' "$(today)"
  printf 'hm=%s\n'    "$(now_hm)"
  printf 's_ok=%s\n'  "$([ "$(now_s)" -gt 1000000000 ] && echo yes || echo no)"
  log "拨钟检查"
  printf 'logline=%s\n' "$(tail -n 1 "$LOG")"
} > "$T_WORK/clock.txt"
DRIVER

  f="$SK_WORK/clock.txt"
  t_eq "today() 走可注入时间源（拨到 2026-10-01）" "$(sk_val "$f" today)" "2026-10-01"
  t_eq "now_hm() 走可注入时间源（拨到 22:05）" "$(sk_val "$f" hm)" "22:05"
  t_eq "now_s() 仍取真实时间（mock 只接管固定格式）" "$(sk_val "$f" s_ok)" "yes"
  ln=$(sk_val "$f" logline)
  case "$ln" in
    \[[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\ [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\]\ 拨钟检查)
      _t_pass "log() 走同一时间源，时间戳格式不变" ;;
    *)
      _t_fail "log() 的时间戳格式变了：[$ln]" ;;
  esac
}

sk_case_base_rotate() {
  local f
  sk_setup
  sk_write_env
  sk_run rot <<'DRIVER'
{
  # 造一份超过阈值（256KB）的日志
  "$BB" awk 'BEGIN { for (i = 0; i < 9000; i++) print "2026-01-01 00:00:00 填充填充填充填充填充填充填充填充填充填充填充填充" }' > "$LOG"
  printf 'before=%s\n' "$(wc -l < "$LOG" | tr -dc '0-9')"
  rotate_log
  printf 'after=%s\n' "$(wc -l < "$LOG" | tr -dc '0-9')"
  printf 'last=%s\n'  "$(tail -n 1 "$LOG")"
  printf 'tmpleft=%s\n' "$(ls "$MODDIR" | grep -c '\.tmp$')"
} > "$T_WORK/rot.txt"
DRIVER

  f="$SK_WORK/rot.txt"
  t_eq "轮转前：日志确实超过阈值" "$(sk_val "$f" before)" "9000"
  t_eq "轮转后：保留最近 1000 行 + 一条轮转记录" "$(sk_val "$f" after)" "1001"
  t_has "轮转后追加一条记录" "$f" "日志已轮转（保留最近 1000 行）"
  t_eq "轮转不留临时文件" "$(sk_val "$f" tmpleft)" "0"
}

# ============================================================
# 入口：装配与分发
# ============================================================

sk_case_entry_missing_layer() {
  local d rc
  sk_setup
  d=$(sk_stage_module "$SK_WORK/entry")
  rm -f "$d/lib/api.sh"

  # 在模块目录里以相对路径调用入口：入口的「自身路径 → 模块目录」推导在
  # POSIX 绝对路径与相对路径下都要成立（Windows 上的 D:/ 形式只走后者）
  ( cd "$d" && BB_OVERRIDE="$SK_WORK/bin/bb" $(t_sh) "./fafu_checkin.sh" status ) \
    > "$SK_WORK/entry.out" 2> "$SK_WORK/entry.err"
  rc=$?

  t_ne "缺一层：以非 0 退出" "$rc" 0
  t_has "缺一层：报出缺的是哪一层" "$SK_WORK/entry.err" "缺少库层"
  t_has "缺一层：点明具体文件" "$SK_WORK/entry.err" "lib/api.sh"
  t_has "缺一层：写进模块日志（不是只打印）" "$d/fafu_checkin.log" "缺少库层"
  t_has "缺一层：日志里也点明具体文件" "$d/fafu_checkin.log" "lib/api.sh"
  t_hasnt "缺一层：不继续执行子命令" "$SK_WORK/entry.out" "======"
}

sk_case_entry_dispatch() {
  local d rc
  sk_setup
  d=$(sk_stage_module "$SK_WORK/entry2")

  ( cd "$d" && BB_OVERRIDE="$SK_WORK/bin/bb" $(t_sh) "./fafu_checkin.sh" status ) \
    > "$SK_WORK/status.out" 2> "$SK_WORK/status.err"
  rc=$?
  t_eq "层齐：status 正常退出" "$rc" 0
  t_has "status：打印标题" "$SK_WORK/status.out" "====== 数字FAFU 晚查寝自动签到 ======"
  t_has "status：从模块元数据读到版本" "$SK_WORK/status.out" "版本: v"
  t_has "status：默认开关为已启用" "$SK_WORK/status.out" "开关: 🟢 已启用"
  t_has "status：能生成动态描述" "$SK_WORK/status.out" "描述: 🟢 已启用"
  if [ -f "$d/.fafu_checkin.pid" ]; then
    _t_fail "status 不该启动守护进程（出现了 PID 文件）"
  else
    _t_pass "status 不启动守护进程（无 PID 文件）"
  fi

  ( cd "$d" && $(t_sh) "./fafu_checkin.sh" bogus ) > "$SK_WORK/usage.out" 2>&1
  rc=$?
  t_ne "未知子命令：以非 0 退出" "$rc" 0
  t_has "未知子命令：打印用法" "$SK_WORK/usage.out" "用法: sh "
}

# 开关文件的往返：夹具按**旧版本写下的格式**写文件，入口必须原样读出来。
# 这条跨过了「夹具 → 真实入口」两侧，是「格式没变」这件事最直接的一条断言。
sk_case_entry_switch_file() {
  local d rc stat
  sk_setup
  d=$(sk_stage_module "$SK_WORK/entry3")
  stat="$d/fafu-checkin.state"

  printf 'disabled\n' > "$stat"
  ( cd "$d" && BB_OVERRIDE="$SK_WORK/bin/bb" $(t_sh) "./fafu_checkin.sh" status ) \
    > "$SK_WORK/off.out" 2> "$SK_WORK/off.err"
  rc=$?
  t_eq "停用态：status 正常退出" "$rc" 0
  t_has "停用态：status 报告已停用" "$SK_WORK/off.out" "开关: ⏸ 已停用"
  t_has "停用态：描述也显示已停用" "$SK_WORK/off.out" "描述: ⏸ 已停用"

  printf 'enabled\n' > "$stat"
  ( cd "$d" && BB_OVERRIDE="$SK_WORK/bin/bb" $(t_sh) "./fafu_checkin.sh" status ) \
    > "$SK_WORK/on.out" 2> "$SK_WORK/on.err"
  rc=$?
  t_eq "启用态：status 正常退出" "$rc" 0
  t_has "启用态：status 报告已启用" "$SK_WORK/on.out" "开关: 🟢 已启用"
  t_has "启用态：描述也显示已启用" "$SK_WORK/on.out" "描述: 🟢 已启用"
}

# ============================================================
# 打包：清单、权限、产物校验
# ============================================================

# 打包用例的静态那半：权限归属、页面资源里不需要 zip 的两条结构断言。
sk_package_static() {
  local page
  page="$T_ROOT/webroot/index.html"

  t_has "安装脚本覆盖库层" "$T_ROOT/customize.sh" '"$MODPATH"/lib/*.sh'
  t_has "安装脚本给库层数据权限（0644）" "$T_ROOT/customize.sh" 'set_perm "$f" 0 0 0644'
  t_hasnt "卸载脚本不删除库层文件" "$T_ROOT/uninstall.sh" 'rm -f "$MODDIR/lib'
  # 页面资源目录的权限与安全上下文由管理器在安装时设置：安装脚本不该提到这个目录
  t_hasnt "安装脚本不碰页面资源目录" "$T_ROOT/customize.sh" 'webroot'
  # 打包清单纳入页面资源目录（是否真的进包由下面的构建分支按路径核对）
  t_has_re "打包清单纳入页面资源目录" "$T_ROOT/build.sh" '^DIRS=.*webroot'

  # 结构断言一：页面入口文件在源树里（清单写的路径必须真的存在）
  t_file "页面入口文件在源树里" "$page"
  # 结构断言三：页面文本不含任何外部 URL（判据只有 tools/lib.sh 里一份）
  t_eq "页面文本不含任何外部 URL" "$(ext_url_hits "$page")" ""
}

# 判据自证：ext_url_hits 必须真的会命中，否则「页面零命中」只是恒真的摆设。
# 样本里的链接一律在运行时拼出来：这两个 .sh 自己也在「零外部资源」这条口径的覆盖范围内，
# 连两个斜杠都单独拎出来，免得口径和它的样本互相打架（单个斜杠不构成任何形状）。
SK_SLASH2='//'
sk_page_scan_self_check() {
  local d scheme upper rel clean
  d="$SK_WORK/scan"
  mkdir -p "$d"
  scheme="$d/scheme.html"
  upper="$d/upper.html"
  rel="$d/rel.html"
  clean="$d/clean.html"

  printf '<link rel="stylesheet" href="ht%s">\n' "tps:${SK_SLASH2}cdn.example.com/a.css" > "$scheme"
  printf '<script src="HT%s"></script>\n' "TPS:${SK_SLASH2}CDN.EXAMPLE.COM/b.js" > "$upper"
  printf '<script src="/%s"></script>\n' '/cdn.example.com/c.js' > "$rel"
  {
    printf '<img src="/local/pic.png">\n'
    printf '<style>body{background:#fff}/* 块注释 */</style>\n'
    printf '<script>\n// 行注释\n'
    printf '//无空格的行注释\n'
    printf '</script>\n'
  } > "$clean"

  t_ne "自证：带协议头的链接会被扫出来" "$(ext_url_hits "$scheme")" ""
  t_ne "自证：协议头大小写变形也会被扫出来" "$(ext_url_hits "$upper")" ""
  t_ne "自证：省略协议头的链接会被扫出来" "$(ext_url_hits "$rel")" ""
  t_eq "自证：干净样本零命中（判据不是恒真）" "$(ext_url_hits "$clean")" ""
  # 构建脚本开着 set -e，零命中是正常答案：判据不能把「没找到」的状态码漏给调用方。
  # 直接看状态码——用例跑在 if 条件里（run-tests.sh 的 T_RUN），那种上下文会抑制
  # errexit，改用子 shell 试 set -e 就成了永远为真的摆设。
  ext_url_hits "$clean" > /dev/null
  t_true "自证：零命中以 0 退出（构建脚本开着 set -e）" "$?"
}

# 打包用例的动态那半：真打一次包，核对产物里逐个文件都在，再跑三条反向。
# 本机（Windows）没有 zip/unzip，这一段只在 CI 上跑。
sk_package_build() {
  local pkg zip rc f
  sk_setup
  pkg="$SK_WORK/pkg"
  mkdir -p "$pkg/tools"
  for f in module.prop customize.sh service.sh action.sh uninstall.sh fafu_checkin.sh build.sh; do
    cp "$T_ROOT/$f" "$pkg/"
  done
  cp "$T_ROOT/tools/lib.sh" "$pkg/tools/"
  cp -R "$T_ROOT/lib" "$pkg/lib"
  cp -R "$T_ROOT/webroot" "$pkg/webroot"

  ( cd "$pkg" && sh build.sh dev ) > "$SK_WORK/pkg.out" 2>&1
  rc=$?
  zip=$(ls "$pkg"/dist/*.zip 2>/dev/null | head -n1)
  t_eq "层齐：构建成功" "$rc" 0
  t_file "层齐：产物已生成" "$zip"
  if [ -n "$zip" ]; then
    unzip -l "$zip" > "$SK_WORK/pkg.list" 2>&1
    for f in $TEST_LIB_FILES; do
      t_has "产物含层文件 $f" "$SK_WORK/pkg.list" " $f"
    done
    # 结构断言二：页面入口文件确实在产物里，且是清单里那个路径
    t_has "产物含页面入口 webroot/index.html" "$SK_WORK/pkg.list" " webroot/index.html"
  fi

  # 反向一：少一层必须构建失败（半装是最难排查的失败模式）
  rm -f "$pkg/lib/api.sh"
  ( cd "$pkg" && sh build.sh dev ) > "$SK_WORK/pkg2.out" 2>&1
  rc=$?
  t_ne "缺一层：构建失败" "$rc" 0
  t_has "缺一层：报出缺的是哪一层" "$SK_WORK/pkg2.out" "缺少 lib/api.sh"

  # 反向二：页面没进包也必须构建失败（「装完点不开」不能等使用者发现）
  cp "$T_ROOT/lib/api.sh" "$pkg/lib/api.sh"
  rm -f "$pkg/webroot/index.html"
  ( cd "$pkg" && sh build.sh dev ) > "$SK_WORK/pkg3.out" 2>&1
  rc=$?
  t_ne "页面没进包：构建失败" "$rc" 0
  t_has "页面没进包：报出缺的是哪个文件" "$SK_WORK/pkg3.out" "webroot/index.html"

  # 反向三：页面里人为引入一条外部链接，构建同样必须失败
  cp "$T_ROOT/webroot/index.html" "$pkg/webroot/index.html"
  printf '<link rel="stylesheet" href="ht%s">\n' "tps:${SK_SLASH2}cdn.example.com/a.css" >> "$pkg/webroot/index.html"
  ( cd "$pkg" && sh build.sh dev ) > "$SK_WORK/pkg4.out" 2>&1
  rc=$?
  t_ne "页面引入外部链接：构建失败" "$rc" 0
  t_has "页面引入外部链接：报出原因" "$SK_WORK/pkg4.out" "外部资源"
}

sk_case_package() {
  sk_package_static
  sk_page_scan_self_check

  if ! command -v zip >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1; then
    # 跳过不计入通过，避免「本机没跑」被读成「已验证」
    t_skip "打包产物校验（本机没有 zip/unzip；CI 上会跑）"
    return 0
  fi
  sk_package_build
}

# ---- 注册（顺序即执行顺序） ----

t_case "skeleton · base · 键值读写与 JSON 单字段" sk_case_base_primitives
t_case "skeleton · base · 时间源可拨钟" sk_case_base_clock
t_case "skeleton · base · 日志轮转" sk_case_base_rotate
t_case "skeleton · 入口 · 缺层时明确失败" sk_case_entry_missing_layer
t_case "skeleton · 入口 · 装配与命令分发" sk_case_entry_dispatch
t_case "skeleton · 入口 · 开关文件往返（旧格式仍可读）" sk_case_entry_switch_file
t_case "skeleton · 打包 · 产物含全部层文件与页面入口" sk_case_package
