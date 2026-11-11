# 12 · encoding/json（编解码）

> 一句话：**Go 的 JSON 靠「struct tag」把字段映射到 JSON key。**
> cr-check 里到处是它：解析 GitHub webhook payload、输出 check 详情、写审计日志。

---

## 1. 基本用法

```go
// 编码
b, err := json.Marshal(cfg)
// 解码
var ev pullRequestEvent
err := json.Unmarshal(body, &ev)
```

流式版本（省内存，适合大文件）：

```go
enc := json.NewEncoder(w)      // ★ 直接写进 ResponseWriter
enc.SetIndent("", "  ")        // 缩进
_ = enc.Encode(body)

dec := json.NewDecoder(resp.Body)
err := dec.Decode(&raw)
```

cr-check 两边都用到了：

```go
// internal/webhook/handler.go —— 写响应
enc := json.NewEncoder(w)
enc.SetIndent("", "  ")
_ = enc.Encode(body)

// internal/crplatform/crplatform.go —— 读平台响应
if err := json.NewDecoder(resp.Body).Decode(&raw); err != nil {
    return nil, fmt.Errorf("解析 CR 平台响应: %w", err)
}
```

---

## 2. ★ struct tag

```go
type Event struct {
    Time        time.Time `json:"ts"`
    Kind        string    `json:"kind"`
    Repo        string    `json:"repo,omitempty"`
    PR          int       `json:"pr,omitempty"`
    FailedRules []string  `json:"failed_rules,omitempty"`
}
```

| tag | 作用 |
|---|---|
| `json:"name"` | 指定 JSON key |
| `json:"name,omitempty"` | 零值时**不输出**这个字段 |
| `json:"-"` | **完全忽略**这个字段 |
| `json:"name,string"` | 输出成字符串（`"123"` 而不是 `123`） |

### ★ `omitempty` 的"零值"判定

`omitempty` 对下列类型生效（值为零就省略）：

| 类型 | 零值 |
|---|---|
| bool | `false` |
| 数字 | `0` |
| string | `""` |
| 指针/接口 | `nil` |
| slice/map | `len == 0` |
| array | 长度 0（数组不适用 omitempty） |

> ★ **坑**：`int` 字段用 `omitempty` 后，值为 `0` 的字段**会消失**。
> 如果 `0` 和"没有"是两种不同的业务含义，**不要用 `omitempty`**。
> 需要区分就用指针（`*int`）。

### ★ 大小写匹配规则

Go 的 JSON 解析**不区分大小写**地匹配字段名：
JSON 里的 `HeadSHA` 能匹配到 Go 的 `HeadSHA`、`headsha`、`HEADSHA`。

但**编码时用的是 tag 名**（没 tag 就用字段名原样）。

> ★ 这就是为什么 cr-check 的 webhook payload 结构体用了**匿名嵌套 struct**：

```go
type pullRequestEvent struct {
    Action string `json:"action"`
    Number int    `json:"number"`
    PullRequest struct {
        Number int    `json:"number"`
        Title  string `json:"title"`
        Base   struct {
            Ref  string `json:"ref"`
            Repo struct {
                FullName string `json:"full_name"`
            } `json:"repo"`
        } `json:"base"`
        ...
    } `json:"pull_request"`
}
```

**★ 匿名嵌套 struct 会被"拍平"到外层**：
`pull_request.base.ref` 精确对应嵌套的 `Base.Ref`。

---

## 3. ★ 未知字段：默认忽略

Go 的 `json.Unmarshal` **默认忽略**结构体里没有的字段。

这正是 cr-check 想要的：

```go
// internal/webhook/handler.go 的注释
// ── payload 结构（用我们自己的结构体，更宽容）────────────────
```

GitHub 的 webhook payload 有几百个字段，cr-check 只关心 10 个。
**不需要维护"完整字段表"，只声明需要的就行。**

> ★ 什么时候需要严格模式？当"字段拼错了"是静默 bug 的时候。
> 可以自己实现 `UnmarshalJSON` 或用第三方库（如 `json.Decoder.DisallowUnknownFields()`）。

```go
dec := json.NewDecoder(resp.Body)
dec.DisallowUnknownFields()   // ★ 遇到未知字段就报错
```

---

## 4. ★ `omitempty` 在 webhook 响应里的应用

cr-check 的接口返回用 `map[string]any`：

```go
writeJSON(w, http.StatusOK, map[string]any{
    "status": "duplicate", "reason": "该 delivery id 已处理过", "delivery_id": delivery,
})
```

而**结构体**响应用 tag 控制：

```go
// internal/rules/engine.go
type Outcome struct {
    OK            bool      `json:"ok"`
    SystemError   bool      `json:"system_error"`
    SystemMessage string    `json:"system_message,omitempty"`
    CRNumber      string    `json:"cr_number,omitempty"`
    Env           string    `json:"env,omitempty"`
    Results       []Result  `json:"rules"`
    Skipped       []string  `json:"skipped,omitempty"`
    EvaluatedAt   time.Time `json:"evaluated_at"`
}
```

> ★ **设计要点**：`system_message` / `cr_number` 用 `omitempty`，
> 这样正常判定的响应里不会出现 `"system_message": ""` 这种噪音字段。
> 而 `ok` / `system_error` 不用 `omitempty` ——
> **布尔值必须始终出现**，因为"没这个字段"和"false"在语义上不能混淆。

---

## 5. ★ 自定义编解码

### 场景 A：自定义字符串格式（MarshalJSON）

cr-check 的 `crplatform.Status` 是个 `string` 类型的自定义类型：

```go
type Status string

const (
    StatusUnknown   Status = "unknown"
    StatusApproved  Status = "approved"
)
```

它的 JSON 表示就是普通字符串，**不需要任何自定义代码**（因为底层是 string）。
换句话说：**定义 `type X string` 就自动获得 JSON 支持。**

### 场景 B：自定义解析（UnmarshalJSON）

如果字段是"字符串或数字"两种形态（GitHub API 很常见）：

```go
func (s *Status) UnmarshalJSON(b []byte) error {
    // 去掉引号
    var str string
    if err := json.Unmarshal(b, &str); err == nil {
        *s = Status(str)
        return nil
    }
    var num int
    if err := json.Unmarshal(b, &num); err == nil {
        *s = Status(strconv.Itoa(num))
        return nil
    }
    return fmt.Errorf("无法解析状态: %s", b)
}
```

> ★ **实现 `json.Unmarshaler` 时注意**：接收者要是**指针**，否则改不了原值。

### 场景 C：整个结构体自定义

```go
func (r platformResponse) toModel(aliases map[string][]string) *ChangeRequest {
    ...
}
```

cr-check 用的是**"解析成原始结构 → 转换成领域模型"**的两段式：

```go
// 平台原始格式（会变）
type platformResponse struct {
    Number    string `json:"number"`
    Status    string `json:"status"`
    Approvers []struct {
        Approver  string `json:"approver"`
        DecidedAt string `json:"decidedAt"`
    } `json:"approvers"`
    ...
}

// 内部规范化模型（稳定）
type ChangeRequest struct {
    Number    string     `json:"number"`
    Status    Status     `json:"status"`
    Approvers []Approval `json:"approvers"`
    ValidFrom time.Time  `json:"validFrom"`
    ...
}
```

> ★ **★ 这是一个非常值得学的模式**：
> **外部格式和内部模型解耦**。
> 平台改字段名 → 只改 `platformResponse` + `toModel`；
> 内部所有规则代码一行不动。
> crplatform 包的注释就写明了：
> "★ 职责边界：rules 包只认这里的规范化模型，不认平台的原始响应格式 —— 平台改字段时只需要改这个包。"

---

## 6. ★ 时间字段的处理

```go
type platformResponse struct {
    ValidFrom string `json:"validFrom"`   // ★ 平台给的是字符串
}

type ChangeRequest struct {
    ValidFrom time.Time `json:"validFrom"` // ★ 内部用 time.Time
}
```

转换：

```go
cr.ValidFrom, _ = time.Parse(time.RFC3339, r.ValidFrom)
```

> ★ **注意这里忽略了错误**（`_`）。
> cr-check 在别处更严格（`mockCR.Add` 里也是 `_`）。
> 这在"外部脏数据"场景下是常见的取舍：
> **解析失败就当零值**（`time.Time{}`），后续规则里用 `IsZero()` 区分"没这个字段"。
>
> 对应规则：
> ```go
> if !in.CR.ValidFrom.IsZero() && in.Now.Before(in.CR.ValidFrom) { ... }
> ```

> ★ **另一种写法**：直接用 `time.Time` 字段，
> `encoding/json` 会自动解析 RFC3339 格式的时间字符串。
> 但那样"格式不对"就变成整个 Unmarshal 失败 —— 更严格但更脆。

---

## 7. JSON Lines（审计日志）

cr-check 的审计写文件时用的是"一行一个 JSON 对象"：

```go
if b, err := json.Marshal(e); err == nil {
    b = append(b, '\n')          // ★ 手动补换行
    s.mu.Lock()
    _, _ = f.Write(b)
    s.mu.Unlock()
}
```

这就是 **JSONL / NDJSON** 格式 —— 日志和审计的标准做法：

- 一行一个对象 → 可以流式写、可以 `grep`、可以 `tail -f`
- 不需要整体读入内存

> ★ Go 1.21+ 有 `log/slog` 的 `JSONHandler` 可以直接输出 JSON 日志，
> 见 [18-logging-slog.md](18-logging-slog.md)。

---

## 8. ★ map vs struct：什么时候用哪个

cr-check 两种都用了，用途不同：

| | struct | `map[string]any` |
|---|---|---|
| 字段固定 | ✅ | ❌ |
| 类型安全 | ✅ | ❌ |
| 字段可选（omitempty） | ✅ | 手动判断 |
| 动态字段 | ❌ | ✅ |

```go
// ✅ 字段固定 → struct
type Outcome struct { ... }

// ✅ 动态拼装 → map
writeJSON(w, http.StatusOK, map[string]any{
    "status": "queued", "pr": pr.Number, "repo": pr.Repo, "head_sha": pr.HeadSHA,
})
```

> ★ **注意**：`map[string]any` 里的 key 顺序在编码时会被 **`encoding/json` 排序**（按 key 字母序），
> 所以输出是稳定的，但**不是**你写的顺序。想要顺序就用 struct。

---

## 9. 一页速查

```go
// 编码
b, _ := json.Marshal(v)
b, _ := json.MarshalIndent(v, "", "  ")

// 解码（忽略未知字段）
err := json.Unmarshal(data, &v)

// 解码（严格）
dec := json.NewDecoder(r)
dec.DisallowUnknownFields()
err := dec.Decode(&v)

// 流式写
enc := json.NewEncoder(w)
enc.SetIndent("", "  ")
err := enc.Encode(v)

// tag 速记
`json:"name"`           → 改名
`json:"name,omitempty"` → 零值省略
`json:"-"`              → 忽略
```

---

## 10. 一句话总结

> **Go 的 JSON = struct + tag。**
> - 编码用 tag 名，解码**大小写不敏感**
> - 未知字段默认忽略（webhook 场景正好需要）
> - **`omitempty` 会吞掉 `0` 和 `""`** —— 布尔字段别用
> - **★ 外部格式和内部模型解耦**（`platformResponse` → `ChangeRequest`）
> - 日志/审计用 JSONL（一行一个对象）

---

## 11. 自测题

1. Go 解码时 JSON 的 `head_sha` 能匹配 struct 的 `HeadSHA` 字段吗？
2. `omitempty` 对 `int` 字段的值 `0` 生效吗？如果 `0` 和"没有"业务含义不同，该怎么写？
3. 为什么 crplatform 要定义 `platformResponse` 和 `ChangeRequest` 两个结构体，而不是直接用一个？
4. `json.Marshal(map[string]any{...})` 的输出 key 顺序是写入顺序吗？
5. 为什么审计日志要写成 JSONL 而不是一个大 JSON 数组？

---

上一篇：[11-http.md](11-http.md) ｜ 下一篇：[13-testing.md](13-testing.md) ｜ 回到 [00-index.md](00-index.md)
