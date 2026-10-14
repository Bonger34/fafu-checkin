# ============================================================
# base 层 —— 环境与工具：模块 / 工具链定位、日志与轮转、时间源、文件读写原语
#
# 加载顺序：第 1 层（最先）。本层不引用其它层的函数，其余各层都可以用本层。
# 注入点（生产环境不设置）：BB_OVERRIDE=busybox 替身。
# ============================================================

# ---- 模块目录与工具链定位 ----
# 模块目录由入口定位后传入；单独加载本层（断言驱动）时回退到调用方所在目录
SELF="${SELF:-$0}"
MODDIR="${MODDIR:-${SELF%/*}}"
MODID="fafu-checkin"
VER=$(grep -m1 '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)

# ---- busybox（KernelSU / Magisk / 系统） ----
BB=/data/adb/ksu/bin/busybox
[ -x "$BB" ] || BB=/data/adb/magisk/busybox
[ -x "$BB" ] || BB=busybox
BB="${BB_OVERRIDE:-$BB}"   # 允许测试注入替身（生产环境不设置）

# ---- ksud（KernelSU 用户空间工具；用于官方「动态描述」覆盖） ----
KSUD=/data/adb/ksu/bin/ksud
[ -x "$KSUD" ] || KSUD=/data/adb/ksud
[ -x "$KSUD" ] || KSUD=$(command -v ksud 2>/dev/null)
[ -x "$KSUD" ] || KSUD=""

# ---- 运行时文件（全部位于模块目录内，随模块卸载一并清除） ----
# 日志路径入口会先设一次：库层缺失时 base 还没加载，那条失败日志只能就地写
LOG="${LOG:-$MODDIR/fafu_checkin.log}"
PIDF="$MODDIR/.fafu_checkin.pid"

# ---- 时间源 ----
# 取「现在几点」只有这一个入口：测试把 $BB 指向 mock 即可拨钟。
_now()      { "$BB" date "$@"; }
now_s()     { _now +%s; }                          # unix 秒（节流与冷却基准）
now_hm()    { _now +%H:%M; }                       # 21:30（描述与签到记录）
now_full()  { _now '+%Y-%m-%d %H:%M:%S'; }         # 2026-10-03 21:30:14（日志与保活统计）
today()     { _now +%Y-%m-%d; }                    # 2026-10-03（当日判定）
today_tag() { _now +%Y%m%d; }                      # 20261003（通知 tag 与每日一次去重）

# 当前时刻的「当日第几分钟」（0~1439）：窗口判定全部用它，避免各处自己拆时分。
now_minutes() { hm_minutes "$(now_hm)"; }

# HH:MM → 当日第几分钟：配置里的钟点与「现在」的比较共用这一处换算。
# 先去前导 0 再算（`$((08))` 会被当成八进制而报错）。
hm_minutes() { # $1=HH:MM
  local h m
  h=${1%%:*}; m=${1#*:}
  h=${h#0}; m=${m#0}; [ -n "$h" ] || h=0; [ -n "$m" ] || m=0
  echo $((h * 60 + m))
}

# ---- 日志与轮转 ----
log() { echo "[$(_now '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

rotate_log() { # 日志超过 256KB 时保留最近 1000 行（防止长期运行无限增长）
  local sz
  [ -f "$LOG" ] || return 0
  sz=$("$BB" wc -c < "$LOG" 2>/dev/null | "$BB" tr -dc '0-9')
  [ -n "$sz" ] || return 0
  [ "$sz" -gt 262144 ] || return 0
  "$BB" tail -n 1000 "$LOG" 2>/dev/null | write_atomic "$LOG" || return 0
  log "日志已轮转（保留最近 1000 行）"
}

# ---- 文件读写原语 ----

# 原子写：内容从 stdin 读入，先写同目录临时文件再整体改名（不留半截文件）。
# 空内容不覆盖已有内容——一次失败的读取不该把日志 / 状态清空。
write_atomic() { # $1=目标文件
  local tmp
  tmp="$1.tmp"
  "$BB" cat > "$tmp" || return 1
  if [ ! -s "$tmp" ] && [ -s "$1" ]; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  "$BB" mv -f "$tmp" "$1" || { rm -f "$tmp" 2>/dev/null; return 1; }
}

# 键值读取：$1=文件 $2=键名 → 输出值（文件或键不存在时输出空）
kv_get() {
  [ -f "$1" ] || return 0
  "$BB" grep -m1 "^$2=" "$1" 2>/dev/null | "$BB" cut -d= -f2-
}

# 键值写入：$1=文件，其后是「键 值」对；按传入顺序整份原子替换
kv_set() { # $1=文件 $2=键 $3=值 [$4=键 $5=值 ...]
  local f
  f="$1"
  shift
  { while [ $# -ge 2 ]; do printf '%s=%s\n' "$1" "$2"; shift 2; done; } | write_atomic "$f"
}

# JSON 单字段提取：$1=JSON 文本 $2=字段名 → 该字段第一次出现的值（去两侧引号；只适用于扁平字段）。
# **故意不起子进程**：设备那份 busybox 的 `grep -oE` 会段错误，且后果极隐蔽——
# 字符串字段恒为空、数字字段全对。参数展开没有这个缺陷，还省掉每字段一次 fork。
json_first() {
  local rest v
  case "$1" in
    *"\"$2\":"*) : ;;
    *) return 0 ;;                      # 字段不存在 → 空
  esac
  rest=${1#*"\"$2\":"}                  # `#` 最短匹配 → 停在第一次出现处
  case "$rest" in
    \"*) v=${rest#\"}; v=${v%%\"*} ;;   # 带引号的值
    *)   v=${rest%%,*}; v=${v%%\}*} ;;  # 不带引号的值
  esac
  printf '%s' "$v"
}

# 取字段值：$1=JSON 文本 $2=字段名 $3=first|last → 该次出现处的值（去引号，两侧空格剥掉）。
# 值有带引号 / 不带引号两种形状，裁到引号、逗号、`}`、`]` 为止；json_first 与 _json_last
# 共用这一小段（两处各写一遍迟早分叉成两种读法），同样只做参数展开、不起子进程。
_json_val() {
  local rest v
  case "$3" in
    # 模式写法与 json_first 一致（引号在里、外面再包一层引号）：写成 ${1##*\"$2\":} 这种
    # 裸 \" 形状时，这份 busybox 的 ash 会报「unterminated quoted string」。照抄一处形状，
    # 两种取值方向就不会各自演化出不同的读法。
    last) rest=${1##*"\"$2\":"} ;;      # `##` 最长前缀匹配 → 停在**最后**一次出现处
    *)    rest=${1#*"\"$2\":"} ;;       # `#`  最短前缀匹配 → 停在第一次出现处
  esac
  case "$rest" in
    \"*) v=${rest#\"}; v=${v%%\"*} ;;
    *)   v=${rest%%,*}; v=${v%%\}*}; v=${v%%\]*} ;;
  esac
  # 逐字符剥掉两侧空格。值里不会真的含空格（字段值是数字或时间戳），故剥到底为止；
  # 写成循环是因为 POSIX case 没有「一个或多个字符」的写法。
  while :; do
    case "$v" in
      ' '*) v=${v#?} ;;
      *) break ;;
    esac
  done
  while :; do
    case "$v" in
      *' ') v=${v%?} ;;
      *) break ;;
    esac
  done
  printf '%s' "$v"
}

# 某字段**最后一次**出现的值（语义见下面的 _json_coord）。
_json_last() { # $1=JSON $2=字段名
  case "$1" in
    *"\"$2\":"*) _json_val "$1" "$2" last ;;
  esac
}

# 从响应里取一个**可用**的经纬度：$1=JSON 文本 $2=lng|lat。「可用」＝数值形状，
# 且取**最后一次**出现——顶层那份是字符串 `null`，先撞上它就会把 `lng=null&lat=null`
# 发出去被回 400。按形状取而不是切块取，接口结构怎么变都还取得到那个真值。
_json_coord() {
  local v
  v=$(_json_last "$1" "$2")
  case "$v" in
    ''|null|NULL|None) v=$(json_first "$1" "$2") ;;   # 最后一份不可用 → 再看第一份
  esac
  case "$v" in
    null|NULL|None|'') printf '' ;;
    *[!0-9.+-]*) printf '' ;;           # 非数值形状 → 当作没取到，走回退
    *) printf '%s' "$v" ;;
  esac
}

# 本机时区偏移（形如 +0800）。**绝不输出空**：空值会让日志里的 TZ=[…] 段退化成
# [未设/]，读的人分不清「没取到偏移」与「偏移为零」——取不到时给哨兵 `--`。
# 退化路径算出的差值同样不当偏移交出（它分不清「恰好为 0」与「真在 UTC」）。
tz_offset() {
  local z n u
  z=$("$BB" date +%z 2>/dev/null)
  # 别写成 `[+-]`：这份 ash 把它当区间；偏移形状一律照抄下面的逐字符写法。
  case "$z" in
    [+][0-9][0-9][0-9][0-9]|[-][0-9][0-9][0-9][0-9]) printf '%s' "$z"; return 0 ;;
  esac
  # 只在日志里补一个旁证：两个读数的差（只到小时）。它只用于肉眼判断，
  # 不参与任何换算——换算要的偏移由 tz_offset_s 给，判不出来时它给空。
  n=$(now_s)
  u=$("$BB" date -u +%s 2>/dev/null)
  case "$n$u" in
    ''|*[!0-9]*) printf '%s' "--" ;;
    *)
      n=$(( n - u ))
      if [ "$n" -lt 0 ]; then
        printf '%s' "--($(( (0 - n + 1800) / 3600 )))"
      else
        printf '%s' "--(+$(( (n + 1800) / 3600 )))"
      fi
      ;;
  esac
}

# 时区偏移的**秒数**（东八区 → 28800）：需要拿偏移做算术的地方往这里要。
# **判不出来时输出空**，让调用方走「不写钟点」那条路——宁可不写，也不要按 UTC
# 写一个偏几小时的钟点给用户看；`+0000` 是合法的 0，不是判不出来。
tz_offset_s() {
  local z sign rest h m
  z=$(tz_offset)
  # 同样别写 `[+-]`；`--` 开头一律当判不出来（退化路径的旁证值不参与换算）。
  case "$z" in
    ''|--|--*|-) return 0 ;;
    [+][0-9][0-9][0-9][0-9]|[-][0-9][0-9][0-9][0-9])
      sign=${z%"${z#?}"}                # 首字符（+ 或 -）
      rest=${z#?}
      m=${rest#??}; m=${m#0}; [ -n "$m" ] || m=0     # 后两位是分钟，剥前导 0
      h=${rest%??}; h=${h#0}; [ -n "$h" ] || h=0     # 前两位是小时，剥前导 0
      ;;
    [+]*|[-]*)                          # 退化的 `+8` / `-5`（同样避开 `[+-]`）
      sign=${z%"${z#?}"}
      h=${z#?}; h=${h#0}; [ -n "$h" ] || h=0
      m=0
      ;;
    *) return 0 ;;
  esac
  case "$h$m" in *[!0-9]*) return 0 ;; esac
  h=$(( h * 3600 + m * 60 ))
  if [ "$sign" = "-" ]; then printf '%s' "$(( 0 - h ))"; else printf '%s' "$h"; fi
}

# 毫秒时间戳 → 当日钟点 HH:MM（$2=要叠加的偏移秒数，缺省 0 即 UTC）。
# **不用 `date -d @<epoch>`**：设备上它给错值，改为纯算术
# (戳秒 + 偏移秒) mod 86400——不依赖时区库、不 fork。
ms_to_hm() { # $1=毫秒时间戳 $2=偏移秒数（省略=0 即 UTC；显式给空=判不出偏移 → 输出空）
  local e tod off
  e="$1"
  # `${2-0}` 而非 `${2:-0}`：要分开「没给」（当 UTC）与「给了但为空」（判不出偏移→输出空）。
  off="${2-0}"
  case "$e" in ''|*[!0-9]*) return 0 ;; esac
  case "$off" in ''|*[!0-9-]*) return 0 ;; esac
  tod=$(( (e / 1000 + off) % 86400 ))
  [ "$tod" -lt 0 ] && tod=$(( tod + 86400 ))
  printf '%02d:%02d' $(( tod / 3600 )) $(( tod % 3600 / 60 ))
}
