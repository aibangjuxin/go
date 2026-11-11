# daydayup —— 每天学一点 Go
#
# 常用命令：
#   make help        看所有命令
#   make list        看已经学了几天
#   make test        跑全部测试（彩色输出）
#   make watch       保存文件自动重跑测试（写练习时最常用）
#   make run DAY=d01 跑某一天的示例
#   make new         生成下一天（代码 + 文档 + 索引）
#   make fmt vet     格式化 / 静态检查
#
# 注意：每个 dNN/ 是独立的 package main，所以 `go run ./d01` 不会和 d02 冲突。

GO          ?= go
GOTESTSUM   ?= $(shell command -v gotestsum 2>/dev/null)
GOFMT       ?= gofmt
GOIMPORTS   ?= $(shell command -v goimports 2>/dev/null)

# 所有 dNN 目录
DAYS := $(sort $(notdir $(wildcard d[0-9][0-9])))

.DEFAULT_GOAL := help

.PHONY: help list test watch cover fmt vet lint run new clean

help: ## 显示所有命令
	@echo "daydayup —— 每天学一点 Go"
	@echo ""
	@echo "  make list            列出已有的天: $(DAYS)"
	@echo "  make test            跑全部测试"
	@echo "  make watch           保存文件自动重跑测试"
	@echo "  make cover           跑测试并生成覆盖率报告 cov.out"
	@echo "  make run DAY=d01     跑某一天的示例程序"
	@echo "  make new [主题]      生成下一天（代码+文档+索引）"
	@echo "  make fmt             格式化所有 go 文件"
	@echo "  make vet             go vet 静态检查"
	@echo "  make lint            golangci-lint 静态检查"
	@echo "  make clean           清理临时产物"

list: ## 列出已有的天
	@for d in $(DAYS); do \
		nn=$$(echo "$$d" | sed 's/^d//'); \
		doc=$$(ls md/$$nn-*.md 2>/dev/null | head -1); \
		if [ -n "$$doc" ]; then \
			printf "  %s  %-28s %s\n" "$$d" "$$doc" "($$(ls $$d/*.go 2>/dev/null | wc -l | tr -d ' ') 个 go 文件)"; \
		else \
			printf "  %s  %-28s %s\n" "$$d" "(还没写文档)" ""; \
		fi; \
	done

test: ## 跑全部测试
ifeq ($(GOTESTSUM),)
	@$(GO) test ./...
else
	@$(GOTESTSUM) --format testname -- ./...
endif

watch: ## 保存文件自动重跑测试
ifeq ($(GOTESTSUM),)
	@echo "⚠️  没装 gotestsum，用 go test（没有自动重跑）"
	@$(GO) test ./...
else
	@$(GOTESTSUM) --watch --format testname -- ./...
endif

cover: ## 跑测试 + 覆盖率报告
	@$(GO) test -coverprofile=cov.out ./...
	@$(GO) tool cover -func=cov.out | tail -1
	@echo "HTML 报告: go tool cover -html=cov.out"

run: ## 跑某一天的示例: make run DAY=d01
ifeq ($(DAY),)
	@echo "用法: make run DAY=d01   （可选: $(DAYS)）"
	@exit 1
endif
	@$(GO) run ./$(DAY)

fmt: ## 格式化
ifeq ($(GOIMPORTS),)
	@$(GOFMT) -w .
else
	@$(GOIMPORTS) -w .
endif

vet: ## go vet 静态检查
	@$(GO) vet ./...

lint: ## golangci-lint 静态检查
	@command -v golangci-lint >/dev/null 2>&1 || { echo "⚠️  没装 golangci-lint"; exit 1; }
	@golangci-lint run

new: ## 生成下一天: make new slices   或   make new TOPIC="slice 与 append"
	@topic="$(TOPIC)"; \
	if [ -z "$$topic" ]; then \
		for g in $(MAKECMDGOALS); do \
			case "$$g" in new|-*) ;; *) topic="$$g";; esac; \
		done; \
	fi; \
	./scripts/newday.sh "$$topic"

clean: ## 清理临时产物
	@rm -f cov.out
	@rm -rf tmp bin

# `make new slices` 这种写法：把多出来的目标吞掉（主题由 new 目标从 MAKECMDGOALS 里取）
%:
	@if [ "$(words $(MAKECMDGOALS))" -gt 1 ] && echo "$(MAKECMDGOALS)" | grep -qw "$(firstword $(MAKECMDGOALS))"; then \
		exit 0; \
	else \
		echo "✗ 未知目标: $@"; \
		echo "  跑 'make help' 看可用命令"; \
		exit 1; \
	fi
