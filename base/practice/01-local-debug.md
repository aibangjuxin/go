# 01 · 本地调试（在 macOS 上不反复编译地调 Go）

> 一句话：**Go 的"编译"其实很快（实测增量编译 0.09 秒），
> 所以调试体验的核心不是"跳过编译"，而是"别让进程重启吃掉你的注意力"。**
> 本文给出 macOS 上从轻到重的四套方案，以及 cr-check 专属的复现姿势。

---

## 0. 先看一组实测数据（cr-check，Apple Silicon）

```bash
cd /Users/lex/git/go/cr-check

$ time go build -o /tmp/cc ./cmd/server     # 冷编译（无缓存）
real    0m2.535s

$ touch internal/rules/engine.go
$ time go build -o /tmp/cc ./cmd/server     # 改一个业务文件后重编
real    0m0.091s
```

**★ 结论**：
Go 的增量编译是 **90 毫秒级**。
你"感觉要等很久"，通常是因为：
- 跑的是 `go run ./cmd/server`（多了链接 + 启动）
- 跑的是 `go test ./...`（要链接测试二进制 + 跑全部测试）
- 或者在跑 `docker build`（那才是真的慢）

**所以第一原则：本地调试用 `go build` / `go run`，不要用 docker。**

---

## 1. 四套方案速查

| 方案 | 适合什么 | 重启耗时 | 心智负担 |
|---|---|---|---|
| **A. `go build` + 手动重启** | 改一行的日常 | 0.1s | 最低 |
| **B. Air 自动重启** | 持续迭代 | 0.1s + 进程重启 | 低 |
| **C. Delve 断点调试** | 查逻辑 bug | 断点即时 | 中 |
| **D. mock + 固定时间 + curl** | **复现一个具体 case** | 秒级 | 最低 |

**★ D 是 cr-check 最该用的**（见第 5 节），它能让你**不写任何代码**就复现一个 case。

---

## 2. 方案 A：`go build` + 手动重启

### 基本循环

```bash
cd /Users/lex/git/go/cr-check

# 一行编译 + 起服务
make run        
# = go run ./cmd/server -config config/policy.yaml -mode mock -addr :8081 -sync-eval
##  go run ./cmd/server -config config/policy.yaml -mode mock -addr :8081 -sync-eval
```

`make run` 用的就是 `go run` —— Go 会复用编译缓存，所以实际是"编译 + 启动"约 0.3s。

### ★ 更好的做法：一个终端跑服务，一个终端跑请求

```bash
# 终端 1：起服务（改代码后 Ctrl-C 重来，0.3s）
make run

# 终端 2：反复打请求
- /Users/lex/git/go/cr-check at this dir 
curl -s -X POST http://localhost:8081/github/webhook \
  -H 'X-GitHub-Event: pull_request' \
  -H 'X-GitHub-Delivery: demo-1' \
  -H 'Content-Type: application/json' \
  --data @testdata/pr-event.json | jq
```

cr-check 已经提供了测试脚本：

```bash
# cr-check/scripts/send-test-event.sh
./scripts/send-test-event.sh
```

### ★ 别忘了 `-show-config`：确认"生效的配置"是什么

```bash
make show-config
```

**★ 排查"为什么规则没生效"时，这一条命令能省半小时** ——
它打印的是**脱敏后**的最终生效配置（含环境变量覆盖后的结果）。

---

## 3. 方案 B：Air（文件监听自动重启）

**Air** 是 Go 生态最常用的 live-reload 工具：监听文件变化 → 自动编译 → 重启进程。

### 安装

```bash
# 方式 A：brew（推荐，有 bottle 不用编译，秒装）
brew install go-air
# ⚠️ 别装错：brew 里的 `air` 是 R 语言的格式化工具，
#    Go 的这个叫 `go-air`，两者二进制同名、互斥

# 方式 B：go install（版本最新，但要编译 ~1 分钟）
go install github.com/air-verse/air@latest
# 装到 ~/go/bin/air（你的 PATH 里已经有 ~/go/bin）
```

> 本机现状：**air v1.67.4 已装**（`/opt/homebrew/bin/air`）。
> 2026-11-11 实测可用。

### ★ v1.67 的 schema 变化（网上老教程/博客基本都是错的）

| 旧写法 | 新写法 | 后果 |
|---|---|---|
| `[run]` 段 | **已移除** | `[run] cmd` 被静默忽略，程序拿不到任何参数 |
| `build.bin = "./tmp/main"` | `build.entrypoint = ["./tmp/main"]` | 打印 `build.bin is deprecated` 警告 |
| `bin = "x"`, `cmd = "y"` 分开写 | `entrypoint = ["可执行文件", "参数1", ...]` | **数组**，第一个是二进制，其余是参数 |

> ★ **`entrypoint` 是数组，没有 shell 展开**：
> 写 `"-addr", ":$PORT"` **不会生效**，端口必须写死或改配置文件。

### 配置 `.air.toml`（v1.67 实测可用）

```toml
root = "."
tmp_dir = "tmp"

[build]
  # ★ 用 go build 而不是 go run：避免 go run 的进程包装层，信号能直达你的程序
  cmd = "go build -o ./tmp/cr-check ./cmd/server"

  # ★ 第一个元素是二进制，后面都是默认参数（数组，不是字符串）
  entrypoint = [
    "./tmp/cr-check",
    "-config", "config/policy.yaml",
    "-mode", "mock",
    "-addr", ":8081",
    "-sync-eval",
  ]

  include_ext = ["go", "yaml", "yml", "json", "tpl"]
  exclude_dir = ["tmp", "vendor", "testdata", "deploy", "bin", ".git"]
  exclude_regex = ["_test\\.go"]
  exclude_unchanged = true
  delay = 100          # ★ 防抖：连续保存时不要立刻重启
  stop_on_error = false # ★ false = 编译失败时**保留旧进程**，服务不挂
  send_interrupt = true # 先 SIGTERM 优雅关闭，再 SIGKILL
  kill_delay = "500ms"

[misc]
  clean_on_exit = true

[log]
  time = true
```

> cr-check 仓库里已经放好了可直接用的版本：`cr-check/.air.toml`。

### 运行

```bash
air          # 用当前目录的 .air.toml
air -d       # 调试模式：打印详细日志（air 不重启时先开这个看）
```

改代码 → 自动编译 → 自动重启。

**验证是否真的生效**（2026-11-11 实测流程）：

```bash
cd /Users/lex/git/go/cr-check
air &                                     # 或另开一个终端
# 改一行代码 → 日志出现 "building... / running..." → 新代码生效
```

### ★ 三个关键配置的解释

**① `stop_on_error = false`（重要！）**

Air 官方字段说明是 **"Stop running old binary when build errors occur"**，
所以 `true` 的意思是**编译出错就把旧进程杀掉**（air 的默认值就是 `true`）。

想要「编译失败时旧进程继续跑」，必须显式写 `stop_on_error = false`。

| 值 | 编译出错时 | 适合 |
|---|---|---|
| `true`（air 官方示例模板显式设的值；**air 真正的默认值是 `false`**） | **杀掉旧进程 → 服务中断** | 想让错误立刻暴露 |
| `false` | **保留旧进程 → 服务继续可用** | 边改边验证（**推荐**） |

> ⚠️ 本笔记早期版本把这里写反了（写成 `stop_on_error = true` 能保活）。
> 2026-11-11 实测确认：写 `true` 时编译报错，旧进程被 SIGTERM 掉，
> curl 直接连不上；写 `false` 时旧进程存活，服务照常响应。
> `stop_on_error = true` 的真实用途是**别让旧二进制偷偷跑着骗你**——
> 你以为在测新代码，其实测的是旧代码。

**② `exclude_dir` 必须排除 `tmp`**

Air 编译产物在 `tmp/`，如果不排除，
Air 会检测到自己生成的二进制变化 → **无限重启循环**。这是最常见的坑。

**③ `delay = 100` 防抖**

编辑器保存一次可能触发多个事件（尤其带格式化插件时）。
100ms 延迟能合并掉。

### ★ Air 的信号处理

Air 默认会 `SIGTERM` 子进程。
cr-check 用了 `signal.NotifyContext` + `srv.Shutdown`，
所以能优雅关闭（10 秒超时）。

但如果你想调试"卡住"的问题，可以临时让 Air 强杀：

```toml
[build]
  send_interrupt = false   # 发 SIGKILL 而不是 SIGTERM
```

---

## 4. 方案 C：Delve（断点调试）

**Delve (dlv)** 是 Go 的官方调试器。你机器上**已经装好了**：

```bash
$ dlv version
Delve Debugger
Version: 1.27.2
```

### 4.1 命令行调试

```bash
cd /Users/lex/git/go/cr-check

# 启动并进入交互式调试
dlv debug ./cmd/server -- -config config/policy.yaml -mode mock -addr :8081 -sync-eval
```

`--` 之后的参数会传给程序本身。

进入后：

```
Type 'help' for 'help list'.
(dlv) break internal/rules/engine.go:212      # 在某行打断点
(dlv) break rules.ruleR4                       # 在函数打断点
(dlv) break github.com/acme/cr-check/internal/rules.Engine.Evaluate
(dlv) continue                                 # 继续运行
(dlv) next                                     # 单步（不进入函数）
(dlv) step                                     # 单步（进入函数）
(dlv) print in.PR                             # 打印变量
(dlv) print len(in.CR.Approvers)
(dlv) args                                     # 打印当前函数参数
(dlv) locals                                   # 打印当前函数局部变量
(dlv) bt                                       # 打印调用栈
(dlv) goroutines                               # ★ 列出所有 goroutine
(dlv) goroutine 12                             # 切到某个 goroutine
(dlv) vars                                     # 当前作用域所有变量
(dlv) restart                                  # 重启程序
(dlv) quit
```

### ★ 最有用的三个命令

| 命令 | 用途 |
|---|---|
| `print x` | 看变量 |
| `bt` | 看调用栈 |
| **`goroutines`** | **看 goroutine 卡在哪**（排查死锁/泄漏神器） |

### 4.2 调试测试

```bash
dlv test ./internal/rules/ -- -test.run TestWindowContains
```

进去后 `break rules.TestWindowContains`。
**★ 调试测试比调试服务更适合纯逻辑**（不用起服务、不用发请求）。

### 4.3 附加到已经在跑的进程

```bash
# 先拿到 PID
pgrep -f cr-check

# 附加
dlv attach $(pgrep -f cr-check)
```

> ★ `dlv attach` 需要二进制带符号信息。
> 如果用 `-ldflags '-s -w'` 编译的，**调试信息被剥掉了** → attach 会失败。
> 调试时用 `make build` 的**不带 `-w`** 的版本，或者直接 `dlv debug`。

### 4.4 远程调试

```bash
# 本地监听，远程机器连过来
dlv debug --headless --listen=:2345 --api-version=2 ./cmd/server
```

```bash
# 另一台机器
dlv connect host:2345
```

> ★ **注意安全**：`--listen` 默认**没有鉴权**，
> 任何能连上这个端口的人都能控制你的进程。
> **不要暴露到公网**，用 SSH 隧道：
> ```bash
> ssh -N -L 2345:localhost:2345 user@remote
> ```

### 4.5 VS Code / GoLand（图形化）

**VS Code**（装 Go 扩展 + `vscode-go.delve`）：
- `F5` 启动调试
- 左侧断点、行号点击设断点
- 变量面板 / 调用栈 / goroutine 面板
- **Hot Reload（热重载）**：Delve v1.22+ 支持 DAP 的热重载请求，
  在**函数级别**修改代码后可以不重启进程（Go 1.18+ 支持方法/函数级别的热重载）
  —— 你现在的 Delve 1.27.2 版本足够新。
  > ⚠️ 热重载有**限制**：只支持函数体，不支持改结构体字段、加/删函数、
  > 改全局变量。加了 `go.mod` 依赖或改了类型定义 → 必须重启。

**GoLand**（JetBrains）：
- 内置调试器，体验最好（重构、goroutine 视图、内存视图）
- 支持 `Ctrl+F9` 之类的热重载

### ★ 什么时候**不**该用断点调试

| 场景 | 更好的工具 |
|---|---|
| 逻辑很复杂、状态很多 | **先写测试**（见第 6 节） |
| 复现某个具体 case | **mock + 固定时间 + curl**（见第 5 节） |
| 并发问题 | `go test -race` + `goroutines` 命令 |
| 性能问题 | **pprof**（见第 7 节） |

**★ 断点调试是"最后手段"**。因为它依赖你在正确的时刻暂停在正确的位置 ——
而并发程序里"正确的时刻"往往不存在。

---

## 5. ★★ 方案 D：mock + 固定时间 + curl（cr-check 专属，最实用）

**这是 cr-check 最有价值的调试能力，已经内置了。**

### 5.1 mock 模式：不连任何外部依赖

```bash
make run
# = go run ./cmd/server -config config/policy.yaml -mode mock -addr :8081 -sync-eval
```

| 标志 | 作用 |
|---|---|
| `-mode mock` | 用内置假 CR 平台 + 日志型 check writer |
| `-sync-eval` | **同步判定** → curl 立刻拿到结论，不用等异步 |
| `-now <RFC3339>` | **固定"当前时间"** → 验证维护窗口规则 |
| `-show-config` | 打印脱敏后的生效配置 |
| `-audit-file <path>` | 审计日志落盘 |

### ★ 5.2 用固定时间验证"维护窗口"

维护窗口规则（R6w）依赖"当前时刻"，是**最难手动复现**的规则。
`-now` 让它变得可复现：

```bash
# 窗口是 Asia/Shanghai 的 Mon-Fri 02:00-04:00
# 2025-01-06 是周一，03:00 在窗口内 → R6w 通过
# ★ -now 是**启动参数**，不是请求参数 —— 要重启服务换时间
go run ./cmd/server -config config/policy.yaml -mode mock -sync-eval \
    -now "2025-01-06T03:00:00+08:00" -addr :8081

# 然后打请求
curl -s -X POST http://localhost:8081/github/webhook \
  -H 'X-GitHub-Event: pull_request' \
  -H 'X-GitHub-Delivery: demo-1' \
  -H 'Content-Type: application/json' \
  --data @testdata/pr-event.json | jq '.failed_rules'
```

**★ 同一个服务实例，起两次就能对比"窗口内 / 窗口外"**：

```bash
# 第一次：窗口内
-now "2025-01-06T03:00:00+08:00"    # → R6w ✅

# 第二次：窗口外（Ctrl-C 后重启）
-now "2025-01-06T10:00:00+08:00"    # → R6w ❌
```

> ★ **这个能力不只是调试用的**，它还是一个**可复现的验收手段**：
> 维护窗口出问题的时候，能立刻复现并验证修复。

### 5.3 内置的假 CR 平台可以直接查

```bash
curl -s http://localhost:8081/mock/cr | jq
curl -s http://localhost:8081/mock/cr/1234 | jq
```

### 5.4 内部观测端点

```bash
curl -s http://localhost:8081/internal/policy     | jq   # 生效配置（脱敏）
curl -s http://localhost:8081/internal/last-check | jq   # 最近一次 check 写入
curl -s http://localhost:8081/internal/audit      | jq   # 最近 50 条审计
curl -s http://localhost:8081/internal/registry   | jq   # 已登记的受管 PR
curl -s http://localhost:8081/internal/recheck -X POST | jq   # 立刻触发一次重扫
curl -s http://localhost:8081/metrics | grep cr_check       # Prometheus 指标
```

> ★ **`/internal/*` 这些端点是调试的黄金入口**。
> 它们让你**不用加任何临时日志**就能看到内部状态。

### 5.5 复现一个 case 的完整配方

```bash
# 1. 起服务（mock + 同步 + 固定时间）
go run ./cmd/server -config config/policy.yaml -mode mock -sync-eval \
    -now "2025-01-06T03:00:00+08:00" -addr :8081

# 2. 打事件
curl -s -X POST http://localhost:8081/github/webhook \
  -H 'X-GitHub-Event: pull_request' \
  -H 'X-GitHub-Delivery: demo-1' \
  -H 'Content-Type: application/json' \
  --data @testdata/pr-event.json | jq '.conclusion, .failed_rules, .rules'

# 3. 看内部状态
curl -s http://localhost:8081/internal/last-check | jq
curl -s http://localhost:8081/internal/audit | jq '.[-1]'
```

**★ 全程零代码改动**。想试不同 case，改 `-now` 或 payload 就行。

### ★ 5.6 mock 数据也在配置里 —— 加 case 不用改代码

```yaml
# config/policy.yaml
mock:
  enabled: true
  crs:
    - number: "1234"     # ✅ 合规
      status: Implement
      requester: alice
      approvers: [bob, carol]
      targetEnv: prd
      validFrom: "2020-01-01T00:00:00+08:00"
      validTo: "2035-12-31T23:59:59+08:00"

    - number: "5678"     # ❌ Draft 状态 → R3
      status: Draft
      ...
    - number: "9999"     # ⚠️ 模拟平台故障 → fail-closed
      error: "simulated CR platform timeout"
```

**★ 加一个测试 case = 加一段 YAML**，不用改 Go 代码。
这正是"不要写死"的直接体现（详见 [02-config-and-deploy.md](02-config-and-deploy.md)）。

---

## 6. 方案 E：测试驱动调试（**最被低估的调试方式**）

**当逻辑复杂时，"写一个失败的测试"比"打断点"快得多。**

```bash
# 只跑一个测试
go test ./internal/rules/ -run TestWindowContains -v

# 带 race detector
go test -race ./internal/rules/ -run TestWindowContains -v

# 看覆盖率，找出没覆盖的分支
go test -coverprofile=/tmp/cov.out ./internal/rules/
go tool cover -html=/tmp/cov.out     # 浏览器打开
```

### ★ 调试 + 测试组合拳

```bash
# 1. 写一个失败的测试，复现 bug
# 2. go test -run TestXxx 确认它失败（复现成功）
# 3. dlv test 进去打断点，看中间状态
dlv test ./internal/rules/ -- -test.run TestXxx
# 4. 修代码
# 5. go test -run TestXxx 确认通过
# 6. go test -race -cover ./... 确认没弄坏别的
```

**★ 这个循环的好处**：
- 测试是**永久资产**（调试完还留着防回归）
- 不依赖手动发请求
- 可以进 CI

### ★ fuzz 测试：让机器帮你找边界情况

```bash
go test -fuzz=FuzzXxx -fuzztime=30s ./internal/rules/
```

---

## 7. 方案 F：pprof（性能问题专用）

### 开启

```go
import (
    "net/http"
    "net/http/pprof"
)

mux := http.NewServeMux()
mux.HandleFunc("/debug/pprof/", pprof.Index)
mux.HandleFunc("/debug/pprof/profile?seconds=30", pprof.Profile)
mux.HandleFunc("/debug/pprof/heap", pprof.Handler("heap").ServeHTTP)
mux.HandleFunc("/debug/pprof/goroutine", pprof.Handler("goroutine").ServeHTTP)
```

> ★ **只在本地/内网开，不要暴露到公网**（pprof 能泄漏堆信息）。

### 使用

```bash
# CPU 剖析（30 秒）
go tool pprof http://localhost:8081/debug/pprof/profile?seconds=30

# 堆内存
go tool pprof http://localhost:8081/debug/pprof/heap

# goroutine 泄漏
curl -s http://localhost:8081/debug/pprof/goroutine?debug=2 | head -40
```

> ★ **`?debug=2` 是排查 goroutine 泄漏的利器**：
> 它直接打印每个 goroutine 的栈，能直接看出"谁卡在 channel 上"。

---

## 8. macOS 专属的坑

### 坑 1：端口被占用

```bash
# 查谁占着 8081
lsof -i :8081

# 杀掉
lsof -ti :8081 | xargs kill -9

# 或者换个端口
make run ADDR=:9090
```

> ★ **本机端口分配约定**（2026-11-11 起统一）：
> | 服务 | 端口 | 说明 |
> |---|---|---|
> | rag | 8080 | 本机常驻，**别动** |
> | cr-check | **8081** | 本仓库全部配置已统一改成 8081 |
>
> 改端口时记得**三处一起改**，否则服务起不来：
> `config/policy.yaml` 的 `server.addr` → `Makefile` 的 `ADDR` → `.air.toml` 的 `entrypoint`。
> 容器侧还要同步：`deploy/deployment.yaml` 的 `containerPort` / `targetPort` / ConfigMap `addr`。

#### ★★ 更阴的版本：两个服务「同时」占着同一个端口

本机真实案例（2026-11-11，**改端口之前** cr-check 和 rag 都用了 8080）：

```
$ lsof -i :8080 -sTCP:LISTEN
Python   4343 lex  6u  IPv4  0x...  TCP localhost:8080 (LISTEN)   ← rag 服务，只绑 127.0.0.1
server  49427 lex  6u  IPv6  ...    TCP *:8080 (LISTEN)             ← cr-check，绑 IPv6 通配
```

**不报错，但请求会打到不同的服务**：

```bash
$ curl http://localhost:8080/healthz   # → ::1  → 命中 cr-check（HTTP 200）
$ curl http://127.0.0.1:8080/          # → IPv4 → 命中 rag（FastAPI 404）
```

原因：macOS 上 `localhost` 先解析到 `::1`（IPv6），curl 连 IPv6；
写 `127.0.0.1` 则强制 IPv4 → 打到另一个进程。

> ★ **教训**：`lsof -i :8080` 看到两行 ≠ 安全。
> 要看**地址族**（IPv4/IPv6），否则你会在"为什么有时 404 有时 200"上浪费一天。
> **根治**：开发端口一人一个，别撞。现在 cr-check 用 8081、rag 用 8080，彻底分开。

> ★ **Air 场景下更常见**：Air 杀进程有时不彻底，端口一直被占。
> Air 的 `kill_delay = "500ms"` 就是给这个留的余量。

### 坑 2：Air 无限重启

**原因**：`tmp/` 没被 `exclude_dir` 排除 → Air 看到自己的产物变化 → 重启 → 再变化……
**解法**：确保 `.air.toml` 里有 `exclude_dir = ["tmp", ...]`。

### 坑 3：Apple Silicon 的架构

```bash
go env GOARCH   # arm64
```

GKE 节点池如果是 amd64，本地交叉编译的二进制**启动即失败**（exec format error）。
**解法**：在 CI 里 `docker build`，让基础镜像决定架构（见 [17-modules-build.md](../17-modules-build.md)）。

### 坑 4：系统休眠导致连接断

Mac 休眠后，本地服务可能被冻结，curl 报"连接被重置"。
唤醒后重新跑就行。调试时可以用：

```bash
caffeinate -i make run     # ★ 阻止系统休眠
```

### 坑 5：Go 工具链的 Gatekeeper 提示

用 `go install` 装的 `~/go/bin/air` 第一次运行可能提示"无法验证开发者"：

```bash
xattr -d com.apple.quarantine ~/go/bin/air
```

> 用 `brew install go-air` 装的没这个问题（brew 会去掉 quarantine 属性）。

### 坑 6：文件监听事件不完整

macOS 的 FSEvents 对某些目录（尤其是网络盘、`~/Library` 下）事件会丢。
Air 配 `include_ext` 明确只监听 `.go`/`.yaml`，能减少丢事件。

---

## 9. 一张"该用什么"决策表

| 你要做的事 | 用什么 |
|---|---|
| 改一行业务逻辑，看效果 | `make run` + Air |
| 复现一个具体的 PR 判定 case | **mock + `-now` + curl** |
| 查"为什么这个值不对" | `dlv` 断点 / `print` |
| 查"为什么服务卡住了" | `dlv` 的 `goroutines` / pprof `goroutine?debug=2` |
| 查"为什么这么慢" | pprof CPU profile |
| 查"为什么行为不稳定" | `go test -race` |
| 查"边界情况对不对" | 表驱动测试 / fuzz |
| 查"线上跑的是哪个版本" | `/version` 端点（**建议加上**） |

---

## 10. 团队协作建议

**★ 把调试姿势固化进 Makefile，不要靠记。**

cr-check 的 Makefile 建议补成：

```makefile
ADDR    ?= :8081
CONFIG  ?= config/policy.yaml
NOW     ?=
DELIVERY ?= demo-1

run: ## 本地起服务
	go run ./cmd/server -config $(CONFIG) -mode mock -addr $(ADDR) -sync-eval $(if $(NOW),-now $(NOW),)

run-real: ## 真实凭据
	go run ./cmd/server -config $(CONFIG) -mode real -addr $(ADDR)

debug: ## 启动 Delve 调试
	dlv debug ./cmd/server -- -config $(CONFIG) -mode mock -addr $(ADDR) -sync-eval

test-watch: ## 每次保存自动跑测试
	air -c .air.test.toml

fmt vet lint test: ...
```

然后用法变成：

```bash
make run                                  # 常规
make run NOW=2025-01-06T03:00:00+08:00   # 固定时间
make run ADDR=:9090                      # 换端口
make debug                               # 断点调试
```

**★ 好处**：新人 clone 下来 `make help` 就知道怎么跑，
不用问"上次那个命令是啥来着"。

---

## 11. 一句话总结

> **Go 调试的核心认知：编译只要 0.1 秒，别把时间花在编译上。**
> - 本地一律 `go build` / `go run`，**不要 `docker build`**
> - **Air** 做自动重启（`stop_on_error = false` 保活 + 排除 `tmp`）
> - **Delve** 查逻辑（你已装 v1.27.2），重点会用 `print` / `bt` / `goroutines`
> - **★ cr-check 专属王牌：mock + `-now` + `-sync-eval` + `/internal/*` 端点**
>   → 复现任何 case 都不用改代码
> - 并发问题先 `go test -race`，性能问题先 pprof
> - 把调试命令固化进 Makefile

---

## 12. 自测题

1. 为什么 `go build` 的增量编译只要 0.1 秒？这个缓存存在哪？
2. Air 的 `stop_on_error = false` 解决什么问题？为什么默认的 `true` 反而危险？
3. 为什么 Air 必须把 `tmp` 加进 `exclude_dir`？
4. cr-check 的 `-now` 参数解决了什么"调试困难"？
5. 为什么说"写一个失败的测试"往往比断点调试更快？
6. `dlv attach` 为什么会失败（提示二进制编译时带了 `-s -w`）？
7. 排查 goroutine 泄漏，pprof 的哪个端点最有用？

---

上一篇：[README.md](README.md) ｜ 下一篇：[02-config-and-deploy.md](02-config-and-deploy.md) ｜ 回到 [00-index.md](../00-index.md)
