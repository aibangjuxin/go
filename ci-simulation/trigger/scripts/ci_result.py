#!/usr/bin/env python3
"""CI 结果的读写层。

约定（整套模板靠这个协议串起来）：
  * 每个校验 step 结束，在 RESULT_DIR 下写一个 <slug>.json；
  * JSON 字段固定：name / status / exit_code / duration_s / summary / details / files / order；
  * status 取值：passed / failed / skipped；
  * 最后的 report step 读全部 JSON → 渲染 markdown → 回填 PR。

用法：
  python3 ci_result.py write        # 从环境变量读（ci_step.sh 用这条）
  python3 ci_result.py check        # 有 failed 就 exit 1（让 build 变红）
  python3 ci_result.py list         # 打印所有结果
"""
import glob
import json
import os
import re
import sys

RESULT_DIR = os.environ.get("RESULT_DIR", "/workspace/artifacts/results")
MARKER = os.environ.get("REPORT_MARKER", "<!-- pull-report-bot:report -->")
STATUSES = ("passed", "failed", "skipped")


def slugify(name):
    s = re.sub(r"[^0-9a-zA-Z]+", "-", str(name).strip().lower()).strip("-")
    return s or "step"


def result_dir():
    return os.environ.get("RESULT_DIR", RESULT_DIR)


def write_result(rec, directory=None):
    d = directory or result_dir()
    os.makedirs(d, exist_ok=True)
    rec = dict(rec)
    rec.setdefault("status", "passed")
    if rec["status"] not in STATUSES:
        raise ValueError("bad status: %s" % rec["status"])
    rec.setdefault("exit_code", 0)
    rec.setdefault("duration_s", 0.0)
    rec.setdefault("summary", "")
    rec.setdefault("details", "")
    rec.setdefault("files", None)
    rec.setdefault("order", 999)
    path = os.path.join(d, slugify(rec.get("name", "step")) + ".json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(rec, f, ensure_ascii=False, indent=2)
    return path


def load_results(directory=None):
    d = directory or result_dir()
    out = []
    for p in sorted(glob.glob(os.path.join(d, "*.json"))):
        try:
            with open(p, encoding="utf-8") as f:
                out.append(json.load(f))
        except Exception as exc:  # 一个坏文件不该让整份报告挂掉
            out.append({
                "name": os.path.basename(p),
                "status": "failed",
                "summary": "结果文件解析失败: %s" % exc,
                "details": "",
                "duration_s": 0,
                "files": None,
                "order": 998,
            })
    out.sort(key=lambda r: (r.get("order", 999), r.get("name", "")))
    return out


def _write_from_env():
    files = os.environ.get("CI_STEP_FILES", "").strip()
    rec = {
        "name": os.environ.get("CI_STEP_NAME", "unnamed"),
        "status": os.environ.get("CI_STEP_STATUS", "passed"),
        "exit_code": int(os.environ.get("CI_STEP_CODE", "0") or 0),
        "duration_s": float(os.environ.get("CI_STEP_DURATION", "0") or 0),
        "summary": os.environ.get("CI_STEP_SUMMARY", ""),
        "details": os.environ.get("CI_STEP_DETAILS", ""),
        "files": int(files) if files.isdigit() else None,
        "order": int(os.environ.get("CI_STEP_ORDER", "999") or 999),
    }
    path = write_result(rec)
    print("[ci_result] wrote %s (%s)" % (path, rec["status"]))
    return 0


def _check():
    results = load_results()
    failed = [r for r in results if r.get("status") == "failed"]
    if failed:
        for r in failed:
            print("[ci_result] FAILED: %s -- %s" % (r.get("name"), r.get("summary", "")))
        return 1
    print("[ci_result] 全部通过（或跳过）")
    return 0


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "list"
    if cmd == "write":
        return _write_from_env()
    if cmd == "check":
        return _check()
    if cmd == "list":
        for r in load_results():
            print("%-10s %-28s %s" % (r.get("status"), r.get("name"), r.get("summary", "")))
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
