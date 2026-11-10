# 03 · Interface（接口）

> 一句话：**Interface 描述"一个值能做哪些事"，不描述"它是什么"。**
> Go 的接口是**隐式实现**的（鸭子类型）—— 不需要写 `implements`。

---

## 1. 最小的接口长什么样

```go
// internal/crplatform/crplatform.go:75
type Client interface {
	Get(ctx context.Context, number string) (*ChangeRequest, error)
}
```

就这么多。整个 cr-check 项目里最核心的接口。

---

## 2. ★ 隐式实现：不需要 `implements`

只要一个类型**有名字完全一致、方法签名完全一致**的方法，它就实现了这个接口。

```go
// internal/crplatform/crplatform.go:147
func (c *HTTPClient) Get(ctx context.Context, number string) (*ChangeRequest, error) { ... }

// internal/crplatform/crplatform.go:244
func (m *MockClient) Get(ctx context.Context, number string) (*ChangeRequest, error) { ... }
```

`HTTPClient` 和 `MockClient` **从来没写过"implements Client"**，
但它们都能当 `Client` 用：

```go
// cmd/server/main.go:111
var crClient crplatform.Client
if mode == "mock" {
	crClient = mockCR                        // *MockClient ✅
} else {
	crClient = crplatform.NewHTTPClient(...)  // *HTTPClient ✅
}
```

Go 官方说法叫 **duck typing**：
> "如果它走起来像鸭子、叫起来像鸭子，那它就是鸭子。"

**对比 Java**：

```java
public class HTTPClient implements Client { ... }   // Java 必须写
```

---

## 3. ★ 关键原则：接口定义在**使用者**那边，不是实现者那边

Go 社区有个著名 proverb：

> **"Accept interfaces, return structs."**
> （接收接口，返回结构体）

意思是：
- **参数**尽量用接口（这样调用方可以塞任何实现进来 → 好测试）
- **返回值**尽量用具体类型（调用方能直接用它的所有方法，不用先断言）

看 cr-check 是怎么做的：

### 参数用接口 ✓

```go
// internal/webhook/handler.go:24
type Handler struct {
	Cfg         *config.Config
	Engine      *rules.Engine
	CRClient    crplatform.Client    // ← 接口！可以是 HTTPClient 也可以是 MockClient
	Writer      check.Writer         // ← 接口！可以是 LogWriter 也可以是 GitHubWriter
	Store       queue.Store          // ← 接口！可以是 MemoryStore 也可以是 RedisStore
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

`Handler` 完全不知道 `CRClient` 到底是 HTTP 还是 Mock。

### 返回值用结构体 ✓

```go
func NewMockClient(aliases map[string][]string) *MockClient   // 返回具体类型
func NewHTTPClient(...) *HTTPClient                            // 返回具体类型
func (m *MockClient) Get(...) (*ChangeRequest, error)          // 返回具体类型
```

---

## 4. ★ 窄接口原则：一个接口只描述一种角色

cr-check 里的三个接口，每个都**很小**：

```go
// internal/crplatform/crplatform.go:75 —— 只管"查变更单"
type Client interface {
	Get(ctx context.Context, number string) (*ChangeRequest, error)
}

// internal/check/writer.go:25 —— 只管"写 check"
type Writer interface {
	MarkInProgress(ctx context.Context, ref Ref, summary string) error
	Complete(ctx context.Context, ref Ref, outcome rules.Outcome) error
}

// internal/queue/queue.go:17 —— 只管"幂等去重"
type Store interface {
	Seen(ctx context.Context, key string) (bool, error)
	Remember(ctx context.Context, key string, ttl time.Duration) error
}
```

### 为什么这么小？

因为**接口是"使用者的需求清单"，不是"实现者的能力全集"**。

`LogWriter` 明明还有 `Last()`、`All()` 两个方法，
但 `check.Writer` 接口里**故意没有**它们 —— 因为 `Handler` 根本不需要。
（`main.go` 里想用的时候，是先断言成具体类型再调：

```go
// cmd/server/main.go
lw, ok := writer.(*check.LogWriter)
if !ok {
	// real 模式下没有本地记录
}
```
）

> ★ **"接口越小越好"** 是 Go 的核心美学。
> Go 官方的 `io.Reader` 只有 1 个方法，`io.Writer` 只有 1 个方法，
> `io.Closer` 只有 1 个方法 —— 全都是"单一职责"的极致体现。

---

## 5. 一个接口，多个实现

cr-check 的"可替换点"清单：

| 接口 | 实现 1 | 实现 2 | 切换方式 |
|---|---|---|---|
| `crplatform.Client` | `HTTPClient`（真平台） | `MockClient`（本地假平台） | `-mode mock/real` |
| `check.Writer` | `GitHubWriter`（真 GitHub） | `LogWriter`（本地日志） | `-mode mock/real` |
| `queue.Store` | `RedisStore`（生产） | `MemoryStore`（本地） | 代码里选 |

**一个接口多个实现 = 可以在运行时/编译期自由替换 = 好测试的根本原因。**

看测试怎么用（`internal/webhook/handler_test.go` 里的思路）：

```go
// 用 MockClient 替掉真的 HTTP 调用
mockCR := crplatform.NewMockClient(cfg.CR.StatusAliases)
mockCR.Add(&crplatform.ChangeRequest{Number: "CR-1", Status: crplatform.StatusApproved})

handler := &webhook.Handler{
	CRClient: mockCR,   // ← 一行替换掉整个外部世界
	Writer:   check.NewLogWriter(logger),
	Store:    queue.NewMemoryStore(),
	...
}
```

**这就是依赖注入的价值**（下一篇 05 细讲）。

---

## 6. ★ 类型断言：把接口变回具体类型

接口变量不能直接访问具体类型的字段，需要**断言**：

```go
// cmd/server/main.go（/internal/last-check 路由）
lw, ok := writer.(*check.LogWriter)
if !ok {
	webhook.WriteJSON(w, http.StatusOK, map[string]any{
		"note": "real 模式下没有本地记录，请去 GitHub PR 上看 check run",
	})
	return
}
webhook.WriteJSON(w, http.StatusOK, lw.Last())
```

语法：`x := i.(T)` （单返回值，失败会 panic）
安全版：`x, ok := i.(T)` （推荐）

### 类型 switch（一次判断多个类型）

```go
switch v := payload.(type) {
case *ChangeRequest:
	...
case *string:
	...
default:
	...
}
```

---

## 7. ★ 大坑：`nil` 接口 vs "装着 nil 指针的接口"

这是 Go 最经典的坑，cr-check 里**恰好有一个安全写法**。

```go
// 危险写法
func NewBrokenClient() crplatform.Client {
	var c *HTTPClient   // nil 指针
	return c             // ⚠️ 返回的接口值 != nil！
}

// 调用方
c := NewBrokenClient()
if c == nil {          // ❌ 永远 false！
	// 永远进不来
}
c.Get(ctx, "CR-1")     // panic: nil pointer dereference
```

**原因**：接口值由「动态类型 + 动态值」两部分组成。
`(*HTTPClient, nil)` 和 `(nil, nil)` 是**两个不同的接口值**。

### cr-check 怎么避免的？

看 `NewMockClient` —— 它**永远返回非 nil 的指针**：

```go
// internal/crplatform/crplatform.go:221
func NewMockClient(aliases map[string][]string) *MockClient {
	return &MockClient{
		items:   map[string]*ChangeRequest{},
		errs:    map[string]error{},
		aliases: aliases,
	}
}
```

所以 main.go 里：

```go
crClient = mockCR   // 指针非 nil，接口非 nil ✅
```

> **Go 社区的通用建议**：
> 构造函数**永远返回具体的非 nil 指针**（`*T`），不要返回 `T`（接口）。
> 需要返回接口时，宁可返回 `(T, error)` 的具体类型，也不要返回可能包着 nil 指针的接口。

---

## 8. 接口 vs 结构体：什么时候用哪个？

| | 用 Interface | 用 Struct |
|---|---|---|
| 例子 | `crplatform.Client` | `crplatform.ChangeRequest` |
| 什么时候 | 有**多个实现**、调用方需要替换 | 数据结构固定、调用方要用它的具体字段 |
| 怎么判断 | 问自己"以后会不会有第二个实现？" | 问自己"调用方需要读它的字段吗？" |

判断口诀：

> **"会不会有两种做法？"** 会 → 接口。不会 → 结构体。

cr-check 的例子：
- 查变更单 → 会有「真平台 / 假平台」两种 → `Client` 接口 ✅
- 变更单长什么样 → 只有一种 → `ChangeRequest` 结构体 ✅

---

## 9. 空接口 `any`：什么都装

```go
// internal/webhook/handler.go:377
func writeJSON(w http.ResponseWriter, status int, body any) error { ... }

// cmd/server/main.go
ready := map[string]any{"ready": true, "mode": mode}
```

`any` = `interface{}`（Go 1.18+ 的别名）。它没有任何方法，
所以**任何类型**都满足它。

用在 JSON 响应体这种"结构不固定"的地方很合适。

---

## 10. 一句话总结

> **Interface = 行为契约。**
> - 隐式实现（鸭子类型），不写 `implements`
> - **接口定义在使用者那边**，且**越窄越好**
> - 一个接口多个实现 = 可替换 = 好测试
> - 参数用接口，返回值用具体类型
> - 构造函数返回 `*T` 而不是接口，避免 nil 陷阱

---

## 11. 自测题

1. `crplatform.Client` 这个接口为什么定义在 `crplatform` 包里，
   而不是定义在 `webhook` 包里？（提示：想想 `rules` 包）
2. `check.Writer` 接口里为什么没有 `Last()` 和 `All()`？
3. `func (m MockClient) Get(...)`（值接收者）改过来后，
   `crClient = mockCR` 这行还能编译吗？
4. 为什么 `NewMockClient` 返回 `*MockClient` 而不是 `crplatform.Client`？
5. `any` 和 `interface{}` 是什么关系？

---

上一篇：[02-method.md](02-method.md) ｜ 下一篇：[04-constructor.md](04-constructor.md)
