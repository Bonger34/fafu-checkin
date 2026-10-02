# ============================================================
# device 层 —— 设备控制：屏幕状态判定、前端任务枚举、打开 / 移除打卡页
#
# 加载顺序：第 4 层。四项能力（屏幕状态、任务枚举、开页、移除任务）都只在这里，
# 其余层不直接调 dumpsys / am（改设备行为不必跨层找）。
# 三条硬约束（改这里会坏什么）：
#   1) 屏幕判定失败一律按「亮屏」处理——误判成熄屏会走静默刷新，而亮着屏时开页不通知；
#   2) 绝不主动切换用户的前台——页面清理不彻底就让它留在后台（回桌面兜底会把正在用
#      手机的人直接甩到桌面，已实测否定）；
#   3) 系统命令固定 </dev/null >/dev/null 2>&1 且不接管道——KernelSU 的 SELinux 拒绝向
#      /data/adb 下文件传递 binder fd，输出接给 lib/ 下的 busybox 会报 Failed transaction。
# ============================================================

PKG="cn.edu.fafu.iportal"
PAGE="http://stuhealth.fafu.edu.cn/declarew/#/fafu/login"

# dumpsys 的输出只经**变量**承接（`$(_dumpsys …)`），不把命令本身接进管道：
# 命令自身的 fd 因此不会流进 /data/adb（见上第 3 条硬约束）。
# stdout 故意不做 >/dev/null——它的输出正是调用方要的内容，加固落在 `</dev/null` 上。
# 子命令按原样透传（`activity activities` 是两个参数，不能只取第一个——只写 activity
# 打印的是服务概览，没有 ActivityRecord 可解析）。
_dumpsys() { # $1…=dumpsys 的子命令 → 输出诊断文本（取不到时输出为空）
  dumpsys "$@" </dev/null 2>/dev/null
}

screen_is_on() {
  local out
  out=$(_dumpsys power)
  # 检测失败（无输出、或 ROM 把字段名又改了）时返回 0 = 按「屏幕亮着」处理：
  # 误判成熄屏会去走静默刷新（屏幕不亮），而亮着屏时开页却不发预警——两条都比多等一轮更糟。
  [ -n "$out" ] || return 0
  echo "$out" | "$BB" grep -qE 'mWakefulness=Awake|Display Power: state=ON|mScreenState=ON'
}

# 打卡页的活动记录：dumpsys 的一份输出里，同一条记录可能重复多行——去重后每行一条。
# 正则与原先逐字一致，只截到包名之后的第一个 "}"——ActivityRecord 的 Intent 部分内容
# 可变（缩短时会印成 "... 1 more"），不依赖它才不会被 ROM 的打印格式带崩。
# 取字段一律用 grep -oE（本机这版 busybox 的 ash 在「模式里带空格」时不参与匹配，实测）。
_activity_records() {
  _dumpsys activity activities \
    | "$BB" grep -oE 'ActivityRecord\{[^}]*'"$PKG"'[^}]*\}' | "$BB" sort -u
}

app_task_ids() {
  # 任务 id 是活动记录里紧跟在 "u0 " 后面的 t<数字>（用户名 u0 与任务号紧挨着，见开发文档 §3.3）；
  # 短横线换个方向取也一样：`[ }]` 之后的 `t<数字>` 是任务号。
  # 输出形态与重构前一致（升序去重 + 空格分隔 + 结尾一个空格）。
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
  # 移除打卡页所在任务，让页面退场；清理不彻底就让它留在后台，
  # 绝不主动切换用户的前台（曾在这里用回桌面兜底，会把正在用手机的人直接甩到桌面）。
  # 注意：循环变量名不要用 t（会与调用方 refresh_token 的 token 变量冲突）
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
