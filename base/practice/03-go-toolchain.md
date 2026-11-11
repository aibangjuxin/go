# 03 · Go 测试与调试工具链手册（macOS）

> 一句话：**工具链的价值不在"能跑"，而在"把反馈循环从 30 秒压到 1 秒"。**
> 本文是本机实测过的工具清单 + 用法手册，每条都在 2026-11-11 跑通验证过。

---

## 0. 本机现状（实测）

| 工具 | 用途 | 状态 | 位置 |
|---|---|---|---|
| **Go** | 编译器 / 工具链 | ✅ 1.27.3 darwin/arm64 | `/opt/homebrew/bin/go` |
| **air** | live-reload，改代码自动重启 | ✅ 1.67.4 | `/opt/homebrew/bin/air` |
| **gotestsum** | 测试结果彩色输出 + 汇总 | ✅ 1.13.0 | `~/go/bin/gotestsum` |
| **dlv (Delve)** | 调试器 / 断点 / 看 goroutine | ✅ | `~/go/bin/dlv` |
| **golangci-lint** | 静态检查（比 `go vet` 强得多） | ✅ | `~/go/bin/golangci-lint` |
| **goimports** | 格式化 + 自动整理 import | ✅ | `~/go/bin/goimports` |
| **gopls** | LSP，给编辑器做跳转/补全 | ✅ | `~/go/bin/gopls` |
| mockery | 生成 mock | ❌ 可选 | `go install github.com/vektra/mockery/v2@latest` |

> `~/go/bin` 已在 `~/.zshrc` 的 PATH 里（`export PATH="$PATH:$HOME/go/bin"`），
> 所以 `go install` 装的东西**开新终端直接可用**。

### 安装/升级速查

```bash
brew install go-air          # ★ 注意别装错：brew 的 `air` 是 R 语言格式化工具
go install gotest.tools/gotestsum@latest
go install github.com/vektra/mockery/v2@latest

# 一键装齐
go install gotest.tools/gotestsum@latest \
        github.com/vektra/mockery/v2@latest \
        golang.org/x/tools/cmd/goimports@latest \
        golang.org/x/tools/gopls@latest
```

---

## 1. Air：改代码自动重启

### 1.1 一句话原理

```
监听文件变化 → go build → 杀掉旧进程 → 启动新进程
```

### 1.2 最小启动

```bash
cd /Users/lex/git/go/cr-check
air
```

`cr-check/.air.toml` 和 `cr-check/.air.test.toml` 是现成可用的两份配置。

### 1.3 ★ v1.67 schema（网上老教程基本都过时了）

Air v1.67 做过一次破坏性改版，三条必须知道：

| 旧写法 | 新写法 | 不改会怎样 |
|---|---|---|
| `[run]` 段 | **已删除** | `[run] cmd` 被静默忽略，**程序收不到任何命令行参数** |
| `build.bin = "./tmp/x"` | `build.entrypoint = ["./tmp/x"]` | 打印 `build.bin is deprecated` 警告 |
| `bin` / `cmd` 分开 | `entrypoint = ["二进制", "参数1", "参数2"]` | 参数丢失 |

**★ `entrypoint` 是数组，没有 shell 展开**：

```toml
entrypoint = ["./tmp/app", "-addr", ":$PORT"]   # ❌ $PORT 不会被展开
entrypoint = ["./tmp/app", "-addr", ":8081"]    # ✅ 只能写死
```

需要环境变量时改用 `full_bin` 或 `args_bin`。

### 1.4 关键配置项

```toml
root = "."          # 工作目录
tmp_dir = "tmp"     # 产物目录

[build]
  cmd = "go build -o ./tmp/app ./cmd/server"
  entrypoint = ["./tmp/app", "-config", "config/policy.yaml", "-mode", "mock"]

  include_ext  = ["go", "yaml", "yml", "json"]   # 只盯这些扩展名
  exclude_dir  = ["tmp", "vendor", "testdata", ".git"]  # ★ tmp 必须排除
  exclude_regex = ["_test\\.go"]
  exclude_unchanged = false  # ★ 保持 false（air 默认），见下方坑 4

  delay = 100           # 防抖(ms)，编辑器一次保存可能触发多个事件
  stop_on_error = false # ★ false = 编译失败保留旧进程
  send_interrupt = true # 先 SIGTERM 优雅关闭，再 SIGKILL
  kill_delay = "500ms"
```

### 1.5 ★ `stop_on_error` 的真实语义

官方字段注释是 **"Stop running old binary when build errors occur"**。

| 值 | 编译出错时 | 何时用 |
|---|---|---|
| `true`（**air 默认**） | **杀掉旧进程 → 服务中断** | 想让错误立刻暴露 |
| `false` | **保留旧进程 → 服务照常可用** | 边改边验证（**推荐**） |

> ⚠️ **默认的 `true` 反而危险**：你改崩了代码，服务直接挂了，
> 你连"改崩前是什么样"都看不到。
> 反过来，如果你**以为**在测新代码、其实旧进程还活着在服务，那是更隐蔽的坑——
> 所以关键是**先想清楚你要哪种**，而不是无脑抄配置。

### 1.6 四大经典坑

| 坑 | 症状 | 解法 |
|---|---|---|
| **无限重启** | 日志刷屏 `building...` | `tmp` 加进 `exclude_dir` |
| **参数丢失** | 服务起来了但端口/配置不对 | 用 `entrypoint` 数组，别用 `[run]` |
| **端口被占** | `address already in use` | `lsof -ti :8081 \| xargs kill -9` 或换端口 |
| **漏重建** | 改了代码但没重启 | `exclude_unchanged` 保持 `false` |

> ★ **坑 4 详细**：`exclude_unchanged = true` 时 air 按**内容哈希**判断变更，
> 如果你把文件**改回之前的内容**（比如 `git checkout`、撤销实验），
> air 会认为「没变」而**跳过重建**——你还在跑旧代码。
> 保持 `false`（air 默认）最安全。

### 1.7 排查手册

```bash
air -d                    # debug 模式：看 air 到底执行了什么
air --help                # 全部参数
```

```bash
# 想知道 air 实际跑了什么命令
ps -o pid,command -p $(pgrep -f 'tmp/app')
```

### 1.8 每次保存自动跑测试

用 `cr-check/.air.test.toml`：

```bash
cd /Users/lex/git/go/cr-check
air -c .air.test.toml
```

改代码 → 自动 `go test -race -cover ./...` → 输出彩色结果。

### 1.9 和其他工具搭配

| 场景 | 组合 |
|---|---|
| 改业务逻辑看效果 | `air` |
| 改业务逻辑但要断点 | `air` + `dlv attach`（或 `dlv debug`） |
| 边写测试边看红绿 | `air -c .air.test.toml` |
| 查"为什么慢" | `air` + pprof（见 [01-local-debug.md](01-local-debug.md)） |

---

## 2. `go test`：内置测试能力（零安装）

```bash
go test ./...                       # 跑全部
go test -v ./internal/rules/        # verbose，看每个用例名
go test -run TestFoo ./...          # 只跑名字匹配的
go test -race ./...                 # ★ 竞态检测（并发 bug 必开）
go test -cover ./...                # 覆盖率
go test -coverprofile=cov.out ./... && go tool cover -html=cov.out   # 可视化
go test -bench=. ./...              # benchmark
go test -count=1 ./...              # ★ 跳过缓存强制重跑（怀疑结果假绿时用）
go test -run xxx -bench=. ./...     # 常见 CI 组合
go test -short ./...                # 跳过慢用例
```

**★ 最容易被忽略的三个 flag**：

| flag | 什么时候必须加 |
|---|---|
| `-race` | 任何有 goroutine / channel / map 并发的代码 |
| `-count=1` | 怀疑测试结果被缓存骗了 |
| `-v` | 失败时想知道是哪个 case 挂的 |

---

## 3. gotestsum：给测试结果上色 + 汇总

原生 `go test` 的输出在失败时会刷一大堆无用日志。gotestsum 帮你压缩。

```bash
gotestsum ./...                                  # 彩色输出
gotestsum --format testname ./...                # 只显示用例名（最清爽）
gotestsum --format short-verbose ./...           # 失败时展开细节
gotestsum --format json --jsonfile out.json ./...  # 接 CI / 二次分析
gotestsum --rerun-fails ./...                    # ★ 失败的用例自动重跑（最多 2 次）
```

**★ v1.13 没有 `--race` flag**（实测报 `ERROR unknown flag: --race`）。
要跑竞态检测用 `--raw-command` 透传：

```bash
gotestsum --format testname --raw-command -- go test -race -json ./...
```

**★ gotestsum 自带 watch 模式**（写测试时其实不必开 air）：

```bash
gotestsum --watch ./...        # 改代码自动重跑测试
gotestsum --watch --watch-clear --watch-chdir ./...
```

> 有 `gotestsum --watch` 就不需要 `air -c .air.test.toml` 了；
> 区别是 `air` 能改启动参数、`gotestsum` 不能。

**★ 排错黄金组合**：

```bash
gotestsum --format testname -- ./... 2>&1 | grep -A 20 "FAIL"
```

或者直接：

```bash
gotestsum --format short-verbose ./...
```

### 和 air 一起用

`cr-check/.air.test.toml` 里的 `cmd` 是：

```toml
cmd = "gotestsum --format testname --raw-command -- go test -race -json ./... > tmp/test.out 2>&1; cat tmp/test.out"
```

（实测：32 个用例 + 竞态检测，输出干净）

---

## 4. dlv（Delve）：调试器

```bash
dlv debug ./cmd/server                 # ★ 调试并自动跑
dlv debug ./cmd/server -- -mode mock   # ★ -- 之后是传给程序的参数
dlv test ./...                         # 调试测试
dlv test ./internal/rules/ -test.run TestFoo
dlv attach $(pgrep -f 'tmp/app')        # attach 到已在跑的进程（配合 air）
dlv connect localhost:2345             # 远程
```

**常用交互命令**（进入 dlv 后）：

| 命令 | 作用 |
|---|---|
| `break main.go:42` | 在 42 行打断点 |
| `break Foo` | 在函数 Foo 断点 |
| `r` / `c` | 运行 / 继续 |
| `n` / `s` | 下一行 / 步入 |
| `bt` | 打印调用栈 |
| `print x` | ★ 打印变量（比猜值快得多） |
| `vars` / `locals` | 列出所有变量 |
| `goroutines` | ★ 列出所有 goroutine |
| `goroutine 3` | 切到第 3 个 goroutine 看栈 |

> ★ **调试 Go 的第一手段不是断点，是 `print`**。
> 90% 的"值不对"问题，`print x` 一行就定位了，比设断点快得多。

---

## 5. golangci-lint：静态检查

比 `go vet` 强一个数量级，能查出**并发、错误未处理、资源泄漏、性能**等问题。

```bash
golangci-lint run                    # 全量
golangci-lint run ./internal/...     # 只跑部分包
golangci-lint run --fix             # 自动修可修的
golangci-lint run --enable-all      # 打开所有 linter（很吵）
golangci-lint run --new-from-rev=HEAD  # ★ 只报新增代码（CI 里用）
```

cr-check 的 `make lint` 已经调好了。推荐配置（`.golangci.yml`）：

```yaml
linters:
  enable:
    - errcheck      # 未检查的错误
    - govet
    - staticcheck   # 最强的一批通用检查
    - ineffassign
    - unused
    - bodyclose     # http response body 没关
    - noctx         # http 请求没带 context
    - misspell
```

---

## 6. goimports / gopls

```bash
goimports -w .          # 格式化 + 整理 import 分组（比 gofmt 强）
goimports -l .          # 只列出需要改的文件（CI 检查用）
gopls check file.go     # 跑 LSP 的诊断
```

编辑器里（VS Code / gopls）保存时自动跑 goimports。

---

## 7. 组合工作流（推荐）

### 日常开发

```bash
# 终端 A：起服务，改代码自动重启
air

# 终端 B：验证
curl -s localhost:8081/healthz
curl -s localhost:8081/internal/policy | jq
```

### 写测试

```bash
# 终端 A：保存即跑测试
air -c .air.test.toml

# 终端 B：偶尔手动深挖
gotestsum --format short-verbose --race ./...
```

### 查 bug

```bash
# 1. 先用 print 猜
# 2. 猜不到再上断点
dlv debug ./cmd/server -- -config config/policy.yaml -mode mock
```

### 提交前

```bash
make fmt vet lint test
```

---

## 8. 一张速查表

| 我想… | 命令 |
|---|---|
| 改代码自动重启服务 | `air` |
| 改代码自动跑测试 | `air -c .air.test.toml` |
| 测试结果看得舒服点 | `gotestsum --format testname ./...` |
| 看某个用例为什么挂 | `gotestsum --format short-verbose --run TestX ./...` |
| 查竞态 | `go test -race ./...` |
| 查覆盖率 | `go test -coverprofile=cov.out ./... && go tool cover -html=cov.out` |
| 断点调试 | `dlv debug ./cmd/server -- -mode mock` |
| 附加到已在跑的服务 | `dlv attach $(pgrep -f 'tmp/app')` |
| 看所有 goroutine | dlv 里 `goroutines` |
| 静态检查 | `golangci-lint run` |
| 格式化 | `goimports -w .` |

---

## 9. 相关

- [01-local-debug.md](01-local-debug.md) —— 调试的**思路**（四套方案、mock 复现、pprof）
- [02-config-and-deploy.md](02-config-and-deploy.md) —— 配置与部署
- [17-modules-build.md](../17-modules-build.md) —— 构建与依赖
