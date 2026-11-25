#!/usr/bin/env bash
# AOA（Argo CD onboarding）阶段的一组 bash 断言。
# 目的：演示"bash 步骤失败 → CI 变红"是怎么发生的。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT_DIR}"

TOOLS_BIN_DIR="${TOOLS_BIN_DIR:-${ROOT_DIR}/.tools/bin}"
export PATH="${TOOLS_BIN_DIR}:${PATH}"

APPS_OUT="${ROOT_DIR}/build/foundation-apps.json"
CLUSTER_SPEC="${ROOT_DIR}/cluster/cluster-spec.json"
CHART_DIR="${ROOT_DIR}/charts/ci-demo"

fail() { printf '[test_checks] FAIL: %s\n' "$*" >&2; exit 1; }
ok()   { printf '[test_checks] OK: %s\n' "$*"; }

# 1) foundation apps 产物必须存在（由 make prepare-foundation-apps 生成）
[ -f "${APPS_OUT}" ] || fail "缺少 ${APPS_OUT}，先跑 make prepare-foundation-apps"
ok "foundation apps 产物存在"

# 2) 必须包含关键 app
grep -q '"platform-metrics"' "${APPS_OUT}" || fail "foundation apps 里没有 platform-metrics"
ok "platform-metrics 在清单里"

# 3) 被禁用的 app 不该出现在产物里
if grep -q '"legacy-dashboard"' "${APPS_OUT}"; then
  fail "legacy-dashboard 已禁用，却出现在产物里"
fi
ok "禁用的 app 已被排除"

# 4) 集群规格必须有 argocd 的 secret-type 标签
[ -f "${CLUSTER_SPEC}" ] || fail "缺少 ${CLUSTER_SPEC}"
grep -q 'argocd.argoproj.io/secret-type' "${CLUSTER_SPEC}" || fail "集群规格缺少 argocd secret-type 标签"
ok "集群规格标签正确"

# 5) chart 必须能渲染出 ConfigMap（和 make test-helm 呼应，但这里再独立校验一次）
command -v helm >/dev/null 2>&1 || fail "PATH 里没有 helm"
RENDERED="$(helm template argocd-bootstrap "${CHART_DIR}")" || fail "helm template 失败"
echo "${RENDERED}" | grep -q 'kind: ConfigMap' || fail "渲染结果里没有 ConfigMap"
ok "chart 渲染出 ConfigMap"

printf '[test_checks] 全部断言通过\n'
