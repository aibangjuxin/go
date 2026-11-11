# 16 · Slice / Map 与常用标准库

> 一句话：**Go 的集合类型很简单（只有 slice 和 map），
> 剩下的能力都在标准库里（`strings` / `sort` / `regexp` / `strconv` / `bytes`）。**
> cr-check 里到处是这些用法。

---

## 1. Slice（切片）

```go
s := []string{"a", "b", "c"}
```

Slice = **指针 + 长度 + 容量**（header）。它引用底层数组，不复制数据。

| 操作 | 说明 |
|---|---|
| `len(s)` | 长度 |
| `cap(s)` | 容量 |
| `s = append(s, x)` | 追加（可能重新分配） |
| `s = s[1:]` | 切片（**共享底层数组**） |
| `copy(dst, src)` | 拷贝 |
| `delete(m, k)` | map 删除 |

### ★ append 的坑

```go
s1 := []int{1, 2, 3}
s2 := append(s1, 4)
s3 := append(s1, 5)
fmt.Println(s2, s3)   // [1 2 3 4] [1 2 3 5]
```

**★ 经典陷阱**：如果 `s1` 的容量足够，`append` 会**原地写**，
`s2` 和 `s3` 会共享底层数组，互相覆盖。

**解法**：需要独立副本时显式拷贝。

```go
s3 := append([]int(nil), s1...)   // 深拷贝一份
```

### ★ nil slice vs 空 slice

```go
var a []string          // nil，长度 0，JSON 序列化成 null
b := []string{}         // 空，长度 0，JSON 序列化成 []
c := make([]string, 0)  // 空，长度 0，JSON 序列化成 []
```

cr-check 里处理 labels 时用了 `make`：

```go
labels := make([]string, 0, len(ev.PullRequest.Labels))
for _, l := range ev.PullRequest.Labels {
    labels = append(labels, l.Name)
}
```

> ★ `make([]string, 0, cap)` 是 **预分配**：
> 一次分配好容量，避免循环里反复扩容。
> 已知元素个数时用 `make([]T, 0, n)`，性能差别很明显。

### ★ 遍历

```go
for i, v := range s { ... }        // 索引 + 值
for i := range s { ... }            // 只要索引
for _, v := range s { ... }          // 只要值
```

> ★ Go 1.22+ 循环变量每轮独立（见 [13-testing.md](13-testing.md)）。

### ★ range 遍历 map 的顺序是随机的

```go
for k, v := range m { ... }   // ★ 顺序不保证！
```

**★ 需要稳定顺序时，必须先排序**。
cr-check 的 `Extraction.add` 就是这么做的：

```go
func (e *Extraction) add(num, source string) {
    if _, ok := e.Sources[num]; ok {
        return
    }
    e.Sources[num] = source
    e.Numbers = append(e.Numbers, num)
    sort.Strings(e.Numbers)     // ★ 保证顺序稳定
}
```

> ★ 这很重要：如果不排序，`ExtractCRNumbers` 的输出顺序会随运行变化，
> 导致**测试 flaky**（同样的输入，不同的顺序）。

---

## 2. Map

```go
m := map[string]int{"a": 1}
v, ok := m["a"]      // ★ ok 表示"键是否存在"
v2 := m["missing"]   // 不存在时返回零值（不会 panic）
delete(m, "a")
```

### ★ 三条规则

**规则 1：key 必须是可比较类型**
`string` / 数字 / 布尔 / 指针 / 数组 / **struct**（字段全部可比较）。
**不能**用 slice / map / func 作 key。

**规则 2：读不存在的键返回零值，不报错**

```go
count := m["nonexistent"]   // 0，不会 panic
```

**规则 3：★ map 是引用类型，但并发不安全**

```go
m := map[string]int{}
m2 := m          // m2 和 m 是同一个 map
```

**★ map 不能并发读写**，必须加锁（见 [09-sync.md](09-sync.md)）。

### ★ 配置里的 map

cr-check 的配置大量用 map：

```go
type Config struct {
    BranchEnvMap map[string]string `json:"branchEnvMap"`
}

type CRConfig struct {
    StatusAliases map[string][]string `json:"statusAliases"`
}
```

查找：

```go
func (c *Config) EnvForBranch(ref string) string {
    if env, ok := c.BranchEnvMap[ref]; ok {
        return env
    }
    return ""
}
```

> ★ **注意**：map 查找用 `v, ok := m[k]`，
> **不能**用 `if m[k] != ""` 判断存在性 —— 因为存在但值为空串时会被误判。
> 上面的 `EnvForBranch` 用 `ok` 是对的。

---

## 3. strings：字符串处理

```go
strings.TrimSpace(s)         // 去空格
strings.ToLower(s) / ToUpper
strings.TrimPrefix(s, "cr/") // ★ 去掉前缀
strings.TrimSuffix
strings.Split(s, ",")         // → []string
strings.Join(slice, ", ")     // → string
strings.Contains(s, sub)
strings.HasPrefix / HasSuffix
strings.ReplaceAll(s, old, new)
strings.EqualFold(a, b)       // ★ 大小写不敏感比较
strings.Builder               // ★ 高效拼接
strings.Repeat
```

### ★ EqualFold：大小写不敏感比较

cr-check 里到处都是：

```go
// internal/rules/engine.go
func containsFold(list []string, v string) bool {
    for _, x := range list {
        if strings.EqualFold(x, v) {   // ★ 忽略大小写
            return true
        }
    }
    return false
}
```

```go
// internal/crplatform/crplatform.go
if strings.EqualFold(canonical, s) { ... }
```

> ★ **为什么状态/用户名比较要用 EqualFold？**
> CR 平台可能返回 `Approved` / `approved` / `APPROVED`，
> GitHub 用户名理论上不区分大小写。
> 用 `==` 会导致"同样的东西被判成不一样" —— 在 fail-closed 系统里 =
> 误拦用户。

### ★ strings.Builder：高效的字符串拼接

cr-check 的 Markdown 渲染：

```go
func (o Outcome) Render() string {
    var b strings.Builder
    ...
    fmt.Fprintf(&b, "- **变更单**：`%s`\n", o.CRNumber)
    ...
    return b.String()
}
```

> ★ **不要用 `s += "..."` 循环拼接**：
> 每次 `+=` 都是**新分配 + 复制**，O(n²)。
> `strings.Builder` 是 O(n)，而且它实现了 `io.Writer`，
> 可以直接用 `fmt.Fprintf(&b, ...)`。

> ★ **对比 `bytes.Buffer`**：功能一样，
> `strings.Builder` 专门给字符串用，API 更少。

### ★ 字符串 vs []byte 的取舍

| | `string` | `[]byte` |
|---|---|---|
| 可变 | ❌ 不可变 | ✅ |
| map key | ✅ | ❌ |
| 零值 | `""` 可用 | `nil` |
| 拼接 | `strings.Builder` | `bytes.Buffer` |

---

## 4. sort：排序

```go
sort.Strings(s)
sort.Ints(s)
sort.Slice(users, func(i, j int) bool { return users[i].Age < users[j].Age })
sort.SliceStable(users, ...)
```

### ★ Go 1.21+ 的 slices 包（更简洁）

```go
import "slices"

slices.Sort(s)
slices.Contains(s, "abc")
slices.Index(s, "abc")
slices.SortFunc(users, func(a, b User) int { return a.Age - b.Age })
slices.Max([]int{1, 3, 2})    // 3
slices.Clone(s)
```

> ★ **`sort.Slice` 不稳定**：相等的元素顺序可能变。
> 需要稳定排序（比如"先按部门，再按工号"）用 `sort.SliceStable` 或 `slices.SortStableFunc`。

---

## 5. regexp：正则

cr-check 的核心解析逻辑：

```go
// internal/rules/extract.go
re, err := regexp.Compile(labelPattern)
if err == nil {
    for _, l := range labels {
        if !re.MatchString(l) { continue }
        ...
    }
}

// body marker：^(marker)\s*(number)$
marker := regexp.QuoteMeta(bodyMarker)
bre := regexp.MustCompile(`(?im)^\s*` + marker + `\s*([0-9A-Za-z][0-9A-Za-z._/-]*)\s*$`)
for _, m := range bre.FindAllStringSubmatch(body, -1) {
    num := strings.TrimSpace(m[1])
    ...
}
```

### ★ 三个要点

**要点 1：`regexp.QuoteMeta` 转义元字符**

```go
marker := regexp.QuoteMeta(bodyMarker)   // "Change-Request:" → "Change\-Request\:"
```

> ★ bodyMarker 是**用户可配**的，直接拼进正则会有注入风险。
> `QuoteMeta` 是必须的。

**要点 2：`(?im)` 是内联标志**

| 标志 | 含义 |
|---|---|
| `i` | 忽略大小写 |
| `m` | 多行模式（`^` `$` 匹配行首行尾） |
| `s` | 让 `.` 匹配换行 |

**要点 3：`Compile` vs `MustCompile`**

| | 行为 |
|---|---|
| `regexp.Compile` | 出错返回 error，**不 panic** |
| `regexp.MustCompile` | 出错**直接 panic** |

> ★ **规则**：
> - 正则是**写死的常量** → `MustCompile`（编译期/初始化时炸，比运行期炸好）
> - 正则来自**用户配置** → `Compile` + 处理 error
>
> cr-check 的 `labelPattern` 来自配置，用 `Compile` + 忽略错误；
> 而 `bodyMarker` 的模式是拼出来的，用 `MustCompile`。
> 严格说，拼接出来的正则也可能出错（比如 marker 里有非法转义），
> 更稳妥的做法是也用 `Compile` 并把错误返回给调用方。

### ★ 正则的性能

Go 的 `regexp` 是 **RE2**（自动机，没有回溯）：
- **保证线性时间**，不会有"灾难性回溯"（ReDoS）风险
- 不支持反向引用和 lookaround

> ★ 这对处理**用户输入**（比如 PR body）是巨大的安全优势。

---

## 6. strconv：类型转换

```go
strconv.Atoi(s)              // 字符串 → int（带 error）
strconv.Itoa(i)              // int → 字符串
strconv.ParseInt(s, 10, 64)
strconv.FormatInt(i, 10)
strconv.ParseFloat(s, 64)
strconv.ParseBool(s)
strconv.Quote(s)             // 加引号转义（写日志/JSON 时）
```

cr-check 的用法：

```go
// internal/config/config.go
h, err := strconv.Atoi(parts[0])
if err != nil || h < 0 || h > 24 {
    return 0, fmt.Errorf("小时非法: %q", s)
}
```

```go
// internal/gh/client.go —— 手写 int64 解析（避免引入 json）
for _, c := range rest[:j] {
    id = id*10 + int64(c-'0')
}
```

> ★ **`strconv.Atoi` vs `fmt.Sscanf`**：
> 前者快且能明确区分错误，后者慢且错误信息含糊。
> **永远优先 strconv。**

---

## 7. io / os / bufio

```go
os.ReadFile(path)
os.WriteFile(path, data, 0o644)
os.Open / os.Create
io.ReadAll(r)
io.LimitReader(r, n)
bufio.NewReader(r) / bufio.NewScanner(r)
```

### ★ 限制读取大小（防内存打爆）

cr-check 的 webhook 读请求体：

```go
// internal/webhook/handler.go
body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, h.Cfg.Webhook.MaxBodyBytes))
```

> ★ `http.MaxBytesReader` 是**必须**的：
> 攻击者发一个 10GB 的 body，你的服务 OOM。
> 配置项 `webhook.maxBodyBytes` 默认 2MB。

---

## 8. 一页速查

| 需求 | 用什么 |
|---|---|
| 字符串去空格/分割/拼接 | `strings.TrimSpace` / `Split` / `Join` / `Builder` |
| 大小写不敏感比较 | `strings.EqualFold` |
| 排序 | `slices.Sort` / `slices.SortFunc` |
| 查元素 | `slices.Contains` |
| 正则 | `regexp`（RE2，无回溯） |
| 字符串转数字 | `strconv.Atoi` |
| 写文件 | `os.WriteFile(path, data, 0o600)` |
| 限制读取 | `io.LimitReader` / `http.MaxBytesReader` |

---

## 9. 一句话总结

> **Go 的集合只有 slice 和 map，能力靠标准库补齐。**
> - `append` 可能原地写 → 需要独立副本时显式 copy
> - `make([]T, 0, n)` 预分配
> - **map 遍历顺序随机 → 需要稳定顺序必须排序**
> - map 查找用 `v, ok := m[k]`，别用 `!= ""`
> - **字符串拼接用 `strings.Builder`，别用 `+=`**
> - 大小写不敏感比较用 `strings.EqualFold`
> - 用户配置拼进正则前先 `regexp.QuoteMeta`
> - 读外部输入必须限流（`http.MaxBytesReader`）

---

## 10. 自测题

1. `append` 在什么情况下会覆盖已有元素？举一个具体例子。
2. 为什么 `Extraction.add` 里要 `sort.Strings`？不排序会有什么后果？
3. `if m["key"] != ""` 判断键存在性有什么问题？
4. 为什么 `strings.Builder` 比 `s += "x"` 快？
5. 为什么 bodyMarker 拼进正则前要用 `regexp.QuoteMeta`？
6. Go 的正则为什么不会有"灾难性回溯"？
7. 为什么 webhook 读 body 必须用 `http.MaxBytesReader`？

---

上一篇：[15-defer-panic-recover.md](15-defer-panic-recover.md) ｜ 下一篇：[17-modules-build.md](17-modules-build.md) ｜ 回到 [00-index.md](00-index.md)
