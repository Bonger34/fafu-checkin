#!/usr/bin/env python3
"""校验 module.prop 与 update.json 的格式与约束。

供 CI（.github/workflows/build.yml / check.yml）与本地开发使用。
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def load_props() -> dict:
    props = {}
    for line in (ROOT / "module.prop").read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and "=" in line:
            key, _, value = line.partition("=")
            props[key.strip()] = value.strip()
    return props


def main() -> int:
    props = load_props()

    # module.prop 约束
    assert re.match(r"^[a-zA-Z][a-zA-Z0-9._-]+$", props["id"]), "module id 不合法"
    assert props["versionCode"].isdigit(), "versionCode 必须为整数"
    assert props["updateJson"].startswith("https://"), "updateJson 必须为 https"

    # update.json 约束
    upd = json.loads((ROOT / "update.json").read_text(encoding="utf-8"))
    assert set(upd) == {"version", "versionCode", "zipUrl", "changelog"}, "update.json 字段异常"
    assert isinstance(upd["versionCode"], int), "update.json versionCode 必须为整数"
    assert upd["changelog"].startswith("https://"), "changelog 必须为 https"
    assert "/releases/" not in upd["changelog"], "changelog 不能指向 Release 网页（HTML）"

    print(
        "✅ 元数据 OK: "
        f"module.prop {props['version']} (code {props['versionCode']}) / "
        f"update.json {upd['version']} (code {upd['versionCode']})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
