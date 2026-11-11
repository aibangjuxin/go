# Go 工程实践笔记

> 这里放**不是语言语法、但决定你日常开发效率与上线质量**的内容。
> 语言基础在上一层的 [01~18](../00-index.md)，本文只讲工程实践。

## 文档列表

| # | 文档 | 主题 | 解决什么问题 |
|---|---|---|---|
| 01 | [01-local-debug.md](01-local-debug.md) | 本地调试 | 改代码后怎么最快看到效果；不反复编译；macOS 专属坑 |
| 02 | [02-config-and-deploy.md](02-config-and-deploy.md) | 配置注入与部署 | 变量该放 YAML 还是 env；GKE 部署；哪些不该写死 |
| 03 | [03-go-toolchain.md](03-go-toolchain.md) | 测试与调试工具链 | air / gotestsum / dlv / golangci-lint 怎么装怎么用 |
| 04 | [air.md](air.md) | air 专题 | air 加载哪个配置文件；air ↔ go run ↔ make run 等价关系；字段全解 |

## 两条主线

### 调试（本地）

```
改一行代码
   ↓
make run          ← 0.3s 起服务（增量编译只要 0.09s）
   ↓
curl 打一发 / 用 mock 数据复现 case
   ↓
Air 自动重启 / dlv 断点 / go test -race
```

### 配置（上线）

```
代码默认值  →  policy.yaml (ConfigMap)  →  环境变量 (Secret)
  兜底          业务策略，走 PR             部署维度 + 密钥
```

**判断标准**：
> **"这个值变了，要走代码评审/发版流程吗？"**
> 要 → YAML；不要，只是这台机器不一样 → 环境变量；是密码 → Secret。

## cr-check 相关的重点结论

| 主题 | 结论 |
|---|---|
| 调试 | `-mode mock -sync-eval -now <RFC3339>` 组合能**不改代码**复现任何 case；`/internal/*` 端点可直接看内部状态 |
| 依赖 | `sigs.k8s.io/yaml` 用 **JSON 的 tag 规则** |
| 配置 | `replicas: 2` + 内存幂等 Map = **幂等失效（bug）**；Redis 实现已写好但没接上 |
| 部署 | `ENTRYPOINT` 必须 exec 形式，否则收不到 SIGTERM，优雅关闭失效 |
| 多环境 | 用 Kustomize overlays，不要复制 Deployment |

## 相关

- 上级目录：[Go 学习笔记](../README.md) · [学习地图](../00-index.md)
