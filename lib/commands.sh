# ============================================================
# commands 层 —— 子命令表：分发、需要降权探测的命令集合、用法文本同源
#
# 加载顺序：第 10 层（最后一个）。本层的输出文案是使用者的手动排查入口。
# 对外提供：cmd_specs（命令表）/ cmd_known / cmd_dispatch / cmd_usage，
#   以及表里每个子命令的 cmd_<名字> 处理函数；入口只调前四个。
# 新增子命令 = 表里加一行 + 写一个 cmd_<名字>：用法文本与降权探测都从同一张表读出来，
# 没有第三处要同步。`start` 不在表里——它的处理函数是入口的 cmd_start。
# ============================================================

# 读出命令表（每行「名字 处理函数 是否需要降权探测 一行说明」）。
# 表与解析都只此一处：加子命令 = 在这里加一行，用法文本与探测集合跟着一起变。
# CD_SENTINEL 是分发时的「退出码哨兵」前缀：处理函数以 exit 收尾，返回码只能靠一行
# 哨兵从命令替换里带回来（见 cmd_dispatch）。它必须是不可能出现在命令输出里的串。
CD_SENTINEL="__fafu_rc__"

cmd_specs() {
  cat <<'SPECS'
stop      cmd_stop      0 停止守护进程（不改变开关状态）
status    cmd_status    0 查看开关 / 服务 / token 状态
notify    cmd_notify    1 发一条测试通知，确认通知链路是否真的能送到
once      cmd_once      1 立即检查一次并签到（幂等）
refresh   cmd_refresh   1 手动刷新 token（测试用）
keepalive cmd_keepalive 1 手动执行一次保活检查
toggle    cmd_toggle    0 切换服务开关（启用 ⇄ 停用）
enable    cmd_enable    0 启用服务
disable   cmd_disable   0 停用服务
SPECS
}

# 可用子命令的清单（按表里的顺序，空格分隔）——用法文本与 cmd_known 都用它，
# 不再另维护一份名单
dispatch_cmds() {
  cmd_specs | while read -r name handler probe desc; do
    [ -n "$name" ] && printf '%s ' "$name"
  done
}

# 用法文本（未知子命令时打印）：命令集合与顺序都取自命令表。
# 表里没有 `start`，故它只写在下面这行说明里（"start" 即不带子命令）。
# 返回非 0：调用方一律按「用法即失败」处理。
cmd_usage() {
  printf '用法: sh %s [%sstart]\n' "$SELF" "$(dispatch_cmds)"
  return 1
}

# 这个子命令在命令表里吗？给入口判定用：不在表里、也不是 start = 未知子命令（打印用法并非 0 退出）。
# 表里没有 start（守护进程的后台化与单实例判定在入口，见入口的 cmd_start），故这里显式认它一次。
cmd_known() {
  case "$1" in start|"") return 0 ;; esac
  case " $(dispatch_cmds) " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# 分发：先把该探测的命令探完，再执行处理函数 —— 两道循环分开写，
# 于是「降权探测发生在任何子命令分支之前」是结构上的必然，不靠注释或断言维持。
# 只认表里的子命令：名字不在表里 =「不带子命令」或 start，两者都由入口的 cmd_start 接手，
# 这里什么都不做、正常返回（未知子命令在入口就被拦下，不会走到这里）。
#
# $1 是子命令，**其余参数原样转交处理函数**（子命令名本身不算参数）：这两件事都靠位置参数，
# 故本函数里除了开头摘掉子命令名，不再动位置参数（探测那一趟改用具名变量逐列读表）。
#
# 命中处理函数即终局：它做完这件事就以它的返回码**退出整个进程**（起止都在它自己体内）。
# 输出与返回码必须分开走（混在一条流里会两头都坏：输出被吞掉、$? 里夹着文字），
# 分开的办法是**一层命令替换 + 一行哨兵**，全程只用 fd 1：
#
#   rc=$(cmd_handler_out "$handler")      # 里面是 { "$handler"; echo "$CD_SENTINEL$?"; }
#
# 哨兵行由本函数从末尾剥掉：它之前是处理函数的输出（原样送回 stdout），它之后是返回码。
# 处理函数以 exit 收尾也不能把哨兵带走——它跑在管道右侧那个子 shell 里（见 cmd_handler_out）。
# 不用 fd 3 承接输出：fd 3 是调用者的环境事实，root shell 常常关着它 exec 本脚本，
# 而重定向一个未打开的 fd 会让整条子命令当场失败——分发路径不依赖任何外部 fd。
cmd_dispatch() {
  local cmd name handler probe desc rc _cd_in cd_rc cd_out
  cmd="${1:-start}"
  [ $# -eq 0 ] || shift
  # 今日日期 tag（YYYYMMDD）：通知 tag 与「当日首次」判定都用它。
  # 守护主循环每轮会重算一次——进程常驻，跨日后 tag 不应仍停在启动那天。
  PL=$(today_tag)
  # 一、降权探测：入口在装配阶段已经探过一次，结果经 FAFU_SU_MODE 随环境传了进来
  # （守护进程就是靠它才带着写法常驻）。这里只处理没继承到的情形，省掉重复的 su 调用。
  if [ "$NOTIFY" = "1" ] && [ -z "${FAFU_SU_MODE:-}" ] && [ -z "$SU_MODE" ]; then
    _cd_in=$(cmd_specs)
    # 这一趟读的是 here-doc 而不是管道：管道右侧的 while 在子 shell 里跑，探测写下的
    # SU_MODE 会随子 shell 一起丢掉（表现为探测成功、通知却发不出去）。
    # read 逐行读、四列直接读进四个具名变量（行尾的说明文本落在第 4 列），
    # 不用 set -- 拆列：位置参数要原样留给处理函数。
    while read -r name handler probe desc; do
      if [ -n "$name" ] && [ "$name" = "$cmd" ] && [ "${probe:-0}" = "1" ]; then probe_su "$cmd"; fi
    done <<EOF
$_cd_in
EOF
  fi
  # 二、分发：哨兵行告诉调用方「处理函数真的跑过了、它的返回码是多少」
  rc=$(cmd_dispatch_rc "$cmd" "$@")
  case "$rc" in
    *"$CD_SENTINEL"*)
      # 哨兵之后是返回码；哨兵之前是处理函数的输出（原样送回 stdout，顺序不受影响）
      cd_rc="${rc##*"$CD_SENTINEL"}"
      cd_out="${rc%"$CD_SENTINEL"*}"
      [ -n "$cd_out" ] && printf '%s\n' "$cd_out"
      exit "$cd_rc"
      ;;
  esac
  return 0
}

# 命令表里那一行 → 调它的处理函数，子命令之后的参数原样跟在后面；输出「处理函数的输出 + 一行哨兵+退出码」。
# 没命中时不输出任何东西（调用方按「这个子命令不归命令表管」处理）。
# 处理函数跑在管道右侧的 while 里（那本身就是个子 shell），所以它的 exit 只终结这个子 shell、
# 把退出码交给 `{ }` 里紧跟着的哨兵 —— 若哪天改成不经管道直接调，exit 会连哨兵一起带走。
cmd_dispatch_rc() {
  local name handler probe desc want
  want="$1"
  [ $# -eq 0 ] || shift
  cmd_specs | while read -r name handler probe desc; do
    if [ -n "$name" ] && [ "$name" = "$want" ]; then
      { "$handler" "$@"; echo "$CD_SENTINEL$?"; }
      exit 0
    fi
  done
}

# 立即检查一次：处理函数一律命名 cmd_<子命令>，故 once 也在这里包一层（内容就是调用本身）
cmd_once() { run_once; }

cmd_refresh() {
  log "===== 手动刷新测试 ====="
  old=$(get_token)
  new=$(refresh_token "$old")
  if [ -n "$new" ] && [ "$new" != "$old" ]; then
    log "✅ 刷新成功: $new"
    resp=$(api "sign_in/student/my/page" "rows=1&pageNum=1" "$new"); rc=$?
    if [ $rc -eq 0 ] && echo "$resp" | "$BB" grep -q '"records"'; then
      log "✅ 新 token 接口验证通过"
    else
      log "⚠️ 新 token 接口验证异常(rc=$rc): $(echo "$resp" | "$BB" head -c 120)"
    fi
  else
    log "❌ 刷新失败（未获得新 token）"
  fi
}

cmd_keepalive() {
  log "===== 手动保活检查 ====="
  tok=$(get_token)
  if [ -z "$tok" ]; then
    log "无 token"
  else
    resp=$(api "sign_in/student/my/page" "rows=1&pageNum=1" "$tok"); rc=$?
    if [ $rc -eq 0 ] && echo "$resp" | "$BB" grep -q '"records"'; then
      log "token 有效: $tok"
    else
      log "调用未成功（token 失效或网络异常），token=$tok"
    fi
  fi
}

cmd_notify() { # 发一条测试通知，用来确认通知链路是否真的能送到
  if [ "$NOTIFY" != "1" ]; then
    echo "通知已关闭（配置 NOTIFY=0）"
    return 1
  fi
  if [ -z "$SU_MODE" ]; then
    echo "降权不可用：找不到可用的 su 写法，通知无法发送"
    echo "（先确认 $SU_BIN 存在；可试 su -c /system/bin/id -u 是否输出 2000）"
    return 1
  fi
  _NT_TITLE="🔔 通知测试"
  _NT_TEXT="如果你看到这条，说明通知链路正常（$("$BB" date '+%m-%d %H:%M')）"
  if notify "fafu-$(tag_of test)-$PL"; then
    echo "已发送（降权写法: $SU_MODE）"
    echo "没收到时依次查：系统设置里 Shell 的通知权限、勿扰模式、以及是否被 ROM 拦截"
    return 0
  fi
  echo "发送失败（降权写法: $SU_MODE）"
  return 1
}

cmd_status() {
  echo "====== 数字FAFU 晚查寝自动签到 ======"
  [ -n "$VER" ] && echo "版本: $VER"
  # 开关状态
  if svc_is_disabled; then echo "开关: ⏸ 已停用"; else echo "开关: 🟢 已启用"; fi
  # 服务状态
  if [ -f "$PIDF" ]; then
    pid=$("$BB" cat "$PIDF" 2>/dev/null)
    if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
      echo "服务: 运行中 (PID $pid)"
    else
      echo "服务: 未运行"
    fi
  else
    echo "服务: 未运行"
  fi
  # 保活状态（最近一次结果 + 今日统计）
  ka_last=$(ka_last_time)
  if [ -z "$ka_last" ]; then
    echo "保活: 暂无记录"
  else
    if [ "$(ka_last_result)" = "ok" ]; then ka_mark="✅"; else ka_mark="❌"; fi
    if ka_is_today; then
      echo "保活: 最近 $ka_last $ka_mark · 今日 $(ka_ok_count) 成功 / $(ka_fail_count) 失败"
    else
      echo "保活: 最近 $ka_last $ka_mark（今日暂无记录）"
    fi
  fi
  # 描述预览
  echo "描述: $(desc_text)"
  # token 状态
  tok=$(get_token)
  if [ -z "$tok" ]; then
    echo "token: 未找到（应用未安装或未登录过）"
  else
    resp=$(api "sign_in/student/my/page" "rows=1&pageNum=1" "$tok"); rc=$?
    if [ $rc -eq 0 ] && echo "$resp" | "$BB" grep -q '"records"'; then
      echo "token: 有效 $tok"
    else
      echo "token: 失效或网络异常 $tok"
    fi
  fi
  echo "最近日志:"
  "$BB" tail -n 6 "$LOG" 2>/dev/null
  # 顺带刷新一次动态描述（保证日期与状态最新）
  update_desc
}

cmd_stop() {
  if [ -f "$PIDF" ]; then
    pid=$("$BB" cat "$PIDF" 2>/dev/null)
    if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
      kill "$pid" 2>/dev/null
      sleep 1
      [ -d "/proc/$pid" ] && kill -9 "$pid" 2>/dev/null
      log "守护进程已停止 (PID $pid)"
      echo "已停止 (PID $pid)"
    else
      echo "服务未在运行（清理残留 PID 文件）"
    fi
    rm -f "$PIDF"
  else
    echo "服务未在运行"
  fi
}

cmd_enable() {
  svc_set enabled
  log "===== 服务已启用（操作按钮/命令） ====="
  sh "$SELF" start </dev/null >/dev/null 2>&1
  update_desc
  echo "🟢 服务已启用"
  echo "再次点击操作按钮可停用"
}

cmd_disable() {
  svc_set disabled
  log "===== 服务已停用（操作按钮/命令） ====="
  cmd_stop </dev/null >/dev/null 2>&1
  update_desc
  echo "⏸ 服务已停用"
  echo "再次点击操作按钮可启用"
}

cmd_toggle() {
  if svc_is_disabled; then
    cmd_enable
  else
    cmd_disable
  fi
}
