#!/bin/sh
# ============================================================
# 模块断言总入口 —— 不需要手机、不需要 root、不需要网络
#
# 用法（在本仓库根目录执行）：
#   sh tools/run-tests.sh              # 跑全部用例
#   sh tools/run-tests.sh ^layer       # 只跑 layer 套件（^ 表示前缀匹配）
#   sh tools/run-tests.sh 通知          # 只跑名字里含「通知」的用例
#
# shell 选择：
#   - CI（ubuntu）直接用系统 sh 跑（下面就是普通 POSIX sh），断言文件保持 POSIX 兼容；
#   - 本机（Windows）没有独立 sh：在 tools/busybox/ 放一个 busybox（该目录不入库），
#     或用 TEST_BUSYBOX=<路径> 指定；本脚本会用 busybox sh 重新执行自己。
# ============================================================

set -e
cd "$(dirname "$0")/.."
ROOT="$PWD"
export T_ROOT="$ROOT"

. "$ROOT/tools/lib.sh"

# ---- 定位随附 busybox；找不到就退回系统 sh（CI 路径） ----
BB=$(find_busybox)

# 已经在 busybox 的 ash 下（ash 会导出 $BUSYBOX）就不再套壳
case "${BUSYBOX:-}" in
  *ash*) BB="" ;;
esac

if [ -n "$BB" ]; then
  exec "$BB" sh "$ROOT/tools/run-tests.sh" "$@"
fi

echo "断言总入口 · 仓库根：$ROOT"
if [ -n "${BUSYBOX:-}" ]; then
  echo "shell：busybox sh ($BUSYBOX)"
else
  echo "shell：系统 sh"
fi
echo ""

. "$ROOT/tests/harness.sh"

# 用例筛选关键字（可选）：T_NAMES 为空则跑全部
T_NAMES="$*"

# 用例文件：tests/ 下不以 _ 开头的 .sh；每个文件跑完自己的用例再换下一个，
# 这样某个文件里注册出错不会连累其他文件（harness.sh 里已关掉 set -e）
FAILED=0
ALL_PASS=0
ALL_FAIL=0
for f in "$ROOT"/tests/*.sh; do
  [ -f "$f" ] || continue
  case "${f##*/}" in
    _*|harness.sh) continue ;;
  esac
  T_CASES=""
  . "$f"
  if T_RUN; then :; else FAILED=1; fi
  ALL_PASS=$((ALL_PASS + T_PASS))
  ALL_FAIL=$((ALL_FAIL + T_FAIL))
done

echo ""
echo "=============================================="
echo " 合计：$ALL_PASS 通过 / $ALL_FAIL 失败（共 $((ALL_PASS + ALL_FAIL)) 项）"
echo "=============================================="

# 总入口的退出码：全部用例通过才 0，便于 CI 与 pre-commit 直接判定
exit $FAILED
