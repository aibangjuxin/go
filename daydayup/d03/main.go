// Package main 演示 Day 3 的 if / for：让程序自己做判断、重复做事。
//
// 接着用 Day 2 那三个变量：
//   - title   PR 标题
//   - passed  检查结果
//   - count   记检查了几次
package main

import (
	"fmt"
	"strings"
)

// CheckResult 是标题检查的结果。
type CheckResult struct {
	Passed bool   // 是否通过
	Reason string // 没通过时说明缺什么
}

// checkTitle 用 if / else if / else 判断标题合不合规。
//
// ★ Go 的 if：条件不用圆括号，但大括号必须有。
// ★ == 是「比较」，= 是「赋值」—— 写错是编译错误，不是逻辑 bug。
func checkTitle(title string) CheckResult {
	if title == "" {
		return CheckResult{Passed: false, Reason: "标题为空"}
	} else if strings.Contains(title, "CH") {
		return CheckResult{Passed: true, Reason: "标题通过"}
	} else {
		return CheckResult{Passed: false, Reason: "标题缺少 CH 号"}
	}
}

// countChecks 三段式 for：初始化 / 条件 / 步进。
//
// count++ 和 count = count + 1 完全等价。
func countChecks(times int) int {
	count := 0
	for i := 0; i < times; i++ {
		count++
	}
	return count
}

// retryUntilPassed 模拟「复查直到通过」。
//
// Go 没有 while 关键字，三段式 for 把「初始化」和「步进」留空，就是别的语言的 while。
// ★ 循环条件里同时盯着两件事：还没通过（!passed）而且还没超次数（tries < maxTries）。
func retryUntilPassed(title string, maxTries int) (passed bool, tries int) {
	for !passed && tries < maxTries {
		tries++
		// 第二轮「补上 CH 号」—— 模拟用户改了标题再来一次
		if tries == 2 {
			title = "feat(actions): add cr-prefix check for CH013456"
		}
		r := checkTitle(title)
		fmt.Printf("  第 %d 次复查…… %s\n", tries, r.Reason)
		if r.Passed {
			passed = true
		}
	}
	return passed, tries
}

// checkAll 用 for range 遍历一批标题，统计通过几个。
//
// for range 可以拿到下标和值；只要值就写 for _, v := range。
func checkAll(titles []string) (total, passed int) {
	for _, title := range titles {
		total++
		if checkTitle(title).Passed {
			passed++
		}
	}
	return total, passed
}

// findFirst 演示 break：找到第一个就停，不再往下走。
func findFirst(titles []string) (string, bool) {
	for _, title := range titles {
		if checkTitle(title).Passed {
			return title, true
		}
	}
	return "", false
}

func main() {
	// ---- Day 2 的三个变量 ----
	title := "feat(actions): add cr-prefix check for CH013456"
	passed := false
	count := 0

	fmt.Println("== 1. if：符合条件才执行 ==")
	r := checkTitle(title)
	passed = r.Passed
	fmt.Printf("  %s\n  → %s\n", title, r.Reason)
	if !passed {
		fmt.Println("  passed = false，检查不通过")
	} else {
		fmt.Println("  passed = true，检查通过")
	}

	fmt.Println("\n== 2. for（三段式）：重复做同一件事 ==")
	count = countChecks(3)
	fmt.Printf("  一共检查了 %d 次\n", count)

	fmt.Println("\n== 3. for（条件式）：相当于 while ==")
	ok, tries := retryUntilPassed("fix: 修个 bug", 3)
	fmt.Printf("  最终结果：%v（共复查 %d 次）\n", ok, tries)

	fmt.Println("\n== 4. for range：遍历一批标题 ==")
	titles := []string{
		"feat(actions): add cr-prefix check for CH013456", // 有 CH → 通过
		"fix: 修个 bug", // 缺 CH → 不通过
		"",            // 空标题 → 不通过
	}
	total, good := checkAll(titles)
	fmt.Printf("  %d 个标题，%d 个通过\n", total, good)

	first, found := findFirst(titles)
	fmt.Printf("  第一个通过的是：%q（found=%v）\n", first, found)
}
