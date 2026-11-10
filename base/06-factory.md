# 06 · Factory Pattern（工厂模式）

> 一句话：**当"要造哪个实现"在编译期不知道、只有运行时才知道时，用工厂。**
> cr-check 里有两种工厂，一种在 `main.go`，一种在 `internal/gh`。

---

## 1. 先分清：Constructor vs Factory

| | Constructor（构造函数） | Factory（工厂） |
|---|---|---|
| 造什么 | **一个确定**的对象 | **一堆候选**里挑一个 |
| 输入 | 造它需要的**依赖** | **选择标准**（配置/参数） |
| 返回 | 具体类型 `*T` | 具体类型 `*T`（但"是哪个 T"不确定） |
| cr-check 例子 | `NewHTTPClient(...)` | `gh.Factory` |

一句话：

> **Constructor 回答"怎么造"，Factory 回答"造哪一个"。**

---

## 2. 工厂形式一：★ 选择型工厂（在 `main.go` 里）

这是最常见的工厂，**长得不像工厂，但就是工厂**：

```go
// cmd/server/main.go:111
var crClient crplatform.Client
var mockCR *crplatform.MockClient
if mode == "mock" {
	mockCR = crplatform.NewMockClient(cfg.CR.StatusAliases)
	// ... 塞 mock 数据 ...
	crClient = mockCR                                     // ← 候选 A
} else {
	crClient = crplatform.NewHTTPClient(...)                // ← 候选 B
}
```

```go
// cmd/server/main.go:149
var writer check.Writer
if mode == "mock" {
	writer = check.NewLogWriter(logger)                     // ← 候选 A
} else {
	writer = check.NewGitHubWriter(gh.NewFactory(&cfg.GitHub), logger)  // ← 候选 B
}
```

### 为什么它算工厂？

因为**返回类型是接口，具体是哪个实现由运行时条件决定**。
调用方拿到的只是 `crplatform.Client`，不知道背后是 HTTP 还是 Mock。

### 这种"工厂"通常不单独包一层函数

因为**选择条件就是配置本身**，包一层反而多此一举。
一个常见但**不推荐**的写法是：

```go
// ❌ 过度设计：把 if/else 包进函数里，收益为零
func NewCRClient(mode string, cfg *config.Config) crplatform.Client { ... }
```

**判断标准**：

> 选择逻辑简单（一个 if/else）+ 只用一次 → **直接写在组装段**（cr-check 的做法）
> 选择逻辑复杂（多条件、多种组合）→ **抽成一个工厂函数或工厂类型**

---

## 3. 工厂形式二：★ 带缓存的工厂（`internal/gh`）

这是 cr-check 里真正的"工厂类型"，也是 Go 里非常典型的一种用法。

```go
// internal/gh/client.go:18
// Factory 按 installation_id 缓存 GitHub client。
type Factory struct {
	appID          int64
	privateKeyPath string
	apiURL         string

	mu      sync.Mutex
	clients map[int64]*gogithub.Client
}

// NewFactory 构造 client 工厂。
func NewFactory(cfg *config.GitHubConfig) *Factory {
	return &Factory{
		appID:          cfg.AppID,
		privateKeyPath: cfg.PrivateKeyPath,
		apiURL:         cfg.APIURL,
		clients:        map[int64]*gogithub.Client{},
	}
}
```

### 它解决的三个问题

**问题 1：构造很贵。**
`ghinstallation.NewKeyFromFile` 要读私钥文件、生成 JWT。
每个请求都造一次太浪费。

**问题 2：GitHub App 有多个 installation。**
一个 App 可以被装到很多仓库上，每个仓库有独立的 `installation_id`，
需要各自的 token。所以缓存的 key 是 `installation_id`：

```go
clients map[int64]*gogithub.Client
```

**问题 3：并发安全。**
Webhook 是并发的，多个请求可能同时要同一个 client。
所以有 `mu sync.Mutex`。

### 工厂的"取货"方法

```go
// internal/gh/client.go:38
// Client 返回某个 installation 的 client（带缓存）。
func (f *Factory) Client(installationID int64) (*gogithub.Client, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if c, ok := f.clients[installationID]; ok {
		return c, nil                    // ← 命中缓存，直接返回
	}
	// ghinstallation 内部完成 JWT → installation token 的换取与 1h 过期续期。
	tr, err := ghinstallation.NewKeyFromFile(nil, f.appID, installationID, f.privateKeyPath)
	if err != nil {
		return nil, fmt.Errorf("构造 installation transport: %w", err)
	}
	c, err := gogithub.NewClient(gogithub.WithHTTPClient(&http.Client{Transport: tr}))
	if err != nil {
		return nil, fmt.Errorf("构造 GitHub client: %w", err)
	}
	if f.apiURL != "" {
		// GitHub Enterprise：换 API 地址
		u := f.apiURL
		c, err = gogithub.NewClient(
			gogithub.WithHTTPClient(&http.Client{Transport: tr}),
			gogithub.WithURLs(&u, &u),
		)
		if err != nil {
			return nil, fmt.Errorf("构造 GitHub client（自定义 API 地址）: %w", err)
		}
	}
	f.clients[installationID] = c     // ← 放进缓存
	return c, nil
}
```

### ★ 三个要点

1. **缓存（Cache）**：同样的输入 → 同样的输出，只造一次。
2. **懒加载（Lazy）**：真正需要时才造（不是 `NewFactory` 时就造）。
3. **并发安全**：`sync.Mutex` 保护 map。

> 这是个很地道的 Go 工厂。Golang 标准库里的
> `sync.Once`、`http.Transport` 的连接池、`sql.DB` 的连接池，
> 都是同一个思路。

---

## 4. 工厂怎么被用？

```go
// cmd/server/main.go:156
writer = check.NewGitHubWriter(gh.NewFactory(&cfg.GitHub), logger)
```

工厂被**注入**给 `GitHubWriter`（不是 `GitHubWriter` 内部自己 new 一个）。

然后 `GitHubWriter` 每次写 check 时向工厂要 client：

```go
// internal/check/writer.go:143
func (w *GitHubWriter) upsert(ctx context.Context, ref Ref, status, conclusion, title, summary string) error {
	cl, err := w.factory.Client(InstallationIDFromContext(ctx))   // ← 要 client
	if err != nil {
		return err
	}
	...
}
```

### 为什么不用全局变量？

```go
// ❌ 不推荐
var globalFactory = gh.NewFactory(&cfg.GitHub)

// ✅ 推荐：显式传
writer := check.NewGitHubWriter(gh.NewFactory(&cfg.GitHub), logger)
```

原因：
- **可测试**：测试时能塞一个假工厂
- **无隐藏状态**：看 `main.go` 就知道用的是哪个
- **无并发初始化竞态**：全局变量在 `init()` 里初始化会和并发访问打架

> Go 社区原则：**用参数传递，不用全局变量。**

---

## 5. ★ 工厂 vs 单例（Singleton）

Go 里**没有内置单例**（Java 有 `static` 字段 + 私有构造）。

想实现"全局唯一"有几种路子：

| 方式 | 写法 | 评价 |
|---|---|---|
| **包级变量** | `var defaultFactory = NewFactory(...)` | 最简单，但有初始化顺序问题 |
| **`sync.Once`** | `once.Do(func(){ f = NewFactory(...) })` | 线程安全，标准做法 |
| **包级 `init()`** | `func init() { f = NewFactory(...) }` | 简单但隐藏了副作用 |
| **依赖注入（推荐）** | 显式传给需要的人 | 无魔法、可测试 |

cr-check 选的是**依赖注入**：

```go
writer = check.NewGitHubWriter(gh.NewFactory(&cfg.GitHub), logger)
```

**工厂自己被当成普通依赖传下去了** —— 这就是 Go 处理"全局资源"的标准姿势。

---

## 6. 什么时候该写工厂？

| 场景 | 例子 |
|---|---|
| **创建代价高，要缓存** | `gh.Factory`（读私钥文件 + 生成 JWT） |
| **创建需要运行时才知道的参数** | 按 `installation_id` 造不同 client |
| **同类有多个实现，要按条件挑** | `mode == "mock"` 挑 Mock / Real |
| **要屏蔽创建细节（复杂的多步构造）** | `gh.Factory.Client` 里有 4 层分支 |
| **同一个依赖要共享实例** | 多个 `GitHubWriter` 共用一个 Factory |

**不需要工厂的情况**：

```go
// ✅ 简单对象，直接造
store := queue.NewMemoryStore()
registry := recheck.NewRegistry()
metrics := observability.New()
```

> **判断标准**：
> "造这个对象要 3 步以上" 或者 "同一次运行里会造好几次同一个对象" → 用工厂。
> 否则用构造函数。

---

## 7. 一句话总结

> **Factory = "造哪一个"由运行时决定。**
> 两种形态：
> 1. **选择型**：`if mode == "mock" { A } else { B }`（cr-check 的 `main.go`）
> 2. **缓存型**：`gh.Factory` —— 懒加载 + 缓存 + 并发安全
>
> 工厂本身也是普通依赖，用**参数传递**（不要全局变量）。

---

## 8. 自测题

1. `main.go` 里的 `if mode == "mock"` 分支算工厂吗？为什么？
2. `gh.Factory` 里的 `sync.Mutex` 保护的是什么？
3. 为什么 `gh.Factory` 不在 `NewFactory` 里就把 client 造好，而是懒加载？
4. `writer = check.NewGitHubWriter(gh.NewFactory(&cfg.GitHub), logger)`
   这行里一共造了几个对象？它们分别是什么？
5. 如果把 `gh.NewFactory(...)` 改成一个包级全局变量，会有什么问题？

---

上一篇：[05-dependency-injection.md](05-dependency-injection.md) ｜ 下一篇：[07-context.md](07-context.md)
