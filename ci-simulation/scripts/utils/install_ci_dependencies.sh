#!/usr/bin/env bash
# 幂等安装 CI 依赖。
#
# 设计要点：
#   · 只往仓库内的 .tools/bin 装东西，不污染系统，也不要求 root（除非装 make）
#   · 幂等：重复跑不会重复下载
#   · 跨环境：本地 macOS / Cloud Build 的 ubuntu 容器都能跑
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELM_BIN_DIR="${HELM_BIN_DIR:-${ROOT_DIR}/.tools/bin}"
HELM_VERSION="${HELM_VERSION:-v3.15.4}"

mkdir -p "${HELM_BIN_DIR}"

log() { printf '[install_ci_dependencies] %s\n' "$*"; }

ensure_make() {
  if command -v make >/dev/null 2>&1; then
    log "make: $(make --version | head -1)"
    return 0
  fi
  if command -v apt-get >/dev/null 2>&1 && [ "$(id -u)" = "0" ]; then
    log "make 不存在，用 apt-get 安装 ..."
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends make
    log "make 安装完成：$(make --version | head -1)"
    return 0
  fi
  log "缺少 make，且当前环境无法自动安装（需要 root + apt-get）"
  return 1
}

ensure_helm() {
  if [ -x "${HELM_BIN_DIR}/helm" ]; then
    log "helm 已在本地工具目录：$(${HELM_BIN_DIR}/helm version --short 2>/dev/null || echo unknown)"
    return 0
  fi

  if command -v helm >/dev/null 2>&1; then
    log "复用系统 helm：$(command -v helm)"
    ln -sf "$(command -v helm)" "${HELM_BIN_DIR}/helm"
    return 0
  fi

  local os arch tmp
  case "$(uname -s)" in
    Linux)  os=linux ;;
    Darwin) os=darwin ;;
    *) log "不支持的操作系统：$(uname -s)"; return 1 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)  arch=amd64 ;;
    arm64|aarch64) arch=arm64 ;;
    *) log "不支持的架构：$(uname -m)"; return 1 ;;
  esac

  tmp="$(mktemp -d)"
  log "下载 helm ${HELM_VERSION} (${os}/${arch}) ..."
  curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-${os}-${arch}.tar.gz" -o "${tmp}/helm.tgz"
  tar -xzf "${tmp}/helm.tgz" -C "${tmp}"
  install -m 0755 "${tmp}/${os}-${arch}/helm" "${HELM_BIN_DIR}/helm"
  rm -rf "${tmp}"
  log "helm 安装完成：$(${HELM_BIN_DIR}/helm version --short)"
}

ensure_python() {
  if command -v python3 >/dev/null 2>&1; then
    log "python3: $(python3 --version 2>&1)"
    return 0
  fi
  log "缺少 python3"
  return 1
}

ensure_make
ensure_helm
ensure_python

log "依赖就绪。把这一行加进 PATH 即可：export PATH=${HELM_BIN_DIR}:${PATH}"
