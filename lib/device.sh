# ============================================================
# device 层 —— 设备控制：屏幕状态判定、前端任务枚举、打开 / 移除打卡页
#
# 加载顺序：第 4 层。
# 两条实测确认过的硬约束（改这里会坏什么）：
#   1) 绝不主动切换用户的前台——页面清理不彻底就让它留在后台（回桌面兜底会把
#      正在用手机的人直接甩到桌面，已实测否定）；
#   2) 系统命令固定 </dev/null >/dev/null 2>&1——KernelSU 的 SELinux 会拒绝向
#      /data/adb 下文件传递 binder fd，不加固会报 Failed transaction。
# ============================================================

PKG="cn.edu.fafu.iportal"
PAGE="http://stuhealth.fafu.edu.cn/declarew/#/fafu/login"

screen_is_on() {
  _out=$(dumpsys power 2>/dev/null)
  [ -n "$_out" ] || return 0     # 检测失败时按“屏幕亮着”处理，避免误熄屏
  echo "$_out" | "$BB" grep -qE 'mWakefulness=Awake|Display Power: state=ON|mScreenState=ON'
}

act_count() {
  dumpsys activity activities 2>/dev/null \
    | "$BB" grep -oE 'ActivityRecord\{[^}]*cn\.edu\.fafu\.iportal[^}]*\}' \
    | "$BB" sort -u | "$BB" wc -l | "$BB" tr -dc '0-9'
}

app_task_ids() {
  dumpsys activity activities 2>/dev/null \
    | "$BB" grep -oE 'ActivityRecord\{[^}]*cn\.edu\.fafu\.iportal[^}]*\}' \
    | "$BB" grep -oE 't[0-9]+[ }]' | "$BB" tr -dc '0-9\n' \
    | "$BB" sort -u | "$BB" tr '\n' ' '
}

open_page() {
  am start --user 0 -n "$PKG/huawei.w3.ui.welcome.W3SplashScreenActivity" \
    -a com.huawei.works.action.shortcut -c android.shortcut.conversation \
    -d "$PAGE" --ei src 202 </dev/null >/dev/null 2>&1
}
# 说明：「把用户原来的 App 提回前台」这条路径已实测否定，故不再保留相关代码。

close_page() {
  # 移除打卡页所在任务，让页面退场；清理不彻底就让它留在后台，
  # 绝不主动切换用户的前台（曾经在这里用回桌面兜底，会把正在用手机的人直接甩到桌面）。
  # 注意：循环变量名不要用 t（会与调用方 refresh_token 的 token 变量冲突）
  ids=$(app_task_ids)
  for tid in $ids; do am stack remove "$tid" </dev/null >/dev/null 2>&1; done
  sleep 2
  C=$(act_count)
  if [ "$C" -gt 0 ]; then
    ids=$(app_task_ids)
    for tid in $ids; do am stack remove "$tid" </dev/null >/dev/null 2>&1; done
    sleep 2
    C=$(act_count)
  fi
  [ "$C" -gt 0 ] && log "页面移除未彻底(残留$C)，保留在后台（不再回桌面）"
  log "页面关闭检查: 残留活动=$C"
}
