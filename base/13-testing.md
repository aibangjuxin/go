# 13 · 测试（testing）

> 一句话：**Go 把测试做进了语言本身** —— `go test` 是标准工具链的一部分，
> `_test.go` 文件 + `testing.T` + `t.Run` 就够了，**不需要 mock 框架**。
> cr-check 的测试全部零第三方依赖。

---

## 1. 测试文件放哪

- 文件名以 `_test.go` 结尾
- 和被测代码**同一个包**（白盒）或 `xxx_test` 包（黑盒）
- 测试函数名 `TestXxx`，签名 `func(t *testing.T)`

```go
// internal/rules/rules_test.go
package rules

func TestExtractCRNumbers(t *testing.T) { ... }
func TestWindowContains(t *testing.T) { ... }
```

```bash
go test ./...                # 跑全部
go test -run TestWindow ./...  # 只跑名字匹配的
go test -v ./internal/rules  # 详细输出
```

---

## 2. ★ 表驱动测试（Table-driven）

**这是 Go 社区最主流的测试写法**，cr-check 大量使用：

```go
func TestExtractCRNumbers(t *testing.T) {
    cases := []struct {
        name      string
        labels    []string
        body      string
        wantCount int
        wantFirst string
        wantConf  bool
    }{
        {
            name:      "label 载体",
            labels:    []string{"cr/1234", "feature"},
            body:      "",
            wantCount: 1, wantFirst: "1234",
        },
        {
            name:      "body marker 载体",
            labels:    nil,
            body:      "描述\n\nChange-Request: 5678\n",
            wantCount: 1, wantFirst: "5678",
        },
        {
            name:      "label 与 body 冲突 → 必须报冲突",
            labels:    []string{"cr/1234"},
            body:      "Change-Request: 5678",
            wantCount: 2, wantFirst: "1234", wantConf: true,
        },
        // ...
    }

    for _, tc := range cases {
        t.Run(tc.name, func(t *testing.T) {
            got := ExtractCRNumbers(tc.labels, tc.body, `^cr/[0-9A-Za-z._-]+$`, "cr/", "Change-Request:")
            if len(got.Numbers) != tc.wantCount {
                t.Fatalf("数量 = %d，期望 %d（结果 %v）", len(got.Numbers), tc.wantCount, got.Numbers)
            }
            if tc.wantCount > 0 && got.First() != tc.wantFirst {
                t.Errorf("首个编号 = %q，期望 %q", got.First(), tc.wantFirst)
            }
            if got.Conflict != tc.wantConf {
                t.Errorf("冲突标记 = %v，期望 %v", got.Conflict, tc.wantConf)
            }
        })
    }
}
```

### ★ 三个要点

**要点 1：匿名结构体定义用例表**

```go
cases := []struct {
    name string
    ...
}{ ... }
```

**要点 2：`t.Run` 给每个用例起名字**

失败时输出长这样，一眼定位：

```
=== RUN   TestExtractCRNumbers/label_与_body_冲突
    rules_test.go:64: 冲突标记 = false，期望 true
--- FAIL: TestExtractCRNumbers/label_与_body_冲突
```

**要点 3：`Fatalf` vs `Errorf`**

| | 行为 |
|---|---|
| `t.Fatalf` | 打印并**终止当前测试函数** |
| `t.Errorf` | 打印并**继续**跑后面的断言 |

**规则：前置条件失败用 `Fatalf`，并列的独立断言用 `Errorf`。**
这样一次能报出多个问题，而不是修一个跑一次。

### ★ Go 1.22+ 的循环变量语义变更

Go 1.22 起，`for` 循环里的变量**每轮都是新的**，
所以 `t.Run` 的闭包捕获不再需要 `tc := tc`：

```go
for _, tc := range cases {
    t.Run(tc.name, func(t *testing.T) {   // ★ Go 1.22+ 安全
        ...
    })
}
```

> Go 1.21 及更早必须写 `tc := tc`。
> cr-check 的 go.mod 是 `go 1.27.3`，**不需要**那行 —— 别被老博客误导。

---

## 3. ★ t.Helper()

```go
func newTestHandler(t *testing.T) (*Handler, *check.LogWriter) {
    t.Helper()      // ★ 标记这是辅助函数
    ...
}
```

**作用**：报错时堆栈指向**调用者**而不是辅助函数内部。

没有 `t.Helper()` 时：

```
handler_test.go:42: 配置校验失败: ...
```
（指向 newTestHandler 内部）

有了之后：

```
handler_test.go:88: 配置校验失败: ...
```
（指向真正调用它的那一行）

> ★ **凡是接收 `*testing.T` 的辅助函数，第一行就写 `t.Helper()`。**
> 这是 Go 测试的社区惯例。

---

## 4. ★ httptest：测 HTTP handler

不需要起真的服务器：

```go
// internal/webhook/handler_test.go
func post(h *Handler, body []byte, delivery string) (int, map[string]any) {
    r := httptest.NewRequest(http.MethodPost, "/github/webhook", bytes.NewReader(body))
    r.Header.Set("X-GitHub-Event", "pull_request")
    r.Header.Set("X-GitHub-Delivery", delivery)
    w := httptest.NewRecorder()
    h.ServeHTTP(w, r)

    var out map[string]any
    _ = json.Unmarshal(w.Body.Bytes(), &out)
    return w.Code, out
}
```

| API | 作用 |
|---|---|
| `httptest.NewRequest(method, url, body)` | 造一个假请求 |
| `httptest.NewRecorder()` | 造一个假 ResponseWriter，记录状态码和 body |
| `httptest.NewServer(handler)` | **起真的 HTTP 服务器**（测客户端用） |
| `httptest.NewTLSServer(handler)` | 带 TLS 的真服务器 |

### 测客户端时用 NewServer

```go
srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
    w.Write([]byte(`{"number":"1234","status":"approved"}`))
}))
defer srv.Close()

client := crplatform.NewHTTPClient(srv.URL, "token", "/api/cr/{number}", time.Second, aliases)
cr, err := client.Get(context.Background(), "1234")
```

---

## 5. ★ Fakes 而不是 Mocks

cr-check 里有一个手工实现的 fake：

```go
// internal/crplatform/crplatform.go
type MockClient struct {
    mu      sync.RWMutex
    items   map[string]*ChangeRequest
    errs    map[string]error
    aliases map[string][]string
}

func (m *MockClient) Add(cr *ChangeRequest) { ... }
func (m *MockClient) AddError(number string, err error) { ... }
```

**★ Go 社区强烈偏好 fake（假实现）而不是 mock（严格验证调用次数/参数）。**

| | Mock | Fake |
|---|---|---|
| 验证 | "这个方法必须被调用一次，参数是 X" | "给我一个可用的假实现" |
| 耦合度 | 高（测试跟着实现改） | 低 |
| Go 生态 | 需要第三方库（gomock 等） | 手写几行就行 |

**★ 理由**：Go 的接口很小、很容易手写 fake，
而 mock 框架带来的"精确调用断言"会让重构变痛苦。

### ★ cr-check 的 fake 设计亮点：能模拟故障

```go
mock.AddError("9999", context.DeadlineExceeded)
```

**★ 这让"系统异常 → fail-closed"这条最关键的逻辑可以被测试覆盖**：

```go
func TestHandler_SystemErrorFailsClosed(t *testing.T) {
    h, _ := newTestHandler(t)
    _, out := post(h, payload("9999", "release/prd"), "d3")

    if out["system_error"] != true {
        t.Fatalf("system_error = %v，期望 true", out["system_error"])
    }
    // ★ 绝不能是 success
    if out["conclusion"] == "success" {
        t.Fatalf("系统异常时结论不能是 success（这是门禁被打开）")
    }
}
```

> ★ **测试要盯住"绝不能发生的事"，不只是"应该发生的事"。**
> `if out["conclusion"] == "success" { t.Fatalf(...) }` 这一行，
> 比任何注释都更能表达这条安全约束。

---

## 6. ★ 依赖注入让测试变简单

注意 `newTestHandler` 里可以直接塞 fake：

```go
mock := crplatform.NewMockClient(cfg.CR.StatusAliases)
mock.Add(&crplatform.ChangeRequest{...})

h := &Handler{
    Cfg:      cfg,
    Engine:   engine,
    CRClient: mock,          // ★ 换成 fake
    Writer:   lw,
    Store:    queue.NewMemoryStore(),
    ...
}
```

**这就是 [05-dependency-injection.md](05-dependency-injection.md) 的回报**：
因为 `Handler.CRClient` 的类型是**接口**，测试才能一行替换成 fake。
如果当时写的是具体类型 `*crplatform.HTTPClient`，这个测试根本没法写。

---

## 7. ★ 时间也要能注入

```go
// internal/webhook/handler.go
type Handler struct {
    ...
    // Clock 返回"当前时间"。生产用 time.Now；
    // 本地可以用 -now 参数固定时间，方便验证维护窗口规则。
    Clock func() time.Time
}

func (h *Handler) now() time.Time {
    if h.Clock != nil {
        return h.Clock()
    }
    return time.Now()
}
```

测试里：

```go
Clock: func() time.Time {
    return time.Date(2025, 1, 6, 3, 0, 0, 0, time.FixedZone("CST", 8*3600))
},
```

**★ 时间不注入就没法写稳定的测试**：
- 维护窗口规则依赖"当前时间"
- 用真实时间写测试 → 半夜跑 CI 突然失败
- 跨时区部署 → 同一份代码在不同机器结果不同

> ★ **凡是影响判定结果的时间/随机数，都要可注入。**
> `Clock func() time.Time` 这种"函数字段"是最简单的可注入手段。

---

## 8. ★ -race 和 -cover

cr-check 的 Makefile：

```makefile
test: ## 跑测试
	go test -race -cover ./...
```

| flag | 作用 |
|---|---|
| `-race` | **检测数据竞态**（见 [09-sync.md](09-sync.md)） |
| `-cover` | 覆盖率 |
| `-coverprofile=out.out` | 生成覆盖率报告（可上传 codecov） |
| `-count=1` | 禁用测试缓存，强制真跑 |
| `-shuffle=on` | **随机打乱测试顺序**（能暴露测试间的隐藏依赖） |
| `-timeout=60s` | 超时（默认 10 分钟，防挂死） |

> ★ **`-race` 让测试慢 2~10 倍**，但这是**必开**的。
> 没有 race detector 的 Go 测试等于没测并发。

### 覆盖率怎么看

```bash
go test -coverprofile=cov.out ./...
go tool cover -html=cov.out     # 生成 HTML 报告
go tool cover -func=cov.out     # 逐函数看
```

> ★ **覆盖率数字本身没有意义**，重要的是：
> **关键路径（判定逻辑、fail-closed 分支）必须 100% 覆盖**，
> 而不是"整体 80%"这种好看的数字。
> cr-check 的 `TestHandler_SystemErrorFailsClosed` 就是关键路径覆盖的典范。

---

## 9. ★ 其他实用技巧

### 只在需要时打印

```go
if t.Failed() {
    t.Logf("完整响应: %v", out)
}
```

### 并行测试

```go
func TestXxx(t *testing.T) {
    t.Parallel()   // ★ 与其它顶层测试并行
}
```

> ⚠️ 并行测试里**不要用共享的全局状态**。

### 跳过

```go
if testing.Short() {
    t.Skip("短模式跳过慢测试")
}
```

### 基准测试

```go
func BenchmarkExtract(b *testing.B) {
    for i := 0; i < b.N; i++ {
        ExtractCRNumbers(labels, body, pattern, prefix, marker)
    }
}
```

```bash
go test -bench=. -benchmem ./...
```

### 模糊测试（Go 1.18+）

```go
func FuzzExtractCRNumbers(f *testing.F) {
    f.Add([]string{"cr/1234"}, "Change-Request: 1234")
    f.Fuzz(func(t *testing.T, labels []string, body string) {
        _ = ExtractCRNumbers(labels, body, `^cr/[0-9A-Za-z._-]+$`, "cr/", "Change-Request:")
    })
}
```

```bash
go test -fuzz=FuzzExtractCRNumbers -fuzztime=30s
```

**★ 模糊测试会自动喂随机输入并把失败的种子存下来**，
特别适合测"解析用户输入"这类代码 —— cr-check 的 `ExtractCRNumbers` 正是这种。

---

## 10. cr-check 的测试清单（可直接照抄）

```
internal/rules/rules_test.go
  ├── TestExtractCRNumbers          ← 表驱动，多载体 + 冲突场景
  └── TestWindowContains            ← 表驱动，边界（闭区间开区间）
  └── TestWindowCrossMidnight       ← 表驱动，跨零点

internal/webhook/signature_test.go
  └── 验签：正确签名 / 错误签名 / 空 secret

internal/webhook/handler_test.go
  ├── newTestHandler                ← 共享装配 + t.Helper()
  ├── TestHandler_HappyPath         ← 正常通过
  ├── TestHandler_RuleFailure       ← 规则不通过
  ├── TestHandler_SystemErrorFailsClosed ← ★ fail-closed
  ├── TestHandler_UnmanagedBranchIgnored ← 分支过滤
  ├── TestHandler_Idempotency       ← 幂等
  ├── TestHandler_MissingCRNumber   ← 缺单号
  └── TestHandler_Ping              ← ping 事件
```

**★ 覆盖了 cr-check 最需要守住的 5 条不变量**：
1. 正常路径能通过
2. 规则不通过时明确指出是哪条规则
3. **系统异常时绝不 success**
4. 非受管分支不产生 check
5. 重复投递不重复处理

---

## 11. 一句话总结

> **Go 的测试 = 标准库 + 表驱动 + 手写 fake。**
> - `cases := []struct{...}` + `t.Run` = 主流写法
> - `t.Fatalf` 终止 / `t.Errorf` 继续
> - `t.Helper()` 让报错指向调用者
> - `httptest.NewRequest` + `NewRecorder` 测 handler，不用起服务器
> - **手写 fake 优于 mock 框架**
> - **时间必须可注入**（`Clock func() time.Time`）
> - **CI 必跑 `-race`；关键路径覆盖率 100%**

---

## 12. 自测题

1. `t.Fatalf` 和 `t.Errorf` 的区别是什么？什么时候用哪个？
2. `t.Helper()` 改变了报错堆栈的哪一部分？
3. 为什么 Go 社区更推荐 fake 而不是 mock？
4. 为什么 `Handler` 里要放一个 `Clock func() time.Time` 字段？
5. `TestHandler_SystemErrorFailsClosed` 里为什么要专门断言 `conclusion != "success"`？
6. `-shuffle=on` 能发现什么问题？

---

上一篇：[12-json.md](12-json.md) ｜ 下一篇：[14-time.md](14-time.md) ｜ 回到 [00-index.md](00-index.md)
