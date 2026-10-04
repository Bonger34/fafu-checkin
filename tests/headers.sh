# ============================================================
# 注释口径守卫：文件头只留用法与配置（≤15 行），代码里不留文档指针与历史叙事
#
# 用法：由 tools/run-tests.sh 加载，检查入口、lib/、tools/、tests/ 下的 .sh
# （与 CI 语法检查同一范围：`*.sh lib/*.sh tools/*.sh tests/*.sh`）。
# 判据是启发式的，只看两件事：首个注释块的行数、文本里有没有那几类字样。
# 守卫自己不在被检查之列——它的判据里就必须写出那几类字样。
# 配置：HD_FILES=<文件清单> 可覆盖被检查的对象（空格分隔，自证用例用它）。
# ============================================================

HD_LIMIT=15
HD_WORK="$T_WORK_ROOT/headers"

# 要检查的脚本：仓库里所有 .sh，去掉守卫自己
hd_files() {
  if [ -n "${HD_FILES:-}" ]; then
    printf '%s\n' $HD_FILES
    return 0
  fi
  printf '%s\n' "$T_ROOT"/*.sh "$T_ROOT"/lib/*.sh "$T_ROOT"/tools/*.sh "$T_ROOT"/tests/*.sh |
    grep -v '/headers\.sh$'
}

# 被扫描的脚本数：每条扫描断言都要先确认它不为零——清单落空时的「零命中」是假绿
hd_count() {
  local f n
  n=0
  for f in $(hd_files); do
    [ -f "$f" ] && n=$((n + 1))
  done
  printf '%s' "$n"
}

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

# ---- 注册（顺序即执行顺序） ----

t_case "headers · 文件头不超过 15 行" hd_case_header_limit
t_case "headers · 不写指向文档的指针" hd_case_no_doc_pointer
t_case "headers · 不留历史叙事" hd_case_no_history
t_case "headers · 判据自证" hd_case_self_check
