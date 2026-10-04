# ============================================================
# base 层 —— 环境与工具：模块 / 工具链定位、日志与轮转、时间源、文件读写原语
#
# 加载顺序：第 1 层（最先）。本层不引用其它层的函数，其余各层都可以用本层。
# 对外提供：now_s / now_hm / now_full / today / today_tag / now_minutes / hm_minutes、
#   log / rotate_log、write_atomic、kv_get / kv_set、json_first。
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
# 各层一律用这里的函数取时间，不再自己调 "$BB" date（否则拨钟只对一半链路生效）。
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

# JSON 单字段提取：$1=JSON 文本 $2=字段名 → 该字段第一次出现的值（去掉两侧引号）。
# 只适用于扁平字段（本模块要取的 id / name / signState / 时间戳 / 坐标都是这一类）。
json_first() {
  printf '%s' "$1" | "$BB" grep -oE "\"$2\":(\"[^\"]*\"|[^,}]*)" \
    | "$BB" head -n 1 | "$BB" cut -d: -f2- | "$BB" tr -d '"'
}
