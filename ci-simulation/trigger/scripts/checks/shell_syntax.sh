#!/usr/bin/env bash
# 检查项：Shell 语法校验
#  * 只看本次 PR 改动的 *.sh
#  * 用 bash -n：只解析、不执行（安全 + 快）
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib_changed.sh"

FILES="$(filter_ext '\.sh$' | sort -u)"
COUNT="$(printf '%s\n' "$FILES" | grep -c . || true)"
if [ "$COUNT" = "0" ]; then
  echo "::summary::本次没有 shell 改动"
  exit 77
fi
echo "::files::$COUNT"

FAIL=0
CHECKED=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$f" ] || continue
  CHECKED=$((CHECKED+1))
  ERR="$(bash -n "$f" 2>&1)"
  if [ -z "$ERR" ]; then
    echo "OK   $f"
  else
    FAIL=$((FAIL+1))
    echo "FAIL $f"
    echo "$ERR" | head -5 | sed 's/^/     /'
  fi
done <<< "$FILES"

if [ "$FAIL" -eq 0 ]; then
  echo "::summary::$CHECKED 个 shell 文件语法通过"
  exit 0
fi
echo "::summary::$FAIL/$CHECKED 个 shell 文件语法错误"
exit 1
