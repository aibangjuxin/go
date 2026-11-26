# OpenShift CI 的 GitHub App 剖解 · 以及企业在 GHES 上落地「PR 门禁」的第 ④ 条路（Prow）

> 这份文档回答三个问题：
> 1. **OpenShift CI 这个 GitHub App 的源码能看到吗？**
> 2. **我已经给 org 下所有仓库装了这个 App，为什么什么都没发生？怎么用起来？**
> 3. **企业内部是 GHES，能不能照着它做一套我们自己的？**
>
> 文中所有"事实"都在 2026-11-25 实际抓取核对过（GitHub API / 仓库内容 / Prow 官方文档），
> 凡是**推断**的地方都单独标了"（推断）"。

---

## 0. TL;DR —— 先看这 8 条

1. **GitHub App 本身没有"源码"可看。** 一个 App = 一份 manifest（权限/事件/Webhook URL/安装范围）+ 一个 Webhook 接收端 + 安装后拿到的 installation token。**里面没有任何 CI 逻辑。**
2. **OpenShift CI App 的"后端"是 Prow**，Prow 是开源的（`kubernetes-sigs/prow`，Apache-2.0），文档在 `docs.prow.k8s.io`。OpenShift 的官方文档里明确写了："Prow is the k8s-native upstream CI system, source code hosted in the kubernetes-sigs/prow repository"。
3. **OpenShift CI 有两个 App**：`openshift-ci`（跑测试/回写状态）+ `openshift-merge-bot`（合并机器人）。官方 onboarding 文档要求**两个都装**。
4. **OpenShift 自己的 Prow 作业配置是公开的**：`openshift/release` 仓库里的
   `ci-operator/config/$org/$repo/`（每个仓库的测试定义）和 `core-services/prow/02_config/`（全局配置 + 插件配置）。
   **看不到的只有那份 App manifest 本身**（`openshift/ci` 仓库现在不是公开仓库，API 返回 404）。
5. ★ **装了 App ≠ 会有 CI。** Prow 的 hook 收到 webhook 后，**只处理"有配置"的仓库**。没有 presubmit 配置的仓库，App 就是个摆设。
6. **想让仓库跑起来只有两条路**：
   - **路 A**：把仓库接进 **OpenShift 官方 CI** —— 给 `openshift/release` 提 PR 加 ci-operator 配置（`make new-repo` / `make jobs`）。这条路**只适合 OpenShift 组件**，且代码要出你的内网。
   - **路 B**：**自建 Prow**（推荐给企业 GHES）。Prow **原生支持 GHES**，官方文档有专门的 "Deploying with GitHub Enterprise" 章节。
7. ★ **GHES 没有 GitHub Actions**（Enterprise Server 不含 Actions，只有 Enterprise Cloud 有）。所以"照抄 Actions 方案"这条路在你们那儿天然不通 —— **Prow 正好是这条缺口的标准答案**。
8. **Prow 有个特性特别适合企业**：`inrepoconfig` —— 把 `.prow.yaml` 放进**业务仓库自己**，就能定义这个仓库要跑什么 job，不用改中心配置。

---

## 1. 这个 App 到底是什么：GitHub App 的解剖

### 1.1 一个 GitHub App 由四部分组成

| 组成 | 说明 | OpenShift CI App 的情况 |
| :--- | :--- | :--- |
| **Manifest** | 权限清单、订阅事件、Webhook URL、安装范围（哪些 org / 哪些 repo） | 私有（`openshift/ci` 仓库当前非公开） |
| **App 后端服务** | 接收 webhook 的 HTTP 服务 | **Prow 的 hook 组件**（开源） |
| **安装凭据** | App ID + RSA 私钥 → 换取 installation token 调 API | 私有 |
| **可见性** | 在 PR 上以 App 身份出现（如 "OpenShift CI"） | 你在 PR 上能看到的那一行 |

**结论**：GitHub App 页面上那个"App"其实只是**一把钥匙 + 一个门铃**。
真正干活的是门铃那头接电话的人。对 OpenShift CI 来说，接电话的是 Red Hat 运营的 Prow 集群（`prow.ci.openshift.org`，Deck 首页可访问，插件目录在 `https://prow.ci.openshift.org/plugins`）。

### 1.2 OpenShift 有两个 App，分工不同

| App | URL | 职责 |
| :--- | :--- | :--- |
| **OpenShift CI** | [github.com/apps/openshift-ci](https://github.com/apps/openshift-ci) | 回写 commit status / check、跑 presubmit、响应 `/test` `/retest` `/lgtm` 等 |
| **Openshift Merge Bot** | [github.com/apps/openshift-merge-bot](https://github.com/apps/openshift-merge-bot) | 自动合并（tide）等 |

官方 onboarding 文档原话（已核对）：

> All repositories need the [Openshift CI](https://github.com/apps/openshift-ci) and the [Openshift Merge Bot](https://github.com/apps/openshift-merge-bot) GitHub Apps installed. Go to the app and click Configure. Repeat the process for the second app.

**你装 App 时要注意**：App 的**权限变更（哪怕是减少）会导致所有 installation 失效，必须全体重新安装**（Prow 官方文档明确警告）。

### 1.3 事件流全景

```
 你的 PR 提交
     │
     ▼
 GitHub（GHES / github.com）
     │  ① webhook 事件（pull_request / issue_comment / push ...）
     │     → 投递到 App 清单里的 Webhook URL，带 HMAC 签名
     ▼
 Prow · hook 组件  ── ② 用 HMAC secret 校验签名
     │  ③ 判断这个 repo 有没有配置？（没配置 → 直接丢弃）
     │  ④ 分发给插件：trigger / testgrid / lgtm / approve / tide / size ...
     ▼
 Prow · prow-controller-manager → plank（调度到 k8s 集群）→ crier（回报）
     │  ⑤ 回写 commit status / check 到 PR 上
     ▼
 GitHub PR 页面：Checks 变绿/变红 → Branch protection 卡住合并
     │
     ▼
 Prow · tide（看 label + 必过 job）→ 合入 / Openshift Merge Bot
```

**第 ③ 步就是你"装了 App 却没反应"的全部原因。**

---

## 2. 源码可见性：能看什么、不能看什么

### 2.1 逐项盘点

| 层 | 有没有公开源码 | 在哪 |
| :--- | :--- | :--- |
| App manifest（App ID / 权限清单 / Webhook URL / 事件订阅） | ❌ **没有** | `openshift/ci` 仓库当前非公开（`api.github.com/repos/openshift/ci` → **404**） |
| CI 引擎（Prow 本体） | ✅ **有** | [github.com/kubernetes-sigs/prow](https://github.com/kubernetes-sigs/prow)（OpenShift 内部可能跑的是自己的 fork，差异不明） |
| Prow 官方文档 | ✅ 有 | [docs.prow.k8s.io](https://docs.prow.k8s.io) |
| OpenShift 的 Prow **全局配置** | ✅ 有 | `openshift/release` → `core-services/prow/02_config/_config.yaml`、`_plugins.yaml` |
| 每个仓库的**测试定义**（ci-operator） | ✅ 有 | `openshift/release` → `ci-operator/config/$org/$repo/$org-$repo-$branch.yaml` |
| 生成出来的 **Prow job** | ✅ 有 | `openshift/release` → `ci-operator/jobs/$org/$repo/...-presubmits.yaml` |
| 生成器（ci-operator → prow job） | ✅ 有 | [github.com/openshift/ci-tools](https://github.com/openshift/ci-tools) → `cmd/ci-operator-prowgen` |
| OpenShift CI 官方文档 | ✅ 有 | [docs.ci.openshift.org](https://docs.ci.openshift.org) （源码 `openshift/ci-docs`） |
| OpenShift 官方的 **webhook 后端部署**（Prow 集群怎么跑的、密钥怎么管） | ❌ 没有 | 内部基础设施 |

### 2.2 为什么"看不到 App manifest"也不影响你复刻

因为 **App manifest 没有任何"聪明"的东西**，它只有 4 个字段是有信息量的：

1. **权限清单** —— Prow 官方文档已经给了最小可用集合（见 §4.2）；
2. **订阅事件** —— Prow 文档说 "In `Subscribe to events` select all events"；
3. **Webhook URL** —— 指向你自己的 Prow `/hook`；
4. **Webhook secret** —— 一段随机 hex，自己生成即可。

**所以结论是：想复刻 OpenShift CI 的"能力"，不需要它的 App，只需要 Prow + 一份作业配置。**

### 2.3 "CI 配置"到底放在哪 —— 三层，别搞混

| 层 | 放什么 | 放哪 | 谁维护 |
| :--- | :--- | :--- | :--- |
| **① App / 凭据层** | 权限、Webhook、token | GitHub App 设置页 + k8s Secret | 平台/安全团队 |
| **② Prow 全局层** | 集群、插件开关、branch protection 策略、deck 主题 | `config.yaml` + `plugins.yaml`（OpenShift 在 `openshift/release/core-services/prow/02_config/`） | CI 管理员 |
| **③ 作业层** | "这个 repo 跑什么 job" | 三选一：中心 `config.yaml` / 仓库内 `.prow.yaml`（inrepoconfig）/ ci-operator 配置 | 业务团队 or CI 管理员 |

OpenShift 走的是 **②+③（ci-operator）** 这一套 —— ci-operator 是一个"配置生成器"：你写 YAML，工具把它展开成一堆 ProwJob YAML，再由 Prow 加载。

> 对企业自建来说，**③ 用 inrepoconfig（仓库内 `.prow.yaml`）通常比 ci-operator 简单一个数量级**，因为 ci-operator 是为"OpenShift 那种几十个仓库、上千个 job、需要 release 联动"的场景设计的。

---

## 3. 装到 org 全部 repo 之后：为什么"什么都没发生"

### 3.1 直接原因

Prow 的 hook 收到事件后，第一步是 **"检查这个 repository 是否 enabled"**。判断依据是：
**有没有为这个 repo 定义 presubmit / postsubmit 作业**（或启用了 inrepoconfig）。

没有配置 → 事件被丢弃 → 不跑任何 job → PR 上连一条 status 都不会有。

**所以"给 org 下所有仓库装 App"这个动作本身，价值为 0**（除非后面还要为每个仓库补配置）。

### 3.2 三种"仓库与 CI 的关系"

| 状态 | 现象 | 该做什么 |
| :--- | :--- | :--- |
| 装了 App，无作业配置 | 完全静默 | 补配置（路 A 或 路 B） |
| 装了 App + 有作业配置 | PR 上出现 check，`/test` 可用 | 正常用 |
| 没装 App 但有作业配置 | Prow 收不到事件 → 同样静默 | 装 App |

### 3.3 路 A：把仓库接进 **OpenShift 官方 CI**（具体步骤）

这条路**只有在你的仓库是 OpenShift 生态组件（要进 OCP release、要跑 e2e）时才有意义**。
但它证明了"App + 配置"这个模式对**外部 org**同样成立 —— `openshift/release` 里就有一堆非 openshift org 的仓库配置，比如 `ci-operator/config/Azure/ARO-HCP/`、`ci-operator/config/3scale/`。

**步骤（全部已核对官方文档）**：

```bash
# 0) 前置：仓库里有 OWNERS 文件（决定 review/approve 归属）
# 1) 安装两个 App
#    https://github.com/apps/openshift-ci            → Configure → 选 org → 选全部 repo
#    https://github.com/apps/openshift-merge-bot     → 同上
#
# 2) clone openshift/release（很大，建议 --filter=blob:none）
git clone --filter=blob:none https://github.com/openshift/release.git
cd release
#
# 3) 交互式生成 ci-operator 配置（官方 target：make new-repo）
#    产出：ci-operator/config/$org/$repo/$org-$repo-$branch.yaml
make new-repo
#
# 4) 生成 Prow job（产出：ci-operator/jobs/$org/$repo/...-presubmits.yaml）
#    全量很慢，可以只生成一个 org/repo：
make jobs WHAT=openshift/addon-operator
#
# 5) 生成插件配置（产出：core-services/prow/02_config/$org/$repo/_pluginconfig.yaml）
make prow-config
#
# 6) 提 PR 到 openshift/release（需 root approver 审核）
```

**产物的形状**（真实样例，`ci-operator/config/openshift/addon-operator/`）：

```yaml
# ci-operator/config/openshift/addon-operator/openshift-addon-operator-main.yaml
binary_build_commands: make all
build_root:
  from_repository: true
images:
  items:
  - dockerfile_path: build/Dockerfile
    to: addon-operator-manager
tests:
- as: coverage
  commands: |
    export CODECOV_TOKEN=$(cat /tmp/secret/CODECOV_TOKEN)
    make coverage
  container:
    from: src
  secret:
    collection: sd-sre-secrets
    group: addon-operator-codecov-token
    mount_path: /tmp/secret
```

生成出来的 Prow job（`ci-operator/jobs/openshift/addon-operator/openshift-addon-operator-main-presubmits.yaml`）：

```yaml
presubmits:
  openshift/addon-operator:
  - agent: kubernetes
    always_run: true
    branches:
    - ^main$
    cluster: build07
    context: ci/prow/ci-index-addon-operator-bundle
    decorate: true
    labels:
      ci.openshift.io/generator: prowgen
    name: pull-ci-openshift-addon-operator-main-ci-index-addon-operator-bundle
    rerun_command: /test ci-index-addon-operator-bundle
    spec:
      containers:
      - command:
        - ci-operator
        image: quay-proxy.ci.openshift.org/openshift/ci:ci_ci-operator_latest
        name: ""
        serviceAccountName: ci-operator
```

> ★ 注意 `rerun_command: /test ci-index-...`，这就是 PR 里 `/test <job>` 命令的来源，
> 以及 PR 上那条 check 的**名字**（`name:` 字段）—— 门禁要 required 的就是这个名字。

**路 A 的三个硬伤**（决定了它不能作为企业通用方案）：

1. **代码要出内网** —— job 跑在 Red Hat 的集群上，克隆你私有仓库需要额外的凭据与授权；
2. **提 PR 到别人的仓库** —— 每次改作业定义都要走 openshift/release 的 review；
3. **只覆盖 OpenShift 场景** —— 跑的是 OCP 的 builder / e2e 流程，不是你公司自己的检查。

---

## 4. 路 B：自建 Prow（★ 企业 GHES 的推荐路线）

### 4.1 架构与组件

| 组件 | 作用 | GHES 相关 |
| :--- | :--- | :--- |
| `hook` | 收 webhook、校验 HMAC、分发给插件 | 需要 GHES 能访问它的 `/hook` |
| `deck` | Web UI（看 job、看日志、重跑） | 需 GHES token 读私有仓库 |
| `prow-controller-manager` | 把 presubmit 配置变成 ProwJob | — |
| `plank` | 在 k8s 里跑 ProwJob（每个 job 一个 pod） | — |
| `crier` | 把 pod 结果回报成 status | 写 GHES 的 status API |
| `sinker` | 清理旧 pod | — |
| `status-reconciler` | 保证 status 与真实 pod 状态一致（防止卡住） | — |
| `tide` | 自动合并（可选） | 需要 admin 级机器人 |
| `branchprotector` | 自动配置/回收 branch protection（可选） | 需要 admin 权限 |
| `ghproxy` | GitHub API 反代缓存，节省 rate limit | GHES 需要改 `--upstream` |
| `peribolos` | 用 App 身份管理 org 成员/团队（可选） | 需要 Members: R/W |

### 4.2 GitHub App：权限与事件（Prow 官方最小集）

仓库级权限：

| 权限 | 需要 | 备注 |
| :--- | :--- | :--- |
| Commit statuses | **Read & write** | 回写 check 的核心权限 |
| Issues | **Read & write** | 处理 `/test` `/lgtm` `/approve` 等评论命令 |
| Pull requests | **Read & write** | PR 元信息、label |
| Metadata | Read-Only | 必选 |
| Administration | Read-Only | 取 team/collaborator；branch protection 自动化要 Read & write |
| Contents | Read | tide 要 Read & write |
| Checks | Read-Only | tide 需要 |
| Actions | Read-Only | tide 需要 |
| Workflows | Read & write | 推荐 |
| Projects | Admin | 仅用 `projects` 插件时 |

组织级权限：**Members: Read-Only**（用 `peribolos` 要 Read & write）；**Projects: Admin**（同上，可不选）。

其他要点：

- **Subscribe to events：全选**（官方原文 "select all events"）；
- Webhook URL 可以先填 dummy，等 Prow 起来再改成 `https://prow.<内网域名>/hook`；
- **Webhook secret**：`openssl rand -hex 20` 生成，同时要写进 Prow 的 `hmac-token` Secret；
- **App ID + 私钥**：创建 App 后 "Generate Private Key" 下载 `.pem`，和 App ID 一起存进 k8s Secret；
- **App 权限一改，所有 installation 都要重装** —— 这条要在变更流程里写死。

### 4.3 部署七步（官方 getting-started-deploy 的骨架）

```bash
# 1) 有个 k8s 集群（OpenShift 也行）
# 2) 两个 Secret
openssl rand -hex 20 > /path/to/hook/secret
kubectl create secret -n prow generic hmac-token --from-file=hmac=/path/to/hook/secret

kubectl create secret -n prow generic github-token \
  --from-file=cert=/path/to/github/cert \
  --from-literal=appid=<你的 App ID>

# 3) ProwJob CRD
kubectl apply --server-side=true \
  -f https://raw.githubusercontent.com/kubernetes-sigs/prow/main/config/prow/cluster/prowjob-crd/prowjob_customresourcedefinition.yaml

# 4) 官方 starter 清单（s3 / gcs / azure 三选一），替换
#    $GITHUB_TOKEN / $GITHUB_APP_ID / $HMAC_TOKEN / $PROW_HOST / $GITHUB_ORG
kubectl apply -f starter.yaml

# 5) 拿 Ingress 地址
kubectl get ingress -n prow prow

# 6) 回 GitHub App 设置页，把 Webhook URL 改成
#    https://prow.<内网域名>/hook ，Webhook secret 填第 2 步的值

# 7) 安装 App 到你的 org / repo
#    App 页面 → Install app → 选 org → 勾 repo
```

起来之后 `deck` 首页应该有一个绿色的 `echo-test`。

### 4.4 ★ GHES 专属配置（最容易踩的一节）

Prow 官方文档 "Deploying with GitHub Enterprise" 给了两种端点形态：

| 形态 | REST v3 | GraphQL v4 |
| :--- | :--- | :--- |
| GHES **带** `api` 子域 | `https://api.<host>` | `https://api.<host>/graphql` |
| GHES **不带** `api` 子域 | `https://<host>/api/v3` | `https://<host>/api/graphql` |

（大多数自建 GHES 是**不带** `api` 子域**的那种**，即 `https://ghe.corp/api/v3`。）

**各组件需要的参数**：

```bash
# ghproxy
--upstream=https://ghe.corp/api/v3
#   ⚠️ 不带 api 子域时，ghproxy 代理不了 graphql（路径不对），graphql 要直连

# crier / deck / hook / status-reconciler / tide / prow-controller-manager
--github-endpoint=http://ghproxy
--github-endpoint=https://ghe.corp/api/v3
--github-graphql-endpoint=https://ghe.corp/api/graphql

# deck / hook / tide / prow-controller-manager
--github-host=ghe.corp
```

**Prow 全局配置（`config.yaml`）**：

```yaml
github:
  link_url: https://ghe.corp        # 决定 PR 里生成链接的域名
```

**ProwJob 配置（clone 相关，最容易"job 卡在 clone"的地方）**：

```yaml
# 每个 job 都要显式给 clone_uri / path_alias
clone_uri: https://ghe.corp/<org>/<repo>.git
path_alias: ghe.corp/<org>/<repo>
# 私有仓库还要配 ssh_host_fingerprints / 凭据
```

### 4.5 作业怎么定义：三种方式

| 方式 | 配置位置 | 适合 |
| :--- | :--- | :--- |
| **中心配置** | Prow 的 `config.yaml` 里 `presubmits: {org/repo: [...]}` | 少量核心仓库，配置由平台统一管 |
| **inrepoconfig** | **业务仓库里的 `.prow.yaml`**（或 `.prow/` 目录下多个 yaml） | ★ 大量仓库，业务团队自己维护 |
| **ci-operator** | 复杂生成链（OpenShift 用的那套） | 超大规模、需要 release 联动 |

**inrepoconfig 开启方式**（Prow `config.yaml`）：

```yaml
in_repo_config:
  enabled:
    "*": true              # 或写具体 org、或 org/repo；最窄的匹配生效
  allowed_clusters:
    "*": ["default"]
```

**仓库内的 `.prow.yaml`（本目录 ci-simulation 就能直接用）**：

```yaml
presubmits:
- name: pull-ci-simulation-test
  always_run: true
  decorate: true
  branches:
  - ^main$
  spec:
    containers:
    - image: python:3.11
      command:
      - bash
      - -lc
      - |
        cd /home/prow/go/src/<org>/<repo>/ci-simulation
        make install-deps
        make test
```

> ★ inrepoconfig 是**按需加载**的：配置写错不会立刻报错，而是"PR 卡住且没有解释"。
> 所以官方建议**再配一个 `checkconfig` 校验 job**，专门校验各仓库的 `.prow.yaml` 语法。

### 4.6 门禁：branch protection + 自动合并

- **branch protection**：Prow 的 `branchprotector` 会**自动**给有必过 job 的仓库设置保护规则。
  OpenShift 侧是每 6 小时跑一次 `periodic-branch-protector`（**所以改完必过 job，最长等 6 小时才生效** —— 这个延迟很反直觉，值得注意）。
- **私有仓库**：Prow 侧要设 `unmanaged: true`（OpenShift 文档明确：private repos 不能用 branch protection 的自动配置）。
- **tide 自动合并**：给 Prow 的机器人 `admin` 权限（要能验证允许的 merge method）；PR 上打 `lgtm` label，所有必过 job 绿了，tide 就合。
  OpenShift 的做法是 `/lgtm` label + `do-not-merge/hold` 兜底。

---

## 5. GHES 上做 Prow 的坑清单

| # | 坑 | 现象 | 解法 |
| :--- | :--- | :--- | :--- |
| 1 | **GHES 没有 GitHub Actions** | `Actions` 菜单不存在 / workflow 不触发 | 用 Prow 或外部 CI；或用 Actions Runner Controller 把 GHES 的 job 派到 EC runner（有限支持） |
| 2 | **API 端点写错** | 401/404/路径 404 | 不带 `api` 子域时必须是 `https://<host>/api/v3`；graphql 同理 |
| 3 | **Webhook 必须是 GHES 能访问到的内网地址** | App 装上但没事件 | Prow 必须在 GHES 可达的网段；证书要能被 GHES 信任（内网 CA 要装进 GHES 信任库） |
| 4 | **clone 私有仓库失败** | job 卡在 clone | 配 `clone_uri` / `path_alias` / 凭据；或用 App token 克隆 |
| 5 | **App 权限变更** | 所有 installation 失效、事件全断 | 权限变更当 breaking change 走，重新安装全部 org |
| 6 | **ghproxy 代理 graphql 失败** | 只有 GraphQL 请求 404 | 不带 `api` 子域时 graphql 直连，不走 ghproxy |
| 7 | **rate limit** | 429 | 装 ghproxy；开 `--github-hourly-tokens` / `--github-allowed-burst` 限流 |
| 8 | **inrepoconfig 写错没人发现** | PR 永远卡住且无提示 | 加 `checkconfig` 校验 job |
| 9 | **branch protection 有 6 小时延迟** | 加了必过 job 但还能合 | 接受延迟，或手工先在 GHES 上配 |
| 10 | **日志/产物落在哪** | 合规问题 | Prow 的 bucket 要落在你们自己的对象存储（OpenShift 用 GCS + `additional_allowed_buckets`） |
| 11 | **App 的事件是"投递"而不是"拉取"** | 事件丢失/延迟 | 配 `status-reconciler` 做状态兜底；job 侧保证幂等 |
| 12 | **GHES 版本差异** | 新 API 在旧 GHES 上没有 | 锁定 GHES 版本矩阵，先验证 Prow 用的 API 在你们版本上都有 |

---

## 6. 与本目录 `ci-simulation` 的衔接（最小可跑）

本目录已经有"检查逻辑"层（`Makefile` + `scripts/` + `charts/`），**正好可以直接塞进 Prow job**：

| 层 | 现状 | Prow 里对应什么 |
| :--- | :--- | :--- |
| 检查逻辑 | `make test`（helm lint + python 单测 + bash 断言） | job 的 `command` |
| 触发器 | Cloud Build trigger / GitHub Actions workflow | Prow 的 `presubmits` + App webhook |
| 回写 | Cloud Build / Actions 自动写 status | Prow 的 `crier` 写 commit status |
| 门禁 | Branch protection required check | 同左，check 名 = ProwJob 的 `name` |

**注意两个细节**（踩过才知道）：

1. **Prow job 里的工作目录不是仓库根**：`decorate: true` 时代码在 `/home/prow/go/src/<org>/<repo>`，所以要 `cd .../ci-simulation`。
2. **job 容器里没有你本机的工具**：本仓库的 `Makefile` 把工具装进 `.tools/`（按平台分目录），正好适配容器（Linux），不用改。详见 `README.md` §4。

---

## 7. 选型对照：你们该走哪条

| 方案 | 跑在哪 | GHES 支持 | 需要自研 App？ | 适合你们吗 |
| :--- | :--- | :--- | :--- | :--- |
| GitHub Actions（原生 workflow） | — | ❌ **GHES 不含 Actions** | 否 | ❌ 前提不成立 |
| Actions Runner Controller（GHES → EC runner） | 你们的 runner | 部分 | 否 | ⚠️ 能用，但 GHES 侧支持有限 |
| 外部 CI（Cloud Build / Jenkins / Tekton） | 外部 | ✅ | 通常要（App 凭证） | ✅ 见 `ci-simulation-enterprise-cloud-build.md` |
| **Prow（自建）** | 你们的 k8s | ✅ **原生支持** | 否（App 是标准件，权限有官方清单） | ✅ **GHES 上的"原生"解** |
| 接入 OpenShift 官方 CI | Red Hat 集群 | — | — | ❌ 只适用 OpenShift 组件 |

**推荐组合**（如果你们已经在跑 Cloud Build 链路）：
**外部 CI 负责"跑"**（省掉 k8s 运维），**Prow/自研 App 负责"门禁语义"**（`/test`、tide、branch protection）；
或者干脆**全用 Prow**，一条链路到底，少一个跨系统对账。

---

## 8. 参考资料（全部已核对可访问）

OpenShift CI 侧：

- App 主页：<https://github.com/apps/openshift-ci>
- Merge Bot：<https://github.com/apps/openshift-merge-bot>
- 官方文档站：<https://docs.ci.openshift.org>
  - 新组件接入：<https://docs.ci.openshift.org/docs/how-tos/onboarding-a-new-component/>
  - ci-operator 架构：<https://docs.ci.openshift.org/docs/architecture/ci-operator/>
  - Branch protection：<https://docs.ci.openshift.org/docs/architecture/branch-protection/>
  - 私有仓库：<https://docs.ci.openshift.org/docs/architecture/private-repositories/>
  - Pipeline 两段式：<https://docs.ci.openshift.org/docs/how-tos/creating-a-pipeline/>
- 配置仓库：<https://github.com/openshift/release>
  - 全局 Prow 配置：`core-services/prow/02_config/_config.yaml`
  - 插件默认配置：`core-services/prow/02_config/_plugins.yaml`
  - 每仓库测试定义：`ci-operator/config/$org/$repo/`
  - 生成的 job：`ci-operator/jobs/$org/$repo/`
- 文档源码：<https://github.com/openshift/ci-docs>
- 生成器：<https://github.com/openshift/ci-tools>（`cmd/ci-operator-prowgen`）
- Prow 实例：<https://prow.ci.openshift.org> ，插件目录 <https://prow.ci.openshift.org/plugins>

Prow 侧（开源）：

- 源码：<https://github.com/kubernetes-sigs/prow>
- 文档：<https://docs.prow.k8s.io>
  - 部署 + **GitHub App 权限清单** + **GHES 端点**：<https://docs.prow.k8s.io/docs/getting-started-deploy/>
  - GitHub 认证（PAT vs App）：<https://docs.prow.k8s.io/docs/github-api-access/>
  - **inrepoconfig（仓库内 `.prow.yaml`）**：<https://docs.prow.k8s.io/docs/inrepoconfig/>
  - hook（webhook）：<https://docs.prow.k8s.io/docs/components/core/hook/>
  - tide（自动合并）：<https://docs.prow.k8s.io/docs/components/core/tide/>
  - branchprotector：<https://docs.prow.k8s.io/docs/components/optional/branchprotector/>
  - peribolos：<https://docs.prow.k8s.io/docs/components/cli-tools/peribolos/>

本目录相关：

- `README.md` —— ci-simulation 怎么跑
- `ci-simulation-enterprise.md` —— 企业版（GHES）整体路线图
- `ci-simulation-enterprise-cloud-build.md` —— GHE × Cloud Build 打通细节

---

## 附录 A · 术语速查

| 词 | 意思 |
| :--- | :--- |
| **GitHub App** | 一种"安装式"应用身份：装到 org/repo 后拿到 installation token，可被授予细粒度权限 |
| **Prow** | Kubernetes 原生的 CI 调度系统（k8s-sigs/prow），OpenShift CI 的引擎 |
| **Hook** | Prow 里接收 GitHub webhook 的组件 |
| **Deck** | Prow 的 Web UI |
| **Plank** | Prow 里真正把 job 跑成 pod 的组件 |
| **Crier** | 回报 job 结果的组件 |
| **Tide** | Prow 的自动合并组件 |
| **ProwJob** | Prow 的作业 CRD |
| **presubmit** | PR 上的测试（合并前必须跑） |
| **postsubmit** | 合并到主干后触发的测试 |
| **periodic** | 定时跑的测试 |
| **ci-operator** | OpenShift 的"配置 → Prow job"生成器 |
| **prowgen** | ci-operator 生成 prow job 的那个子命令 |
| **inrepoconfig** | 把作业配置放进业务仓库的 `.prow.yaml` 的特性 |
| **ghproxy** | Prow 自带的 GitHub API 缓存反代 |
| **branchprotector** | Prow 里自动维护 branch protection 的组件 |
| **peribolos** | Prow 里用 App 身份管理 org 成员的组件 |
| **GHES / GHE** | GitHub Enterprise Server / GitHub Enterprise（Cloud） |

## 附录 B · 上手自查清单

**如果你只想让"官方 OpenShift CI"跑起来**：

- [ ] 确认仓库是要进 OpenShift release 的组件（否则路 A 没意义）
- [ ] 装 `openshift-ci` + `openshift-merge-bot` 两个 App
- [ ] 仓库里有 `OWNERS`
- [ ] 给 `openshift/release` 提 PR：`ci-operator/config/$org/$repo/` + `OWNERS`
- [ ] `make jobs WHAT=$org/$repo` 生成 job 并一起提交
- [ ] `make prow-config` 生成插件配置
- [ ] PR 上出现 `pull-ci-...` 的 check → 在 branch protection 里设为 required
- [ ] 确认 robots（`openshift-ci-robot` / `openshift-merge-robot`）已加为 collaborator 且 merge-robot 有 admin

**如果你要自建 Prow**：

- [ ] k8s 集群 + 域名 + 证书（GHES 要能信任）
- [ ] GHES 上建 App（权限按 §4.2，事件全选）
- [ ] 拿到 App ID + `.pem`
- [ ] 生成 hmac secret
- [ ] 部署 Prow（starter manifest，替换 5 个 `$` 变量）
- [ ] 按 §4.4 配 GHES 端点（**先确认你们有没有 `api` 子域**）
- [ ] Webhook URL 改成内网地址
- [ ] App 安装到 org（**先装 1 个 repo 试点**）
- [ ] 用 `.prow.yaml` 定义第一个 job（先跑 echo，再跑真实检查）
- [ ] 加 `checkconfig` 校验 job
- [ ] branch protection 里把 Prow 的 job 名设为 required（**注意可能有延迟**）
- [ ] 要自动合并 → 给机器人 admin 权限，配 tide
