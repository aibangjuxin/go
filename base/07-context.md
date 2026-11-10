# 07 · Context（上下文与生命周期管理）

> 一句话：**Context 是 Go 用来传递"这次调用/这个请求"范围数据的标准载体，
> 同时也是取消信号和超时的传递通道。**
> 规则只有一条，但很硬：**`ctx context.Context` 永远是第一个参数。**

---

## 1. Context 是什么

`context.Context` 是一个接口：

```go
type Context interface {
	Deadline() (deadline time.Time, ok bool)
	Done() <-chan struct{}
	Err() error
	Value(key any) any
}
```

它同时承担三件事：

| 能力 | 说明 |
|---|---|
| **传值** | 塞一些"本次请求的附带信息"，跨函数传递 |
| **取消** | 上游喊停 → 下游立刻停止工作 |
| **超时** | 到了时间就自动取消 |

---

## 2. ★ 黄金法则

### 规则 1：`ctx` 永远是第一个参数

```go
// internal/crplatform/crplatform.go:147
func (c *HTTPClient) Get(ctx context.Context, number string) (*ChangeRequest, error)

// internal/check/writer.go:126
func (w *GitHubWriter) MarkInProgress(ctx context.Context, ref Ref, summary string) error

// internal/rules/engine.go:204
func (e *Engine) Evaluate(ctx context.Context, in Input) Outcome

// internal/queue/queue.go:151
func (q *Queue) Start(ctx context.Context, handler func(Job))
```

注意：**返回 `error` 时，`ctx` 放最后**：

```go
func (r *Registry) Get(key string) (rules.PRInfo, bool)         // 没有 ctx
func (s *Scheduler) RunOnce(ctx context.Context)                 // 有 ctx
```

这是 Go 官方约定，有专门的 lint 工具（`containedctx` / `revive`）检查。

### 规则 2：★ 不要把 ctx 存进 struct

```go
// ❌ 绝对不要
type Handler struct {
	ctx context.Context     // 灾难
}

// ✅ 用参数传
func (h *Handler) Evaluate(ctx context.Context, pr rules.PRInfo, ...) rules.Outcome
```

原因：ctx 是**每次调用**都不同的。存进 struct 就变成"上一次调用的 ctx"，
会串味（尤其并发时）。

> Go 官方文档原话：
> "Do not store Contexts inside a struct type; instead, pass a Context explicitly to each function that needs it."

### 规则 3：不用就传 `nil`？—— **不要！**

```go
// ❌ 千万不要
cr.Get(nil, "CR-1")     // 会 panic 或行为诡异

// ✅ 传 context.Background()
cr.Get(context.Background(), "CR-1")
```

---

## 3. Context 在 cr-check 里的传递链

把一次 webhook 请求的 ctx 流向画出来：

```
GitHub HTTP 请求
    │
    │  r.Context()  ← net/http 自动为每个请求创建 ctx
    ▼
webhook.Handler.ServeHTTP(w, r)
    │
    ├─► h.Store.Seen(r.Context(), delivery)          ← 幂等检查
    ├─► h.Store.Remember(r.Context(), delivery, ttl)
    │
    └─► handlePullRequest(w, r, body, delivery)
            │
            │  ctx := check.WithInstallationID(r.Context(), ev.Installation.ID)
            │            ↑ 在原 ctx 上挂了一个值
            ▼
        h.Evaluate(ctx, pr, delivery, "webhook")
            │
            ├─► h.Writer.MarkInProgress(ctx, ref, "正在校验变更单…")
            ├─► h.CRClient.Get(ctx, crNumber)
            │        │
            │        └─► http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
            │                 ↑ ★ ctx 挂到了 HTTP 请求上 → 客户端断开/超时会传导到平台调用
            │
            └─► h.Writer.Complete(ctx, ref, outcome)
                    │
                    └─► w.factory.Client(InstallationIDFromContext(ctx))
                            ↑ 从 ctx 里把 installation_id 取回来
```

**★ 重点看 `http.NewRequestWithContext`** —— 这是 ctx 最有价值的用法：

```go
// internal/crplatform/crplatform.go:147
func (c *HTTPClient) Get(ctx context.Context, number string) (*ChangeRequest, error) {
	url := c.baseURL + strings.ReplaceAll(c.path, "{number}", number)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	//                                              ↑ 把 ctx 绑到请求上
	if err != nil {
		return nil, fmt.Errorf("构造请求: %w", err)
	}
	...
	resp, err := c.http.Do(req)
```

绑上之后：
- ctx 被取消 → 正在进行的 HTTP 请求立刻中断
- ctx 超时 → 请求自动超时
- 用户断开连接 → ctx 取消 → 平台调用也停

**没有这一句，平台卡住就一直卡住，直到 `http.Client.Timeout` 生效。**

---

## 4. ★ `context.WithValue`：往 ctx 里挂数据

### cr-check 的用法

```go
// internal/check/writer.go:194
// installationIDKey 是 context 里携带 installation id 的键。
type installationIDKey struct{}

// WithInstallationID 把 installation id 放进 context。
func WithInstallationID(ctx context.Context, id int64) context.Context {
	return context.WithValue(ctx, installationIDKey{}, id)
}

// InstallationIDFromContext 取出 context 里的 installation id。
func InstallationIDFromContext(ctx context.Context) int64 {
	if v, ok := ctx.Value(installationIDKey{}).(int64); ok {
		return v
	}
	return 0
}
```

### 用法

```go
// internal/webhook/handler.go
ctx := check.WithInstallationID(r.Context(), ev.Installation.ID)
```

```go
// internal/check/writer.go:143
cl, err := w.factory.Client(InstallationIDFromContext(ctx))
```

### ★ 为什么键要定义成 `struct{}` 而不是用字符串？

```go
// ❌ 千万别这样
ctx = context.WithValue(ctx, "installation_id", id)          // 字符串键，容易撞
ctx = context.WithValue(ctx, "userID", userID)               // 不同包可能用同一个字符串！

// ✅ 定义一个私有类型做键
type installationIDKey struct{}
ctx = context.WithValue(ctx, installationIDKey{}, id)
```

原因：
1. **防冲突**：`installationIDKey{}` 是 `check` 包私有的类型，别的包造不出同样的键
2. **防误用**：字符串键 `"installation_id"` 可能和别的包撞车
3. **Go 官方明确要求**：键应该是**自定义类型**（通常是未导出的 struct）

> ★ Go 官方文档：
> "The provided key must be comparable and should not be of type string or any other built-in type to avoid collisions between packages."

### ★ 但 `WithValue` 不该乱用

Go 官方对 `WithValue` 的定位非常明确：

> **"Use context values only for request-scoped data that flows across API boundaries
> and does not have any type defined in the function signature."**
> （只用于"跨 API 边界的请求级数据"，不要用它传递普通参数）

**判断标准**：

| 该不该用 WithValue | 例子 |
|---|---|
| ✅ 该用 | installation_id、trace_id、请求用户身份 —— **下游函数不知道该带它** |
| ❌ 不该用 | 一个函数明明有参数位，却偏要塞 ctx |

cr-check 的 `installation_id` 就是典型的"该用"：
`Writer.Complete(ctx, ref, outcome)` 的签名里没有 installation_id，
但 GitHubWriter 内部需要它 → 只能走 ctx。

---

## 5. ★ 取消：`context.WithCancel`

```go
ctx, cancel := context.WithCancel(parentCtx)
defer cancel()      // ★ 一定要 defer cancel()
```

`cancel()` 会关闭 ctx 里的 `Done()` channel，所有监听者立刻收到信号。

### cr-check 的 `Queue.Start`：标准的 worker 模式

```go
// internal/queue/queue.go:151
func (q *Queue) Start(ctx context.Context, handler func(Job)) {
	var wg sync.WaitGroup
	for i := 0; i < q.workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-ctx.Done():      // ★ 收到取消信号 → 优雅退出
					return
				case j, ok := <-q.ch:
					if !ok {
						return
					}
					handler(j)         // 处理任务
				}
			}
		}()
	}
	go func() {
		<-ctx.Done()      // ★ 等 ctx 取消
		wg.Wait()         //    等所有 worker 退出
	}()
}
```

**`select` + `ctx.Done()` 是 Go 里"可取消的循环"的标准写法。**
`select` 会在多个 channel 都 ready 时**随机选一个**，
所以即使队列里一直有任务，ctx 一取消也能马上退出。

### `Scheduler.Run`：定时任务的标准写法

```go
// internal/recheck/recheck.go:127
func (s *Scheduler) Run(ctx context.Context) {
	ticker := time.NewTicker(s.Interval)
	defer ticker.Stop()
	s.Logger.Info("定时重扫已启动", "interval", s.Interval)
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.RunOnce(ctx)
		}
	}
}
```

> ★ **标准模板**：
> ```go
> ticker := time.NewTicker(d)
> defer ticker.Stop()
> for {
>     select {
>     case <-ctx.Done():
>         return
>     case <-ticker.C:
>         doWork(ctx)
>     }
> }
> ```

---

## 6. ★ 超时：`context.WithTimeout`

```go
ctx, cancel := context.WithTimeout(parentCtx, 5*time.Second)
defer cancel()
```

cr-check 里的两处：

### 6.1 优雅关闭（10 秒超时）

```go
// cmd/server/main.go:192
ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
defer stop()

// ... 启动 HTTP 服务、worker、scheduler ...

<-ctx.Done()                       // ★ 阻塞直到收到 SIGINT/SIGTERM
logger.Info("收到退出信号，开始优雅关闭")
shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
defer cancel()
return srv.Shutdown(shutdownCtx)   // ★ 最多等 10 秒让在途请求跑完
```

**★ `signal.NotifyContext` 是 Go 1.16+ 的便捷函数**：
把 OS 信号（Ctrl+C / SIGTERM）转成 ctx 取消。

```go
ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
```

一行搞定"监听退出信号 → 取消 ctx → 所有 goroutine 优雅退出"。

### 6.2 HTTP 客户端超时

```go
// internal/crplatform/crplatform.go:125
http: &http.Client{Timeout: timeout},
```

这里的 `timeout` 来自配置：

```go
// cmd/server/main.go:143
crClient = crplatform.NewHTTPClient(
	cfg.CRPlatform.BaseURL, cfg.CRPlatform.Token, cfg.CRPlatform.Path,
	time.Duration(cfg.CRPlatform.TimeoutSeconds)*time.Second, cfg.CR.StatusAliases)
```

> ★ **两套超时机制要分清**：
>
> | | 作用范围 | 谁负责 |
> |---|---|---|
> | `http.Client.Timeout` | 单次 HTTP 调用（含连接+读取） | 传输层 |
> | `context.WithTimeout` | 一整串操作（可能多次 HTTP） | 业务流程 |
>
> **两个都设，才安全。**

---

## 7. `context.Background()` vs `context.TODO()`

| | 什么时候用 |
|---|---|
| `context.Background()` | 根 ctx，**永远不会取消**。用于 main、后台任务起点 |
| `context.TODO()` | "这里应该有个 ctx，但还没想好"。**临时占位**，别留着 |

cr-check 的用法：

```go
// cmd/server/main.go:192 —— 根 ctx
ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)

// cmd/server/main.go:338 —— 关闭时不能用已经取消的 ctx，要开一个新的
shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
```

> ★ **坑**：`shutdownCtx` 故意用 `context.Background()` 而不是原来的 `ctx`，
> 因为原来的 `ctx` **已经被取消了**！用已取消的 ctx 去 `Shutdown` 会立刻返回，什么都不等。

---

## 8. Context 的三条铁律（官方文档）

Go 官方 `context` 包的文档里，明确列了三条规则：

1. **不要把 Context 存进 struct**（前面讲过）
2. **不要传 nil Context**；不确定就传 `context.TODO()`
3. **只用 Context 传递请求级信息**，不要用它传普通参数

> "Functions that accept Context should derive their own Context from the one passed in"
> （接收 ctx 的函数应该从父 ctx 派生自己的 ctx，不要直接换掉）

---

## 9. 完整对照表

| API | 作用 | cr-check 里的位置 |
|---|---|---|
| `context.Background()` | 根 ctx | `main.go:192`, `main.go:338` |
| `context.TODO()` | 占位 | — |
| `context.WithCancel(parent)` | 手动取消 | 概念上对应 `signal.NotifyContext` |
| `context.WithTimeout(parent, d)` | 超时取消 | `main.go:338` 优雅关闭 |
| `context.WithDeadline(parent, t)` | 截止时间取消 | — |
| `context.WithValue(parent, k, v)` | 挂值 | `check.WithInstallationID` |
| `ctx.Done()` | 取消信号 channel | `queue.Start`, `Scheduler.Run` |
| `ctx.Err()` | 取消原因 | — |
| `ctx.Value(k)` | 取值 | `InstallationIDFromContext` |

---

## 10. 一句话总结

> **Context = 这次调用的"生命周期 + 附带数据"。**
> - 第一个参数，永远叫 `ctx`
> - 不存进 struct，不传 nil
> - `WithValue` 只传"下游签名里放不下"的请求级数据，键要用自定义类型
> - `select { case <-ctx.Done(): ... }` = 可取消的循环
> - `http.NewRequestWithContext` = 把取消/超时传导到外部调用
> - `signal.NotifyContext` = 优雅退出的标准起手式

---

## 11. 自测题

1. 为什么 `shutdownCtx` 用 `context.Background()` 而不是原来的 `ctx`？
2. `http.Client{Timeout: 5s}` 和 `context.WithTimeout(ctx, 5s)` 有什么区别？
3. `WithInstallationID` 为什么不直接用 `context.WithValue(ctx, "installation_id", id)`？
4. `queue.Start` 里的 `select` 为什么能保证"队列一直有任务时，ctx 取消也能立刻退出"？
5. 为什么 `Handler` 结构体里不能存 `ctx`？

---

上一篇：[06-factory.md](06-factory.md) ｜ 回到 [00-index.md](00-index.md)
