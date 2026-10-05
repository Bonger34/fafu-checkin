#!/bin/sh
# ============================================================
# 数字FAFU 晚查寝自动签到 —— 打包脚本：生成可刷入的模块 zip（输出到 dist/）
#
# 用法：
#   sh build.sh          发布构建 → dist/fafu-checkin-<版本>.zip（保留 updateJson）
#   sh build.sh dev      开发构建 → dist/fafu-checkin-<版本>-dev.<commit>.zip
#                        （带 commit 标识，移除 updateJson 以免被提示升级到正式版）
#
# 依赖与配置：Info-ZIP 的 zip / unzip；层清单从入口的 FAFU_LAYERS 读（唯一真源）。
# ============================================================
set -e
cd "$(dirname "$0")"
ROOT="$PWD"

# 打包依赖 Info-ZIP：zip 造包、unzip 核对产物。缺了就先说清楚缺什么，
# 而不是让 zip/unzip 自己的报错混在构建输出里
for c in zip unzip; do
  if ! command -v "$c" >/dev/null 2>&1; then
    echo "打包失败：找不到 $c（打包与产物核对需要 Info-ZIP 的 zip / unzip）" >&2
    exit 1
  fi
done

. "$ROOT/tools/lib.sh"
LIBFILES=$(read_layers "$ROOT")
[ -n "$LIBFILES" ] || { echo "打包失败：读不出层清单（$ROOT/fafu_checkin.sh 里的 FAFU_LAYERS）" >&2; exit 1; }

VER=$(sed -n 's/^version=//p' module.prop | head -n1)
FILES="module.prop customize.sh service.sh action.sh uninstall.sh fafu_checkin.sh"
DIRS="lib webroot"
PAGE="webroot/index.html"

# ---- 页面资源的结构断言（源树那两条放在打包之前，免得留下一个已经坏掉的 zip） ----
# 断言一：入口文件在源树里——清单写的路径必须真的存在
[ -f "$PAGE" ] || { echo "打包失败：源树里没有页面入口文件 $PAGE" >&2; exit 1; }
# 断言三：页面文本不含任何外部 URL——离线可用是硬要求，判据只有 tools/lib.sh 一份
PAGE_URLS=$(ext_url_hits "$PAGE")
if [ -n "$PAGE_URLS" ]; then
  echo "打包失败：页面引用了外部资源，离线可用是硬要求：" >&2
  printf '%s\n' "$PAGE_URLS" >&2
  exit 1
fi

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
  for d in $DIRS; do
    cp -pR "$d" "$STAGE/$d"
  done
  grep -v '^updateJson=' "$STAGE/module.prop" > "$STAGE/module.prop.new"
  mv "$STAGE/module.prop.new" "$STAGE/module.prop"
  # 统一权限（避免受 umask 影响）
  chmod 644 "$STAGE/module.prop"
  chmod 755 "$STAGE"/*.sh
  chmod 644 "$STAGE"/lib/*.sh
  SRC="$STAGE"
  NOTE="（开发版：已移除 updateJson，不参与更新检测）"
else
  OUT="$ROOT/dist/fafu-checkin-${VER}.zip"
  SRC="$ROOT"
  # 统一权限（避免受 umask 影响）
  chmod 644 "$ROOT/module.prop"
  chmod 755 "$ROOT"/*.sh
  chmod 644 "$ROOT"/lib/*.sh
  NOTE=""
fi

mkdir -p "$ROOT/dist"
rm -f "$OUT"

(cd "$SRC" && zip -X -r "$OUT" $FILES $DIRS > /dev/null)

# ---- 校验产物（缺文件即失败，不给「半装」留机会） ----
# 断言二：页面入口文件确实在产物里，且是清单里那个完整路径（不只看文件名）
ALLFILES="$FILES $LIBFILES $PAGE"
LISTING=$(unzip -l "$OUT")
for f in $ALLFILES; do
  if ! printf '%s\n' "$LISTING" | grep -q " $f\$"; then
    echo "打包失败：产物里缺少 $f" >&2
    exit 1
  fi
done
echo "产物校验通过：$(printf '%s' "$ALLFILES" | wc -w) 个文件（含全部层文件与页面入口）"

echo "已生成: dist/$(basename "$OUT") $NOTE"
echo ""
unzip -l "$OUT"
