# using-make · 这个 `make` 命令是怎么来的，为什么能工作

> 面向对象：**没用过 make，或者用过但不知道它到底在干嘛**。
> 读完你应该能回答三个问题：
> 1. `make test` 背后到底发生了什么？
> 2. 这个 Makefile 的每一行为什么这么写？
> 3. 我怎么自己加一条命令？

---

## 0. 一句话结论

> **`make` 就是一个「读 Makefile → 画依赖图 → 按图执行 shell 命令」的小调度器。**
> 它自己不懂 Go、不懂测试，它只干一件事：**把你在 README 里抄来抄去的那几行命令，固化成一个个名字。**

`daydayup/Makefile` 里 12 个目标，没有一个是自己发明的算法 ——
全是 `go test ./...`、`go run ./d01` 这类原生命令，加了一层「有没有装工具」「目录里有哪些天」的判断。

---

## 1. make 的核心模型（先搞懂这个，后面都好懂）

### 1.1 三要素

一个 Makefile 里每条规则长这样：

```makefile
目标: 依赖1 依赖2
	命令1
	命令2
```

| 元素 | 含义 | 类比 |
|---|---|---|
| **目标（target）** | 一个名字，`make test` 里的 `test` | 函数名 |
| **依赖（prerequisite）** | 做这件事需要先有什么 | 函数参数 |
| **命令（recipe）** | 真正干活的 shell 命令 | 函数体 |

**关键约束：命令行必须用 Tab 缩进**（不是空格）。这是 GNU make 几十年前为了兼容 `.sh` 脚本留下的历史包袱，也是唯一一个新手 100% 会踩的坑。

```makefile
all:
    echo "用空格 → make: *** missing separator. Stop."
```

### 1.2 图 + 时间戳

make 做的事只有两步：

```
1. 读 Makefile，把所有「目标 → 依赖」关系收集起来，构成一张有向图
2. 从命令行请求的目标出发，递归检查依赖：
     依赖不存在？      → 先造它
     依赖比目标旧？    → 先更新它
     都满足？          → 目标已是最新，直接跳过
3. 按顺序执行目标的命令
```

**这套「时间戳比较」是 make 血统的来源。** make 是 1976 年为了替代 Unix 上散落的 `make.sh` 脚本而生的，
天生就是「编译 C 代码」的工具 —— 判断"要不要重新编译"靠的就是 `源文件 mtime > 目标文件 mtime`。

那对 Go 项目来说时间戳毫无意义（Go 自己有 build cache），所以这份 Makefile **几乎所有目标都声明成 `.PHONY`**，
等于告诉 make："这些目标没有对应文件，每次都给我跑"。

### 1.3 `.PHONY`：本项目最重要的一个词

```makefile
.PHONY: help list stats today test watch test-watch cover fmt vet lint run new clean
```

`.PHONY` 声明的目���，make **永远执行**它的命令，不管目录里有没有同名文件。

对比一下实测结果：

```bash
$ cat Makefile          # 没有 .PHONY
test:
	@echo "ran"

$ touch test            # 目录里有个叫 test 的文件
$ make test
make: `test' is up to date.      ← 什么都没干！

$ cat Makefile          # 有 .PHONY
.PHONY: test
test:
	@echo "ran"

$ make test
ran                            ← 正常执行
```

> **踩坑预警**：任何时候你写了一个叫 `test` / `all` / `clean` / `install` 的目标，
> 都要记得 `.PHONY`。目录里哪天多了一个叫 `test` 的文件，`make test` 就会静默不干活 —— 这种 bug 极难查。

---

## 2. 这个 Makefile 是怎么"长"出来的

它不是一次拍脑袋写出来的，是从 `cr-check/Makefile`（同仓库的真实项目）**抄骨架 + 按本地场景改造**的。
演进路径大致是：

```
第 1 步：把 README 里的命令抄成目标
        test  → go test ./...
        vet   → go vet ./...
        fmt   → gofmt -w .

第 2 步：把「可能不存在的工具」做成软依赖
        装了 gotestsum → 用它（彩色输出）
        没装         → 退回 go test
        ★ 这就是 ifeq 的用武之地

第 3 步：把「跟目录内容有关」的东西做成动态的
        有了 d01 d02 d03 → make list 自动列出来
        ★ 这就是 $(wildcard) 的用武之地

第 4 步：加「友好的默认值」
        敲 make 不带参数 → 显示 help 而不是报错
        ★ 这就是 .DEFAULT_GOAL

第 5 步：加「兜底 + 静默吞掉多余目标」
        make new slices → slices 不该报错
        ★ 这就是 % 模式规则
```

`cr-check/Makefile` 的骨架可以对照看：
[`../cr-check/Makefile`](../cr-check/Makefile)（`?=` 变量、`.PHONY`、`## ` 注释约定一脉相承）。

---

## 3. 逐段拆解 `daydayup/Makefile`

### 3.1 变量层：把"工具名"抽出来

```makefile
GO          ?= go
GOTESTSUM   ?= $(shell command -v gotestsum 2>/dev/null)
GOFMT       ?= gofmt
GOIMPORTS   ?= $(shell command -v goimports 2>/dev/null)
```

| 写法 | 含义 | 本例效果 |
|---|---|---|
| `=` | 递归展开（用到的最后一次才计算） | — |
| `:=` | **立即展开**（读到这一行就计算一次） | — |
| `?=` | **只有未定义时才赋值** | 外部可以覆盖 |
| `+=` | 追加 | — |

`?=` 的价值：**不用改 Makefile 就能换工具**。

```bash
$ make test GOTESTSUM=/path/to/my-wrapper
$ make test GO=go1.27.3
```

`$(shell ...)` 是 make 内置函数：**执行一条 shell 命令，把 stdout 抓回来当字符串**。
`command -v gotestsum` 就是"这东西在 PATH 里吗"，在就打印路径，不在就打印空 + 返回非 0，
`2>/dev/null` 把 stderr 吞掉。

> ★ **一个隐藏的性能细节**：`?=` 产生的是**递归变量**，所以 `$(shell command -v gotestsum)`
> **每次被引用都会重新执行一遍**。实测这份 Makefile：
>
> ```bash
> $ make test     → gotestsum 被探测 3 次
> $ make help     → 被探测 2 次
> ```
>
> 2 次是因为 **`ifeq` 是在解析 Makefile 时求值的，不管你这次要跑哪个目标** ——
> `test` 和 `watch` 两个块里的 `ifeq` 每次都会执行。第 3 次是 recipe 里真正用它那次。
>
> 改成 `:=` 就只探测 1 次。几毫秒的差别，但**这是理解「make 的两阶段」的关键证据**：
> **解析阶段**（读文件、算变量、选分支）vs **执行阶段**（跑命令）。

### 3.2 动态发现：有哪些天？

```makefile
DAYS := $(sort $(notdir $(wildcard d[0-9][0-9])))
```

拆成三步：

| 片段 | 作用 |
|---|---|
| `$(wildcard d[0-9][0-9])` | 在当前目录做 glob 匹配，返回 `d01 d02 d03`（不存在就返回空） |
| `$(notdir ...)` | 去掉目录部分，只留文件名（这里其实多余，wildcard 本来就不带路径） |
| `$(sort ...)` | **排序 + 去重**，得到 `d01 d02 d03` |
| `:=` | 立即求值 —— 读 Makefile 时就算一次，不是每次用的时候算 |

结果实测：

```bash
$ make -p -n help | grep ^DAYS
DAYS := d01 d02
```

> 用 `:=` 而不是 `=` 是**故意的**：DAYS 只依赖目录内容，在一次 make 运行内它不会变，
> 没必要反复 glob。**用 `:=` 是"这个值稳定"的一种表达。**
>
> 注意 `sort` 是**字典序**：`d10` 会排在 `d09` 后面 —— 但因为目录名是**两位补零**的，
> 字典序恰好等于数值序，所以 `$(lastword $(DAYS))` 拿到的就是"最新的一天"。
> 哪天要是改成 `d1 d2 d10`，`today` 就会错。

### 3.3 默认目标和声明

```makefile
.DEFAULT_GOAL := help

.PHONY: help list stats today test watch test-watch cover fmt vet lint run new clean
```

`.DEFAULT_GOAL := help` 的作用：敲 `make`（不带参数）时执行 `help`。
不加的话 make 会跑**Makefile 里出现的第一个目标** —— 这里恰好也是 `help`，但换个顺序就会翻车。

### 3.4 条件分支：工具在不在？

这是整份 Makefile 最核心的技巧，四处用到：

```makefile
test: ## 跑全部测试
ifeq ($(GOTESTSUM),)
	@$(GO) test ./...
else
	@$(GOTESTSUM) --format testname -- ./...
endif
```

**`ifeq` 是 make 的条件编译，不是 shell 的 `if`。** 它在**解析阶段**判断，
决定**哪一段命令会被收录进这个目标**。运行 `make test` 时，被执行的是二选一的那一段，不是"运行时再判断"。

```bash
$ make test                       # 装了 gotestsum
/Users/lex/go/bin/gotestsum --format testname -- ./...

$ PATH=/usr/bin:/bin make -n test  # 假装没装
go test ./...                      ← 降级成功
```

四种条件写法：

| 写法 | 含义 |
|---|---|
| `ifeq (a,b)` | a == b |
| `ifneq (a,b)` | a != b |
| `ifdef VAR` | VAR 已定义（且非空） |
| `ifndef VAR` | VAR 未定义 |

配套的还有 `else` / `endif`。

### 3.5 逐个目标在干什么

| 目标 | 干什么 | 值得注意的点 |
|---|---|---|
| `help` | 打印所有命令 | 里面嵌了 `$(DAYS)`，所以帮助信息里会显示"可选：d01 d02" |
| `list` | 列出每天的目录 + 对应笔记 + go 文件数 | **纯 shell 循环**，`for d in $(DAYS); do ... done` |
| `stats` | 天数 / 笔记数 / 测试数 / 代码行数 | 用 `grep -rho '^func Test...'` 数测试函数 |
| `today` | 跑最后一天的示例 + 测试 | `$(lastword $(DAYS))` 取最新 |
| `test` | 跑全部测试 | `ifeq` 双分支；有 gotestsum 用彩色 |
| `watch` | 保存文件自动重跑 | `gotestsum --watch`，靠文件变更触发 |
| `test-watch` | 同上，但走 air | 和 `cr-check` 保持同一个肌肉记忆 |
| `cover` | 覆盖率 | `go test -coverprofile` + `go tool cover -func` |
| `run` | 跑某天示例 | **需要参数** `make run DAY=d01`，用 `ifeq ($(DAY),)` 检查 |
| `fmt` | 格式化 | 有 goimports 用 goimports，否则 gofmt |
| `vet` | 静态检查 | 直接 `go vet ./...` |
| `lint` | golangci-lint | 先 `command -v` 检查，**没有就明确报错退出**，而不是装个空气 |
| `new` | 生成下一天 | 主题可以从 `MAKECMDGOALS` 里捞，见 3.6 |
| `clean` | 清理 `cov.out` / `tmp` / `bin` | — |

`run` 是最典型的"带参数的目标"：

```makefile
run: ## 跑某一天的示例: make run DAY=d01
ifeq ($(DAY),)
	@echo "用法: make run DAY=d01   （可选: $(DAYS)）"
	@exit 1
endif
	@$(GO) run ./$(DAY)
```

`DAY` 是**外部传进来的变量**（命令行 `DAY=d01` 或环境变量）。
`$(origin DAY)` 能告诉你它从哪来：

| `$(origin X)` | 含义 | 优先级 |
|---|---|---|
| `undefined` | 没定义 | 最低 |
| `environment` | 来自环境变量 | |
| `file` | 来自 Makefile | |
| `command line` | 来自 `make X=v` | **最高** |

实测：

```bash
$ make run DAY=d01      → origin(DAY) = command line
$ make run              → 提示用法，exit 1
```

### 3.6 `%` 模式规则：把多余的参数"吃掉"

```makefile
%:
	@if [ "$(words $(MAKECMDGOALS))" -gt 1 ] && echo "$(MAKECMDGOALS)" | grep -qw "$(firstword $(MAKECMDGOALS))"; then \
		exit 0; \
	else \
		echo "✗ 未知目标: $@"; \
		echo "  跑 'make help' 看可用命令"; \
		exit 1; \
	fi
```

`%` 是 make 的**模式规则**（pattern rule）："任何还没定义的目标，都用我的命令"。

它的作用是**同时干两件相反的事**：

| 场景 | 期望行为 | 机制 |
|---|---|---|
| `make foobar`（打错字） | 报错，告诉我用 `make help` | `$(words $(MAKECMDGOALS))` = 1，走 else 分支 |
| `make new slices`（主题是参数） | 别把 `slices` 当成目标报错 | words = 2，走 then 分支，静默 `exit 0` |

而 `new` 目标自己从 `MAKECMDGOALS` 里把主题捞出来：

```makefile
new: ## 生成下一天: make new slices   或   make new TOPIC="slice 与 append"
	@topic="$(TOPIC)"; \
	if [ -z "$$topic" ]; then \
		for g in $(MAKECMDGOALS); do \
			case "$$g" in new|-*) ;; *) topic="$$g";; esac; \
		done; \
	fi; \
	./scripts/newday.sh "$$topic"
```

`$(MAKECMDGOALS)` = "**这次命令行上要求的所有目标**"，空格分隔。
`make new slices` 时它是 `new slices`，循环里跳过 `new`（和以 `-` 开头的选项），剩下的 `slices` 就是主题。

实测：

```bash
$ make new slices
✅ 建好了：
   d03/main.go
   d03/main_test.go
   md/03-slices.md

$ make new TOPIC="slice 与 append"    # 主题带空格时用这个
```

> **两个小坑**（都实测过）：
> 1. `make new slices extra` → 主题取**最后一个** `extra`（循环没有 break）。
> 2. `make foobar baz` → **静默成功，退出码 0**，什么提示都没有。
>    因为 `$(words ...)` = 2 就走 then 分支了。这是这套兜底逻辑的副作用，知道就行。

### 3.7 `%` 规则不是万能的：文件存在就跳过

```bash
$ touch slices && make slices
make: `slices' is up to date.        ← 因为 slices 是个真实文件

$ make d01
make: `d01' is up to date.           ← d01 是真实目录
```

**模式规则只在目标不对应真实文件时才应用。** 真实文件优先。

---

## 4. 语法速查表

| 语法 | 含义 | 坑 |
|---|---|---|
| `目标: 依赖` | 规则头 | 冒号后必须有空格才有意义 |
| **Tab** | 命令行缩进 | **用空格 = `missing separator`** |
| `$(VAR)` / `${VAR}` | 引用变量 | 两种都行 |
| `$(shell cmd)` | 执行 shell 抓 stdout | 每次引用都重跑 |
| `$(wildcard pat)` | glob 匹配 | 找不到返回空 |
| `$(sort ...)` | 排序 + 去重 | 字典序，不是数值序 |
| `$(notdir ...)` | 去掉目录部分 | — |
| `$(dir ...)` | 只留目录部分 | — |
| `$(words n)` | 列表里有几个词 | `$(words a b c)` = 3 |
| `$(firstword ...)` / `$(lastword ...)` | 首 / 末一个 | — |
| `$(origin VAR)` | 变量从哪来 | 见 3.5 |
| `$(MAKECMDGOALS)` | 命令行上要的目标 | 多目标时用得上 |
| `$(MAKEFILE_LIST)` | 读过的 Makefile 列表 | 做自动 help 的常见手法 |
| `$(CURDIR)` | 当前目录绝对路径 | 拼路径用 |
| `$(MAKE_VERSION)` | make 版本 | 3.81 / 4.x 行为有差异 |
| `$$` | 转义成字面 `$` 给 shell | `$$d` → shell 里的 `$d` |
| `@` 前缀 | 不回显这条命令 | 几乎所有目标都用了 |
| `-` 前缀 | 忽略这条命令的错误 | `-false` 之后还会继续跑 |
| `\` 行尾 | 续行 | 几行 shell 合成**一个** shell 进程 |
| `.PHONY: a b c` | 声明伪目标 | **本项目必写** |
| `.DEFAULT_GOAL := x` | 无参时的默认目标 | — |
| `include other.mk` | 引入另一个 Makefile | — |

### 4.1 三个必须记住的执行语义

**① 每行 recipe 是一个独立的 shell 进程。**

```makefile
multi:
	@echo "line1: $HOME"
	@echo "line2: $HOME"
```

`line1` 和 `line2` 是**两个不同的 shell**，但因为都是 `sh -c` 单条命令，环境变量照常传递，
看不出差别。真正的差别出现在 **`cd` / `export` 这类"改变 shell 状态"的操作**：

```makefile
bad:
	cd /tmp
	ls            # ← 这是另一个 shell，还在原目录！
```

**要跨行保持状态，用 `\` 续行把它变成一条命令**：

```makefile
good:
	cd /tmp && \
	ls
```

本项目的 `list` / `stats` / `new` 全用了续行 —— 那些 `for` 循环**必须**是一个 shell 才能跑。

**② `@` 只是不回显，不影响执行。** make 默认会把每条命令原样打出来，`@` 把它藏起来。
（本项目的 `make -n` 之所以还能看到内容，就是因为 `-n` 会无视 `@` 打印所有命令。）

**③ `$$` 是给 shell 的 `$`。** make 看到 `$$` 才会把它还原成 `$`。
本项目里 `for g in $(MAKECMDGOALS)` 循环体里的 `$$g`、`$$topic` 全是这个意思。

---

## 5. 为什么它"能工作" —— 两层验证

### 5.1 make 层：它到底做了什么

用 `make --debug=v` 可以看 make 的思考过程：

```bash
$ make --debug=v test
Considering target file `test'.
 File `test' does not exist.
 Finished prerequisites of target file `test'.
Must remake target `test'.
/Users/lex/go/bin/gotestsum --format testname -- ./...
Successfully remade target file `test'.
```

**`test` 这个文件不存在 → 必须造它 → 执行 recipe → 造好了。**
就这么简单。`.PHONY` 的作用是把 "File `test' does not exist" 变成永远成立。

### 5.2 Go 层：命令本身为什么有效

| 命令 | 依赖的 Go 机制 |
|---|---|
| `go test ./...` | `./...` 是**包模式**，匹配当前模块下所有子目录里的包。`d01` `d02` 各自是独立 package，自动全跑 |
| `go run ./d01` | `./d01` 是**目录**形式的包路径，等价于 `go run d01/main.go`，但会带上同目录的其它文件 |
| `go test -count=1` | 关掉测试缓存（Go 默认缓存测试结果，会"假绿"） |
| `go test -coverprofile=cov.out` | 生成覆盖率数据文件 |

**为什么 `d01` 和 `d02` 能各自 `package main` 而不冲突？**
因为 Go 的规则是**一个目录 = 一个包**。两个目录 = 两个互不相干的包，各自一个 `main()` 完全合法。

```bash
$ go list ./...
daydayup/d01
daydayup/d02
```

**为什么 `go run ./d01` 不会把 d02 也带上？**
因为 `./d01` 精确指定了一个目录 = 一个包。

### 5.3 工具层：watch 是怎么"自动重跑"的

| 工具 | 机制 |
|---|---|
| `gotestsum --watch` | 监听文件变化 → 重跑 `go test` |
| `air -c .air.test.toml` | 监听文件变化 → 执行 `build.cmd` → 输出到 `tmp/test.out` |

`.air.test.toml` 里有个很有意思的细节：

```toml
cmd = "gotestsum ... -- go test -count=1 -json ./... > tmp/test.out 2>&1; cat tmp/test.out"
```

**结尾的 `cat` 是必须的。** air 只看 `build.cmd` 的**退出码**，
而 `go test` 失败时退出码非 0 → air 会以为"构建失败"而中断。
`cat` 永远返回 0，把退出码"洗"成成功，测试结果照样从 `tmp/test.out` 打出来。

---

## 6. 可复现实验（8 个，建议自己敲一遍）

### 实验 1：干跑，看 make 到底要执行什么

```bash
$ make -n test
/Users/lex/go/bin/gotestsum --format testname -- ./...
```

`-n` = dry run，只打印不执行。**改 Makefile 时先用这个。**

### 实验 2：导出 make 的整个内部数据库

```bash
$ make -p -n help | grep -E "^(DAYS|GO|GOTESTSUM) "
GOTESTSUM = $(shell command -v gotestsum 2>/dev/null)
GO = go
DAYS := d01 d02
```

注意 `GOTESTSUM = $(shell ...)` 前面是 `=`（递归），`DAYS :=` 是 `:=`（立即）——
`-p` 把这个区别直接打给你看。

### 实验 3：看 make 的决策过程

```bash
$ make --debug=v test
$ make --debug=b test      # 只看基础信息，更清爽
```

### 实验 4：验证 `?=` 能被覆盖

```bash
$ make test GOTESTSUM=echo gotestsum
$ make test GO=/opt/homebrew/bin/go
$ make test GOTESTSUM=      # 空值 → 强制走 go test 分支
```

### 实验 5：验证 `.PHONY` 的必要性

```bash
$ touch test && make test      # → make: `test' is up to date.（什么都不干）
$ rm test
```

### 实验 6：验证 `ifeq` 在解析阶段执行

```bash
$ make -n help                # help 里根本没提 GOTESTSUM
# 但 gotestsum 仍被探测了 2 次 —— 两个 ifeq 块在解析时就执行了
```

### 实验 7：观察 `$(MAKECMDGOALS)`

```bash
$ make -n new slices | head -3
topic=""; \
	if [ -z "$topic" ]; then \
		for g in new slices; do \
```

### 实验 8：制造一个"打错字"的目标

```bash
$ make testt
✗ 未知目标: testt
  跑 'make help' 看可用命令
make: *** [testt] Error 1
```

### 附：常用调试开关

| 开关 | 作用 |
|---|---|
| `make -n` | dry run，只打印不执行 |
| `make -p` | 打印内部数据库（变量、规则、隐式规则） |
| `make --debug=v` | 打印完整决策过程 |
| `make --debug=b` | 打印基础决策信息 |
| `make -t` | 不执行命令，只把目标当"已是最新"（本项目全是 .PHONY，实际等于什么都不做） |
| `make -j4` | 4 个并行任务（**本项目别乱用**，有顺序依赖） |
| `make -C dir` | 在 `dir` 目录下执行 |
| `make -f file` | 用指定文件当 Makefile |
| `make --warn-undefined-variables` | 用了没定义的变量时警告 |

---

## 7. 踩坑清单

| 坑 | 症状 | 解法 |
|---|---|---|
| 命令行用空格缩进 | `make: *** missing separator. Stop.` | **必须 Tab** |
| 忘了 `.PHONY` | 目录里有个同名文件 → `make xxx` 静默不干活 | `.PHONY: xxx` |
| `$$` 写成 `$` | shell 拿到空变量，循环里全空 | `$$g` |
| 多行 shell 忘了续行 | `for` 循环第一行就结束 | 行尾加 `\` |
| 期望运行时才判断，写成 shell `if` | make 层做不到 | 用 `ifeq`（解析期选分支） |
| `?=` 的 `$(shell)` 重复执行 | 每次引用都跑一遍探测 | 稳定值用 `:=` |
| `sort` 是字典序 | `d10` 排在 `d09` 前 | 目录名补零 |
| 目标名和真实文件撞名 | 模式规则不生效 | 确认目标不是真实文件 |

---

## 8. 我想加一条命令，怎么加？

三步：

**① 写目标 + 加 `.PHONY`**

```makefile
.PHONY: ... bench          # ← 加进 .PHONY 列表

bench: ## 跑基准测试
	@$(GO) test -bench ./...
```

**② 写 `## 说明`** —— 本项目所有目标都有这个注释，是给人看的。

**③ 想让别人能覆盖的东西，用 `?=` 变量**

```makefile
BENCHTIME ?= 1s
bench:
	@$(GO) test -bench=.$(BENCHTIME) ./...
```

```bash
$ make bench BENCHTIME=10s
```

**验证**：

```bash
$ make -n bench      # 先干跑看看
$ make bench
```

> 注意 `## 说明` 这套约定在本项目里**只是注释**（不像 `cr-check/Makefile` 那样用 `grep` 自动生成 help）。
> 想抄那个更省事的做法，去看
> [`../cr-check/Makefile`](../cr-check/Makefile) 里的 `help:` 目标。

---

## 9. 速查：make vs 常用替代品

| 工具 | 适合 | 不适合 |
|---|---|---|
| **Make** | 固化命令、参数化、环境探测、跨平台 | 复杂的条件逻辑、真正的依赖分析 |
| **npm scripts** | 前端项目 | 非 JS 生态 |
| **just** | Make 的现代替代，语法更干净 | 生态小、没人熟 |
| **Taskfile** | YAML 写任务 | 同样生态小 |
| **纯 shell 脚本** | 逻辑复杂时其实更好写 | 参数化、帮助信息难做 |

> 本项目选 make 的理由很朴素：**README 里那十几条命令，全是"输入名字 → 跑一条 shell 命令"**，
> 这正是 make 最擅长的事。而且它已经在 cr-check 里用顺手了，保持肌肉记忆。

---

## 10. 一页纸总结

```
make 做的事：
  读 Makefile → 画「目标 → 依赖」图 → 检查时间戳 → 跑 shell 命令

这份 Makefile 的四层设计：
  1. 变量层    GO / GOTESTSUM / GOFMT / GOIMPORTS   ← ?= 可被外部覆盖
  2. 发现层    DAYS := $(sort $(wildcard d[0-9][0-9])) ← 自动认出有哪些天
  3. 条件层    ifeq ... else ... endif                 ← 工具在不在，优雅降级
  4. 执行层    12 个 .PHONY 目标 + % 兜底规则          ← 名字 → 命令

三条必须记住的语义：
  · 命令行必须 Tab 缩进
  · 条件在「解析阶段」求值，不在运行阶段
  · 每行 recipe 一个独立 shell，跨行状态用 \ 续行

为什么它真的有用：
  因为它把你每次都要手敲、而且会敲错的那行命令，
  变成了一个不会忘、不会敲错、还能被别人 `--help` 出来的名字。
```

---

## 相关

- [`../cr-check/Makefile`](../cr-check/Makefile) —— 真实项目里的同一套写法
- [`../base/17-modules-build.md`](../base/17-modules-build.md) —— Go 工程化：go.mod + Makefile + Dockerfile
- [`../base/practice/03-go-toolchain.md`](../base/practice/03-go-toolchain.md) —— 工具链手册（air / gotestsum / golangci-lint）
- [`../base/practice/air.md`](../base/practice/air.md) —— air 专题
- [GNU Make 手册](https://www.gnu.org/software/make/manual/make.html) —— 权威出处

*最后更新：2026-11-11*
