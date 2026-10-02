# ============================================================
# 测试底座：断言原语、用例注册与汇总、shell 与库文件定位
#
# 约定：
#   - 用例文件放在 tests/ 下、文件名不以 _ 开头，只定义函数并调用 t_case 注册；
#   - 用例内的断言只描述外部行为（返回码、文件产物、交给系统执行的命令字符串），
#     不断言行号，也不断言行内的实现写法；
#   - 断言函数内部一律用 local，避免上游循环变量被下游断言悄悄覆盖（草稿区旧版踩过）。
#
# 由 tools/run-tests.sh 加载；单独跑某个用例见 tools/run-tests.sh --help。
# ============================================================

# 调用方可能开着 set -e（tools/run-tests.sh 就有）。断言经常需要「看某个命令失败」
# （检查器应当非 0 退出、子进程应当报错），开着 set -e 会让用例在第一次非 0 处直接死掉、
# 后面所有断言静默消失。测试期间一律关掉。
set +e

T_PASS=0
T_FAIL=0

# 仓库根目录：本文件位于 <root>/tests/
T_ROOT=$(cd "$(dirname "$0")/.." && pwd)

# busybox 定位与 tools/ 共用（避免本机与 CI 各用一套规则）
. "$T_ROOT/tools/lib.sh"

# ---- 被测源码清单（依赖顺序；必须是库里实际加载的顺序） ----
# 重构过渡期：库与程序仍在同一个文件里，tests/ 通过 TEST_BOUNDARY 只截取库段。
# 拆分完成后：把 lib 文件名按入口加载顺序追加到 TEST_LIB_FILES，并清空 TEST_BOUNDARY。
# 层清单的真源在 tools/check-layer-order.sh（守卫那边），这里不重复维护一份。
TEST_LIB_FILES="fafu_checkin.sh"
TEST_BOUNDARY='# ---- 子命令分发 ----'

# 用例工作目录：临时文件、mock 工具链、驱动脚本都放这里，跑完保留供排查
T_WORK_ROOT="$T_ROOT/tests/.work"

# ------------------------------------------------------------
# shell / 工具链定位
# ------------------------------------------------------------

# 查找随附 busybox（实现在 tools/lib.sh，与守卫共用同一套规则）
t_find_busybox() {
  find_busybox
}

# 输出「以本机 shell 执行某个脚本」的命令前缀
t_sh() {
  local bb
  bb=$(t_find_busybox)
  if [ -n "$bb" ]; then
    printf '%s sh' "$bb"
  else
    printf 'sh'
  fi
}

# 生成 mock busybox 的调用包装（tests/mock/busybox 是 POSIX 脚本，需要一个 shell 去跑它）。
# 之所以在运行时生成：包装内容依赖本机真实 busybox 的路径（Windows 上是 .exe），
# 把它固化进仓库就等于把某台机器的路径写死在测试里。
t_bb_wrap() {
  local bb real out
  bb=$(t_find_busybox)
  # 没有独立 busybox 文件时（例如已经在 busybox sh 里）用 applet 名，
  # 真实调用由当前 shell 里的 busybox 承接
  [ -n "$bb" ] || bb="busybox"
  out="${1:-$T_WORK/bin/bb}"
  mkdir -p "$(dirname "$out")"
  case "$bb" in
    *.exe|*.EXE) real="$bb sh \"\$0\" \"\$@\"" ;;   # Windows：借 busybox.exe 跑这个 sh 脚本
    *)           real="$bb \"\$0\" \"\$@\"" ;;
  esac
  {
    echo '#!/bin/sh'
    echo '# 由 tests/harness.sh 生成：把 applet 调用转发给 mock 脚本，再透传给真实 busybox'
    echo "BB_REAL='$bb'"
    echo "MOCK_DIR='$T_ROOT/tests/mock'"
    echo 'export BB_REAL'
    echo 'exec "$MOCK_DIR/busybox" "$@"'
  } > "$out"
  chmod +x "$out" 2>/dev/null || true
  printf '%s' "$out"
}

# 「今天」（YYYY-MM-DD）：用真实 busybox 取，绕开 mock 时钟。
# 用例用它断言「落到状态文件里的日期就是今天」——断言因此不依赖具体日期。
t_today() {
  local bb
  bb=$(t_find_busybox)
  if [ -n "$bb" ]; then
    "$bb" date +%Y-%m-%d
  else
    date +%Y-%m-%d
  fi
}

# ------------------------------------------------------------
# 用例注册与执行
# ------------------------------------------------------------

# t_case <名称> <处理函数>
# 用例名含空格，故按整行记录（用 $T_CASES 直接 for 会被拆词，踩过）
t_case() {
  T_CASES="$T_CASES$1|$2
"
}

# 依次执行用例；T_NAMES 非空时只跑匹配的用例。
# 关键字是子串匹配；以 ^ 开头表示「只能用在前缀」（例：^layer 只跑 layer 套件，
# 不会误伤名字里恰好含 layer 的其它用例）。
T_RUN() {
  local c n hit pat
  # 每个用例文件单独计数：_t_summary 报的是本文件的结果，总入口再累加
  T_PASS=0
  T_FAIL=0
  # 用 here-doc 供 stdin（而不是管道）：断言计数在 while 里累加，
  # 管道会让 while 落进子 shell，计数丢失（踩过）
  while IFS='|' read -r c n; do
    [ -n "$c" ] || continue
    hit=1
    if [ -n "$T_NAMES" ]; then
      hit=0
      for w in $T_NAMES; do
        case "$w" in
          '^'*) pat="${w#^}"; case "$c" in "$pat"*) hit=1 ;; esac ;;
          *)    case "$c" in *"$w"*) hit=1 ;; esac ;;
        esac
      done
    fi
    [ "$hit" = "1" ] || continue
    _t_banner "$c"
    "$n"
  done <<EOF
$T_CASES
EOF
  _t_summary
}

_t_banner() {
  echo ""
  echo "【$1】"
}

_t_summary() {
  echo ""
  echo "=============================================="
  echo " 结果：$T_PASS 通过 / $T_FAIL 失败（共 $((T_PASS + T_FAIL)) 项）"
  echo "=============================================="
  [ "$T_FAIL" -eq 0 ]
}

_t_pass() {
  T_PASS=$((T_PASS + 1))
  echo "  [PASS] $1"
}

_t_fail() {
  T_FAIL=$((T_FAIL + 1))
  echo "  [FAIL] $1"
}

# ------------------------------------------------------------
# 断言原语
# ------------------------------------------------------------

# 相等：t_eq <说明> <实际> <期望>
t_eq() {
  if [ "$2" = "$3" ]; then _t_pass "$1 ($2)"; else _t_fail "$1: 期望 [$3] 实际 [$2]"; fi
}

t_ne() {
  if [ "$2" != "$3" ]; then _t_pass "$1 ($2)"; else _t_fail "$1: 不应等于 [$3]"; fi
}

t_true() {
  if [ "$2" = "0" ]; then _t_pass "$1"; else _t_fail "$1（返回 $2）"; fi
}

# 文件存在且非空：t_file <说明> <路径>
t_file() {
  if [ -s "$2" ]; then _t_pass "$1"; else _t_fail "$1（$2 不存在或为空）"; fi
}

# 把 grep 结果写进临时文件并输出匹配行数。
# 不走 $( ) + 管道：本机 busybox（Windows 版）在这种嵌套命令替换下会直接栈溢出崩掉，
# 写文件是等价且稳定的做法。
_t_grep_count() { # $1=模式 $2=-F|-E $3=文件
  local f="$T_WORK_ROOT/.grep.tmp"
  mkdir -p "$T_WORK_ROOT"
  grep "$2" -e "$1" -- "$3" > "$f" 2>/dev/null
  grep -c . "$f" > "$T_WORK_ROOT/.grep.n" 2>/dev/null
  cat "$T_WORK_ROOT/.grep.n" 2>/dev/null
}

# 行数相等：t_lines <说明> <路径> <期望行数>
t_lines() {
  local c
  c=$(grep -c . "$2" 2>/dev/null)
  [ -n "$c" ] || c=0
  t_eq "$1" "$c" "$3"
}

# 文件里出现该字符串（出现次数 ≥1）：t_has <说明> <文件> <模式> [次数]
t_has() {
  local n
  n=$(_t_grep_count "$3" -F "$2")
  [ -n "$n" ] || n=0
  if [ "$n" -ge 1 ] && { [ -z "${4:-}" ] || [ "$n" = "$4" ]; }; then
    _t_pass "$1 ($n 处)"
  else
    _t_fail "$1（未找到 [$3]，实际 $n 处）"
  fi
}

# 文件里不该出现该字符串：t_hasnt <说明> <文件> <模式>
t_hasnt() {
  local n
  n=$(_t_grep_count "$3" -F "$2")
  [ -n "$n" ] || n=0
  if [ "$n" -eq 0 ]; then _t_pass "$1"; else _t_fail "$1（不该出现 [$3]，实际 $n 处）"; fi
}

# 相对顺序：t_before <说明> <文件> <前模式> <后模式>
# 用「锚点字符串的先后」代替行号比较，重构搬代码不会制造假红灯，但顺序真的变了会红。
# t_call 用来把锚点钉在**调用点**上（模式前带空格），而不是函数定义上。
t_before() {
  local a b
  a=$(grep -nF -m1 -e "$3" -- "$2" 2>/dev/null | cut -d: -f1)
  b=$(grep -nF -m1 -e "$4" -- "$2" 2>/dev/null | cut -d: -f1)
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then
    _t_pass "$1"
  else
    _t_fail "$1（前=[$3]@${a:-未找到} 后=[$4]@${b:-未找到}）"
  fi
}

# 「某个函数的首次调用」锚点：函数定义形如 `name() {`，调用点前面必有分隔符
t_call() {
  printf ' %s' "$1"
}

# ------------------------------------------------------------
# 库加载
# ------------------------------------------------------------

# 拼出被测库字符串放到 $1。
#
# 过渡期做法：库段仍在 fafu_checkin.sh 里，按 TEST_BOUNDARY 只取标记之前的部分，
# 这样断言可以 source 真实的库（而不是从源码里抽取片段再拼接）。
# 声明了 TEST_BOUNDARY 却在源码里找不到它时必须**明确失败**：静默地整文件加载会把
# 程序段（子命令分发）也执行一遍，测试会以难以理解的方式炸掉。
# 分层完成后把 TEST_BOUNDARY 清空即可（那时每个文件本身就是库）。
t_write_lib() {
  local out f src n
  out="$1"
  : > "$out"
  for f in $TEST_LIB_FILES; do
    src="$T_ROOT/$f"
    if [ ! -f "$src" ]; then
      echo "找不到被测源码：$src（见 tests/harness.sh 的 TEST_LIB_FILES）" >&2
      return 1
    fi
    if [ -n "$TEST_BOUNDARY" ]; then
      if ! grep -qF -e "$TEST_BOUNDARY" -- "$src" 2>/dev/null; then
        echo "源码里找不到库段边界 [$TEST_BOUNDARY]：$f" >&2
        echo "（边界改名或已拆层时，请同步 tests/harness.sh 的 TEST_BOUNDARY）" >&2
        return 1
      fi
      n=$(grep -nF -m1 -e "$TEST_BOUNDARY" -- "$src" | cut -d: -f1)
      sed -n "1,$((n - 1))p" "$src" >> "$out"
    else
      cat "$src" >> "$out"
    fi
  done
  [ -s "$out" ]
}
