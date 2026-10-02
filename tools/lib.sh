#!/bin/sh
# ============================================================
# 工具脚本共用的小函数（POSIX sh；由 tools/*.sh 与 tests/harness.sh source）
#
# 只放「多处都要用、且必须只有一份」的东西：现在只有 busybox 定位。
# 之所以要收敛：本地（Windows）跑断言需要一个真实 busybox，CI 没有随附它，
# 三处各写一遍查询规则的结果就是「本机行、CI 不行」这种只在一边暴露的问题。
# ============================================================

# 仓库根：以本文件位置（<root>/tools/）为准
TOOLS_ROOT=$(cd "$(dirname "$0")/.." && pwd)

# 输出可用的 busybox 路径；找不到则输出空串。
# 只认「显式指定」与「仓库内随附」：不查 PATH——busybox 的 ash 会把内建 applet
# 也报成 PATH 上的命令（`command -v busybox` 返回 busybox），据此 exec 会无限自我递归。
find_busybox() {
  local c p
  for c in "${TEST_BUSYBOX:-}" "$TOOLS_ROOT/tools/busybox/busybox" "$TOOLS_ROOT/tools/busybox/busybox.exe"; do
    [ -n "$c" ] || continue
    if [ -f "$c" ]; then
      printf '%s' "$c"
      return 0
    fi
  done
  return 0
}

# 输出可用的 awk 命令；有随附 busybox 就用它，否则用系统 awk（CI）
pick_awk() {
  local bb
  bb=$(find_busybox)
  if [ -n "$bb" ]; then
    printf '%s awk' "$bb"
  else
    printf 'awk'
  fi
}
