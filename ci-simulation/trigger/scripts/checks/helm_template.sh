#!/usr/bin/env bash
# 检查项：Helm 渲染（helm template）
#  * lint 只看模板静态结构；template 才会真正渲染出 manifest
#  * 渲染失败通常是因为 values 缺字段 —— 这正是最常见的"合不进去"的原因
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

RELEASE="${HELM_RELEASE_NAME:-pr-validate}"
ERRFILE="$(mktemp)"
trap 'rm -f "$ERRFILE"' EXIT
FAIL=0
while IFS= read -r c; do
  [ -n "$c" ] || continue
  [ -d "$c" ] || continue
  echo "--- helm template $RELEASE $c"
  "$HELM_BIN" template "$RELEASE" "$c" >/dev/null 2>"$ERRFILE"
  RC=$?
  if [ "$RC" -ne 0 ]; then
    FAIL=$((FAIL+1))
    tail -8 "$ERRFILE"
  else
    echo "    rendered OK"
  fi
done <<< "$CHARTS"

if [ "$FAIL" -eq 0 ]; then
  echo "::summary::$COUNT 个 chart 渲染成功"
  exit 0
fi
echo "::summary::$FAIL/$COUNT 个 chart 渲染失败"
exit 1
