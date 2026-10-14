#!/bin/sh
# ============================================================
# 模块断言总入口 —— 不需要手机、不需要 root、不需要网络
#
# 用法（在本仓库根目录执行）：
#   sh tools/run-tests.sh              # 跑全部用例
#   sh tools/run-tests.sh ^layer       # 只跑 layer 套件（^ 表示前缀匹配）
#   sh tools/run-tests.sh -j 4         # 并行跑：一次 4 个用例文件（也可用 TEST_JOBS 指定）
#   busybox sh tools/run-tests.sh      # 本机（Windows）没有系统 sh 时这样跑
#
# shell 与 busybox：CI（ubuntu）用系统 sh 跑，断言文件保持 POSIX 兼容。断言里的 mock
#   时间源需要一个**真实 busybox** 承接其余 applet（见 tests/mock/busybox），它由
#   tools/lib.sh 的 find_busybox 定位：显式指定 > 仓库内 tools/busybox/ > 系统安装。
#   并行时每个用例文件由一个子进程跑，子进程的 shell 同样按这套规则挑，不由本脚本重定。
# ============================================================

set -e
cd "$(dirname "$0")/.."
ROOT="$PWD"
export T_ROOT="$ROOT"

. "$ROOT/tools/lib.sh"

# ---- worker 模式：被总入口挑中、只跑一个用例文件 ----
# 总入口并行跑时用自己拉起子进程、每个子进程跑一个文件（T_WORK_ROOT 各不相同，
# 故固定名的子目录不会互相覆盖）。子进程的输出由总入口按顺序原样打印。
# 筛选关键字原样透传，不做「文件名 → 用例名前缀」的换算：两者本来就不总是一致
# （文件 layer-order.sh 里的用例名前缀是 layer）。
# 子进程里没有 set -e：`T_RUN` 的返回值就是失败信号，交给总入口记。
# 变量名带下划线前缀，是为了不与调用方环境里的通用名相撞——撞上就会把整轮跑静默切进
# 「只跑一个文件」的模式（忽略全部参数、还不打 banner），那比报错更难发现。
if [ -n "${_T_WORKER_SUITE:-}" ]; then
  if [ ! -f "$ROOT/tests/$_T_WORKER_SUITE" ]; then
    echo "worker：找不到用例文件 tests/$_T_WORKER_SUITE" >&2
    exit 2
  fi
  # 关掉 set -e：用例里「命令返回非 0」是正常路径（比返回值、看日志），
  # 失败靠 _t_fail 计数、由 T_RUN 的返回值汇总。开着 set -e 会让子进程在第一条
  # 非 0 断言处直接消失——表现为「没有横幅、只有空汇总」。
  set +e
  . "$ROOT/tests/harness.sh"
  . "$ROOT/tests/$_T_WORKER_SUITE"
  if T_RUN; then exit 0; else exit 1; fi
fi

JOBS="${TEST_JOBS:-1}"
# 不清空 T_NAMES：并行时它是父进程透传下来的筛选关键字（清空就等于所有子进程都跑全套）
T_NAMES="${T_NAMES:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    -j|--jobs)
      # 并行度是紧跟其后的那个参数，不能落到用例筛选关键字里（筛选关键字按子串匹配，
      # 一个数字会匹配到一批无关用例）。只认纯数字，免得把后面的筛选关键字吃掉。
      case "${2:-}" in
        ''|*[!0-9]*) echo "-j 后面要给并行度（非负整数）" >&2; exit 2 ;;
      esac
      JOBS="$2"
      shift 2
      continue
      ;;
    -j*)      JOBS="${1#-j}" ;;
    --jobs=*) JOBS="${1#--jobs=}" ;;
    *)
      # 筛选关键字按**字面量**收下，不剥引号也不做别的加工：旧行为就是 `T_NAMES="$*"`
      # 原样透传，一个带空格的关键字串（'^a ^b'）在旧实现里是「两个词」，必须保持
      T_NAMES="$T_NAMES $1" ;;
  esac
  shift
done

case "$JOBS" in
  ''|*[!0-9]*) echo "并行度必须是非负整数（当前：[$JOBS]）" >&2; exit 2 ;;
esac
# 0 或 1 都按串行跑（0 与 make 的语义一致：不并行）
[ "$JOBS" -ge 2 ] || JOBS=1

echo "断言总入口 · 仓库根：$ROOT"
echo "shell：${BUSYBOX:+busybox }sh${BUSYBOX:+（$BUSYBOX）}"
echo "mock 用的真实 busybox：$(find_busybox || echo '（未找到——用到 mock 的断言会明确报错）')"
echo ""

# 本机（Windows）没有系统 sh，子进程要借随附的 busybox 起
run_sh() {
  local bb
  bb=$(find_busybox)
  if [ -n "$bb" ]; then "$bb" sh "$@"; else sh "$@"; fi
}

# 用例文件：tests/ 下不以 _ 开头的 .sh、且不是 harness 自己；每个文件跑完自己的用例
# 再换下一个，这样某个文件里注册出错不会连累其他文件。
# 顺序按**耗时降序**排（signin 一个就占全量三分之一以上）：并行时先起最长的，
# 关键路径才不会被一小撮长套件拖住。新增用例文件请按耗时插进这个清单；
# 没登记的会被下面的兜底扫描按文件名顺序补在末尾，不会被漏掉。
SUITE_ORDER="signin.sh commands.sh poll.sh api.sh keepalive.sh notify.sh config.sh state.sh
device.sh headers.sh skeleton.sh layer-order.sh"
SUITES=""
for s in $SUITE_ORDER; do
  [ -f "$ROOT/tests/$s" ] && SUITES="$SUITES $s"
done
for f in "$ROOT"/tests/*.sh; do
  [ -f "$f" ] || continue
  s="${f##*/}"
  case "$s" in
    _*|harness.sh) continue ;;
  esac
  case " $SUITES " in
    *" $s "*) ;;
    *) SUITES="$SUITES $s" ;;   # 没登记的兜底，保证新文件不会被漏掉
  esac
done
SUITES="${SUITES# }"

# 一个用例文件一份工作根：固定名的子目录（api / state / …）才不会在并发时互相覆盖。
# 串行也走这里，故清理范围只是这个工作根，不碰 tests/.work 下的历史产物。
# 根目录可由 T_WORK_BASE 重定向：两趟 run-tests 同时跑时，各自指一处才不会互删。
WORK="${T_WORK_BASE:-$ROOT/tests/.work-run}"
ALL_PASS=0
ALL_FAIL=0
ALL_SKIP=0
FAILED=0
BATCH=""

run_batch() {
  local s d RES S_PASS S_FAIL S_SKIP
  # 先全部起好，再一次 `wait`（不带参数 = 等所有后台任务）。
  # 不用 `wait <一个个 pid>`：本机 busybox 上那个写法会漏、还会重复等同一个 pid
  # （第二次直接 rc=127），结果是父进程在子进程写完之前就去读它的输出。
  for s in $BATCH; do
    d="$WORK/$s"
    mkdir -p "$d"
    _T_WORKER_SUITE="$s" T_NAMES="$T_NAMES" T_WORK_ROOT="$d" \
      run_sh "$ROOT/tools/run-tests.sh" > "$d.out" 2>&1 &
  done
  # wait 会把「最后一个」子进程的退出码当自己的返回值（有用例失败时就是 1）。
  # 父脚本开着 set -e，不收这个码就会在打印任何输出之前直接死掉——失败判定一律
  # 由下面的计数决定，不看这里的退出码。
  wait || true
  for s in $BATCH; do
    d="$WORK/$s"
    cat "$d.out"
    # 计数只从子进程自己的「结果」行里取（每个用例文件一个子进程，计数各报各的），
    # 用与打印端同一套 sed 取法。**不能按空格切字段再滤数字**：那一行的第 2 个字段是
    # 「结果：74」这种「汉字+数字」，滤完会把「通过数」和后面的「总数」粘成一个数。
    RES=$(grep '^ 结果：' "$d.out" | head -n1)
    if [ -z "$RES" ]; then
      # 子进程没跑到汇总行（崩了 / 被打断）：不能当成「0 通过 0 失败」，那会被读成通过
      echo "  [FAIL] $s 没产出结果行——这个用例文件没有跑完" >&2
      FAILED=1
      continue
    fi
    S_PASS=$(printf '%s' "$RES" | sed -n 's/^ 结果：\([0-9][0-9]*\) 通过.*/\1/p')
    S_FAIL=$(printf '%s' "$RES" | sed -n 's/.*通过 \/ \([0-9][0-9]*\) 失败.*/\1/p')
    S_SKIP=$(printf '%s' "$RES" | sed -n 's/.*跳过 \([0-9][0-9]*\) 项.*/\1/p')
    # 兜底：汇总行没解析出「失败数」时，看输出里到底有没有 [FAIL] 行。有就说明
    # 这个用例文件确实有失败——不能因为汇总格式变了就把失败静默记成 0。
    if [ -z "$S_FAIL" ] && grep -q '\[FAIL\]' "$d.out"; then
      echo "  [FAIL] $s 的结果行没解析出失败数，但输出里有 [FAIL] 行" >&2
      FAILED=1
    fi
    ALL_PASS=$((ALL_PASS + ${S_PASS:-0}))
    ALL_FAIL=$((ALL_FAIL + ${S_FAIL:-0}))
    ALL_SKIP=$((ALL_SKIP + ${S_SKIP:-0}))
  done
  BATCH=""
}

rm -rf "$WORK"
mkdir -p "$WORK"
for s in $SUITES; do
  BATCH="$BATCH $s"
  [ "$(printf '%s\n' $BATCH | grep -c .)" -ge "$JOBS" ] && run_batch
done
[ -n "$BATCH" ] && run_batch
[ "$ALL_FAIL" -eq 0 ] || FAILED=1

echo ""
echo "=============================================="
if [ "$ALL_SKIP" -gt 0 ]; then
  echo " 合计：$ALL_PASS 通过 / $ALL_FAIL 失败（共 $((ALL_PASS + ALL_FAIL)) 项）；跳过 $ALL_SKIP 项（本机缺工具）"
else
  echo " 合计：$ALL_PASS 通过 / $ALL_FAIL 失败（共 $((ALL_PASS + ALL_FAIL)) 项）"
fi
echo "=============================================="

# 总入口的退出码：全部用例通过才 0，便于 CI 与 pre-commit 直接判定
exit $FAILED
