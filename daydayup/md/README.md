# 📚 学习地图

> 每天一个 Go 小技巧。代码在 [`../dNN/`](../)，笔记在这里。

## 目录约定

| 位置 | 放什么 |
|---|---|
| `md/` | 文档和资料（笔记、速查、坑） |
| `dNN/` | 第 NN 天的代码（`main.go` + `main_test.go`） |
| `scripts/newday.sh` | 一键生成下一天的骨架 |

**代码目录和文档目录一一对应**：`dNN/` ↔ `md/NN-xxx.md`。

## 学习进度

| # | 文档 | 主题 | 代码 |
|---|---|---|---|
| 01 | [01-go-basics.md](01-go-basics.md) | Go 长什么样：package / import / func main | [`d01/`](../d01/) |
| 02 | [02-variables.md](02-variables.md) | 变量声明的三种方式 + 零值 | [`d02/`](../d02/) |
| 03 | [03-if-for.md](03-if-for.md) | if / for：判断 + 循环 | [`d03/`](../d03/) |
| 04 | [04-functions-returns.md](04-functions-returns.md) | 函数和返回值：输入 → 输出 | [`d04/`](../d04/) |
<!-- AUTO-INDEX -->

## 参考文档

不配练习代码的专题笔记，用 cr-check 真实项目举例：

| 文档 | 主题 |
|---|---|
| [04-go-mod.md](04-go-mod.md) | go.mod / go.sum：依赖声明、版本语义化、间接依赖、缓存与常用命令 |

## 之后可以学的（挑着来）

按 `base/` 里的核心概念，从易到难：

| 主题 | 核心问题 |
|---|---|
| Slice vs Array | `append` 到底发生了什么？切片为什么能共享底层数组？ |
| Map | 为什么 `map` 遍历顺序是随机的？ |
| Struct & Method | 值接收者 vs 指针接收者，什么时候必须用指针？ |
| Interface | 为什么 Go 不需要 `implements`？隐式接口怎么实现？ |
| Error | 为什么 Go 没有 try/catch？`errors.Is` / `errors.As` 怎么用？ |
| Defer | 资源释放的推荐写法，`defer` 在什么时候求值？ |
| Goroutine & Channel | `go func()` 起了什么，`select` 怎么选？ |
| Context | 取消信号怎么一路传下去？ |
| Testing | 表驱动测试、fake、`-race` 到底在查什么？ |

## 相关

- [`../base/00-index.md`](../base/00-index.md) —— 核心概念速查（基于 cr-check 项目）
- [`../base/practice/03-go-toolchain.md`](../base/practice/03-go-toolchain.md) —— 工具链手册
