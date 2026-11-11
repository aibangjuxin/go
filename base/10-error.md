# 10 · 错误处理（error）

> 一句话：**Go 没有异常。所有可预期的失败都通过返回值 `error` 表达。**
> cr-check 里最关键的一条设计原则是 **fail-closed**：
> **"系统出错"绝不能被当成"检查通过"。**

---

## 1. error 就是一个接口

```go
type error interface {
    Error() string
}
```

任何实现了 `Error() string` 的类型都是 error。

标准库预置了几个：

```go
errors.New("xxx")           // 创建
fmt.Errorf("格式化: %w", err)  // 包装
```

---

## 2. ★ 三种处理方式

### 方式 1：直接返回（最常见）

```go
func (c *HTTPClient) Get(ctx context.Context, number string) (*ChangeRequest, error) {
    resp, err := c.http.Do(req)
    if err != nil {
        return nil, fmt.Errorf("调用 CR 平台失败: %w", err)
    }
    ...
}
```

### 方式 2：包装后返回（**推荐**）

`%w` 是 Go 1.13+ 的**错误包装**动词：

```go
return nil, fmt.Errorf("解析 CR 平台响应: %w", err)
```

包装后：
- 错误信息有**上下文**（"解析 CR 平台响应: invalid character 'x'"）
- 原始错误**没丢**，`errors.Is` / `errors.As` 还能认出它

> ★ **`%w` vs `%v` 的区别**：
> - `%v` → 只是把错误转成字符串，**原始错误丢失**，无法 `errors.Is`
> - `%w` → 建立**链条**，可以 `errors.Is` / `errors.As`
>
> **有条件就用 `%w`。** 这是 Go 社区的强约定。

### 方式 3：处理掉（不返回）

```go
// internal/crplatform/crplatform.go
resp, err := c.http.Do(req)
if err != nil {
    return nil, fmt.Errorf("调用 CR 平台失败: %w", err)
}
defer func() { _ = resp.Body.Close() }()   // ★ Close 的错误显式忽略
```

如果确定这个错误不重要，显式忽略它（写 `_ =`），
**不要写 `defer resp.Body.Close()`**（go vet 会报 "unhandled error"）。

---

## 3. ★ errors.Is / errors.As

包装之后怎么判断"底层是不是某个特定错误"？

### errors.Is：判断是不是某个"哨兵错误"

```go
// internal/webhook/signature.go
var ErrBadSignature = errors.New("webhook 签名校验失败")

func VerifySignature(secret, body []byte, header string) error {
    if len(secret) == 0 {
        return nil
    }
    if header == "" {
        return fmt.Errorf("%w: 缺少 X-Hub-Signature-256", ErrBadSignature)
    }
    ...
    if !hmac.Equal([]byte(expected), []byte(header)) {
        return ErrBadSignature
    }
    return nil
}
```

调用方：

```go
if err := VerifySignature(...); err != nil {
    h.Metrics.WebhookRejected.WithLabelValues("bad_signature").Inc()
    h.Logger.Warn("webhook 验签失败", "remote", r.RemoteAddr, "err", err)
    writeJSON(w, http.StatusUnauthorized, map[string]any{"error": err.Error()})
    return
}
```

> ★ **哨兵错误（sentinel error）** = 包级 `var ErrXxx = errors.New(...)`。
> 它是**契约**：告诉调用者"我可能会返回这种错误，你可以 `errors.Is` 判断"。

### errors.As：判断是不是某个"具体类型"

```go
var netErr *net.OpError
if errors.As(err, &netErr) {
    // 是网络错误
}
```

### 对照表

| | 判断 | 典型用途 |
|---|---|---|
| `errors.Is(err, ErrXxx)` | 是不是**某个特定错误** | 哨兵错误 |
| `errors.As(err, &target)` | 是不是**某种类型**（取出内部值） | 结构化错误 |

---

## 4. ★ 判断"错误类型"的标准写法

Go 的惯例是：**用返回值表达"发生了什么"，用 error 表达"为什么失败"**。

cr-check 的 `crplatform.Client` 接口注释写得很清楚：

```go
// Client 是查询变更单的接口。
//
// ★ 返回值语义（整个设计的关键）：
//
//	(nil, nil) → 平台确认"不存在" → 业务不通过 → check = failure，理由明确
//	(err)      → 平台超时 / 5xx / 解析失败 → 系统异常 → check = failure（不得写 success）
type Client interface {
    Get(ctx context.Context, number string) (*ChangeRequest, error)
}
```

**★ 这是一个"三态"接口：**

| 返回 | 含义 | 处理 |
|---|---|---|
| `(cr, nil)` | 找到了 | 继续判定 |
| `(nil, nil)` | **确实不存在** | 业务失败：R2 不通过 |
| `(nil, err)` | **调用失败** | 系统异常：fail-closed |

实现：

```go
// HTTPClient.Get
case resp.StatusCode == http.StatusNotFound:
    // 业务语义：变更单不存在
    return nil, nil
case resp.StatusCode >= 500:
    return nil, fmt.Errorf("CR 平台返回 %d", resp.StatusCode)
```

```go
// MockClient.Get
cr, ok := m.items[number]
if !ok {
    return nil, nil // 不存在 = 业务不通过
}
```

> ★ **`(nil, nil)` 看着别扭，但它精确表达了"没找到"和"出错了"的区别。**
> 这是 Go 里非常地道的一种设计 —— 不 new error，就是"这不是错误，是正常结果"。

---

## 5. ★ fail-closed：Go 里最容易翻车的地方

**这是 cr-check 整个设计里最重要的一条。**

```go
// internal/webhook/handler.go
got, err := h.CRClient.Get(ctx, crNumber)
if err != nil {
    // ★ 系统异常：fail-closed
    h.Metrics.CRPlatformCalls.WithLabelValues("error").Inc()
    h.Logger.Error("调用 CR 平台失败（系统异常）", "cr", crNumber, "err", err)
    sys = rules.Outcome{
        OK: false, SystemError: true, SystemMessage: err.Error(),
        CRNumber: crNumber, Env: h.Cfg.EnvForBranch(pr.BaseRef), EvaluatedAt: time.Now(),
    }
    h.writeOutcome(ctx, ref, sys, pr, deliveryID, source)
    h.alert(sys, pr)
    return sys
}
```

**★ 错误写法**（Go 里的经典陷阱）：

```go
// ❌❌❌ 千万别这样
got, err := h.CRClient.Get(ctx, crNumber)
if got == nil {
    // 以为"拿不到就是不存在" → 但平台故障时也拿不到！
    // 结果：平台挂了 = 门禁自动放行 = 灾难
}
```

**`got == nil` 同时覆盖了"不存在"和"调用失败"两种情况**，
而这两者的处理方式完全相反。

### ★ 为什么 fail-closed 是 Go 里的"默认正确选择"

Go 有一条很重要的社区共识：

> **当你不确定时，让程序"停下来报错"，而不是"猜一个答案继续跑"。**

这就是为什么 Go 没有"未捕获异常就吞掉继续执行"的机制 ——
panic 一定会 crash，error 一定会被显式处理。

在 cr-check 里体现为：

```go
// internal/rules/engine.go
func (o Outcome) Conclusion() string {
    if o.OK && !o.SystemError {
        return "success"
    }
    return "failure"        // ★ 任何不确定 → failure
}
```

> ★ **一个更普适的原则**：
> "写不出来的结果"和"没找到的结果"在安全相关的系统里**必须分开**，
> 并且"写不出来"要往**保守**的方向兜底。

---

## 6. ★ 什么时候用 panic

**panic 是"程序内部 bug"，不是"预期内的失败"。**

| 用 error | 用 panic |
|---|---|
| 文件读不到 | 数组越界 |
| 网络超时 | nil 指针解引用 |
| 用户输入非法 | 违反了一个不可能的约定 |
| 对方返回 5xx | `switch` 漏了 case |

### 判定标准

> **"这个错误能靠重试 / 改配置 / 换输入解决吗？"**
> 能 → error
> 不能（说明代码写错了）→ panic

### cr-check 里的 panic 使用：**没有**

整个项目没有一个 `panic()`。这是对的：
webhook 服务里 panic 会导致**整个进程挂掉**，所有 PR 的门禁全失效。

### ★ 那 panic 发生后怎么办？

即使你不主动 panic，运行时错误（nil 解引用、越界）也会 panic。
webhook 服务必须能扛住：

```go
// 典型的 recover 中间件（cr-check 尚未加，但生产必备）
func RecoverMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        defer func() {
            if rec := recover(); rec != nil {
                slog.Error("panic recovered", "err", rec, "path", r.URL.Path)
                writeJSON(w, http.StatusInternalServerError, map[string]any{
                    "error": "internal error",
                })
            }
        }()
        next.ServeHTTP(w, r)
    })
}
```

> ★ Go 标准库 `net/http` **自带**每个请求 goroutine 的 panic 保护：
> `http.Server` 会 recover 住 handler 里的 panic，不让整个进程死。
> 但**默认不写日志**，而且连接会被直接断开。
> 详见 [15-defer-panic-recover.md](15-defer-panic-recover.md)。

---

## 7. ★ 多错误聚合（Go 1.20+）

有时候要同时报告多个错误：

```go
// errors.Join
if err := doA(); err != nil {
    errs = append(errs, err)
}
...
return errors.Join(errs...)
```

`errors.Join` 返回的 error 可以被 `errors.Is` 逐个匹配（对所有被 join 的错误都成立）。

---

## 8. 实战：错误处理 checklist

- [ ] 每个可能失败的调用都检查了 `err`
- [ ] 用 `%w` 包装并加上**有信息量的上下文**（"哪个动作失败了"）
- [ ] 需要被上层识别的错误，用**哨兵错误** + `errors.Is`
- [ ] 需要取出错误内部信息的，用 `errors.As`
- [ ] **区分"没有"和"失败"**（`(nil, nil)` vs `(nil, err)`）
- [ ] 安全相关的判定，**不确定就往保守方向兜底**（fail-closed）
- [ ] 不用 `panic` 处理预期内的失败
- [ ] 忽略错误时显式写 `_ =`

---

## 9. 一句话总结

> **Go 的错误处理 = 返回值 + 显式检查。**
> - `err != nil` 是常态，不是例外
> - `%w` 包装保留错误链，`errors.Is` / `errors.As` 用来识别
> - **哨兵错误**是包对外的契约
> - **★ 区分"没有"和"失败"**，安全系统必须 **fail-closed**
> - panic = 代码有 bug，不是业务失败

---

## 10. 自测题

1. `%w` 和 `%v` 的区别是什么？什么时候必须用 `%w`？
2. `errors.Is` 和 `errors.As` 分别用来判断什么？
3. cr-check 的 `Client.Get` 为什么需要 `(nil, nil)` 这个第三种状态？能不能去掉？
4. 如果把 `if err != nil { ... }` 写成 `if got == nil { ... }`，会在什么场景下出事故？
5. 什么情况下应该用 panic 而不是 error？

---

上一篇：[09-sync.md](09-sync.md) ｜ 下一篇：[11-http.md](11-http.md) ｜ 回到 [00-index.md](00-index.md)
