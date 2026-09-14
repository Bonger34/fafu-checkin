#!/bin/sh
# ============================================================
# 数字FAFU 晚查寝自动签到 —— 打包脚本
# 生成可刷入的模块 zip（输出到 dist/）
# 用法: sh build.sh
# ============================================================
set -e
cd "$(dirname "$0")"

VER=$(sed -n 's/^version=//p' module.prop | head -n1)
OUT="dist/fafu-checkin-${VER}.zip"

mkdir -p dist
rm -f "$OUT"

zip -X -r "$OUT" \
  module.prop customize.sh service.sh action.sh uninstall.sh fafu_checkin.sh \
  > /dev/null

echo "已生成: $OUT"
echo ""
unzip -l "$OUT"
