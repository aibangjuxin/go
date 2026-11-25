#!/usr/bin/env python3
"""prepare_foundation_apps.py 的单元测试。"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.dirname(os.path.dirname(HERE))
SCRIPT = os.path.join(HERE, "prepare_foundation_apps.py")
OUT_FILE = os.path.join(ROOT_DIR, "build", "foundation-apps.json")


def run_script() -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, SCRIPT],
        capture_output=True,
        text=True,
        check=False,
    )


class TestPrepareFoundationApps(unittest.TestCase):
    def test_script_succeeds(self) -> None:
        proc = run_script()
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)

    def test_output_file_created(self) -> None:
        self.assertEqual(run_script().returncode, 0)
        self.assertTrue(os.path.exists(OUT_FILE), "build/foundation-apps.json 没生成")
        with open(OUT_FILE, encoding="utf-8") as fh:
            doc = json.load(fh)
        self.assertEqual(doc["kind"], "ApplicationSet")
        self.assertEqual(doc["count"], len(doc["apps"]))

    def test_apps_sorted_and_have_required_fields(self) -> None:
        self.assertEqual(run_script().returncode, 0)
        with open(OUT_FILE, encoding="utf-8") as fh:
            doc = json.load(fh)
        names = [a["name"] for a in doc["apps"]]
        self.assertEqual(names, sorted(names), "apps 必须按 name 排序")
        for app in doc["apps"]:
            for field in ("name", "repo", "path", "syncPolicy"):
                self.assertIn(field, app)
            self.assertTrue(app["name"])

    def test_disabled_apps_excluded(self) -> None:
        self.assertEqual(run_script().returncode, 0)
        with open(OUT_FILE, encoding="utf-8") as fh:
            doc = json.load(fh)
        for app in doc["apps"]:
            self.assertTrue(app.get("enabled", True), "被禁用的 app 不该出现在产物里")

    def test_deterministic(self) -> None:
        self.assertEqual(run_script().returncode, 0)
        with open(OUT_FILE, encoding="utf-8") as fh:
            first = fh.read()
        self.assertEqual(run_script().returncode, 0)
        with open(OUT_FILE, encoding="utf-8") as fh:
            second = fh.read()
        self.assertEqual(first, second, "同样的输入必须产出同样的文件")


if __name__ == "__main__":
    unittest.main()
