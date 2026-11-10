# Go 核心概念速查（基于 cr-check 项目）

> 这组文档全部用 `/Users/lex/git/go/cr-check` 这个真实项目做例子。
> 每读一个概念，都可以直接打开对应文件对照看。

---

## 0. cr-check 是什么

一句话：**一个用 Go 写的 GitHub App 后端服务**，接收 GitHub 的 PR 事件，
去内部「变更单（CR）平台」查这张 PR 关联的变更单是否合规，
然后把结论写回 GitHub 的 Check Run（required status check）。

```
GitHub  ──webhook──▶  cmd/server/main.go
                         │
                         ├─ internal/webhook     接收 + 验签 + 幂等
                         ├─ internal/rules       判定引擎（R1~R7）
                         ├─ internal/crplatform  查变更单（HTTP / Mock）
                         ├─ internal/check       写 Check Run（日志 / GitHub）
                         ├─ internal/queue       幂等存储 + 异步队列
                         ├─ internal/recheck     定时重扫
                         ├─ internal/audit       审计留痕
                         ├─ internal/observability  Prometheus 指标
                         ├─ internal/config      加载 policy.yaml
                         └─ internal/gh          GitHub App client 工厂
```

## 1. 项目结构 = Go 项目结构

```
cr-check/
├── cmd/server/main.go     ← 程序入口（main 包只有这一个）
├── internal/              ← 内部包，外部项目不能 import
│   ├── webhook/
│   ├── rules/
│   └── ...
├── config/policy.yaml     ← 配置文件
├── deploy/                ← k8s 部署清单
└── go.mod                 ← 依赖声明（module github.com/acme/cr-check）
```

Go 的约定：

| 目录 | 约定 |
|---|---|
| `cmd/<name>/` | 每个子目录一个可执行程序，`package main` |
| `internal/` | 内部实现，不对外暴露 |
| 顶层包名 | 一般和目录同名（`internal/rules` → `package rules`） |
| 导入路径 | `module 名 + 目录`，所以是 `github.com/acme/cr-check/internal/rules` |

> ⚠️ Go 没有"包内私有 / 包外公开"这种 Java 式的修饰符。
> 规矩是：**首字母大写 = 导出（外部可见），首字母小写 = 不导出（仅本包可见）**。
> 例子：`crplatform.Client`（大写，导出）、`crplatform.normalizeStatus`（小写，私有）。

---

## 2. 学习地图

| # | 文档 | 一句话 | 在 cr-check 里的对应物 |
|---|---|---|---|
| 1 | [01-struct.md](01-struct.md) | Struct：把相关数据打包成一个类型 | `crplatform.ChangeRequest`、`rules.PRInfo` |
| 2 | [02-method.md](02-method.md) | Method：给类型挂上行为 | `(o Outcome) Conclusion()`、`(e *Engine) Evaluate()` |
| 3 | [03-interface.md](03-interface.md) | Interface：只描述"能做什么"，用鸭子类型隐式实现 | `crplatform.Client`、`check.Writer`、`queue.Store` |
| 4 | [04-constructor.md](04-constructor.md) | Constructor：`NewXxx()` 负责初始化与校验 | `NewHTTPClient`、`NewEngine`、`NewLogWriter` |
| 5 | [05-dependency-injection.md](05-dependency-injection.md) | 依赖注入：把依赖当参数传进来，而不是内部 new | `main.go` 的"依赖组装"段 + `webhook.Handler` 的字段 |
| 6 | [06-factory.md](06-factory.md) | 工厂：需要"运行时才知道用哪个实现"时用 | `gh.Factory`（按 installation_id 缓存 client） |
| 7 | [07-context.md](07-context.md) | Context：跨调用传值 + 取消信号 + 超时 | `ctx` 一路穿过 handler → client → HTTP 请求 |
| 8 | [newclient.md](newclient.md) | （已读）构造函数模式的通用介绍 | — |

**建议顺序**：struct → method → interface → constructor → DI → factory → context。
前三者是最基础的地基，interface 是 Go 的灵魂，后四个是工程惯例。

---

## 3. 跑起来看看（顺便认识工具链）

```bash
cd /Users/lex/git/go/cr-check

make run          # = go run ./cmd/server -config config/policy.yaml -mode mock -addr :8080 -sync-eval
make test         # go test -race -cover ./...
make vet          # go vet ./...   官方静态检查
make fmt          # gofmt -w .     格式化
make build        # 编译到 bin/cr-check
```

curl 试一下：

```bash
curl -s -X POST http://localhost:8080/github/webhook \
  -H 'X-GitHub-Event: pull_request' \
  -H 'X-GitHub-Delivery: demo-1' \
  -H 'Content-Type: application/json' \
  --data @testdata/pr-event.json | jq
```

四个 Go 常用命令记住就够：

```bash
go build ./...        # 编译
go run ./cmd/server   # 跑起来
go test ./...         # 跑测试
go vet ./...          # 静态检查
go doc <包>.<符号>    # 看文档（godoc）
```

---

## 4. 一页速查

| 你想干的事 | Go 里怎么做 |
|---|---|
| 定义一个数据类型 | `type Foo struct { ... }` |
| 给类型加行为 | `func (f *Foo) Bar() {}` |
| 定义"能力" | `type Fooer interface { Bar() }` |
| 创建对象 | `f := NewFoo(...)` 或 `&Foo{...}` |
| 传依赖 | 在构造函数参数里传接口类型 |
| 取消一个操作 | `ctx, cancel := context.WithCancel(ctx)` |
| 报错 | 返回 `error`，用 `if err != nil` 处理 |
| 遍历 | `for i, v := range slice` |
| 映射 | `map[K]V`，读出来是 `v, ok := m[k]` |
| 加锁 | `mu sync.Mutex` + `defer mu.Unlock()` |

---

## 5. Go 和 Java 的差异速查（给你减负）

| 维度 | Java | Go |
|---|---|---|
| 构造函数 | `new Foo(a, b)` | `NewFoo(a, b)`（普通函数） |
| 方法接收者 | `this` | 显式写 `(f *Foo)` |
| 公开性 | `public` / `private` | 首字母大小写 |
| 继承 | `extends` / `implements` | **没有**；用「组合 + 接口」 |
| 空值 | `null` | `nil` |
| 错误处理 | try/catch 异常 | **返回 error**，不抛异常 |
| 泛型 | 常见 | 少见，Go 1.18+ 才有但用得不多 |
| 依赖注入 | 框架（Spring） | **手动传参**（构造函数） |
| 空结构体 | 不允许 | 允许（`struct{}`） |

> ★ Go **没有继承**。想要"复用 + 多态"，套路是：
> **结构体组合（嵌入）+ 接口**。这就是 cr-check 里 `Handler` 持有 `crplatform.Client` 接口的原因。

---

## 6. 接下来读哪一篇？

第一次看，直接按顺序读 01 → 07，每篇 5~10 分钟。
读完 07 之后，建议自己动手：

1. 打开 `internal/crplatform/crplatform.go`，找出「接口定义」和「两个实现」；
2. 打开 `cmd/server/main.go` 的第 92~190 行，看「依赖组装」是怎么把实现塞进接口的；
3. 跑 `make run`，用 curl 打一发，看日志里 `ctx` 传到了哪里。

---

相关文档： [newclient.md](newclient.md)（构造函数模式）
