# CR Check —— 开发常用命令
APP      := cr-check
PKG      := ./...
CONFIG   ?= config/policy.yaml
ADDR     ?= :8081
LDFLAGS  := -s -w

.PHONY: help run run-real show-config build test test-watch air probe event lint fmt vet tidy clean docker

help: ## 显示可用命令
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

run: ## 本地起服务（mock 模式，同步判定，curl 立刻能看到结论）
	go run ./cmd/server -config $(CONFIG) -mode mock -addr $(ADDR) -sync-eval

run-real: ## 按真实凭据起服务（异步判定）
	go run ./cmd/server -config $(CONFIG) -mode real -addr $(ADDR)

show-config: ## 打印生效配置（脱敏）
	go run ./cmd/server -config $(CONFIG) -show-config

probe: ## 打一发 webhook（用 testdata/pr-event.json）
	@# ★ 用 $(CURDIR) 拼绝对路径：否则在仓库父目录执行会报
	@#   curl: option --data: error encountered when reading a file
	curl -s -X POST http://localhost$(ADDR)/github/webhook \
	  -H 'X-GitHub-Event: pull_request' \
	  -H "X-GitHub-Delivery: demo-$$(date +%s%N)" \
	  -H 'Content-Type: application/json' \
	  --data-binary "@$(CURDIR)/testdata/pr-event.json" | jq

event: ## 发测试事件（可指定 CR 号）：make event CR=5678
	ADDR=http://localhost$(ADDR) ./scripts/send-test-event.sh $(or $(CR),1234)

build: ## 编译到 bin/
	CGO_ENABLED=0 go build -trimpath -ldflags '$(LDFLAGS)' -o bin/$(APP) ./cmd/server

air: ## live reload：改代码自动编译并重启服务（air v1.67）
	air

test-watch: ## live reload：每次保存自动跑测试
	air -c .air.test.toml

test: ## 跑测试
	go test -race -cover ./...
	# 想要彩色输出：gotestsum --format testname --raw-command -- go test -race -json ./...

vet: ## 官方静态检查
	go vet ./...

lint: ## golangci-lint
	golangci-lint run ./...

fmt: ## 格式化 + 整理 import
	gofmt -w .
	goimports -w .

tidy: ## 清理依赖
	go mod tidy

clean: ## 清理
	rm -rf bin
	go clean -testcache

docker: ## 构建镜像
	docker build -t $(APP):dev .
