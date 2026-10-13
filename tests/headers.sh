# ============================================================
# 注释口径守卫 —— 两条口径：
#   ① 全部脚本：文件头 ≤15 行（只留用法与配置）、不写文档指针、不留历史叙事；
#   ② 模块本体（入口 + 十个层 + 四个脚本 + 页面）：文件内任何注释块 ≤3 行、
#      不出现仓库侧的名字（模块外指针）。受管范围 = 本体清单 − 过渡豁免清单，
#      豁免清单已删空，故受管范围就是本体清单本身（十六个文件，无人为例外）。
#
# 用法：由 tools/run-tests.sh 加载，扫的是仓库里的文本，不看任何实现。
# 守卫自己不在被检查之列——它的判据里就必须写出那些字样与超限样本。
# 配置：HD_FILES / HD_BODY / HD_EXEMPT 覆盖被检查的对象（空格分隔；自证用例用）。
# ============================================================

HD_LIMIT=15
HD_BLOCK_LIMIT=3
HD_BODY_TOTAL=16
HD_WORK="$T_WORK_ROOT/headers"

# ---- 被检查的脚本（口径①） ----

# 要检查的脚本：仓库里所有 .sh，去掉守卫自己
hd_files() {
  if [ -n "${HD_FILES:-}" ]; then
    printf '%s\n' $HD_FILES
    return 0
  fi
  printf '%s\n' "$T_ROOT"/*.sh "$T_ROOT"/lib/*.sh "$T_ROOT"/tools/*.sh "$T_ROOT"/tests/*.sh |
    grep -v '/headers\.sh$'
}

# 清单里真实存在的文件数：每条扫描断言都要先确认它不为零——清单落空时的「零命中」是假绿
hd_count_of() { # $1…=文件
  local f n
  n=0
  for f in "$@"; do
    [ -f "$f" ] && n=$((n + 1))
  done
  printf '%s' "$n"
}

hd_count() { hd_count_of $(hd_files); }

# 首个注释块的行数：先跳过 shebang 与块前的空行，再从第一行注释数到第一个非注释行。
# 两个细节都是判据的一部分，不能省：块前的空行、行首空白都不该成为绕过判据的口子。
hd_lines() { # $1=文件
  local line rest lead n started
  n=0
  started=0
  while IFS= read -r line || [ -n "$line" ]; do
    # 去掉行首空白后再判（缩进的注释同样算注释）
    lead="${line%%[! 	]*}"
    rest="${line#"$lead"}"
    case "$rest" in
      '#!'*) [ "$started" -eq 0 ] && continue ;;   # 文件第一行的 shebang 不算头部注释
      '#'*) n=$((n + 1)); started=1; continue ;;
    esac
    [ "$started" -eq 0 ] && continue               # 块还没开始：空行继续往下找
    break
  done < "$1"
  printf '%s' "$n"
}

# 命中的字样（每行一个）：按**字节**做字面量匹配——本机 busybox 的 grep 在多字节
# 模式下匹配不上中文，LC_ALL=C 才能让这条判据在本机与 CI 上给出同一结果。
hd_scan() { # $1=文件，其余=字样
  local f p
  f="$1"
  shift
  for p in "$@"; do
    LC_ALL=C grep -aqF -e "$p" "$f" 2>/dev/null && printf '%s\n' "$p"
  done
}

# 指向文档的指针（零指针口径）与历史叙事（否决方案 / 实测史 / 「曾经……」）。
# 两类的共同点是：它们属于开发文档，进了代码就会和代码一起过期。
HD_DOC=".md README DEVELOPMENT CHANGELOG 开发文档 说明文档 §"
HD_HIST="踩过 曾经 原先 重构前 拆分前 已否决 草稿 实测"

# 仓库全量扫描：输出「文件:字样」
hd_repo_hits() { # $1…=字样
  local f hit
  for f in $(hd_files); do
    [ -f "$f" ] || continue
    hit=$(hd_scan "$f" "$@")
    [ -n "$hit" ] || continue
    printf '%s\n' "$hit" | while IFS= read -r p; do
      printf '%s:%s ' "${f##*/}" "$p"
    done
  done
}

# ---- 模块本体（口径②） ----

# 本体清单（打进 zip 的那一份，正好十六个文件）：入口 + 十层 + 四个安装/启动脚本 + 页面。
# 层清单从入口的 FAFU_LAYERS 读（tools/lib.sh 的 read_layers 是唯一真源），不另抄一份。
hd_body_files() {
  local l
  if [ -n "${HD_BODY:-}" ]; then
    printf '%s\n' $HD_BODY
    return 0
  fi
  printf '%s\n' "$T_ROOT/fafu_checkin.sh"
  for l in $(read_layers "$T_ROOT"); do
    printf '%s\n' "$T_ROOT/$l"
  done
  printf '%s\n' "$T_ROOT/service.sh" "$T_ROOT/action.sh" \
    "$T_ROOT/customize.sh" "$T_ROOT/uninstall.sh" "$T_ROOT/webroot/index.html"
}

# 过渡豁免清单：瘦身期间分批移出，现已删空——本体十六个文件全部受管，无人为例外。
# 语义是失败关闭：不在这行里的本体文件默认受管，所以空清单就是「判据对本体全量生效」。
HD_EXEMPT=""

# 在豁免清单里返回 0（$1=文件；绝对路径与仓库内相对路径都认）
hd_exempt() {
  local f e
  f="$1"
  for e in ${HD_EXEMPT:-}; do
    [ "$e" = "$f" ] && return 0
    [ "$e" = "${f#"$T_ROOT"/}" ] && return 0
  done
  return 1
}

# 受管的本体文件 = 本体清单 − 豁免清单
hd_managed_files() {
  local f
  for f in $(hd_body_files); do
    hd_exempt "$f" && continue
    printf '%s\n' "$f"
  done
}

hd_body_count() { hd_count_of $(hd_body_files); }
hd_managed_count() { hd_count_of $(hd_managed_files); }

# 仓库侧的名字（模块外指针）：模块被刷进手机之后，这些路径与文档在那台机器上都翻不到。
# 这组词只对本体的受管文件生效，不影响断言与工具脚本自己的旧判据（HD_DOC）。
HD_BODY_WORDS="tools/ tests/ scripts/ .github/ build.sh update.json CHANGELOG.md README DEVELOPMENT"

# ---- 块扫描 ----

# 超限即报：输出「文件:块首行:块长」（零超限则什么都不输出）
hd_block_report() { # $1=文件 $2=块首行 $3=块长 $4=上限
  [ "$3" -gt "$4" ] || return 0
  printf '%s:%s:%s\n' "${1##*/}" "$2" "$3"
}

# 分区标题（导航，非注释）：去掉行首空白后形如 `# ---- <非空> ----`，两端至少各两个连字符。
# 判定放在 shell 里做：每个注释行都要问一次，不起子进程。$1=去掉行首空白的整行
hd_divider() {
  local s left tail
  case "$1" in
    '# '*) s="${1#'# '}" ;;
    *) return 1 ;;
  esac
  left="${s%%[!-]*}"                      # 左端连字符串
  [ "${#left}" -ge 2 ] || return 1
  s="${s#"$left" }"                       # 去掉「连字符 + 空格」
  [ "$s" != "${s#* }" ] || return 1       # 后面还得有「文本 + 空格 + 连字符」
  tail="${s##* }"
  case "$tail" in
    --*) ;;
    *) return 1 ;;
  esac
  [ -n "${s% *}" ]                        # 文本段非空
}

# shell 文件的注释块：块 = 连续若干行「去掉行首空白后以 # 开头」，空行或非注释行即切断。
# 第一个块是文件头（只受 HD_LIMIT 管，不适用 HD_BLOCK_LIMIT）；分区标题从扫描里排除——
# 它既不自成一块，也不算进它后面那个块。行尾短注不以 # 起头，故天然不计入。
hd_sh_blocks() { # $1=文件 $2=块长上限
  local f limit line lead rest n start no first
  f="$1"
  limit="$2"
  n=0
  start=0
  no=0
  first=1
  while IFS= read -r line || [ -n "$line" ]; do
    no=$((no + 1))
    lead="${line%%[! 	]*}"
    rest="${line#"$lead"}"
    if hd_divider "$rest"; then
      continue
    fi
    case "$rest" in
      '#!'*)
        [ "$n" -eq 0 ] && [ "$first" -eq 1 ] && continue   # 文件开头的 shebang：与 hd_lines 一致
        ;;
      '#'*)
        n=$((n + 1))
        [ "$start" -gt 0 ] || start=$no
        continue
        ;;
    esac
    [ "$n" -gt 0 ] || continue
    [ "$first" -eq 1 ] || hd_block_report "$f" "$start" "$n" "$limit"
    n=0
    start=0
    first=0
  done < "$f"
  [ "$first" -eq 1 ] || hd_block_report "$f" "$start" "$n" "$limit"
  return 0
}

# 页面的注释块：`/* … */` 与行首的 `//`；空行切断、块内空行不计、一个块 ≤ 上限。
# 只认行首（含缩进）的注释，贴在代码行后的短注与 shell 侧一样不计入。
# 页面没有文件头判据，故第一块不豁免——否则等于给它留一个没人管的角。
hd_html_blocks() { # $1=文件 $2=块长上限
  local f limit line lead rest n start no in_block
  f="$1"
  limit="$2"
  n=0
  start=0
  no=0
  in_block=0
  while IFS= read -r line || [ -n "$line" ]; do
    no=$((no + 1))
    lead="${line%%[! 	]*}"
    rest="${line#"$lead"}"
    if [ "$in_block" -eq 1 ]; then
      [ -n "$rest" ] || continue                       # 块内空行不计
      n=$((n + 1))
      case "$rest" in
        *'*/'*) hd_block_report "$f" "$start" "$n" "$limit"; n=0; start=0; in_block=0 ;;
      esac
      continue
    fi
    case "$rest" in
      '/*'*)
        hd_block_report "$f" "$start" "$n" "$limit"     # 先收掉前面的 // 段
        n=0
        start=0
        case "$rest" in
          *'*/'*) ;;                                    # 单行块：1 行，必然在上限内
          *) n=1; start=$no; in_block=1 ;;
        esac
        continue
        ;;
      '//'*)
        n=$((n + 1))
        [ "$start" -gt 0 ] || start=$no
        continue
        ;;
    esac
    hd_block_report "$f" "$start" "$n" "$limit"
    n=0
    start=0
  done < "$f"
  hd_block_report "$f" "$start" "$n" "$limit"
  return 0
}

# 按注释语法分派：页面用 CSS/JS 的写法，其余（shell）用 # 行注释
hd_block_hits() { # $1=文件 $2=块长上限
  case "$1" in
    *.html) hd_html_blocks "$1" "$2" ;;
    *)      hd_sh_blocks "$1" "$2" ;;
  esac
}

# 受管文件里的超限块：输出「文件:块首行:块长」
hd_body_block_hits() {
  local f
  for f in $(hd_managed_files); do
    [ -f "$f" ] || continue
    hd_block_hits "$f" "$HD_BLOCK_LIMIT"
  done
}

# 受管文件里命中的仓库侧名字：输出「文件:字样」
hd_body_word_hits() {
  local f hit p
  for f in $(hd_managed_files); do
    [ -f "$f" ] || continue
    hit=$(hd_scan "$f" $HD_BODY_WORDS)
    [ -n "$hit" ] || continue
    printf '%s\n' "$hit" | while IFS= read -r p; do
      printf '%s:%s ' "${f##*/}" "$p"
    done
  done
}

# ---- 用例 ----

hd_case_header_limit() {
  local f n over scanned
  over=""
  scanned=0
  for f in $(hd_files); do
    [ -f "$f" ] || continue
    scanned=$((scanned + 1))
    n=$(hd_lines "$f")
    [ "$n" -le "$HD_LIMIT" ] || over="$over ${f##*/}:$n"
  done
  t_ne "扫描到的脚本数不为零（否则下面的断言会空转）" "$scanned" 0
  t_eq "文件头都在 $HD_LIMIT 行以内（只留用法与配置）" "${over:-无}" "无"
  # 反向：头部确实在说自己是什么，而不是被压成了空壳
  t_has "入口的文件头写着用法" "$T_ROOT/fafu_checkin.sh" '用法：sh fafu_checkin.sh'
  t_has "层的文件头写着加载顺序" "$T_ROOT/lib/api.sh" '加载顺序：第 4 层'
  t_has "配置层的文件头写着加载顺序" "$T_ROOT/lib/config.sh" '加载顺序：第 2 层'
  t_has "断言的文件头写着它测什么" "$T_ROOT/tests/api.sh" 'api 层验收断言'
}

hd_case_no_doc_pointer() {
  local hits
  t_ne "被扫描的脚本数不为零（否则下面的断言会空转）" "$(hd_count)" 0
  hits=$(hd_repo_hits $HD_DOC)
  t_eq "代码里不写指向文档的指针" "${hits:-无}" "无"
}

hd_case_no_history() {
  local hits
  t_ne "被扫描的脚本数不为零（否则下面的断言会空转）" "$(hd_count)" 0
  hits=$(hd_repo_hits $HD_HIST)
  t_eq "代码里不留历史叙事（否决方案 / 实测史 / 曾经）" "${hits:-无}" "无"
}

hd_case_body_block_limit() {
  local hits
  t_ne "扫描到的本体文件数不为零（否则下面的断言会空转）" "$(hd_body_count)" 0
  t_eq "本体清单正好十六个文件（入口 + 十层 + 四脚本 + 页面）" "$(hd_body_count)" "$HD_BODY_TOTAL"
  hits=$(hd_body_block_hits)
  t_eq "本体文件内任何注释块都不超过 $HD_BLOCK_LIMIT 行" "${hits:-无}" "无"
}

hd_case_body_word() {
  local hits
  t_ne "扫描到的本体文件数不为零（否则下面的断言会空转）" "$(hd_body_count)" 0
  hits=$(hd_body_word_hits)
  t_eq "本体文件里不出现仓库侧的名字（模块外指针）" "${hits:-无}" "无"
}

# 守卫自证：判据本身必须真的会失败，否则「全绿」只说明它是个摆设
hd_case_self_check() {
  local f over bad gap i
  mkdir -p "$HD_WORK"
  f="$HD_WORK/over.sh"
  over="$HD_WORK/ok.sh"
  bad="$HD_WORK/bad.sh"
  gap="$HD_WORK/gap.sh"
  {
    printf '#!/bin/sh\n'
    i=0
    while [ "$i" -lt $((HD_LIMIT + 1)) ]; do
      printf '# 头部第 %s 行\n' "$i"
      i=$((i + 1))
    done
    printf 'echo hi\n'
  } > "$f"
  printf '#!/bin/sh\n# 一行\n# 两行\necho hi\n' > "$over"
  printf '#!/bin/sh\n# 踩过的坑：写法见 README\n' > "$bad"
  # 空行 + 超长头：与前一种写法等价，不能被它绕过（块前的空行必须跳过）
  printf '#!/bin/sh\n\n\n' > "$gap"
  i=0
  while [ "$i" -lt $((HD_LIMIT + 1)) ]; do
    printf '# 头部第 %s 行\n' "$i" >> "$gap"
    i=$((i + 1))
  done
  printf 'echo hi\n' >> "$gap"
  t_file "自证：超限样本已落盘" "$f"
  t_file "自证：合规样本已落盘" "$over"
  t_file "自证：违规样本已落盘" "$bad"
  t_eq "自证：超限的头部会被数出超限行数" "$(hd_lines "$f")" "$((HD_LIMIT + 1))"
  t_eq "自证：合规的头部只数注释块" "$(hd_lines "$over")" "2"
  t_eq "自证：块前的空行绕不过判据" "$(hd_lines "$gap")" "$((HD_LIMIT + 1))"
  t_eq "自证：样本里没有文档指针（下面的命中不是空转）" "$(hd_scan "$f" $HD_DOC)" ""
  # 全量扫描那一段（hd_repo_hits）也要有反向样本，否则它可能整段空转
  t_ne "自证：全量扫描能命中违规样本" \
    "$(HD_FILES="$bad" hd_repo_hits $HD_HIST $HD_DOC)" ""
  t_eq "自证：全量扫描对干净样本零命中" \
    "$(HD_FILES="$over" hd_repo_hits $HD_HIST $HD_DOC)" ""
  t_eq "自证：被扫描数按清单算" "$(HD_FILES="$bad $over" hd_count)" "2"
  printf '# 见开发文档 §2.1\n' >> "$f"
  t_ne "自证：写入指针后立刻命中" "$(hd_scan "$f" $HD_DOC)" ""
}

# 块长 / 词表 / 豁免清单的自证：反向样本一律落在 $HD_WORK 下，不往仓库里写文件
hd_case_body_self_check() {
  local ok3 over4 gap4 tail div word
  mkdir -p "$HD_WORK"
  ok3="$HD_WORK/block3.sh"
  over4="$HD_WORK/block4.sh"
  gap4="$HD_WORK/gap4.sh"
  tail="$HD_WORK/tailnote.sh"
  div="$HD_WORK/divider.sh"
  word="$HD_WORK/repo-word.sh"
  # 合规：头部 1 行 + 空行 + 3 行块
  {
    printf '#!/bin/sh\n# 头部\n\n'
    printf '# 一\n# 二\n# 三\n'
    printf 'echo hi\n'
  } > "$ok3"
  # 超限：4 行块且带缩进（行首空白不得成为绕过判据的口子）
  {
    printf '#!/bin/sh\n# 头部\n\nif true; then\n'
    printf '  # 一\n  # 二\n  # 三\n  # 四\n'
    printf 'fi\n'
  } > "$over4"
  # 超限：4 行块前隔着两个空行（块前的空行不得成为口子）
  {
    printf '#!/bin/sh\n# 头部\n\n\n'
    printf '# 一\n# 二\n# 三\n# 四\n'
    printf 'echo hi\n'
  } > "$gap4"
  # 行尾短注：贴在代码行后的 # 不计入块长，也不设上限
  {
    printf '#!/bin/sh\n# 头部\n'
    printf 'x=1   # 说明一\ny=2   # 说明二\nz=3   # 说明三\nw=4   # 说明四\n'
    printf 'echo hi\n'
  } > "$tail"
  # 分区标题：既不自成一块，也不算进它后面那个块
  {
    printf '#!/bin/sh\n# 头部\necho hi\n'
    printf '# ---- 分区标题 ----\n'
    printf '# 一\n# 二\n# 三\n'
    printf 'echo hi\n# ---- 只有标题 ----\necho hi\n'
  } > "$div"
  {
    printf '#!/bin/sh\n# 头部\n'
    printf '# 用法：见 tools/run-tests.sh\n'
    printf 'echo hi\n'
  } > "$word"
  t_file "自证：合规的 3 行块样本已落盘" "$ok3"
  t_file "自证：超限的 4 行块样本已落盘" "$over4"
  t_eq "自证：3 行的块零命中（判据不是恒真）" \
    "$(HD_BODY="$ok3" HD_EXEMPT='' hd_body_block_hits)" ""
  t_eq "自证：4 行缩进块被报出块首行与块长" \
    "$(HD_BODY="$over4" HD_EXEMPT='' hd_body_block_hits)" "${over4##*/}:5:4"
  t_eq "自证：块前的空行绕不过块长判据" \
    "$(HD_BODY="$gap4" HD_EXEMPT='' hd_body_block_hits)" "${gap4##*/}:5:4"
  t_eq "自证：行尾短注不计入（连着四行也不算块）" \
    "$(HD_BODY="$tail" HD_EXEMPT='' hd_body_block_hits)" ""
  t_eq "自证：分区标题不自成一块，也不算进后面那个块" \
    "$(HD_BODY="$div" HD_EXEMPT='' hd_body_block_hits)" ""
  hd_divider '# ---- 分区标题 ----'
  t_true "自证：分区标题被认出（两端各至少两个连字符）" "$?"
  hd_divider '# 普通注释'
  t_ne "自证：普通注释不算分区标题" "$?" 0
  t_ne "自证：仓库侧的名字会被词表命中" \
    "$(HD_BODY="$word" HD_EXEMPT='' hd_body_word_hits)" ""
  t_eq "自证：词表对干净样本零命中" \
    "$(HD_BODY="$ok3" HD_EXEMPT='' hd_body_word_hits)" ""
  # 豁免清单得真的是个开关：同一份超限样本，受管时报出、进清单后不再生效
  t_ne "自证：超限样本在受管时被报出" \
    "$(HD_BODY="$over4" HD_EXEMPT='' hd_body_block_hits)" ""
  t_eq "自证：同一份样本进豁免清单后判据不再生效" \
    "$(HD_BODY="$over4" HD_EXEMPT="$over4" hd_body_block_hits)" ""
  t_eq "自证：受管数按「本体清单 − 豁免清单」算" \
    "$(HD_BODY="$ok3 $over4" HD_EXEMPT="$ok3" hd_managed_count)" "1"
}

# 豁免清单的自证：清单已删空，所以这里要钉住两件事——空的时候本体一个不漏地被扫，
# 非空的时候它真的还会豁免。少了任何一头，「全量生效」都可能只是清单空转的假象。
# 成员判定不用 case 通配（本机 busybox 对含换行的长串会失配），改为两条清单逐条精确比对。
hd_case_exempt_list() {
  local f m e hit body managed
  body=$(hd_body_files)
  managed=$(hd_managed_files)
  hit=0
  for f in $body; do
    for m in $managed; do
      [ "$m" = "$f" ] && hit=$((hit + 1))
    done
  done
  t_ne "自证：本体清单非空（否则下面「一个不漏」的说法没有内容）" "$(hd_body_count)" "0"
  t_eq "自证：名单里出现的本体文件数 = 本体文件数（空清单 = 一个不漏）" \
    "$hit" "$(hd_body_count)"
  t_eq "自证：受管数与本体数相同（清单为空即全量生效）" \
    "$(hd_managed_count)" "$(hd_body_count)"

  # 反向样本：证明清单本身还是个开关，而不是一个恒不生效的摆设
  e="$HD_WORK/exempt.sh"
  mkdir -p "$HD_WORK"
  {
    printf '#!/bin/sh\n# 头部\n\n'
    printf '# 一\n# 二\n# 三\n# 四\n'
    printf 'echo hi\n'
  } > "$e"
  t_ne "自证：样本在受管时报出超限块" \
    "$(HD_BODY="$e" HD_EXEMPT='' hd_body_block_hits)" ""
  t_eq "自证：样本进清单后判据不再生效、受管数减一" \
    "$(HD_BODY="$e" HD_EXEMPT="$e" hd_managed_count)" "0"
  t_eq "自证：未设 HD_EXEMPT 时同样全量受管（默认失败关闭）" \
    "$(unset HD_EXEMPT; HD_BODY="$e" hd_managed_count)" "1"
  t_eq "自证：清单只认精确路径，同前缀的另一个文件不受影响" \
    "$(HD_BODY="$e" HD_EXEMPT="${e%/*}/exempt-other.sh" hd_managed_count)" "1"
}

# 分区标题只免计数，不是块边界：两侧的注释仍算同一块（减压手段是空行）
hd_case_divider_scope() {
  local two
  mkdir -p "$HD_WORK"
  two="$HD_WORK/divider-between.sh"
  {
    printf '#!/bin/sh\n# 头部\necho hi\n'
    printf '# 一\n# 二\n'
    printf '# ---- 分区标题 ----\n'
    printf '# 三\n# 四\n'
    printf 'echo hi\n'
  } > "$two"
  t_eq "自证：分区标题两侧的注释仍算同一块（拆块靠空行）" \
    "$(HD_BODY="$two" HD_EXEMPT='' hd_body_block_hits)" "${two##*/}:4:4"
}

# 页面的自证：块注释与行注释两套语法都要有反向样本
hd_case_page_self_check() {
  local p2 p4 ps pt pb
  mkdir -p "$HD_WORK"
  p2="$HD_WORK/page-2line.html"
  p4="$HD_WORK/page-4line.html"
  ps="$HD_WORK/page-slash.html"
  pt="$HD_WORK/page-tail.html"
  pb="$HD_WORK/page-blank.html"
  printf '<style>\n/* 一\n   二 */\n</style>\n' > "$p2"
  printf '<style>\n/* 一\n   二\n   三\n   四 */\n</style>\n' > "$p4"
  printf '<script>\n// 一\n// 二\n// 三\n// 四\nvar a = 1;\n</script>\n' > "$ps"
  printf '<script>\nvar a = 1;   /* 一 */\nvar b = 2;   /* 二 */\nvar c = 3;   /* 三 */\nvar d = 4;   /* 四 */\n</script>\n' > "$pt"
  printf '<style>\n/* 一\n   二\n\n   三\n   四 */\n</style>\n' > "$pb"
  t_eq "自证：页面 2 行的 /* */ 块零命中" \
    "$(HD_BODY="$p2" HD_EXEMPT='' hd_body_block_hits)" ""
  t_eq "自证：页面 4 行的 /* */ 块被报出" \
    "$(HD_BODY="$p4" HD_EXEMPT='' hd_body_block_hits)" "${p4##*/}:2:4"
  t_eq "自证：页面 4 行的 // 行注释同样计数" \
    "$(HD_BODY="$ps" HD_EXEMPT='' hd_body_block_hits)" "${ps##*/}:2:4"
  t_eq "自证：页面行尾的 /* */ 短注不计入" \
    "$(HD_BODY="$pt" HD_EXEMPT='' hd_body_block_hits)" ""
  t_eq "自证：块注释里的空行不计入块长" \
    "$(HD_BODY="$pb" HD_EXEMPT='' hd_body_block_hits)" "${pb##*/}:2:4"
}

# ---- 注册（顺序即执行顺序） ----

t_case "headers · 文件头不超过 15 行" hd_case_header_limit
t_case "headers · 不写指向文档的指针" hd_case_no_doc_pointer
t_case "headers · 不留历史叙事" hd_case_no_history
t_case "headers · 判据自证" hd_case_self_check
t_case "headers · 本体注释块不超过 3 行" hd_case_body_block_limit
t_case "headers · 本体不写仓库侧指针" hd_case_body_word
t_case "headers · 本体判据自证" hd_case_body_self_check
t_case "headers · 豁免清单自证（空清单 = 全量生效）" hd_case_exempt_list
t_case "headers · 分区标题的范围自证" hd_case_divider_scope
t_case "headers · 页面注释自证" hd_case_page_self_check
