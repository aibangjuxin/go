package main

import (
    "flag"
    "fmt"
)

func main() {
    // 定义命令行参数
    messagePtr := flag.String("message", "Hello, World!", "A message to display")

    // 解析命令行参数
    flag.Parse()

    // 使用命令行参数
    message := *messagePtr
    fmt.Println(message)
}

