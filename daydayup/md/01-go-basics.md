# Day 1 · Go 长什么样

> 对应代码：[`../d01/`](../d01/)

> 一句话目标：先能看懂 Go 代码，尤其是 CR Check 那种 Go 代码。

## Go 是干什么的

Go 是 Google 做的语言，专门写服务端、常驻服务。CR Check 这种一直跑着等 Webhook 的服务就很适合它。

语法特意做得很简单，编译后就是一个可执行文件。

现在最新稳定版是 Go 1.27.3，2026 年 10 月 19 日发布的。装的话去 [go.dev/dl](https://go.dev/dl)，装完跑 `go version` 能看到版本号就行。

## 先看最小的一段

```go
package main

import "fmt"

func main() {
	fmt.Println("Hello, Le")
}
```

## 逐行拆开

读代码就靠这几行：

| 你看到的 | 意思是 |
|---|---|
| `package main` | 文件属于哪个包 |
| `import "fmt"` | 用了哪些现成的包 |
| `func 名字()` | 一个函数 / 一段要做的事 |
| `x := 123` | 新建一个变量，类型自动推断，不用写 |
| `var name string = "Le"` | 新建一个变量，明确写出类型是字符串 |
| `if` / `for` | 判断 / 循环，和别的语言差不多 |
| `return` | 函数做完，把结果交回去 |

**记住一个规律：Go 里类型写在变量名后面。** `name string` 就是「name 是 string」——和很多语言反过来，刚开始别扭，看两天就顺了。

## 贴近 CR Check 的样子

CR Check 的核心就是收到 GitHub 发来的 Webhook，然后判断、回状态。大概长这样：

```go
func handleWebhook(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		return
	}
	fmt.Println("收到一个 PR 事件")
}
```

| 代码 | 意思 |
|---|---|
| `w` | 回信用的笔，用来给 GitHub 回结果 |
| `r` | 收到的那封信，里面有 PR 信息 |
| `*http.Request` | `*` 先不用深究，暂时理解为「这是一份 Request 的引用」 |
| `!=` | 不等于，不是 POST 就直接 return，不往下走 |

能读出上面这段，你 Day 1 就过关了。

---

## 今日练习（`../d01/`）

```bash
make run DAY=d01   # 跑示例
make test          # 跑测试
```

| 文件 | 内容 |
|---|---|
| [`../d01/main.go`](../d01/main.go) | `greet()` 函数 + `main()` 入口 |
| [`../d01/main_test.go`](../d01/main_test.go) | 表驱动测试（table-driven test） |

## 自测

- [ ] 我能解释 `package main` 和 `package rules` 的区别
- [ ] 我能解释 `import "fmt"` 到底在做什么
- [ ] 我知道 `func main()` 是唯一的入口
- [ ] 我知道 `x := 123` 和 `var x int = 123` 的区别
- [ ] 我知道为什么「声明了没用」会编译报错
