# Day 2 · 变量声明的三种方式

> 对应代码：[`../d02/`](../d02/)

## 目标

- [ ] 学会：`:=` / `var` / `var ( ... )` 三种声明
- [ ] 能用一句话解释：**Go 的零值（zero value）**

## 三种写法

```go
// 1. := 短声明 —— 类型由右边推断
title := "feat: add cr-prefix check"  // string
count := 0                             // int

// 2. var 显式声明 —— 类型写在变量名后面
var passed bool                        // 零值 false

// 3. var 块声明 —— 一次声明多个
var (
    s string
    i int
)
```

## 关键点：零值

**Go 里所有变量都有值，不需要初始化。** 声明了没赋值 ≠ 未定义。

| 类型 | 零值 |
|---|---|
| `int` `int64` `float64` | `0` |
| `string` | `""` |
| `bool` | `false` |
| 指针 / map / slice / chan / func / interface | `nil` |

这也是 Go 和 Java 最大的区别之一：Java 里 `int i;` 是「未初始化」，
Go 里 `var i int` 直接就是 `0`，可以直接用。

## 坑

| 坑 | 症状 | 解法 |
|---|---|---|
| 声明了没用 | 编译报错 `declared and not used: x` | 用起来，或 `_ = x` 丢弃 |
| 以为 `var x int` 是「空」 | 实际是 `0`，逻辑判断出错 | 明确写 `var x *int = nil` 表示「没有值」 |
| 忘了类型在后 | 写成 `string name` | 记住 Go 是「名 类型」，和 Java 反过来 |

## 代码

对应代码目录：[`../d02/`](../d02/)

```bash
make run DAY=d02   # 跑示例
make test          # 跑测试（TestZeroValue 验证零值）
```

| 文件 | 内容 |
|---|---|
| [`../d02/main.go`](../d02/main.go) | 三种声明方式 + `build()` |
| [`../d02/main_test.go`](../d02/main_test.go) | `TestBuild` / `TestZeroValue` |

## 自测

- [ ] 我能默写出三种声明方式的区别
- [ ] 我能说出 5 种类型的零值
- [ ] 我知道为什么 `declared and not used` 是编译错误而不是警告
