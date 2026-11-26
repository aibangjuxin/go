#!/usr/bin/env bash
# 检查项：Helm lint
#  * 找出本次改动涉及的 chart（含 Chart.yaml 的目录）
#  * helm lint --strict：warning 也算失败，适合做门禁
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib_changed.sh"

HELM_BIN="${TOOLS_BIN_DIR:-$PWD/.tools/bin}/helm"
[ -x "$HELM_BIN" ] || HELM_BIN="$(command -v helm || true)"
if [ -z "$HELM_BIN" ]; then
  echo "::summary::找不到 helm（install_deps.sh 会把它装进 TOOLS_BIN_DIR）"
  exit 1
fi

CHARTS="$(changed_files | grep -E '(^|/)Chart\.yaml$' | xargs -r -n1 dirname | sort -u)"
COUNT="$(printf '%s\n' "$CHARTS" | grep -c . || true)"
if [ "$COUNT" = "0" ]; then
  echo "::summary::本次没有 Helm chart 改动"
  exit 77
fi
echo "::files::$COUNT"

FAIL=0
while IFS= read -r c; do
  [ -n "$c" ] || continue
  [ -d "$c" ] || continue
  echo "--- helm lint $c"
  OUT="$( "$HELM_BIN" lint "$c" --strict 2>&1 )"
  RC=$?
  echo "$OUT" | tail -5
  if [ "$RC" -ne 0 ]; then
    FAIL=$((FAIL+1))
  fi
done <<< "$CHARTS"

if [ "$FAIL" -eq 0 ]; then
  echo "::summary::$COUNT 个 chart lint 通过"
  exit 0
fi
echo "::summary::$FAIL/$COUNT 个 chart lint 失败"
exit 1
