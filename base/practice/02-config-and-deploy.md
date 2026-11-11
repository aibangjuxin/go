# 02 · 配置注入与部署（本地 → GKE 的配置最佳实践）

> 一句话：**配置要分层，而且每一层只回答一个问题。**
> - **业务策略**（阈值、名单、窗口）→ YAML / ConfigMap，走 PR 改
> - **部署维度**（端口、日志级别、超时、队列大小）→ 环境变量 / 命令行参数
> - **密钥**（token、secret、私钥）→ Secret，绝不进 Git
>
> 本文以 cr-check 为例，逐条评估现状、给出改造方案。

---

## 1. 先回答你的三个问题

| 你的问题 | 结论 |
|---|---|
| **变量放在 Deploy 配置文件里合理吗？** | **部分合理**。Deploy YAML 里应该放**部署维度**（副本、端口、资源、探针、环境变量引用），**不应该放业务阈值**（`minApprovals: 2` 这种）。业务阈值放 ConfigMap 挂载的 `policy.yaml`。 |
| **用变量/入参传进去更适合 Go 吗？** | **是**。Go 的 `os.Getenv` + `flag` 就是社区标准做法（12-factor）。但要**分清哪些参数走哪条路**，不能全都塞进环境变量。 |
| **简单判断不要写死？** | **对**。cr-check 现在有几处硬编码（队列缓冲 256、幂等 TTL 24h、审计缓存 500 条、shutdown 超时 10s），改一次要发版。应该提到配置里。 |

---

## 2. ★ 核心模型：三层配置，各管各的

```
┌─────────────────────────────────────────────────────────┐
│  第 3 层：环境变量 / Secret         ← 部署维度 + 密钥      │
│  （改了要重启 Pod）                                      │
├─────────────────────────────────────────────────────────┤
│  第 2 层：policy.yaml (ConfigMap)  ← 业务策略             │
│  （改配置走 PR，SIGHUP 可热加载，不用发版）               │
├─────────────────────────────────────────────────────────┤
│  第 1 层：代码里的默认值            ← 兜底 + 本地开发       │
└─────────────────────────────────────────────────────────┘
```

**★ 关键：不是所有参数都吃这三层。**
每一类参数应该**只属于一层**，避免"两个真相来源"。

### 决策表（照着填就行）

| 参数类型 | 例子 | 放哪 | 为什么 |
|---|---|---|---|
| **业务策略** | `minApprovals`、`allowedApprovers`、`statusAliases`、`windows` | **YAML / ConfigMap** | 改它 = 改策略，要评审、要留痕；不该因为"调个阈值"就发版 |
| **部署维度** | `LOG_LEVEL`、`WORKERS`、`TIMEOUT`、`QUEUE_SIZE`、`SHUTDOWN_TIMEOUT` | **环境变量** | 跟着环境走（dev/prd/prod 不同），且不同环境不同值 |
| **密钥** | `WEBHOOK_SECRET`、`CR_PLATFORM_TOKEN`、私钥 | **Secret → 环境变量或文件挂载** | 绝不能进 Git，也绝不能出现在 `kubectl describe` 里 |
| **一次性运行参数** | `-config` 路径、`-mode`、`-show-config` | **命令行 flag** | 每次运行可能不同，不是"配置" |
| **代码逻辑** | "审批要几个人算通过" | **Go 代码** | 逻辑不是配置；放 YAML 里会变成"用 YAML 写程序" |

> ★ **一句话判据**：
> **"这个值变了，需要走代码评审/发版流程吗？"**
> - 需要 → 走 PR 的 YAML（业务策略）
> - 不需要，只是"这台机器上不一样" → 环境变量（部署维度）
> - 是密码 → Secret

---

## 3. cr-check 现状评估

### ✅ 做得好的地方

**① 已经分了两层（YAML + env）**

```go
// internal/config/config.go
func (c *Config) applyEnv() {
    set := func(key string, dst *string) {
        if v := os.Getenv(key); v != "" {
            *dst = v
        }
    }
    set("WEBHOOK_SECRET", &c.Webhook.Secret)
    set("GITHUB_APP_PRIVATE_KEY_PATH", &c.GitHub.PrivateKeyPath)
    set("GITHUB_API_URL", &c.GitHub.APIURL)
    set("CR_PLATFORM_URL", &c.CRPlatform.BaseURL)
    set("CR_PLATFORM_TOKEN", &c.CRPlatform.Token)
    set("CHECK_NAME", &c.CheckName)
    ...
}
```

**② 敏感值不进 Git**（YAML 里写 `secret: ""`，靠 env 注入）。

**③ 私钥用文件挂载而不是 env**：

```yaml
volumeMounts:
  - name: githubapp
    mountPath: /etc/cr-check/githubapp
    readOnly: true
```

**★ 这点做对了** —— 私钥在 env 里会被 `kubectl describe pod` 打出来。

### ❌ 需要改进的地方

#### 问题 1：★ 多副本下用内存做幂等 —— 这是真 bug

```go
// cmd/server/main.go
// 幂等存储（本地用内存；生产换 Redis）
store := queue.NewMemoryStore()
```

**但是 `queue.NewRedisStore` 从来没被调用过**：

```bash
$ grep -rn "NewRedisStore" --include="*.go" .
./internal/queue/queue.go:73:func NewRedisStore(...)   # ← 只有定义，没有调用
```

而 `deploy/deployment.yaml` 里：

```yaml
replicas: 2                       # ★ ≥2，避免单点
```

**★ 后果**：两个副本各有各的内存 Map。
GitHub 投递到副本 A，A 记下 delivery-id；重投到副本 B，B 没见过 → **重复处理**。
幂等在多副本下**完全失效**。

**修复**（在 `main.go` 里按配置选实现）：

```go
var store queue.Store
if cfg.Redis.Addr != "" {
    rs := queue.NewRedisStore(cfg.Redis.Addr, cfg.Redis.Password, cfg.Redis.DB, "cr-check:delivery:")
    defer rs.Close()
    store = rs
    logger.Info("幂等存储：Redis", "addr", cfg.Redis.Addr)
} else {
    store = queue.NewMemoryStore()
    if cfg.Server.Replicas > 1 {   // 或者干脆: logger.Warn(...)
        logger.Warn("★ 使用内存幂等存储，多副本下幂等会失效！")
    }
}
```

> ★ **这条同时是"配置驱动"和"正确性"的交叉点**：
> Redis 地址应该是**配置**，不是代码里写死。

#### 问题 2：硬编码的部署维度参数

| 位置 | 硬编码 | 应该在哪 |
|---|---|---|
| `main.go:163` | `queue.NewQueue(256, cfg.Server.Workers)` | `server.queueBuffer` 配置项 |
| `main.go:188` | `DeliveryTTL: 24 * time.Hour` | `webhook.deliveryTTLHours` |
| `main.go:323` | `ReadHeaderTimeout: 10s` | 配置 |
| `main.go:323` | `WriteTimeout: 30s` | 配置 |
| `main.go:323` | `IdleTimeout: 60s` | 配置 |
| `main.go:338` | `shutdownCtx, 10*time.Second` | `server.shutdownTimeoutSeconds` |
| `handler.go:134` | `ttl = 24 * time.Hour`（兜底） | 同上，去掉兜底 |
| `writer.go:83` | `len(w.all) > 200` | `server.logWriterBuffer` |
| `sink.go:60` | `len(s.recs) > 500` | `server.auditBuffer` |
| `main.go` | `GET /internal/audit` 里的 `50` | 常量或配置 |

**★ 这些都属于"部署维度"**，应该走环境变量 / 配置。

#### 问题 3：环境变量只覆盖了 6 项，业务参数一个都改不了

现在的 `applyEnv` 只能改 secret 和几个地址。
**想临时把 `minApprovals` 从 2 改成 1 做灰度？** 现在做不到 —— 只能改 YAML → 走 PR → 重新部署。

**这不一定是坏事**（业务参数走 PR 是好事），但要**明确写下来**：
"哪些参数可以运行时覆盖，哪些不行"。

#### 问题 4：★ 缺少运行时观测与热加载

- 没有 `/version` 端点 → 排查线上问题不知道跑的是哪个版本
- 没有日志级别配置 → 想开 debug 要改代码
- ConfigMap 变了不会自动生效 → 要重启 Pod（Argo CD 靠 `checksum/config` 注解，但那行还是占位符）

#### 问题 5：`checksum/config` 是占位符

```yaml
annotations:
  # ★ 每次改镜像都触发滚动更新（Argo CD 用它判断是否需要 sync）
  checksum/config: "replace-me-with-config-checksum"
```

**这行永远是固定字符串** → 改 ConfigMap **不会**触发滚动更新。

正确做法是用 kustomize 的 `configMapGenerator`（自带 hash 后缀）：

```yaml
# deploy/kustomization.yaml
configMapGenerator:
  - name: cr-check-policy
    files:
      - policy.yaml=config/policy.yaml
    options:
      disableNameSuffixHash: false    # ★ 默认就是 false：名字带 hash
generatorOptions:
  disableNameSuffixHash: false
```

生成的名字会变成 `cr-check-policy-<hash>` → **hash 变了 → Deployment 引用的名字变了 → 自动滚动更新**。
这样 `checksum/config` 注解就可以删掉了。

---

## 4. ★ K8s 里三种注入方式怎么选

| 方式 | 写法 | 优点 | 缺点 | 用在哪 |
|---|---|---|---|---|
| **环境变量** | `valueFrom.secretKeyRef` / `value` | 简单，改了要重启 | **会出现在 `kubectl describe pod` 和 `/proc/1/environ`** | 非敏感标量、部署维度 |
| **ConfigMap 挂载为文件** | `volumeMounts` | 结构化、能存大块内容、可热加载 | 需要自己 reload | **业务策略 YAML** |
| **Secret 挂载为文件** | `volumeMounts` + `secret` | **不暴露在 describe / environ**，权限可控 | 同上 | **私钥、token（敏感）** |

### ★ 安全性排序

```
Secret 挂载为文件  >  Secret 用 env  >  ConfigMap 挂载  >  明文写在 Deployment 里
```

**★ 机密信息永远不要用 env**：

```bash
# ❌ 任何有 pod 读权限的人都能看到
kubectl describe pod cr-check-xxx | grep -A2 env

# ✅ 挂在 tmpfs 上，权限 0400
kubectl exec -it cr-check-xxx -- cat /etc/secrets/token   # 需要额外权限
```

### ★ cr-check 现在的 Secret 处理可以改进

```yaml
# 现在：token 用 env
env:
  - name: CR_PLATFORM_TOKEN
    valueFrom:
      secretKeyRef:
        name: cr-check-crplatform
        key: token
```

**改成文件挂载**：

```yaml
volumeMounts:
  - name: crplatform
    mountPath: /etc/cr-check/crplatform
    readOnly: true
volumes:
  - name: crplatform
    secret:
      secretName: cr-check-crplatform
      defaultMode: 0400
```

代码侧：

```go
// internal/config/config.go
func (c *Config) applyEnv() {
    // 优先读文件（Secret 挂载），回退到 env（本地开发方便）
    if v := readSecretFile("/etc/cr-check/crplatform/token"); v != "" {
        c.CRPlatform.Token = v
        return
    }
    if v := os.Getenv("CR_PLATFORM_TOKEN"); v != "" {
        c.CRPlatform.Token = v
    }
}
```

> ★ **本地开发用 env、生产用文件** —— 同一份代码，两种模式。

### ★ GKE 特有的两个机制

**① Downward API：把 Pod 元信息注入 env**

```yaml
env:
  - name: POD_NAME
    valueFrom:
      fieldRef:
        fieldPath: metadata.name
  - name: POD_NAMESPACE
    valueFrom:
      fieldRef:
        fieldPath: metadata.namespace
  - name: NODE_NAME
    valueFrom:
      fieldRef:
        fieldPath: spec.nodeName
```

> ★ **日志里带上 pod 名**是排查"到底哪个副本出的问题"的基础。
> cr-check 的日志现在只有 pod 级上下文（Argo CD 收集时会加），
> 建议显式打出来。

**② ConfigMap 变更的传播延迟**

ConfigMap 挂载的文件更新**不是即时的**，kubelet 有同步周期（默认最长 ~60 秒 + 缓存）。
所以：

- **env 改了 → 必须重启 Pod**
- **ConfigMap 文件改了 → 最多等 ~1 分钟，但需要你主动 reload**

---

## 5. ★ 改造方案 A：把部署维度参数提到环境变量

### 5.1 定义一份"配置契约"

在 `internal/config/config.go` 里集中定义：

```go
// ServerConfig 是服务端自身的配置。
type ServerConfig struct {
    Addr string `json:"addr"`
    SyncEval bool `json:"syncEval"`
    Workers int `json:"workers"`
    RecheckIntervalSeconds int `json:"recheckIntervalSeconds"`

    // ★ 新增：以下为部署维度参数，默认值来自环境变量
    QueueBuffer          int    `json:"queueBuffer"`
    DeliveryTTLHours     int    `json:"deliveryTTLHours"`
    ShutdownTimeoutSeconds int  `json:"shutdownTimeoutSeconds"`
    ReadHeaderTimeoutSeconds int `json:"readHeaderTimeoutSeconds"`
    WriteTimeoutSeconds      int `json:"writeTimeoutSeconds"`
    IdleTimeoutSeconds       int `json:"idleTimeoutSeconds"`
}
```

### 5.2 写一个好用的 env 解析工具

```go
// internal/config/env.go
package config

import (
    "os"
    "strconv"
    "time"
)

// envString 取字符串环境变量，为空时用默认值。
func envString(key, def string) string {
    if v := os.Getenv(key); v != "" {
        return v
    }
    return def
}

// envInt 取整型环境变量。
func envInt(key string, def int) int {
    if v := os.Getenv(key); v != "" {
        if n, err := strconv.Atoi(v); err == nil {
            return n
        }
    }
    return def
}

// envBool 取布尔环境变量（支持 1/true/yes/on）。
func envBool(key string, def bool) bool {
    if v := os.Getenv(key); v != "" {
        if b, err := strconv.ParseBool(v); err == nil {
            return b
        }
    }
    return def
}

// envDuration 取时长环境变量（单位：秒）。
func envDuration(key string, def time.Duration) time.Duration {
    return time.Duration(envInt(key, int(def.Seconds()))) * time.Second
}
```

### 5.3 应用

```go
func (c *Config) applyEnv() {
    // ── 敏感项（保持现状）──
    set := func(key string, dst *string) { ... }
    set("WEBHOOK_SECRET", &c.Webhook.Secret)
    set("CR_PLATFORM_TOKEN", &c.CRPlatform.Token)
    ...

    // ── 部署维度 ──
    c.Server.QueueBuffer = envInt("QUEUE_BUFFER", c.Server.QueueBuffer)
    c.Server.Workers = envInt("WORKERS", c.Server.Workers)
    c.Server.DeliveryTTLHours = envInt("DELIVERY_TTL_HOURS", c.Server.DeliveryTTLHours)
    c.Server.ShutdownTimeoutSeconds = envInt("SHUTDOWN_TIMEOUT_SECONDS", c.Server.ShutdownTimeoutSeconds)
    c.Server.ReadHeaderTimeoutSeconds = envInt("READ_HEADER_TIMEOUT_SECONDS", c.Server.ReadHeaderTimeoutSeconds)
    c.Server.WriteTimeoutSeconds = envInt("WRITE_TIMEOUT_SECONDS", c.Server.WriteTimeoutSeconds)
    c.Server.IdleTimeoutSeconds = envInt("IDLE_TIMEOUT_SECONDS", c.Server.IdleTimeoutSeconds)
}
```

> ★ **注意分层**：`envInt("WORKERS", c.Server.Workers)` 的默认值来自 YAML。
> 也就是说 **YAML 里能配，env 能覆盖** —— 这是"第 2 层 < 第 3 层"的优先级。
>
> **但业务参数（`minApprovals` 等）故意不给 env 覆盖** ——
> 它们必须走 PR。这是有意的设计，不是遗漏。

### 5.4 用起来

```go
// cmd/server/main.go
jobQueue := queue.NewQueue(cfg.Server.QueueBuffer, cfg.Server.Workers)

handler := &webhook.Handler{
    ...
    DeliveryTTL: time.Duration(cfg.Server.DeliveryTTLHours) * time.Hour,
}

srv := &http.Server{
    Addr:              cfg.Server.Addr,
    Handler:           mux,
    ReadHeaderTimeout: time.Duration(cfg.Server.ReadHeaderTimeoutSeconds) * time.Second,
    WriteTimeout:      time.Duration(cfg.Server.WriteTimeoutSeconds) * time.Second,
    IdleTimeout:       time.Duration(cfg.Server.IdleTimeoutSeconds) * time.Second,
}

shutdownCtx, cancel := context.WithTimeout(context.Background(),
    time.Duration(cfg.Server.ShutdownTimeoutSeconds)*time.Second)
```

---

## 6. ★ 改造方案 B：多环境用 Kustomize overlays

**一套 YAML 走天下是错的**。dev / prd / prod 的差异应该用 overlay 表达。

### 目录结构

```
deploy/
├── base/                    # 公共部分
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── ingress.yaml
│   └── kustomization.yaml
├── overlays/
│   ├── dev/
│   │   ├── kustomization.yaml
│   │   └── patch-deployment.yaml
│   ├── prd/
│   │   ├── kustomization.yaml
│   │   └── patch-deployment.yaml
│   └── prod/
│       ├── kustomization.yaml
│       └── patch-deployment.yaml
```

### base/kustomization.yaml

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: cr-check

resources:
  - deployment.yaml
  - service.yaml
  - ingress.yaml

configMapGenerator:
  - name: cr-check-policy
    files:
      - policy.yaml=config/policy.yaml     # ★ 从仓库根的 config/ 拿

generatorOptions:
  disableNameSuffixHash: false             # ★ 名字带 hash → 变了自动滚动更新
```

### overlays/prod/kustomization.yaml

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: cr-check

resources:
  - ../../base

configMapGenerator:
  - name: cr-check-policy
    files:
      - policy.yaml=../../config/policy.prod.yaml   # ★ 生产用不同策略

patches:
  - path: patch-deployment.yaml

images:
  - name: ghcr.io/acme/cr-check
    newTag: v1.4.2
```

### overlays/prod/patch-deployment.yaml

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cr-check
spec:
  replicas: 4
  template:
    spec:
      containers:
        - name: cr-check
          env:
            - name: LOG_LEVEL
              value: "info"
            - name: WORKERS
              value: "8"
            - name: QUEUE_BUFFER
              value: "1024"
            - name: SHUTDOWN_TIMEOUT_SECONDS
              value: "30"
```

**★ 好处**：
- 差异一目了然（prod 4 副本 8 worker，dev 1 副本 2 worker）
- 公共部分只有一份，不会"改了 dev 忘了改 prod"
- **业务策略仍然只有一份 YAML**（`config/policy.prod.yaml`），走 PR 评审

---

## 7. ★ 改造方案 C：特性开关（Feature Flag）

**"有些地方用简单判断，不要写死"** —— 这就是特性开关的场景。

### 什么时候需要开关

| 场景 | 开关 |
|---|---|
| 新判定逻辑灰度 | `FEATURE_NEW_RULES_ENABLED` |
| 换掉幂等存储实现 | `STORE_REDIS_ENABLED` |
| 异步判定 vs 同步判定 | `server.syncEval`（已有） |
| 临时放宽某条规则 | `CR_MIN_APPROVALS_OVERRIDE`（⚠️ 慎用） |
| 打开 pprof | `PPROF_ENABLED` |

### Go 里的写法

```go
// internal/config/config.go
type FeatureFlags struct {
    NewRulesEnabled bool `json:"newRulesEnabled"`
    StoreRedis      bool `json:"storeRedis"`
    PprofEnabled    bool `json:"pprofEnabled"`
}
```

```go
// cmd/server/main.go
if cfg.Features.PprofEnabled {
    mux.HandleFunc("/debug/pprof/", pprof.Index)
    logger.Warn("★ pprof 已开启（仅限内部网络访问）")
}
```

```go
// internal/rules/engine.go
for _, r := range e.rules() {
    if r.id == "R11" && !e.cfg.Features.NewRulesEnabled {
        out.Skipped = append(out.Skipped, "R11")
        continue
    }
    ...
}
```

> ★ **★ 开关是"临时手段"，不是"永久架构"。**
> 每个开关都要有：
> 1. **默认关闭**（新功能默认不影响现有行为）
> 2. **有清理计划**（灰度完成后删掉代码和开关）
> 3. **写进日志**（`logger.Info("启动 CR Check", "features_new_rules", cfg.Features.NewRulesEnabled)`）
>
> **开关堆积 = 技术债堆积。** 一年后没人记得它是干嘛的。

---

## 8. ★ 改造方案 D：SIGHUP 热加载配置

**这是"业务策略不该写死在 Deploy 里"的终极解法。**

### 现状的问题

```
改 policy.yaml → 走 PR → Argo CD sync → ConfigMap 更新 → Pod 重启
                                                      ↑
                                    重启 = 短暂不可用（滚动更新能缓解）
```

### 改进：SIGHUP 重载

```go
// cmd/server/main.go
func run(ctx context.Context, ...) error {
    ...
    // 启动时加载
    cfg, err := config.Load(configPath)
    ...

    // SIGHUP → 重新加载配置
    hup := make(chan os.Signal, 1)
    signal.Notify(hup, syscall.SIGHUP)
    go func() {
        for {
            select {
            case <-ctx.Done():
                return
            case <-hup:
                newCfg, err := config.Load(configPath)
                if err != nil {
                    logger.Error("重载配置失败，继续使用旧配置", "err", err)
                    continue          // ★ 加载失败要保留旧配置！
                }
                *cfg = *newCfg        // 原子替换（⚠️ 要注意并发读）
                logger.Info("配置已热重载")
            }
        }
    }()
}
```

> ⚠️ **并发安全**：`*cfg = *newCfg` 是整体替换指针指向的结构体，
> 如果别的 goroutine 正在读 `cfg.CR.MinApprovals`，会有竞态。
> **正确做法**：把 `*config.Config` 换成 `atomic.Pointer[config.Config]`，
> 读的时候 `cfg.Load()`。

```go
type Config struct {
    ptr atomic.Pointer[Config]   // ...
}

// 用的时候
cfg := c.ptr.Load()
```

> ★ 这就是 `sync/atomic` 的典型用法（见 [09-sync.md](../09-sync.md)）。

### 什么时候值得做

| 情况 | 值不值得 |
|---|---|
| 策略经常改（每天/每周） | ✅ 值得 |
| 策略一年改两次 | ❌ 不值得（重启就行） |
| 改配置要立刻生效（封禁某个人） | ✅ 必须 |

> ★ **先问一句"多久改一次"**。为了一个一年改两次的配置写热加载，
> 是典型的过度设计。

---

## 9. ★ 环境变量命名规范

```bash
# 格式：<服务名>_<参数名>，全大写下划线
CR_CHECK_LOG_LEVEL
CR_CHECK_WORKERS
CR_CHECK_QUEUE_BUFFER
CR_CHECK_SHUTDOWN_TIMEOUT_SECONDS

# 密钥（不加前缀，避免泄露服务名？—— 其实加了更清晰）
CR_CHECK_WEBHOOK_SECRET
```

| 规则 | 理由 |
|---|---|
| 全大写 + 下划线 | shell 友好，不容易被 shell 误转义 |
| 带服务名前缀 | 多个服务共享一个 Pod 时不冲突 |
| 带单位后缀（`_SECONDS`、`_BYTES`） | 避免"秒还是毫秒"的歧义（Go 的 `time.Duration` 内部是纳秒！） |
| 布尔用 `true/false` | `strconv.ParseBool` 直接支持 |

### ★ 特别注意时间单位

```go
// ❌ 危险：Duration 内部是纳秒
timeout := time.Duration(envInt("TIMEOUT", 30)) * time.Second   // ✅ 显式乘

// ❌❌ 千万别这样
timeout := time.Duration(envInt("TIMEOUT", 30))   // 30 纳秒！
```

---

## 10. ★ 完整的"本地 → GKE"工作流

```
┌── 本地开发 ────────────────────────────────────────────────┐
│                                                              │
│  config/policy.yaml  ← 唯一真相来源（业务策略）               │
│  .env / export  ← 本地覆盖（敏感项）                        │
│                                                              │
│  make run          # mock 模式，0.3s 起服务                  │
│  make run NOW=...  # 固定时间，验证时间相关规则               │
│  make debug        # Delve 断点                              │
│                                                              │
└────────────────────────┬─────────────────────────────────────┘
                         │ git push → PR → CODEOWNERS 复核
                         ▼
┌── CI ───────────────────────────────────────────────────────┐
│  gofmt / go vet / golangci-lint / go test -race             │
│  docker build → 推 ghcr.io                                  │
│  kustomize build deploy/overlays/prod | kubectl apply       │
└────────────────────────┬─────────────────────────────────────┘
                         ▼
┌── GKE (Argo CD 托管) ────────────────────────────────────────┐
│                                                              │
│  Deployment.yaml    ← 部署维度：副本、端口、资源、探针        │
│     env:                                                        │
│       LOG_LEVEL / WORKERS / QUEUE_BUFFER  ← 部署维度         │
│       WEBHOOK_SECRET / CR_PLATFORM_TOKEN ← 密钥(Secret)      │
│                                                              │
│  ConfigMap cr-check-policy-<hash>                          │
│     └─ policy.yaml  ← 业务策略（来自仓库的 config/）         │
│                                                              │
│  Secret cr-check-crplatform                                │
│     └─ token  ← 挂载为文件，不进 env                         │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### ★ 一条铁律

> **Deployment YAML 里不应该出现业务语义的数字。**
>
> ❌ `minApprovals: 2` 写在 Deployment 的 env 里
> ✅ `minApprovals: 2` 写在 `config/policy.yaml` 里
>
> 因为前者是"代码评审看不到的魔法数字"，
> 后者是"有 owner、有历史、可追溯的策略文件"。

---

## 11. 改造优先级（按性价比排序）

| 优先级 | 事项 | 理由 |
|---|---|---|
| **P0** | **多副本改用 Redis 做幂等** | **这是 bug，不是优化**（`replicas: 2` + 内存 Map = 幂等失效） |
| **P0** | 加 `/version` 端点 + 版本注入 | 排查问题的基本工具 |
| **P1** | 部署维度参数提到 env（queue buffer / TTL / 超时 / workers） | 消除硬编码 |
| **P1** | 补 `terminationGracePeriodSeconds` + `preStop` | 优雅关闭现在会被 k8s 砍掉 |
| **P1** | Secret 改成文件挂载（token） | 安全基线 |
| **P2** | kustomize overlays（base + overlays/dev|prd|prod） | 多环境可维护性 |
| **P2** | `configMapGenerator` 替代占位符 `checksum/config` | 让配置变更真的能生效 |
| **P2** | 日志级别可配置（`LOG_LEVEL`） | 线上排查不用发版 |
| **P3** | SIGHUP 热加载配置 | 只有"策略改得频繁"才做 |
| **P3** | 特性开关体系 | 有新功能时再做，不要提前造 |

---

## 12. 一句话总结

> **配置分三层，各管各的，别混。**
> - **业务策略 → YAML/ConfigMap**（走 PR，可评审、可追溯）
> - **部署维度 → 环境变量**（跟着环境走，改了要重启）
> - **密钥 → Secret**，且**尽量挂载成文件而不是 env**
> - 一次性运行参数 → 命令行 flag
> - **★ 硬编码的部署参数（缓冲 256、TTL 24h、超时 10s）必须提到配置**
> - **★ 多副本 + 内存幂等 = bug**（cr-check 现在就有）
> - 多环境差异用 Kustomize overlays 表达，不要复制 Deployment
> - 特性开关默认关闭、有清理计划、写进启动日志
> - **判断标准："这个值变了要不要发版？"** 要 → YAML；不要 → env

---

## 13. 自测题

1. 为什么 `minApprovals` 不应该用环境变量注入？
2. `replicas: 2` + `queue.NewMemoryStore()` 会导致什么问题？
3. 为什么私钥/token 应该挂载成文件而不是 env？
4. `QUEUE_BUFFER=1024` 这种"部署维度"和 `minApprovals=2` 这种"业务策略"，改动的流程有什么不同？
5. 为什么 `time.Duration(envInt("TIMEOUT", 30))` 是个 bug？
6. Kustomize 的 `configMapGenerator` 为什么能解决"改了 ConfigMap 不生效"？
7. 什么时候**不该**做 SIGHUP 热加载？
8. 特性开关为什么必须"默认关闭"且"有清理计划"？

---

上一篇：[01-local-debug.md](01-local-debug.md) ｜ 回到 [README.md](README.md)
