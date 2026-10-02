# ============================================================
# 骨架验收断言：base 层原语、入口装配、打包管道
#
# 三块都只针对「外部可观察的行为」：
#   base 原语：函数的输出、落盘内容、轮转后的行数（含拨钟与「空内容不覆盖」）；
#   入口：缺一层时写模块日志并以非 0 退出；层齐时能装配起来跑通子命令分发；
#   打包：产物里确实有每个层文件、少一个就构建失败（本机没有 zip/unzip 时跳过该项）。
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
# 入口按自身路径定位模块目录，故副本能自己跑起来，不会碰到仓库本身。
sk_stage_module() { # $1=目标目录
  local d f
  d="$1"
  rm -rf "$d"
  mkdir -p "$d/lib"
  cp "$T_ROOT/fafu_checkin.sh" "$T_ROOT/module.prop" "$d/"
  for f in $TEST_LIB_FILES; do
    cp "$T_ROOT/$f" "$d/$f"
  done
  printf '%s' "$d"
}

# 从驱动输出里取一行（形如 key=value）
sk_val() { # $1=文件 $2=键
  sed -n "s/^$2=//p" "$1"
}

# ============================================================
# base 层原语
# ============================================================

sk_case_base_primitives() {
  local f
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

  # 原子写：内容落盘且不留临时文件；空内容不覆盖已有内容（别把状态清空）
  printf 'atom\n' | write_atomic "$T_WORK/mod/atom.txt"
  printf 'atom=%s\n' "$(cat "$T_WORK/mod/atom.txt")"
  printf '' | write_atomic "$T_WORK/mod/atom.txt"
  printf 'kept=%s\n' "$(cat "$T_WORK/mod/atom.txt")"
  printf 'tmpleft=%s\n' "$(ls "$T_WORK/mod" | grep -c '\.tmp$')"
} > "$T_WORK/prim.txt"
DRIVER

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

sk_case_package() {
  local pkg zip rc f
  # 静态部分：权限归属与「卸载不删自己的代码」
  t_has "安装脚本覆盖库层" "$T_ROOT/customize.sh" '"$MODPATH"/lib/*.sh'
  t_has "安装脚本给库层数据权限（0644）" "$T_ROOT/customize.sh" 'set_perm "$f" 0 0 0644'
  t_hasnt "卸载脚本不删除库层文件" "$T_ROOT/uninstall.sh" 'rm -f "$MODDIR/lib'

  # 动态部分：真的打一次包，逐个核对产物里的层文件。本机（Windows）没有 zip/unzip，
  # 这一支只在 CI 上跑；跳过不计入通过，避免「本机没跑」被读成「已验证」。
  if ! command -v zip >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1; then
    t_skip "打包产物校验（本机没有 zip/unzip；CI 上会跑）"
    return 0
  fi

  sk_setup
  pkg="$SK_WORK/pkg"
  mkdir -p "$pkg/tools"
  for f in module.prop customize.sh service.sh action.sh uninstall.sh fafu_checkin.sh build.sh; do
    cp "$T_ROOT/$f" "$pkg/"
  done
  cp "$T_ROOT/tools/lib.sh" "$pkg/tools/"
  cp -R "$T_ROOT/lib" "$pkg/lib"

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
  fi

  # 反向：少一层必须构建失败（半装是最难排查的失败模式）
  rm -f "$pkg/lib/api.sh"
  ( cd "$pkg" && sh build.sh dev ) > "$SK_WORK/pkg2.out" 2>&1
  rc=$?
  t_ne "缺一层：构建失败" "$rc" 0
  t_has "缺一层：报出缺的是哪一层" "$SK_WORK/pkg2.out" "缺少 lib/api.sh"
}

# ---- 注册（顺序即执行顺序） ----

t_case "skeleton · base · 键值读写与 JSON 单字段" sk_case_base_primitives
t_case "skeleton · base · 时间源可拨钟" sk_case_base_clock
t_case "skeleton · base · 日志轮转" sk_case_base_rotate
t_case "skeleton · 入口 · 缺层时明确失败" sk_case_entry_missing_layer
t_case "skeleton · 入口 · 装配与命令分发" sk_case_entry_dispatch
t_case "skeleton · 入口 · 开关文件往返（旧格式仍可读）" sk_case_entry_switch_file
t_case "skeleton · 打包 · 产物含全部层文件" sk_case_package
