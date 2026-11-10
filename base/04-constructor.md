# 04 · Constructor（构造函数模式）

> 一句话：**Go 没有构造函数，靠约定：函数名 = `New` + 类型名。**
> 它就是一个普通函数，唯一的"魔法"是社区约定 + 命名规范。

---

## 1. Go 确实没有构造函数

Java：

```java
public class HTTPClient {
    public HTTPClient(String baseURL, String token) { ... }   // 构造函数
}
```

Go：

```go
type HTTPClient struct {
	baseURL string
	token   string
	// ...
}

// NewHTTPClient 创建平台客户端。          ← 这就是 Go 的"构造函数"
func NewHTTPClient(baseURL, token, path string, timeout time.Duration, aliases map[string][]string) *HTTPClient {
	return &HTTPClient{
		baseURL: strings.TrimRight(baseURL, "/"),
		token:   token,
		path:    path,
		aliases: aliases,
		http:    &http.Client{Timeout: timeout},
	}
}
```

来源：`internal/crplatform/crplatform.go:119`

**没有任何关键字表明它是构造函数。** 它只是一个返回 `*HTTPClient` 的普通函数。
约定俗成的规则：

> `New` + 类型名（`NewHTTPClient` / `NewEngine` / `NewRegistry`）

---

## 2. cr-check 的构造函数全景

| 构造函数 | 文件:行 | 干什么 |
|---|---|---|
| `NewHTTPClient` | `internal/crplatform/crplatform.go:119` | 造一个连真平台的客户端 |
| `NewMockClient` | `internal/crplatform/crplatform.go:221` | 造一个假平台（空 map 初始化） |
| `NewEngine` | `internal/rules/engine.go:178` | 造判定引擎（**解析所有维护窗口，可能失败**） |
| `NewUsage` | `internal/rules/engine.go:141` | 造占用表 |
| `NewLogWriter` | `internal/check/writer.go:59` | 造日志 writer |
| `NewGitHubWriter` | `internal/check/writer.go:121` | 造真 GitHub writer |
| `NewFactory` | `internal/gh/client.go:28` | 造 GitHub client 工厂 |
| `NewMemoryStore` | `internal/queue/queue.go:37` | 造内存幂等存储 |
| `NewRedisStore` | `internal/queue/queue.go:73` | 造 Redis 幂等存储 |
| `NewQueue` | `internal/queue/queue.go:127` | 造异步队列（**处理默认 buffer/workers**） |
| `NewRegistry` | `internal/recheck/recheck.go:41` | 造 PR 登记表 |
| `NewScheduler` | `internal/recheck/recheck.go:112` | 造定时重扫器（**处理默认 interval**） |
| `NewSink` | `internal/audit/sink.go:43` | 造审计 sink（**可能打开文件失败**） |
| `New` | `internal/observability/metrics.go:29` | 造指标集合（**注册全部 metric**） |

---

## 3. ★ 构造函数的三种典型职责

### 职责 A：初始化内部状态（最常见）

```go
// internal/queue/queue.go:37
func NewMemoryStore() *MemoryStore {
	return &MemoryStore{entries: map[string]memEntry{}}
}
```

**为什么不直接 `&MemoryStore{}`？**
因为 `entries` 是 map，零值是 `nil`，往 nil map 写会 panic。
构造函数保证返回的对象**开箱即用**。

### 职责 B：填充默认值

```go
// internal/queue/queue.go:127
func NewQueue(buffer, workers int) *Queue {
	if buffer <= 0 {
		buffer = 256
	}
	if workers <= 0 {
		workers = 4
	}
	return &Queue{ch: make(chan Job, buffer), workers: workers}
}
```

```go
// internal/recheck/recheck.go:112
func NewScheduler(reg *Registry, eval Evaluator, interval time.Duration, logger *slog.Logger) *Scheduler {
	if interval <= 0 {
		interval = 5 * time.Minute
	}
	return &Scheduler{...}
}
```

> **Go 没有默认参数**，所以"默认值"只能在构造函数里兜。

### 职责 C：做校验，可能失败 → 返回 `error`

```go
// internal/rules/engine.go:178
func NewEngine(cfg *config.Config) (*Engine, error) {
	e := &Engine{
		cfg:     cfg,
		windows: map[string]*Window{},
		usage:   NewUsage(),
	}
	for _, wc := range cfg.Windows {
		w, err := ParseWindow(wc, cfg.Timezone)
		if err != nil {
			return nil, err        // ← 构造失败
		}
		e.windows[wc.Env] = w
	}
	return e, nil
}
```

```go
// internal/audit/sink.go:43
func NewSink(logger *slog.Logger, filePath string) (*Sink, error) {
	s := &Sink{logger: logger}
	if filePath != "" {
		f, err := os.OpenFile(filePath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
		if err != nil {
			return nil, err        // ← 打不开审计文件，直接失败
		}
		s.file = f
	}
	return s, nil
}
```

**调用方处理**：

```go
// cmd/server/main.go:95
engine, err := rules.NewEngine(cfg)
if err != nil {
	return fmt.Errorf("构造判定引擎: %w", err)
}
```

> 注意 `%w` —— 这是 Go 1.13+ 的错误包装，能用 `errors.Is` / `errors.As` 追溯原始错误。

---

## 4. ★ 两条强约定

### 约定 1：返回**指针**

```go
func NewRegistry() *Registry    // ✅
func NewRegistry() Registry     // ❌
```

原因（见 [02-method.md](02-method.md)）：
- 方法用指针接收者时，指针类型才满足接口
- 含 `sync.Mutex` 的类型必须用指针
- 避免"值拷贝"带来的意外

### 约定 2：可能失败就返回 `(T, error)`

```go
func NewEngine(cfg *config.Config) (*Engine, error)    // 可能失败
func NewMemoryStore() *MemoryStore                      // 不会失败
```

判断标准：**构造函数要读文件、要开连接、要解析外部输入 → 可能失败 → 返回 error。**

---

## 5. ★ 什么时候用构造函数，什么时候直接用字面量？

| 场景 | 写法 |
|---|---|
| 只是装几个字段，没有隐藏逻辑 | `crplatform.ChangeRequest{Number: "CR-1"}` ✅ |
| 需要初始化 map/slice/chan | `NewMemoryStore()` |
| 需要兜默认值 | `NewQueue(0, 0)` |
| 需要校验 | `NewEngine(cfg)` |
| 需要打开外部资源 | `NewSink(logger, path)` |

**判断口诀**：

> **"有没有隐藏的初始化逻辑？"**
> 有 → 构造函数。没有 → 字面量。

看 cr-check 的对比：

```go
// ✅ 直接字面量：没有任何隐藏逻辑
cr := &crplatform.ChangeRequest{
	Number:    m.Number,
	Status:    crplatform.NormalizeStatus(m.Status, cfg.CR.StatusAliases),
	Requester: m.Requester,
	TargetEnv: m.TargetEnv,
	URL:       m.URL,
}
```

```go
// ✅ 构造函数：有隐藏逻辑（map 初始化、默认值、校验）
store := queue.NewMemoryStore()
```

---

## 6. ★ 构造函数是"依赖注入"的入口

这是本文最重要的一节。

`NewHTTPClient` 的参数里，**所有外部依赖都是参数传进来的**：

```go
func NewHTTPClient(baseURL, token, path string, timeout time.Duration, aliases map[string][]string) *HTTPClient {
	return &HTTPClient{
		baseURL: strings.TrimRight(baseURL, "/"),
		token:   token,
		path:    path,
		aliases: aliases,
		http:    &http.Client{Timeout: timeout},   // ← http.Client 是从外面"塞"进来的标准库类型
	}
}
```

而 `NewGitHubWriter` 直接接收一个**已经造好的工厂**：

```go
// internal/check/writer.go:121
func NewGitHubWriter(f *gh.Factory, logger *slog.Logger) *GitHubWriter {
	return &GitHubWriter{factory: f, logger: logger}
}
```

`NewScheduler` 更是直接接收一个**函数**：

```go
// internal/recheck/recheck.go:93
type Evaluator func(ctx context.Context, pr rules.PRInfo) (outcome rules.Outcome, err error)

// internal/recheck/recheck.go:112
func NewScheduler(reg *Registry, eval Evaluator, interval time.Duration, logger *slog.Logger) *Scheduler {
```

> ★ 注意 `Evaluator` —— **Go 里"函数"是类型**，可以定义成命名类型、当参数传。
> 这是 Go 做依赖注入最灵活的地方：连"行为"都能注入。

---

## 7. 一个常见的 Go 误用（顺便避免）

```go
// ❌ 不好：构造函数内部偷偷 new 依赖，导致无法替换
func NewGitHubWriter(logger *slog.Logger) *GitHubWriter {
	tr, _ := ghinstallation.NewKeyFromFile(nil, appID, installationID, keyPath)  // 内部藏了 appID/keyPath
	return &GitHubWriter{...}
}

// ✅ 好：依赖全部从参数进来
func NewGitHubWriter(f *gh.Factory, logger *slog.Logger) *GitHubWriter {
	return &GitHubWriter{factory: f, logger: logger}
}
```

cr-check 选的是后者 —— 因为 `gh.Factory` 本身是可替换、可缓存的（见 [06-factory.md](06-factory.md)）。

---

## 8. 一句话总结

> **Go 的构造函数 = 一个叫 `NewXxx` 的普通函数。**
> 职责：初始化内部状态、兜默认值、校验（失败返回 error）。
> 约定：返回 `*T`，可能失败就 `(T, error)`。
> **最重要的价值：它是依赖注入的入口** —— 依赖从参数进来，而不是内部 new。

---

## 9. 自测题

1. `NewQueue(0, 0)` 会发生什么？为什么构造函数要兜这个默认值？
2. `NewEngine` 和 `NewMemoryStore` 的返回签名为什么不一样？
3. `NewSink` 为什么要返回 `error`？它做了什么可能失败的事？
4. 下面这种写法有什么问题？
   ```go
   func NewHTTPClient(url string) *HTTPClient {
       return &HTTPClient{http: &http.Client{Timeout: 5 * time.Second}}
   }
   ```
5. `NewGitHubWriter(f *gh.Factory, ...)` 为什么不自己内部造 Factory？

---

上一篇：[03-interface.md](03-interface.md) ｜ 下一篇：[05-dependency-injection.md](05-dependency-injection.md)
