// Package main 演示 Day 4 的函数和返回值：
//
//	函数 = 一段起了名字的代码，给它输入，它给你输出。
//
// 接着 Day 1 的 greet、Day 3 的标题检查，今天把它们都拆成函数。
package main

import (
	"fmt"
	"strings"
)

// ---------------------------------------------------------------
// 1. 最简单的函数：名字 + 参数 + 返回值
// ---------------------------------------------------------------

// greet 具名参数 + 单返回值。
//
// 读法：func 名字(参数名 参数类型) 返回类型 { ... }
// greet 接受一个 string，返回一个 string。
func greet(name string) string {
	return "Hello, " + name
}

// greetWith 返回两个值：问候语 + 长度。
//
// ★ Go 一次返回多个值，直接写成 (string, int)，
//
//	接收的时候按顺序接：msg, n := ...
func greetWith(name string) (string, int) {
	msg := "Hello, " + name
	return msg, len(msg)
}

// ---------------------------------------------------------------
// 2. 没有返回值的函数：只干活，不给结果
// ---------------------------------------------------------------

// printTitle 有参数、没有返回值 —— 它只做「打印」这件事。
//
// ★ 不写返回类型就是「不返回任何东西」，不能写 func printTitle(...) void。
func printTitle(title string) {
	fmt.Printf("  正在检查：%s\n", title)
}

// record 把检查结果记进一个切片里（没有返回值，靠副作用改外面的数据）。
func record(results *[]string, title string) {
	*results = append(*results, title)
}

// ---------------------------------------------------------------
// 3. 多返回值：检查结果 + 原因
// ---------------------------------------------------------------

// hasCHNumber 单个 bool 返回值：有没有 CH 编号。
func hasCHNumber(title string) bool {
	return strings.Contains(title, "CH")
}

// checkTitle 一次返回两个值：通过没通过 + 原因。
//
// ★ return 一执行，函数立刻结束，后面的代码不会再跑。
func checkTitle(title string) (bool, string) {
	if title == "" {
		return false, "标题为空"
	}
	if hasCHNumber(title) {
		return true, "标题包含 CH 编号"
	}
	return false, "标题缺少 CH 编号"
}

// ---------------------------------------------------------------
// 4. 命名返回值：先声明名字，再 return
// ---------------------------------------------------------------

// classifyTitle 用「命名返回值」写法。
//
// 声明了 (passed bool, reason string) 之后，函数体里这两个名字就能直接用，
// 而且可以只写 return（裸 return），Go 会把这两个变量原样返回。
//
// ★ 命名返回值的坑：忘了赋值就 return，会返回零值（false / ""），不是编译错误。
func classifyTitle(title string) (passed bool, reason string) {
	if title == "" {
		return false, "标题为空" // 显式 return：不依赖命名变量
	}
	if hasCHNumber(title) {
		passed = true
		reason = "标题包含 CH 编号"
		return // 裸 return：等价于 return passed, reason
	}
	reason = "标题缺少 CH 编号"
	return
}

// ---------------------------------------------------------------
// 5. 函数也是值：可以赋值、可以当参数传
// ---------------------------------------------------------------

// apply 把一个函数当参数传进来，用完它的结果。
//
// func(string) string 是「函数类型」：接受 string，返回 string 的函数。
func apply(f func(string) string, name string) string {
	return f(name)
}

// shout 是一个接收 string 返回 string 的函数，正好符合 func(string) string。
func shout(name string) string {
	return strings.ToUpper(greet(name))
}

func main() {
	fmt.Println("== 1. 一个参数、一个返回值 ==")
	fmt.Println("  ", greet("Le")) // Hello, Le

	msg, n := greetWith("Le")
	fmt.Printf("  %s（长度 %d）\n", msg, n)

	fmt.Println("\n== 2. 没有返回值的函数 ==")
	printTitle("feat(actions): add cr-prefix check for CH013456")

	results := []string{}
	record(&results, "release: pfb-gcp-v0.1.0")
	record(&results, "fix: 修个 bug")
	fmt.Printf("  记下了 %d 个标题\n", len(results))

	fmt.Println("\n== 3. 一次返回两个值 ==")
	ok, reason := checkTitle("feat(actions): add cr-prefix check for CH013456")
	fmt.Printf("  %v %s\n", ok, reason)

	ok, reason = checkTitle("release: pfb-gcp-v0.1.0")
	fmt.Printf("  %v %s\n", ok, reason)

	// 只要一个值的时候，另一个用 _ 丢掉
	only := func() bool {
		ok, _ := checkTitle("fix: 修个 bug")
		return ok
	}()
	fmt.Printf("  只要 ok（丢掉 reason）：%v\n", only)

	fmt.Println("\n== 4. 命名返回值 ==")
	p, r := classifyTitle("fix: 修个 bug")
	fmt.Printf("  %v %s\n", p, r)

	fmt.Println("\n== 5. 函数也是值 ==")
	f := greet                                      // 函数赋给变量
	fmt.Println("  ", f("Le"))                      // Hello, Le
	fmt.Println("  ", apply(shout, "Le"))           // HELLO, LE
	fmt.Println("  ", apply(func(s string) string { // 匿名函数
		return "[" + s + "]"
	}, "Le")) // [Le]
}
