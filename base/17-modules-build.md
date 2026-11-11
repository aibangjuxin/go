# 17 · 依赖管理、构建与发布

> 一句话：**Go 的依赖管理是"声明式"的（go.mod），构建是"一条命令"的（Makefile + Dockerfile）。**
> cr-check 的 `go.mod` / `Makefile` / `Dockerfile` 已经是标准写法，本文逐行拆解。

---

## 1. go.mod：依赖声明

```go
module github.com/acme/cr-check

go 1.27.3

require (
    github.com/bradleyfalzon/ghinstallation/v2 v2.19.0
    github.com/google/go-github/v88 v88.0.0
    github.com/prometheus/client_golang v1.25.0
    github.com/redis/go-redis/v9 v9.23.0
    sigs.k8s.io/yaml v1.6.0
)

require (
    github.com/beorn7/perks v1.0.1 // indirect
    ...
)
```

| 字段 | 含义 |
|---|---|
| `module` | 模块路径 = 导入路径前缀 |
| `go` | 最低 Go 版本（决定语言特性可用性） |
| `require` | 依赖声明 |
| `// indirect` | 间接依赖（不是你直接 import 的） |

### ★ 常用命令

```bash
go mod tidy        # ★ 添加/清理依赖（最常用）
go mod download    # 下载依赖
go mod verify     # 校验依赖未被篡改
go mod graph      # 看依赖树
go mod why <pkg>   # 为什么依赖它
```

> ★ **`go mod tidy` 必须在每次改完 import 后跑**，
> 否则 CI 会因为 `go.mod` 不一致而失败。
> cr-check 的 Makefile 就有这个目标：
> ```makefile
> tidy: ## 清理依赖
> 	go mod tidy
> ```

### ★ go.sum：校验和

`go.sum` 记录每个依赖的哈希，**必须提交进 Git**。
作用：防止依赖被篡改（供应链安全）。

### ★ 语义化版本 + `v2` 后缀

```go
github.com/google/go-github/v88 v88.0.0
```

Go 的规则：**v2 及以上必须在模块路径里带 `/vN`**。
这是为了避免和 v1 产生 import 路径冲突。

### ★ 依赖选型

cr-check 的依赖列表很短，这是好事：

| 依赖 | 用途 | 能不能自己写 |
|---|---|---|
| `go-github/v88` | GitHub API | ❌ 太大 |
| `ghinstallation/v2` | GitHub App JWT + token 续期 | ❌ 加密细节多 |
| `client_golang` | Prometheus 指标 | ❌ 生态标准 |
| `go-redis/v9` | Redis 客户端 | ❌ 协议细节多 |
| `sigs.k8s.io/yaml` | YAML 解析 | ❌ 但注意：**它用 JSON 的 tag 规则** |

> ★ **`sigs.k8s.io/yaml` 的坑**：
> 它把 YAML 转成 JSON 再用 `encoding/json` 解析，
> **所以 struct tag 用的是 `json:"xxx"` 而不是 `yaml:"xxx"`**！
> 这就是 cr-check 的配置结构体里全是 `json:"..."` tag 的原因：
> ```go
> type Config struct {
>     CheckName string `json:"checkName"`
> }
> ```
> 这也是为什么 YAML 里的 key 必须是**小驼峰**（`checkName` 而不是 `check_name`）。
>
> **实测验证**（v1.6.0）：
> ```go
> type C struct {
>     Other string `json:"otherName" yaml:"otherYaml"`
>     Third string `yaml:"thirdYaml"`
> }
> yaml.Unmarshal([]byte("otherYaml: B\nthirdYaml: C\n"), &c)
> // → {Other: Third:}  ← 两个都是空！
> ```
> `yaml` tag 被**完全忽略**，而且不报错 —— 改错 tag 是静默失效。
> （唯一能歪打正着的是"字段名大小写不敏感匹配"，别依赖它。）

### ★ 少依赖的收益

Go 的编译是**整包编译**，依赖树越大编译越慢。
标准库能做的就别引第三方：

| 想做的事 | 标准库方案 |
|---|---|
| YAML 解析 | `sigs.k8s.io/yaml`（或 `gopkg.in/yaml.v3`） |
| 路由 | Go 1.22+ `net/http` ServeMux |
| 日志 | Go 1.21+ `log/slog` |
| 重试 | 手写（几行） |
| 定时任务 | `time.Ticker` |

---

## 2. Makefile：把命令固化

cr-check 的 Makefile：

```makefile
APP      := cr-check
PKG      := ./...
CONFIG   ?= config/policy.yaml
ADDR     ?= :8081
LDFLAGS  := -s -w

.PHONY: help run build test lint fmt vet tidy clean docker

help: ## 显示可用命令
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

run: ## 本地起服务（mock 模式，同步判定，curl 立刻能看到结论）
	go run ./cmd/server -config $(CONFIG) -mode mock -addr $(ADDR) -sync-eval

build: ## 编译到 bin/
	CGO_ENABLED=0 go build -trimpath -ldflags '$(LDFLAGS)' -o bin/$(APP) ./cmd/server

test: ## 跑测试
	go test -race -cover ./...

vet: ## 官方静态检查
	go vet ./...

lint: ## golangci-lint
	golangci-lint run ./...

fmt: ## 格式化 + 整理 import
	gofmt -w .
	goimports -w .

tidy: ## 清理依赖
	go mod tidy
```

### ★ Makefile 的关键语法

| 语法 | 含义 | 例 |
|---|---|---|
| `:=` | 立即赋值（递归展开） | `LDFLAGS := -s -w` |
| `?=` | **未定义时才赋值**（可被外部覆盖） | `CONFIG ?= config/policy.yaml` |
| `+=` | 追加 | |
| `.PHONY` | 声明目标是伪目标（不生成同名文件） | |

> ★ **`?=` 的意义**：
> ```bash
> make run CONFIG=/tmp/my-policy.yaml ADDR=:9090
> ```
> 不用改 Makefile 就能换配置 —— 这正是"不要写死"的一种体现。

> ★ **`.PHONY` 必须写**：
> 目录里有个叫 `test` 的文件，`make test` 就会跳过执行。

### ★ 常用构建 flag

| flag | 作用 | cr-check |
|---|---|---|
| `CGO_ENABLED=0` | 纯静态二进制（scratch/distroless 镜像必需） | ✅ |
| `-trimpath` | 去掉构建机器的绝对路径（可复现构建 + 不泄露路径） | ✅ |
| `-ldflags '-s -w'` | 去符号表 + 去 DWARF，**二进制小 30%+** | ✅ |
| `-o` | 输出路径 | `bin/cr-check` |

> ★ **`-trimpath` 的额外价值**：编译错误信息里的路径不会暴露你的本机目录。

---

## 3. Dockerfile：多阶段构建

cr-check 的 Dockerfile：

```dockerfile
# ---- build ----
FROM golang:1.27-alpine AS build
WORKDIR /src

# 先只拷依赖描述文件 → 依赖层可复用缓存
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags '-s -w' -o /out/cr-check ./cmd/server

# ---- runtime ----
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/cr-check /cr-check
EXPOSE 8081
USER nonroot:nonroot
ENTRYPOINT ["/cr-check"]
CMD ["-config", "/etc/cr-check/policy.yaml", "-mode", "real", "-addr", ":8081"]
```

### ★ 逐行拆解

**① 多阶段：编译环境不进最终镜像**

最终镜像只有**一个静态二进制**（几 MB），
不带 Go 工具链、不带 alpine 的包管理器。

**② 依赖层缓存**

```dockerfile
COPY go.mod go.sum ./     # ★ 先只拷依赖描述
RUN go mod download       # ★ 这一层只在依赖变化时重建
COPY . .                 # 源码变化只影响最后一层
```

> ★ **顺序反了的话，每次改一行代码都要重新下载全部依赖** —— CI 会慢到无法忍受。

**③ `distroless` + `nonroot`**

- `gcr.io/distroless/static` = **没有 shell、没有包管理器、没有 libc**（只要静态二进制）
- `USER nonroot:nonroot` = **不用 root 跑**

> ★ distroless 镜像**没有 shell**，所以 `kubectl exec` 进去没法执行命令。
> 这是"安全 vs 运维便利"的权衡 —— 生产环境推荐 distroless，
> 排查问题用 `kubectl debug` 起一个临时带 shell 的容器。

**④ `ENTRYPOINT` 用 exec 形式（数组）**

```dockerfile
ENTRYPOINT ["/cr-check"]       # ✅ exec 形式：二进制是 PID 1，能收到信号
CMD ["-config", "..."]          # ✅ CMD 是数组
```

> ★ **★ 千万别写成 shell 形式**：
> ```dockerfile
> ENTRYPOINT /cr-check          # ❌
> ```
> shell 形式会通过 `/bin/sh -c` 启动，**shell 变成 PID 1，不会转发 SIGTERM**！
> 结果：k8s 发 SIGTERM → 进程收不到 → 等 30 秒宽限期后被 SIGKILL。
> cr-check 的优雅关闭（`signal.NotifyContext` + `srv.Shutdown`）就完全失效了。
>
> **这是 Go 服务上 k8s 最经典的坑之一。**

**⑤ `GOOS=linux`** —— macOS 上构建 linux 镜像时需要（cross-compile）。

### ★ .dockerignore

```dockerfile
# .dockerignore
.git
bin/
*.zip
testdata/
```

> ★ 不写 `.dockerignore` 的话，`COPY . .` 会把整个目录（包括 `.git`、
> 那些 60MB 的 zip 文件）塞进构建上下文 → 构建变慢、镜像层巨大。
> cr-check 仓库根目录有 63MB 的 `go-plugin-*.zip`，**这个必须有 .dockerignore**。

---

## 4. 交叉编译

Go 是编译成静态机器码的，**一套代码能编译到所有平台**：

```bash
# macOS (arm64)
GOOS=darwin GOARCH=arm64 go build -o bin/cr-check-darwin-arm64 ./cmd/server

# Linux (amd64) —— GKE 节点通常是 amd64
GOOS=linux GOARCH=amd64 go build -o bin/cr-check-linux-amd64 ./cmd/server

# Linux (arm64) —— Graviton 节点
GOOS=linux GOARCH=arm64 go build -o bin/cr-check-linux-arm64 ./cmd/server

# Windows
GOOS=windows GOARCH=amd64 go build -o bin/cr-check.exe ./cmd/server
```

### ★ GKE 的架构问题

**★ 这是 GKE 部署的常见坑**：
如果 GKE 节点池是 `amd64`，但你本地（Apple Silicon）编译了 `arm64` 的二进制 → **启动即失败**。

**检查节点架构**：

```bash
gcloud container node-pools describe <pool> --cluster <cluster> --zone <zone>
```

或者在 Pod 里看：

```bash
kubectl exec -it <pod> -- uname -m
```

> ★ **最省心的做法**：
> **在 CI 里用 `docker build` 构建镜像**（Dockerfile 里 `GOOS=linux`），
> 让基础镜像 `golang:1.27-alpine` 决定架构，**永远和节点池架构一致**。
> **不要在本地交叉编译后手动上传二进制。**

---

## 5. ★ 版本信息注入（ldflags）

```go
var (
    Version   = "dev"
    Commit    = "none"
    BuildTime = "unknown"
)
```

```makefile
VERSION    := $(shell git describe --tags --always --dirty)
COMMIT     := $(shell git rev-parse --short HEAD)
BUILD_TIME := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
LDFLAGS    := -s -w \
	-X main.Version=$(VERSION) \
	-X main.Commit=$(COMMIT) \
	-X main.BuildTime=$(BUILD_TIME)
```

```bash
go build -ldflags "$(LDFLAGS)" -o bin/cr-check ./cmd/server
```

然后在 `/healthz` 或 `/version` 里返回这些信息：

```go
mux.HandleFunc("GET /version", func(w http.ResponseWriter, r *http.Request) {
    webhook.WriteJSON(w, http.StatusOK, map[string]any{
        "version": Version, "commit": Commit, "build_time": BuildTime,
    })
})
```

> ★ **强烈建议加 `/version` 端点**：
> 排查线上问题时，第一句话就是"你跑的是哪个版本？"
> 没有版本信息的二进制，排查会痛苦十倍。

### ★ `-s -w` 的取舍

| | 效果 |
|---|---|
| `-s` | 去符号表（DWARF） |
| `-w` | 去 DWARF 调试信息 |

**代价**：Go 的 **pprof 性能剖析会失效**（需要符号表）。
如果生产环境要用 pprof，就**不要**加 `-w`（或另外保留一份带符号的二进制）。

---

## 6. ★ 静态检查工具链

| 工具 | 作用 | 怎么用 |
|---|---|---|
| `go vet` | 官方静态检查（printf、copylocks 等） | `go vet ./...` |
| `gofmt` | 格式化 | `gofmt -w .` |
| `goimports` | 格式化 + 整理 import 分组 | `goimports -w .` |
| `golangci-lint` | 社区 lint 集合（可配置） | `golangci-lint run ./...` |
| `staticcheck` | SA 系列静态分析 | 包含在 golangci-lint 里 |
| `govulncheck` | **漏洞扫描** | `govulncheck ./...` |

> ★ **CI 必跑的四条**：
> ```bash
> gofmt -l . | tee /dev/stderr | wc -l   # 格式检查（0 才通过）
> go vet ./...
> go test -race -cover ./...
> golangci-lint run ./...
> ```
> cr-check 的 Makefile 已经把它们都固化了。

### ★ golangci-lint 常用 linter

| linter | 查什么 |
|---|---|
| `errcheck` | 未检查的 error（★ 最容易漏） |
| `govet` | 官方检查 |
| `staticcheck` | 各种 bug 模式 |
| `unused` | 未使用的代码 |
| `gosec` | 安全问题（如硬编码密码、弱随机） |
| `ineffassign` | 无效赋值 |
| `bodyclose` | HTTP response body 没关 |

> ★ **建议的 `.golangci.yml`**：
> ```yaml
> linters:
>   enable:
>     - errcheck
>     - gosec
>     - staticcheck
>     - ineffassign
>     - bodyclose
>     - noctx        # HTTP 请求没用 NewRequestWithContext
> linters-settings:
>   errcheck:
>     check-type-assertions: true
> ```

---

## 7. go:embed：把文件嵌进二进制

```go
//go:embed policy.yaml
var policyYAML string

//go:embed templates/*.tmpl
var templates embed.FS
```

**用途**：
- 单二进制交付（配置/模板/静态资源跟着二进制走）
- k8s 里用 ConfigMap 挂载也行，但**嵌进二进制能保证版本一致**
  （ConfigMap 可能被改，代码不会）

> ★ **cr-check 目前用文件挂载**（`/etc/cr-check/policy.yaml`）。
> 这也合理 —— 因为策略**要能不重新发版就改**。
> **取舍很清楚**：
> - 策略要热改 → 挂载文件
> - 静态资源不变 → embed

---

## 8. 一页速查

```bash
go mod tidy                    # 整理依赖
go build ./...                 # 编译全部
go build -trimpath -ldflags '-s -w' -o bin/app ./cmd/server
go test -race -cover ./...
go vet ./...
gofmt -w . && goimports -w .
golangci-lint run ./...
go run ./cmd/server -config config/policy.yaml -mode mock
```

---

## 9. 一句话总结

> **Go 的工程化 = go.mod 声明依赖 + Makefile 固化命令 + 多阶段 Dockerfile 交付。**
> - `go mod tidy` 每次改 import 都要跑
> - `sigs.k8s.io/yaml` 用 **JSON 的 tag 规则**
> - Makefile 用 `?=` 让外部能覆盖，`-trimpath -ldflags '-s -w'` 是标配
> - **Dockerfile 必须多阶段 + distroless + nonroot**
> - **`ENTRYPOINT` 必须 exec 形式**（否则收不到 SIGTERM）
> - **`.dockerignore` 必写**（否则大文件进构建上下文）
> - **在 CI 里构建镜像，别在本地交叉编译**（架构不一致会启动失败）
> - 加 `/version` 端点注入版本信息

---

## 10. 自测题

1. 为什么 cr-check 的配置结构体用 `json:"..."` tag 而不是 `yaml:"..."`？
2. Dockerfile 里 `COPY go.mod go.sum ./` 放在 `COPY . .` 前面是为了什么？
3. 为什么 `ENTRYPOINT ["/cr-check"]` 不能写成 shell 形式？后果是什么？
4. 本地编译的二进制部署到 GKE 后启动失败，可能是什么原因？
5. `-s -w` 的代价是什么？什么场景下不能加？
6. `go vet` 能查出 `resp.Body.Close()` 没检查错误吗？

---

上一篇：[16-slice-map-stdlib.md](16-slice-map-stdlib.md) ｜ 下一篇：[18-logging-slog.md](18-logging-slog.md) ｜ 回到 [00-index.md](00-index.md)
