# ci-simulation —— 用 Cloud Build 给 PR 加 CI 门禁的最小可运行样例
#
# 常用命令：
#   make help            看所有命令
#   make test            跑全部检查（Cloud Build 里跑的就是这一套）
#   make install-deps    安装 CI 依赖（helm 落到 .tools/bin）
#   make test-helm       helm lint + helm template
#   make test-python     python 单测（foundation apps + 集群 onboarding）
#   make test-bash       bash 断言
#   make clean           清理产物
#
# ★ 核心原则：**本地和 CI 跑的是同一条命令**（make test），
#   所以"本地过了 CI 挂"这种事基本不会发生，差异只剩环境。

SHELL := bash
PYTHON ?= python3
HELM_BIN_DIR := $(CURDIR)/.tools/bin
CHART_DIR ?= charts/ci-demo
RELEASE_NAME ?= argocd-bootstrap

ifeq ($(OS),Windows_NT)
export PATH := $(HELM_BIN_DIR);$(PATH)
else
export PATH := $(HELM_BIN_DIR):$(PATH)
endif

.DEFAULT_GOAL := help

.PHONY: help test ci install-deps prepare-foundation-apps test-helm test-python test-bash clean

help: ## 显示所有命令
	@echo "ci-simulation —— Cloud Build PR CI 最小样例"
	@echo ""
	@echo "  make test             跑全部检查（CI 用的就是这条）"
	@echo "  make test-helm        helm lint + helm template"
	@echo "  make test-python      python 单测"
	@echo "  make test-bash        bash 断言"
	@echo "  make install-deps     安装依赖（helm -> $(HELM_BIN_DIR)）"
	@echo "  make clean            清理产物"

test: test-helm test-python test-bash ## 跑全部检查
ci: test ## CI 的别名

install-deps: ## 安装 CI 依赖（幂等）
	@bash scripts/utils/install_ci_dependencies.sh

prepare-foundation-apps: ## 生成 foundation apps 清单
	$(PYTHON) scripts/utils/prepare_foundation_apps.py

test-helm: install-deps ## helm lint + template
	helm lint $(CHART_DIR) --strict
	helm template $(RELEASE_NAME) $(CHART_DIR) > /dev/null
	@echo "[test-helm] OK"

test-python: prepare-foundation-apps ## python 单测
	$(PYTHON) -m unittest discover -s scripts/utils -p 'test_*.py' -v
	$(PYTHON) -m unittest discover -s scripts/02-cluster-onboarding -p 'test_onboard_cluster.py' -v

test-bash: prepare-foundation-apps ## bash 断言
	bash scripts/utils/test_install_ci_dependencies.sh
	bash scripts/01-aoa-onboarding/test_checks.sh

clean: ## 清理产物
	rm -rf build .tools
