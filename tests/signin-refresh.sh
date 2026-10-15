# ============================================================
# signin 刷新与窗口边界：token 失效后刷新重试、窗口边界五个时点
#
# 边界逐分钟：判定的基准是「当前时刻（毫秒）」，断言把 EPOCH 拨到
# 21:29 / 21:30 / 22:30 / 22:59 / 23:00 各跑一次 signin_decide，每个时点只比一侧。
# 前导（夹具／替身／取值辅助）在 tests/_signin-common.sh，本文件只放用例。
# ============================================================
# ---- 共享前导（定义在 tests/_signin-common.sh；本文件自己 source）----
. "$T_ROOT/tests/_signin-common.sh"

# 提交失败后的短重试：真机连续四天在 21:30~21:33 被拒、而同分钟内手动提交就成功，
# 说明窗口刚开的那一小段服务端还没开始收——等满一分钟太亏，故失败后短等重来。
# 顺带证明「首次失败 → 刷新 token → 再试」这条老路径仍然保留（第 2 次调用就是它）。
sg_case_submit_retry() {
  local d f
  sg_setup retry
  sg_at 1290
  sg_body 1290 0 > "$SG_WORK/ctl/body.page"
  printf 'page:0\nsign:0\nsign:0\nsign:0\n' > "$SG_WORK/ctl/api.seq"
  printf '%s\n' "$SG_SIGN_FAIL" > "$SG_WORK/ctl/body.sign"
  # 成功体由用例写进文件，驱动只读文件——驱动是独立进程，测试变量不会自动进去
  # （写成 $SG_SIGN_OK 会展开成空串，于是「成功」被当成空响应体，重试根本不会被触发）
  printf '%s' "$SG_SIGN_OK" > "$SG_WORK/ctl/body.ok"
  sg_run retry <<'DRIVER'
# 自己接管网络：第 1 次提交（总第 2 次调用，前一次是查询）失败，下一次提交成功。
# 计次落在文件上——api() 在 $( ) 子 shell 里调用，变量加法跨不过去。
# 这一次调用的事实仍交给 api 层落笔，本驱动只决定「这次返回什么」。
printf '0' > ctl/b.n
: > ctl/refresh
http_post() {
  _n=$(cat ctl/b.n); _n=$((_n + 1)); printf '%s' "$_n" > ctl/b.n
  printf '%s | %s\n' "$1" "$2" >> ctl/api.calls
  case "$1" in
    # 尾星不能省：URL 里 sign 之后还有 "?lng=..."，`*student/sign)` 这种写法
    # 在这条 busybox ash 链路上匹配不上（判据是「整串匹配」，不是「子串包含」）
    *student/sign*)
      if [ "$_n" -le 2 ]; then
        _api_note 0 400 "$(cat ctl/body.sign)" "" "" "" ""
        printf '%s' "$(cat ctl/body.sign)"
      else
        _api_note 0 200 "$(cat ctl/body.ok)" "" "" "" ""
        printf '%s' "$(cat ctl/body.ok)"
      fi
      return 0 ;;
  esac
  _api_note 0 200 "$(cat ctl/body.page)" "" "" "" ""
  printf '%s' "$(cat ctl/body.page)"
  return 0
}
run_once; printf 'rc=%s\n' "$?"
printf 'kind=%s\n'      "$(sed -n 's/^sign_kind=//p' mod/fafu_checkin.status)"
printf 'attempts=%s\n'  "$(grep -c '提交尝试:' mod/fafu_checkin.log)"
printf 'signs=%s\n'     "$(grep -c 'student/sign' ctl/api.calls 2>/dev/null)"
printf 'refreshed=%s\n' "$(grep -c . ctl/refresh 2>/dev/null || echo 0)"
DRIVER
  d="$SG_WORK/retry.out"
  f=$(sg_plain_log)
  t_eq "重试：最终成功（返回 0）" "$(sg_val "$d" rc)" "0"
  t_eq "重试：记录类型为 normal" "$(sg_val "$d" kind)" "normal"
  # 断言「每次都各留一行」这件事，不钉精确尝试次数：次数受刷新路径与调用环境影响，
  # 钉死它只会让断言在别的环境下假红。
  t_eq "重试：每次尝试各留一行（行数 = 提交调用数）" \
    "$(sg_val "$d" attempts)" "$(sg_val "$d" signs)"
  t_has "重试：失败的那次留下状态码与完整正文" "$f" \
    "提交尝试: try=1 rid=88123 lng=119.243462 lat=26.088417 http=400 body=$SG_SIGN_FAIL"
  t_has "重试：成功的那次同样留一行（同一字段集）" "$f" \
    "提交尝试: try=2 rid=88123 lng=119.243462 lat=26.088417 http=200 body=$SG_SIGN_OK"
  t_has "重试：日志里留下了重试成功那一笔" "$f" "提交重试"
  t_has "重试：日志里也记了签到成功" "$f" "✅ 签到成功"
  t_before "重试：先有成功那次的事实，再有业务结论" "$f" "提交尝试: try=2" "✅ 签到成功"
}

# ============================================================
# 五、窗口边界：21:29 / 21:30 / 22:30 / 22:59 / 23:00(+1)
#
# 判定把「当前时刻（毫秒）」与接口给的 beginTime / supplementEndTime 比较，
# 故边界直接用**判定函数的返回码**观察：0 = 提交（窗口内），1 = 不在时段（窗口外）。
# 夹具是 21:30~22:30 + 补签截止 23:00，于是五个时点各只跨过一条边。
# 注意补签截止的判据是 `-gt`（严格大于）：整点那一刻仍在窗口内，23:01 才出窗口 ——
# 这正是「最后一次不晚于 22:59 发起」那条口径能成立的原因，别顺手改成 -ge。
# 这一节直接调 signin_decide（判定的边界是它自己的事），所以驱动里只有提交调用，
# 序列只需覆盖 sign 那一档。
# ============================================================

sg_case_boundaries() {
  local d
  sg_setup boundary
  sg_body 1290 0 > "$SG_WORK/ctl/body.page"
  printf 'sign:0\n' > "$SG_WORK/ctl/api.seq"
  printf '%s\n' "$SG_SIGN_OK" > "$SG_WORK/ctl/body.sign"
  sg_run boundaries <<'DRIVER'
: > ctl/bounds
# 判定的边界是它自己的事，故直接调 signin_parse / signin_decide（不经 run_once）：
# 这一节因此只有提交调用，序列只需覆盖 sign 那一档。
# 注意两个函数的形状：解析把字段写进调用方声明的 local，判定再按参数收下它们。
one() { # $1=当日第几分钟 → stdout=判定返回码
  local resp rid name state bt dline et rc
  sg_at "$1"
  resp=$(cat ctl/body.page)
  signin_parse "$resp" rid name state bt dline et >/dev/null || { printf 'parse-fail'; return 0; }
  signin_decide "$resp" TOK "$rid" "$name" "$state" "$bt" "$dline" "$et" >/dev/null 2>&1; rc=$?
  printf '%s' "$rc"
}
for m in 1289 1290 1350 1379 1380 1381; do
  printf '%s=%s\n' "$m" "$(one $m)" >> ctl/bounds
done
printf 'bounds=%s\n' "$(tr '\n' ',' < ctl/bounds)"
DRIVER
  d="$SG_WORK/boundaries.out"
  t_eq "六个时点都被判定到（没有中途退出）" \
    "$(grep -c '=' "$SG_WORK/ctl/bounds")" "6"
  t_has "21:29 → 窗口外（可重试）" "$d" "1289=1,"
  t_has "21:30 → 进入窗口（提交）" "$d" "1290=0,"
  t_has "22:30 → 主窗口最后一分钟仍在窗口内" "$d" "1350=0,"
  t_has "22:59 → 补签时段内仍提交" "$d" "1379=0,"
  t_has "23:00 整点仍在窗口内（判据是严格大于）" "$d" "1380=0,"
  t_has "23:01 → 已过补签截止，窗口外" "$d" "1381=1,"
}

# ============================================================
# 六、token 失效：查询异常 → 刷新后重试；重试仍失败 → 任务异常
# ============================================================

sg_case_token_refresh() {
  local d
  sg_setup refresh
  sg_at 1290
  sg_body 1290 0 > "$SG_WORK/ctl/body.page"
  # ① 第一次查询失败 → 刷新 → 第二次成功 → 照常走完判定与提交
  printf '%s\n' "$SG_SIGN_OK" > "$SG_WORK/ctl/body.sign"
  sg_run refetch <<'DRIVER'
SG_NEWTOKEN=NEWTOKEN
printf 'page:1\npage:0\nsign:0\n' > ctl/api.seq
refresh_token() { printf 'refresh\n' >> ctl/refresh; printf '%s' "$SG_NEWTOKEN"; }
run_once; printf 'rc=%s\n' "$?"
printf 'refresh=%s\n' "$(grep -c . ctl/refresh 2>/dev/null || echo 0)"
printf 'calls=%s\n'   "$(grep -c . ctl/api.calls 2>/dev/null || echo 0)"
DRIVER
  d="$SG_WORK/refetch.out"
  t_eq "查询异常后刷新 token 重试成功：返回 0" "$(sg_val "$d" rc)" "0"
  t_eq "查询异常确实触发了刷新" "$(sg_val "$d" refresh)" "1"
  t_eq "刷新后重试：三次网络调用（查询失败 + 查询成功 + 提交）" "$(sg_val "$d" calls)" "3"

  # ② 刷新后仍失败 → 任务异常（返回 2），并报「拿不到任务」
  sg_run refail <<'DRIVER'
SG_NEWTOKEN=NEWTOKEN
printf 'page:1\npage:1\n' > ctl/api.seq
refresh_token() { printf '%s' "$SG_NEWTOKEN"; }
run_once; printf 'rc=%s\n' "$?"
printf 'events=%s\n' "$(tr '\n' ',' < ctl/events 2>/dev/null)"
DRIVER
  d="$SG_WORK/refail.out"
  t_eq "刷新后仍拿不到任务：返回 2（任务异常）" "$(sg_val "$d" rc)" "2"
  t_eq "拿不到任务：通知事件是 failtask" "$(sg_val "$d" events)" "failtask,"
  t_has "拿不到任务：日志带 rc" "$SG_WORK/mod/fafu_checkin.log" "获取任务失败: rc=1"

  # ③ 刷新那几行要说明**触发原因**（用户故事 18）：走真实 refresh_token（SG_REFRESH_MODE=real
  #    让前导不再顶替它），只把采样等待与 token 来源换成替身——三段时序本身归 keepalive 套件。
  #    调用点在本层，故「签到查询失败」这几个字必须由本层的调用点传下去。
  sg_setup refresh-reason
  sg_at 1290
  sg_body 1290 0 > "$SG_WORK/ctl/body.page"
  printf 'page:1\npage:0\nsign:0\n' > "$SG_WORK/ctl/api.seq"
  printf 'mWakefulness=Awake\n' > "$SG_WORK/ctl/power.txt"
  SG_REFRESH_MODE=real
  export SG_REFRESH_MODE
  sg_run refetch_reason <<'DRIVER'
printf '0' > ctl/tok.n
sleep() { :; }        # 采样等待不真等（次数与时序不是这条断言要考的东西）
get_token() {         # 第一次是 run_once 取的旧 token，之后给新的（刷新因此会成功）
  n=$(cat ctl/tok.n); n=$((n + 1)); printf '%s' "$n" > ctl/tok.n
  if [ "$n" -le 1 ]; then printf 'OLD'; else printf 'NEWTOKEN'; fi
}
run_once; printf 'rc=%s\n' "$?"
DRIVER
  unset SG_REFRESH_MODE
  d="$SG_WORK/refetch_reason.out"
  t_eq "真实刷新链路：查询失败后刷新、再查、照常提交（返回 0）" "$(sg_val "$d" rc)" "0"
  t_has "刷新那一行说明触发原因是「签到查询失败」" "$SG_WORK/mod/fafu_checkin.log" \
    "刷新 token（静默优先） 触发原因=签到查询失败"
  t_has "刷新成功那一行同样带触发原因" "$SG_WORK/mod/fafu_checkin.log" \
    "刷新成功: OLD → NEWTOKEN 触发原因=签到查询失败"
}
