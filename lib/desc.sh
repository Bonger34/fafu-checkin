# ============================================================
# desc 层 —— 模块描述：读状态层生成描述文本，并写入
#
# 加载顺序：第 6 层。描述文本只读状态层（开关 + 最近签到记录），本层不碰任何文件格式；
# 触发点由调用方决定，本层只提供这三个函数。
# 对外提供：desc_text（生成文本）/ set_desc（写入）/ update_desc（内容变化时才写）。
# 写入方式：KernelSU 官方覆盖优先，失败回退改写模块元数据。
# ============================================================

# 当前生效的描述：KernelSU 覆盖值为空时回退读模块元数据（否则会重复写入同一条描述）
_desc_current() {
  local cur
  if [ -n "$KSUD" ]; then
    cur=$(KSU_MODULE="$MODID" "$KSUD" module config get override.description 2>/dev/null)
  fi
  [ -n "$cur" ] || cur=$(kv_get "$MODDIR/module.prop" description)
  printf '%s' "$cur"
}

desc_text() { # 生成当前应显示的模块描述（使用绝对日期，守护进程退出后信息也不会失真）
  local today_v d t k dd
  today_v=$(today)
  d=$(sign_get sign_date)
  t=$(sign_get sign_time)
  k=$(sign_get sign_kind)
  if svc_is_disabled; then
    if [ -n "$d" ]; then
      dd=${d#*-}
      if [ -n "$t" ]; then echo "⏸ 已停用 · 最近签到 $dd $t"; else echo "⏸ 已停用 · 最近签到 $dd"; fi
    else
      echo "⏸ 已停用 · 暂无签到记录"
    fi
  elif [ "$d" = "$today_v" ] && [ "$k" = "leave" ]; then
    echo "🟢 已启用 · 🏖 ${d#*-} 已请假"
  elif [ "$d" = "$today_v" ]; then
    if [ -n "$t" ]; then echo "🟢 已启用 · ✅ ${d#*-} 已签到 $t"; else echo "🟢 已启用 · ✅ ${d#*-} 已签到"; fi
  else
    echo "🟢 已启用 · ⏳ ${today_v#*-} 未签到"
  fi
}

set_desc() { # $1=描述文本；优先 KernelSU 官方覆盖，失败则改写 module.prop（Magisk）
  local tmp
  if [ -n "$KSUD" ]; then
    if KSU_MODULE="$MODID" "$KSUD" module config set override.description "$1" >/dev/null 2>&1; then
      return 0
    fi
  fi
  [ -f "$MODDIR/module.prop" ] || return 1
  tmp="$MODDIR/module.prop.tmp"
  "$BB" grep -v '^description=' "$MODDIR/module.prop" > "$tmp" 2>/dev/null
  # 改写前必须校验：grep 失败会留下空文件，直接 mv 会把 module.prop 清空
  # （模块元数据全丢，管理器里连模块名都没了）
  [ -s "$tmp" ] || { rm -f "$tmp" 2>/dev/null; return 1; }
  printf 'description=%s\n' "$1" >> "$tmp"
  "$BB" mv -f "$tmp" "$MODDIR/module.prop" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  "$BB" chmod 644 "$MODDIR/module.prop" 2>/dev/null
  return 0
}

update_desc() { # 计算描述并写入（内容变化时才写）
  local new
  new=$(desc_text)
  [ "$new" = "$(_desc_current)" ] && return 0
  set_desc "$new"
}
