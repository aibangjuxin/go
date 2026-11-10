# 02 · Method（方法）

> 一句话：**Method 就是带"接收者"的函数**。
> `func (r Foo) Bar()` —— `Foo` 类型的值就能调用 `.Bar()`。

---

## 1. 语法：括号里那个就是"接收者"（receiver）

```go
// internal/crplatform/crplatform.go:54
func (c *ChangeRequest) IsExecutable() bool {
	return c.Status == StatusApproved || c.Status == StatusImplement
}
```

调用：

```go
cr := &crplatform.ChangeRequest{Status: crplatform.StatusApproved}
if cr.IsExecutable() { ... }
```

这里 `c` 就是接收者 ≈ Java 的 `this`。

对照 Java：

```java
public boolean isExecutable() {
    return status == APPROVED || status == IMPLEMENT;
}
```

---

## 2. ★ 重点一：值接收者 vs 指针接收者

这是 Go 初学者最容易踩坑的地方。cr-check 里两种都有，是绝佳教材。

### 值接收者（`func (v Value) M()`）

```go
// internal/rules/engine.go:33
func (p PRInfo) Key() string {
	return fmt.Sprintf("%s/%s#%d", p.Owner, p.Repo, p.Number)
}

// internal/rules/engine.go:69
func (o Outcome) Conclusion() string {
	if o.OK && !o.SystemError {
		return "success"
	}
	return "failure"
}

// internal/rules/engine.go:77
func (o Outcome) FailedIDs() []string { ... }
```

调用时 `p`、`o` 会被**复制一份**给方法。

### 指针接收者（`func (v *Value) M()`）

```go
// internal/rules/engine.go:204
func (e *Engine) Evaluate(ctx context.Context, in Input) Outcome { ... }

// internal/recheck/recheck.go:46
func (r *Registry) Add(pr rules.PRInfo) { ... }

// internal/check/writer.go:143
func (w *GitHubWriter) upsert(ctx context.Context, ...) error { ... }
```

调用时传的是**原对象的地址**，方法里能修改原对象。

### 怎么选？记住三条

| 情况 | 用哪个 | cr-check 例子 |
|---|---|---|
| 需要修改接收者 | 指针 | `Registry.Add`（写 map）、`LogWriter.write`（写字段） |
| 结构体较大（含切片/map/锁） | 指针 | `Engine`、`Registry`、`MockClient` |
| 只是读数据，算个结果 | 值 | `PRInfo.Key()`、`Outcome.Conclusion()` |

> **Go 官方社区惯例：**
> **"如果一个类型有任何方法用了指针接收者，那它的所有方法都应该用指针接收者。"**
> 保持一致，不要一半值一半指针。

### 为什么值接收者有坑？

```go
type Engine struct {
	cfg *config.Config
	usage *Usage
}

func (e Engine) Count() int { return len(e.usage.m) }  // 值接收者
```

`e` 是副本，但 `e.usage` 是指针，**指向同一个 Usage** —— 所以看起来"能用"。
但如果哪天加了个 `func (e Engine) Reset()` 想改 `e.usage.xxx`，
因为 `e.usage` 是指针所以也能改……**这属于"侥幸能用"，不是"设计正确"**。

**结论：业务类型统一用指针接收者；纯值类型（小结构体、只读）用值接收者。**

---

## 3. ★ 重点二：方法集（method set）—— 决定"能不能赋给接口"

Go 有一条**反直觉但极其重要**的规则：

> **值类型 `T` 的方法集只包含值接收者的方法；
> 指针类型 `*T` 的方法集包含值接收者 + 指针接收者的所有方法。**

也就是说：

```go
type Foo struct{}
func (f Foo) A() {}   // 值接收者
func (f *Foo) B() {}  // 指针接收者

var i1 interface{ A() } = Foo{}    // ✅ OK
var i2 interface{ B() } = Foo{}    // ❌ 编译错误！Foo 没有 B
var i3 interface{ B() } = &Foo{}   // ✅ OK
```

**这就是为什么 cr-check 的构造函数全都返回 `*T` 而不是 `T`：**

```go
func NewMockClient(...) *MockClient { ... }   // 返回指针
func NewRegistry() *Registry { ... }           // 返回指针
func NewEngine(...) (*Engine, error) { ... }  // 返回指针
```

因为这些类型的方法都用指针接收者，返回指针才能满足接口。

### 一个真实的坑（值得看）

```go
// internal/crplatform/crplatform.go:75
type Client interface {
	Get(ctx context.Context, number string) (*ChangeRequest, error)
}

// internal/crplatform/crplatform.go:244
func (m *MockClient) Get(...) (*ChangeRequest, error) { ... }  // 指针接收者 ✅
```

`MockClient` 的 `Get` 用的是指针接收者，所以 `*MockClient` 实现了 `Client`。
main.go 里：

```go
// cmd/server/main.go:111
var crClient crplatform.Client
...
crClient = mockCR     // mockCR 是 *MockClient ✅
```

如果 `Get` 改成了值接收者，这里还能编译，但你会**丢掉 mock 内部的锁保护**——
因为值接收者复制的是 `MockClient`，`mu sync.RWMutex` 被复制了一份，
**加锁等于没加**。

> 这就是"含 `sync.Mutex` 的类型必须用指针接收者"的真正原因。

---

## 4. ★ 重点三：方法和"包级函数"可以互换

Go 里 `NormalizeStatus` 是**包级函数**，不是方法：

```go
// internal/crplatform/crplatform.go:81
func NormalizeStatus(raw string, aliases map[string][]string) Status { ... }
```

调用：`crplatform.NormalizeStatus(raw, aliases)`

什么时候用包级函数 vs 方法？

| | 包级函数 | 方法 |
|---|---|---|
| 例子 | `NormalizeStatus(raw, aliases)` | `(c *ChangeRequest) IsExecutable()` |
| 适合 | 输入输出都是参数、不涉及某个实例状态 | 需要读接收者的字段 |
| 读起来 | `包.函数(参数...)` | `对象.方法()` |

> 小技巧：Go 社区常用的"**包名.函数名**"其实和 Java 的 `static 方法" 很像。

---

## 5. cr-check 里的方法全景

### 领域模型上的方法（值接收者，因为只读）

```go
// internal/rules/engine.go
func (p PRInfo) Key() string              // owner/repo#number
func (o Outcome) Conclusion() string       // success / failure
func (o Outcome) FailedIDs() []string      // 失败的规则 ID
func (o Outcome) Render() string           // 渲染成 Markdown

// internal/rules/extract.go
func (e Extraction) First() string         // 第一个候选编号
func (e Extraction) Describe() string      // 人类可读摘要

// internal/crplatform/crplatform.go
func (c *ChangeRequest) ApproverNames() []string
```

### 有状态组件上的方法（指针接收者，因为要改状态）

```go
// internal/recheck/recheck.go
func (r *Registry) Add(pr rules.PRInfo)
func (r *Registry) Remove(key string)
func (r *Registry) SetConclusion(key, conclusion string)

// internal/rules/engine.go
func (u *Usage) Claim(crNumber, prKey string) bool
func (e *Engine) Evaluate(ctx context.Context, in Input) Outcome

// internal/check/writer.go
func (w *LogWriter) write(r Record) error
```

### 接口实现（后面 03 讲）

```go
func (c *HTTPClient) Get(ctx context.Context, number string) (*ChangeRequest, error)
func (m *MockClient) Get(ctx context.Context, number string) (*ChangeRequest, error)
func (w *LogWriter) MarkInProgress(ctx context.Context, ref Ref, summary string) error
func (w *LogWriter) Complete(ctx context.Context, ref Ref, outcome rules.Outcome) error
```

---

## 6. ★ 那些 `_` 是什么意思？

cr-check 的规则函数签名很怪：

```go
// internal/rules/engine.go:241
func ruleR1(_ context.Context, _ *Engine, in Input) Result {
	if len(in.Extraction.Numbers) == 0 {
		return Result{"R1", false, fmt.Sprintf(...)}
	}
	return Result{"R1", true, fmt.Sprintf(...)}
}

// internal/rules/engine.go:277
func ruleR3(_ context.Context, e *Engine, in Input) Result {
	...
	if !e.cfg.IsExecutableStatus(string(in.CR.Status)) { ... }
}
```

- `_` 是**空白标识符（blank identifier）**，表示"这个参数我不用"。
- `ruleR1` 不用 `ctx` 也不用 `engine`，就写 `_`。
- `ruleR3` 要用 `e.cfg`，所以写 `e`。

注意：**即使不用，也必须出现在参数列表里**（Go 没有默认参数、没有函数重载）。

### 为什么规则函数要长这样？

因为它们要**统一签名**，才能放进一个列表里批量执行：

```go
// internal/rules/engine.go:198
type rule struct {
	id string
	fn func(ctx context.Context, e *Engine, in Input) Result
}

// internal/rules/engine.go:226
func (e *Engine) rules() []rule {
	return []rule{
		{"R1", ruleR1},
		{"R1a", ruleR1a},
		{"R2", ruleR2},
		...
	}
}
```

`rule` 是一个 **struct 存一个函数字段** —— 在 Go 里，
"函数"是一等公民，可以当值存进结构体、当参数传、当返回值返回。

> 这是 Go 很强大的一点，也是函数式风格的基础。

---

## 7. 一个完整的小例子：把方法串起来看

```go
// ① 领域模型 + 方法
type ChangeRequest struct {
	Number    string
	Status    Status
	Approvers []Approval
}

func (c *ChangeRequest) ApproverNames() []string {
	var out []string
	for _, a := range c.Approvers {
		if strings.EqualFold(a.Decision, "approve") {
			out = append(out, a.Approver)
		}
	}
	return out
}

// ② 引擎调用它
func ruleR4(_ context.Context, e *Engine, in Input) Result {
	if in.CR == nil {
		return Result{"R4", false, "变更单不存在，无法检查审批"}
	}
	approvers := in.CR.ApproverNames()     // ← 方法调用
	if len(approvers) < e.cfg.CR.MinApprovals {
		return Result{"R4", false, fmt.Sprintf(
			"变更单 %s 的审批人只有 %d 位（%s），需要至少 %d 位",
			in.CR.Number, len(approvers), strings.Join(approvers, ", "), e.cfg.CR.MinApprovals)}
	}
	return Result{"R4", true, fmt.Sprintf("审批充分：%s", strings.Join(approvers, ", "))}
}
```

注意 `in.CR == nil` 这个检查出现了**四次**（R2/R3/R4/R5/R6 都写了）。
这是 Go 的常见习惯：**不做"防御性 panic"，而是每个规则自己判空并给出人话解释**。
因为这是门禁服务，错误信息要能直接显示给 PR 作者看。

---

## 8. 一句话总结

> **Method = 带接收者的函数，让行为和数据待在一起。**
> 需要改数据/结构体大/含锁 → 指针接收者；只读计算 → 值接收者。
> 同类型的接收者风格要统一。
> 含 `sync.Mutex` 的类型**必须**用指针接收者、必须返回指针。

---

## 9. 自测题

1. `func (o Outcome) Conclusion()` 是值接收者，
   `func (e *Engine) Evaluate()` 是指针接收者，为什么这么分？
2. 为什么 `NewRegistry()` 返回 `*Registry` 而不是 `Registry`？
3. 如果把 `func (m *MockClient) Get(...)` 改成值接收者 `func (m MockClient) Get(...)`，
   代码还能编译吗？会有什么隐患？
4. `ruleR1` 的参数里为什么要写 `_ context.Context`？不能直接删掉吗？
5. `rule` 这个 struct 里存了一个 `fn func(...)` 字段 —— Go 里函数可以作为值吗？

---

上一篇：[01-struct.md](01-struct.md) ｜ 下一篇：[03-interface.md](03-interface.md)
