#!/usr/bin/env bash
# ci_step.sh —— 校验 step 的统一包装器（整套 report 模板的核心）。
#
# 用法：
#   ci_step.sh "<检查项名称>" <命令...>
#
# 约定：
#   * 命令退出码 0   → passed
#   * 命令退出码 77  → skipped（本次没有需要检查的文件）
#   * 其他退出码      → failed
#   * 本脚本自己**永远 exit 0**：校验失败不能让 build 提前中断，
#     否则后面的 report step 跑不到，就永远没有报告。
#     “这次 build 该不该红”由最后的 report step 统一决定。
#
# 命令可以额外输出两行协议，wrapper 会提取成结构化字段：
#   ::files::12         本次检查了多少个文件
#   ::summary::12 个 YAML 语法通过   一句话结论（会出现在报告表格里）
#
# 环境变量：
#   RESULT_DIR   结果目录（默认 /workspace/artifacts/results）
#   CI_STEP_ORDER 报告里的排序（小到大）
set -uo pipefail

NAME="${1:?用法: ci_step.sh <检查项名称> <命令...>}"
shift || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULT_DIR="${RESULT_DIR:-/workspace/artifacts/results}"
OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT

if [ "$#" -eq 0 ]; then
  echo "::summary::没有可执行的检查命令"
  CI_STEP_NAME="$NAME" CI_STEP_STATUS="failed" CI_STEP_CODE="2" \
  CI_STEP_DURATION="0" CI_STEP_SUMMARY="没有可执行的检查命令" CI_STEP_DETAILS="" \
  RESULT_DIR="$RESULT_DIR" python3 "$SCRIPT_DIR/ci_result.py" write
  exit 0
fi

START="$(date +%s.%N)"
set +e
"$@" >"$OUT" 2>&1
CODE=$?
END="$(date +%s.%N)"
DURATION="$(awk -v a="$START" -v b="$END" 'BEGIN{printf "%.1f", (b-a)*1000/1000}')"

case "$CODE" in
  0)  STATUS=passed ;;
  77) STATUS=skipped ;;
  *)  STATUS=failed ;;
esac

FILES="$(grep -m1 '^::files::' "$OUT" | sed 's/^::files:://' || true)"
SUMMARY="$(grep -m1 '^::summary::' "$OUT" | sed 's/^::summary:://' || true)"
DETAILS="$(grep -v '^::summary::' "$OUT" | grep -v '^::files::' | tail -n 40 | cut -c1-500 || true)"

if [ -z "$SUMMARY" ]; then
  SUMMARY="$(grep -v '^::' "$OUT" | grep -m1 '.' | cut -c1-200 || true)"
  [ -z "$SUMMARY" ] && SUMMARY="(无输出)"
fi

# 没显式给 CI_STEP_ORDER 时，按调用顺序自动递增（保证报告里的顺序 = 执行顺序）
if [ -z "${CI_STEP_ORDER:-}" ]; then
  CI_STEP_ORDER=$(( $(ls -1 "${RESULT_DIR}"/*.json 2>/dev/null | wc -l) + 1 ))
fi

CI_STEP_NAME="$NAME" \
CI_STEP_STATUS="$STATUS" \
CI_STEP_CODE="$CODE" \
CI_STEP_DURATION="$DURATION" \
CI_STEP_SUMMARY="$SUMMARY" \
CI_STEP_DETAILS="$DETAILS" \
CI_STEP_FILES="$FILES" \
CI_STEP_ORDER="$CI_STEP_ORDER" \
RESULT_DIR="$RESULT_DIR" \
python3 "$SCRIPT_DIR/ci_result.py" write

echo "----- $NAME ($STATUS, ${DURATION}s) -----"
tail -n 20 "$OUT"
exit 0
