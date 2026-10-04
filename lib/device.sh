# ============================================================
# device 层 —— 设备控制：屏幕状态判定、前端任务枚举、打开 / 移除打卡页
#
# 加载顺序：第 4 层。这四项能力只在本层，其余层不直接调 dumpsys / am。
# 对外提供：screen_is_on / app_task_ids / act_count / open_page / close_page。
# ============================================================

PKG="cn.edu.fafu.iportal"
PAGE="http://stuhealth.fafu.edu.cn/declarew/#/fafu/login"

# 系统命令的 fd 加固：固定 `</dev/null >/dev/null 2>&1`，且不把命令本身接进管道——
# KernelSU 的 SELinux 拒绝向 /data/adb 下文件传递 binder fd（报 Failed transaction）。
# dumpsys 的输出因此只经**变量**承接（`$(_dumpsys …)`）；它的 stdout 不重定向，
# 那正是调用方要的内容。
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
# 正则只截到包名之后的第一个 "}"——ActivityRecord 的 Intent 部分内容可变（缩短时会印成
# "... 1 more"），不依赖它才不会被 ROM 的打印格式带崩。
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
  # 移除打卡页所在任务，让页面退场；清理不彻底就让它留在后台——
  # 绝不主动切换用户的前台。
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
