# ============================================================
# config 层验收断言：键登记、校验、写入落盘、生效值读数
#
# 三条口径：
#   1) 校验是纯函数：给一个值，断言接受 / 拒绝与可读原因（不碰文件、不碰网络）；
#   2) 读写往返在**模块副本**上做：副本里放一份真实的 fafu-checkin.conf，经 cfg_load
#      读回生效值——断言「文件里写了什么 → 生效值是什么」，不靠环境变量假装生效；
#   3) 写入只有一个闸门：非法值不落盘、旧值不变；合法值整份原子重写并回读回显。
#
# 加载：直接 source 真实层文件（harness 的 TEST_LIB_FILES，顺序取自入口的 FAFU_LAYERS）。
# ============================================================

CF_WORK="$T_WORK_ROOT/config"

# 模块目录与 busybox 替身：相对 $CF_WORK（cf_run 会先 cd 过去，见 tests/state.sh 的说明）。
# 模块目录用**真实的模块副本**：配置文件必须放在一个真能被入口跑起来的目录里。
CF_MODDIR="./mod"
CF_BB="./bin/bb"

cf_setup() {
  rm -rf "$CF_WORK"
  mkdir -p "$CF_WORK/mod"
  t_bb_wrap "$CF_WORK/bin/bb" >/dev/null
}

# 把模块拷成一份可独立运行的副本（入口 + 全部层 + 元数据），输出副本目录
cf_stage() { # $1=目标目录
  t_stage_module "$1"
}

# 驱动脚本的公共前导：注入替身 busybox 与模块目录，再按加载顺序加载真实层文件。
# 路径一律用**相对路径**：Windows 的 D:/ 在 sh 里不是合法路径（见 tests/state.sh）。
cf_write_env() {
  cat > "$CF_WORK/_env.sh" <<ENV
PATH='/bin:/usr/bin'
T_ROOT='$T_ROOT'
T_WORK='$CF_WORK'
MODDIR='$CF_MODDIR'
BB_OVERRIDE='$CF_BB'
export MODDIR BB_OVERRIDE
for _f in $TEST_LIB_FILES; do . "\$T_ROOT/\$_f"; done
ENV
}

# 跑一个驱动脚本；用法：cf_run <名字>，主体从 stdin 读入（公共前导自动接在前面）
cf_run() {
  local name rc
  name="$1"
  cat > "$CF_WORK/_body.sh"
  cp "$CF_WORK/_env.sh" "$CF_WORK/$name.sh"
  cat "$CF_WORK/_body.sh" >> "$CF_WORK/$name.sh"
  ( cd "$CF_WORK" && $(t_sh) "./$name.sh" ) > "$CF_WORK/$name.out" 2> "$CF_WORK/$name.err"
  rc=$?
  echo "$rc" > "$CF_WORK/$name.rc"
  if [ -s "$CF_WORK/$name.err" ]; then
    echo "  （驱动 $name 的 stderr）"
    sed 's/^/    /' "$CF_WORK/$name.err"
  fi
}

# 从驱动输出里取一行（形如 key=value）。
# 用 cut 而不是 sed：sed 的替换串里 `&` 会展开成整个匹配，键名恰好含 & 时会把整行吐回来。
cf_val() { # $1=文件 $2=键
  grep "^$2=" "$1" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '\r\n'
}

# ============================================================
# 一、校验规则：时间项、整数项、开关项（纯函数，返回码即结论）
# ============================================================

cf_case_rules() {
  local d
  cf_setup
  cf_write_env
  cf_run rules <<'DRIVER'
{
  # 时间项（严格 HH:MM 且落在 00:00–23:59）
  tt() { printf 'time_%s=%s\n' "$1" "$(cfg_time_ok "$2"; echo $?)"; }
  tt ok_zero    00:00
  tt ok_seven   07:00
  tt ok_lead0   09:05
  tt ok_end     23:59
  tt bad_2500   25:00
  tt bad_2400   24:00
  tt bad_95     9:5
  tt bad_letters ab:cd
  tt bad_hour7  7:00
  tt bad_min60  12:60
  tt bad_word   25
  tt bad_empty  ""
  tt bad_pad    " 20:00"
  # 整数项（闭区间，纯十进制）
  ti() { printf 'int_%s=%s\n' "$1" "$(cfg_int_ok "$2" "$3" "$4"; echo $?)"; }
  ti lead0     0 0 600
  ti lead5     5 0 600
  ti lead600   600 0 600
  ti lead601   601 0 600
  ti leadneg   -1 0 600
  ti leadalpha abc 0 600
  ti leadfloat 1.5 0 600
  ti leadempty "" 0 600
  ti cool0     0 0 86400
  ti cool86400 86400 0 86400
  ti coolover  86401 0 86400
  # 开关项（只接受 0 / 1）
  ts() { printf 'sw_%s=%s\n' "$1" "$(cfg_switch_ok "$2"; echo $?)"; }
  ts zero  0
  ts one   1
  ts two   2
  ts yes   1x
  ts empty ""
} > "$T_WORK/rules.txt"
DRIVER

  d="$CF_WORK/rules.txt"
  for k in ok_zero ok_seven ok_lead0 ok_end; do
    t_eq "时间项：$k 合法" "$(cf_val "$d" "time_$k")" "0"
  done
  for k in bad_2500 bad_2400 bad_95 bad_letters bad_hour7 bad_min60 bad_word bad_empty bad_pad; do
    t_eq "时间项：$k 拒绝" "$(cf_val "$d" "time_$k")" "1"
  done
  for k in lead0 lead5 lead600; do
    t_eq "整数项：$k 在区间内接受" "$(cf_val "$d" "int_$k")" "0"
  done
  for k in lead601 leadneg leadalpha leadfloat leadempty; do
    t_eq "整数项：$k 拒绝" "$(cf_val "$d" "int_$k")" "1"
  done
  t_eq "整数项：0 接受（提前量可关）" "$(cf_val "$d" int_cool0)" "0"
  t_eq "整数项：冷却上界 86400 接受" "$(cf_val "$d" int_cool86400)" "0"
  t_eq "整数项：冷却 86401 拒绝" "$(cf_val "$d" int_coolover)" "1"
  t_eq "开关项：0 接受" "$(cf_val "$d" sw_zero)" "0"
  t_eq "开关项：1 接受" "$(cf_val "$d" sw_one)" "0"
  t_eq "开关项：2 拒绝" "$(cf_val "$d" sw_two)" "1"
  t_eq "开关项：1x 拒绝" "$(cf_val "$d" sw_yes)" "1"
  t_eq "开关项：空值拒绝" "$(cf_val "$d" sw_empty)" "1"
}

# ============================================================
# 二、键登记与默认值：登记表是键名、默认值与写入顺序的唯一真源
# ============================================================

cf_case_registry() {
  local d
  cf_setup
  cf_write_env
  cf_run registry <<'DRIVER'
{
  printf 'keys=%s\n' "$(cfg_keys | tr '\n' ' ')"
  printf 'nkeys=%s\n' "$(cfg_keys | grep -c .)"
  printf 'unk=[%s]\n' "$(cfg_effective NOPE)"
  for k in $(cfg_keys); do printf 'eff_%s=%s\n' "$k" "$(cfg_effective "$k")"; done
  # 各键的读取函数：后面各层用它取值，读数必须与 cfg_effective 一致
  printf 'fn_keepalive=%s\n'       "$(cfg_keepalive)"
  printf 'fn_poll_start=%s\n'      "$(cfg_poll_start)"
  printf 'fn_poll_end=%s\n'        "$(cfg_poll_end)"
  printf 'fn_notify=%s\n'          "$(cfg_notify)"
  printf 'fn_notify_lead=%s\n'     "$(cfg_notify_lead)"
  printf 'fn_notify_cooldown=%s\n' "$(cfg_notify_cooldown)"
  printf 'fn_ka_start=%s\n'        "$(cfg_ka_start)"
  printf 'fn_ka_end=%s\n'          "$(cfg_ka_end)"
} > "$T_WORK/registry.txt"
DRIVER

  d="$CF_WORK/registry.txt"
  t_eq "登记的键与顺序（写入顺序即此）" "$(cf_val "$d" keys)" \
    "KEEPALIVE POLL_START POLL_END NOTIFY NOTIFY_LEAD NOTIFY_COOLDOWN KA_START KA_END "
  t_eq "登记表共八个键" "$(cf_val "$d" nkeys)" "8"
  t_eq "未登记的键：生效值为空" "$(cf_val "$d" unk)" "[]"
  t_eq "默认值：KEEPALIVE" "$(cf_val "$d" eff_KEEPALIVE)" "1"
  t_eq "默认值：轮询范围起" "$(cf_val "$d" eff_POLL_START)" "20:00"
  t_eq "默认值：轮询范围止" "$(cf_val "$d" eff_POLL_END)" "23:59"
  t_eq "默认值：NOTIFY" "$(cf_val "$d" eff_NOTIFY)" "1"
  t_eq "默认值：预警提前量" "$(cf_val "$d" eff_NOTIFY_LEAD)" "5"
  t_eq "默认值：通知冷却" "$(cf_val "$d" eff_NOTIFY_COOLDOWN)" "300"
  t_eq "默认值：保活时段起（原写死钟点搬家）" "$(cf_val "$d" eff_KA_START)" "07:00"
  t_eq "默认值：保活时段止（原写死钟点搬家）" "$(cf_val "$d" eff_KA_END)" "21:25"
  for k in KEEPALIVE POLL_START POLL_END NOTIFY NOTIFY_LEAD NOTIFY_COOLDOWN KA_START KA_END; do
    t_eq "读取函数 cfg_$(printf '%s' "$k" | tr 'A-Z' 'a-z') 与生效值一致" \
      "$(cf_val "$d" "fn_$(printf '%s' "$k" | tr 'A-Z' 'a-z')")" "$(cf_val "$d" "eff_$k")"
  done
}

# 文件字节数（断言「不打印噪音」用：字节为 0 才算真的静默）
cf_bytes() { # $1=文件
  wc -c < "$1" 2>/dev/null | tr -dc '0-9'
}

# ============================================================
# 三、配置文件真的被加载：模块副本里放一份真文件，读回生效值
# ============================================================

cf_case_load_file() {
  local d rc
  cf_setup
  d=$(cf_stage "$CF_WORK/mod")
  t_file "模块副本已就位（入口 + 全部层）" "$d/fafu_checkin.sh"
  t_file "模块副本含配置层" "$d/lib/config.sh"

  # 使用者手写的那份：带注释、顺序随意、值都是非默认值——读回的值必须逐字等于它
  cat > "$d/fafu-checkin.conf" <<'CONF'
# 手写配置：注释行与顺序都不该影响读数
KA_END=18:30
KEEPALIVE=0
POLL_START=06:30
NOTIFY_COOLDOWN=60
POLL_END=22:15
NOTIFY=0
KA_START=09:00
NOTIFY_LEAD=0
CONF
  cf_write_env
  cf_run load <<'DRIVER'
{
  cfg_load
  for k in $(cfg_keys); do printf 'eff_%s=%s\n' "$k" "$(cfg_effective "$k")"; done
} > "$T_WORK/load.txt"
DRIVER

  d="$CF_WORK/load.txt"
  t_eq "文件里写了什么就读回什么：KEEPALIVE" "$(cf_val "$d" eff_KEEPALIVE)" "0"
  t_eq "文件里写了什么就读回什么：轮询范围起" "$(cf_val "$d" eff_POLL_START)" "06:30"
  t_eq "文件里写了什么就读回什么：轮询范围止" "$(cf_val "$d" eff_POLL_END)" "22:15"
  t_eq "文件里写了什么就读回什么：NOTIFY" "$(cf_val "$d" eff_NOTIFY)" "0"
  t_eq "文件里写了什么就读回什么：预警提前量" "$(cf_val "$d" eff_NOTIFY_LEAD)" "0"
  t_eq "文件里写了什么就读回什么：通知冷却" "$(cf_val "$d" eff_NOTIFY_COOLDOWN)" "60"
  t_eq "文件里写了什么就读回什么：保活时段起" "$(cf_val "$d" eff_KA_START)" "09:00"
  t_eq "文件里写了什么就读回什么：保活时段止" "$(cf_val "$d" eff_KA_END)" "18:30"

  # 反向：把文件删掉，同一批键必须回到登记表里的默认值
  rm -f "$CF_WORK/mod/fafu-checkin.conf"
  cf_run load0 <<'DRIVER'
{
  cfg_load
  for k in $(cfg_keys); do printf 'eff_%s=%s\n' "$k" "$(cfg_effective "$k")"; done
} > "$T_WORK/defaults.txt"
DRIVER
  d="$CF_WORK/defaults.txt"
  t_eq "没有配置文件：KEEPALIVE 取默认" "$(cf_val "$d" eff_KEEPALIVE)" "1"
  t_eq "没有配置文件：轮询范围起取默认" "$(cf_val "$d" eff_POLL_START)" "20:00"
  t_eq "没有配置文件：轮询范围止取默认" "$(cf_val "$d" eff_POLL_END)" "23:59"
  t_eq "没有配置文件：NOTIFY 取默认" "$(cf_val "$d" eff_NOTIFY)" "1"
  t_eq "没有配置文件：预警提前量取默认" "$(cf_val "$d" eff_NOTIFY_LEAD)" "5"
  t_eq "没有配置文件：通知冷却取默认" "$(cf_val "$d" eff_NOTIFY_COOLDOWN)" "300"
  t_eq "没有配置文件：保活时段起取默认" "$(cf_val "$d" eff_KA_START)" "07:00"
  t_eq "没有配置文件：保活时段止取默认" "$(cf_val "$d" eff_KA_END)" "21:25"
}

# ============================================================
# 四、容错读：文件被手改坏时退回默认值，不崩、不静默改变行为
#
# 写入口会拒绝这些值，所以「手改坏的文件」是唯一能造出它们的途径。
# ============================================================

cf_case_load_broken() {
  local d rc
  cf_setup
  d=$(cf_stage "$CF_WORK/mod")
  cat > "$d/fafu-checkin.conf" <<'CONF'
# 坏文件：值非法、起止颠倒、还有表外的键
KEEPALIVE=7
POLL_START=25:00
POLL_END=22:15
NOTIFY_LEAD=abc
KA_START=23:00
KA_END=01:00
NOPE=1
CONF
  cf_write_env
  cf_run broken <<'DRIVER'
{
  cfg_load; printf 'rc=%s\n' "$?"
  for k in $(cfg_keys); do printf 'eff_%s=%s\n' "$k" "$(cfg_effective "$k")"; done
  printf 'nkeys=%s\n' "$(cfg_keys | grep -c .)"
} > "$T_WORK/broken.txt"
DRIVER

  d="$CF_WORK/broken.txt"
  t_eq "坏文件：加载照常返回 0（不崩）" "$(cf_val "$d" rc)" "0"
  t_eq "坏文件：非法开关退回默认" "$(cf_val "$d" eff_KEEPALIVE)" "1"
  t_eq "坏文件：非法时刻退回默认" "$(cf_val "$d" eff_POLL_START)" "20:00"
  t_eq "坏文件：非法整数退回默认" "$(cf_val "$d" eff_NOTIFY_LEAD)" "5"
  t_eq "坏文件：未受影响的键保留文件里的值" "$(cf_val "$d" eff_POLL_END)" "22:15"
  t_eq "坏文件：起止颠倒整对退回默认（起）" "$(cf_val "$d" eff_KA_START)" "07:00"
  t_eq "坏文件：起止颠倒整对退回默认（止）" "$(cf_val "$d" eff_KA_END)" "21:25"
  t_eq "坏文件：表外的键不进入读数（键数不变）" "$(cf_val "$d" nkeys)" "8"
  t_eq "坏文件：静默退回默认值（没有额外输出）" "$(cf_bytes "$CF_WORK/broken.err")" "0"
}

# ============================================================
# 五、写入闸门：合法值整份原子重写 + 回读回显
# ============================================================

cf_case_write_ok() {
  local d
  cf_setup
  d=$(cf_stage "$CF_WORK/mod")
  # 先摆一份「手写过的」文件：注释行与表外的键都不该活过这次重写
  printf '# 注释\nKEEPALIVE=0\nNOPE=1\n' > "$d/fafu-checkin.conf"
  cf_write_env
  cf_run write <<'DRIVER'
{
  if cfg_write KEEPALIVE=0 POLL_START=06:30 POLL_END=22:15 NOTIFY=0 \
               NOTIFY_LEAD=0 NOTIFY_COOLDOWN=60 KA_START=09:00 KA_END=18:30 \
               > "$T_WORK/echo.txt" 2> "$T_WORK/echo.err"; then rc=0; else rc=1; fi
  printf 'rc=%s\n' "$rc"
  printf 'file=%s\n' "$(cat "$MODDIR/fafu-checkin.conf" | tr '\n' '|')"
  printf 'lines=%s\n' "$(grep -c . "$MODDIR/fafu-checkin.conf")"
  printf 'nope=%s\n' "$(grep -c '^NOPE=' "$MODDIR/fafu-checkin.conf")"
  printf 'comment=%s\n' "$(grep -c '^#' "$MODDIR/fafu-checkin.conf")"
  # 回读生效值：不重新加载也必须是刚写进去的值
  printf 'eff_ka_end=%s\n' "$(cfg_effective KA_END)"
  printf 'eff_notify=%s\n' "$(cfg_effective NOTIFY)"
  # 重新加载一次（模拟进程重启）：生效值仍来自文件
  cfg_load
  printf 'reload=%s\n' "$(cfg_effective POLL_START)"
  printf 'tmpleft=%s\n' "$(ls "$MODDIR" | grep -c '\.tmp$')"
} > "$T_WORK/write.txt"
DRIVER

  d="$CF_WORK/write.txt"
  t_eq "写入合法值：返回 0" "$(cf_val "$d" rc)" "0"
  t_eq "写入合法值：整份重写、按登记顺序" "$(cf_val "$d" file)" \
    "KEEPALIVE=0|POLL_START=06:30|POLL_END=22:15|NOTIFY=0|NOTIFY_LEAD=0|NOTIFY_COOLDOWN=60|KA_START=09:00|KA_END=18:30|"
  t_eq "写入合法值：文件恰好八行" "$(cf_val "$d" lines)" "8"
  t_eq "写入合法值：不保留表外的键" "$(cf_val "$d" nope)" "0"
  t_eq "写入合法值：不保留手写注释" "$(cf_val "$d" comment)" "0"
  t_eq "写入合法值：回读生效值（末键）" "$(cf_val "$d" eff_ka_end)" "18:30"
  t_eq "写入合法值：回读生效值（开关）" "$(cf_val "$d" eff_notify)" "0"
  t_eq "写入合法值：重新加载后仍读回文件里的值" "$(cf_val "$d" reload)" "06:30"
  t_eq "写入合法值：不留临时文件" "$(cf_val "$d" tmpleft)" "0"
  # 回显给调用方（配置页据此确认值真的进去了）
  t_eq "写入合法值：回显八行键=值" "$(grep -c . "$CF_WORK/echo.txt")" "8"
  t_has "写入合法值：回显里带上刚写的值" "$CF_WORK/echo.txt" "KA_END=18:30"
  t_eq "写入合法值：没有报错输出" "$(cf_bytes "$CF_WORK/echo.err")" "0"
}

# ============================================================
# 六、写入闸门：非法值不落盘、旧值不变
# ============================================================

cf_case_write_reject() {
  local d before
  cf_setup
  d=$(cf_stage "$CF_WORK/mod")
  cat > "$d/fafu-checkin.conf" <<'CONF'
KEEPALIVE=0
POLL_START=06:30
POLL_END=22:15
NOTIFY=0
NOTIFY_LEAD=0
NOTIFY_COOLDOWN=60
KA_START=09:00
KA_END=18:30
CONF
  before=$(cat "$d/fafu-checkin.conf")
  cf_write_env
  cf_run reject <<'DRIVER'
{
  cfg_load
  # 每一类非法值：非 0 返回码 + 可读原因 + 生效值原地不动
  bad() { # $1=样本名，其余=「键=值」
    _n="$1"; shift
    if cfg_write "$@" > "$T_WORK/rej.out" 2> "$T_WORK/rej.err"; then _rc=0; else _rc=1; fi
    printf '%s_rc=%s\n'  "$_n" "$_rc"
    printf '%s_why=%s\n' "$_n" "$(cat "$T_WORK/rej.err" | tr '\n' ' ')"
  }
  bad badtime  POLL_START=25:00
  bad badswitch KEEPALIVE=2
  bad badint   NOTIFY_LEAD=601
  bad unknown  NOPE=1
  bad nosep    POLL_START
  bad noargs
  printf 'eff_poll=%s\n' "$(cfg_effective POLL_START)"
  printf 'eff_ka=%s\n'   "$(cfg_effective KEEPALIVE)"
  printf 'eff_lead=%s\n' "$(cfg_effective NOTIFY_LEAD)"
  printf 'tmpleft=%s\n'  "$(ls "$MODDIR" | grep -c '\.tmp$')"
  # 跨午夜的起止组合：单看每个值都合法，组合起来必须被拒
  bad midnight POLL_START=23:00 POLL_END=01:00
  bad equal    KA_START=21:25 KA_END=21:25
  bad past_end KA_START=22:00
  printf 'eff_ka_start=%s\n' "$(cfg_effective KA_START)"
  printf 'eff_poll_start=%s\n' "$(cfg_effective POLL_START)"
  printf 'eff_poll_end=%s\n'   "$(cfg_effective POLL_END)"
  # 一路拒绝下来，文件必须还是原样（这一步在下面那次合法写入之前取）
  cp "$MODDIR/fafu-checkin.conf" "$T_WORK/conf.after_rejects"
  # 合法的一组照旧能写进去（证明上面的拒绝不是「一律拒绝」）
  if cfg_write POLL_START=06:00 POLL_END=06:01 >/dev/null 2>&1; then _ok=0; else _ok=1; fi
  printf 'ok_rc=%s\n' "$_ok"
  printf 'ok_poll=%s\n' "$(cfg_effective POLL_START)"
} > "$T_WORK/reject.txt"
DRIVER

  d="$CF_WORK/reject.txt"
  for k in badtime badswitch badint unknown nosep noargs midnight equal past_end; do
    t_eq "非法写入：$k 返回非 0" "$(cf_val "$d" "${k}_rc")" "1"
  done
  t_ne "非法写入：时刻不合规给出可读原因" "$(cf_val "$d" badtime_why)" ""
  t_has "非法写入：原因里点明键名" "$d" "POLL_START"
  t_has "非法写入：原因里带上被拒的值" "$d" "25:00"
  t_ne "非法写入：未登记的键给出可读原因" "$(cf_val "$d" unknown_why)" ""
  t_eq "非法写入：被拒后生效值仍是旧值（时刻）" "$(cf_val "$d" eff_poll)" "06:30"
  t_eq "非法写入：被拒后生效值仍是旧值（开关）" "$(cf_val "$d" eff_ka)" "0"
  t_eq "非法写入：被拒后生效值仍是旧值（整数）" "$(cf_val "$d" eff_lead)" "0"
  t_eq "非法写入：不留临时文件" "$(cf_val "$d" tmpleft)" "0"
  t_eq "跨午夜组合：拒绝且起点不动" "$(cf_val "$d" eff_poll_start)" "06:30"
  t_eq "跨午夜组合：拒绝且终点不动" "$(cf_val "$d" eff_poll_end)" "22:15"
  t_eq "起止相等：拒绝（起必须早于止）" "$(cf_val "$d" eff_ka_start)" "09:00"
  t_eq "起点越过当前终点：拒绝" "$(cf_val "$d" eff_ka_start)" "09:00"
  t_eq "合法的一组：照旧写进去" "$(cf_val "$d" ok_rc)" "0"
  t_eq "合法的一组：生效值随之更新" "$(cf_val "$d" ok_poll)" "06:00"
  t_eq "被拒的写入没有落盘（文件逐字节不变）" "$(cat "$CF_WORK/conf.after_rejects")" "$before"
}

# ============================================================
# 七、配置改动真的改变行为：改的是文件，读的是各层的 cfg_ 函数
# ============================================================

cf_case_behavior() {
  local d
  cf_setup
  d=$(cf_stage "$CF_WORK/mod")
  cf_write_env
  cf_run behave <<'DRIVER'
{
  SU_MODE="stub"
  nt_send() { printf '%s\n' "$1" >> "$T_WORK/sent.log"; }
  cfg_write NOTIFY=0 NOTIFY_LEAD=60 NOTIFY_COOLDOWN=60 >/dev/null
  WAS_ON=1
  printf 'once_off=%s\n' "$( (notify_once miss; echo $?) )"
  printf 'warn_off=%s\n' "$( (notify_warn; echo $?) )"
  printf 'sent_off=%s\n' "$(grep -c . "$T_WORK/sent.log" 2>/dev/null || echo 0)"
  printf 'mark_off=%s\n' "$(notify_marked miss && echo marked || echo no)"

  cfg_write NOTIFY=1 NOTIFY_LEAD=60 NOTIFY_COOLDOWN=60 >/dev/null
  printf 'lead_on=%s\n'   "$(notify_lead)"
  printf 'warn_on=%s\n'   "$( (notify_warn; echo $?) )"
  printf 'sent_on=%s\n'   "$(grep -c . "$T_WORK/sent.log" 2>/dev/null || echo 0)"
  printf 'cool=%s\n'      "$(cfg_notify_cooldown)"
} > "$T_WORK/behave.txt"
DRIVER

  d="$CF_WORK/behave.txt"
  t_eq "NOTIFY=0：当日一次的通知零发送（返回 0）" "$(cf_val "$d" once_off)" "0"
  t_eq "NOTIFY=0：预警报「没发」（非 0，调用方不该等）" "$(cf_val "$d" warn_off)" "1"
  t_eq "NOTIFY=0：一条命令都没发出去" "$(cf_val "$d" sent_off)" "0"
  t_eq "NOTIFY=0：不落当日标记" "$(cf_val "$d" mark_off)" "no"
  t_eq "NOTIFY=1 且提前量 60：预警提前量跟着配置走" "$(cf_val "$d" lead_on)" "60"
  t_eq "NOTIFY=1：预警真的发出去（返回 0）" "$(cf_val "$d" warn_on)" "0"
  t_eq "NOTIFY=1：发出了一条命令" "$(cf_val "$d" sent_on)" "1"
  t_eq "通知冷却跟着配置走" "$(cf_val "$d" cool)" "60"

  # 默认值只留一处：两层不再各自用 ${VAR:-默认} 兜底，改经配置层读取
  t_hasnt "keepalive 层不再自己兜 KEEPALIVE 默认值" "$T_ROOT/lib/keepalive.sh" 'KEEPALIVE="${KEEPALIVE:-'
  t_hasnt "notify 层不再自己兜 NOTIFY 默认值" "$T_ROOT/lib/notify.sh" 'NOTIFY="${NOTIFY:-'
  t_hasnt "notify 层不再自己兜提前量默认值" "$T_ROOT/lib/notify.sh" 'NOTIFY_LEAD="${NOTIFY_LEAD:-'
  t_hasnt "notify 层不再自己兜冷却默认值" "$T_ROOT/lib/notify.sh" 'NOTIFY_COOLDOWN="${NOTIFY_COOLDOWN:-'
  t_has "notify 层经配置层取冷却值" "$T_ROOT/lib/notify.sh" 'cfg_notify_cooldown'
  t_has "keepalive 层经配置层取时段" "$T_ROOT/lib/keepalive.sh" 'cfg_ka_start'
}

# ============================================================
# 八、收口边界：配置文件只经 config 层，入口不再自己 source 它
# ============================================================

cf_case_ownership() {
  local owners f
  owners=""
  for f in "$T_ROOT"/*.sh "$T_ROOT"/lib/*.sh; do
    if grep -qF -e '$MODDIR/fafu-checkin.conf' "$f" 2>/dev/null; then owners="$owners ${f##*/}"; fi
  done
  t_eq "配置文件名只出现在配置层与卸载清单里" \
    "$(printf '%s\n' $owners | sort | tr '\n' ' ')" "config.sh uninstall.sh "
  t_has "配置层持有配置文件名" "$T_ROOT/lib/config.sh" 'CFG_FILE="$MODDIR/fafu-checkin.conf"'
  t_has "配置层经 base 的原子写落盘" "$T_ROOT/lib/config.sh" 'write_atomic "$CFG_FILE"'
  for f in base state api device notify desc keepalive signin commands; do
    t_hasnt "$f 层不直接碰配置文件" "$T_ROOT/lib/$f.sh" '$MODDIR/fafu-checkin.conf'
  done
  # 入口不再自己 source 配置文件：加载移交给配置层，且在层都加载完之后调一次
  t_hasnt "入口不再 . \"\$CONFIG\"" "$T_ROOT/fafu_checkin.sh" '. "$CONFIG"'
  t_has "入口经配置层加载" "$T_ROOT/fafu_checkin.sh" 'cfg_load'
  t_before "入口：配置加载排在层加载之后" "$T_ROOT/fafu_checkin.sh" \
    'for _layer in $FAFU_LAYERS' 'cfg_load'
  t_has "入口：层清单里配置层紧随 base 层" "$T_ROOT/fafu_checkin.sh" \
    'FAFU_LAYERS="base config state api device notify desc keepalive signin commands"'
}

# ============================================================
# 九、入口把配置文件交给配置层（真实副本 + 真实入口）
# ============================================================

cf_case_entry_handover() {
  local d rc
  cf_setup
  d=$(cf_stage "$CF_WORK/mod")
  printf 'NOTIFY=0\n' > "$d/fafu-checkin.conf"
  ( cd "$d" && BB_OVERRIDE="$CF_WORK/bin/bb" $(t_sh) "./fafu_checkin.sh" notify ) \
    > "$CF_WORK/entry.out" 2>&1
  rc=$?
  t_ne "入口：配置文件里的 NOTIFY=0 真的生效（子命令报已关闭）" "$rc" 0
  t_has "入口：命令层看到的是配置文件里的值" "$CF_WORK/entry.out" "通知已关闭"
}

# ---- 注册（顺序即执行顺序） ----

t_case "config · 校验规则（时间 / 整数 / 开关）" cf_case_rules
t_case "config · 键登记与默认值" cf_case_registry
t_case "config · 配置文件读写往返" cf_case_load_file
t_case "config · 坏文件容错读" cf_case_load_broken
t_case "config · 写入闸门（整份重写 + 回读回显）" cf_case_write_ok
t_case "config · 写入闸门（非法值不落盘、旧值不变）" cf_case_write_reject
t_case "config · 配置改动经各层生效" cf_case_behavior
t_case "config · 收口边界（配置文件只经本层）" cf_case_ownership
t_case "config · 入口把配置文件交给配置层" cf_case_entry_handover
