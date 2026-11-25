#!/usr/bin/env bash
# 校验"CI 依赖安装"这一步的结果。
# 注意：脚本里刻意用绝对判断，任何一条不满足就 exit 1 —— CI 必须真的能红。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOLS_BIN_DIR="${TOOLS_BIN_DIR:-${ROOT_DIR}/.tools/bin}"
export PATH="${TOOLS_BIN_DIR}:${PATH}"

fail() { printf '[test_install_ci_dependencies] FAIL: %s\n' "$*" >&2; exit 1; }
ok()   { printf '[test_install_ci_dependencies] OK: %s\n' "$*"; }

command -v python3 >/dev/null 2>&1 || fail "python3 不存在"
ok "python3 $(python3 --version 2>&1)"

command -v make >/dev/null 2>&1 || fail "make 不存在（PATH 里没有 ${TOOLS_BIN_DIR}/make）"
ok "make $(make --version | head -1)"

if [ -x "${TOOLS_BIN_DIR}/helm" ]; then
  HELM_BIN="${TOOLS_BIN_DIR}/helm"
else
  HELM_BIN="$(command -v helm || true)"
fi
[ -n "${HELM_BIN}" ] || fail "既没有 ${TOOLS_BIN_DIR}/helm，也没有 PATH 里的 helm"

HELM_VERSION_OUT="$("${HELM_BIN}" version --short 2>&1)" || fail "helm version 执行失败：${HELM_VERSION_OUT}"
ok "helm ${HELM_VERSION_OUT}"
