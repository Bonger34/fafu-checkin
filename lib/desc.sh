# ============================================================
# desc 层 —— 模块描述：读状态层生成描述文本，并写入
#
# 加载顺序：第 6 层。写入沿用「KernelSU 官方覆盖优先、失败回退改写模块元数据」，
# 且改写前必须校验：grep 失败会留下空文件，直接 mv 会把 module.prop 清空
# （模块元数据全丢，管理器里连模块名都没了）。
# ============================================================

desc_text() { # 生成当前应显示的模块描述（使用绝对日期，守护进程退出后信息也不会失真）
  _today=$("$BB" date +%Y-%m-%d)
  d=$(status_get sign_date)
  t=$(status_get sign_time)
  k=$(status_get sign_kind)
  if is_disabled; then
    if [ -n "$d" ]; then
      dd=${d#*-}
      if [ -n "$t" ]; then echo "⏸ 已停用 · 最近签到 $dd $t"; else echo "⏸ 已停用 · 最近签到 $dd"; fi
    else
      echo "⏸ 已停用 · 暂无签到记录"
    fi
  elif [ "$d" = "$_today" ] && [ "$k" = "leave" ]; then
    echo "🟢 已启用 · 🏖 ${d#*-} 已请假"
  elif [ "$d" = "$_today" ]; then
    if [ -n "$t" ]; then echo "🟢 已启用 · ✅ ${d#*-} 已签到 $t"; else echo "🟢 已启用 · ✅ ${d#*-} 已签到"; fi
  else
    echo "🟢 已启用 · ⏳ ${_today#*-} 未签到"
  fi
}

set_desc() { # $1=描述文本；优先 KernelSU 官方覆盖，失败则改写 module.prop（Magisk）
  if [ -n "$KSUD" ]; then
    if KSU_MODULE="$MODID" "$KSUD" module config set override.description "$1" >/dev/null 2>&1; then
      return 0
    fi
  fi
  [ -f "$MODDIR/module.prop" ] || return 1
  tmp="$MODDIR/module.prop.tmp"
  "$BB" grep -v '^description=' "$MODDIR/module.prop" > "$tmp" 2>/dev/null
  # 校验：grep 失败会留下空文件，直接 mv 会把 module.prop 清空（模块元数据全丢）
  [ -s "$tmp" ] || { rm -f "$tmp" 2>/dev/null; return 1; }
  printf 'description=%s\n' "$1" >> "$tmp"
  "$BB" mv -f "$tmp" "$MODDIR/module.prop" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  "$BB" chmod 644 "$MODDIR/module.prop" 2>/dev/null
  return 0
}

update_desc() { # 计算描述并写入（内容变化时才写）
  new=$(desc_text)
  cur=""
  if [ -n "$KSUD" ]; then
    cur=$(KSU_MODULE="$MODID" "$KSUD" module config get override.description 2>/dev/null)
  fi
  if [ -z "$cur" ] && [ -f "$MODDIR/module.prop" ]; then
    cur=$("$BB" grep -m1 '^description=' "$MODDIR/module.prop" 2>/dev/null | "$BB" cut -d= -f2-)
  fi
  [ "$new" = "$cur" ] && return 0
  set_desc "$new"
}
