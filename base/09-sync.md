# 09 · sync 包（并发安全）

> 一句话：**Go 没有 Java 的 `synchronized` 关键字，也没有内置锁**，
> 要靠 `sync` 包里的 `Mutex` / `RWMutex` / `WaitGroup` / `atomic` / `Once`。
> cr-check 里所有"多个 goroutine 共享同一份数据"的地方都靠它们。

---

## 1. 为什么需要它

Go 的 `map` 和普通变量**不是**并发安全的：

```go
m := map[string]int{}
go func() { m["a"] = 1 }()   // 写
go func() { _ = m["a"] }()   // 读
```

这会触发 **fatal error: concurrent map writes** —— 直接 crash，不是报错，是**整个进程死**。

而且即使不崩，Go 的内存模型也不保证你能**及时**看到别的 goroutine 的写入。

**结论：多 goroutine 共享数据，必须显式同步。**

---

## 2. sync.Mutex（互斥锁）

```go
type Usage struct {
    mu sync.Mutex
    m  map[string]string
}

func (u *Usage) Claim(crNumber, prKey string) bool {
    u.mu.Lock()
    defer u.mu.Unlock()          // ★ 解锁
    if owner, ok := u.m[crNumber]; ok && owner != prKey {
        return false
    }
    u.m[crNumber] = prKey
    return true
}
```

这就是 cr-check 的"变更单占用表"：
**同一个变更单不能被两个 PR 同时占用**（R7 防重复上线）。
而 R7 会被多个 worker 并发执行 → 必须加锁。

### ★ 三条规矩

**规矩 1：锁的粒度要小**
别把网络调用、文件 IO 放进锁里。cr-check 的锁里只有 map 读写。

**规矩 2：必须 `defer mu.Unlock()`**

```go
mu.Lock()
defer mu.Unlock()
```

这样即使中间 `return` 了也会解锁。
反例：

```go
mu.Lock()
if cond {
    return          // ❌ 永远不 Unlock → 死锁
}
mu.Unlock()
```

**规矩 3：★ 不要拷贝带锁的 struct**

`sync.Mutex` 包含状态，**复制一个已加锁的 Mutex 是 undefined behavior**。
Go 1.x 的 `go vet` 会帮你检查（`copylocks`）。

---

## 3. sync.RWMutex（读写锁）

普通 Mutex 是**独占**的：读和读也互斥。
如果读远多于写（比如 `Registry.List()` 每次重扫都要读全部条目），
用 `RWMutex` 可以让多个读并发进行。

cr-check 的 `Registry` 就用了：

```go
type Registry struct {
    mu      sync.RWMutex
    entries map[string]Entry
}

func (r *Registry) List() []Entry {
    r.mu.RLock()          // ★ 读锁
    defer r.mu.RUnlock()
    out := make([]Entry, 0, len(r.entries))
    for _, e := range r.entries {
        out = append(out, e)
    }
    return out
}

func (r *Registry) Add(pr rules.PRInfo) {
    r.mu.Lock()           // ★ 写锁
    defer r.mu.Unlock()
    ...
}
```

| 方法 | 语义 |
|---|---|
| `Lock()` / `Unlock()` | 独占锁 |
| `RLock()` / `RUnlock()` | 共享锁（多个读并发，写独占） |

> ★ **别滥用 RWMutex**：它的开销比 Mutex 大。
> 只有"读 >> 写"且"临界区不短"时才值得用。
> cr-check 的 `Registry` 里读（List）确实远多于写（Add/SetConclusion），用得合理。

---

## 4. sync.WaitGroup（等 goroutine 结束）

```go
var wg sync.WaitGroup
wg.Add(1)        // ★ Add 必须在 go 之前
go func() {
    defer wg.Done()   // ★ Done 必须在 goroutine 里
    doWork()
}()
wg.Wait()        // 等所有 Done
```

cr-check 的 `queue.Start`：

```go
func (q *Queue) Start(ctx context.Context, handler func(Job)) {
    var wg sync.WaitGroup
    for i := 0; i < q.workers; i++ {
        wg.Add(1)
        go func() {
            defer wg.Done()
            for { ... }
        }()
    }
    go func() {
        <-ctx.Done()
        wg.Wait()      // ★ 等所有 worker 优雅退出
    }()
}
```

> ★ **注意 `wg.Add(1)` 一定在 `go` 之前调用**，
> 否则可能 `Add` 还没执行 goroutine 就跑完并 `Done` 了 → `panic: sync: negative WaitGroup counter`。

### 什么时候用 WaitGroup，什么时候用 channel？

- **等一批 goroutine 完成** → WaitGroup（更直观）
- **把结果从一个 goroutine 传给另一个** → channel

---

## 5. sync.Once（只执行一次）

```go
var once sync.Once
once.Do(func() {
    // 只会执行一次，即使并发调用
})
```

典型用途：延迟初始化（昂贵资源只建一次）、单例。

cr-check 里没有直接用 `sync.Once`，但有一个等价的手写版本 —— `gh.Factory` 的 client 缓存：

```go
func (f *Factory) Client(installationID int64) (*gogithub.Client, error) {
    f.mu.Lock()
    defer f.mu.Unlock()
    if c, ok := f.clients[installationID]; ok {
        return c, nil
    }
    tr, err := ghinstallation.NewKeyFromFile(nil, f.appID, installationID, f.privateKeyPath)
    ...
    f.clients[installationID] = c
    return c, nil
}
```

用 Mutex 把"查缓存 + 建 client + 写缓存"做成**原子操作**。
如果分成"先查锁外，再加锁写"—— 两个 goroutine 可能重复建 client，白费资源。

> ★ `sync.Once` 更适合"只读共享的全局初始化"，
> 而 `Factory` 需要"按 key 缓存"，所以用 Mutex + map 更合适。

---

## 6. sync/atomic（原子操作）

无锁计数器：

```go
var counter atomic.Int64
counter.Add(1)
v := counter.Load()
```

适合**单个数值**的高频更新（计数器、标志位）。
不适合复杂数据结构（还是要用锁）。

Go 1.19+ 的泛型原子类型：`atomic.Int64` / `atomic.Bool` / `atomic.Pointer[T]` / `atomic.Value`。

cr-check 用 Prometheus 而不是 atomic 做计数（因为要暴露成指标）。
但 `Scheduler` 里的翻转计数器用了锁：

```go
type Scheduler struct {
    flipped uint64
    mu      sync.Mutex
}

func (s *Scheduler) Flipped() uint64 {
    s.mu.Lock()
    defer s.mu.Unlock()
    return s.flipped
}
```

> ★ 这里其实可以用 `atomic.Uint64` 更简洁 —— 但因为要同时更新 `flipped` 和触发回调，
> 用锁把"计数 + 回调"包成一个原子操作也说得过去。

---

## 7. ★ 竞态检测器（最重要的工具）

Go 内置了 race detector：

```bash
go test -race ./...
go run -race ./cmd/server
```

**它会在运行时检测"未同步的并发读写"**，并打印出冲突的两个栈。

cr-check 的 Makefile 就开着：

```makefile
test: ## 跑测试
	go test -race -cover ./...
```

### race detector 报告长什么样

```
WARNING: DATA RACE
Write at 0x00c000104010 by goroutine 8:
  internal/rules.Engine.Claim()
      /Users/lex/git/go/cr-check/internal/rules/engine.go:120
Previous read at 0x00c000104010 by goroutine 9:
  internal/rules.Engine.Claim()
      /Users/lex/git/go/cr-check/internal/rules/engine.go:120
```

**★ 强烈建议：CI 里必须跑 `go test -race ./...`。**
很多竞态在低并发下"看起来正常"，一上生产就出诡异 bug。

---

## 8. ★ 常见并发坑速查

| 坑 | 症状 | 解法 |
|---|---|---|
| 返回 map/slice 的内部引用 | 调用方改了数据，结构体内部跟着变 | 返回**拷贝**（见下） |
| 忘记 `Unlock` | 死锁 | `defer mu.Unlock()` |
| 锁里做慢 IO | 吞吐塌陷 | 缩小临界区 |
| 拷贝带锁的 struct | 隐蔽 bug | `go vet` 会报 |
| `for` 循环里 goroutine 捕获变量 | 全部用同一个变量 | Go 1.22+ 已修复；老代码要 `v := v` |
| map 并发读写 | fatal error，进程死 | 锁 / `sync.Map` |
| 双检锁 | 忘了加锁的那次读 | 用 `sync.Once` |

### ★ "返回拷贝"这个坑，cr-check 里有真实案例

```go
// internal/crplatform/crplatform.go —— MockClient.Get
func (m *MockClient) Get(_ context.Context, number string) (*ChangeRequest, error) {
    m.mu.RLock()
    defer m.mu.RUnlock()
    cr, ok := m.items[number]
    if !ok {
        return nil, nil
    }
    cp := *cr            // ★ 拷贝一份
    return &cp, nil
}
```

如果不拷贝，调用方改了返回的 `cr.Approvers`，
mock 存储里的数据也被改了 → 后续测试互相污染。

```go
// internal/check/writer.go —— LogWriter.All
func (w *LogWriter) All() []*Record {
    w.mu.Lock()
    defer w.mu.Unlock()
    out := make([]*Record, len(w.all))
    copy(out, w.all)     // ★ 拷贝 slice 本身
    return out
}
```

**★ 规则：任何"从共享结构里取出来的集合"，要么返回深拷贝，要么明确文档说明"返回的是内部引用"。**

---

## 9. 一句话总结

> **Go 没有内置锁，靠 `sync` 包。**
> - `Mutex` 独占；`RWMutex` 读共享写独占（读多写少才用）
> - **永远 `defer mu.Unlock()`**
> - `WaitGroup`：Add 在 go 之前，Done 在 goroutine 里
> - `Once`：只执行一次；`atomic`：无锁计数器
> - **共享数据返回时记得拷贝**
> - **CI 必须跑 `go test -race ./...`**

---

## 10. 自测题

1. `Usage.Claim` 里如果去掉 `defer u.Unlock()`，哪个分支会导致死锁？
2. `Registry.List()` 用 `RLock` 和 `Lock` 有什么区别？什么时候值得用 RLock？
3. `MockClient.Get` 为什么要 `cp := *cr`？不拷贝会有什么后果？
4. `sync.WaitGroup` 的 `Add` 和 `Done` 分别应该放在哪里？为什么顺序重要？
5. race detector 报出来的"data race"和"map 并发写"是同一个问题吗？

---

上一篇：[08-goroutine-channel.md](08-goroutine-channel.md) ｜ 下一篇：[10-error.md](10-error.md) ｜ 回到 [00-index.md](00-index.md)
