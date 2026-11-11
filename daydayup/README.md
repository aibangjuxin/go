# daydayup · 每天学一点 Go

> **目标**：每天 10 分钟，掌握一个 Go 小技巧。
> 攒够 30 天之后，能独立读懂 [`cr-check`](../cr-check) 的代码，并且敢自己改。

---

## 这是什么

一个**自学的练习场**，不是课程，不是教程。

| | 干什么 | 怎么用 |
|---|---|---|
| [`../base`](../base) | **读文档学概念** —— 例子全部来自 cr-check 真实项目 | 当地图，遇到不懂的名词去查 |
| [`../base/practice`](../base/practice) | **工程实践** —— 调试、部署、工具链 | 干活时翻 |
| **`daydayup/`（本目录）** | **动手写 + 写测试** —— 每天 10 行代码 | 当健身房，每天打卡 |

一句话区别：**`base/` 告诉你"Go 长这样"，`daydayup/` 逼你"自己写一遍"。**

---

## 快速开始

```bash
cd /Users/lex/git/go/daydayup

make list               # 看已经学了几天
make run DAY=d01        # 跑第 1 天的示例程序
make test               # 跑全部测试
make watch              # 保存文件自动重跑测试 ← 写练习时开这个
make new slices         # 生成下一天（代码 + 文档 + 自动更新索引）
```

第一次用，建议按这个顺序走一遍：

```bash
make list               # 1. 看看现状
make run DAY=d01        # 2. 跑一下已有代码
make test               # 3. 看测试长什么样
vim md/01-go-basics.md  # 4. 读今天的笔记
```

---

## 目录结构

```
daydayup/
├── README.md            ← 你在这里（使用说明）
├── go.mod               ← 独立模块（module daydayup）
├── Makefile             ← 把常用命令固化成 make xxx
├── .gitignore
│
├── md/                  ← 📄 文档和资料
│   ├── README.md        ←   学习地图 / 进度索引 / 接下来学什么
│   ├── 01-go-basics.md  ←   Day 1：Go 长什么样
│   ├── 02-variables.md  ←   Day 2：变量声明 + 零值
│   └── 03-xxx.md        ←   ……
│
├── d01/                 ← Day 1 的代码
│   ├── main.go          ←   可运行的示例
│   └── main_test.go     ←   配套测试（断言今天学的技巧）
├── d02/
│   ├── main.go
│   └── main_test.go
│
└── scripts/
    └── newday.sh        ← 一键生成下一天的骨架
```

### 为什么每天一个目录 `dNN/`？

Go 里**一个目录只能有一个 `package main` 的 `func main()`**。
把所有天的代码堆在一个目录里，第三天就会炸：

```
main redeclared in this block
```

所以每天独立成目录，`d01/` `d02/` 各有各的 `main()`，互不干扰：

```bash
go run ./d01     # ✅
go run ./d02     # ✅
go run .         # ❌ 根目录没有 main 包
go test ./...    # ✅ 一次跑完所有天
```

### 为什么 `md/` 和 `dNN/` 分开放？

代码和笔记的**生命周期不一样**：
代码是"能跑就留着"，笔记是"要反复翻、反复改"。
分开放以后，`md/` 就是一本纯手册，可以顺序读、可以跳着读、不会跟一堆 `.go` 文件混在一起。

约定：**`dNN/` ↔ `md/NN-xxx.md`**，编号对齐，一眼能找到配套代码。

### 为什么每个技巧都要写测试？

```go
// d02/main_test.go
func TestZeroValue(t *testing.T) {
	var (
		s string
		i int
		b bool
	)
	if s != "" || i != 0 || b != false {
		t.Errorf("零值不对: %q %d %v", s, i, b)
	}
}
```

**「会写」和「知道自己写对了」是两件事。**
写完不跑测试，你永远不知道自己是不是理解对了 —— 尤其是 Go 这种"不报错但行为不同"的坑很多（比如切片共享底层数组、map 遍历顺序随机、闭包捕获变量）。

把知识点变成断言，就再也不会"以为懂了"。

---

## 每天的流程（10 分钟）

```
1. 看    读 md/README.md 的「之后可以学的」，挑一个主题
2. 建    make new <主题>     → 自动生成代码骨架 + 文档骨架 + 索引
3. 写    dNN/main.go         → 写今天练手的代码
         dNN/main_test.go    → 写断言，把技巧钉死
4. 记    md/NN-xxx.md        → 记「坑」和「一句话总结」
5. 跑    make test           → 全绿才算过
```

第 4 步最容易偷懒，但**它才是让笔记变值钱的步骤**。
半年后你翻自己的"坑表"，比翻官方文档有用得多。

---

## 命令速查

| 命令 | 作用 |
|---|---|
| `make help` | 看所有命令 |
| `make list` | 列出已有的天 + 对应文档 |
| `make run DAY=d01` | 跑某天的示例程序 |
| `make test` | 跑全部测试（有 gotestsum 就彩色输出，没装自动退回 `go test`） |
| `make watch` | 保存文件自动重跑测试 |
| `make cover` | 跑测试 + 覆盖率（生成 `cov.out`） |
| `make new slices` | 生成下一天 |
| `make new TOPIC="slice 与 append"` | 生成下一天（主题带空格时用这个） |
| `make fmt` | 格式化（优先用 goimports，没有则 gofmt） |
| `make vet` | `go vet` 静态检查 |
| `make lint` | `golangci-lint` 静态检查 |
| `make clean` | 清理临时产物 |

### 不用 make 的原生命令

```bash
go run ./d01                            # 跑某天
go test ./...                           # 跑全部测试
go test -v ./d02/                       # verbose，看到每个用例名
go test -race ./...                     # ★ 竞态检测（写并发时必开）
go test -count=1 ./...                  # ★ 跳过缓存强制重跑（怀疑结果假绿时）
go test -coverprofile=cov.out ./... && go tool cover -html=cov.out

gotestsum --format testname -- ./...    # 彩色 + 压缩输出
gotestsum --watch --format testname -- ./...   # 保存即重跑
```

### 推荐的小习惯

- **写代码时开 `make watch`** —— 另开一个终端，保存就看到测试结果，循环缩到 1 秒
- **怀疑结果时加 `-count=1`** —— Go 的测试有缓存，"假绿"过一次就记住了
- **提交前 `make fmt vet test`** —— 三秒搞定

---

## 常见问题

<details>
<summary><b>Q: 提示 <code>go: cannot find main module</code></b></summary>

没在 `daydayup/` 目录下跑。`go.mod` 在这里，`cd` 进来再跑。
</details>

<details>
<summary><b>Q: 提示 <code>main redeclared in this block</code></b></summary>

同一个目录里有两个 `func main()`。规矩是**一个目录一个 `main()`**，
所以每天的代码必须在 `dNN/` 独立目录里。
</details>

<details>
<summary><b>Q: 提示 <code>declared and not used: x</code></b></summary>

Go 的强制规则：变量声明了必须用。确实不需要就 `_ = x` 丢掉。
</details>

<details>
<summary><b>Q: <code>go run 1.go</code> 和 <code>go run ./d01</code> 有什么区别？</b></summary>

前者只能跑单个文件、且该文件必须自带 `package` 和 `func main()`；
后者跑整个包（目录），可以拆成多个文件，还能顺手带上 `main_test.go`。
**日常用 `go run ./dNN` 或 `make run DAY=dNN`。**
</details>

<details>
<summary><b>Q: 主题是中文，生成的文档文件名难看？</b></summary>

`make new TOPIC="slice 与 append"` 会生成 `md/NN-slice-append.md`。
纯中文主题会回退成 `md/NN-topic.md`，不影响使用。
</details>

<details>
<summary><b>Q: 我想把整个目录提交到 git</b></summary>

`daydayup/` 目前还没被 git 跟踪。提交前先看一眼 `.gitignore`（已忽略 `bin/` `tmp/` `cov.out`）。
</details>

---

## 学习路线

`md/README.md` 里有一张按易到难排的表，够用 30 天：

| 阶段 | 主题 | 解决的问题 |
|---|---|---|
| **基础** | Slice vs Array | `append` 到底发生了什么？切片为什么会共享底层数组？ |
| | Map | 为什么遍历顺序是随机的？ |
| | Struct & Method | 值接收者 vs 指针接收者，什么时候必须用指针？ |
| | Interface | 为什么 Go 不需要 `implements`？隐式接口怎么实现？ |
| **工程** | Error | 为什么没有 try/catch？`errors.Is` / `errors.As` 怎么用？ |
| | Defer | 资源释放的推荐写法，`defer` 在什么时候求值？ |
| | Goroutine & Channel | `go func()` 起了什么，`select` 怎么选？ |
| | Context | 取消信号怎么一路传下去？ |
| | Testing | 表驱动测试、fake、`-race` 到底在查什么？ |

学完前 5 个，cr-check 的 `internal/rules` 应该就能读顺了。

---

## 相关

- [`../base/00-index.md`](../base/00-index.md) —— Go 核心概念速查（基于 cr-check）
- [`../base/practice/03-go-toolchain.md`](../base/practice/03-go-toolchain.md) —— 工具链手册（air / dlv / gotestsum / golangci-lint）
- [`../cr-check/README.md`](../cr-check/README.md) —— 真实项目

---

*最后更新：2026-11-11*
