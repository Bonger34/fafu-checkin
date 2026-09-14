#!/usr/bin/env python3
"""将 update.json 同步到指定版本。

手动发布流程中使用（见 README「开发与发布」）：
    python3 scripts/sync_update_json.py <tag> <versionCode> <zipUrl>
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def main() -> int:
    if len(sys.argv) != 4:
        print("用法: sync_update_json.py <tag> <versionCode> <zipUrl>", file=sys.stderr)
        return 2

    tag = sys.argv[1]
    version_code = int(sys.argv[2])
    zip_url = sys.argv[3]

    path = ROOT / "update.json"
    data = json.loads(path.read_text(encoding="utf-8"))

    if (
        data.get("version") == tag
        and data.get("versionCode") == version_code
        and data.get("zipUrl") == zip_url
    ):
        print("update.json 已是目标状态，无需修改")
        return 0

    data["version"] = tag
    data["versionCode"] = version_code
    data["zipUrl"] = zip_url
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"✅ update.json → {tag} (versionCode {version_code})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
