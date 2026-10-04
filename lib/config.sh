# ============================================================
# config 层 —— 配置：键登记、默认值、校验、写入、生效值读数
#
# 加载顺序：第 2 层（在环境与工具层之后、状态层之前）。本层是配置文件
# fafu-checkin.conf 的唯一归属地：其余层与入口只经这里的函数取值，不自己读写它，
# 也不各自兜默认值。
# 对外提供：cfg_load / cfg_effective / cfg_keys / cfg_time_ok / cfg_int_ok /
#   cfg_switch_ok / cfg_valid / cfg_reason / cfg_write，
#   以及各键的读取函数 cfg_keepalive / cfg_poll_start / cfg_poll_end / cfg_notify /
#   cfg_notify_lead / cfg_notify_cooldown / cfg_ka_start / cfg_ka_end。
# 生效值存放在与键同名的变量里：层加载时先落默认值，cfg_load 再按配置文件覆盖。
# ============================================================

CFG_FILE="$MODDIR/fafu-checkin.conf"

# ---- 键登记表（键名、默认值、写入顺序的唯一真源） ----
# 一行一个键：「键名<空格>默认值」。不在表里的键一律拒绝，不引入自由文本配置项。
_cfg_specs() {
  cat <<'SPECS'
KEEPALIVE 1
POLL_START 20:00
POLL_END 23:59
NOTIFY 1
NOTIFY_LEAD 5
NOTIFY_COOLDOWN 300
KA_START 07:00
KA_END 21:25
SPECS
}

# 按登记顺序输出全部键名（每行一个）
cfg_keys() { _cfg_specs | "$BB" cut -d' ' -f1; }

# 登记表里某键的默认值（未登记的键输出空）
_cfg_default() { # $1=键
  local k d
  while read -r k d; do
    if [ "$k" = "$1" ]; then printf '%s' "$d"; return 0; fi
  done <<SPECS
$(_cfg_specs)
SPECS
  return 0
}

# 该键是否登记在册
_cfg_registered() { # $1=键
  local k d
  while read -r k d; do
    [ "$k" = "$1" ] && return 0
  done <<SPECS
$(_cfg_specs)
SPECS
  return 1
}

# 写入某个键的生效值（赋值者只有 cfg_load 与它的起止修正）
_cfg_set() { # $1=键（必须在册） $2=值
  eval "$1=\$2"
}

# 全部键先落成登记表里的默认值：配置文件缺失、或被手改坏时，读数都由它兜底
_cfg_defaults() {
  local k
  for k in $(cfg_keys); do _cfg_set "$k" "$(_cfg_default "$k")"; done
}

# ---- 生效值读数 ----
# 该键现在真正生效的值：配置文件里的合法值优先，否则是登记表里的默认值。
# 未登记的键输出空（调用方据此判断「这个键不属于配置」）。
cfg_effective() { # $1=键
  local v
  _cfg_registered "$1" || return 0
  eval "v=\${$1:-}"
  [ -n "$v" ] || v=$(_cfg_default "$1")
  printf '%s' "$v"
}

# 各键的读取函数：其余层与入口用它取值，不直接读变量
cfg_keepalive()       { cfg_effective KEEPALIVE; }
cfg_poll_start()      { cfg_effective POLL_START; }
cfg_poll_end()        { cfg_effective POLL_END; }
cfg_notify()          { cfg_effective NOTIFY; }
cfg_notify_lead()     { cfg_effective NOTIFY_LEAD; }
cfg_notify_cooldown() { cfg_effective NOTIFY_COOLDOWN; }
cfg_ka_start()        { cfg_effective KA_START; }
cfg_ka_end()          { cfg_effective KA_END; }

# ---- 校验（返回值即结论；校验在写入之前发生） ----

# 时间项：严格 HH:MM（两位数字冒号两位数字）且落在 00:00–23:59
cfg_time_ok() { # $1=值
  case "$1" in
    [0-1][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) return 0 ;;
    *) return 1 ;;
  esac
}

# 整数项：纯十进制，且落在闭区间 [下界, 上界]
cfg_int_ok() { # $1=值 $2=下界 $3=上界
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}

# 开关项：只接受 0 或 1
cfg_switch_ok() { # $1=值
  case "$1" in
    0|1) return 0 ;;
    *) return 1 ;;
  esac
}

# 单个键值是否可接受（起止类的先后由 cfg_write 与 cfg_load 另行判定）
cfg_valid() { # $1=键 $2=值
  case "$1" in
    KEEPALIVE|NOTIFY)                    cfg_switch_ok "$2" ;;
    NOTIFY_LEAD)                         cfg_int_ok "$2" 0 600 ;;
    NOTIFY_COOLDOWN)                     cfg_int_ok "$2" 0 86400 ;;
    POLL_START|POLL_END|KA_START|KA_END) cfg_time_ok "$2" ;;
    *) return 1 ;;
  esac
}

# 不合格的可读原因（合格时输出空）：给使用者与配置页看的，故写清接受范围
cfg_reason() { # $1=键 $2=值
  if ! _cfg_registered "$1"; then
    printf '未登记的配置键：%s' "$1"
    return 0
  fi
  cfg_valid "$1" "$2" && return 0
  case "$1" in
    KEEPALIVE|NOTIFY) printf '只能填 0 或 1（当前 %s）' "$2" ;;
    NOTIFY_LEAD)      printf '只能填 0–600 的整数秒（当前 %s）' "$2" ;;
    NOTIFY_COOLDOWN)  printf '只能填 0–86400 的整数秒（当前 %s）' "$2" ;;
    *)                printf '只能填 HH:MM 形式的时刻，范围 00:00–23:59（当前 %s）' "$2" ;;
  esac
  return 0
}

# 加载时先把默认值落好：任何层在任何时候读数都不会拿到空
_cfg_defaults

# ---- 加载配置文件 ----
# 入口在装配阶段调一次。缺文件即全取默认值；某个键的值不合法（只有手改能造出）
# 就退回该键的默认值——坏文件不该让程序崩，也不该悄悄改变行为。
cfg_load() {
  local k v
  while read -r k; do
    [ -n "$k" ] || continue
    v=$(kv_get "$CFG_FILE" "$k")
    cfg_valid "$k" "$v" || v=$(_cfg_default "$k")
    _cfg_set "$k" "$v"
  done <<KEYS
$(cfg_keys)
KEYS
  _cfg_fix_pair POLL_START POLL_END
  _cfg_fix_pair KA_START KA_END
  return 0
}

# 起点必须严格早于终点（不支持跨午夜）
_cfg_order_ok() { # $1=起点 $2=终点
  cfg_time_ok "$1" && cfg_time_ok "$2" && [ "$(hm_minutes "$1")" -lt "$(hm_minutes "$2")" ]
}

# 先后颠倒时整对退回默认值：只退一半会让读到的区间更没有意义
_cfg_fix_pair() { # $1=起点键 $2=终点键
  _cfg_order_ok "$(cfg_effective "$1")" "$(cfg_effective "$2")" && return 0
  _cfg_set "$1" "$(_cfg_default "$1")"
  _cfg_set "$2" "$(_cfg_default "$2")"
}

# ---- 写入（唯一闸门：别的层不直接碰这个文件） ----

# 候选值：批次里最后一次出现的为准，批次里没提到的键沿用当前生效值
_cfg_cand() { # $1=键，其余=「键=值」批次
  local k p out
  k="$1"; shift
  out=""
  for p in "$@"; do
    [ "${p%%=*}" = "$k" ] && out="${p#*=}"
  done
  [ -n "$out" ] || out=$(cfg_effective "$k")
  printf '%s' "$out"
}

# 先校验全部（键在册、值合法、起止先后），全过才整份原子重写，最后回读生效值回显。
# 任一步不过：非 0 返回 + 可读原因，磁盘与生效值都保持原样。
cfg_write() { # $1…=「键=值」
  local pair k v body
  [ $# -gt 0 ] || { echo "没有要写入的配置项（用法：键=值 …）" >&2; return 1; }
  for pair in "$@"; do
    case "$pair" in
      *=*) : ;;
      *) echo "配置项要写成 键=值：$pair" >&2; return 1 ;;
    esac
    k=${pair%%=*}; v=${pair#*=}
    if ! _cfg_registered "$k"; then
      echo "未登记的配置键：$k" >&2
      return 1
    fi
    if ! cfg_valid "$k" "$v"; then
      echo "$k 的值不合法：$(cfg_reason "$k" "$v")" >&2
      return 1
    fi
  done
  if ! _cfg_order_ok "$(_cfg_cand POLL_START "$@")" "$(_cfg_cand POLL_END "$@")"; then
    echo "轮询范围起（$(_cfg_cand POLL_START "$@")）必须早于止（$(_cfg_cand POLL_END "$@")），不支持跨午夜" >&2
    return 1
  fi
  if ! _cfg_order_ok "$(_cfg_cand KA_START "$@")" "$(_cfg_cand KA_END "$@")"; then
    echo "保活时段起（$(_cfg_cand KA_START "$@")）必须早于止（$(_cfg_cand KA_END "$@")），不支持跨午夜" >&2
    return 1
  fi
  # 整份原子重写：按登记顺序写出全部键（不保留手写注释，也不保留表外的键）
  body=""
  for k in $(cfg_keys); do
    v=$(_cfg_cand "$k" "$@")
    body="$body$k=$v
"
  done
  printf '%s' "$body" | write_atomic "$CFG_FILE" || { echo "写入失败：$CFG_FILE" >&2; return 1; }
  # 回读生效值：读的是刚落盘的那份文件，回显给调用方确认值真的进去了
  cfg_load
  for k in $(cfg_keys); do
    v=$(cfg_effective "$k")
    printf '%s=%s\n' "$k" "$v"
  done
  return 0
}
