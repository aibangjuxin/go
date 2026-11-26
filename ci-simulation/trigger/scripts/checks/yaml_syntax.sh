#!/usr/bin/env bash
# 检查项：YAML 语法校验
#  * 只看本次 PR 改动的 *.yaml / *.yml
#  * 跳过 Helm 模板目录（templates/ 里的不是合法 YAML）
#  * 解析器优先级：python3+pyyaml → ruby -ryaml → 都没有就明确失败
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib_changed.sh"

FILES="$(filter_ext '\.ya?ml$' | exclude_helm_templates | sort -u)"
COUNT="$(printf '%s\n' "$FILES" | grep -c . || true)"
if [ "$COUNT" = "0" ]; then
  echo "::summary::本次没有 YAML 改动"
  exit 77
fi
echo "::files::$COUNT"

PARSER=""
if python3 -c 'import yaml' >/dev/null 2>&1; then
  PARSER=python
elif command -v ruby >/dev/null 2>&1 && ruby -ryaml -e 'exit 0' >/dev/null 2>&1; then
  PARSER=ruby
else
  echo "::summary::环境里没有 YAML 解析器（pyyaml / ruby）"
  echo "缺依赖：install_deps.sh 负责装 pyyaml"
  exit 1
fi

FAIL=0
CHECKED=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$f" ] || continue
  CHECKED=$((CHECKED+1))
  if [ "$PARSER" = "python" ]; then
    ERR="$(python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1], encoding="utf-8"))' "$f" 2>&1)"
  else
    ERR="$(ruby -ryaml -e 'YAML.parse_file(ARGV[0])' "$f" 2>&1)"
  fi
  if [ -z "$ERR" ]; then
    echo "OK   $f"
  else
    FAIL=$((FAIL+1))
    echo "FAIL $f"
    echo "$ERR" | head -5 | sed 's/^/     /'
  fi
done <<< "$FILES"

if [ "$FAIL" -eq 0 ]; then
  echo "::summary::$CHECKED 个 YAML 文件语法通过"
  exit 0
fi
echo "::summary::$FAIL/$CHECKED 个 YAML 文件语法错误"
exit 1
