#!/bin/sh
# ============================================================
# 层序守卫 —— 检查「一层只能引用更早加载的层」这条依赖不变量
#
# 用法：
#   sh tools/check-layer-order.sh                       # 检查仓库默认清单（= 入口的加载清单）
#   LAYER_FILES="a.sh lib/b.sh" sh tools/check-layer-order.sh
#   LAYER_WHITELIST=path sh tools/check-layer-order.sh
#
# 它做什么：
#   1) 按清单顺序建立「函数 → 所属文件（层）」映射；
#   2) 扫描每个函数体，命中「更后层」定义的函数即报违规——包括
#      handler=cmd_status 之后 "$handler" 这种经变量间接调用的写法；
#   3) 命令名写在变量里、静态判不出目标的动态分派，走显式白名单
#      （tools/layer-whitelist.txt，缺失即失败，不静默当成空名单）。
#
# 它是启发式的：只守住肉眼看不出的那条不变量，不做 shell 解析。
# 函数体里的注释不参与判定（注释里提到更后层的名字不算引用）。
# 违规时以非 0 退出，并打印「调用者 @ 文件 → 被调用者（定义于更后的 X）」。
# ============================================================

set -e
# 仓库根默认取本脚本的上一级；LAYER_ROOT 可覆盖，供测试用临时样本充当仓库
ROOT="${LAYER_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
. "$ROOT/tools/lib.sh"

# ---- awk 程序以文件形式传给 awk（-f），不写成单个参数 ----
# 程序里有 "\034" 这类带反斜杠的字符串，Windows 版 busybox 解析单个参数时会吃掉引号，
# 报 "Unexpected end of string"；用 -f 传同一个程序就正常。
# 程序落盘在 tests/.work（已 gitignore）；注释里不要出现半角单引号或反引号。
write_prog() {
  cat <<'AWKEOF'
# 把「name()」「name ()」这类**定义**写法遮掉，避免定义本身被当成调用。
# 不用 %*s（busybox awk 不支持动态宽度），改成循环补空格。
function mask_defs(line,   pre, n, pad, i) {
  while (match(line, /[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)/)) {
    pre = substr(line, 1, RSTART - 1)
    n = RLENGTH
    pad = ""
    for (i = 0; i < n; i++) pad = pad " "
    line = pre pad substr(line, RSTART + RLENGTH)
  }
  return line
}

BEGIN {
  nf = split(files, fl, " ")
  nfn = 0
  nviol = 0

  for (fi = 1; fi <= nf; fi++) {
    while ((getline line < fl[fi]) > 0) {
      if (match(line, /^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)/)) {
        name = line
        sub(/^[ \t]*/, "", name)
        sub(/[ \t]*\(\).*/, "", name)
        if (!(name in owner)) {
          owner[name] = fi
          fname[name] = fl[fi]
          nfn++
        }
      }
    }
    close(fl[fi])
  }

  if (nfn == 0) {
    print "层序检查失败：一个函数都没解析出来（清单或源码格式异常）"
    exit 1
  }

  while ((getline w < wl) > 0) {
    sub(/[ \t]*#.*/, "", w)
    gsub(/^[ \t]+/, "", w)
    gsub(/[ \t]+$/, "", w)
    if (w != "") skip[w] = 1
  }
  close(wl)

  for (fi = 1; fi <= nf; fi++) {
    cur = ""
    buf = ""
    while ((getline line < fl[fi]) > 0) {
      # 注意：busybox awk 里 continue 会跳出整个 getline 循环（不是跳到下一行读取），
      # 所以这里一律用 if/else 串联，不能用 continue 做「跳过本行」。
      if (line ~ /^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)/) {
        if (cur != "") { body = buf; scan(cur) }
        nm = line
        sub(/^[ \t]*/, "", nm)
        sub(/[ \t]*\(\).*/, "", nm)
        cur = nm
        buf = ""
      } else if (cur != "") {
        # 续行拼成一行；行与行之间用 ; 接上，保证每行开头的命令也算一个命令位置
        if (line ~ /\\$/) {
          sub(/\\$/, " ", line)
          buf = buf line
        } else {
          buf = buf ";" line
          body = buf
          scan(cur)
          buf = ""
        }
      }
    }
    if (cur != "") { body = buf; scan(cur) }
    close(fl[fi])
  }

  if (nviol > 0) {
    for (i = 1; i <= nviol; i++) {
      split(viol[i], a, "\034")
      where = (a[2] == "") ? "(文件顶层)" : a[2]
      print "  违规: " a[1] "@" where " → " a[3] "（定义于更后的 " a[4] "）"
    }
    print ""
    print "层序检查失败：上面 " nviol " 处调用方向与加载顺序相反（一层只能引用更早加载的层）。"
    print "确实需要跨层回调时，把命令名放进白名单 " wl " 并写清理由。"
    exit 1
  }

  printf "层序检查通过：%d 个函数、%d 个层文件，未发现反向引用。\n", nfn, nf
  exit 0
}

# 扫描一个函数体：找出所有「最终会调到某个更后层函数」的位置，判断层序。
#
# 两步走：
#   1) 先收「变量 → 被赋的层函数名」（cmd=cmd_status，或 cmd="$CMD_STATUS" 取到的字面量）；
#   2) 再逐字符扫描命令位：命令位上的层函数（含经变量间接调用的）都算调用。
# 白名单里的名字整轮跳过——它说的是「这个变量是动态分派，静态判不出」，而不是「它安全」。
#
# busybox awk 兼容点（都踩过，每一条都会让守卫变成「永远通过」的摆设）：
#   1) body 是全局变量，**不能**出现在参数表里——awk 的形参一律是局部的，写进参数表就读到空串；
#   2) 不用 (a|b|c) 交替组做 match()，也不要在锚定符后放可选量词；这里改成逐字符扫描；
#   3) 循环里不能用 continue —— busybox 里它会跳出整个 getline 循环。
function scan(fn,   line, i, ch, start, w, nextc, j, k, v, target, prev) {
  line = mask_defs(body)
  gsub(/[;&|()]/, "@", line)      # 归一化命令分隔符
  gsub(/"/, "", line)             # 引号对取词无意义（$_ntc 与 "$_ntc" 等价）
  gsub(/#[^@]*/, "", line)        # 注释里提到更后层的函数名不算引用（@ 已是行分隔符）

  # ---- 第一步：变量 → 被赋的层函数名 ----
  for (k in varmap) delete varmap[k]
  i = 1
  while (i <= length(line)) {
    ch = substr(line, i, 1)
    if (ch ~ /[A-Za-z_]/) {
      start = i
      while (i <= length(line) && substr(line, i, 1) ~ /[A-Za-z0-9_]/) i++
      w = substr(line, start, i - start)
      if (substr(line, i, 1) == "=") {          # 形如 NAME=...
        j = i + 1
        while (j <= length(line) && substr(line, j, 1) ~ /[ \t$"{]/) j++
        k = j
        while (k <= length(line) && substr(line, k, 1) ~ /[A-Za-z0-9_]/) k++
        v = substr(line, j, k - j)
        if (v != "" && (v in owner)) varmap[w] = v
      }
    } else {
      i++
    }
  }

  # ---- 第二步：命令位取词 ----
  i = 1
  prev = ""
  while (i <= length(line)) {
    ch = substr(line, i, 1)
    if (ch == "@" || ch == " " || ch == "\t") { i++ }
    else if (ch == "$" || ch == "{" || ch == "}" || ch == "=") { i++ }
    else if (ch ~ /[A-Za-z_]/) {
      start = i
      while (i <= length(line) && substr(line, i, 1) ~ /[A-Za-z0-9_]/) i++
      w = substr(line, start, i - start)
      nextc = substr(line, i, 1)
      # 「目标」= 这个名字，或者它作为一个变量所指向的层函数
      target = (w in varmap) ? varmap[w] : w
      # 命中条件：目标是已定义的层函数、且属于更后加载的层；
      # 变量名与被指向的函数名都在白名单外；且这确实是命令位而不是赋值右侧
      if ((target in owner) && owner[target] > owner[fn] && !skip[w] && !skip[target] && prev != "=") {
        nviol++
        viol[nviol] = fn "\034" fname[fn] "\034" ((w in varmap) ? w "→" target : target) "\034" fname[target]
      }
      prev = nextc
    } else {
      prev = ch
      i++
    }
  }
}
AWKEOF
}

# ---- 层清单：从入口脚本的加载清单读出来（唯一真源，避免两份列表漂移） ----
# 默认按入口 FAFU_LAYERS 的顺序列出 lib/ 下各层；LAYER_FILES 可覆盖，供测试用临时样本。
FILES="${LAYER_FILES:-$(read_layers "$ROOT")}"
SEEN=""

# 清单为空 = 入口的加载清单读不出来（改名、格式变了、文件不在）：必须响亮地失败，
# 不能当成「没有层要检查」而静默通过——那样守卫会变成永远为真的摆设。
case "$FILES" in
  *[!\ ]*) : ;;
  *)
    echo "层序检查失败：读不出层清单（入口 fafu_checkin.sh 里的 FAFU_LAYERS；或用 LAYER_FILES 指定）" >&2
    exit 1
    ;;
esac

AWK=$(pick_awk)

# ---- 动态分派白名单：单一真源是仓库里的文件，缺失即失败（不静默当成空名单） ----
WL="${LAYER_WHITELIST:-tools/layer-whitelist.txt}"
if [ ! -f "$WL" ]; then
  echo "层序检查失败：找不到动态分派白名单：$WL" >&2
  echo "（白名单说明哪些变量承载动态分派，静态判不出；仓库里应有一份）" >&2
  exit 1
fi

# 清单里的文件先由 shell 确认存在、且不重复出现
# （同一文件写两遍会让「函数 → 层」映射失真，属配置错误，必须报出来）
for f in $FILES; do
  if [ ! -f "$f" ]; then
    echo "层序检查失败：清单里的文件不存在：$f" >&2
    exit 1
  fi
  case " $SEEN " in
    *" $f "*)
      echo "层序检查失败：清单里的文件重复出现：$f" >&2
      exit 1
      ;;
  esac
  SEEN="$SEEN $f"
done

echo "层序检查 · 清单：$FILES"

PROG="$ROOT/tests/.work/layer-order.awk"
mkdir -p "$ROOT/tests/.work"
write_prog > "$PROG"

$AWK -v files="$FILES" -v wl="$WL" -f "$PROG" /dev/null
