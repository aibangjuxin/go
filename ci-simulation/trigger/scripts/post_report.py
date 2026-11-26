#!/usr/bin/env python3
"""把 report 回填到 PR：新建评论，或用 marker 找到旧评论并更新（幂等）。

只用标准库（urllib），不需要在 builder 镜像里 pip install 任何东西。

用法：
  python3 post_report.py --body /workspace/artifacts/report.md
  python3 post_report.py --body report.md --dry-run

环境变量：
  GITHUB_TOKEN  具备 issues: write 的 token（PAT 或 installation token）
  REPO          owner/repo
  PR_NUMBER     PR 号
  GITHUB_API    API 基址（GHES 改成 https://ghe.example.com/api/v3）
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ci_result  # noqa: E402

API = os.environ.get("GITHUB_API", "https://api.github.com")


def request(method, url, token, payload=None):
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    req.add_header("User-Agent", "pull-report-bot")
    req.add_header("Authorization", "Bearer " + token)
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8")
            return resp.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        raise SystemExit("[post_report] HTTP %s %s\n%s" % (exc.code, url, detail))


def find_existing(repo, pr, token, marker):
    """翻页找带 marker 的评论（marker 用来做幂等更新）。"""
    page = 1
    while page <= 5:
        url = "%s/repos/%s/issues/%s/comments?per_page=100&page=%d" % (API, repo, pr, page)
        _, comments = request("GET", url, token)
        if not comments:
            break
        for c in comments:
            if marker in (c.get("body") or ""):
                return c
        if len(comments) < 100:
            break
        page += 1
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--body", required=True, help="markdown 文件路径")
    ap.add_argument("--repo", default=os.environ.get("REPO", ""))
    ap.add_argument("--pr", default=os.environ.get("PR_NUMBER", ""))
    ap.add_argument("--marker", default=ci_result.MARKER)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    if not args.repo or not args.pr:
        print("[post_report] 缺少 REPO / PR_NUMBER，跳过回填（本地 dry-run 常见）")
        return 0

    with open(args.body, encoding="utf-8") as f:
        body = f.read()

    token = os.environ.get("GITHUB_TOKEN", "")
    if not token:
        if args.dry_run:
            print("[post_report][dry-run] 没有 GITHUB_TOKEN，只打印 payload，不发请求")
            print(json.dumps({"body": body}, ensure_ascii=False)[:2000])
            return 0
        print("[post_report] 没有 GITHUB_TOKEN，跳过回填")
        return 0

    if args.dry_run:
        try:
            existing = find_existing(args.repo, args.pr, token, args.marker)
        except SystemExit as exc:
            print("[post_report][dry-run] 查询历史评论失败（按新建处理）: %s" % exc)
            existing = None
    else:
        existing = find_existing(args.repo, args.pr, token, args.marker)
    if existing:
        method = "PATCH"
        url = "%s/repos/%s/issues/comments/%s" % (API, args.repo, existing["id"])
    else:
        method = "POST"
        url = "%s/repos/%s/issues/%s/comments" % (API, args.repo, args.pr)

    payload = {"body": body}
    if args.dry_run:
        print("[post_report][dry-run] %s %s" % (method, url))
        print(json.dumps(payload, ensure_ascii=False)[:2000])
        return 0

    status, resp = request(method, url, token, payload)
    print("[post_report] %s %s -> HTTP %s" % (method, url, status))
    if resp and isinstance(resp, dict):
        print("[post_report] comment id=%s url=%s" % (resp.get("id"), resp.get("html_url")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
