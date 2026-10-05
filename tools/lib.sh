#!/bin/sh
# ============================================================
# 工具脚本共用的小函数（POSIX sh；由 tools/*.sh 与 tests/harness.sh source）
#
# 只放「多处都要用、且必须只有一份」的东西：busybox 定位、层清单读取、外部资源判据。
# 用法：
#   find_busybox              输出可用的真实 busybox 路径（找不到则空串）
#   read_layers <仓库根>      输出入口声明的层文件清单（带 lib/ 前缀，按加载顺序）
#   pick_awk                  输出可用的 awk 命令（有随附 busybox 就用它）
#   ext_url_hits <文件>       输出文本里命中的外部资源形状（零命中则空串）
# 配置：TEST_BUSYBOX=<路径> 显式指定真实 busybox。
# ============================================================

# 仓库根：以本文件位置（<root>/tools/）为准
TOOLS_ROOT=$(cd "$(dirname "$0")/.." && pwd)

# 输出可用的 busybox 路径；找不到则输出空串。
# 来源按优先级：显式指定 → 仓库内随附 → 系统安装的（CI 的 busybox-static 就是这类）。
#
# 为什么必须校验「是文件」而不是直接信任命令名：断言里的 mock 时间源需要一个真实
# busybox 承接其余 applet（tests/mock/busybox 会 exec "$BB_REAL"）。busybox 的 ash 会把
# 内建 applet 也报成 PATH 上的命令（`command -v busybox` 只回一个名字，PATH 里并无此
# 文件），拿这个名字当路径用会自我递归；所以只接受确实存在的文件。
# `which` 在这类 shell 下反而会给出真实路径，故两条都试。
find_busybox() {
  local c p
  for c in "${TEST_BUSYBOX:-}" "$TOOLS_ROOT/tools/busybox/busybox" "$TOOLS_ROOT/tools/busybox/busybox.exe"; do
    [ -n "$c" ] || continue
    if [ -f "$c" ]; then
      printf '%s' "$c"
      return 0
    fi
  done
  for p in /bin/busybox /usr/bin/busybox /sbin/busybox /usr/sbin/busybox; do
    if [ -f "$p" ]; then
      printf '%s' "$p"
      return 0
    fi
  done
  for p in "$(which busybox 2>/dev/null || true)" "$(command -v busybox 2>/dev/null || true)"; do
    [ -n "$p" ] || continue
    if [ -f "$p" ]; then
      printf '%s' "$p"
      return 0
    fi
  done
  return 0
}

# 输出入口声明的层文件清单（带 lib/ 前缀，按加载顺序；读不出来则输出空串）。
# 唯一真源是入口脚本里的 FAFU_LAYERS：守卫（层序）、断言（被测源码）、
# 打包（清单与产物校验）三处都从这里读，不各自维护一份。
# $1=仓库根：调用方显式传入（tools/lib.sh 被从别处 source 时，$0 不是本仓库里的脚本，
# 上面的 TOOLS_ROOT 推断会指向别处——只用于随附 busybox 定位，不能用来找入口脚本）
read_layers() {
  local l out root
  root="${1:-$TOOLS_ROOT}"
  out=""
  # 容忍行首空白与行尾注释；清单读不出来时输出空串，由各调用方明确失败
  for l in $(sed -n 's/^[ 	]*FAFU_LAYERS="\([^"]*\)".*$/\1/p' "$root/fafu_checkin.sh" 2>/dev/null | head -n1); do
    out="${out}${out:+ }lib/$l.sh"
  done
  printf '%s' "$out"
}

# 输出文本里命中的外部资源形状（每行一条；零命中则输出空串）。
# 两类形状：带协议头的绝对形式（大小写不敏感），以及省略协议头的网络路径形式
# （以两个斜杠起头；要求主机名里含点，否则页面里正常的双斜杠写法会被误伤）。
# scheme 在正则里拆开写：本文件自己也在「零外部资源」的口径之内，
# 连续写出完整形状会让口径和它的实现互相打架。
# 恒以 0 退出：调用方（构建脚本）开着 set -e，零命中是正常答案而不是失败。
# $1=文件（不存在时按零命中处理——存在性由调用方单独断言）
ext_url_hits() {
  local re
  re='(ht|f)tp(s)?://|//[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z0-9]'
  [ -f "$1" ] || return 0
  LC_ALL=C grep -aoiE -e "$re" -- "$1" 2>/dev/null
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
