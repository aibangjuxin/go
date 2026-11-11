package main

import "fmt"

// Flags 是今天的三种变量声明方式。
type Flags struct {
	Title  string // := 短声明：Go 自己推断类型，string
	Count  int    // := 推断为 int
	Passed bool   // var 显式声明：先声明类型，值是零值 false
}

// build 演示三种声明方式。
func build() Flags {
	// := 短声明：Go 自己推断类型
	title := "feat: add cr-prefix check"
	// 推断为 int
	count := 0

	// var 显式声明：先声明类型，值是零值 false
	var passed bool
	passed = true

	return Flags{Title: title, Count: count, Passed: passed}
}

func main() {
	f := build()
	fmt.Println(f.Title)
	fmt.Println(f.Count)
	fmt.Println(f.Passed)
}
