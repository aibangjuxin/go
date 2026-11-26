#!/usr/bin/env bash
# 公共函数：算出“本次 PR 改动了哪些文件”。
#
# ★ 为什么做增量：
#   全仓库扫描会让历史遗留错误永远红，久而久之大家就学会无视这条检查
#   —— 这是 CI 最常见的死法。历史问题要单独开 PR 修。
#
# 环境变量：
#   BASE_BRANCH  PR 的目标分支（Cloud Build 里是 $_BASE_BRANCH），默认 main
#   FULL_SCAN=1 强制全量扫描（排查用）
changed_files() {
  local base="${BASE_BRANCH:-main}"
  if [ "${FULL_SCAN:-0}" = "1" ]; then
    git ls-files
    return 0
  fi
  local out
  out="$(git diff --name-only --diff-filter=ACMR "origin/${base}...HEAD" 2>/dev/null || true)"
  if [ -z "$out" ]; then
    # 退化：拿不到 base（比如浅克隆）→ 全量扫描，宁可多查也不要静默跳过
    out="$(git ls-files 2>/dev/null || true)"
  fi
  printf '%s\n' "$out"
}

# 过滤出匹配正则的文件（入参是完整正则，例如 '\.ya?ml$'）
filter_ext() {
  local re="$1"
  changed_files | grep -E "$re" || true
}

# 过滤掉 Helm 模板目录（模板不是合法 YAML，必须交给 helm 校验）
exclude_helm_templates() {
  grep -v '/templates/' || true
}
