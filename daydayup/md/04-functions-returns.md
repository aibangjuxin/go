# Day 4 · 函数和返回值 —— 给代码起个名字，给它输入，拿它输出

> 对应代码：[`../d04/`](../d04/)

> 一句话目标：**看懂 `func 名字(参数) 返回值` 这一行，并把逻辑拆成能复用的小函数。**

## 目标

- [ ] 学会：`func 名字(参数名 参数类型) 返回类型 { ... }` 的完整写法
- [ ] 学会：一个函数返回多个值（`(bool, string)`）
- [ ] 学会：没有返回值的函数长什么样
- [ ] 能用一句话解释：**`return` 一执行，函数立刻结束**

---

## 0. 先看 Day 1 那个最小的函数

```go
func greet(name string) string {
    return "Hello, " + name
}
```

一行行拆开：

| 片段 | 含义 |
|---|---|
| `func` | 这是个函数 |
| `greet` | 函数名（叫什么都行，Go 里首字母大写＝导出） |
| `name string` | 参数：名字叫 name，类型是 string |
| `string` | 返回值类型 |
| `return "Hello, " + name` | 把这个字符串交出去 |

调用：

```go
fmt.Println(greet("Le"))   // Hello, Le
```

> 🎯 **小练习的落点**：你要求写的 `greet(name string) string` 就是它。
> 在本仓库它对应 [`../d04/main.go`](../d04/main.go) 里的 `greet()`，
> 跑 `make run DAY=d04` 就能看到 `Hello, Le`。
> （Day 1 的 [`../d01/main.go`](../d01/main.go) 里也有一份一模一样的 `greet`，可以对比着看。）

---

## 1. 读代码技巧：先看签名

看到一行函数声明，**先读名字和括号**，别急着看函数体：

```go
func checkTitle(title string) (bool, string)
```

- 名字 `checkTitle` → 它在「检查标题」
- 括号里 `title string` → 输入是一个标题
- 括号后面的 `(bool, string)` → 输出两个值：一个 bool，一个 string

函数体怎么写是后面的事，**签名先告诉你这个函数能干什么**。

---

## 2. 多个返回值

Go 一次可以返回多个值，直接用括号列出来：

```go
func checkTitle(title string) (bool, string) {
    if hasCHNumber(title) {
        return true, "标题包含 CH 编号"
    }
    return false, "标题缺少 CH 编号"
}
```

接收的时候按顺序接：

```go
ok, reason := checkTitle("feat: add cr-prefix check for CH013456")
fmt.Println(ok, reason)   // true 标题包含 CH 编号
```

### 2.1 只要其中一个怎么办？

用 `_`（下划线）丢掉不要的那个：

```go
ok, _ := checkTitle("fix: 修个 bug")   // 只要 bool
```

### 2.2 `return` 一执行，函数立刻结束

```go
func checkTitle(title string) (bool, string) {
    if title == "" {
        return false, "标题为空"   // ← 执行到这儿，函数就结束了
    }
    if hasCHNumber(title) {
        return true, "标题包含 CH 编号"
    }
    return false, "标题缺少 CH 编号"  // ← 只有前面都没 return 才轮得到这行
}
```

所以一个函数里**有多个 `return` 是正常的**，每个 `return` 都是一条独立的出口。
（不是「只执行第一个 return」——那是 C/C++ 里没有返回值的老写法。）

---

## 3. 没有返回值的函数

不写返回类型就行：

```go
func printTitle(title string) {
    fmt.Printf("正在检查：%s\n", title)
}
```

- 没有返回值 ≠ 什么都不能干：它可以**打印**、**改传进来的东西**
- Go 里**不能写 `void`** —— `func f() void` 是语法错误

想「有结果但不想返回值」，用两种方式：

| 方式 | 写法 | 用在哪 |
|---|---|---|
| 改指针指向的数据 | `func record(results *[]string, title string)` | 收集结果 |
| 改全局变量 | `var count int` + `func bump()` | 极少用，别学 |

---

## 4. 命名返回值（具名返回）

在返回类型里把名字写出来，函数体里就能直接用这些变量：

```go
func classifyTitle(title string) (passed bool, reason string) {
    if title == "" {
        return false, "标题为空"
    }
    if hasCHNumber(title) {
        passed = true
        reason = "标题包含 CH 编号"
        return          // ← 裸 return，等价于 return passed, reason
    }
    reason = "标题缺少 CH 编号"
    return
}
```

### 坑：命名返回值忘了赋值

```go
func f() (ok bool) {
    return            // ok 还是零值 false
}
```

**这不是编译错误**，是运行时返回 `false`。
裸 `return` 写起来方便，但团队里更常见的是**显式 `return a, b`**，不容易漏赋值。

---

## 5. 函数也是值

Go 的函数是**一等公民**：能赋值给变量、能当参数传、还能当返回值。

```go
f := greet                        // 函数赋给变量
fmt.Println(f("Le"))              // Hello, Le

func apply(f func(string) string, name string) string {
    return f(name)
}
fmt.Println(apply(shout, "Le"))   // HELLO, LE
```

`func(string) string` 叫**函数类型**：接受一个 string、返回一个 string 的函数。

### 匿名函数（当场写一个函数）

```go
fmt.Println(apply(func(s string) string {
    return "[" + s + "]"
}, "Le"))                          // [Le]
```

---

## 6. 坑

| 坑 | 症状 | 解法 |
|---|---|---|
| 写 `func f() void` | **语法错误** | 不写返回类型就是「无返回值」 |
| 忘了 `return`（有返回值的函数） | **编译错误** `missing return` | 每个出口都要 return |
| 命名返回值忘了赋值 | 编译通过，但返回零值（`false` / `""`） | 用显式 `return a, b` |
| 多返回值接收顺序写反 | 静默 bug（两个都是 string 时更坑） | 接收后立刻断言一次 |
| `return` 后面还写代码 | 那段代码**永远不执行** | 删掉，或挪到 return 之前 |
| 形参和返回值同名搞混 | `func f(x int) int { x := 1 }` 编译错误（x 已声明） | 用 `:=` 换个名或直接赋值 `x = 1` |
| 以为函数能改实参 | 值传递，改不到外面 | 要改就传指针 `*T` 或切片/map |

---

## 7. 小练习（代码里都做了）

| 练习 | 在哪 |
|---|---|
| 写 `greet(name string) string` 返回 `"Hello, " + name` | `greet()` + `TestGreet` |
| 一次返回「结果 + 原因」 | `checkTitle()` + `TestCheckTitle` |
| 用命名返回值重写一遍 | `classifyTitle()` + `TestClassifyTitle` |
| 写一个没有返回值、只打印的函数 | `printTitle()` |
| 把函数当参数传 | `apply()` + `TestApply` |

---

## 8. 代码

对应代码目录：[`../d04/`](../d04/)

```bash
make run DAY=d04   # 跑示例
make test          # 跑测试
```

| 文件 | 内容 |
|---|---|
| [`../d04/main.go`](../d04/main.go) | `greet`（单返回值）/ `greetWith`（多返回值）/ `printTitle`（无返回值）/ `record`（指针副作用）/ `checkTitle`（结果 + 原因）/ `classifyTitle`（命名返回值）/ `apply`（函数当参数） |
| [`../d04/main_test.go`](../d04/main_test.go) | 表驱动测试 + 「return 会停住函数」的断言 |

### 重点看这几个测试

| 测试 | 钉死的知识点 |
|---|---|
| `TestGreet` | 参数 → 返回值，一一对应 |
| `TestCheckTitle` | 多返回值的**顺序**和内容 |
| `TestClassifyTitle` | 命名返回值和普通写法**结果必须一致** |
| `TestRecord` | 无返回值的函数靠**副作用**留结果 |
| `TestReturnStopsFunction` | `return` 之后不会再执行 |

---

## 9. 自测

- [ ] 我能默写 `func 名字(参数名 参数类型) 返回类型` 这一行
- [ ] 我能解释 `func f()` 和 `func f() void` 的区别
- [ ] 我知道 Go 一次能返回多个值，接收时怎么写、怎么丢掉一个
- [ ] 我能说出 `return` 执行后会发生什么
- [ ] 我知道命名返回值忘了赋值会返回什么（零值，不是编译错误）
- [ ] 我能写一个函数把另一个函数当参数传
