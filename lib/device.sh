# ============================================================
# device 层 —— 设备控制：屏幕状态判定、前端任务枚举、打开 / 移除打卡页
#
# 加载顺序：第 5 层。dumpsys 与 am 只在本层出现，其余层不直接调设备命令。
# ============================================================

PKG="cn.edu.fafu.iportal"
PAGE="http://stuhealth.fafu.edu.cn/declarew/#/fafu/login"

# 系统命令一律带 `</dev/null` 加固（am 另加 `>/dev/null 2>&1`；_dumpsys 要 stdout，只丢 stderr）：
# KernelSU 的 SELinux 拒绝向 /data/adb 下文件传 binder fd，命令自身的 fd 因此永远不流进 /data/adb——
# 输出可以经变量承接，也可以就地接管道。子命令按原样透传（只写 activity 打印的是服务概览）。
_dumpsys() { # $1…=dumpsys 的子命令 → 输出诊断文本（取不到时输出为空）
  dumpsys "$@" </dev/null 2>/dev/null
}

screen_is_on() {
  local out
  out=$(_dumpsys power)
  # 检测失败时返回 0 = 按「屏幕亮着」处理：误判成熄屏的代价（不发预警、收尾还熄屏）比多等一轮更糟。
  [ -n "$out" ] || return 0
  echo "$out" | "$BB" grep -qE 'mWakefulness=Awake|Display Power: state=ON|mScreenState=ON'
}

# 打卡页活动记录：dumpsys 的一份输出里同一条记录可能重复多行，故去重后每行一条。
# 正则只截到包名后的第一个 "}"——Intent 内容可变（缩短时印成 "... 1 more"），不依赖它才不会被 ROM 打印格式带崩。
# 取字段一律用 grep -oE（本机这版 busybox 的 ash 在「模式里带空格」时不参与匹配）。
_activity_records() {
  _dumpsys activity activities \
    | "$BB" grep -oE 'ActivityRecord\{[^}]*'"$PKG"'[^}]*\}' | "$BB" sort -u
}

app_task_ids() {
  # 任务 id 在活动记录里出现两处、取到的是同一个号：紧跟在 "u0 " 之后的 t<数字>，
  # 以及记录末尾 "}" 之前的 t<数字>。输出形态：升序去重、空格分隔、结尾一个空格。
  _activity_records | "$BB" grep -oE 't[0-9]+[ }]' | "$BB" tr -dc '0-9\n' \
    | "$BB" sort -u | "$BB" tr '\n' ' '
}

act_count() {
  _activity_records | "$BB" wc -l | "$BB" tr -dc '0-9'
}

open_page() {
  # 只能作为新任务启动（start-activity 没有「不抢焦点」的标志），因此它会抢前台：
  # 调用方一拿到新 token 就要立刻 close_page，把中断压缩到登录所需的那几秒。
  am start --user 0 -n "$PKG/huawei.w3.ui.welcome.W3SplashScreenActivity" \
    -a com.huawei.works.action.shortcut -c android.shortcut.conversation \
    -d "$PAGE" --ei src 202 </dev/null >/dev/null 2>&1
}

close_page() {
  local ids cnt
  # 移除打卡页所在任务；清理不彻底就让它留在后台——绝不主动切换用户的前台。
  # 循环变量名不要用 t（会与调用方 refresh_token 的 token 变量冲突）
  ids=$(app_task_ids)
  for tid in $ids; do am stack remove "$tid" </dev/null >/dev/null 2>&1; done
  sleep 2
  cnt=$(act_count)
  if [ "$cnt" -gt 0 ]; then
    ids=$(app_task_ids)
    for tid in $ids; do am stack remove "$tid" </dev/null >/dev/null 2>&1; done
    sleep 2
    cnt=$(act_count)
  fi
  # am stack remove 会留下不可见的残留记录（visible=false、sz=1），清不掉也无实际影响：
  # 残留非 0 时只记一行日志，不再尝试任何「切前台」的动作。
  [ "$cnt" -gt 0 ] && log "页面移除未彻底(残留$cnt)，保留在后台（不再回桌面）"
  log "页面关闭检查: 残留活动=$cnt"
}
