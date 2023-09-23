以下是在Mac OS上写并执行Hello World程序的步骤:

创建一个文件hello.go,写入以下内容:
package main

import "fmt"

func main() {
  fmt.Println("Hello World!")
}
确保文件在GOPATH的src目录下,例如~/go/src

编译程序:

go build hello.go
这会生成一个可执行文件hello

执行程序:
./hello
会打印:
Hello World!
如果不指定文件名称也可以直接运行:
go run hello.go
主要步骤是:

创建.go文件包含main方法
将文件放在GOPATH/src下编译
编译生成可执行文件
运行可执行文件
这是Go语言最简单的Hello World实例,可以帮助你了解Go如何编写、编译和执行一个程序。从这个例子开始,你可以慢慢学习Go的基本语法和功能
