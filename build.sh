#!/bin/sh
# ============================================================
# 数字FAFU 晚查寝自动签到 —— 打包脚本
# 生成可刷入的模块 zip（输出到 dist/）
#
# 用法:
#   sh build.sh          发布构建 → dist/fafu-checkin-<版本>.zip
#   sh build.sh dev      开发构建 → dist/fafu-checkin-<版本>-dev.<commit>.zip
#
# 说明: dev 构建用于日常测试（带 commit 标识，可追溯）；
#       发布构建使用干净的文件名（与 update.json 的 zipUrl 对应）。
# ============================================================
set -e
cd "$(dirname "$0")"

VER=$(sed -n 's/^version=//p' module.prop | head -n1)

MODE="$1"
if [ "$MODE" = "dev" ]; then
  SHA="${GITHUB_SHA:-}"
  [ -n "$SHA" ] || SHA=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
  SHA=$(printf '%s' "$SHA" | cut -c1-7)
  OUT="dist/fafu-checkin-${VER}-dev.${SHA}.zip"
else
  OUT="dist/fafu-checkin-${VER}.zip"
fi

mkdir -p dist
rm -f "$OUT"

zip -X -r "$OUT" \
  module.prop customize.sh service.sh action.sh uninstall.sh fafu_checkin.sh \
  > /dev/null

echo "已生成: $OUT"
echo ""
unzip -l "$OUT"
