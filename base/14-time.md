# 14 · time 包（时间与时区）

> 一句话：**Go 的时间类型是 `time.Time`（值类型，带单调时钟），
> 时长是 `time.Duration`（int64 纳秒）。**
> cr-check 的维护窗口规则完全建立在时间之上，所以这块必须精确。

---

## 1. 两个核心类型

```go
type Duration int64        // 单位：纳秒
type Time struct { ... }   // 墙钟时间 + 单调时钟
```

### time.Duration

```go
const (
    Nanosecond  Duration = 1
    Microsecond          = 1000 * Nanosecond
    Millisecond          = 1000 * Microsecond
    Second               = 1000 * Millisecond
    Minute               = 60 * Second
    Hour                 = 60 * Minute
)
```

它本质是 `int64`，所以可以直接加减：

```go
d := 10*time.Second + 500*time.Millisecond
fmt.Println(d)        // 10.5s
fmt.Println(d.Seconds())  // 10.5
```

> ★ **千万不要用 `int` 表示时长**：
> ```go
> timeout := 30              // ❌ 单位不明，是纳秒还是秒？
> timeout := 30 * time.Second // ✅
> ```
> cr-check 的配置层用 `int` 存秒，转换时用 `time.Duration(...) * time.Second`：
> ```go
> time.Duration(cfg.CRPlatform.TimeoutSeconds) * time.Second
> time.Duration(cfg.Server.RecheckIntervalSeconds) * time.Second
> ```

### time.Time

```go
now := time.Now()
t := time.Date(2025, 1, 6, 3, 0, 0, 0, loc)
```

常用方法：

| 方法 | 作用 |
|---|---|
| `t.Format("2006-01-02 15:04:05")` | 格式化 |
| `t.Before/After(t2)` | 比较 |
| `t.Add(d)` / `t.AddDate(y,m,d)` | 加时间 |
| `t.In(loc)` | 换时区 |
| `t.UTC()` | 转 UTC |
| `t.IsZero()` | 是否零值 |
| `t.Sub(t2)` | 差值（返回 Duration） |
| `t.Weekday()` | 星期几 |

---

## 2. ★ 时间格式的魔法字符串

Go 用**参考时间** `2006-01-02 15:04:05` 来表示格式：

```go
t.Format("2006-01-02 15:04:05 MST")   // 2025-01-06 03:00:00 CST
t.Format(time.RFC3339)                // 2025-01-06T03:00:00+08:00
t.Format("15:04")                     // 03:00
```

常用常量：

```go
time.RFC3339      // "2006-01-02T15:04:05Z07:00"
time.RFC3339Nano  // 带纳秒
time.DateOnly     // "2006-01-02"
time.TimeOnly     // "15:04:05"
```

> ★ **为什么是 2006？**
> 因为它是 Go 的诞生年（2006-01-02 15:04:05）。
> 记住 "01/02 03:04:05PM '06 -0700" 这个模板就行。

cr-check 里：

```go
// internal/rules/engine.go
fmt.Fprintf(&b, "- **判定时刻**：`%s`\n", o.EvaluatedAt.Format(time.RFC3339))

// internal/rules/window.go
fmt.Fprintf(&b, "...当前 %s）", w.StartMin, ..., in.Now.In(w.Loc).Format("2006-01-02 15:04:05 MST"))
```

---

## 3. ★ 时区：必须用 IANA 名

```go
loc, err := time.LoadLocation("Asia/Shanghai")
```

**★ 绝不要用固定偏移量**：

```go
// ❌❌❌ 千万别这样
loc := time.FixedZone("CST", 8*3600)
```

原因：
1. **夏令时**：有 DST 的地区固定偏移会错（虽然中国目前没有，但代码是通用的）
2. **时区政策会变**：历史上改过时区的国家很常见
3. **名字有歧义**：`CST` 既是"中国标准时间"也是"美国中部时间"

> ★ cr-check 的测试里用了 `time.FixedZone("CST", 8*3600)` ——
> 那是**测试里写死一个固定时刻**的简写，可以接受；
> 但**生产代码必须用 `time.LoadLocation("Asia/Shanghai")`**，
> cr-check 的生产代码正是这么做的（见下）。

### cr-check 的时区处理

```go
// internal/config/config.go
func (c *Config) Validate() error {
    if c.Timezone == "" {
        c.Timezone = "UTC"
    }
    if _, err := time.LoadLocation(c.Timezone); err != nil {
        return fmt.Errorf("timezone %q 无效: %w", c.Timezone, err)
    }
    ...
}
```

```yaml
timezone: Asia/Shanghai
```

```go
// internal/rules/window.go
loc, err := time.LoadLocation(tz)
if err != nil {
    return nil, fmt.Errorf("窗口时区 %q 无效: %w", tz, err)
}
```

> ★ **配置里的时区要在启动时校验**，
> 配错了就在启动时报错，而不是等到凌晨窗口判定时才发现。

> ★ **容器里的时区问题**：alpine/distroless 镜像默认是 UTC。
> 所以**永远用 IANA 名 + `time.LoadLocation`**，
> 不要依赖 `TZ` 环境变量或 `time.Local`。
> Go 需要 tzdata 时可以 `import _ "time/tzdata"` 把时区数据嵌进二进制。

---

## 4. ★ 维护窗口：时区的真正难点

cr-check 的 R6w 规则判"当前是否在维护窗口内"。

### 配置

```yaml
windows:
  - env: prd
    days: [Mon, Tue, Wed, Thu, Fri]
    start: "02:00"
    end: "04:00"
    tz: Asia/Shanghai
```

### 解析

```go
func ParseWindow(cfg config.WindowConfig, defaultTZ string) (*Window, error) {
    tz := cfg.TZ
    if tz == "" {
        tz = defaultTZ        // ★ 窗口可以覆盖全局时区
    }
    loc, err := time.LoadLocation(tz)
    ...
    start, err := config.ParseHM(cfg.Start)   // "02:00" → 120（当天零点起的分钟数）
    end, err := config.ParseHM(cfg.End)       // "04:00" → 240
    w := &Window{
        Env: cfg.Env,
        Days: map[time.Weekday]bool{},
        StartMin: start, EndMin: end,
        Loc: loc,
    }
    for _, d := range cfg.Days {
        wd, ok := parseWeekday(d)
        if !ok {
            return nil, fmt.Errorf("未知的星期: %q", d)
        }
        w.Days[wd] = true
    }
    return w, nil
}
```

### ★ "HH:MM" → 分钟数的转换

```go
func parseHM(s string) (int, error) {
    parts := strings.Split(strings.TrimSpace(s), ":")
    if len(parts) != 2 {
        return 0, fmt.Errorf("期望 HH:MM，得到 %q", s)
    }
    h, err := strconv.Atoi(parts[0])
    if err != nil || h < 0 || h > 24 {
        return 0, fmt.Errorf("小时非法: %q", s)
    }
    m, err := strconv.Atoi(parts[1])
    if err != nil || m < 0 || m > 59 {
        return 0, fmt.Errorf("分钟非法: %q", s)
    }
    return h*60 + m, nil
}
```

> ★ **为什么转成"当天零点起的分钟数"？**
> 因为这样比较就是**整数比较**，不需要构造 `time.Time` 再比较。
> 少一次时区换算 = 少一个 bug。

### ★ 判定：左闭右开 + 跨零点

```go
func (w *Window) Contains(t time.Time) bool {
    n := t.In(w.Loc)              // ★ 先转到窗口时区
    minute := n.Hour()*60 + n.Minute()

    if w.StartMin < w.EndMin {
        // 不跨零点
        return w.Days[n.Weekday()] && minute >= w.StartMin && minute < w.EndMin
    }
    // 跨零点（start > end，如 22:00 → 02:00）
    if minute >= w.StartMin && w.Days[n.Weekday()] {
        return true                                    // 今天 start 之后
    }
    if minute < w.EndMin {
        prev := n.AddDate(0, 0, -1).Weekday()          // ★ 前一天
        return w.Days[prev]                            // 昨天 start 延续到今天 end 之前
    }
    return false
}
```

**★ 三个考点**：

1. **左闭右开 `[start, end)`** —— 04:00 整就**不在**窗口内。
   选左闭右开是为了相邻窗口能无缝衔接（`[2:00,4:00)` 和 `[4:00,6:00)`）。
2. **先 `t.In(w.Loc)`** —— 必须用**窗口的时区**判断星期和分钟，
   不能用 UTC 或服务器本地时区。
3. **跨零点要看"前一天"** —— 周一 22:00 到周二 02:00 都在窗口内，
   所以周二 01:00 要看**周一**是否在 Days 里。

对应的测试：

```go
{"窗口开始（闭区间）", time.Date(2025, 1, 6, 2, 0, 0, 0, loc), true},
{"窗口结束（开区间）", time.Date(2025, 1, 6, 4, 0, 0, 0, loc), false},
{"周二 01:00（跨零点延续）", time.Date(2025, 1, 7, 1, 0, 0, 0, loc), true},
```

---

## 5. ★ 有效期判定（R6）

```go
func ruleR6(_ context.Context, _ *Engine, in Input) Result {
    if in.CR == nil {
        return Result{"R6", false, "变更单不存在，无法检查有效期"}
    }
    if !in.CR.ValidFrom.IsZero() && in.Now.Before(in.CR.ValidFrom) {
        return Result{"R6", false, fmt.Sprintf(
            "变更单 %s 尚未生效（生效时间 %s，当前 %s）", ...)}
    }
    if !in.CR.ValidTo.IsZero() && in.Now.After(in.CR.ValidTo) {
        return Result{"R6", false, fmt.Sprintf(
            "变更单 %s 已过期（有效期至 %s，当前 %s）", ...)}
    }
    valid := "永久有效"
    if !in.CR.ValidTo.IsZero() {
        valid = "有效期至 " + in.CR.ValidTo.Format(time.RFC3339)
    }
    return Result{"R6", true, fmt.Sprintf("变更单 %s 在有效期内（%s）", in.CR.Number, valid)}
}
```

**★ 关键点：`IsZero()` 判断"没设置有效期"**。
`time.Time` 的零值是 `0001-01-01 00:00:00 UTC`，
不判断 `IsZero` 的话，"永久有效"会被判成"1970 年就过期了"。

**★ 另一个关键点：`in.Now` 是注入进来的**，不是 `time.Now()`。
这让规则可测试，也让"用固定时间调试"成为可能（`-now` 参数）。

---

## 6. ★ 定时任务：Ticker

```go
// internal/recheck/recheck.go
func (s *Scheduler) Run(ctx context.Context) {
    ticker := time.NewTicker(s.Interval)
    defer ticker.Stop()                    // ★ 必须 Stop，否则泄漏
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

### ★ Ticker vs Timer

| | `NewTicker(d)` | `NewTimer(d)` |
|---|---|---|
| 触发 | 周期触发 | 触发一次 |
| 停止 | `Stop()` | `Stop()` |
| 典型用途 | 定时重扫、指标采集 | 超时、延迟执行 |

### ★ 三个必记的坑

**坑 1：`time.Tick` 会泄漏**

```go
for range time.Tick(time.Second) { ... }   // ❌ 永远不释放
```

必须用 `NewTicker` + `defer ticker.Stop()`。

**坑 2：`time.After` 在循环里会泄漏**

```go
for {
    select {
    case <-time.After(5 * time.Second):   // ❌ 每次循环新建一个 timer
        ...
    }
}
```

Go 1.23+ 改了 GC 行为，未触发的 `time.After` 现在可以被回收了，
但**依然推荐用 `NewTimer` + `Stop()`** —— 语义更清楚。

**坑 3：Ticker 会"追赶"**

如果处理耗时超过间隔，Ticker 会**丢掉中间的 tick**（不堆积）。
这正好符合"定时重扫"的语义 —— 宁可少扫，也不要堆积。

---

## 7. ★ 超时的三种写法

```go
// 1) context 超时（推荐，能传导到下游）
ctx, cancel := context.WithTimeout(parent, 5*time.Second)
defer cancel()

// 2) HTTP 客户端超时
client := &http.Client{Timeout: 5 * time.Second}

// 3) 裸 timer（仅限不需要传导的场景）
timer := time.NewTimer(5 * time.Second)
defer timer.Stop()
select {
case <-ctx.Done():
case <-timer.C:
}
```

> ★ **优先用 context**：只有它能把取消信号传导到下游（HTTP 请求、数据库查询）。

---

## 8. ★ 单调时钟与墙钟

`time.Now()` 返回的 `time.Time` 里其实有两个部分：
- **墙钟时间**（wall clock）：能被 NTP 调整，会突然跳变
- **单调时钟**（monotonic clock）：只在 Go 进程内单调递增，永不跳变

`Sub()` 用的是**单调时钟** → 算耗时不受系统时间调整影响。

```go
start := time.Now()
doWork()
cost := time.Since(start)   // ★ 用 monotonic，安全
```

> ★ **推论**：
> `time.Time` 可以用 `==` 比较吗？**不建议** ——
> 同一个时刻的 `time.Time` 可能有不同的单调时钟读数和位置信息。
> **一律用 `Equal()` / `Before()` / `After()`。**

---

## 9. 一页速查

```go
d := 5 * time.Second
now := time.Now()
t := time.Date(2025, 1, 6, 3, 0, 0, 0, loc)

loc, err := time.LoadLocation("Asia/Shanghai")   // ★ IANA 名
t = t.In(loc)
t.Format(time.RFC3339)
t.Weekday()
t.IsZero()
t.Sub(t2)      // Duration
time.Since(start)
time.Now().Before(t)
```

---

## 10. 一句话总结

> **Go 的时间：`time.Time` 是值类型，`time.Duration` 是 int64 纳秒。**
> - 格式串用参考时间 `2006-01-02 15:04:05`
> - **时区一律用 IANA 名 + `time.LoadLocation`**，绝不用固定偏移
> - **窗口判定先 `t.In(loc)`**，再转"当天分钟数"做整数比较
> - **左闭右开**，跨零点要查"前一天"
> - **`IsZero()` 区分"没设置"和"零值"**
> - **影响判定的"当前时间"必须可注入**（`Clock func() time.Time`）
> - `NewTicker` 一定要 `defer Stop()`

---

## 11. 自测题

1. 为什么不能把时长存成 `int`？用 `int` 存"秒"有什么隐患？
2. 维护窗口为什么先 `t.In(w.Loc)` 再算分钟数？顺序反了会怎样？
3. "22:00 → 02:00" 的窗口，周二 01:00 该怎么判定？为什么要看前一天？
4. `ValidTo` 是零值时，为什么不能直接 `in.Now.After(in.CR.ValidTo)`？
5. `time.Tick` 和 `time.NewTicker` 的区别是什么？为什么前者会泄漏？
6. 为什么 `time.Since(start)` 比 `time.Now().Sub(start)` 更可靠？

---

上一篇：[13-testing.md](13-testing.md) ｜ 下一篇：[15-defer-panic-recover.md](15-defer-panic-recover.md) ｜ 回到 [00-index.md](00-index.md)
