# Go 学习笔记

基于 `/Users/lex/git/go/cr-check` 这个真实项目整理的 Go 核心概念速查。

## 入口

👉 **[00-index.md](00-index.md)** —— 学习地图、项目结构、Go vs Java 速查

## 文档列表

| # | 文档 | 主题 |
|---|---|---|
| 00 | [00-index.md](00-index.md) | 学习地图 · 项目结构 · 工具链 |
| 01 | [01-struct.md](01-struct.md) | Struct（结构体） |
| 02 | [02-method.md](02-method.md) | Method（方法）· 值接收者 vs 指针接收者 |
| 03 | [03-interface.md](03-interface.md) | Interface（接口）· 隐式实现 · 鸭子类型 |
| 04 | [04-constructor.md](04-constructor.md) | Constructor（构造函数模式 `NewXxx`） |
| 05 | [05-dependency-injection.md](05-dependency-injection.md) | Dependency Injection（依赖注入） |
| 06 | [06-factory.md](06-factory.md) | Factory Pattern（工厂模式） |
| 07 | [07-context.md](07-context.md) | Context（上下文与生命周期管理） |
| 08 | [08-goroutine-channel.md](08-goroutine-channel.md) | Goroutine 与 Channel（并发原语 · worker pool） |
| 09 | [09-sync.md](09-sync.md) | sync 包（Mutex · WaitGroup · atomic · race detector） |
| 10 | [10-error.md](10-error.md) | 错误处理（error 包装 · errors.Is/As · fail-closed） |
| 11 | [11-http.md](11-http.md) | net/http（路由 · 中间件 · 超时 · 优雅关闭） |
| 12 | [12-json.md](12-json.md) | encoding/json（struct tag · omitempty · 模型解耦） |
| 13 | [13-testing.md](13-testing.md) | testing（表驱动 · httptest · fake · -race） |
| 14 | [14-time.md](14-time.md) | time 包（Duration · 时区 · 维护窗口 · Ticker） |
| 15 | [15-defer-panic-recover.md](15-defer-panic-recover.md) | defer / panic / recover（资源释放 · 崩溃处理） |
| 16 | [16-slice-map-stdlib.md](16-slice-map-stdlib.md) | Slice / Map 与常用标准库 |
| 17 | [17-modules-build.md](17-modules-build.md) | 依赖管理 · 构建 · 发布（Makefile · Dockerfile） |
| 18 | [18-logging-slog.md](18-logging-slog.md) | log/slog（结构化日志 · 级别 · 审计日志） |
| — | [newclient.md](newclient.md) | NewClient 通用介绍（先读这篇） |

## 工程实践

| 文档 | 主题 |
|---|---|
| [practice/01-local-debug.md](practice/01-local-debug.md) | **本地调试** —— 不反复编译地改代码（make run / Air / dlv / mock 复现 case） |
| [practice/02-config-and-deploy.md](practice/02-config-and-deploy.md) | **配置与部署** —— 变量放 YAML 还是环境变量 · GKE 部署 · 哪些不该写死 |
| [practice/03-go-toolchain.md](practice/03-go-toolchain.md) | **测试与调试工具链** —— air / gotestsum / dlv / golangci-lint 装法与用法 |

## 快速上手

```bash
cd /Users/lex/git/go/cr-check

make run     # mock 模式起服务（:8081）
make test    # 跑测试（-race -cover）
make vet     # 静态检查
```

**调试时最常用的一条命令**（不用改任何代码就能复现一个 case）：

```bash
go run ./cmd/server -config config/policy.yaml -mode mock -sync-eval \
    -now "2025-01-06T03:00:00+08:00" -addr :8081
#  ↑ -now 固定"当前时间"，用来验证维护窗口规则
```

```bash
curl -s -X POST http://localhost:8081/github/webhook \
  -H 'X-GitHub-Event: pull_request' \
  -H 'X-GitHub-Delivery: demo-1' \
  -H 'Content-Type: application/json' \
  --data @testdata/pr-event.json | jq
```
