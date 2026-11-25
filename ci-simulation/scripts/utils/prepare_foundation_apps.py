#!/usr/bin/env python3
"""生成 foundation apps 清单（模拟 Argo CD ApplicationSet 的渲染产物）。

刻意只用标准库：CI 容器里不需要 pip install，跑得起来比什么都重要。
"""
from __future__ import annotations

import json
import os
import sys

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SOURCE = os.path.join(ROOT_DIR, "apps", "foundation-apps.json")
OUT_DIR = os.path.join(ROOT_DIR, "build")
OUT_FILE = os.path.join(OUT_DIR, "foundation-apps.json")

REQUIRED_FIELDS = ("name", "repo", "path", "syncPolicy")


def load_apps() -> list:
    with open(SOURCE, encoding="utf-8") as fh:
        doc = json.load(fh)
    apps = doc.get("apps", [])
    for app in apps:
        missing = [f for f in REQUIRED_FIELDS if f not in app]
        if missing:
            raise ValueError("app 缺少字段: %s" % missing)
    return apps


def build(apps: list) -> dict:
    enabled = sorted(
        (a for a in apps if a.get("enabled", True)),
        key=lambda a: a["name"],
    )
    return {
        "apiVersion": "argoproj.io/v1alpha1",
        "kind": "ApplicationSet",
        "apps": enabled,
        "count": len(enabled),
    }


def main() -> int:
    apps = load_apps()
    payload = build(apps)
    os.makedirs(OUT_DIR, exist_ok=True)
    with open(OUT_FILE, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2, sort_keys=True, ensure_ascii=False)
        fh.write("\n")
    print("[prepare_foundation_apps] 生成 %d 个 app -> %s" % (payload["count"], OUT_FILE))
    return 0


if __name__ == "__main__":
    sys.exit(main())
