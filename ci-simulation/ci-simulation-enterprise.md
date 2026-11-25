# CI Simulation · 企业版（GitHub Enterprise）怎么走同一条 PR 门禁链路

> **副标题**：先把"check 到底是什么、能不能搬"**说清楚**，
> 再把**外部 CI 这条路**拆到"照着做就能落地"的程度。
>
> **本文回答三个问题**
>
> | # | 问题 | 答案 | 章节 |
> |---|---|---|---|
> | Q1 | 这三个 check 是 Actions 里的东西，能不能搬到企业版 GH？ | ★ **一半能搬，一半不能**：<br>✅ **能搬**：check 的**名字**（context）、**门禁配置**、以及"PR 上挂一条记录"这个**机制**<br>❌ **不能原样搬**：`.github/workflows/pr-checks.yml` 这个**文件**（能不能用取决于 Actions 是否可用）、以及里面 ruby/bash/python 那段**检查逻辑**（运行时不同） | [`1](#1-事实澄清这三条-check-到底是什么) |
> | Q2 | 自研 App 要写逻辑 + 要部署，太重？ | ★ **顾虑成立**。所以除了自研 App，还有一条**几乎零重写**的路：<br>**B2 · 自建 runner**（GHES 上 Actions 若可用 → workflow 一个字不改）<br>和 **B1/B3/B4 · 外部 CI**（部署的是**现成 CI**，不是自研代码） | [`3](#3-路线-a自研-github-app什么时候才真的需要)、[`4](#4-路线-b外部-ci全攻略) |
> | Q3 | 外部 CI 这条路具体怎么走？ | ★ 拆成 **4 个子方案 + 1 张"谁回写"对比表 + 验收清单**：<br>B1 Cloud Build 2nd gen + GHE｜B2 自建 runner｜B3 内网 CI（Jenkins/Tekton）｜B4 Argo CD Notifications<br>★ 关键认知：**"谁执行"和"谁回写"是两个正交的选择**，别混在一起选 | [`4](#4-路线-b外部-ci全攻略) |

> 📖 **术语不熟先看**：[ci-simulation-enterprise-cloud-build.md](ci-simulation-enterprise-cloud-build.md) 顶部的「术语表」
> （GHE / GHES / check run / commit status / context / ruleset / App token / connection / trigger …）

---

## 目录

| 章节 | 内容 |
|---|---|
| [1](#1-事实澄清这三条-check-到底是什么) | **事实澄清**：四样东西分清 + 逐项"能不能在 GHE 里用" |
| [2](#2-企业版现状先分清三种可能) | L1/L2/L3 + 判定命令（**GHES 的特殊之处**） |
| [3](#3-路线-a自研-github-app什么时候才真的需要) | 路线 A：自研 App（**什么时候才真的需要**它） |
| [4](#4-路线-b外部-ci全攻略) | ★ **路线 B 全攻略**：4 个子方案 + 回写机制对比 + 验收 |
| [5](#5-三条-check-的逐条迁移矩阵) | 逐条对照：谁跑、怎么实现、check 名怎么办 |
| [6](#6-门禁侧required-status-checks-的契约) | 门禁契约 + 企业版怎么配 |
| [7](#7-推荐落地路线与30-分钟探针) | P0–P5 + **30 分钟探针清单**（先验证再动手） |
| [8](#8-坑清单) | 坑清单 |
| [9](#9-待拍板清单) | 需要你们确认的问题 |
| [10](#10-关联文档) | 关联文档 |

---

## 1. 事实澄清：这三条 check 到底是什么

### 1.1 ★ 四样东西必须分开看（这是误解的根源）

你在 PR 页面看到的"三条 Check"，其实是由**四个彼此独立的东西**组成的。
把它们混成一团，就会得出"check 属于 Actions、搬不了"这个结论。

| # | 东西 | 它到底是什么 | 存在哪 | 能不能搬进 GHE |
|---|---|---|---|---|
| **①** | **workflow 文件**<br>`.github/workflows/pr-checks.yml` | 一份 **YAML 配方**：写明"PR 一开就起 3 个 job、每个 job 跑什么命令"。它是**代码** | **仓库里**（跟着 git 走） | ⚠️ **取决于 GHES 上 Actions 是否可用**（见 `1.5）<br>❌ 就算可用，也**不能原样跑**：GHES **没有 GitHub 托管 runner** |
| **②** | **check run** | GitHub 服务端上的**一条记录**（`name` / `status` / `conclusion` / `head_sha` / `output`） | **GitHub 服务端**（不在仓库里） | ✅ **能**。只要有一个能调 Checks API 的身份（App / PAT / token）就能写，**GHES 上这套 API 一模一样** |
| **③** | **required status check 的 context 名**<br>（如 `YAML 语法校验`） | 门禁规则里引用的**一个字符串** | **branch protection / ruleset 配置**里 | ✅ **能**。在 GHE 上把同样的名字填进去即可 |
| **④** | **检查逻辑**<br>（ruby 解析 YAML、`bash -n`、`py_compile`） | 真正干活的**那几段命令/代码** | **在 ① 里面** | ❌ **不能原样搬**：GHES 上跑的是**你自己准备的机器**，不保证有 ruby/python3/bash |

★ **一句话对照**：

> **"check"这个结论可以搬，"生成这个结论的配方"要重写。**
> 门禁（③）永远在 GitHub 服务端执行 —— 它**从来不认识** Actions，只认识"某个名字的 check 是不是绿的"。

### 1.2 那三条 check 的事实盘点（对应 ①②③④ 四层）

来源：`.github/workflows/pr-checks.yml`（`name: PR Checks`）

| # | job | **Check 名**（= required context） | 检查什么 | 扫描范围 | 实现方式（属于 ④） |
|---|---|---|---|---|---|
| ① | `yaml-syntax` | `YAML 语法校验` | 本次改动里的 `*.yml`/`*.yaml` 能否被解析 | ★ **增量**：`git diff --name-only --diff-filter=ACMR origin/base...HEAD`，排除 `/templates/` | runner 自带 **ruby** `YAML.parse_file` |
| ② | `script-syntax` | `Shell / Python 语法校验` | 本次改动里的 `.sh` / `.py` 语法 | ★ **增量**（同上） | `bash -n` + `python3 -m py_compile` |
| ③ | `demo-manifest` | `示例清单结构自检` | demo 里的 K8s 清单有没有 `apiVersion`/`kind`/`metadata.name` | ⚠️ **常驻**：`ls demo/pr-check-actions/yaml-samples/k8s-*.yaml`（**不增量**） | runner 自带 **ruby** |

触发条件：`on: pull_request: branches: [main]` + `workflow_dispatch`
执行位置（属于 ①）：`runs-on: ubuntu-latest` → **★ 这就是 Actions 专有的那一层**
产物（属于 ②）：每个 job 结束 → GitHub 自动在 PR 上生成 **1 条 Check Run**

配套资产：[demo/pr-check-actions/README.md](../../demo/pr-check-actions/README.md)（含 branch protection 存档 JSON）
另一条执行器路线：[ci-simulation/](../ci-simulation/README.md)（Cloud Build + trigger，同一目的、不同执行器）

### 1.3 PR #16 演示了什么

[PR #16 feat(demo): 新增两份 YAML 示例](https://github.com/aibangjuxin/go/pull/16)（分支 `feat/add-yaml-samples`）只加了两个文件：

| 新增文件 | ① YAML 语法校验 | ② Shell/Python 语法校验 | ③ 示例清单结构自检 |
|---|---|---|---|
| `demo/pr-check-actions/yaml-samples/k8s-service.yaml` | ✅ 命中（增量扫到） | — 本次没改脚本 | ✅ 命中（`k8s-*.yaml` 通配，**顺带被扫**，与增量无关） |
| `demo/pr-check-actions/yaml-samples/app-config.yaml` | ✅ 命中（增量扫到） | — | — （文件名不匹配 `k8s-*.yaml`） |

→ 这个 PR 的价值：**用最小改动把"增量 vs 常驻"的差别可视化了**。
① ② 是**增量**（只看本次改动），③ 是**常驻**（每次都扫 demo 目录里全部 `k8s-*.yaml`）。
它证明的不是"校验很强"，而是"**Check 的命中逻辑是可控的、可解释的**"。

### 1.4 ★ 它们依赖 Actions 的哪一层？

把"PR → Check → 门禁"这条链路拆成四层，逐层看依赖：

| 层 | 干什么 | 依赖 Actions 吗 | GHE 上还在吗 |
|---|---|---|---|
| **L1 触发** | PR 开/更新时"谁来启动这次检查" | ✅（`pull_request` 事件） | ❌ 换 **webhook**（App / Developer Connect / Jenkins / Tekton 订阅 `pull_request`） |
| **L2 执行** | 在哪台机器上跑校验 | ✅（托管 runner + ruby/python3/bash） | ❌ 换 **自研 App 进程** / **外部 CI** / **自建 runner** |
| **L3 回写** | 结果怎么变成 PR 上的一条 Check | ✅（runner 自动调 Checks API） | ✅ **不依赖** —— Checks API / Commit Status API 在 GHES 上**一样有** |
| **L4 门禁** | "不绿不许合" | ❌ **本来就不依赖**（靠 `required_status_checks`） | ✅ **不依赖**，企业版还更强（组织级 ruleset 一次下发） |

★ **结论**：

> **只有 L1、L2 依赖 Actions；L3、L4 完全不依赖。**
> 而 L3/L4 才是"门禁"的本体 —— 所以 **Actions 被禁 = 门禁换个执行者继续存在**。
> **Actions 是可以被替换的实现细节，不是一条能力边界。**

### 1.5 ★ 逐项结论：能不能在我的 GitHub Enterprise 里用？

| 组件 | GHE（Enterprise Server / Cloud）里能不能用 | 说明 |
|---|---|---|
| **Check Run API**（`POST /repos/{o}/{r}/check-runs`） | ✅ **能** | 有 App / PAT 就能写；base URL 换 `https://<host>/api/v3` |
| **Commit Status API**（`POST .../statuses/{sha}`） | ✅ **能** | 老机制，门禁同样认 |
| **required status checks（classic branch protection）** | ✅ **能** | `Settings → Branches → Branch protection rules` |
| **required status checks（ruleset）** | ✅ 能（★ 看版本） | GHES 上 ruleset 从 **3.13** 起可用；< 3.13 就用 classic。<br>**部署前验证项**：`gh api /repos/{O}/{R}/rulesets` |
| **metadata 规则**（`commit_message_pattern` 等） | ✅ **能**（Enterprise 能力） | 但**管不了文件内容** → 替代不了这三条 check |
| **merge queue** | ✅ 能（★ 看版本） | 但 queue **必须等 CI 报告 check** → 恰恰需要我们有 check 产出者 |
| **GitHub Actions 本身** | ⚠️ **GHES 有这个功能，但有两个硬条件**：<br>① 组织策略没禁；<br>② **GHES 不提供 GitHub 托管 runner**，必须**自建 runner** | ★ 这是最关键的一条 —— 很多人以为"GHES 上 Actions 用不了"，<br>其实是"没有免费机器" |
| **`runs-on: ubuntu-latest`** | ❌ **不能直接用** | GHES 没有 GitHub 托管镜像 → 要改成 `runs-on: [self-hosted, linux, x64]` |
| **runner 自带的 ruby / python3** | ⚠️ **不保证有** | 自建 runner 的镜像里要**自己装** |
| **Cloud Build PR trigger（GHE）** | ⚠️ **能，但要打通网络** | 2nd gen `github-enterprise` connection；见 `4.1 |
| **Cloud Build manual / Pub/Sub trigger（GHE）** | ❌ **官方不支持** | 官方明确：这两种 trigger 无法通过 Cloud Build 集成构建 GHE 仓库 |
| **Argo CD Notifications `service.github` 回写** | ✅ 能（需给 token） | 可回写 commit status / check run / deployment / PR 评论 |

★ **对你那个问题的直接回答**：

> **"这个 check 是 Actions 的 check，搬不到企业版" —— 这个说法只对了一半。**
>
> - 搬不过去的：`.github/workflows/pr-checks.yml` 这个**文件**，和里面 ruby/bash/python 那**几行逻辑**；
> - 搬得过去的：**三条 check 的名字**、**门禁配置**、以及"PR 上挂一条记录、按名字判红绿"的**整个机制**。
>
> 而"在企业版上重新生成这三条同名记录"，有 4 种做法（`3、`4），
> **没有一种需要改门禁配置** —— 因为门禁只认名字。

---

## 2. 企业版现状先分清三种可能

"企业版没有这个选项"至少有三种含义，后果完全不同：

| 情况 | 含义 | 影响 | 推荐路线 |
|---|---|---|---|
| **L1 完全禁用 Actions** | 组织策略禁了 Actions，任何 workflow 跑不了 | 本文完整矩阵适用 | **B1/B3**（外部 CI）或 **A**（自研 App） |
| **L2 Actions 可用，但没有托管 runner** | ★ **GHES 的常态**：功能在，只是没有 GitHub 提供的免费机器 | **最省事**：三条 check 原样保留，只要自建一台 runner | ★ **B2（自建 runner）** ← 优先试这个 |
| **L3 禁 Actions 但有内部 CI** | 平台侧已有 Jenkins/Tekton/内部平台 | 走外部 CI，GitHub 只当"被调度的 API" | **B3** |

**判定命令**（把输出贴进 PR，别靠猜）：

```bash
# ① 组织策略里 Actions 的开关
gh api /orgs/<ORG>/actions/permissions 2>&1 | head -20
gh api /orgs/<ORG>/actions/permissions/selected-actions 2>&1 | head -20

# ② 有没有 runner（GHES 上这里一定是空的，除非你们自建过）
gh api /orgs/<ORG>/actions/runners 2>&1 | head -20
gh api /orgs/<ORG>/actions/runner-groups 2>&1 | head -20

# ③ 仓库级：Actions 权限 + 现存 workflow + 现存 check
gh api repos/<ORG>/<REPO>/actions/permissions
gh api repos/<ORG>/<REPO>/actions/workflows --jq '.workflows[].name'
gh api repos/<ORG>/<REPO>/commits/<SHA>/check-runs --jq '.check_runs[] | {name, status, conclusion}'

# ④ GHES 的 API base 要加 /api/v3
gh api --hostname ghe.corp.internal /api/v3/repos/<ORG>/<REPO>/actions/permissions
```

> ★ **部署前验证项**：企业策略字段随版本变化，以你们 Enterprise 管理后台
> 「Settings → Policies → Actions」为准。若该入口**整个不存在** → 基本可判定为 **L1**。
>
> ★ 还要分清 **Enterprise Cloud（ghe.com）** vs **Enterprise Server（自建 GHES）**：
> 后者才有多出"网络打通 / 自签 CA / App 私钥自管 / 内网不可达"四件事。

---

## 3. 路线 A：自研 GitHub App（什么时候才真的需要）

### 3.0 你的顾虑成立，但先把它放在正确的位置

> 顾虑：**"要写自己的逻辑 + 要部署，才能通过 Webhook 调用"** —— 完全正确。
>
> 但要注意：**"部署"这件事，外部 CI 方案也要做**（部署 Cloud Build connection / 部署 Jenkins），
> 区别在于：
>
> | | 路线 A（自研 App） | 路线 B（外部 CI） |
> |---|---|---|
> | 要写多少代码 | ★ **几百到上千行 Go**（webhook、验签、幂等、判定、check 写入、重扫、告警） | **0 行**（用现成 CI）或 **~100 行**（只要一个"回写器"） |
> | 要部署什么 | **自己写的服务**（镜像、配置、密钥、高可用、监控） | **现成 CI 的配置**（connection / job / pipeline） |
> | 长期维护 | 代码要一直维护、改逻辑要发版 | 升级交给 CI 厂商 |
> | 能不能干重活 | ❌ 不能跑真实构建（要装依赖就废了） | ✅ 能 |

→ **所以判断顺序是**：
> ① 先看 **L2 能不能成立**（Actions 可用 + 能自建 runner）→ 最省事，**workflow 一个字不改**；
> ② 不行 → 看 **B1/B3**（外部 CI）→ 不写逻辑，只写配置；
> ③ 两者都不行（内网 + 无 CI + 想要零外部依赖）→ 才走 **A**。

### 3.1 为什么仓库里已经有一份可运行的实现

[cr-check/](../../cr-check/README.md)（自研 GitHub App，Go 实现）**已经会**：

- 收 `pull_request` webhook、验签、幂等去重（`internal/webhook/`、`internal/queue/`）
- 判定规则（`internal/rules/`）
- **写 Check Run**（`internal/check/writer.go`）
- 定时重扫兜底（`internal/recheck/`）、审计留痕（`internal/audit/`）、Prometheus 指标（`internal/observability/`）
- ★ **已经支持 GHE**：`config/policy.yaml` 里 `github.apiURL: ""  # GitHub Enterprise: https://<host>/api/v3`，
  `internal/gh/client.go` 会切 base URL —— **这条路径当时就留着**

所以路线 A 的成本不是"从零做"，而是"**在现成骨架上加一个 lint 规则组**"。

### 3.2 路线 A 要新增的东西

| 新增 | 内容 |
|---|---|
| `internal/lint/` | 校验包：YAML / shell / Go / Python 语法 |
| `internal/scope/` | ★ **"本次改动的文件"** 的计算（增量语义的移植） |
| `internal/rules/engine.go` | 加一组规则：`R-lint-yaml` / `R-lint-shell` / `R-lint-go` / `R-lint-manifest` |
| `config/policy.yaml` | `checkName` 从 1 个变成 **4 个**（或 1 条聚合 check + 3 条细分） |

**★ 增量语义怎么在 Go 里复刻**：

Actions 版靠 `git diff origin/base...HEAD`；App 版没有仓库 checkout，两个选择：

| 方案 | 做法 | 优点 | 缺点 |
|---|---|---|---|
| **A1 走 GitHub API**（推荐） | `GET /repos/{o}/{r}/compare/{base}...{head}` 或 `GET /repos/{o}/{r}/pulls/{n}/files` | 不用 clone，秒级；GHE 通用 | ⚠️ compare API 最多返回 300 个文件，超大 PR 需分页/兜底 |
| **A2 浅 clone 后 diff** | `git clone --filter=blob:none` + `git diff --name-only base...head` | 与 Actions 版**语义完全一致** | 需要网络访问 GHE、耗时更长、有 clone 失败风险 |

> ★ 建议 **A1 为主 + A2 兜底**，并且**把"范围"写进 check 输出**（"本次检查了 N 个文件，命中 M 个"），
> 这样 PR 上能直接看懂"为什么这条 check 没报我的文件"。

**★ 校验实现选型（Go 侧，没有 ruby/python 怎么办）**：

| 原来的（Actions） | Go 里的替代 | 备注 |
|---|---|---|
| ruby `YAML.parse_file` | `gopkg.in/yaml.v3` 或 `sigs.k8s.io/yaml` | **优先 `sigs.k8s.io/yaml`**（走 k8s 的 JSON→YAML 语义，和集群里看到的一致） |
| `bash -n` | `mvdan.cc/sh/v3/syntax` | ★ **纯 Go，无需 bash**；只做语法解析，不执行 |
| `python3 -m py_compile` | ⚠️ **没有好用的纯 Go 替代** | 见下 |
| —— | `go/parser` + `go vet` | ★ **这个仓库真正的语言是 Go** → 企业版更该做 `go build`/`go vet` 级校验 |

> ⚠️ **Python 语法检查的现实解**（三选一）：
> ① **直接砍掉**：仓库以 Go 为主，python 只剩 `ip_validator.py` → 挪进外部 CI；
> ② **tree-sitter**（`github.com/tree-sitter/go-tree-sitter` + python grammar）做语法级解析 —— 能抓语法错，但**不完全等价于 CPython**；
> ③ **容器里带 python3**，用 `python3 -m py_compile` —— 最忠实，要给镜像加 python。
> ★ **建议 ① + ② 组合**。

### 3.3 路线 A 的致命坑

> **"App 没被调用" = 门禁静默消失。**
> Actions 时代有 GitHub 保证"每个 PR 都有 workflow run"；自研 App 时代没有这个保证。
> → 必须补三件事（cr-check 里已有雏形）：
> ① **心跳**：定时扫描"managed 分支上 open 且无 check 的 PR" → 补写一条失败 check（`recheck/` 就是干这个的）；
> ② **写失败要告警**：check run 写不进去 → 报警，而不是假装成功；
> ③ **幂等**：同 SHA 重跑要覆盖同名 check（用 `external_id` 做幂等键，别产生两条同名 check）。

---

## 4. ★ 路线 B：外部 CI 全攻略

### 4.0 先把两个正交的选择分开（选型时最容易乱的地方）

路线 B 其实是 **两个独立选择** 的组合：

```
┌─────────────────────────┐      ┌─────────────────────────┐
│  谁执行（跑检查）         │      │  谁回写（写 check）        │
│  · Cloud Build (Google)  │      │  ① CI 平台自带的 GitHub 集成 │
│  · 自建 runner (Actions) │ ───▶ │  ② 自研 reporter（Checks API）│
│  · Jenkins / Tekton      │      │  ③ Argo CD Notifications    │
│  · 内部平台              │      │                            │
└─────────────────────────┘      └─────────────────────────┘
```

★ **组合表**：

| | ① 平台自带回写 | ② 自研 reporter | ③ Argo CD Notifications |
|---|---|---|---|
| **Cloud Build** | ✅ 免写代码，context 形如 `gcb/<trigger>` | ⭕ 想要自定义名字/多条时用 | ❌ 不相关 |
| **自建 runner（Actions）** | ✅ Actions 自带 | — | ❌ 不相关 |
| **Jenkins / Tekton** | ✅ 插件自带 | ⭕ 想要统一命名/强日志时用 | ❌ 不相关 |
| **Argo CD** | — | — | ✅ 官方支持回写 commit status / check run |

★ **选型口诀**：
> **"平台自带回写"最省事，但 check 名字由平台决定（多一条 check 就要多一个 job/trigger）；
> "自研 reporter"最可控（能写任意多条、任意名字、能带详细日志），但要写 ~100 行 + 部署一个小服务。**

### 4.1 B1 · Cloud Build 2nd gen + GitHub Enterprise（Google 托管执行）

**适用**：GHE 能被 Google 访问（公网 / Service Directory / PSC），GHE 能出网到 `cloudbuild.googleapis.com`。

#### 4.1.1 前置条件

| 条件 | 说明 |
|---|---|
| GHE 形态 | Cloud 或 Server 都可以，Server 需额外打通网络 |
| **网络双向** | ① GHE → Google（webhook 投递方向）② Google → GHE（拉源码方向） |
| 防火墙 | 走 Service Directory 时放行 `35.199.192.0/19` |
| 自签 CA | GHE 用自签证书时准备 `ca.pem`（≤10KB，PEM），配 `--ssl-ca-file` |

#### 4.1.2 在 GHE 上建 GitHub App（★ GHE 上 App 是"你们自己"的）

在 `https://ghe.corp.internal/settings/apps/new`：

| 表单项 | 填什么 |
|---|---|
| **App Name** | 如 `gcb-builder` |
| **Webhook → Active** | ✅ 勾选 |
| **Webhook → Webhook URL** | `https://cloudbuild.googleapis.com/v2/projects/{PROJECT_NUMBER}/locations/{REGION}/connections:processWebhook` |
| **Webhook → Webhook secret** | 自己生成的随机串（**要记下来**） |
| **Repository permissions** | `Checks`: Read & write · `Contents`: Read & write · `Commit statuses`: Read & write · `Pull requests`: Read-only · `Metadata`: Read-only |
| **Subscribe to events** | Check run · Check suite · Commit comment · Pull request · Pull request review comment · Push · Repository |
| **Any account** | 勾选 |

> ⚠️ **Webhook URL 里的 REGION 必须和 connection 的 region 完全一致**，否则事件投递被丢弃 —— GHES 最常见的配置错误之一。
> ⚠️ 官方给的权限里 `Contents` 是 Read & write（比 GitHub.com 场景宽），可在 GHE 策略层收紧。

拿到 4 个东西：**App ID**、**App slug**、**私钥 PEM**、**Installation ID**。

#### 4.1.3 凭据入 Secret Manager（★ 与 GitHub.com 最大的不同：凭据生命周期归你们）

```bash
gcloud secrets create ghe-app-private-key --data-file=./ghe-app.pem
printf '%s' '<your-webhook-secret>' | gcloud secrets create ghe-webhook-secret --data-file=-

# Cloud Build 服务代理要能读这两个 secret
for S in ghe-app-private-key ghe-webhook-secret; do
  gcloud secrets add-iam-policy-binding $S \
    --member="serviceAccount:service-<PROJECT_NUMBER>@gcp-sa-cloudbuild.iam.gserviceaccount.com" \
    --role="roles/secretmanager.secretAccessor"
done
```

#### 4.1.4 建 connection / repository / trigger

```bash
gcloud services enable cloudbuild.googleapis.com developerconnect.googleapis.com \
  secretmanager.googleapis.com servicedirectory.googleapis.com   # 内网 GHE 才要最后一个

# ① connection
gcloud builds connections create github-enterprise my-ghe-conn \
  --project=<PROJECT_ID> --region=asia-northeast1 \
  --host-uri=https://ghe.corp.internal \
  --app-id=<APP_ID> --app-slug=<APP_SLUG> --app-installation-id=<INSTALLATION_ID> \
  --private-key-secret-version=projects/<PROJECT_ID>/secrets/ghe-app-private-key/versions/1 \
  --webhook-secret-secret-version=projects/<PROJECT_ID>/secrets/ghe-webhook-secret/versions/1 \
  --ssl-ca-file=ca.pem            # 自签 CA 才要

gcloud builds connections describe my-ghe-conn --region=asia-northeast1
# ★ 看 installationState，必须是 COMPLETE；不是的话 describe 会给一个"继续安装"的链接

# ② repository（--remote-uri 用 GHE 域名）
gcloud builds repositories create my-repo \
  --connection=my-ghe-conn --region=asia-northeast1 \
  --remote-uri=https://ghe.corp.internal/<ORG>/<REPO>.git

# ③ PR trigger
gcloud builds triggers create github \
  --name=pr-ci-test --region=asia-northeast1 \
  --repository=projects/<PROJECT_ID>/locations/asia-northeast1/connections/my-ghe-conn/repositories/my-repo \
  --pull-request-pattern='^main$' \
  --build-config=ci-simulation/ci-test.yaml \
  --service-account=projects/<PROJECT_ID>/serviceAccounts/gcb-ci@<PROJECT_ID>.iam.gserviceaccount.com \
  --comment-control=COMMENTS_DISABLED \
  --include-logs-with-status \
  --no-require-approval
```

> ★ **build config 直接复用仓库里已有的** `ci-simulation/ci-test.yaml`（路径相对仓库根目录）。
> 它跑的就是 `make test-helm / test-python / test-bash` —— **本地和 CI 同一套命令**。

#### 4.1.5 回写机制：Cloud Build 自己写（免写代码）

| build 状态 | 回写到 GHES 的状态 |
|---|---|
| `QUEUED` / `WORKING` | `pending`（转圈） |
| `SUCCESS` | `success`（绿勾） |
| `FAILURE` | `failure`（红叉） |
| `INTERNAL_ERROR` / `TIMEOUT` | `error` / `failure` |

三个要点：

1. **PR 触发时构建的是 GitHub 生成的"临时合并结果"**（PR head + base 最新代码）→ 正是 CI 想要的语义。
2. **回写由 Cloud Build 完成**，不需要你写代码、不需要 Actions。
3. ⚠️ **一次 build = PR 上的一条 check**。`ci-test.yaml` 里 4 个 step → **不是 4 条 check，而是 1 条**。

#### 4.1.6 ★ 三条 check 怎么办？

| 方案 | 做法 | 结果 |
|---|---|---|
| **A · 多 trigger**（最省事，推荐） | 每个测试组建一个 trigger + 一份 config：`pr-ci-yaml`、`pr-ci-script`、`pr-ci-manifest` | PR 上 **3 条独立 check**，可分别设 required；<br>⚠️ 代价：trigger 数膨胀、build-minute 翻倍、**context 名由 trigger 名决定**（要抄） |
| **B · 一个 build 内分组** | 一个 trigger，`ci-test.yaml` 里用 `waitFor`/`allowFailure` 组织 | PR 上**仍然只有 1 条 check**，看不到"哪组挂了" |
| **C · 自己写 check** | 构建脚本里用 Checks API 写 check run（token 用 Cloud Build SA 的） | ★ **完全自定义**：3 条 check、任意名字、带 summary 日志<br>代价：要处理 token、幂等、失败态上报；**放弃 Cloud Build 自动回写**（变成"自己回写 + Cloud Build 只跑"） |

> ★ **怎么选**：
> - 想要**门禁体验和现在一模一样**（三条同名 check）→ **方案 C**，回写器见 `4.5；
> - 想**最省事** → **方案 A**，接受 context 名由 trigger 决定。

#### 4.1.7 验证三板斧 + 抄 context 名

```bash
# ① trigger 对不对
gcloud builds triggers describe pr-ci-test --region=asia-northeast1

# ② 有没有 build 被创建
gcloud builds list --region=asia-northeast1 --limit=5

# ③ build 日志
gcloud builds log <BUILD_ID> --region=asia-northeast1

# ④ ★ PR 上的 check 到底叫什么（context 名必须一字不差）
gh pr checks <PR_NUMBER>
gh api repos/<ORG>/<REPO>/commits/<SHA>/check-runs --jq '.check_runs[] | {name, status, conclusion}'
gh api repos/<ORG>/<REPO>/commits/<SHA>/status --jq '.statuses[] | {context, state}'
```

#### 4.1.8 GHES 专属坑（速查表）

| 现象 | 根因 | 处理 |
|---|---|---|
| **push 不触发，但代码能拉到** | webhook 方向（GHE → Google）不通 | 放行 GHE 出网到 `cloudbuild.googleapis.com`；或用中转 |
| **触发了但拉不到源码（超时）** | 拉源码方向（Google → GHE）不通 | Service Directory / PSC / 公网暴露；放行 `35.199.192.0/19` |
| `installationState` 不是 `COMPLETE` | App 没装完 / SAML 没授权 | 点 describe 给的链接补完 |
| `x509: certificate signed by unknown authority` | 自签 CA | `--ssl-ca-file=ca.pem`（≤10KB, PEM） |
| `x509: certificate is valid for X, not Y` | `--host-uri` 与证书 SAN 不匹配 | 用证书里的域名做 host-uri |
| webhook 收不到事件 | webhook URL 的 REGION 与 connection region 不一致 | 两者必须一致 |
| webhook 401/403 | webhook secret 不一致 | GHE 上 App 的 secret 与 Secret Manager 的版本要对上 |
| 拉源码 permission denied（App 已装） | 只装了 org 没勾具体 repo | 重装 App 时**选中 repo** |
| App 安装报 SAML 错 | GHE 启用了 SAML SSO | 用 org owner 域账号装，或在后台配 SAML group 权限 |
| 私钥相关报错 | 用了 SSH key 而非 RSA PEM | 要 **PEM 格式 RSA 私钥**（`-----BEGIN RSA PRIVATE KEY-----`） |
| **manual / Pub-Sub trigger 对 GHE 无效** | ★ **官方限制** | 改用 push / PR trigger |
| 建 repository 报找不到 | region 不一致 | connection / repository / trigger **三者同区** |
| SA 报 secretmanager 权限错 | 服务代理没读私钥权限 | 给两个 secret 加 `roles/secretmanager.secretAccessor` |
| **PR 上没有 Cloud Build 的 check** | ⚠️ 可能是 **Cloud Build 只回了 commit status**，而你只看 check-runs | ★ 用 `gh api .../status` 一并查（两种机制 PR 页面统一渲染，但 API 是两套） |

### 4.2 B2 · 自建 runner（★ 如果 GHES 上 Actions 其实可用，这是最省事的一条）

**为什么这条值得先试**：**workflow 文件一个字不改**，三条 check 的名字、实现方式、增量逻辑全部原样保留，
只需要**准备一台能跑 job 的机器**。

#### 4.2.1 前提

- GHES 上 Actions **未被组织策略禁用**（`2 的探测命令）
- 你有一台（或一组）能跑的机器：VM / 容器 / K8s Pod
- ⚠️ **GHES 没有 GitHub 托管 runner** → 这台机器是**你们自己负责**的

#### 4.2.2 三步接上

```bash
# ① GHE 上拿注册 token
#    Settings → Actions → Runners → New self-hosted runner → 复制 token

# ② 下载并启动 runner agent（在你们自己的机器上）
mkdir -p /opt/ghe-runner && cd /opt/ghe-runner
# 从 https://<ghe-host>/actions/runner 下载对应版本
tar -xzf actions-runner-linux-x64-*.tar.gz
./config.sh --url https://<ghe-host>/<ORG>/<REPO> --token <TOKEN> --labels ghe-linux,x64 --unattended
./run.sh
```

#### 4.2.3 workflow 只改一行

```yaml
# .github/workflows/pr-checks.yml
jobs:
  yaml-syntax:
-   runs-on: ubuntu-latest
+   runs-on: [self-hosted, linux, x64]
```

> ★ 其余（触发条件、增量 diff、ruby/bash/python 命令）**全部不动**。
> ⚠️ 但 **runner 机器上要自己装工具**：`ruby`、`python3`（含 `python3 -m py_compile` 需要的 stdlib）、`bash`、`git`。
> → **建议**：用固定镜像（如 `ruby:3.3` / `python:3.11`）当 runner 基础镜像，工具链版本才不会漂。

#### 4.2.4 必须一起做的 3 件安全/运维的事

| 事项 | 为什么 |
|---|---|
| **用 ephemeral runner**（每个 job 起一个新容器/job 完销毁） | PR 代码是**不可信输入**，跑在常驻机器上等于开门；CI 文档里"PR 是不可信输入"讲的正是这件事 |
| **限制并发 + 磁盘回收** | 自建 runner 常年跑 → 磁盘满 → job 静默失败 |
| **runner 要能被 GitHub 访问** | GHES → runner 的连接方向（出网） |

#### 4.2.5 这条路的评价

| 优点 | 缺点 |
|---|---|
| ✅ **零代码重写**，三条 check 原样保留 | ⚠️ 要自己运维 runner（机器、镜像、工具链、磁盘） |
| ✅ 门禁配置零改动 | ⚠️ 要改 workflow 里的 `runs-on`（一行） |
| ✅ 增量语义、失败形态全部与现在一致 | ⚠️ GHES 上要装 `ruby`/`python3`（GitHub 托管 runner 白送的东西） |
| ✅ 天然并行（一个 job 一个 runner） | ⚠️ 机器成本 |

### 4.3 B3 · 内网 CI（Jenkins / Tekton / 内部平台）

**适用**：GHE 完全内网、Cloud Build 打不通；但公司已有 CI 平台。

#### 4.3.1 通用形态（三个组件）

```
① 触发：GHE 上装一个轻量 GitHub App（或用 CI 平台自带的 GitHub 插件）订阅 pull_request
② 执行：CI 平台跑你的 job（本地/CI 同一套命令，make test）
③ 回写：CI 平台的 GitHub 集成写 commit status；或自研 reporter 写 check run
```

#### 4.3.2 Jenkins

- 装 **GitHub plugin**（回写 commit status，`context` 默认 = job 名）+ **GitHub Branch Source**（自带 webhook + PR 触发）
- GHE 需要配：Server URL = `https://<ghe-host>/api/v3`、Credentials = PAT（`repo`/`status` 权限）、勾"Use credentials"、webhook 勾选 PR events
- 回写出来的是 **commit status**，门禁里填 **`context`**（= job 名）
- ★ 名字可控性：**中等**（job 名可改，但改了就断引用）

#### 4.3.3 Tekton

- **Tekton Triggers**：`GitHub` interceptor 收 `pull_request` 事件 → 启动 Pipeline
- 回写：`github-add-status` 之类的 task，或自研 reporter
- ★ GHE 支持：Tekton 的 GitHub interceptor 需要配 `githubSecret` + `githubOwner`/`githubRepo`，**base URL 要指到 GHES**（这一步最容易配错）

#### 4.3.4 ★ 自研 reporter（~100 行 Go，能写任意名字的三条 check）

**这是"最小自研"**：不写 webhook 逻辑、不写判定逻辑，只做"**看到 CI 的结果 → 写一条 check**"。

复用现成资产：[cr-check/](../../cr-check/README.md) 里
`internal/gh/client.go`（**已经支持切 GHE base URL**）+ `internal/check/writer.go`（**已经封装了写 check run**）：

```go
// 骨架：外部 CI 的结果 → PR 上的一条 check
ref := check.Ref{Owner: owner, Repo: repo, SHA: headSHA, Name: "YAML 语法校验"}
w.MarkInProgress(ctx, ref, "CI 运行中…")
w.Complete(ctx, ref, outcome)   // outcome.Conclusion() → success / failure
```

**幂等要点**：
- 用 `external_id`（例如 `lint-yaml:<sha>`）做幂等键 → 同 SHA 重跑**覆盖**同名 check，不产生第二条
- 先写 `in_progress` 再写终态 → 旧结论不会冒充新结论
- 写失败要**重试 + 告警**（否则就是"check 没上报"→ PR 永远卡住）

★ **这个 reporter 同时也是 B1 方案 C 的实现方式** —— 也就是说：
**一旦有了它，B1/B2/B3 都能统一成"3 条同名 check"，门禁配置永远不用动。**

### 4.4 B4 · Argo CD Notifications `service.github`（如果已经有 Argo CD）

| 能写什么 | API |
|---|---|
| commit status | `POST /repos/{o}/{r}/statuses/{sha}` |
| check run | `POST /repos/{o}/{r}/check-runs` |
| deployment | `POST /repos/{o}/{r}/deployments` |
| PR 评论 | `POST /repos/{o}/{r}/issues/{n}/comments` |

★ 适合承载"**渲染成功 / 同步成功 / 健康**"这类检查；
⚠️ **它是 Argo CD 的副作用驱动**，拿不到"本次 PR 改了哪些文件"这种语义 → **不适合替代 ①② 那种增量语法校验**。

### 4.5 回写机制对比表（选型看这张）

| | Cloud Build | Jenkins plugin | Tekton | **自研 reporter** | Argo CD Notifications |
|---|---|---|---|---|---|
| 产出什么 | **commit status** | commit status | commit status / check run | ★ **check run** | commit status / check run / deployment |
| 名字字段 | `context` | `context` | 自定义 | ★ `name`（完全可控） | 模板定义 |
| 一条 CI 产出几条 | 1 条（1 个 trigger） | 1 条（1 个 job） | 可 | ★ **任意多条** | 可 |
| 名字能否保持"YAML 语法校验" | ⚠️ 由 trigger 名决定 | ⚠️ 由 job 名决定 | ✅ | ✅ | ✅ |
| 能带详细日志/摘要 | 弱 | 弱 | 弱 | ★ **强**（`output.summary`） | 中 |
| 幂等/重试 | 平台托管 | 平台托管 | 需自己做 | ★ 自己做（`external_id`） | 平台托管 |
| 部署成本 | 建 connection + App | 装插件 | 建 Triggers | ★ **一个小服务** | 已 Argo CD 则为零 |

### 4.6 ★ 路线 B 下，这三条 check 具体怎么落

| context 名 | B2（自建 runner） | B1（Cloud Build） | B3（内网 CI + reporter） |
|---|---|---|---|
| `YAML 语法校验` | ✅ **原样**（workflow 不改） | 方案 A：多 trigger（名字变）<br>方案 C：reporter 写同名 | ✅ reporter 写同名 |
| `Shell / Python 语法校验` | ✅ **原样** | 同上 | ✅ 同上 |
| `示例清单结构自检` | ✅ **原样** | 同上 | ✅ 同上 |
| 增量语义（只看本次改动） | ✅ 原生 | ❌ build 跑的是**合并结果**（要自己算 diff） | ⚠️ 需自己实现（compare API 或 clone diff） |
| 工具链 | ⚠️ runner 镜像要装 ruby/python | ✅ build 镜像自带（`python:3.11`） | 视平台 |
| 门禁配置 | ✅ **零改动** | ⚠️ 方案 A 要改 context 名；方案 C 零改动 | ✅ 零改动 |

> ★ 注意 **B1 的一个语义差异**：Cloud Build 的 PR trigger 构建的是 **PR head + base 的临时合并结果**，
> 所以它**天然包含 base 分支的代码** → "只查本次改动"这件事要么在 build 脚本里自己算 diff，
> 要么干脆**改成全量检查**（Cloud Build 场景下全量更自然，因为环境本来就是干净的全量检出）。

---

## 5. 三条 check 的逐条迁移矩阵

| 原 check（Actions） | B2 自建 runner | B1 Cloud Build | B3 + reporter | A 自研 App | 门禁配置 |
|---|---|---|---|---|---|
| ① `YAML 语法校验`（增量） | ✅ 原样 | ⚠️ 改名 or reporter | ✅ reporter | ✅ Go 重写 | ✅ 零改动 |
| ② `Shell / Python 语法校验`（增量） | ✅ 原样 | 同上 | ✅ 同上 | ✅ Go 重写（python 见 `3.2） | ✅ 零改动 |
| ③ `示例清单结构自检`（常驻） | ✅ 原样 | 同上 | ✅ 同上 | ✅ Go 重写 | ✅ 零改动 |
| （新）`go build / go vet` | ✅ 加一个 job | ✅ 加一个 trigger | ✅ | ✅ | ❌ 需加进 required |
| （新）`helm lint / template` | ⚠️ 要装 helm | ✅ **天然适合**（`ci-simulation`） | ✅ | ❌ 不适合 | ❌ 需加进 required |
| （新）CR 号 / 分支命名 | — | — | — | — | ✅ **Ruleset 服务端拦**（不产生 check） |

---

## 6. 门禁侧：required status checks 的契约

### 6.1 唯一的耦合点：**check 名（context）**

```
┌──────────────┐   产出 check run    ┌────────────────────┐   读 context 名   ┌──────────────────┐
│  执行器       │ ─────────────────▶ │  GitHub Checks API │ ───────────────▶ │ branch protection │
│ (App / CI)    │                    └────────────────────┘                   │ / ruleset        │
└──────────────┘                                                            └──────────────────┘
```

★ **只要两边名字逐字符一致（含斜杠、大小写、空格），执行器换成谁都行。**
这条契约就是迁移的**全部成本所在**。

### 6.2 企业版上怎么配

| 方式 | 位置 | 说明 |
|---|---|---|
| **组织级 ruleset**（★ 推荐） | `Settings → Rules → Rulesets`（组织级） | 一次下发全组织；仓库级只能**加严**不能放松；★ GHES 需 3.13+ |
| **仓库级 ruleset** | 仓库 `Settings → Rules` | 单仓库试点用 |
| **Classic branch protection** | `Settings → Branches` | 最老的一套，GHES 兼容性最好（**GHES 老版本走这个**） |

```bash
# 看企业版 main 上现在要求哪些 check
gh api repos/<ORG>/<REPO>/branches/main/protection --jq '.required_status_checks'
# GHES：加 base
gh api --hostname ghe.corp.internal /api/v3/repos/<ORG>/<REPO>/branches/main/protection --jq '.required_status_checks'

# 加三条（名字必须逐字符一致）
gh api -X PUT repos/<ORG>/<REPO>/branches/main/protection \
  -F 'required_status_checks[strict]=true' \
  -F 'required_status_checks[contexts][]=YAML 语法校验' \
  -F 'required_status_checks[contexts][]=Shell / Python 语法校验' \
  -F 'required_status_checks[contexts][]=示例清单结构自检' \
  -F 'enforce_admins=true' \
  -F 'required_pull_request_reviews[required_approving_review_count]=1'
```

### 6.3 企业版比个人版强在哪（对这条链路而言）

| 能力 | 个人版 | 企业版 |
|---|---|---|
| `required_status_checks` | ✅ | ✅（**同一套**） |
| 组织级 ruleset（一次下发全组织） | ❌ | ✅ |
| `required_workflows`（组织级强制 CI） | ❌ | ⚠️ **本质是 Actions**，禁了就没 |
| merge queue（需要 CI 报告 check） | ❌ | ✅（但**我们得自己有 check 产出者**） |
| `commit_message_pattern` 等元数据规则 | ❌ | ✅（**帮不了内容门禁**） |
| 治理面 | 一个仓库一道门 | ★ **整个组织一道门**（配错全组织一起卡） |

★ **迁移的正确姿势不是"照搬个人版"，
而是"把执行器换掉 + 把门禁升到组织级 + 用元数据规则接管格式类"**。

---

## 7. 推荐落地路线与 30 分钟探针

### 7.1 ★ 先做 4 个探针（半天内出结论，别先写代码）

| 探针 | 做什么 | 决定什么 |
|---|---|---|
| **A · Actions 可用性** | `gh api /orgs/<ORG>/actions/permissions` + `/actions/runners` | L1 还是 L2 → 决定走 B2 还是 B1/B3 |
| **B · Checks API 可写性** | 在 GHE 上装一个最小 App（或用 PAT）→ `POST /api/v3/repos/{O}/{R}/check-runs` 写一条空 check | ★ **"GHE 上能不能写 check"是一切的前提**，先证明它 |
| **C · Cloud Build 连通性** | `gcloud builds connections create github-enterprise ...` → 看 `installationState` | B1 是否可行 |
| **D · 内网 CI 可达性** | 内部 CI 能不能被 GHE 的 webhook 打到、能不能 pull 到 GHE 仓库 | B3 是否可行 |

> ★ **探针 B 的最小命令**（有 PAT 就能试，不需要写代码）：
> ```bash
> curl -sS -X POST \
>   -H "Authorization: Bearer $GH_TOKEN" \
>   -H "Accept: application/vnd.github+json" \
>   https://<ghe-host>/api/v3/repos/<ORG>/<REPO>/check-runs \
>   -d '{"name":"probe/can-i-write","head_sha":"<真实 SHA>","status":"completed","conclusion":"success"}'
> ```
> 能返回 201 → **GHE 上的 check 生产链路通了**，剩下只是"谁来写"。

### 7.2 阶段路线（P0–P5）

| 阶段 | 目标 | 动作 | 完成判据 |
|---|---|---|---|
| **P0 摸底** | 知道到底缺什么 | 跑 `2 探测 + `7.1 四个探针；列全仓 `.github/workflows/*` | 一张"谁在依赖它"的清单 |
| **P1 契约先行** | 把 check 名固化 | 无论走哪条路，都先把三个 context 名写进一处配置 + 契约校验 | 改名字会 CI 报错 |
| **P2 换执行者** | 让 PR 上出现三条 check | 按探针结果选 B2 / B1 / B3 / A | PR 上三条 check 出现，且能故意跑红 |
| **P3 门禁下发** | 变成硬门禁 | 企业版用组织级 ruleset（先 `disabled` → 单仓库 → 全量） | 不绿真的合不进去 |
| **P4 兜底** | 集群侧最后一道 | Argo CD 渲染失败即同步失败；Gatekeeper 管镜像 tag/标签/配额 | 故意提交违规资源被拒 |
| **P5 清账** | 确认没有残留依赖 | grep 全仓 workflow 引用；检查 ruleset 里没有指向已删 workflow 的 required check | **每个 required context 都仍有产出者** |

> ⚠️ **P5 最容易漏**：删掉 workflow / 关掉 Actions 之后，如果 ruleset 还在要求它的 check 名，
> 那个 check **永远不会出现** → 所有 PR 永久卡住，或反过来规则被静默丢弃。

### 7.3 最小可行方案（按探针结果三选一）

```
探针 A = L2（Actions 可用，只是没 runner）
  → B2：准备一台 runner 机器（装 ruby/python3/bash/git）
  → workflow 只改 runs-on: [self-hosted, linux, x64]
  → 三条 check 原样保留，门禁零改动            ★ 最省事

探针 A = L1 且 探针 C = 通（Cloud Build 能连 GHE）
  → B1：建 App → connection → repository → trigger
  → 方案 A（3 个 trigger，context 名变）或 方案 C（reporter 写同名）
  → 复用 ci-simulation/ci-test.yaml             ★ 已有资产直接用

探针 A = L1 且 探针 C = 不通（内网）
  → B3：内网 CI（Jenkins/Tekton）+ 自研 reporter（复用 cr-check 的 writer/client）
  → reporter 写三条同名 check，门禁零改动        ★ 唯一可能要写代码的 ~100 行
```

---

## 8. 坑清单

| # | 坑 | 后果 | 规避 |
|---|---|---|---|
| 1 | 以为"禁 Actions = 没有 CI" | 门禁被悄悄删掉 | 跑探测命令（`2/`7.1） |
| 2 | 以为 GHES 上 Actions 完全不可用 | 白折腾外部 CI | ★ **GHES 有 Actions，只是没有托管 runner** → 先试 B2 |
| 3 | 以为"这三条 check 属于 Actions，搬不了" | 把"名字/门禁/机制"一起扔掉 | 分清 `1.1 的四样东西 |
| 4 | 以为企业版原生规则能替代这三条 check | 格式管了、**内容没人管** | 分清"元数据门禁 vs 内容门禁" |
| 5 | **App/CI 没被调用时 silently pass** | 门禁形同虚设 | 心跳 + 补写失败 check + 写失败告警 |
| 6 | 迁移后 **check 名改了** | ruleset 引用失效（静默放行）或永久卡死 | context 名写进配置 + **契约校验** + 改名前先改 ruleset |
| 7 | **required check 永不上报**（`paths` 过滤、scope 算失败、trigger 没建） | PR 永远 `BLOCKED`，看不出卡在哪 | 每个 PR 都必须上报；失败要写失败 check 而不是跳过 |
| 8 | **"没跑" 和 "跑红了" 在 PR 上长得一样** | 排查困难 | `gh api .../status` + `.../check-runs` **两个都查**；输出区分 `not_run`/`failed` |
| 9 | 换执行器后**工具链缺失**（ruby/python3/helm） | `command not found` | 每个执行器显式声明工具链；Go 版不依赖预装 |
| 10 | Helm 模板（`{{ .Values.x }}`）当普通 YAML 解析 | 永远红 | 排除 `/templates/`；用 `helm lint` 兜底 |
| 11 | **全量扫描**代替增量扫描 | 历史遗留错误让 check 永远红 → 大家开始无视 | 坚持增量；历史问题单独开 PR 修 |
| 12 | 换了执行器但**没做幂等** | 同 SHA 出现两条同名 check，required 判定错乱 | `external_id` 做幂等键；同名覆盖 |
| 13 | GHES 内网不可达 / 自签 CA | build 拉不到源码、webhook 投递失败 | Service Directory / PSC / 公网暴露；`--ssl-ca-file` |
| 14 | GHE App 私钥 / webhook secret 不轮换 | 间歇性失败、难排查 | 存 Secret Manager + 定期轮换 |
| 15 | **自建 runner 跑不可信 PR 代码** | 攻击者拿到 runner 机器 | ephemeral runner + 最小权限 + 隔离网络 |
| 16 | 忘了 **merge queue** 需要 check 产出者 | 队列把没校验的改动合进去 | 先有 check 产出者再开 queue |
| 17 | 组织级 ruleset 配错 | **全组织一起卡死**，只有 org owner 能改 | 先 `enforcement=disabled` → 单仓库联调 → 再全量下发；提前分配熔断权限 |
| 18 | PR 页面的 "Re-run jobs" 按钮对非 Actions 的 CI 无效 | 不知道去哪重跑 | Cloud Build：控制台 History → Retry；Jenkins：Build → Rebuild |

---

## 9. 待拍板清单

| # | 问题 | 为什么关键 |
|---|---|---|
| Q1 | 企业版是 **Enterprise Cloud** 还是 **Enterprise Server（自建）**？ | 决定走不走 Cloud Build 2nd gen + GHE connection |
| Q2 | "没有这个选项"具体指哪个界面？（管理后台没有 Actions 策略入口？还是 PR 页没有 Actions 标签？） | 判定 L1 / L2 / L3 |
| Q3 | 组织策略里，**Actions 是禁了还是只是没 runner**？ | L2 的话 **B2 最省事**（零重写） |
| Q4 | 有**没有内网 CI**（Jenkins/Tekton/内部平台）？ | 决定 B3 的可行性 |
| Q5 | GHE 实例**能不能被 Google 访问**（公网/PSC/Service Directory）？ | 决定 B1 是否可行 |
| Q6 | 你们愿意**自建 runner 机器**吗（含工具链、磁盘、运维）？ | 决定 B2 是否可持续 |
| Q7 | 真实业务仓库里**要检查哪些东西**？（这三条是 demo 资产） | 决定规则清单与 context 名清单 |
| Q8 | 要不要**保持三条 check 名**，还是合并成一条？ | 影响迁移成本（保持 = 门禁零改动） |

---

## 10. 关联文档

| 主题 | 文档 |
|---|---|
| ★ 当前这套 PR Checks 的完整说明（含门禁存档 JSON） | [demo/pr-check-actions/README.md](../../demo/pr-check-actions/README.md) |
| ★ 另一条执行器路线（Cloud Build + trigger，本地/CI 同一套命令） | [ci-simulation/README.md](../ci-simulation/README.md) |
| ★ 自研 GitHub App（**reporter 可直接复用**：写 check run / 幂等 / GHE base URL） | [cr-check/README.md](../../cr-check/README.md) |
| ★ Cloud Build 触发 GitHub（含 **GHES Server 专章 `7**） | [how-to-github-trigger-cloud-build.md](file:///Users/lex/git/knowledge/gcp/gcp-cloud-build/how-to-github-trigger-cloud-build.md) |
| ★ Cloud Build 做 PR 门禁（**`4 Check 回写机制** / `4.4 多 check 的三种做法） | [how-to-pr-checks-with-cloud-build.md](file:///Users/lex/git/knowledge/gcp/gcp-cloud-build/how-to-pr-checks-with-cloud-build.md) |
| ★ 无 GitHub Actions 的替代方案矩阵 | [19-no-actions-alternative-matrix.md](file:///Users/lex/git/knowledge/gcp/ucp/argocd-topics/gh-enterprise/19-no-actions-alternative-matrix.md) |
| ★ 企业版能力矩阵（哪些 rule type 要什么条件） | [00-enterprise-capabilities.md](file:///Users/lex/git/knowledge/gcp/ucp/argocd-topics/examples/rulesets-enterprise/00-enterprise-capabilities.md) |
| ★ 个人版 ↔ 企业版差异对照 | [personal-vs-enterprise.md](file:///Users/lex/git/knowledge/gcp/ucp/argocd-topics/examples/rulesets-enterprise/personal-vs-enterprise.md) |
| Argo CD × GitHub Enterprise 专题总览 | [gh-enterprise/README.md](file:///Users/lex/git/knowledge/gcp/ucp/argocd-topics/gh-enterprise/README.md) |

---

## 附：两句话记住整件事

> **① "check"不是 Actions 的东西，是 GitHub 服务端的一条记录。**
> 搬得走的是**名字 + 门禁 + 机制**；搬不走的是**workflow 文件 + 那几行 ruby/bash/python**。
>
> **② 换执行器只有两个选择："谁来跑"和"谁来写"。**
> 最省事 = 自建 runner（workflow 一个字不改）；
> 想复用现成资产 = Cloud Build / 内网 CI（复用 `ci-simulation` 的 Makefile）；
> 想完全掌控三条 check 名 = 加一个 ~100 行的 reporter（复用 `cr-check` 的 writer + GHE base URL）。
