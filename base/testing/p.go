package main

import (
    "fmt"
    "os"
)


func main() {
  kubeconfig := os.Getenv("HOME") + "/.kube/config"
  fmt.Println(kubeconfig)
}
// output /Users/lex/.kube/config
