#!/bin/sh
# ============================================================
# 工具脚本共用的小函数（POSIX sh；由 tools/*.sh 与 tests/harness.sh source）
#
# 只放「多处都要用、且必须只有一份」的东西：busybox 定位、层清单读取、外部资源判据、
# 以及「结果汇总行」的拼装与解析（写的一侧是 tests/harness.sh，读的一侧是 tools/run-tests.sh）。
# 用法：
#   find_busybox              输出可用的真实 busybox 路径（找不到则空串）
#   read_layers <仓库根>      输出入口声明的层文件清单（带 lib/ 前缀，按加载顺序）
#   pick_awk                  输出可用的 awk 命令（优先系统 awk，没有才用 busybox 的）
#   ext_url_hits <文件>       输出文本里命中的外部资源形状（零命中则空串）
#   summary_line [-l 标签] <通过> <失败> [跳过]   输出一条汇总行（标签默认「结果」）
#   summary_pick                        从 stdin 挑出第一条汇总行（零命中则空串）
#   summary_parse <汇总行>              输出「通过|失败|跳过|总数」四段（缺项为空）
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

# 输出可用的 awk 命令：**优先系统 awk**，本机（Windows）没有系统 awk 时才回落到 busybox 的 applet。
# 为什么不是反过来：busybox 的 awk 是精简实现，容错差——Magisk / KernelSU 随附的
# busybox 1.36.1.1（= 设备上那一份）在层序守卫的那段程序上直接段错误（exit 139）。
# awk 只出现在开发者这一侧的守卫里：模块运行时一个 applet 都不用，故这里没有
# 「与设备保持一致」的价值，稳定性优先。
pick_awk() {
  local bb
  if command -v awk >/dev/null 2>&1; then
    printf 'awk'
    return 0
  fi
  bb=$(find_busybox)
  if [ -n "$bb" ]; then
    printf '%s awk' "$bb"
  else
    printf 'awk'
  fi
}

# ------------------------------------------------------------
# 结果汇总行：写的一侧是 tests/harness.sh 的 _t_summary，读的一侧是 tools/run-tests.sh
# 的 run_batch。同一份格式放在两处必然漂移，而漂移的表现是「失败被静默记成 0」——
# 故拼装与解析都收在这里，两侧都不再自己写 sed。
# ------------------------------------------------------------

# 输出一条汇总行。跳过为 0（或不给）时不出「跳过」那一段。
# -l <标签>：默认「结果」（每个用例文件那一行）；总入口的「合计」行用它区分层级。
# 标签后面必须接「通过」与「失败」两个计数：缺了就是调用方写错，直接非 0 退出——
# 空操作数会让 $(( )) 报错并终止整个 shell（连 set -e 都不用），那比在这里拦住更难查。
# 注意：这里的「跳过」指的是用例自己报的 t_skip（本机缺工具），总入口把各文件的跳过
# 累加后再报一次，两者同形但不是一回事。
summary_line() { # [-l 标签] <通过> <失败> [跳过]
  local label
  label=结果
  if [ "${1:-}" = "-l" ]; then
    label="${2:-}"
    shift 2
  fi
  if [ $# -lt 2 ] || [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
    echo "summary_line：标签后面要给「通过」与「失败」两个计数" >&2
    return 2
  fi
  if [ "${3:-0}" -gt 0 ] 2>/dev/null; then
    printf '%s' " $label：$1 通过 / $2 失败（共 $(( $1 + $2 )) 项）；跳过 $3 项（本机缺工具）"
  else
    printf '%s' " $label：$1 通过 / $2 失败（共 $(( $1 + $2 )) 项）"
  fi
}

# 从一段输出里挑出**第一条**汇总行（零命中则空串）：总入口的每个用例文件各有一行，
# 它只认第一条，与「解析一行」分开——这个「认哪一行」的规则也属于格式契约的一部分。
# 两个模式各自的**前导空格是判据的一部分，不能省**：断言自己的说明文字里会出现
# 「结果：」这几个字（例如 `[PASS] 最近一次结果：仍取原值`），不锚前导空格就会把它
# 当成汇总行——那一行的字段不是数字，解析会失败，那个文件的 229 项就会被整个漏掉。
# **恒以 0 退出**：调用方（总入口）开着 set -e，零命中是正常答案（那个文件没跑完），
# 让 grep 的 1 冒出去会把「记一条 FAIL」变成「整个总入口直接死掉」。
summary_pick() { # $1=含汇总行的文本（stdin 亦可）
  grep -e ' 结果：' -e ' 合计：' 2>/dev/null | head -n1
  return 0
}

# 解析汇总行，输出「通过|失败|跳过|总数」四段（行首标签是「结果」还是「合计」都认）。
# 用 case + 参数展开而不是 sed：本机（Windows）每次裸 applet 调用都在几十毫秒一档，
# 而这条路径每个用例文件走一次；两者都是内建，解析一行不起任何外部进程。
# 认不出来的行**四段全空**，由调用方决定怎么兜底（run-tests 会再看输出里有没有
# [FAIL] 行）——不要在这里默认成 0，那会把「解析失败」记成「没有失败」。
summary_parse() { # $1=汇总行
  local rest p f s t
  case "$1" in
    *'结果：'*) rest="${1#*结果：}" ;;
    *'合计：'*) rest="${1#*合计：}" ;;
    *)          printf '|||' ; return 0 ;;
  esac
  case "$rest" in *' 通过 '*|' 通过 '*) ;; *) printf '|||' ; return 0 ;; esac
  p="${rest%% 通过*}"
  rest="${rest#* 通过 / }"
  f="${rest%% 失败*}"
  rest="${rest#* 失败（共 }"
  t="${rest%% 项*}"
  # 通过数与失败数必须是纯数字：不是数字的形状（会被调用方的 $(( )) 当算术表达式）
  # 一律按「没解析出来」处理，否则算错数、甚至把整个 shell 打掉
  case "$p" in ''|*[!0-9]*) printf '|||' ; return 0 ;; esac
  case "$f" in ''|*[!0-9]*) printf '|||' ; return 0 ;; esac
  case "$rest" in
    *'；跳过 '*) s="${rest#*；跳过 }" ;;
    *)           s="" ;;
  esac
  # 跳过后缀是「<数> 项（本机缺工具）」：只取**前导**数字那一段。
  # 必须用 %%（从左边截到第一个非数字）：## 会从左边剥到**最后**一个非数字，
  # 即把整个后缀吃掉、只剩空串，跳过数于是静默变成「没解析出来」。
  case "$s" in
    ''|*[!0-9]*) s="${s%%[!0-9]*}" ;;
  esac
  printf '%s|%s|%s|%s' "$p" "$f" "$s" "$t"
}
