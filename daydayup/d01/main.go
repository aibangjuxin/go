package main

import "fmt"

// greet 是今天学到的东西：函数 + 具名返回值 + 字符串拼接。
func greet(name string) string {
	return "Hello, " + name
}

func main() {
	fmt.Println(greet("Le"))
}
