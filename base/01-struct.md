# 01 · Struct（结构体）

> 一句话：**Struct 就是把一堆相关的数据打包成一个"自定义类型"**。
> Go 里几乎所有东西都是结构体：配置对象、领域模型、HTTP 响应体、日志记录……

---

## 1. 最小例子

```go
package crplatform

// ChangeRequest 是 CR 管理平台的规范化视图。
type ChangeRequest struct {
	Number    string     `json:"number"`
	Status    Status     `json:"status"`
	Requester string     `json:"requester"`
	Approvers []Approval `json:"approvers"`
	TargetEnv string     `json:"targetEnv"`
	ValidFrom time.Time  `json:"validFrom"`
	ValidTo   time.Time  `json:"validTo"`
	Artifacts []string   `json:"artifacts"`
	URL       string     `json:"url"`
}
```

来源：`internal/crplatform/crplatform.go:39`

拆开看四件事：

| 元素 | 含义 |
|---|---|
| `type X struct { }` | 定义一个新类型 X，它是个结构体 |
| `Number string` | 字段名 + 类型 |
| `,` | **每个字段后面都要逗号**（最后一行也要） |
| `json:"number"` | 结构体标签（tag），告诉 `encoding/json` 怎么映射字段名 |

**Go 特有习惯**：类型名用 `PascalCase`（`ChangeRequest`），
字段名也用 `PascalCase`（`Number`）——**因为导出字段才能被别的包访问**。

---

## 2. 怎么用

```go
// 声明（零值）：所有字段是类型零值
cr := crplatform.ChangeRequest{
	Number:    "CR-123",
	Status:    crplatform.StatusApproved,
	Requester: "alice",
}

// 指针形式（更常用）
crp := &crplatform.ChangeRequest{Number: "CR-123"}

// 读字段
fmt.Println(crp.Number)

// 改字段（指针可以直接改）
crp.Status = crplatform.StatusImplement
```

### 零值（Zero Value）——Go 的一个重要特性

Go 里**所有类型的默认值都存在**，不需要像 Java 那样显式 `new`：

| 类型 | 零值 |
|---|---|
| 数字 | `0` |
| 字符串 | `""` |
| bool | `false` |
| 指针 / 接口 / slice / map / chan / func | `nil` |

所以 `var c crplatform.ChangeRequest` 之后，`c.Number == ""`、`c.Approvers == nil`，
**永远不会是"未初始化的垃圾数据"**。这是 Go 相对 C++/Java 的一个安全优势。

---

## 3. 结构体标签（tag）：最常见的用途是 JSON

cr-check 里有两套结构体，是理解 tag 的最佳例子：

### 3.1 外部世界的原始格式（`platformResponse`）

```go
// internal/crplatform/crplatform.go:130
type platformResponse struct {
	Number    string `json:"number"`
	Status    string `json:"status"`
	Requester string `json:"requester"`
	Approvers []struct {
		Approver  string `json:"approver"`
		DecidedAt string `json:"decidedAt"`
		Decision  string `json:"decision"`
	} `json:"approvers"`
	TargetEnv string   `json:"targetEnv"`
	ValidFrom string   `json:"validFrom"`
	ValidTo   string   `json:"validTo"`
	Artifacts []string `json:"artifacts"`
	URL       string   `json:"url"`
}
```

注意两点：
- `ValidFrom` 是 **string**（平台给的是字符串）；
- `Approvers` 直接写了一个**匿名结构体切片**。

### 3.2 我们自己的规范化格式（`ChangeRequest`）

```go
// internal/crplatform/crplatform.go:39
type ChangeRequest struct {
	...
	ValidFrom time.Time  `json:"validFrom"`
	...
}
```

`ValidFrom` 变成了 **`time.Time`**。

中间靠一个转换方法搭桥：

```go
// internal/crplatform/crplatform.go:186
func (r platformResponse) toModel(aliases map[string][]string) *ChangeRequest {
	cr := &ChangeRequest{ ... }
	for _, a := range r.Approvers {
		t, _ := time.Parse(time.RFC3339, a.DecidedAt)
		cr.Approvers = append(cr.Approvers, Approval{ ... })
	}
	cr.ValidFrom, _ = time.Parse(time.RFC3339, r.ValidFrom)
	return cr
}
```

### ★ 这个设计的意义（值得学的思想）

> **"平台原始响应" 和 "我们内部模型" 分开。**
> 平台改一个字段名，只要改 `crplatform` 这一个包；
> `rules` 包一行都不用动。

这叫 **防腐层（Anti-Corruption Layer）**。注释里写得很清楚：

```go
// ★ 职责边界：rules 包只认这里的规范化模型（ChangeRequest），
// 不认平台的原始响应格式 —— 平台改字段时只需要改这个包。
```

---

## 4. 嵌套结构体 vs 匿名结构体

cr-check 的 webhook payload 用了**嵌套的匿名结构体**：

```go
// internal/webhook/handler.go:52
type pullRequestEvent struct {
	Action string `json:"action"`
	Number int    `json:"number"`
	PullRequest struct {
		Number int    `json:"number"`
		Title  string `json:"title"`
		Body   string `json:"body"`
		Base   struct {
			Ref  string `json:"ref"`
			Repo struct {
				FullName string `json:"full_name"`
			} `json:"repo"`
		} `json:"base"`
		Head struct {
			SHA string `json:"sha"`
		} `json:"head"`
		User struct {
			Login string `json:"login"`
		} `json:"user"`
		Labels []struct {
			Name string `json:"name"`
		} `json:"labels"`
	} `json:"pull_request"`
	Repository struct {
		Name     string `json:"name"`
		FullName string `json:"full_name"`
		Owner    struct {
			Login string `json:"login"`
		} `json:"owner"`
	} `json:"repository"`
	Installation struct {
		ID int64 `json:"id"`
	} `json:"installation"`
}
```

读法（把它想象成 JSON 树）：

```json
{
  "action": "opened",
  "number": 1,
  "pull_request": {
    "title": "...",
    "base": { "ref": "main", "repo": { "full_name": "acme/app" } },
    "head": { "sha": "abc123" },
    "user": { "login": "alice" },
    "labels": [ { "name": "cr/123" } ]
  },
  "repository": { "name": "app", "owner": { "login": "acme" } },
  "installation": { "id": 42 }
}
```

### ★ 为什么这里用匿名结构体而不是命名类型？

**因为这个结构体只在"解析 webhook JSON"这一个地方用一次**，不需要复用。
起个名字反而是负担（要维护两处）。

**经验法则**：

- 结构体会被多个函数用 → 起名（`ChangeRequest`、`PRInfo`）
- 只在一个地方解析一下 → 匿名嵌套

---

## 5. 另一个例子：配置对象（嵌套 + 命名）

```go
// internal/config/config.go:20
type Config struct {
	CheckName      string            `json:"checkName"`
	Timezone       string            `json:"timezone"`
	ManagedBranches []string         `json:"managedBranches"`
	BranchEnvMap   map[string]string `json:"branchEnvMap"`

	CR         CRConfig         `json:"cr"`
	Windows    []WindowConfig   `json:"windows"`
	Webhook    WebhookConfig    `json:"webhook"`
	GitHub     GitHubConfig     `json:"github"`
	CRPlatform CRPlatformConfig `json:"crPlatform"`
	Server     ServerConfig     `json:"server"`
	Mock       MockConfig       `json:"mock"`
}
```

这里全是**命名子结构体**，因为 `config.Load()` 会把整个 `Config` 到处传，
子配置也要被单独引用（比如 `cfg.CR.MinApprovals`）。

YAML 也是靠 tag 映射的（`sigs.k8s.io/yaml` 会先转成 JSON 再用 json tag）：

```yaml
checkName: "cr-check / change-request"
timezone: "Asia/Shanghai"
managedBranches: ["main", "release"]
```

```go
cfg, err := config.Load("config/policy.yaml")
fmt.Println(cfg.CheckName, cfg.CR.MinApprovals)
```

---

## 6. 结构体 vs Java 的 class

| | Java class | Go struct |
|---|---|---|
| 字段可见性 | public / private / protected | 首字母大小写 |
| 方法 | 类里定义 | **可以定义在别的文件里**（只要同包） |
| 继承 | 可以 | **不可以** |
| 嵌入组合 | `extends` | **可以**（嵌入字段） |
| 接口实现 | `implements` | **隐式**，不用写关键字 |

Go 的 struct 更像 **C 的 struct + Java 的 getter/setter 直接开放**。

---

## 7. 常见坑

### 坑 1：结构体含 `sync.Mutex`，一定要用指针

```go
// internal/recheck/recheck.go:35
type Registry struct {
	mu      sync.RWMutex
	entries map[string]Entry
}

func NewRegistry() *Registry {
	return &Registry{entries: map[string]Entry{}}
}
```

`Registry` 里有一个 `sync.RWMutex`。如果按值传递 `Registry`，
**锁会被复制** → 数据竞争。所以构造函数返回 `*Registry`。

> 规则：**结构体里只要有 `sync.Mutex` / `sync.RWMutex` / `sync.Once`，
> 这个类型就只能按指针用。**

### 坑 2：切片和 map 是"引用类型"，但结构体赋值是"浅拷贝"

```go
a := crplatform.ChangeRequest{Number: "1"}
b := a              // 值拷贝：字段都复制了一份
b.Number = "2"
fmt.Println(a.Number)  // 还是 "1" ✅

// 但如果字段是切片：
c := crplatform.ChangeRequest{Approvers: []crplatform.Approval{{Approver: "alice"}}}
d := c
d.Approvers[0].Approver = "bob"
fmt.Println(c.Approvers[0].Approver)  // "bob" ⚠️ 切片底层数组共享！
```

cr-check 的 `MockClient.Get` 就是**显式做了拷贝**来避免这个问题：

```go
// internal/crplatform/crplatform.go:244
func (m *MockClient) Get(_ context.Context, number string) (*ChangeRequest, error) {
	...
	cp := *cr          // 值拷贝一份
	return &cp, nil    // 返回副本的指针
}
```

---

## 8. 一句话总结

> **Struct = 数据 + （通过 Method）行为。**
> 命名规则：导出用大写开头，内部用小写开头。
> 包含锁的类型一律用指针。

---

## 9. 自测题（能答出来就过了）

1. `crplatform.Approval` 这个类型在别的包里能直接用吗？为什么？
2. `var cr crplatform.ChangeRequest` 之后 `cr.Approvers` 是什么值？能不能直接 `range` 遍历？
3. `platformResponse.ValidFrom` 是 `string`，`ChangeRequest.ValidFrom` 是 `time.Time`，
   这个差异为什么是**好事**？
4. `Registry` 为什么不能按值传？

---

下一篇：[02-method.md](02-method.md) — 给结构体挂上行为
