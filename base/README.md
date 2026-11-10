# Go 学习笔记

基于 `/Users/lex/git/go/cr-check` 这个真实项目整理的 Go 核心概念速查。

## 入口

👉 **[00-index.md](00-index.md)** —— 学习地图、项目结构、Go vs Java 速查

## 文档列表

| # | 文档 | 主题 |
|---|---|---|
| 00 | [00-index.md](00-index.md) | 学习地图 · 项目结构 · 工具链 |
| 01 | [01-struct.md](01-struct.md) | Struct（结构体） |
| 02 | [02-method.md](02-method.md) | Method（方法）· 值接收者 vs 指针接收者 |
| 03 | [03-interface.md](03-interface.md) | Interface（接口）· 隐式实现 · 鸭子类型 |
| 04 | [04-constructor.md](04-constructor.md) | Constructor（构造函数模式 `NewXxx`） |
| 05 | [05-dependency-injection.md](05-dependency-injection.md) | Dependency Injection（依赖注入） |
| 06 | [06-factory.md](06-factory.md) | Factory Pattern（工厂模式） |
| 07 | [07-context.md](07-context.md) | Context（上下文与生命周期管理） |
| — | [newclient.md](newclient.md) | NewClient 通用介绍（先读这篇） |

## 快速上手

```bash
cd /Users/lex/git/go/cr-check

make run     # mock 模式起服务（:8080）
make test    # 跑测试
make vet     # 静态检查
```

```bash
curl -s -X POST http://localhost:8080/github/webhook \
  -H 'X-GitHub-Event: pull_request' \
  -H 'X-GitHub-Delivery: demo-1' \
  -H 'Content-Type: application/json' \
  --data @testdata/pr-event.json | jq
```
