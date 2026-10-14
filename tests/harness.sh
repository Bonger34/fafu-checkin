# ============================================================
# 测试底座：断言原语、用例注册与汇总、shell 与库文件定位
#
# 约定：
#   - 用例文件放在 tests/ 下、文件名不以 _ 开头，只定义函数并调用 t_case 注册；
#   - 用例内的断言只描述外部行为（返回码、文件产物、交给系统执行的命令字符串），
#     不断言行号，也不断言行内的实现写法；
#   - 断言函数内部一律用 local，避免上游循环变量被下游断言悄悄覆盖。
#
# 由 tools/run-tests.sh 加载（跑单个套件用 `sh tools/run-tests.sh ^api` 这样的前缀筛选）。
# ============================================================

# 调用方可能开着 set -e（tools/run-tests.sh 就有）。断言经常需要「看某个命令失败」
# （检查器应当非 0 退出、子进程应当报错），开着 set -e 会让用例在第一次非 0 处直接死掉、
# 后面所有断言静默消失。测试期间一律关掉。
set +e

T_PASS=0
T_FAIL=0
T_SKIP=0

# 仓库根目录：本文件位于 <root>/tests/
T_ROOT=$(cd "$(dirname "$0")/.." && pwd)

# busybox 定位与 tools/ 共用（避免本机与 CI 各用一套规则）
. "$T_ROOT/tools/lib.sh"

# ---- 被测源码清单（= 入口声明的加载顺序；清单真源是入口的 FAFU_LAYERS） ----
# 守卫（层序）、断言、打包三处都从入口读同一份清单，不各自维护（三份列表必然漂移）。
TEST_LIB_FILES=$(read_layers "$T_ROOT")
if [ -z "$TEST_LIB_FILES" ]; then
  echo "读不出层清单（入口 fafu_checkin.sh 里的 FAFU_LAYERS）——断言无法确定被测源码" >&2
  exit 1
fi

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

# 生成 curl 替身（探测 + 一次 POST 调用），供用例注入「这一次网络调用的全部事实」。
# $1=替身落点（要放进 PATH 上的目录，被测层用 CURL_BIN 指向它）
# $2=控制目录：下面这些控制文件都在这里，每次生成都重置为缺省值（200 / 空正文 /
#    空响应头 / 无报错 / 退出码 0），用例按需改写：
#      curl_code    HTTP 状态码（附在正文之后，与真实 curl 的 -w '\n%{http_code}' 一致）
#      curl_body    响应体
#      curl_hdr     响应头原文：被测代码用 `-D <文件>` 时写进那个落点
#      curl_stderr  网络工具打到 stderr 的报错原文（连接层失败的原始报错）
#      curl_rc      退出码（非 0 即「连接层失败」，此时不上报状态码）
#      curl_calls   每次调用的逐个参数追加一行（`|` 分隔，与替身 busybox 的 wget 记录同形）
#      curl_dpaths  每次带 -D 的落点路径追加一行（断言「响应头写到了哪」用）
t_curl_stub() {
  local out ctl
  out="$1"
  ctl="$2"
  mkdir -p "$(dirname "$out")" "$ctl"
  printf '200\n' > "$ctl/curl_code"
  : > "$ctl/curl_body"
  : > "$ctl/curl_hdr"
  : > "$ctl/curl_stderr"
  printf '0\n' > "$ctl/curl_rc"
  : > "$ctl/curl_calls"
  : > "$ctl/curl_dpaths"
  cat > "$out" <<STUB
#!/bin/sh
# 由 tests/harness.sh 的 t_curl_stub 生成：curl 替身（--version 探测 + 一次 POST 调用）
CTL='$ctl'
for _a in "\$@"; do
  [ "\$_a" = "--version" ] && { echo "curl 8.0.0"; exit 0; }
done
{ for _a in "\$@"; do printf '%s|' "\$_a"; done; printf '\n'; } >> "\$CTL/curl_calls" 2>/dev/null
# -D <文件>：把注入的响应头写进落点（分开写与连写两种形态都认），并记下落点路径
_d_path=''
_d_next=0
for _a in "\$@"; do
  if [ "\$_d_next" = "1" ]; then
    _d_path="\$_a"; _d_next=0
  else
    case "\$_a" in
      -D)  _d_next=1 ;;
      -D*) _d_path="\${_a#-D}" ;;
    esac
  fi
done
if [ -n "\$_d_path" ]; then
  cat "\$CTL/curl_hdr" > "\$_d_path" 2>/dev/null
  printf '%s\n' "\$_d_path" >> "\$CTL/curl_dpaths" 2>/dev/null
fi
cat "\$CTL/curl_stderr" >&2 2>/dev/null
cat "\$CTL/curl_body" 2>/dev/null
printf '\n%s\n' "\$(cat "\$CTL/curl_code" 2>/dev/null | tr -dc '0-9')"
_rc=\$(cat "\$CTL/curl_rc" 2>/dev/null | tr -dc '0-9')
exit "\${_rc:-0}"
STUB
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
# 用例名含空格，故按整行记录（用 $T_CASES 直接 for 会被拆词）
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
  T_SKIP=0
  # 用 here-doc 供 stdin（而不是管道）：断言计数在 while 里累加，
  # 管道会让 while 落进子 shell，计数丢失
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
  if [ "$T_SKIP" -gt 0 ]; then
    echo " 结果：$T_PASS 通过 / $T_FAIL 失败（共 $((T_PASS + T_FAIL)) 项）；跳过 $T_SKIP 项（本机缺工具）"
  else
    echo " 结果：$T_PASS 通过 / $T_FAIL 失败（共 $((T_PASS + T_FAIL)) 项）"
  fi
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

# 跳过：用例依赖本机没有的工具（如打包用例需要 zip）。跳过**不算通过**——
# 计数与通过项分开，避免「本机没跑」被读成「已验证」。
t_skip() {
  T_SKIP=$((T_SKIP + 1))
  echo "  [SKIP] $1"
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

# 数文件里命中模式的**非空行**，输出行数（调用方要的是「几处」，空行不算一处）。
# 字面量（默认）走内建 read + case：不起外部进程。本机（Windows）每个裸 applet 调用都在
# 几十毫秒一档，而这个函数被几百处断言调用，旧写法一次要起 3 个进程。
# 正则（第二参数 -E）仍用 grep：case 的模式是 glob，没有 `|`、`+`、分组这些 ERE 语义。
#
# 三条约束（少一条就会静默数错，或被 shell 直接终止）：
#   1) 最后一行没有换行时 read 会填值却返回 1，故循环必须带 `|| [ -n "$l" ]` 兜底；
#   2) 非交互 shell 里 exec 的重定向失败会**终止脚本**，故先判文件存在、且给 exec 兜底；
#   3) 「命中」与「非空行」是**两个条件**：正则那一支要按顺序走两次 grep，不能只数命中行
#      （能匹配空行的正则——空模式、`x*`、`^$`——否则会把空行也数进去）。
_t_grep_count() { # $1=模式 $2=-F|-E $3=文件
  local n=0 l
  if [ "${2:--F}" = "-E" ]; then
    grep -E -e "$1" -- "$3" 2>/dev/null | grep -c . 2>/dev/null
    return 0
  fi
  [ -f "$3" ] || { printf '%s' 0; return 0; }
  exec 3< "$3" || { printf '%s' 0; return 0; }
  while IFS= read -r l <&3 || [ -n "$l" ]; do
    case "$l" in *"$1"*) n=$((n + 1)) ;; esac
  done
  exec 3<&-
  printf '%s' "$n"
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

# 同上，但模式是**正则**：用在「空白量不该被写死」的地方（例如 case 分支的对齐空格）——
# 写死空格会让重构排版制造假红灯。
t_has_re() { # t_has_re <说明> <文件> <正则> [次数]
  local n
  n=$(_t_grep_count "$3" -E "$2")
  [ -n "$n" ] || n=0
  if [ "$n" -ge 1 ] && { [ -z "${4:-}" ] || [ "$n" = "$4" ]; }; then
    _t_pass "$1 ($n 处)"
  else
    _t_fail "$1（未找到正则 [$3]，实际 $n 处）"
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

# 相对顺序（正则版）：t_before_re <说明> <文件> <前模式> <后模式>
# 与 t_before 同理，但锚点写成「整行就是个调用」（^[ ]*name$）——函数名出现在文件头的
# 对外接口清单里时不算调用，只有真的在那行调用它才算。
t_before_re() {
  local a b
  a=$(grep -nE -m1 -e "$3" -- "$2" 2>/dev/null | cut -d: -f1)
  b=$(grep -nE -m1 -e "$4" -- "$2" 2>/dev/null | cut -d: -f1)
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then
    _t_pass "$1"
  else
    _t_fail "$1（前=[$3]@${a:-未找到} 后=[$4]@${b:-未找到}）"
  fi
}

# 「整行就是个调用」的正则锚点：缩进 + 函数名 + 行尾
t_call_re() {
  printf '^[ ]*%s$' "$1"
}

# ------------------------------------------------------------
# 库加载
# ------------------------------------------------------------

# 拼出被测库字符串放到 $1：按加载顺序拼接真实层文件（不是从源码里抽取片段再拼接）。
# 层的加载顺序取自入口的清单，故这里拼出来的环境与运行时一致。
t_write_lib() {
  local out f src
  out="$1"
  : > "$out"
  for f in $TEST_LIB_FILES; do
    src="$T_ROOT/$f"
    if [ ! -f "$src" ]; then
      echo "找不到被测源码：$src（层清单见入口 fafu_checkin.sh 的 FAFU_LAYERS）" >&2
      return 1
    fi
    cat "$src" >> "$out"
  done
  [ -s "$out" ]
}

# 拼出「全程序文本」放到 $1：各层 + 入口，顺序与运行时一致。
# 供静态断言查找函数定义、调用点与**相对顺序**用（只读文本，不执行）。
t_write_program() {
  local out
  out="$1"
  if ! t_write_lib "$out"; then
    return 1
  fi
  cat "$T_ROOT/fafu_checkin.sh" >> "$out"
  [ -s "$out" ]
}

# 把模块拷成一份**可独立运行**的副本（入口 + 全部层 + 元数据），输出副本目录。
# 入口按自身路径定位模块目录，故副本能自己跑起来，不会碰到仓库本身。
# 用例要「在真实模块上做一处临时改动」时用它（改副本，不动仓库文件）。
t_stage_module() { # $1=目标目录
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
