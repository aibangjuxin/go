#!/usr/bin/env python3
"""把各 step 的结果 JSON 渲染成一份 markdown report（回填到 PR 的那份）。

用法：
  python3 render_report.py --out /workspace/artifacts/report.md
  python3 render_report.py            # 直接打到 stdout

环境变量（Cloud Build 内置 substitution 会被 automapSubstitutions 带进来）：
  PR_NUMBER / REPO_FULL_NAME / BUILD_ID / PROJECT_ID / LOCATION
  COMMIT_SHA / SHORT_SHA / HEAD_BRANCH / BASE_BRANCH / TRIGGER_NAME
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ci_result  # noqa: E402

ICON = {"passed": "✅ passed", "failed": "❌ failed", "skipped": "⏭️ skipped"}
FENCE = chr(96) * 3
CODE = chr(96)


def console_url(project, location, build_id):
    """Cloud Build 控制台链接。

    官方最稳的拿法是 gcloud：
      gcloud builds describe $BUILD_ID --format='value(logUrl)'
    这里按新版控制台格式拼一个；region 为空时按 global 处理。
    """
    if not build_id:
        return ""
    location = location or "global"
    return ("https://console.cloud.google.com/cloud-build/builds;region=%s/%s?project=%s"
            % (location, build_id, project or ""))


def render(results, args):
    env = os.environ
    pr = args.pr or env.get("PR_NUMBER", "")
    repo = args.repo or env.get("REPO_FULL_NAME", "")
    build_id = args.build_id or env.get("BUILD_ID", "")
    project = args.project or env.get("PROJECT_ID", "")
    location = args.location or env.get("LOCATION", "")
    sha = env.get("SHORT_SHA") or env.get("COMMIT_SHA", "")
    head = env.get("HEAD_BRANCH", "")
    base = env.get("BASE_BRANCH", "")
    trigger = env.get("TRIGGER_NAME", "")

    passed = [r for r in results if r.get("status") == "passed"]
    failed = [r for r in results if r.get("status") == "failed"]
    skipped = [r for r in results if r.get("status") == "skipped"]

    if failed:
        verdict = "❌ **%d passed / %d failed / %d skipped** —— 有检查未通过" % (
            len(passed), len(failed), len(skipped))
    elif results:
        verdict = "✅ **%d passed / 0 failed / %d skipped** —— 全部通过" % (
            len(passed), len(skipped))
    else:
        verdict = "⚠️ **没有收集到任何检查结果**"

    out = []
    out.append(ci_result.MARKER)
    out.append("## %s · PR %s 校验报告" % (args.bot_name, pr if pr else "-"))
    out.append("")
    out.append(verdict)
    out.append("")
    out.append("| 检查项 | 结果 | 耗时 | 说明 |")
    out.append("|---|---|---|---|")
    for r in results:
        name = r.get("name", "?")
        status = r.get("status", "passed")
        dur = r.get("duration_s", 0)
        summary = (r.get("summary") or "").replace("|", "\\|").replace("\\n", " ")
        files = r.get("files")
        if files:
            summary = ("%s（%d 个文件）" % (summary, files)).strip()
        out.append("| %s | %s | %ss | %s |" % (name, ICON.get(status, status), dur, summary))
    if not results:
        out.append("| _（无）_ | - | - | - |")

    failed_details = [r for r in results if r.get("status") == "failed" and r.get("details")]
    if failed_details:
        out.append("")
        out.append("<details><summary>失败详情</summary>")
        out.append("")
        for r in failed_details:
            out.append("**%s**" % r.get("name"))
            out.append("")
            out.append(FENCE)
            out.append((r.get("details") or "").rstrip())
            out.append(FENCE)
            out.append("")
        out.append("</details>")

    meta = []
    if repo:
        meta.append("仓库 %s%s%s" % (CODE, repo, CODE))
    if head:
        meta.append("分支 %s%s%s → %s%s%s" % (CODE, head, CODE, CODE, base or "?", CODE))
    if sha:
        meta.append("commit %s%s%s" % (CODE, sha, CODE))
    if trigger:
        meta.append("trigger %s%s%s" % (CODE, trigger, CODE))
    if meta:
        out.append("")
        out.append("<sub>" + " · ".join(meta) + "</sub>")

    url = console_url(project, location, build_id)
    if url:
        out.append("")
        out.append("🔗 [查看 Cloud Build 构建与完整日志](%s)" % url)
        out.append("")
        out.append("<sub>build id: %s%s%s</sub>" % (CODE, build_id, CODE))

    out.append("")
    out.append("<sub>由 Cloud Build trigger %s%s%s 自动生成；重复 push 会覆盖同一条评论。</sub>"
               % (CODE, trigger or "pull-report-bot", CODE))
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", default=None, help="结果目录")
    ap.add_argument("--out", default=None, help="输出文件（默认 stdout）")
    ap.add_argument("--pr", default=None)
    ap.add_argument("--repo", default=None)
    ap.add_argument("--build-id", default=None)
    ap.add_argument("--project", default=None)
    ap.add_argument("--location", default=None)
    ap.add_argument("--bot-name", default=os.environ.get("REPORT_BOT_NAME", "pull-report-bot"))
    ap.add_argument("--fail-on-error", action="store_true",
                    help="有 failed 项时 exit 1（让 build 变红）")
    args = ap.parse_args()

    results = ci_result.load_results(args.results)
    md = render(results, args)

    if args.out:
        d = os.path.dirname(os.path.abspath(args.out))
        if d:
            os.makedirs(d, exist_ok=True)
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(md)
        print("[render_report] wrote %s" % args.out)
    else:
        print(md)

    if args.fail_on_error and any(r.get("status") == "failed" for r in results):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
