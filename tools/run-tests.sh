#!/bin/sh
# ============================================================
# 模块断言总入口 —— 不需要手机、不需要 root、不需要网络
#
# 用法（在本仓库根目录执行）：
#   sh tools/run-tests.sh              # 跑全部用例
#   sh tools/run-tests.sh ^layer       # 只跑 layer 套件（^ 表示前缀匹配）
#   busybox sh tools/run-tests.sh      # 本机（Windows）没有系统 sh 时这样跑
#
# shell 与 busybox：
#   - CI（ubuntu）用系统 sh 跑，断言文件保持 POSIX 兼容；
#   - 断言里的 mock 时间源需要一个**真实 busybox** 承接其余 applet（见 tests/mock/busybox），
#     它由 tools/lib.sh 的 find_busybox 定位：显式指定 > 仓库内 tools/busybox/ > 系统安装。
#     本脚本自己不挑 shell、也不重新执行自己——那会引入「谁在跑谁」的递归坑。
# ============================================================

set -e
cd "$(dirname "$0")/.."
ROOT="$PWD"
export T_ROOT="$ROOT"

. "$ROOT/tools/lib.sh"

echo "断言总入口 · 仓库根：$ROOT"
echo "shell：${BUSYBOX:+busybox }sh${BUSYBOX:+（$BUSYBOX）}"
echo "mock 用的真实 busybox：$(find_busybox || echo '（未找到——用到 mock 的断言会明确报错）')"
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
