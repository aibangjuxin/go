# 08 · Goroutine 与 Channel（并发原语）

> 一句话：**Go 用「goroutine + channel」代替线程锁。**
> goroutine 是"轻量线程"，channel 是" goroutine 之间传数据的管道"。
> cr-check 里的**异步判定队列**和**定时重扫**全靠这两个。

---

## 1. goroutine：一个 `go` 关键字

```go
go someFunc(args)
```

前面加 `go`，函数就在**新的 goroutine** 里跑，调用方立刻继续往下走。

### cr-check 里的三处 `go`

```go
// cmd/server/main.go —— HTTP 服务跑在独立 goroutine，主 goroutine 等信号
go func() {
    if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
        logger.Error("HTTP 服务退出", "err", err)
        stop()
    }
}()

// cmd/server/main.go —— 定时重扫跑在独立 goroutine
go scheduler.Run(ctx)

// internal/queue/queue.go —— 每个 worker 一个 goroutine
go func() {
    defer wg.Done()
    for {
        select {
        case <-ctx.Done():
            return
        case j, ok := <-q.ch:
            if !ok { return }
            handler(j)
        }
    }
}()
```

> ★ **goroutine 的代价**：每个 goroutine 初始占 ~2KB 栈（可自动增长到 1GB）。
> 开几万个没问题，开几百万会耗尽内存。
> 绝大多数场景下"一个请求一个 goroutine"是安全的，因为 net/http 每个请求一个 goroutine。

### ★ 主 goroutine 不能直接退出

Go 里 **main 函数返回 = 整个进程退出**，所有 goroutine 一起死。

所以 cr-check 的 main 最后是：

```go
<-ctx.Done()                        // ★ 阻塞，等信号
logger.Info("收到退出信号，开始优雅关闭")
shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
defer cancel()
return srv.Shutdown(shutdownCtx)    // 等在途请求跑完
```

---

## 2. channel：goroutine 之间的管道

```go
ch := make(chan Job)        // 无缓冲：发送方会阻塞直到有人接收
ch := make(chan Job, 256)   // 有缓冲：满了才阻塞
```

| 操作 | 作用 |
|---|---|
| `ch <- v` | 发送（可能阻塞） |
| `v := <-ch` | 接收（可能阻塞） |
| `v, ok := <-ch` | 接收，channel 关闭时 `ok=false` |
| `close(ch)` | 关闭：发送方不再能发，接收方立刻拿到零值 |
| `len(ch)` | 当前缓冲元素个数 |

### ★ 三条铁律

**铁律 1：向已关闭的 channel 发送 → panic**
**铁律 2：从已关闭的 channel 接收 → 立刻返回零值，不会阻塞**
**铁律 3：关闭一个已经关闭的 channel → panic**

所以规则是：**只有发送方能 close**，而且要保证只 close 一次。

---

## 3. ★ select：多路等待

```go
select {
case v := <-ch1:
    use(v)
case v := <-ch2:
    use(v)
case ch3 <- v:
    // 发送
case <-ctx.Done():
    return   // 取消
}
```

`select` 会**阻塞**，直到其中至少一个 case 就绪；多个都就绪时**随机选一个**。

### cr-check 的 worker 循环（标准模板）

```go
// internal/queue/queue.go
func (q *Queue) Start(ctx context.Context, handler func(Job)) {
	var wg sync.WaitGroup
	for i := 0; i < q.workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-ctx.Done():   // ★ 取消 → 立刻退出
					return
				case j, ok := <-q.ch:
					if !ok {         // ★ channel 被关闭 → 退出
						return
					}
				 handler(j)
				}
			}
		}()
	}
	go func() {
		<-ctx.Done()
		wg.Wait()   // ★ 等所有 worker 退出
	}()
}
```

**为什么用 `select` 而不是单纯 `<-q.ch`？**
因为单纯接收时，如果队列一直是满的、ctx 取消了，worker 还在处理任务，
要处理完当前任务才会看到 ctx —— 延迟。
`select` 在两个 case 都 ready 时随机选，ctx 取消能**立刻**生效。

### ★ 队列满时的"快速失败"

```go
// internal/queue/queue.go
func (q *Queue) Push(j Job) bool {
	select {
	case q.ch <- j:
		return true
	default:            // ★ default 分支 = 不等待，队列满就立刻返回 false
		return false
	}
}
```

带 `default` 的 `select` 是**非阻塞**的：永远选一个 ready 的 case，
如果一个都没有就走 `default`。

对应 handler 里的处理：

```go
// internal/webhook/handler.go
if !h.Queue.Push(job) {
    h.Logger.Error("队列已满，任务被丢弃", "delivery_id", delivery)
    writeJSON(w, http.StatusServiceUnavailable, map[string]any{
        "status": "queue_full", "error": "判定队列已满，请稍后重试",
    })
    return
}
```

> ★ **设计要点**：GitHub 的 webhook 有 **10 秒投递预算**，
> 超时 GitHub 会认为投递失败并（可能）重投。
> 所以队列满时**必须返回 503 让对方重试**，而不是干等着阻塞。
> 这正是 `select ... default` 的典型用途。

---

## 4. ★ 有缓冲 vs 无缓冲

| | 无缓冲 `make(chan T)` | 有缓冲 `make(chan T, n)` |
|---|---|---|
| 语义 | **握手**：发送方必须等到有人接收 | **邮箱**：先放进去，后取 |
| 写入阻塞时机 | 一直没有接收方 | 缓冲满 |
| 用途 | 明确的同步点（信号） | 生产者-消费者（任务队列） |

cr-check 的 `Queue` 用有缓冲（256），因为它是**生产者-消费者**模型：

```go
jobQueue := queue.NewQueue(256, cfg.Server.Workers)
```

- `Push` = 生产者（HTTP handler goroutine）
- `Start` 里的 worker = 消费者（`cfg.Server.Workers` 个 goroutine）

---

## 5. ★ Worker Pool（工作池）

Go 没有内置线程池，但模式是固定的，三步：

```
1. 造一个带缓冲的 channel 当任务队列
2. 起 N 个 goroutine 死循环读这个 channel
3. 用 WaitGroup 等所有 worker 退出（优雅关闭）
```

cr-check 的 `queue.Start` 就是标准实现，四个要素齐全：

| 要素 | cr-check 里的实现 |
|---|---|
| 队列 | `ch chan Job`（缓冲 256） |
| worker 数 | `q.workers`（配置 `server.workers`） |
| 退出信号 | `ctx.Done()` |
| 等待退出 | `sync.WaitGroup` |

### ★ 为什么 worker 数不能无限大？

判定要调 CR 平台（外部 HTTP）。worker 太多 → 并发压垮下游。

cr-check 的配置里给了这个旋钮：

```yaml
server:
  workers: 4
```

同时用 Prometheus 监控积压：

```go
h.Metrics.QueueDepth.Set(float64(h.Queue.Depth()))
```

**★ 队列深度是这类系统最重要的健康指标**：
持续上涨 = 处理速度跟不上流量 = 下游挂了或 worker 少了。

---

## 6. 用 channel 做"一次性信号"

有时不需要传数据，只需要"通知一声"。这时用**只关闭一次的 channel**：

```go
done := make(chan struct{})   // ★ 用 struct{}：零大小，不占内存

go func() {
    <-done
    fmt.Println("收到信号")
}()

close(done)   // 广播："可以退出了"
```

比 `chan bool` 好在哪：
- `struct{}` 零内存
- 关闭 = 广播给所有接收方（`chan bool` 写 `false` 只能给一个）

---

## 7. ★ goroutine 泄漏

**goroutine 泄漏** = 有 goroutine 永远不退出。

常见原因：

| 原因 | 例子 |
|---|---|
| 阻塞在 channel 接收，但没人发送 | `ch := make(chan int)` 无人写 |
| 阻塞在 channel 发送，但没人接收 | 无缓冲 channel 无人读 |
| 阻塞在 HTTP/IO，没设超时 | `http.Get` 对方不响应 |

**后果**：goroutine 越多，内存越高，最终 OOM。

### cr-check 的三条防线

**防线 1：所有 IO 都带 ctx / timeout**

```go
// internal/crplatform/crplatform.go
req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
resp, err := c.http.Do(req)     // http.Client 也配了 Timeout
```

**防线 2：worker 循环 select 了 `ctx.Done()`**

```go
case <-ctx.Done():
    return
```

**防线 3：进程退出时统一取消**

```go
ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
defer stop()
```

### ★ 自检口诀

> **每个 goroutine 都要能回答："什么情况下它会退出？"**
> 答不上来 = 泄漏。

---

## 8. ★ 并发下"谁在写"的规矩

goroutine 之间共享内存时，Go 的内存模型不保证你能看到别的 goroutine 的写入，
**必须用同步手段**（channel / mutex / atomic）来建立"happens-before"关系。

cr-check 里：

| 数据 | 谁写 | 保护方式 |
|---|---|---|
| `Queue.ch` | HTTP handler（多个） | channel 本身就是同步的 |
| `Usage.m` | 多个 worker | `sync.Mutex` |
| `MemoryStore.entries` | 多个 handler | `sync.Mutex` |
| `Registry.entries` | handler + scheduler | `sync.RWMutex` |
| `LogWriter.last/all` | 多个 worker | `sync.Mutex` |

细节见 [09-sync.md](09-sync.md)。

---

## 9. 一句话总结

> **goroutine = 并发的执行单元，channel = 它们的对话方式。**
> - `go f()` 启动，`main` 返回 = 全死
> - `select` + `ctx.Done()` = 可取消的循环（标准模板）
> - `select ... default` = 非阻塞操作（队列满立刻失败）
> - 有缓冲 channel = 任务队列；配合 N 个 worker = 工作池
> - 每个 goroutine 都要能说出退出条件，否则是泄漏
> - 共享内存必须用 channel / mutex / atomic 同步

---

## 10. 自测题

1. `Queue.Push` 为什么要用 `select ... default`？不用会怎样？
2. `queue.Start` 里为什么要 `wg.Wait()`？不写会怎样？
3. 什么场景下 goroutine 会泄漏？举两个 cr-check 里的具体例子。
4. `close(ch)` 之后，接收方会拿到什么？
5. 为什么"每来一个请求开一个 goroutine"在 Go 里通常没问题，但在 Java 里要小心？

---

上一篇：[07-context.md](07-context.md) ｜ 下一篇：[09-sync.md](09-sync.md) ｜ 回到 [00-index.md](00-index.md)
