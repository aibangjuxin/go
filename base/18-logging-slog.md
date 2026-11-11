# 18 · log/slog（结构化日志）

> 一句话：**Go 1.21+ 内置了 `log/slog`，不用再引 logrus/zap。**
> 它输出的是"键值对"而不是"拼出来的字符串"—— 这让日志可以被机器查询。

---

## 1. 为什么不用 fmt.Println

```go
// ❌ 老写法
fmt.Printf("[%s] 判定 PR %s 结论 %s\n", time.Now(), pr, conclusion)
```

问题：
1. **格式固定** → 换字段要改代码
2. **不能按字段过滤** → 没法只查"某个 PR 的所有日志"
3. **不能聚合** → 没法统计"每分钟多少条 error"

```go
// ✅ slog
slog.Info("判定完成", "pr", pr, "conclusion", conclusion, "duration_ms", d.Milliseconds())
```

输出（JSON handler）：

```json
{"time":"2025-01-06T03:00:00.000Z","level":"INFO","msg":"判定完成","pr":"acme/platform#42","conclusion":"success","duration_ms":12}
```

**★ 这行日志可以被任意查询**：
`msg="判定完成" and conclusion="failure"`。

---

## 2. 初始化

cr-check 的 `main.go`：

```go
logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
    Level: slog.LevelInfo,
}))
slog.SetDefault(logger)
```

```go
import "log/slog"
```

### ★ `slog.SetDefault` 的意义

设置后，**整个项目（所有包）都可以直接用** `slog.Info(...)`，
不用到处传 logger。

但 cr-check **同时也把 logger 显式注入到各个组件**：

```go
handler := &webhook.Handler{
    ...
    Logger:      logger,
}
```

> ★ **两种风格对比**：
>
> | | `slog.Info`（全局默认） | 注入 `*slog.Logger` |
> |---|---|---|
> | 优点 | 简洁，第三方库也能用 | **可测试**、可多实例、可按组件区分 |
> | 缺点 | 难替换 | 啰嗦 |
>
> **cr-check 的做法是对的**：内部组件用注入（可测试），
> `main` 里 `SetDefault` 兜底（给标准库/第三方库用）。
> 这也是为什么 `audit.Sink`、`check.LogWriter` 都持有自己的 `*slog.Logger`。

### Text vs JSON Handler

```go
slog.NewJSONHandler(os.Stdout, nil)   // JSON —— 生产
slog.NewTextHandler(os.Stdout, nil)   // 文本 —— 本地
```

> ★ **生产用 JSON**（k8s 会收集容器 stdout），
> 本地想看人话就用 Text。
>
> **更好的做法**：根据环境自动切换。
> ```go
> var h slog.Handler
> if cfg.Server.LogFormat == "text" {
>     h = slog.NewTextHandler(os.Stdout, nil)
> } else {
>     h = slog.NewJSONHandler(os.Stdout, nil)
> }
> ```
> 或者干脆**只在本地用 Text，生产用 JSON** —— 通过环境变量切换。

---

## 3. 级别

```go
slog.Debug("调试信息")   // 最啰嗦
slog.Info("正常事件")
slog.Warn("需要注意")
slog.Error("出错了")
```

| 级别 | 用途 | cr-check 里的例子 |
|---|---|---|
| `Debug` | 调试细节，**生产关掉** | （目前没有） |
| `Info` | 正常业务事件 | `"开始判定"`, `"HTTP 服务已启动"` |
| `Warn` | 异常但能继续 | `"webhook 验签失败"`, `"重扫时结论发生翻转"` |
| `Error` | 需要人介入 | `"调用 CR 平台失败（系统异常）"`, `"⚠️ 门禁系统异常"` |

### ★ 级别要对应"要不要叫醒人"

cr-check 的告警分级很清晰：

```go
// 验签失败 —— 可能是攻击者，也可能是我配错了 secret
h.Logger.Warn("webhook 验签失败", "remote", r.RemoteAddr, "err", err)

// CR 平台挂了 —— 门禁会 fail-closed，影响所有人
h.Logger.Error("调用 CR 平台失败（系统异常）", "cr", crNumber, "err", err)

// 需要人工介入
h.Logger.Error("⚠️ 门禁系统异常（fail-closed），需要人工介入",
    "pr", pr.Key(), "error", o.SystemMessage, "action", "检查 CR 平台可用性与网络出网")
```

> ★ **注意最后那条日志带了 `action` 字段** ——
> 直接告诉运维"下一步该做什么"。这比只说"失败了"有用一百倍。

### ★ 日志级别要能动态调

```go
level := slog.LevelInfo
if os.Getenv("LOG_LEVEL") == "debug" {
    level = slog.LevelDebug
}
logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: level}))
```

> ★ **生产环境要能临时开 debug**（排查问题），
> 但**不能为了排查而重新发版** —— 这就是"级别可配置"的意义。

---

## 4. ★ 属性（attrs）

### 4.1 内联属性

```go
slog.Info("开始判定", "pr", pr.Key(), "base", pr.BaseRef, "sha", pr.HeadSHA, "source", source)
```

**★ Go 的 slog 用"键, 值, 键, 值"成对出现**，不是 map。
编译器会检查参数个数是否成对 —— 传错了直接编译错误。

### 4.2 预格式化属性（`LogValuer`）

```go
// 预格式化：只有真的输出时才做格式化
slog.Info("开始判定", "pr", pr.Key(), "results", outcome.Results)
```

slog 会对实现了 `slog.LogValuer` 的类型调用 `LogValue()`。

```go
func (o Outcome) LogValue() slog.Value {
    return slog.GroupValue(
        slog.String("ok", strconv.FormatBool(o.OK)),
        slog.Int("results", len(o.Results)),
    )
}
```

> ★ **性能技巧**：日志级别被过滤掉时，
> slog **不会**计算那些昂贵的参数（因为 `slog.Info` 是惰性的）。
> 但 `fmt.Sprintf` 是在**调用前**就计算完了 —— 所以
> **不要用 `slog.Info("x: " + fmt.Sprintf(...))`**，要传键值对。

### 4.3 `With` 绑定上下文

```go
logger := slog.Default().With("service", "cr-check", "version", Version)
logger.Info("启动")     // 自动带上 service 和 version
```

**★ 典型用法**：在 HTTP 中间件里注入 `request_id`：

```go
func RequestID(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        rid := r.Header.Get("X-Request-Id")
        if rid == "" {
            rid = uuid.NewString()
        }
        next.ServeHTTP(w, r.WithContext(
            context.WithValue(r.Context(), requestIDKey{}, rid),
        ))
    })
}
```

### 4.4 ★ 从 context 里取 logger

`slog` 提供了 context 集成：

```go
// 把 logger 放进 ctx
ctx = slog.NewContext(ctx, logger)

// 在深处取出来
logger := slog.FromContext(ctx)
logger.Info("深层调用")
```

> ★ 这解决了"我不想把 logger 一层层传下去"的痛点。
> 和 `installation_id` 走 ctx 的思路一样 —— **ctx 传"这次调用的环境"**。

---

## 5. ★ 审计日志 ≠ 普通日志

cr-check 明确区分了两者：

```go
// internal/audit/sink.go
// ★ 判定结论不能只存在 GitHub check 里 —— 半年后问"生产上这版是谁批的"，
// 没人答得上来。每一次判定都必须留一条可检索的记录。
type Event struct {
    Time        time.Time `json:"ts"`
    Kind        string    `json:"kind"`
    Repo        string    `json:"repo,omitempty"`
    PR          int       `json:"pr,omitempty"`
    Conclusion  string    `json:"conclusion,omitempty"`
    FailedRules []string  `json:"failed_rules,omitempty"`
    ...
}
```

```go
func (s *Sink) Record(e Event) {
    e.Time = time.Now()
    s.mu.Lock()
    s.recs = append(s.recs, e)
    ...
    s.mu.Unlock()

    s.logger.Info("audit", "kind", e.Kind, "repo", e.Repo, ...)

    if f != nil {
        if b, err := json.Marshal(e); err == nil {
            b = append(b, '\n')
            ...
        }
    }
}
```

### ★ 两者对比

| | 普通日志 | 审计日志 |
|---|---|---|
| 目的 | 排查问题 | **证明发生了什么** |
| 生命周期 | 几天~几周 | **长期（合规要求）** |
| 丢失后果 | 不影响业务 | **可能违反审计要求** |
| 存储 | stdout → 采集 | **专用存储（不可篡改）** |
| 完整性 | 不保证 | 需要防篡改 |

> ★ **审计日志应该写到独立的、append-only 的存储**，
> 而不是只打 stdout。cr-check 写文件（JSONL）是"最低配版本"，
> 生产上应该写到 Cloud Logging / BigQuery / 专门的审计存储。

### ★ 区分"谁做了什么"

cr-check 的审计记录包含：

```go
DeliveryID:  deliveryID,   // GitHub 的投递 ID → 可回溯源事件
Source:      source,       // "webhook" | "recheck" → 知道是实时还是重扫
FailedRules: outcome.FailedIDs(),  // 具体哪条规则
SystemError: outcome.SystemError,
```

**★ `Source` 字段很有价值**：能区分"事件驱动的判定"和"定时重扫的判定"。
排查"为什么结论变了"时，这是关键信息。

---

## 6. ★ 不要用日志做指标

| | 日志 | 指标（Prometheus） |
|---|---|---|
| 形态 | 离散事件 | 聚合数值 |
| 查询 | 按字段过滤 | 统计（rate / sum / avg） |
| 用途 | 排查具体问题 | 告警、趋势图 |

cr-check **两者都有**，而且分工清晰：

```go
// 指标：可聚合
h.Metrics.WebhookRejected.WithLabelValues("duplicate").Inc()
h.Metrics.EvaluationTime.Observe(time.Since(start).Seconds())
h.Metrics.RuleFailed.WithLabelValues(id).Inc()

// 日志：单条事件
h.Logger.Info("开始判定", "pr", pr.Key(), ...)
```

> ★ **★ 关键原则**：
> **"读到了但没写出去"必须是一个独立告警，不能靠间接现象发现。**
> 这是 cr-check 注释里写的话，翻译到工程实践就是：
>
> | 想监控的 | 正确做法 |
> |---|---|
> | 有多少请求 | Counter |
> | 请求多慢 | Histogram |
> | 队列积压 | Gauge |
> | **写 check 失败了** | **独立的 Counter + 告警**（不能靠"结论数对不上"推断） |

```go
if err := h.Writer.Complete(ctx, ref, outcome); err != nil {
    h.Logger.Error("写 check 结论失败", "err", err)
    h.Metrics.GitHubAPIErrors.WithLabelValues("check_write").Inc()  // ★ 独立指标
}
```

---

## 7. 实战 checklist

- [ ] 生产用 `JSONHandler`，本地用 `TextHandler`（或用环境变量切换）
- [ ] `slog.SetDefault` 兜底 + 关键组件显式注入 `*slog.Logger`
- [ ] 日志级别可配置（`LOG_LEVEL` 环境变量）
- [ ] **键值成对**传参，不要用 `fmt.Sprintf` 拼字符串
- [ ] 不要打敏感信息（token、私钥、webhook secret）
- [ ] 错误日志要带**上下文**（哪个 PR、哪个 CR、哪个 delivery）
- [ ] 告警级日志要带 `action`（下一步该做什么）
- [ ] **审计日志和普通日志分开存**
- [ ] 需要 trace 贯穿请求链路 → 注入 `request_id` 到 ctx

---

## 8. 一页速查

```go
logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
slog.SetDefault(logger)

slog.Debug("...", "k", v)
slog.Info("...", "k", v)
slog.Warn("...", "k", v)
slog.Error("...", "k", v)

logger = logger.With("service", "cr-check")
logger.Info("...")

ctx = slog.NewContext(ctx, logger)
logger := slog.FromContext(ctx)
```

---

## 9. 一句话总结

> **`log/slog` = 标准库的结构化日志，不用引第三方。**
> - 键值对传参（不是拼字符串）→ 可被机器查询
> - 生产 JSON / 本地 Text；级别可配置
> - **`slog.SetDefault` 兜底 + 显式注入给组件**（可测试）
> - **审计日志 ≠ 普通日志**：长期、防篡改、含"谁做了什么"
> - **日志 ≠ 指标**：可聚合的用 Prometheus
> - **"写失败了"要有独立指标 + 告警**

---

## 10. 自测题

1. slog 的属性为什么用"键, 值, 键, 值"成对传，而不是传一个 map？
2. 为什么不推荐 `slog.Info("x: " + fmt.Sprintf(...))`？
3. `slog.SetDefault` 和把 logger 注入到结构体，两种方式各适合什么场景？
4. 审计日志和普通日志的三个关键区别是什么？
5. 为什么"写 check 失败"必须有一个独立指标，而不能靠"判定总数"推断？
6. cr-check 的 `Source` 字段（webhook / recheck）为什么有用？

---

上一篇：[17-modules-build.md](17-modules-build.md) ｜ 回到 [00-index.md](00-index.md)
