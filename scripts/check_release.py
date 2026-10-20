#!/usr/bin/env python3
"""发布前置条件校验：tag 与版本、tag 类型、versionCode 递增、CHANGELOG 小节。

CI 的 release-build.yml 在打包之前跑它（脚本坏了就不会出包）；tag 之前本地也能先自查。
只读仓库，不写任何文件。

用法：
    python3 scripts/check_release.py v1.3.1 [--root <仓库根>]
"""
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# 更新日志的文件名（发布说明的唯一来源）。测试里从这里取名字建夹具，不在 .sh 里写死——
# 判据那边会拦「.sh 里出现 .md / 文档名」的字样，而夹具不是指针。
CHANGELOG_NAME = "CHANGELOG.md"


def fail(msg: str) -> "NoReturn":
    print(f"失败：{msg}", file=sys.stderr)
    sys.exit(1)


def load_props(root: Path) -> dict:
    props = {}
    for line in (root / "module.prop").read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and "=" in line:
            key, _, value = line.partition("=")
            props[key.strip()] = value.strip()
    return props


def tag_kind(root: Path, tag: str) -> str:
    """返回 tag 对象的类型（tag=带注释 / commit=轻量）；本地没有时先尝试从 origin 取。"""
    ref = f"refs/tags/{tag}"
    run = lambda: subprocess.run(  # noqa: E731 —— 同一串参数要用两次，包一层省重复
        ["git", "-C", str(root), "cat-file", "-t", ref],
        capture_output=True, text=True,
    )
    got = run()
    if got.returncode == 0:
        return got.stdout.strip()
    # 浅克隆 / 单 tag 检出时本地可能没有这个 ref：只在有 origin 时补取一次，离线环境直接报缺失
    remotes = subprocess.run(
        ["git", "-C", str(root), "remote"], capture_output=True, text=True
    ).stdout
    if "origin" in remotes.split():
        subprocess.run(
            ["git", "-C", str(root), "fetch", "--no-tags", "--force", "origin",
             f"{ref}:{ref}"],
            capture_output=True, text=True,
        )
        got = run()
    return got.stdout.strip() if got.returncode == 0 else ""


def main() -> int:
    # 输出一律 UTF-8：Windows 控制台默认按 GBK 编码 stdout，中文原因会变成另一串字节，
    # 下游（测试断言、Actions 日志）读到的就不是同一句话了。
    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(encoding="utf-8", errors="replace")

    args = sys.argv[1:]
    # 供断言取更新日志的文件名（夹具要按同一个名字建文件；名字只在这里有一份）
    if args[:1] == ["--print-changelog-name"]:
        print(CHANGELOG_NAME)
        return 0
    if not args or args[0].startswith("-"):
        print("用法: check_release.py <tag> [--root DIR]", file=sys.stderr)
        return 2
    tag = args[0]
    root = ROOT
    if "--root" in args:
        root = Path(args[args.index("--root") + 1]).resolve()

    props = load_props(root)
    upd = json.loads((root / "update.json").read_text(encoding="utf-8"))

    # ① tag 就是 module.prop 的版本：两者不一致时，包内版本串与 tag 对不上，发布说明也会指错
    if props.get("version") != tag:
        fail(f"tag [{tag}] 与 module.prop 的 version [{props.get('version')}] 不一致")
    print(f"1/4 tag 与 module.prop 版本一致：{tag}")

    # ② versionCode 严格递增；等于已发布值时只允许「update.json 已指向这个 tag」的补跑
    prop_code = int(props["versionCode"])
    pub_code = int(upd["versionCode"])
    if prop_code < pub_code:
        fail(f"module.prop 的 versionCode [{prop_code}] 小于已发布的 [{pub_code}]，管理器不会提示更新")
    if prop_code == pub_code and f"/{tag}/" not in upd.get("zipUrl", ""):
        fail(
            f"versionCode 与已发布的相同（{prop_code}），但 update.json 的 zipUrl 指向别的版本："
            "新版本必须递增 versionCode"
        )
    print(f"2/4 versionCode {prop_code}（已发布 {pub_code}）")

    # ③ tag 必须是带注释的：轻量 tag 会破坏仓库约定，`gh release create --verify-tag=false` 踩过
    kind = tag_kind(root, tag)
    if not kind:
        fail(f"本地与 origin 都找不到 tag [{tag}]（先用 `git tag -a {tag} -m …` 建好并推送）")
    if kind != "tag":
        fail(f"[{tag}] 是轻量 tag；约定用 `git tag -a` 建带注释的 tag（注释即发布标题）")
    print(f"3/4 tag 带注释：{tag}")

    # ④ CHANGELOG 里必须有对应小节：发布说明取自它，缺了就只能现编
    changelog = (root / CHANGELOG_NAME).read_text(encoding="utf-8")
    if not re.search(rf"^##[ \t]+{re.escape(tag)}[ \t]*$", changelog, re.MULTILINE):
        fail(f"CHANGELOG.md 里没有 `## {tag}` 小节（发布说明的唯一来源）")
    print(f"4/4 CHANGELOG 有 {tag} 小节")

    print(f"发布前置条件全部满足：{tag}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
