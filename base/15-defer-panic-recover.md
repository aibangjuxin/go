# 15 · defer / panic / recover（资源释放与崩溃）

> 一句话：**defer 负责"一定收尾"，panic 负责"我写错了"，recover 负责"别让进程死"。**
> 三者都是 Go 的"异常路径"工具，但用途完全不同。

---

## 1. defer：延迟执行

```go
defer fmt.Println("world")
fmt.Println("hello")
// 输出：hello → world
```

**defer 里的语句在函数返回前执行**，无论函数是正常返回还是 panic。

### ★ 用途一：释放资源

cr-check 里的 defer：

```go
// internal/crplatform/crplatform.go
resp, err := c.http.Do(req)
if err != nil {
    return nil, fmt.Errorf("调用 CR 平台失败: %w", err)
}
defer func() { _ = resp.Body.Close() }()
```

```go
// cmd/server/main.go
auditSink, err := audit.NewSink(logger, auditFile)
if err != nil {
    return fmt.Errorf("构造审计 sink: %w", err)
}
defer func() {
    if err := auditSink.Close(); err != nil {
        logger.Warn("关闭审计文件失败", "err", err)
    }
}()
```

> ★ **为什么 `resp.Body.Close()` 要包一层 func？**
> ```go
> defer resp.Body.Close()          // ❌ 编译错误
> ```
> `resp.Body.Close()` 返回一个 `error`，
> 而 `defer` 直接调用的函数**返回值会被丢弃** —— Go 编译器会报
> "Error return value is not checked"。
> 用 `defer func() { _ = resp.Body.Close() }()` 就没问题了。
> `go vet` 会帮你检查这类问题。

### ★ 用途二：解锁

```go
mu.Lock()
defer mu.Unlock()
```

（详见 [09-sync.md](09-sync.md)）

### ★ 用途三：计时

```go
func (h *Handler) Evaluate(...) rules.Outcome {
    start := time.Now()
    h.Logger.Info("开始判定", ...)
    defer func() {
        h.Metrics.EvaluationTime.Observe(time.Since(start).Seconds())
    }()
    ...
}
```

> ★ **指标采集用 defer 的好处**：
> 无论中间哪个分支 `return`，指标都会被记录。
> 手写在函数末尾就可能在提前 return 时漏掉。

### ★ defer 的三个关键语义

**语义 1：defer 是在函数**返回时**执行，不是离开作用域时**

```go
func f() {
    defer fmt.Println("A")
    if true {
        defer fmt.Println("B")
        return          // 这里返回 → 先执行 B，再执行 A
    }
}
```

**语义 2：defer 的参数在 defer 语句执行时就求值了**

```go
func f() {
    x := 1
    defer fmt.Println("x =", x)   // ★ 打印 1（现在求值）
    x = 2
    fmt.Println("x =", x)          // 打印 2
}
// 输出：x = 2 → x = 1
```

> ★ **推论**：`defer close(ch)` 里的 `ch` 是**当时那个变量**的值。
> 如果 ch 之后被重新赋值，defer 关闭的还是原来那个。
> 闭包写法 `defer func() { close(ch) }()` 捕获的是**变量本身**，行为不同。

**语义 3：多个 defer 按"后进先出"执行**

```go
defer A()
defer B()
defer C()
// 执行顺序：C → B → A
```

这正好符合"后获取的资源先释放"（LIFO）的直觉。

---

## 2. panic：程序出了不该出的错

```go
panic("错误信息")
panic(err)
panic(fmt.Sprintf("...", x))
```

### ★ 什么时候该 panic

**只有一种情况：代码里存在一个不可能成立的约定。**

| 场景 | 用什么 |
|---|---|
| 文件读不到、网络超时 | `error` |
| 用户输入非法 | `error` |
| 参数没通过校验 | `error` |
| 数组越界、nil 解引用 | `panic`（运行时自动） |
| `switch` 漏了 case | `panic`（"逻辑有 bug"） |
| 初始化阶段发现配置致命错误 | `panic` 或 `os.Exit(1)` |

### ★ Go 的一条重要哲学

> **panic 应该"响亮地崩溃"，而不是"安静地继续"。**
> 静默地带着错误状态继续跑，通常会制造更严重的问题。

cr-check 的 `main` 就是这个思路：

```go
func main() {
    ...
    if err := run(logger, *configPath, ...); err != nil {
        logger.Error("启动失败", "err", err)
        os.Exit(1)     // ★ 启动失败 = 立刻退出，不带病运行
    }
}
```

> ★ **启动失败要 `os.Exit(1)`，不要 `panic`**：
> panic 会打印一大坨堆栈，看起来像"程序崩了"；
> 而配置错误是**运维问题**，给一行清晰的错误日志 + 退出码 1 更专业。
> k8s 会看到退出码 1 → CrashLoopBackOff → 告警。

---

## 3. recover：把 panic 变回普通错误

```go
defer func() {
    if r := recover(); r != nil {
        // r 就是 panic 的值
        fmt.Println("Recovered:", r)
    }
}()
```

### ★ recover 的三条限制

1. **只能在 defer 里调用**（在 deferred 函数内部）
2. **只能捕获同一 goroutine 里的 panic**
3. **只能捕获还没被其它 defer 处理掉的 panic**

> ★ **第 2 条是最容易踩的坑**：
> goroutine A 里的 panic，goroutine B 的 `recover()` **抓不到**。
> 每个 goroutine 要自己 recover。

### ★ cr-check 目前没有 recover，但生产必备

webhook 服务里，一个 handler 的 panic 会导致**整个进程挂掉** → 所有 PR 的门禁全失效。

**好消息**：`net/http` 内置了保护 ——
`http.Server` 会 recover 住 handler 里的 panic，不让进程死。
但：
- 默认**不写日志**（只在 ErrorLog 里打一行）
- 连接会被直接断开

所以生产上应该显式加 recover 中间件：

```go
func RecoverMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        defer func() {
            if rec := recover(); rec != nil {
                slog.Error("panic recovered",
                    "err", rec,
                    "path", r.URL.Path,
                    "stack", string(debug.Stack()))   // ★ 一定要打堆栈
                writeJSON(w, http.StatusInternalServerError, map[string]any{
                    "error": "internal error",
                })
            }
        }()
        next.ServeHTTP(w, r)
    })
}
```

挂上：

```go
mux := http.NewServeMux()
mux.Handle("POST /github/webhook", handler)

srv := &http.Server{
    Handler: RecoverMiddleware(mux),   // ★
    ...
}
```

> ★ **重要**：recover 之后**一定要打 stack**。
> 不打堆栈的 recover 等于把 bug 藏起来了 —— 你只知道"出事了"，不知道"在哪出"。

### ★ recover 后要不要继续跑？

**要**。recover 之后函数会从 panic 点**正常返回**（返回零值）。
所以 recover 的位置很重要：

```go
func f() (result int, err error) {
    defer func() {
        if rec := recover(); rec != nil {
            err = fmt.Errorf("panic: %v", rec)   // ★ 转成 error 返回
        }
    }()
    ...
}
```

这样调用方就能正常处理错误，而不是拿到一个诡异的零值。

---

## 4. ★ panic vs error：怎么选

| | panic | error |
|---|---|---|
| 语义 | "代码有 bug" | "这次操作失败了" |
| 谁处理 | 上层的 recover / 进程崩溃 | 调用方逐层处理 |
| 能否预期 | ❌ 不能 | ✅ 能 |
| Go 社区共识 | 只用于"不可能发生"的情况 | **99% 的场景** |

### ★ 决策树

```
这个失败能靠 重试 / 改配置 / 改输入 解决吗？
├── 能  → error
└── 不能 → 检查是不是代码逻辑写错了
          ├── 是 → panic（让它崩，暴露问题）
          └── 不是（比如"用户输入不合法"）→ error
```

> ★ **一个反直觉但重要的点**：
> 在 Go 里，"panic 太多"通常说明**错误处理没想清楚**，
> 而不是说明"这个错误很严重"。

---

## 5. ★ Go 的 panic vs Java 的 Exception

| | Go | Java |
|---|---|---|
| 机制 | panic + recover | throw + catch |
| 检查 | 运行时 | **编译期强制检查**（受检异常） |
| 漏处理的后果 | 进程崩溃 | 编译不过 |
| 默认行为 | 崩溃 | 沿栈向上抛 |

> ★ **Go 没有受检异常** —— 编译器不强制你处理 error。
> 这是 Go 简洁的代价，也是 Go 社区**极度重视 error 规范**的原因：
> 大家都约定"每个 err 都要处理"，靠纪律而不是编译器。

> ★ **Java 的受检异常其实是个设计失误**（业界共识）：
> 它逼着程序员写出 `catch (Exception e) {}` 这种无意义的代码。
> Go 选择"全部显式返回"，虽然啰嗦但**没有隐藏的异常**。

---

## 6. 实战 checklist

- [ ] 每个 `defer` 都有明确的用途（释放资源 / 解锁 / 计时 / 记指标）
- [ ] `defer resp.Body.Close()` 要写成 `defer func() { _ = resp.Body.Close() }()`
- [ ] 锁用 `defer mu.Unlock()`，不要手动 Unlock
- [ ] 启动失败用 `os.Exit(1)` + 清晰日志，不用 panic
- [ ] 业务失败用 error 返回，不用 panic
- [ ] HTTP 服务加 recover 中间件，**并且打 stack**
- [ ] 每个 goroutine 自己负责 recover（recover 跨不了 goroutine）
- [ ] recover 后把 panic 转成 error 返回给调用方

---

## 7. 一句话总结

> **defer = 一定收尾；panic = 我写错了；recover = 别让进程死。**
> - defer 在**函数返回时**执行，参数**当时求值**，多个 defer **后进先出**
> - `defer resp.Body.Close()` 要包一层 func（返回值不能丢）
> - panic 只用于"不可能发生"的情况；业务失败一律 error
> - 启动失败 `os.Exit(1)` 比 panic 更专业
> - **recover 必须在 defer 里，且只管当前 goroutine**
> - HTTP 服务一定要有 recover 中间件，**必须打 stack**

---

## 8. 自测题

1. `defer fmt.Println(x)` 里 `x` 在什么时候求值？
2. 为什么 `defer resp.Body.Close()` 会编译报错？怎么改？
3. 三个 `defer` 的执行顺序是什么？为什么是这样？
4. 启动时发现配置文件格式错误，用 `panic` 还是 `os.Exit(1)`？为什么？
5. goroutine A 里的 panic 能被 goroutine B 的 recover 捕获吗？
6. recover 之后为什么要打 `debug.Stack()`？

---

上一篇：[14-time.md](14-time.md) ｜ 下一篇：[16-slice-map-stdlib.md](16-slice-map-stdlib.md) ｜ 回到 [00-index.md](00-index.md)
