# Day 3 · if / for —— 让程序自己做判断、重复做事

> 对应代码：[`../d03/`](../d03/)

> 一句话目标：**让程序自己判断、自己重复 —— 这两步做完，CR Check 的判定逻辑你就读得懂了。**

## 目标

- [ ] 学会：`if` / `else if` / `else` 的写法（Go 不写括号，大括号不能省）
- [ ] 学会：`for` 的三种形态（三段式 / 条件式 / range）
- [ ] 能用一句话解释：**`==` 是比较，`=` 是赋值**
- [ ] 知道 Go 为什么没有 `while` 关键字

---

## 接着用昨天那三个变量

| 变量 | 类型 | 含义 |
|---|---|---|
| `title` | `string` | PR 标题 |
| `passed` | `bool` | 检查结果 |
| `count` | `int` | 记检查了几次 |

---

## 1. if：符合条件才执行

Go 的 `if` 和别的语言有两点不同：

1. **条件不用圆括号** —— 写 `if x > 0 {`，不是 `if (x > 0) {`
2. **大括号必须有** —— 哪怕只有一行

```go
title := "feat(actions): add cr-prefix check for CH013456"
passed := false

if strings.Contains(title, "CH") {
    passed = true
    fmt.Println("标题通过")
} else {
    fmt.Println("标题缺少 CH 号")
}
```

`strings.Contains(title, "CH")` 是在问：**标题里有没有 CH**。
有就走上面，没有就走 `else`。
`passed` 默认是 `false`（Day 2 学的零值），**通过了才改成 `true`**。

### 多分支

```go
if title == "" {
    fmt.Println("标题为空")
} else if strings.Contains(title, "CH") {
    passed = true
} else {
    fmt.Println("标题缺少 CH 号")
}
```

> ⚠️ **`==` 是比较，`=` 是赋值。**
> `if title == ""` 是问「标题是不是空的」，`if title = ""` 是「把标题改成空」——
> 后者写在 `if` 条件里是**编译错误**（Go 不允许 if 条件是赋值语句），不会带到线上。

### 一个 Go 风格提醒：早返回

上面这种 `if / else if / else` 链写长了会往右缩，Go 社区更常见的是**早返回**：

```go
func checkTitle(title string) CheckResult {
    if title == "" {
        return CheckResult{false, "标题为空"}   // 直接返回，后面就不用看了
    }
    if strings.Contains(title, "CH") {
        return CheckResult{true, "标题通过"}
    }
    return CheckResult{false, "标题缺少 CH 号"}  // 兜底
}
```

两种都对。链短用 `else if`，链长用早返回。

---

## 2. for：重复做同一件事

### 2.1 三段式（最常见）

```go
count := 0
for i := 0; i < 3; i++ {
    count++
    fmt.Println("第", count, "次检查")
}
```

三段分别是：**初始化 → 条件 → 步进**。
`count++` 和 `count = count + 1` 完全等价。

### 2.2 条件式：相当于别的语言的 `while`

```go
passed := false
tries := 0
for !passed && tries < 3 {
    tries++
    fmt.Println("第", tries, "次复查……")
    if tries == 2 {
        passed = true // 第二轮补上 CH 号
    }
}
fmt.Println("最终结果：", passed)
```

**Go 没有 `while` 关键字** —— 把三段式 for 的「初始化」和「步进」留空，就变成了 while：

```go
// 等价于 while (!passed && tries < 3)
for !passed && tries < 3 {
    ...
}
```

> ⚠️ 循环条件里**同时盯着两件事**：还没通过（`!passed`）而且还没超次数（`tries < 3`）。
> 只写 `for !passed {` 就是**死循环** —— 一旦没人改 `passed`，程序永远转圈。

### 2.3 for range：遍历切片 / map / 数组

```go
for _, title := range titles {
    total++
    if checkTitle(title).Passed {
        passed++
    }
}
```

- `range` 后面跟切片、数组、map、字符串、channel
- `_` 是**丢弃**这个位置的值（这里只要标题，不要下标）
- 只要下标就写 `for i := range titles`；两个都要就 `for i, v := range titles`
- **map 遍历顺序是随机的** —— 这是 Go 的规定，不是 bug（Day 7 细说）

### 2.4 break / continue

```go
for _, title := range titles {
    if checkTitle(title).Passed {
        return title, true   // 找到第一个就停（等价于 break + 返回）
    }
}
```

- `break`：跳出**最内层**循环
- `continue`：跳过本轮剩下部分，进下一轮
- `continue` 写在 `for` 的条件式写法里要小心 —— 它跳的是「本轮循环体」，不是「条件判断」

---

## 3. 坑

| 坑 | 症状 | 解法 |
|---|---|---|
| `==` 和 `=` 搞混 | 编译错误 `cannot use ... as bool` / 语法错误 | `==` 比较，`=` 赋值 |
| if 忘了大括号 | **编译错误**（不是「只执行第一行」） | Go 的 if/for/func 大括号都不能省 |
| `for !passed {` 忘了退出条件 | 程序卡死不动 | 条件里加上次数上限 |
| `i++` 用在表达式里 | `i++` 是语句不是表达式 | Go 里没有 `x = i++` |
| 循环变量被闭包捕获 | 异步里全拿到同一个值 | **Go 1.22 起每轮循环变量独立**，老代码要小心 |
| `continue` 写错位置 | 跳过次数计数，导致死循环 | 想跳过就用 `continue`，想退出用 `break` |
| `for range` 遍历 map | 每次顺序都不一样 | 需要稳定顺序就先 `sort` 键 |

---

## 4. 小练习（代码里都做了）

| 练习 | 在哪 |
|---|---|
| 把 title 改成**不含 CH 号**的跑一遍 | `main()` 第 3 段：`retryUntilPassed("fix: 修个 bug", 3)` |
| 加一个**标题为空**打印「标题为空」的分支 | `checkTitle()` 的第一个分支 + `TestCheckTitle` 的「空标题」用例 |
| 再加一个「第二轮补上 CH 号就停」的逻辑 | `retryUntilPassed()` 里的 `if tries == 2` |

---

## 5. 代码

对应代码目录：[`../d03/`](../d03/)

```bash
make run DAY=d03   # 跑示例
make test          # 跑测试
```

| 文件 | 内容 |
|---|---|
| [`../d03/main.go`](../d03/main.go) | `checkTitle`（if 链）/ `countChecks`（三段式 for）/ `retryUntilPassed`（条件式 for）/ `checkAll`（for range）/ `findFirst`（break） |
| [`../d03/main_test.go`](../d03/main_test.go) | 表驱动测试钉死 if 的三个分支 + for 的次数边界 |

### 重点看这几个测试

| 测试 | 钉死的知识点 |
|---|---|
| `TestCheckTitle` | `if / else if / else` 三个分支的**结果**（有 CH / 缺 CH / 空） |
| `TestCountChecks` | 三段式 for 的循环次数**精确相等** |
| `TestRetryStopsAtMax` | 复查次数用完就停 —— **不能死循环** |
| `TestBraceTrap` | 少写大括号是**编译错误**，不是「只执行第一行」 |
| `TestEqualVsAssign` | `==` 比较 vs `=` 赋值 |

---

## 6. 自测

- [ ] 我能默写 Go 的 if 语法，并说出「不写括号、必须写大括号」两条规则
- [ ] 我能解释 `==` 和 `=` 的区别，以及写错时是编译错误还是运行错误
- [ ] 我能用一行写出等价于 `while (cond)` 的 Go 代码
- [ ] 我能说出三种 for 的适用场景（三段式 / 条件式 / range）
- [ ] 我知道 `for range` 遍历 map 为什么顺序是随机的
- [ ] 我能解释 `for !passed {` 为什么会死循环，以及怎么加保险
- [ ] 我知道 `break` 跳出的是哪一层循环
- [ ] 我能说出 `continue` 和 `break` 的区别
