package main

import "fmt"

func main() {
  fmt.Println("Hello World!")
      // 调用自定义的函数来操作数组
  myArray := createAndPrintArray()
  fmt.Println("主函数中的数组:", myArray)
}


func createAndPrintArray() [5]int {
    // 定义和操作数组的函数
    var myArray [5]int
    for i := 0; i < 5; i++ {
        myArray[i] = i + 1
    }

    fmt.Println("自定义函数中的数组:", myArray)

    return myArray
}
