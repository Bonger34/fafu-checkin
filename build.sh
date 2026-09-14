#!/bin/sh
# ============================================================
# 数字FAFU 晚查寝自动签到 —— 打包脚本
# 生成可刷入的模块 zip（输出到 dist/）
#
# 用法:
#   sh build.sh          发布构建 → dist/fafu-checkin-<版本>.zip
#   sh build.sh dev      开发构建 → dist/fafu-checkin-<版本>-dev.<commit>.zip
#
# 说明:
#   - dev 构建用于日常测试（带 commit 标识，可追溯），
#     并会移除 module.prop 中的 updateJson（不参与管理器更新检测，
#     避免开发版被提示升级到正式版）；
#   - 发布构建保留 updateJson，文件名与 update.json 的 zipUrl 对应。
# ============================================================
set -e
cd "$(dirname "$0")"
ROOT="$PWD"

VER=$(sed -n 's/^version=//p' module.prop | head -n1)
FILES="module.prop customize.sh service.sh action.sh uninstall.sh fafu_checkin.sh"

MODE="$1"
if [ "$MODE" = "dev" ]; then
  SHA="${GITHUB_SHA:-}"
  [ -n "$SHA" ] || SHA=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
  SHA=$(printf '%s' "$SHA" | cut -c1-7)
  OUT="$ROOT/dist/fafu-checkin-${VER}-dev.${SHA}.zip"

  # 暂存目录：移除 updateJson 后再打包（不改动仓库中的 module.prop）
  STAGE=$(mktemp -d)
  trap 'rm -rf "$STAGE"' EXIT
  for f in $FILES; do
    cp -p "$f" "$STAGE/"
  done
  grep -v '^updateJson=' "$STAGE/module.prop" > "$STAGE/module.prop.new"
  mv "$STAGE/module.prop.new" "$STAGE/module.prop"
  # 统一权限（避免受 umask 影响）
  chmod 644 "$STAGE/module.prop"
  chmod 755 "$STAGE"/*.sh
  SRC="$STAGE"
  NOTE="（开发版：已移除 updateJson，不参与更新检测）"
else
  OUT="$ROOT/dist/fafu-checkin-${VER}.zip"
  SRC="$ROOT"
  # 统一权限（避免受 umask 影响）
  chmod 644 "$ROOT/module.prop"
  chmod 755 "$ROOT"/*.sh
  NOTE=""
fi

mkdir -p "$ROOT/dist"
rm -f "$OUT"

(cd "$SRC" && zip -X -r "$OUT" $FILES > /dev/null)

echo "已生成: dist/$(basename "$OUT") $NOTE"
echo ""
unzip -l "$OUT"
