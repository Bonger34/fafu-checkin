# ============================================================
# 层序守卫自证
#
# 光「检查能通过」不能证明守卫有用——它可能是个永远为真的摆设。
# 本文件用一份**临时的反向引用样本**（更早的层调用更后的层）验证守卫确实会失败，
# 再用白名单样本、合法反向样本、坏清单样本钉住它的行为边界。
# ============================================================

LO_WORK="$T_WORK_ROOT/layer-order"

lo_fixture() {
  rm -rf "$LO_WORK"
  mkdir -p "$LO_WORK/tools"
  cp "$T_ROOT/tools/check-layer-order.sh" "$LO_WORK/tools/check-layer-order.sh"
  # 不放仓库自带白名单：守卫会退回内建名单（_ntc / SU_MODE / cmd），
  # 需要别的白名单时由用例自己写（"白名单文件缺失时的回退"这条路径也因此被覆盖）
  LO_RC=""
  LO_OUT=""
}

# 写一个层文件：lo_layer <文件名>（内容从 stdin 读，$ 不展开）
lo_layer() {
  cat > "$LO_WORK/$1"
}

# 以 $LO_WORK 为仓库根跑一次守卫，结果落 $LO_RC / $LO_OUT
# 白名单取临时仓库里的那份（不存在时守卫会退回内建名单，这条路径也被覆盖到）
lo_run() {
  LO_OUT=$(LAYER_ROOT="$LO_WORK" LAYER_FILES="${1:-a.sh b.sh c.sh}" \
    LAYER_WHITELIST="$LO_WORK/tools/layer-whitelist.txt" \
    sh "$LO_WORK/tools/check-layer-order.sh" 2>&1)
  LO_RC=$?
}

# 同上，但换一份白名单（用来证明白名单不是摆设）
lo_run_wl() {
  LO_OUT=$(LAYER_ROOT="$LO_WORK" LAYER_FILES="a.sh b.sh c.sh" LAYER_WHITELIST="$1" \
    sh "$LO_WORK/tools/check-layer-order.sh" 2>&1)
  LO_RC=$?
}

# 白名单文件不存在时的回退：守卫应退回内建名单，不能静默把白名单当成空
lo_case_whitelist_fallback() {
  lo_fixture
  lo_layer a.sh <<'A'
notify() {
  _ntc="cmd notification post"
  $SU_MODE "$_ntc"
}
A
  lo_layer b.sh <<'B'
b_task() {
  echo x
}
B
  lo_layer c.sh <<'C'
cmd_run() {
  notify
}
C
  lo_run_wl "$LO_WORK/tools/根本没这个文件.txt"
  t_eq "白名单缺失：退回内建名单，检查通过" "$LO_RC" 0
  lo_hasnt "白名单缺失：没有因为读不到白名单就误报" '违规'
}

# 断言：真实仓库的白名单确实被守卫引用（守卫通过 + 白名单里有那三项）
lo_case_repo_whitelist() {
  t_file "仓库带 tools/layer-whitelist.txt" "$T_ROOT/tools/layer-whitelist.txt"
  t_has "白名单含 _ntc" "$T_ROOT/tools/layer-whitelist.txt" '_ntc'
  t_has "白名单含 SU_MODE" "$T_ROOT/tools/layer-whitelist.txt" 'SU_MODE'
  t_has "白名单含 cmd" "$T_ROOT/tools/layer-whitelist.txt" 'cmd'
}

# 断言：检查输出里出现某字符串
lo_has() {
  if printf '%s' "$LO_OUT" | grep -qF -e "$2"; then
    _t_pass "$1"
  else
    _t_fail "$1（输出中没有 [$2]；实际输出：$LO_OUT）"
  fi
}

# 断言：检查输出里没有出现某字符串
lo_hasnt() {
  if printf '%s' "$LO_OUT" | grep -qF -e "$2"; then
    _t_fail "$1（输出里出现了 [$2]；实际输出：$LO_OUT）"
  else
    _t_pass "$1"
  fi
}

lo_case_valid_order() {
  lo_fixture
  lo_layer a.sh <<'A'
base_log() {
  echo "log"
}
A
  lo_layer b.sh <<'B'
state_save() {
  base_log
  echo "save"
}
B
  lo_layer c.sh <<'C'
cmd_run() {
  base_log
  state_save
  echo "run"
}
C
  lo_run
  t_eq "合法层序：检查通过（退出码 0）" "$LO_RC" 0
  lo_has "合法层序：报告函数数与层文件数" '层序检查通过：3 个函数、3 个层文件'
}

lo_case_reverse_reference_fails() {
  lo_fixture
  # 反向引用样本：a.sh（更早加载）的 base_log 调用了 b.sh（更后加载）的 state_save
  lo_layer a.sh <<'A'
base_log() {
  state_save
  echo "log"
}
A
  lo_layer b.sh <<'B'
state_save() {
  echo "save"
}
B
  lo_layer c.sh <<'C'
cmd_run() {
  base_log
  state_save
}
C
  lo_run
  t_ne "反向引用：检查必须失败（退出码非 0）" "$LO_RC" 0
  lo_has "反向引用：报出调用者与所在层" 'base_log@a.sh'
  lo_has "反向引用：报出被调用者与它所属的更后层" 'state_save（定义于更后的 b.sh）'
  lo_has "反向引用：说明失败原因" '层序检查失败'
}

lo_case_dynamic_dispatch() {
  lo_fixture
  # 动态分派：命令名写在变量里、或处理函数名来自命令表 —— 静态判不出，必须放过。
  # 关键在于被分派的目标确实是「更后层」的层函数（否则样本本身就不构成反向引用，
  # 测出来的绿是假的）。
  lo_layer a.sh <<'A'
dispatch() {
  handler=cmd_status
  "$handler" "$@"
}
A
  lo_layer b.sh <<'B'
cmd_status() {
  echo "status"
}
B
  lo_layer c.sh <<'C'
cmd_run() {
  dispatch
  echo "run"
}
C
  t_file "层函数样本：a 层调用更后层的 cmd_status" "$LO_WORK/b.sh"

  # 动态分派用变量名：把变量名放进白名单才应通过
  printf '%s\n' 'handler' > "$LO_WORK/tools/layer-whitelist.txt"
  lo_run
  t_eq "动态分派：白名单命中 handler，检查通过（退出码 0）" "$LO_RC" 0
  lo_hasnt "动态分派：没有把 handler 当成违规" '违规'

  # 反向验证：白名单是**真的在被读**，不是摆设——同一份样本换成空名单必须报出来
  printf '%s\n' '# 空白名单' > "$LO_WORK/tools/empty-whitelist.txt"
  lo_run_wl "$LO_WORK/tools/empty-whitelist.txt"
  t_ne "空白名单：动态分派必须被报出来（证明白名单真的在被读）" "$LO_RC" 0
  lo_has "空白名单：报出 dispatch 里的变量分派" 'dispatch@a.sh'
  lo_has "空白名单：报出被分派到更后层的函数" 'cmd_status'
}

# 仓库自带的白名单：文件必须在，且三项都在（内容本身是人工维护的契约）
lo_case_repo_whitelist_in_use() {
  t_file "仓库带 tools/layer-whitelist.txt" "$T_ROOT/tools/layer-whitelist.txt"
  t_has "白名单含 _ntc（通知命令字符串）" "$T_ROOT/tools/layer-whitelist.txt" '_ntc'
  t_has "白名单含 SU_MODE（降权写法）" "$T_ROOT/tools/layer-whitelist.txt" 'SU_MODE'
  t_has "白名单含 cmd（命令表分派）" "$T_ROOT/tools/layer-whitelist.txt" 'cmd'
}

lo_case_same_file_and_missing() {
  lo_fixture
  lo_layer a.sh <<'A'
base_log() {
  echo "log"
}
A
  lo_layer b.sh <<'B'
state_save() {
  base_log
  echo "save"
}
B

  # 缺文件：必须报错，不能静默按「只有一个文件」通过
  lo_run "a.sh nope.sh"
  t_ne "坏清单：文件不存在时失败" "$LO_RC" 0
  lo_has "坏清单：说明是哪个文件不存在" 'nope.sh'

  # 同一文件写两遍：属配置错误，必须报出来（否则顺序失真也无人察觉）
  lo_run "a.sh a.sh"
  t_ne "坏清单：同一文件重复出现时失败" "$LO_RC" 0
  lo_has "坏清单：说明哪个文件重复了" '重复出现：a.sh'

  # 空清单：不能当成「无事发生」
  lo_run " "
  t_ne "坏清单：清单为空时失败" "$LO_RC" 0
}

# 真实仓库：默认清单必须通过（现在只有入口脚本，拆分后变成入口 + 各层）
lo_case_repo_manifest() {
  LO_OUT=$(cd "$T_ROOT" && sh tools/check-layer-order.sh 2>&1)
  LO_RC=$?
  t_eq "真实仓库：层序检查通过（退出码 0）" "$LO_RC" 0
  lo_has "真实仓库：报告函数数与层文件数" '层序检查通过'
}

# ---- 注册（顺序即执行顺序） ----

t_case "layer · 合法层序通过" lo_case_valid_order
t_case "layer · 反向引用样本必须失败" lo_case_reverse_reference_fails
t_case "layer · 动态分派走白名单" lo_case_dynamic_dispatch
t_case "layer · 仓库白名单内容" lo_case_repo_whitelist_in_use
t_case "layer · 白名单缺失时退回内建" lo_case_whitelist_fallback
t_case "layer · 坏清单（缺文件 / 重复 / 空）" lo_case_same_file_and_missing
t_case "layer · 真实仓库清单" lo_case_repo_manifest
t_case "layer · 真实仓库白名单" lo_case_repo_whitelist
