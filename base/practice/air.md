# air.md · Go live-reload 工具 air 的工作原理与配置详解

> 一句话：**air = `go build` + 一个文件监听器 + 一个进程管理器。**
> 它不改变你程序的任何行为，只是把「编译」和「重启」这两件重复劳动自动化了。
>
> 本文基于 **air v1.67.4 / macOS arm64** 实测（2026-11-11），所有结论都跑过一遍。

---

## 0. 先回答最容易混淆的问题

你在终端敲的这两条命令，**跑的是同一个程序、同一套参数**：

```bash
# A. 手动
go run ./cmd/server -config config/policy.yaml -mode mock -addr :8081 -sync-eval

# B. air
air
```

区别只有一个：**B 会在你改代码后自动重跑一遍 A**。

---

## 1. 三条命令的等价关系

### 1.1 拆解 `go run`

```
go run ./cmd/server -config config/policy.yaml -mode mock -addr :8081 -sync-eval
├──────────┬────────────────┴──────────────┬──────────────────────────────────┤
│ 命令      │ 包路径（要编译谁）              │ 参数（传给程序的 flag）              │
│ go run   │ ./cmd/server                   │ -config config/policy.yaml        │
│          │  ↓                             │  -mode mock                       │
│          │ 编译成临时二进制                 │  -addr :8081                      │
│          │  ↓                             │  -sync-eval                       │
│          │ exec 临时二进制 ───────────────→└──────────────────────────────────┘
│          │   ↑ go run 自己是个父进程，只是个包装层
```

`go run` 做了三件事：**编译 → 链接 → exec**。它本身还留在前台当父进程。

### 1.2 air 把这三件事拆开了

```toml
# cr-check/.air.toml
[build]
  cmd = "go build -o ./tmp/cr-check ./cmd/server"      # ← 对应「编译」

  entrypoint = [                                       # ← 对应「exec + 参数」
    "./tmp/cr-check",
    "-config", "config/policy.yaml",
    "-mode", "mock",
    "-addr", ":8081",
    "-sync-eval",
  ]
```

**参数逐字相同**，只是从命令行搬进了配置文件。

### 1.3 对照表

| | `go run ./cmd/server -args` | `make run` | `air` |
|---|---|---|---|
| 谁做编译 | `go run` 内部（编译到临时目录） | `go run` 内部 | **`build.cmd` 显式 `go build`** |
| 产物在哪 | 系统临时目录（用完即删） | 系统临时目录 | **`./tmp/cr-check`（你自己指定）** |
| 参数从哪来 | 命令行 | Makefile 变量 `$(CONFIG) $(ADDR)` | **`.air.toml` 的 `entrypoint`** |
| 跑起来的是什么 | go run（父进程）→ 你的程序 | 同左 | **你的程序（无包装层）** |
| 改代码后 | 手动 Ctrl+C 再来一次 | 同左 | **自动重编译 + 自动重启** |
| SIGTERM 能直达程序吗 | ⚠️ 要经过 go run 转发 | ⚠️ 同左 | ✅ **直达** |
| 适合 | 一次性脚本、CI | 团队统一姿势 | **持续迭代开发** |

> ★ **`make run` 就是 `go run` 的封装**（cr-check/Makefile）：
> ```makefile
> ADDR     ?= :8081
> CONFIG   ?= config/policy.yaml
> run: go run ./cmd/server -config $(CONFIG) -mode mock -addr $(ADDR) -sync-eval
> ```
> 所以 `make run` ≡ 你手敲的 `go run ./cmd/server -config config/policy.yaml -mode mock -addr :8081 -sync-eval`。
> **air ≡ make run + 自动重启。**

### 1.4 为什么 air 用 `go build` 而不是 `go run`

air 必须**先拿到一个稳定的二进制文件**才能反复重启：
- `go run` 的产物在临时目录、每次可能不同、且是包装进程 → 没法被干净地 SIGTERM
- `go build -o ./tmp/cr-check` 产出一个固定路径的普通可执行文件 → air 直接 exec 它，**信号直达**，端口释放干净

这也解释了两个配置项：

| 配置 | 作用 |
|---|---|
| `send_interrupt = true` | 先给程序发 **SIGTERM**（让 `srv.Shutdown()` 优雅关闭），再 SIGKILL |
| `kill_delay = "500ms"` | SIGTERM 后等 500ms，给程序收尾时间；不够就强杀 |

---

## 2. air 的完整执行流程

```
┌─ 启动 ─────────────────────────────────────────────────────────┐
│ 1. 读配置（见第 3 节优先级）                                    │
│ 2. root="." → 确定监听根目录                                     │
│ 3. 遍历 root，按 include_ext / exclude_dir / exclude_regex 过滤  │
│    → 得到「要监听的文件集合」                                    │
│ 4. 对集合里的文件装 fsnotify 监听器                              │
└───────────────────────────────────────────────────────────────┘
                          ↓
┌─ 稳态 ─────────────────────────────────────────────────────────┐
│  文件变化事件                                                     │
│    ↓                                                            │
│  delay 防抖（等 100ms，把一次保存触发的多个事件合并）              │
│    ↓                                                            │
│  执行 build.cmd（走 shell）→ 产物 = entrypoint[0]                │
│    ↓                                                            │
│  编译成功？ ──否──→ 报错，打印日志                               │
│    │是                    │                                     │
│    │                      └── stop_on_error=false → 保留旧进程     │
│    ↓                          stop_on_error=true  → 杀掉旧进程     │
│  杀旧进程（SIGTERM → kill_delay → SIGKILL）                      │
│    ↓                                                            │
│  exec entrypoint[0] + entrypoint[1:] → 新进程                     │
│    ↓                                                            │
│  回到稳态，继续监听                                              │
└───────────────────────────────────────────────────────────────┘
```

### 启动时你会看到的日志

```
  __    _   ___        ← 启动 banner
 / /\  | | | |_) 
/_/--\ |_| |_| \_ 
v1.67.4, built with Go 1.27.1

[10:00:57] watching internal        ← 开始监听这些目录
[10:00:57] watching internal/audit
[10:00:57] !exclude tmp              ← 这些被排除
[10:00:57] !exclude vendor
[10:00:57] building...                ← 第一次构建
[10:00:59] running...                 ← 第一次启动
```

改代码之后：

```
[10:01:04] cmd/server/main.go has changed
[10:01:04] building...
[10:01:05] running...
```

---

## 3. 配置从哪来？加载优先级（实测）

air v1.67.4 的查找顺序，**从高到低**：

| 优先级 | 来源 | 实测结果 |
|---|---|---|
| 1 | 命令行 flag：`air --build.cmd "..."` | ✅ 生效，覆盖配置文件 |
| 2 | `air -c /path/to/file.toml` | ✅ 生效，覆盖配置文件 |
| 3 | **当前工作目录下的 `./.air.toml`** | ✅ 生效（**唯一会被自动发现的路径**） |
| 4 | 内置默认值 | ✅ 兜底 |

### 实测过、**不会**被读取的路径（v1.67.4）

| 路径 | 是否生效 | 说明 |
|---|---|---|
| `./.air.toml` | ✅ | **唯一自动发现的路径** |
| `./air.toml`（少个点） | ❌ | 不读 |
| `./config/air.toml` | ❌ | 不读 |
| `$HOME/.air.toml` | ❌ | **不读全局配置** |
| `AIR_TOML_PATH` 环境变量 | ❌ | **不读** |

> ★ **实践含义**：
> - 你**必须 `cd` 到项目根目录**再敲 `air`，否则它找不到 `.air.toml`，会用内置默认值
>   （默认 `go build -o ./tmp/main .`，大概率编译失败）。
> - 想知道 air 到底读了什么，开 debug 模式：`air -d`。
> - 想临时改一项又不想动文件：`air --build.cmd "..."`。

---

## 4. `.air.toml` 字段全解（v1.67 schema）

### 4.1 cr-check 的完整配置 + 逐行解读

```toml
root = "."          # 监听根目录。下面的路径都相对于它
tmp_dir = "tmp"     # 编译产物目录

[build]
  cmd = "go build -o ./tmp/cr-check ./cmd/server"

  entrypoint = [
    "./tmp/cr-check",
    "-config", "config/policy.yaml",
    "-mode", "mock",
    "-addr", ":8081",
    "-sync-eval",
  ]

  include_ext  = ["go", "yaml", "yml", "json", "tpl"]
  exclude_dir  = ["tmp", "vendor", "testdata", "deploy", "bin", ".git"]
  exclude_regex = ["_test\\.go"]
  exclude_unchanged = false

  delay = 100
  stop_on_error = false
  send_interrupt = true
  kill_delay = "500ms"

[log]
  time = true

[misc]
  clean_on_exit = true
```

### 4.2 字段说明

| 字段 | 作用 | cr-check 为什么这么配 |
|---|---|---|
| `root` | 监听根目录，所有相对路径基于它 | `"."` = 项目根 |
| `tmp_dir` | 编译产物放哪 | `tmp/`，加进 gitignore |
| `build.cmd` | **编译命令**（走 shell） | 显式 `go build`，产物路径固定 |
| `build.entrypoint` | **运行什么**（数组） | 二进制 + 完整参数，见 §5 |
| `build.include_ext` | 只盯这些扩展名 | 减少无关事件（`.yaml` 改了要重启） |
| `build.exclude_dir` | 排除目录 | ★ air 默认已含 `tmp`；但你一旦覆盖这个列表，**必须自己把 `tmp` 带上** |
| `build.exclude_regex` | 排除文件名正则 | 改 `_test.go` 不该重启服务 |
| `build.exclude_unchanged` | 内容没变就跳过 | ★ 保持 `false`，见下 |
| `build.delay` | 防抖（ms） | 编辑器保存一次可能触发多个事件（air 默认 1000） |
| `build.stop_on_error` | 编译失败时是否杀旧进程 | ★ 保持 `false`（air 默认），见下 |
| `build.send_interrupt` | 杀进程时先 SIGTERM | cr-check 有优雅关闭逻辑（air 默认 false） |
| `build.kill_delay` | SIGTERM 后等多久再强杀 | `"500ms"`（air 默认 `"0s"`） |
| `log.time` | 日志带时间戳 | 排查时方便 |
| `misc.clean_on_exit` | 退出时删 `tmp/` | 不留垃圾 |

### 4.3 ★ 三个容易踩的坑

#### 坑 1：`exclude_dir` 忘了排 `tmp` → 无限重启

```
[10:00:12] building...
[10:00:13] running...
[10:00:14] building...      ← 自己写的二进制又触发了变化
[10:00:15] running...       ← 没完没了
```

**解法**：`exclude_dir` 里必须有 `tmp`（或任何 `tmp_dir` 指向的目录）。

> ★ air 的**内置默认** `exclude_dir` 是 `assets,tmp,vendor,testdata` —— 已经含 `tmp`。
> 所以这个坑只在**你手动覆盖 exclude_dir 时忘带 tmp** 才会发生。
> cr-check 覆盖成了 `["tmp", "vendor", "testdata", "deploy", "bin", ".git"]`，`tmp` 保留。

#### 坑 2：`stop_on_error` 语义和直觉相反

官方字段注释是 **"Stop running old binary when build errors occur"**：

| 值 | 编译出错时 | 何时用 |
|---|---|---|
| `true` | **杀掉旧进程 → 服务中断** | 想让错误立刻暴露 |
| `false`（**air 默认值**） | **保留旧进程 → 服务照常可用** | 边改边验证（**推荐**） |

> ⚠️ **air 的默认值是 `false`**（`air --help` 里 `default "false"`）。
> 但 air **官方示例模板** `air_example.toml` 里**显式写成了 `true`** ——
> 很多教程直接抄那份模板，就以为「air 默认是 true」，其实不是。
>
> ⚠️ 默认的 `false` 也有隐患：改崩了代码，旧进程还在服务，
> 你可能**以为在测新代码、其实测的是旧代码**。
> 关键不是抄哪个，而是**想清楚你要哪种**：
> - 想「改崩了立刻发现」→ `true`
> - 想「改崩了服务也别断」→ `false`（且心里清楚跑的是旧代码）

#### 坑 3：`exclude_unchanged = true` 会漏重建

air 按**内容哈希**判断变更。如果你把文件**改回之前的内容**
（`git checkout`、撤销实验），air 会认为「没变」而**跳过重建** —— 你还在跑旧代码。

**保持 `false`（air 默认）最安全。**

---

## 5. `entrypoint` / `full_bin` / `args_bin` 的关系（实测）

这三个都决定「最终怎么执行你的程序」，但优先级和拼接方式不同：

| 写法 | 实际执行 | 实测输出 |
|---|---|---|
| `entrypoint = ["dump.sh", "ARG_A", "ARG_B"]` | `dump.sh ARG_A ARG_B` | `argv: dump.sh \| ARG_A ARG_B` |
| 再加 `args_bin = ["EXTRA1", "EXTRA2"]` | `dump.sh ARG_A EXTRA1 EXTRA2` | `argv: dump.sh \| ARG_A EXTRA1 EXTRA2` |
| `full_bin = "MY_ENV=1 dump.sh FROM_FULLBIN"` | `MY_ENV=1 dump.sh FROM_FULLBIN` | `argv: dump.sh \| FROM_FULLBIN` |

**规则**：

```
最终命令行 = full_bin           （如果设了，优先，且支持 ENV=值 前缀）
           否则 = entrypoint[0] + entrypoint[1:] + args_bin
```

> ★ `entrypoint` 是**数组**，没有 shell 展开：
> `"-addr", ":$PORT"` **不会生效**，端口只能写死或改配置文件。
> 要用环境变量 → 用 `full_bin`。
>
> ★ v1.67 里 `[run]` 段已被**移除**，`build.bin` 已废弃。
> 用旧写法会打印 `build.bin is deprecated` 警告，
> 且 `[run] cmd` 会被**静默忽略** —— 程序拿不到任何命令行参数。
> （这是网上老教程最常见的坑，本机第一版配置就踩了。）

---

## 6. cr-check 的两份配置

| | `.air.toml` | `.air.test.toml` |
|---|---|---|
| 用途 | 起**服务**，改代码自动重启 | 每次保存自动**跑测试** |
| `build.cmd` | `go build -o ./tmp/cr-check ./cmd/server` | `gotestsum --format testname --raw-command -- go test -race -json ./...` |
| `entrypoint` | `["./tmp/cr-check", "-config", ..., "-addr", ":8081", ...]` | `["/bin/sh", "-c", "cat tmp/test.out"]` |
| 产物 | 常驻服务进程 | 一段测试输出 |
| 启动 | `air` | `air -c .air.test.toml` |
| Makefile | `make air` | `make test-watch` |

### 为什么测试配置要用 `sh -c` 绕一层？

`go test` **不是一个常驻二进制**，air 需要一个能 exec 的目标。所以：

```toml
cmd = "gotestsum ... > tmp/test.out 2>&1; cat tmp/test.out"
entrypoint = ["/bin/sh", "-c", "cat tmp/test.out"]
```

= 「先把测试结果写进文件，再把文件内容打印出来」。

> ★ `gotestsum` v1.13 **没有 `--race` flag**（会报 `ERROR unknown flag: --race`），
> 要跑竞态检测得用 `--raw-command` 透传：
> ```bash
> gotestsum --format testname --raw-command -- go test -race -json ./...
> ```
>
> ★ 其实 `gotestsum` 自带 watch 模式，写测试时更省事：
> ```bash
> gotestsum --watch ./...
> ```
> 区别是：`gotestsum --watch` 改不了启动参数，`air` 可以。

---

## 7. 排错手册

| 症状 | 原因 | 怎么查 |
|---|---|---|
| 服务没起来，端口不通 | 没 `cd` 到项目根 → 没读到 `.air.toml` | `air -d` 看它到底执行了什么 |
| 命令行参数没生效 | 用了旧的 `[run] cmd` / `build.bin` | 看启动有无 `build.bin is deprecated` 警告 |
| 反复重启停不下来 | `tmp` 没进 `exclude_dir` | 看日志是不是刷 `building...` |
| 改了代码不重启 | `exclude_unchanged = true` + 内容改回了旧值 | 改成 `false` |
| 编译报错服务就没了 | `stop_on_error = true`（air 默认是 `false`） | 想保活就确认它是 `false` |
| 端口一直被占 | air 杀进程不彻底 | `lsof -ti :8081 \| xargs kill -9`；调大 `kill_delay` |
| 想看 air 的完整动作 | — | `air -d`（debug 模式） |
| 想知道支持哪些参数 | — | `air --help`（列出了所有字段和默认值） |
| 想要一份新配置模板 | — | `air init`（在当前目录生成 `.air.toml`） |

### 常用命令

```bash
air                    # 用 ./.air.toml 启动
air -d                 # debug 模式
air -c path/to.toml    # 指定配置文件
air --build.cmd "..."  # 临时覆盖某一项
air init               # 生成默认配置模板
air --help             # 全部字段 + 默认值
```

---

## 8. 速查：想做什么 → 写什么

| 我想… | 配置 |
|---|---|
| 改代码自动重启服务 | `build.cmd` 写 `go build`，`entrypoint` 写二进制 + 参数 |
| 改代码自动跑测试 | `build.cmd` 写 `go test ...`，`entrypoint` 写 `["/bin/sh","-c","cat 输出文件"]` |
| 改代码自动重启 + 改启动参数 | 同上，参数写在 `entrypoint` 里 |
| 用环境变量传参 | `full_bin = "MY_ENV=1 ./tmp/app --flag"` |
| 编译失败别让服务挂 | `stop_on_error = false` |
| 只监听某几种文件 | `include_ext = ["go", "yaml"]` |
| 改测试文件不重启服务 | `exclude_regex = ["_test\\.go"]` |
| 减少重复触发 | `delay = 100` |

---

## 9. 相关

- [01-local-debug.md](01-local-debug.md) —— 调试**思路**（四套方案、mock 复现、pprof、Delve）
- [03-go-toolchain.md](03-go-toolchain.md) —— 工具链**用法**（gotestsum / dlv / golangci-lint）
- [02-config-and-deploy.md](02-config-and-deploy.md) —— 配置注入与部署
