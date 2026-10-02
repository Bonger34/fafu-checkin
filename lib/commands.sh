# ============================================================
# commands 层 —— 子命令的实现（start、分发与降权探测在入口）
#
# 加载顺序：第 9 层（最后一个）。本层的输出文案是使用者的手动排查入口，
# 与 README / 开发文档里列出的命令一一对应，改文案要同步文档。
# ============================================================

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
  if notify "fafu-test-$PL"; then
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
  if is_disabled; then echo "开关: ⏸ 已停用"; else echo "开关: 🟢 已启用"; fi
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
  ka_last=$(ka_state_get last)
  if [ -z "$ka_last" ]; then
    echo "保活: 暂无记录"
  else
    if [ "$(ka_state_get last_result)" = "ok" ]; then ka_mark="✅"; else ka_mark="❌"; fi
    if [ "$(ka_state_get date)" = "$("$BB" date +%Y-%m-%d)" ]; then
      echo "保活: 最近 $ka_last $ka_mark · 今日 $(ka_state_get ok) 成功 / $(ka_state_get fail) 失败"
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
  echo "enabled" > "$STATE"
  log "===== 服务已启用（操作按钮/命令） ====="
  sh "$SELF" start </dev/null >/dev/null 2>&1
  update_desc
  echo "🟢 服务已启用"
  echo "再次点击操作按钮可停用"
}

cmd_disable() {
  echo "disabled" > "$STATE"
  log "===== 服务已停用（操作按钮/命令） ====="
  cmd_stop </dev/null >/dev/null 2>&1
  update_desc
  echo "⏸ 服务已停用"
  echo "再次点击操作按钮可启用"
}

cmd_toggle() {
  if is_disabled; then
    cmd_enable
  else
    cmd_disable
  fi
}
