# 05 · Dependency Injection（依赖注入）

> 一句话：**Go 没有 DI 框架，也不靠反射注入 —— 依赖通过构造函数参数传进来。**
> 唯一需要做的是：**把字段类型声明成接口，而不是具体类型。**

---

## 1. 没有 DI 框架

Java Spring：

```java
@Service
public class GitHubWriter implements Writer {
    @Autowired private GhFactory factory;     // ← 框架反射注入
}
```

Go（cr-check）：

```go
type GitHubWriter struct {
	factory *gh.Factory
	logger  *slog.Logger
}

func NewGitHubWriter(f *gh.Factory, logger *slog.Logger) *GitHubWriter {
	return &GitHubWriter{factory: f, logger: logger}
}
```

没有注解、没有反射、没有容器。**构造函数就是注入点。**

---

## 2. ★ DI 的两个必要条件

### 条件 1：字段声明成**接口**（不是具体类型）

```go
// internal/webhook/handler.go:24
type Handler struct {
	Cfg         *config.Config
	Engine      *rules.Engine
	CRClient    crplatform.Client    // ← ✅ 接口
	Writer      check.Writer         // ← ✅ 接口
	Store       queue.Store          // ← ✅ 接口
	Audit       *audit.Sink
	Metrics     *observability.Metrics
	Logger      *slog.Logger
	Registry    *recheck.Registry
	Queue       *queue.Queue
	SyncEval    bool
	DeliveryTTL time.Duration
	Clock       func() time.Time
}
```

如果写成这样就完蛋了：

```go
type Handler struct {
	CRClient *crplatform.HTTPClient   // ❌ 写死了，测不了
}
```

### 条件 2：构造函数把依赖**传进来**

```go
// cmd/server/main.go:176
handler := &webhook.Handler{
	Cfg:         cfg,
	Engine:      engine,
	CRClient:    crClient,      // ← 从外面传进来的
	Writer:      writer,
	Store:       store,
	Audit:       auditSink,
	Metrics:     metrics,
	Logger:      logger,
	Registry:    registry,
	Queue:       jobQueue,
	SyncEval:    syncEval,
	DeliveryTTL: 24 * time.Hour,
	Clock:       clock,
}
```

> 注意：这里用的是**结构体字面量**，不是 `webhook.NewHandler(...)`。
> 原因很简单 —— `Handler` 有 **13 个字段**，全是平铺的依赖，
> 写个构造函数要写 13 个参数，收益不大。
> Go 社区的做法：**字段少、需校验 → 构造函数；字段多、纯装配 → 结构体字面量。**

---

## 3. ★ `main.go` 的"依赖组装"段 —— 全文最值得看的一段

`cmd/server/main.go` 第 92~190 行：

```go
// ── 依赖组装 ────────────────────────────────────────────
metrics := observability.New()

engine, err := rules.NewEngine(cfg)
if err != nil {
	return fmt.Errorf("构造判定引擎: %w", err)
}

auditSink, err := audit.NewSink(logger, auditFile)
if err != nil {
	return fmt.Errorf("构造审计 sink: %w", err)
}
defer func() {
	if err := auditSink.Close(); err != nil {
		logger.Warn("关闭审计文件失败", "err", err)
	}
}()

// CR 平台客户端
var crClient crplatform.Client           // ← 先声明接口变量
var mockCR *crplatform.MockClient
if mode == "mock" {
	mockCR = crplatform.NewMockClient(cfg.CR.StatusAliases)
	for _, m := range cfg.Mock.CRs {
		// ... 塞 mock 数据 ...
	}
	crClient = mockCR                     // ← 塞实现 A
	logger.Info("mock 模式：使用内置假 CR 平台", "crs", len(cfg.Mock.CRs))
} else {
	crClient = crplatform.NewHTTPClient(   // ← 塞实现 B
		cfg.CRPlatform.BaseURL, cfg.CRPlatform.Token, cfg.CRPlatform.Path,
		time.Duration(cfg.CRPlatform.TimeoutSeconds)*time.Second, cfg.CR.StatusAliases)
}

// check writer
var writer check.Writer                  // ← 同样
if mode == "mock" {
	writer = check.NewLogWriter(logger)   // ← 实现 A
} else {
	if !cfg.HasGitHubCredentials() {
		return errors.New("real 模式需要 GITHUB_APP_ID / ...")
	}
	writer = check.NewGitHubWriter(gh.NewFactory(&cfg.GitHub), logger)  // ← 实现 B
}

// 幂等存储（本地用内存；生产换 Redis）
store := queue.NewMemoryStore()

registry := recheck.NewRegistry()
jobQueue := queue.NewQueue(256, cfg.Server.Workers)
```

**这一段就是"依赖注入"在 Go 里的全部**：手工 new，手工装配。

### 关键细节：`var crClient crplatform.Client` 先声明接口

```go
var crClient crplatform.Client   // ← 零值是 nil 接口
...
crClient = mockCR                // ← 赋值
```

如果不先声明接口变量，直接 `crClient := mockCR`，
那 `crClient` 的类型就**永远被推断成 `*MockClient`**，
后面 `crClient = crplatform.NewHTTPClient(...)` 会**编译报错**（类型不匹配）。

> ★ 这就是"接口变量声明 + 赋值"的标准写法。

---

## 4. ★ DI 带来的三个好处

### 好处 1：可替换（mock 测试）

```go
// internal/webhook/handler_test.go 的思路
mockCR := crplatform.NewMockClient(cfg.CR.StatusAliases)
mockCR.Add(&crplatform.ChangeRequest{
	Number: "CR-1", Status: crplatform.StatusApproved,
})

handler := &webhook.Handler{
	CRClient: mockCR,                    // ← 替换掉整个外部世界
	Writer:   check.NewLogWriter(logger), // ← 不打真 GitHub
	Store:    queue.NewMemoryStore(),     // ← 不连 Redis
	Audit:    auditSink,
	...
}
```

**测 webhook 逻辑，不需要 GitHub、不需要 CR 平台、不需要 Redis。**
这就是 Go 测试好写的根本原因。

### 好处 2：编译期检查

如果 `LogWriter` 少了 `Complete` 方法，**编译就过不去**，
不会等到运行期才发现。

### 好处 3：依赖关系一目了然

打开 `main.go` 看依赖组装段，就知道这个服务依赖了哪些东西：
配置、GitHub、CR 平台、Redis、审计文件、指标、队列、调度器。
**没有隐藏依赖，全在明面上。**

---

## 5. ★ 依赖倒置：接口属于"使用者"，不属于"实现者"

这是 DI 的思想核心，也是 Go 和 Java 最不一样的地方。

### Java 的做法

```java
// 依赖具体的接口，接口和实现放一个包
package writer;
public interface Writer { }
public class GitHubWriter implements Writer { }
```

### Go 的做法（cr-check）

```
internal/crplatform/     ← 定义 Client 接口 + HTTPClient + MockClient
internal/check/          ← 定义 Writer 接口 + LogWriter + GitHubWriter
internal/queue/          ← 定义 Store 接口 + MemoryStore + RedisStore
internal/webhook/        ← 只用 crplatform.Client / check.Writer / queue.Store
```

**接口和实现放在同一个包里** —— 这样切换实现不需要跨包 import。
`webhook` 包只依赖接口定义，**完全不知道 `MockClient` 的存在**。

这叫 **Dependency Inversion（依赖倒置）**：
- 高层模块（webhook）依赖抽象（Client 接口）
- 低层模块（crplatform）实现抽象
- 两者都依赖抽象，不依赖具体实现

---

## 6. ★ 注入"函数"和"行为"

Go 的 DI 不止能注入对象，还能注入**行为**。

### 注入一个函数

```go
// internal/webhook/handler.go:39
// Clock 返回"当前时间"。生产用 time.Now；
// 本地可以用 -now 参数固定时间，方便验证维护窗口规则。
Clock func() time.Time
```

```go
// cmd/server/main.go
clock := time.Now
if nowFlag != "" {
	fixed, err := time.Parse(time.RFC3339, nowFlag)
	if err != nil {
		return fmt.Errorf("解析 -now %q: %w", nowFlag, err)
	}
	clock = func() time.Time { return fixed }
	logger.Warn("使用固定时间（本地调试）", "now", fixed.Format(time.RFC3339))
}
```

> ★ 这就是 Go 里最经典的 **Clock 注入** 模式。
> 有了它，测试"维护窗口过期"这种依赖当前时间的逻辑，
> 可以**把时间钉死**，测试结果永远稳定。

### 注入一个命名函数类型

```go
// internal/recheck/recheck.go:93
type Evaluator func(ctx context.Context, pr rules.PRInfo) (outcome rules.Outcome, err error)

// internal/recheck/recheck.go:112
func NewScheduler(reg *Registry, eval Evaluator, interval time.Duration, logger *slog.Logger) *Scheduler {
```

```go
// cmd/server/main.go
scheduler := recheck.NewScheduler(registry, func(c context.Context, pr rules.PRInfo) (rules.Outcome, error) {
	outcome := handler.Evaluate(c, pr, "", "recheck")
	registry.SetConclusion(pr.Key(), outcome.Conclusion())
	return outcome, nil
}, time.Duration(cfg.Server.RecheckIntervalSeconds)*time.Second, logger)
```

> `Scheduler` 只知道"有个 Evaluator 能帮我重评一个 PR"，
> 完全不知道重评逻辑长什么样。**这是 DI 的极致形态**。

### 注入一个"钩子"回调

```go
// internal/recheck/recheck.go:106
OnScanned func(n int)
OnFlipped func()
```

```go
// cmd/server/main.go
scheduler.OnScanned = func(n int) { metrics.RecheckScanned.Add(float64(n)) }
scheduler.OnFlipped = func() { metrics.RecheckFlipped.Inc() }
```

> 调度器负责"什么时候扫"，指标负责"扫了多少" —— 两者解耦。

---

## 7. 对比表：Java Spring vs Go

| | Spring | Go（cr-check） |
|---|---|---|
| 注入方式 | `@Autowired` 注解 + 反射 | 构造函数参数 |
| 声明依赖 | 字段类型 | 字段类型**写成接口** |
| 配置文件 | `application.yml` | `config/policy.yaml` + `main.go` 组装段 |
| 生命周期 | `@PostConstruct` / `InitializingBean` | 构造函数内自己管，或显式 `Close()` |
| 拿实现 | 自动注入唯一实现 | 手动 `if mode == "mock" { ... } else { ... }` |
| AOP 代理 | 自动 | 无 → 用装饰器 / 显式包装 |
| 测试替身 | `@MockBean` | 手动传一个 Mock 实现 |

### Spring 有而 Go 没有的东西

- **没有** AOP 自动代理（Go 里用"包装一层"手写）
- **没有** 自动按类型找唯一实现
- **没有** 注解驱动的生命周期

### Go 有而 Spring 没有的东西

- **没有** 魔法，一切看得见（那个"依赖组装"段就是全部真相）
- **编译期**就能发现依赖不匹配（Java 也能，但 Spring 是运行期才炸）
- 依赖图可以一眼看完

---

## 8. ★ 什么该 DI，什么不该

| 该 DI | 不该 DI |
|---|---|
| 外部系统（GitHub、CR 平台、Redis） | 值对象（`ChangeRequest`、`PRInfo`） |
| 有多个实现的（`Client`、`Writer`、`Store`） | 纯函数/工具（`strings.TrimRight`） |
| 时间（`Clock func() time.Time`） | 标准库无状态工具（`fmt.Sprintf`） |
| 随机数（`func() int64`） | — |
| 行为（`Evaluator` 回调） | — |
| 外部配置（`*config.Config`） | — |

---

## 9. 一句话总结

> **Go 的 DI = 构造函数传参 + 字段声明成接口。**
> 没有框架、没有注解、没有反射。
> 装配全部集中在 `main.go` 的"依赖组装"段，一眼看清整个服务的依赖图。
> 还能注入**函数**（`Clock`、`Evaluator`），这是 Java 里比较难做到的。

---

## 10. 自测题

1. `main.go` 里为什么先写 `var crClient crplatform.Client`，
   而不是直接 `crClient := mockCR`？
2. `Handler` 有 13 个字段，为什么不用 `webhook.NewHandler(...)` 构造函数？
3. `Clock func() time.Time` 这个字段解决了什么测试难题？
4. `Evaluator` 这个命名函数类型，比传一个 struct 好在哪？
5. 如果把 `Handler.CRClient` 改成 `*crplatform.HTTPClient`，
   会有哪些具体的坏处？

---

上一篇：[04-constructor.md](04-constructor.md) ｜ 下一篇：[06-factory.md](06-factory.md)
