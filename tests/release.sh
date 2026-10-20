#!/bin/sh
# ============================================================
# 发布前置条件守卫（scripts/check_release.py）
#
# 观察面只有两样：脚本的退出码、它说出的原因。夹具是临时目录里的最小仓库
# （module.prop / update.json / 更新日志 + 一个 tag），不碰真仓库、不需要网络。
#
# 四条守卫各有一条负向用例：换版本号忘改 tag、tag 建成轻量、versionCode 没递增、
# 更新日志少了小节——这四种都在发版时真实出现过或差点出现，必须红。
# ============================================================

RL_WORK="$T_WORK_ROOT/release"

# 找 Python：CI 是 python3，Windows 本机常只有 python。
# **必须真跑一次**：Windows 应用执行别名里的 python3.exe 能被 command -v 找到，
# 执行却以 0x2331 失败——只判存在会让整组用例假红成「脚本坏了」。
rl_py() {
  local c
  for c in python3 python; do
    command -v "$c" >/dev/null 2>&1 || continue
    "$c" -c 'import sys' >/dev/null 2>&1 && { printf '%s' "$c"; return 0; }
  done
  return 1
}

rl_ready() {
  rl_py >/dev/null 2>&1 && command -v git >/dev/null 2>&1
}

# 更新日志的文件名从被测脚本里取：真源只有一处，且 .sh 里不必写出文档名
rl_changelog_name() {
  "$(rl_py)" "$T_ROOT/scripts/check_release.py" --print-changelog-name
}

# 夹具：$1=目录 $2=tag（同时写进 module.prop）$3=module.prop versionCode
#       $4=update.json versionCode $5=update.json zipUrl
#       $6=tag 类型（annotated|lightweight|none）$7=更新日志是否有该小节（yes|no）
rl_fixture() {
  local cl
  cl=$(rl_changelog_name)
  [ -n "$cl" ] || return 1
  rm -rf "$1"
  mkdir -p "$1"
  printf 'id=fafu-checkin\nname=t\nversion=%s\nversionCode=%s\nauthor=t\nupdateJson=https://example.com/update.json\n' \
    "$2" "$3" > "$1/module.prop"
  printf '{\n  "version": "v0.0.1",\n  "versionCode": %s,\n  "zipUrl": "%s",\n  "changelog": "https://example.com/notes"\n}\n' \
    "$4" "$5" > "$1/update.json"
  if [ "$7" = "yes" ]; then
    printf '# 更新日志\n\n## %s\n\n- 示例\n' "$2" > "$1/$cl"
  else
    printf '# 更新日志\n\n## v0.0.1\n' > "$1/$cl"
  fi
  ( cd "$1" && git init -q && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init )
  case "$6" in
    annotated) ( cd "$1" && git -c user.name=t -c user.email=t@t tag -a "$2" -m t ) ;;
    lightweight) ( cd "$1" && git tag "$2" ) ;;
  esac
}

# 跑守卫，输出「退出码|合并后的输出」
rl_check() {
  local py out rc
  out=$("$(rl_py)" "$T_ROOT/scripts/check_release.py" "$2" --root "$1" 2>&1)
  rc=$?
  printf '%s|%s' "$rc" "$out"
}

rl_rc() { printf '%s' "${1%%|*}"; }
rl_out() { printf '%s' "${1#*|}"; }

# 非零退出且原因里说到关键词
rl_expect_fail() { # $1=夹具 $2=tag $3=关键词 $4=说明
  local r
  r=$(rl_check "$1" "$2")
  t_ne "$4：非零退出" "$(rl_rc "$r")" 0
  case "$(rl_out "$r")" in
    *"$3"*) _t_pass "$4：原因里说到「$3」" ;;
    *) _t_fail "$4：原因里没说到「$3」→ $(rl_out "$r")" ;;
  esac
}

rl_case_pass() {
  local d="$RL_WORK/pass" r
  rl_ready || { t_skip "release：本机缺 python 或 git"; return 0; }
  rl_fixture "$d" v1.0.0 2 1 "https://example.com/download/v0.9.0/f.zip" annotated yes
  r="$(rl_check "$d" v1.0.0)"
  t_eq "release · 条件齐全时退出码" "$(rl_rc "$r")" 0
  case "$(rl_out "$r")" in
    *全部满足*) _t_pass "release · 条件齐全时给出结论" ;;
    *) _t_fail "release · 条件齐全时没给出结论 → $(rl_out "$r")" ;;
  esac
}

rl_case_tag_mismatch() {
  local d="$RL_WORK/mismatch"
  rl_ready || { t_skip "release：本机缺 python 或 git"; return 0; }
  rl_fixture "$d" v1.0.0 2 1 "https://example.com/download/v0.9.0/f.zip" annotated yes
  rl_expect_fail "$d" v1.0.1 "不一致" "release · tag 与版本不一致"
}

rl_case_lightweight() {
  local d="$RL_WORK/light"
  rl_ready || { t_skip "release：本机缺 python 或 git"; return 0; }
  rl_fixture "$d" v1.0.0 2 1 "https://example.com/download/v0.9.0/f.zip" lightweight yes
  rl_expect_fail "$d" v1.0.0 "轻量" "release · 轻量 tag"
}

rl_case_code() {
  local d="$RL_WORK/code"
  rl_ready || { t_skip "release：本机缺 python 或 git"; return 0; }
  # versionCode 与已发布的相同，且 update.json 还指着旧 tag：这是「忘了加 1」
  rl_fixture "$d" v1.0.0 2 2 "https://example.com/download/v0.9.0/f.zip" annotated yes
  rl_expect_fail "$d" v1.0.0 "versionCode" "release · versionCode 未递增"
}

rl_case_changelog() {
  local d="$RL_WORK/changelog"
  rl_ready || { t_skip "release：本机缺 python 或 git"; return 0; }
  rl_fixture "$d" v1.0.0 2 1 "https://example.com/download/v0.9.0/f.zip" annotated no
  rl_expect_fail "$d" v1.0.0 "小节" "release · 缺更新日志小节"
}

rl_case_rerun() {
  local d="$RL_WORK/rerun" r
  rl_ready || { t_skip "release：本机缺 python 或 git"; return 0; }
  # update.json 已同步到本版（versionCode 相等、zipUrl 指向它）：补跑构建应放行
  rl_fixture "$d" v1.0.0 2 2 "https://example.com/download/v1.0.0/f.zip" annotated yes
  r="$(rl_check "$d" v1.0.0)"
  t_eq "release · 已同步后补跑放行" "$(rl_rc "$r")" 0
}

rl_case_missing_tag() {
  local d="$RL_WORK/missing"
  rl_ready || { t_skip "release：本机缺 python 或 git"; return 0; }
  rl_fixture "$d" v1.0.0 2 1 "https://example.com/download/v0.9.0/f.zip" none yes
  rl_expect_fail "$d" v1.0.0 "找不到" "release · tag 不存在"
}

t_case "release · 前置条件齐全时放行" rl_case_pass
t_case "release · tag 与版本不一致时拦下" rl_case_tag_mismatch
t_case "release · 轻量 tag 拦下" rl_case_lightweight
t_case "release · versionCode 未递增拦下" rl_case_code
t_case "release · 缺更新日志小节拦下" rl_case_changelog
t_case "release · 已同步后的补跑放行" rl_case_rerun
t_case "release · tag 不存在时拦下" rl_case_missing_tag
