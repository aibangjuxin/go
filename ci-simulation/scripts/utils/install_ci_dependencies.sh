#!/usr/bin/env bash
# 幂等安装 CI 依赖（helm 落到 .tools/<os>-<arch>/bin，跨 step 共享）。
#
# 设计要点（每一条都是被 Cloud Build 的真实行为 + 容器实测逼出来的）：
#   1. step 之间**只有 /workspace 共享**：
#      apt-get 装进系统目录的 make，下一个 step（全新容器）就没了
#      → 所以 helm 必须装进 .tools；apt 装出来的 make 也要复制一份进去兜底
#   2. builder 镜像用 python:3.11（full）：自带 make / curl / python3 / git / tar
#      —— ubuntu:22.04 一个都没有，跑起来要 apt-get 装一堆东西
#   3. curl 只在"要下载 helm"时才需要，不该在后续 step 里强制要求
#   4. 工具目录**按平台分目录**（.tools/linux-x86_64/bin、.tools/darwin-arm64/bin）：
#      否则本地 mac 装出来的 helm 会被容器里的 linux step 当成 linux 版用，直接炸
#   5. 只往仓库内的 .tools 装东西，不污染系统；幂等，重复跑不重复下载
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

detect_os() {
  case "$(uname -s)" in
    Linux)  echo linux ;;
    Darwin) echo darwin ;;
    *) echo "$(uname -s | tr '[:upper:]' '[:lower:]')" ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo x86_64 ;;
    arm64|aarch64) echo arm64 ;;
    *) echo "$(uname -m)" ;;
  esac
}

TOOLS_BIN_DIR="${TOOLS_BIN_DIR:-${ROOT_DIR}/.tools/$(detect_os)-$(detect_arch)/bin}"
HELM_VERSION="${HELM_VERSION:-v3.15.4}"

mkdir -p "${TOOLS_BIN_DIR}"

log() { printf '[install_ci_dependencies] %s\n' "$*"; }

can_use_apt() {
  [ "$(id -u)" = "0" ] || return 1
  command -v apt-get >/dev/null 2>&1 || return 1
  return 0
}

apt_install() {
  log "apt-get 安装: $*"
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends "$@"
}

# make：镜像自带就直接用（不复制，避免把容器二进制带进本地目录）；
#      apt 装出来的要复制一份到 .tools，否则下一个 step（全新容器）就没了
ensure_make() {
  if command -v make >/dev/null 2>&1; then
    log "make: $(make --version | head -1)"
    return 0
  fi
  if can_use_apt; then
    apt_install make
  else
    log "缺少 make：请换一个自带 make 的 builder 镜像（例如 python:3.11）"
    return 1
  fi
  install -m 0755 "$(command -v make)" "${TOOLS_BIN_DIR}/make"
  log "make 已复制到 ${TOOLS_BIN_DIR}/make（供后续 step 使用）"
}

ensure_python() {
  if command -v python3 >/dev/null 2>&1; then
    log "python3: $(python3 --version 2>&1)"
    return 0
  fi
  if can_use_apt; then
    apt_install python3
    log "python3 安装完成：$(python3 --version 2>&1)"
    return 0
  fi
  log "缺少 python3：请换一个自带 python 的 builder 镜像（例如 python:3.11）"
  return 1
}

ensure_helm() {
  if [ -x "${TOOLS_BIN_DIR}/helm" ]; then
    log "helm 已在工具目录：$(${TOOLS_BIN_DIR}/helm version --short 2>/dev/null || echo unknown)"
    return 0
  fi
  if command -v helm >/dev/null 2>&1; then
    log "复用系统 helm：$(command -v helm)"
    install -m 0755 "$(command -v helm)" "${TOOLS_BIN_DIR}/helm"
    return 0
  fi

  # 只有真的要下载 helm 时才需要 curl
  if ! command -v curl >/dev/null 2>&1; then
    if can_use_apt; then
      apt_install curl ca-certificates
    else
      log "缺少 curl，且无法自动安装：请换一个自带 curl 的 builder 镜像（例如 python:3.11）"
      return 1
    fi
  fi

  local os arch tmp
  os="$(detect_os)"
  case "$(uname -m)" in
    x86_64|amd64)  arch=amd64 ;;
    arm64|aarch64) arch=arm64 ;;
    *) log "不支持的架构：$(uname -m)"; return 1 ;;
  esac

  tmp="$(mktemp -d)"
  log "下载 helm ${HELM_VERSION} (${os}/${arch}) ..."
  curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-${os}-${arch}.tar.gz" -o "${tmp}/helm.tgz"
  tar -xzf "${tmp}/helm.tgz" -C "${tmp}"
  install -m 0755 "${tmp}/${os}-${arch}/helm" "${TOOLS_BIN_DIR}/helm"
  rm -rf "${tmp}"
  log "helm 安装完成：$(${TOOLS_BIN_DIR}/helm version --short)"
}

ensure_make
ensure_python
ensure_helm

log "依赖就绪。后续 step 请带上：export PATH=${TOOLS_BIN_DIR}:${PATH}"
