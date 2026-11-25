# GHE × Cloud Build · 把「PR → Check → 硬门禁」这条链路真正打通

> **副标题**：在 **GitHub Enterprise（Actions 全禁）** + **GHE↔GCP 已经打通**
> 的前提下，剩下的工作到底有哪些、每一步怎么验、出了问题怎么查。
>
> **一句话结论**
> ★ **你已经打通了"触发"这一段，剩下的四段是**：
> **① 跑什么**（CI 配置）→ **② 回写成什么名字**（check/context）→ **③ 谁把它变成硬门禁**（required status checks）
> → **④ 没跑起来时怎么收场**（兜底）。
> 其中 **②③ 是最容易踩坑的**：一次 Cloud Build build = **一条** check，
> 而你现在要的是**三条同名 check**；context 名**一字不差**才对得上门禁。
>
> ⚠️ **本文档只讲"还差什么"**，不重复已有原理：
> 原理见 [ci-simulation-enterprise.md](ci-simulation-enterprise.md)（为什么"换执行器"就行）。

---

## 术语表 · 读本文档前先统一词

> 下面这些词在本文档里反复出现，先统一一次，后面就不重复解释了。

| 术语 | 是什么 | 在本项目里的角色 |
|---|---|---|
| **GitHub Enterprise（GHE）** | GitHub 的**企业版付费计划**（不是某个功能） | 你们现在这套 |
| **GHES**（Enterprise Server） | GHE 的**自建形态**，装在你们内网 | 大概率是你们这套 |
| **Actions** | GitHub 原生 CI | **已全禁**；它只是"执行器" |
| **check run** | GitHub 服务端的一条记录（name/status/conclusion/head_sha/output） | PR Checks 标签下的一条 |
| **commit status** | 旧机制（context/state） | Cloud Build 常常写的是这个 |
| **context** | 门禁引用的那个**字符串** | ★ **唯一耦合点** |
| **required status checks** | "必须为绿才能合"的名单 | 门禁本体（**服务端**执行） |
| **branch protection（classic）** | 老的分支保护设置 | 试点用；GHES 全版本支持 |
| **ruleset** | 新一代门禁规则 | 生产用；组织级一次下发；GHES 需 3.13+ |
| **metadata 规则** | Enterprise 独有的格式类规则 | 管格式，**管不了内容** |
| **merge queue** | 合并队列 | 暂不启用；**需要有 CI 报告的 check** |
| **GitHub App / installation token** | 让外部服务以"机器人身份"调 API | 回写 check、未来的回写器 |
| **Developer Connect connection** | GCP 侧的 GitHub 连接器 | 你们**已经打通**的那一段 |
| **repository / trigger** | Cloud Build 侧的仓库映射 / 触发规则 | 一个 trigger = 一次 build = **一条** check |
| **build config** | 仓库里声明"跑哪些 step"的文件 | 跑什么；PR 分支上的**可被篡改** |
| **substitution** | 触发时注入的环境变量 | 增量清单的来源（W5） |
| **ephemeral runner** | 跑完即销毁的 runner | 假如走自建 runner 路线 |

### ★ GHE 到底是什么：两种形态

| | **Enterprise Cloud** | **Enterprise Server（GHES）** |
|---|---|---|
| 域名 | `ghe.com` | `ghe.corp.internal`（自建） |
| 部署 | GitHub 托管 | ★ **你们自己装，通常在内网** |
| 登录 | GitHub 账号 + SAML SSO | SAML SSO（域账号） |
| 对接 GCP | 出网容易 | ★ **网络要双向打通**（Google ↔ 内网） |
| API base | `https://api.github.com` | `https://<host>/api/v3` |
| App 安装 | GitHub 应用市场 | ★ **装在你们实例上**，私钥自管 |
| 托管 runner | ✅ 有 | ★ **没有** → Actions 必须自建 runner |
| ruleset | ✅ | 需 3.13+（★ 部署前验证项） |
| merge queue | ✅ | 看版本 |

### ★ Enterprise 这个计划多给了什么

| 能力 | 说明 | 对我们有用吗 |
|---|---|---|
| **组织级 ruleset** | 一次下发全组织；仓库级只能**加严**不能放松 | ✅ 治理面（生产阶段用） |
| `commit_message_pattern` | commit message 格式（CR 号前缀）**push 那一刻就判** | ⚠️ 管格式，**管不了内容** |
| `branch_name_pattern` / `tag_name_pattern` | 分支/tag 命名 | 同上 |
| **push ruleset + `block_credential_changes`** | 密钥/大文件/凭据**进仓库前**就挡 | ✅ **强烈建议做** |
| **merge queue** | 批量合并前排队跑 CI | ⚠️ 但**必须有 CI 报告的 check** → 正好依赖我们产出的 check |
| `required_workflows` | 组织级强制跑某条 workflow | ❌ **本质就是 Actions**，禁了就没 |
| `required_signatures` | 生产分支必须签名提交 | 视合规要求 |
| SAML SSO / 审计日志 / 自定义组织角色 | 治理与合规 | 影响 App 安装流程（SAML 授权那一步） |

### ★ 关于 GHE 的三个常见误解

1. **GHE ≠ "没有 Actions"。**
   GHES 本身**有** Actions；只是 ① 组织策略可以禁它 ② **GHES 不提供托管 runner** →
   就算开着也得自己准备机器（`runs-on: ubuntu-latest` 用不了）。
2. **GHE ≠ "功能更多所以门禁更强"。**
   它多出来的几乎全是"**元数据/格式**"类规则；
   而这三条 check（YAML/shell/python 语法 + 清单结构）是"**内容类**" →
   ★ **GHE 没有任何一条原生规则能替代它们**，所以才需要自己产出 check。
3. **GHE 的"必过 check"与 GitHub.com 完全同一套机制**（required status checks + Checks API）。
   差异不在机制，在**下发面**（组织级 vs 逐仓库）和**失败代价**（配错 = 全组织一起卡）。

> ★ **一句话**：
> **GHE = "门禁判定发生在 GitHub 服务端"这件事不变，但"谁来跑检查"必须由你们自己提供
> → 换执行器，不换门禁。**

## 目录

| 章节 | 内容 |
|---|---|
| [术语表](#术语表--读本文档前先统一词) | ★ **GHE 是什么** + 全书术语表 + 三个常见误解 |
| [0](#0-当前起点与全景) | 起点 + 全景图 + **两种架构**（官方触发器 vs 薄层自研） |
| [1](#1-前提对齐把已经打通翻译成-6-个可验证事实) | ★ **先确认你已经打通的到底是什么**（6 条 + 命令） |
| [2](#2-端到端全景与-6-个-gate) | 全景图 + 6 个 Gate（每个阶段的通过标准） |
| [3](#3-工作分解w1w9) | ★ **W1–W9 工作分解**（做什么 / 怎么做 / 验收标准） |
| [4](#4-ci-配置资产三个-build-config-样例) | 可直接用的三个 build config + Makefile target + changed-files |
| [5](#5-门禁下发) | required status checks 怎么配（context 名契约） |
| [6](#6-不可信输入与安全) | fork PR / secrets / SA 最小权限 |
| [7](#7-观测与运维) | 重跑、告警、漂移巡检 |
| [8](#8-端到端验收清单) | ★ 验收 checklist（可逐条打勾） |
| [9](#9-排错手册) | 症状 → 根因 → 处理 |
| [10](#10-风险与回滚) | 风险登记 + 回滚路径 |
| [11](#11-工作量与排期建议) | 分期建议 |
| [12](#12-待确认清单) | 需要你们拍板的问题 |
| [13](#13-关联文档) | 关联文档 |

---

## 0. 当前起点与全景

### 0.1 你已经做到的（按你的描述）

| # | 已完成 | 状态 |
|---|---|---|
| 1 | GHE 上建了 GitHub App，并把 **Webhook URL 指向 Cloud Build** 的 `connections:processWebhook` | ✅ 你说的"webhook 已配好" |
| 2 | GCP 侧建了 **Developer Connect connection**（type = `github-enterprise`）、**repository**、**trigger** | ⚠️ **需确认**（见 §1） |
| 3 | 拉源码通道打通（Google → GHE） | ⚠️ **需确认** |
| 4 | webhook 投递方向打通（GHE → Google） | ⚠️ **需确认** |

→ 也就是说：**"PR 事件 → Cloud Build"这段大概率已经通了。**
剩下的是：**build 跑什么 → 结果叫什么名字 → 怎么变成硬门禁 → 没跑起来怎么办**。

### 0.2 全景图（把"要做的活"标在链路上）

```
 ┌──────────────── 已经在 GHE 上 ────────────────┐        ┌──────────── GCP ────────────┐
 │                                                │        │                              │
 │  ① PR 打开/更新                                │  ───▶  │  ② Cloud Build trigger 命中  │
 │      │                                         │        │      │                       │
 │      │ (已打通：webhook → Cloud Build)          │        │      ▼                       │
 │      │                                         │        │  ③ 跑 build（pr-ci-*.yaml） │
 │      │                                         │        │      │  ★ W1：跑什么              │
 │      │                                         │        │      ▼                       │
 │      │                                         │        │  ④ build 结果               │
 │      │                                         │  ◀───  │      │  ★ W2：回写成什么名字       │
 │      ▼                                         │        └──────────────────────────────┘
 │  ⑤ PR 页面出现 Check（绿/红/转圈）             │
 │      │                                         │
 │      ▼                                         │
 │  ⑥ required status checks 判定（服务端执行）    │
 │      ★ W3：怎么变成硬门禁                       │
 │      │                                         │
 │      ▼                                         │
 │  ⑦ 不绿就合不进去                               │
 │      ★ W4：没跑起来时怎么收场（兜底）             │
 └────────────────────────────────────────────────┘
```

### 0.3 ★ 两种架构（先选一个，后面的活完全不一样）

| | **架构 A · 官方 trigger 直接跑** | **架构 B · 薄层触发器 + 回写器** |
|---|---|---|
| 组成 | GHE webhook → Cloud Build trigger → build（Cloud Build 自己回写） | GHE webhook → **自研薄层服务** → Cloud Build（只跑） → **薄层服务回写** |
| 写多少代码 | **0 行** | ★ **~200 行**（只做"触发 + 回写"，判定逻辑仍在 Cloud Build） |
| PR 上几条 check | **1 条**（一个 trigger = 一条） | ★ **3 条同名 check**（自己写） |
| check 名可控 | ❌ 由 trigger 名决定（形如 `gcb/<trigger>`，需实测） | ✅ **完全可控**（`YAML 语法校验` 等） |
| 增量语义（只看本次改动） | ⚠️ build 检出的是**合并结果**（含 base 代码），要自己算 | ✅ 触发器手里就有 PR 号 + changed files，直接传进去 |
| fork PR | ⚠️ 行为需实测 | ✅ 可控（触发器决定要不要触发） |
| 没跑起来时 | ❌ PR 永远"Expected — Waiting for status" | ✅ 触发器可**补写失败 check** |
| 门禁配置改动 | ⚠️ 要改成 Cloud Build 的 context 名 | ✅ **零改动** |
| 适合 | 先跑通、验证链路 | 真正当门禁用 |

★ **建议**：**先用架构 A 跑通一次（半天，验证"回写到底写不写 GHE、叫什么名字"），
再决定要不要上架构 B。**
因为架构 A 的产出（context 名字、是否回写）**直接决定架构 B 要不要做**。

---

## 1. 前提对齐：把"已经打通"翻译成 6 个可验证事实

⚠️ **不要用"感觉通了"当依据**，逐条跑一遍并把输出贴进 PR。

| # | 事实 | 怎么验 | 不通过说明 |
|---|---|---|---|
| **F1** | connection 装好了 | `gcloud builds connections describe my-ghe-conn --region=<REGION> --project=<PROJECT>` → `installationState == COMPLETE` | App 没装完 / SAML 没授权 |
| **F2** | repository 绑到 GHE 仓库 | `gcloud builds repositories describe my-repo --region=<REGION>` → `remoteUri` 是 `https://<ghe-host>/<ORG>/<REPO>.git` | 填成了 github.com 的地址 |
| **F3** | trigger 指向正确的 build config | `gcloud builds triggers describe <TRIGGER> --region=<REGION>` → `buildConfig.path` 指向仓库里的文件；`github.pullRequestPattern` 匹配目标分支 | 路径写成绝对路径（Cloud Build 要的是**仓库相对路径**） |
| **F4** | **PR 事件真的能触发 build** | 提一个 PR → `gcloud builds list --region=<REGION> --limit=5` 看有没有新 build | webhook 方向（GHE → Google）不通 / region 不一致 |
| **F5** | build 能拉到源码 | `gcloud builds log <BUILD_ID>` 里能看到 clone/checkout 成功 | Google → GHE 方向不通 / 自签 CA / 防火墙 |
| **F6** | ★ **结果能回写到 GHE** | 见 §1.1 —— **这是最关键、也最不确定的一条** | 整条链路"最后一步"断掉 |

### 1.1 ★ F6：结果到底回写到 GHE 了吗？用什么名字？

```bash
# PR 上的 check 长什么样（两种机制都要查 —— API 是两套，但 PR 页面统一渲染）
gh pr checks <PR_NUMBER> --repo <ORG>/<REPO>

gh api --hostname <ghe-host> /api/v3/repos/<ORG>/<REPO>/commits/<SHA>/check-runs \
  --jq '.check_runs[] | {name, status, conclusion, app: .app.slug}'

gh api --hostname <ghe-host> /api/v3/repos/<ORG>/<REPO>/commits/<SHA>/status \
  --jq '.statuses[] | {context, state, creator: .creator.login}'
```

| 观察结果 | 含义 | 后续动作 |
|---|---|---|
| `check-runs` 里有条目，name 形如 `gcb/<trigger>` | Cloud Build 写的是 **check run** | 门禁 context 填这个 name |
| `statuses` 里有条目，context 形如 `gcb/<trigger>` | Cloud Build 写的是 **commit status** | 门禁 context 填这个 context |
| **两边都空** | ★ **回写没发生** | 查 App 权限（Checks / Commit statuses = R&W）、App 是否勾选了目标 repo、`--comment-control`、见 §9 |
| 名字里带 App 名/触发器名且**和文档不一致** | 名字由平台决定 | ★ **以实测为准**，不要照抄文档 |

> ★ **这一步的产出是整个项目的"事实源"**：这个字符串就是后面 required status checks 里要填的东西。
> **把它写进一处配置**（如 `ci-simulation/check-names.yaml` 或 `policy.yaml`），后面所有地方引用它。

---

## 2. 端到端全景与 6 个 Gate

| Gate | 阶段 | 通过标准（可验证） | 对应工作项 |
|---|---|---|---|
| **G0** | 连接层 | F1–F3 全绿 | 已有，需复核 |
| **G1** | 触发层 | PR 一开，`gcloud builds list` 里有新 build（F4） | 已有，需复核 |
| **G2** | 执行层 | build 里跑的是**你要的检查**，且**故意搞坏能红** | **W1** |
| **G3** | 回写层 | PR 页面出现 check；**名字已确认并固化** | **W2** |
| **G4** | 门禁层 | required status checks 配好；**PR 变红真的合不进去** | **W3** |
| **G5** | 兜底层 | 停掉执行路径时，PR **不会无限等待**（要么明确失败，要么明确放行） | **W4** |

★ **硬规则**：**不要在 G4 没通过之前宣布"CI 配好了"**；
也**不要在 G5 没通过之前把它设成 required**（否则一旦 CI 挂了，全员 PR 卡死）。

---

## 3. 工作分解（W1–W9）

### W1 · 决定"跑什么"（CI 配置层）

**问题**：现在 `ci-simulation/ci-test.yaml` 跑的是 helm / python 单测 / bash 断言 —— 那是 **Cloud Build 演示资产**，
而企业版要的是**内容门禁**：YAML 语法、Shell/Python 语法、清单结构。

| 选项 | 说明 | 建议 |
|---|---|---|
| **① 改造现有 `ci-test.yaml`** | 把三条检查加进去 | ❌ 会让 4 个 step 的 helm 测试与"语法检查"混在一条 check 里，**失败原因不可分** |
| **② 新建三个 build config**（推荐） | `pr-ci-yaml.yaml` / `pr-ci-script.yaml` / `pr-ci-manifest.yaml`，三个 trigger | ✅ 每条 check 独立可重跑、失败点一目了然 |
| **③ 一个 build + 内部聚合** | 保留 1 个 trigger，脚本里自己写三条 check | ✅ 只需 1 个 trigger、build-minute 省；但需要写回写逻辑（≈架构 B） |

★ **W1 的产出**：
① **三个 build config 文件**（样例见 §4）；
② **Makefile 加三个 target**（`make test-yaml` / `make test-script` / `make test-manifest`），
让"本地和 CI 跑同一套命令"这条原则继续成立；
③ **一个"本次改动文件清单"的获取方式**（增量语义，见 W5）。

### W2 · 解决"一条 build = 一条 check" vs "你要三条"

这是**最容易低估**的工作量。事实：

> **Cloud Build 一次 build = PR 上的一条 check。**
> 你的 build config 里 4 个 step → PR 上**不是** 4 条 check，而是 **1 条**。

| 方案 | 门禁里要填的名字 | 工作量 | 评价 |
|---|---|---|---|
| **A · 3 个 trigger + 3 份 config** | Cloud Build 生成的 context 名（实测，形如 `gcb/pr-ci-yaml`） | 小 | ✅ 零代码；但**门禁配置要改**（名字不是"YAML 语法校验"） |
| **B · 1 个 trigger + 自研回写器写三条 check** | 自己定的名字（`YAML 语法校验`…） | 中（~200 行） | ✅ **门禁零改动**、名字可控、可带详细日志 |
| **C · 1 个 trigger + 1 条聚合 check** | 1 个名字 | 小 | ⚠️ 失败原因挤在一条里；门禁要改 |

★ **判断**：
- 如果你们**不在乎 check 叫什么名字**，且能接受"三类检查塞进一条 check"→ **选 A**（最省事）。
- 如果要**保持现在的三条门禁 context 不变**（branch protection 存档 JSON 里就是这三个名字）→ **选 B**。

> 📌 **建议**：**先做 A 跑通链路**（半天），拿到真实的 context 名；
> 如果那个名字形态可接受，**A 就够了，不用写 B**。
> 只有当"门禁必须叫'YAML 语法校验'"或"需要多条独立可重跑 + 详细日志"时，才上 B。

### W3 · 把 check 变成硬门禁

见 [§5](#5-门禁下发)（单独一节，因为要填的 context 名来自 W2）。

### W4 · 兜底：没跑起来时怎么收场（★ 最容易被漏）

**问题**：Cloud Build trigger 挂了 / 网络断了 / trigger 被误删 →
**PR 永远显示 "Expected — Waiting for status"**，所有人都卡住，且看不出是哪一步卡住。

| 兜底手段 | 做法 | 适用 |
|---|---|---|
| **① 巡检脚本**（最省事） | 定时（比如 10 分钟）检查"受管分支上 open 且 required check 缺失的 PR" → 告警 + 人工介入 | ✅ 任何架构都能用 |
| **② 触发器侧补写失败 check** | 架构 B 的薄层服务：超时（>15 分钟）没等到 build 结果 → **主动写一条失败 check** | ✅ 架构 B 天然具备 |
| **③ 定期重跑** | 巡检发现"没有 build 记录的 PR" → 手动 `gcloud builds triggers run` 重跑 | ✅ 配合 ① |
| **④ 不设 required**（最保守） | 只把 check 当"给人看的信号" | ⚠️ 违背门禁初衷，最后兜底用 |

★ **纪律**：**required status check 必须保证每个 PR 都上报**（要么绿、要么红、要么明确失败），
**绝不能"不吭声"**。这就是仓库 README 第 8 节踩过的坑（`validate-ip` 带 `paths` 过滤 → 永久 BLOCKED）。

### W5 · 增量语义（"只看本次改动"）在 Cloud Build 里怎么实现

**语义差异**：Cloud Build 的 PR trigger 检出的是 GitHub 生成的**临时合并结果**
（PR head + base 最新代码）→ **build 里看到的是全量代码**，不是"本次改动"。

| 办法 | 怎么做 | 评价 |
|---|---|---|
| **① 用 GitHub API 取改动清单**（推荐） | build 里用 token 调 `GET /repos/{o}/{r}/pulls/{n}/files` → 写进 `/workspace/changed.txt` | ✅ 与 Actions 版语义一致；需要 token（Secret Manager）+ PR 号 |
| **② 用 git diff** | build 里有完整 git 历史 + base SHA → `git diff --name-only <base>...HEAD` | ✅ 无需 API；**但要先确认 PR trigger 下能拿到 base SHA** |
| **③ 干脆全量检查** | 不算 diff，扫全仓库 | ⚠️ 历史遗留问题会让 check 永远红（本仓库就有 `base/git.sh` 的真实语法错误）→ **不推荐** |

> ★ **部署前验证项（PR 号 / base SHA 从哪来）**：
> Cloud Build 的 GitHub trigger 会注入 substitutions（如 `$BRANCH_NAME`、`$COMMIT_SHA`）。
> **要确认 PR 场景下还有没有 PR 号 / base SHA**：
> ```bash
> gcloud builds describe <BUILD_ID> --region=<REGION> --format='value(build.substitutions)'
> gcloud builds log <BUILD_ID> --region=<REGION> | grep -i -E 'branch|sha|PR'
> ```
> 若**没有 PR 号** → 办法 ① 走不通 → 改走办法 ②（需要 base SHA）
> 或**改用架构 B**（触发器手里有 PR 号和文件清单，直接当 substitutions 传进去）。

### W6 · 不可信输入与安全（PR 是攻击面）

| 事项 | 做法 |
|---|---|
| **fork PR 的行为** | ⚠️ **部署前验证项**：fork 的 PR 会不会触发 Cloud Build？会不会拉到 fork 代码？<br>若不触发 → required check 永不上报 → PR 永久卡住（→ W4 兜底必须做） |
| **build 用的 SA** | ★ **PR build 用专用 SA**，只给读权限；**部署权限的 SA 只给 main 分支的 build** |
| **secrets** | ⚠️ **PR 上来的代码不可信** → PR build 不要挂生产 secrets |
| **build config 从哪来** | PR trigger 用**仓库里 PR 分支的 build config**（可被 PR 篡改）→ 里面不能有特权逻辑；特权操作只允许在 main 触发 |
| **网络出口** | build 里不需要出网到生产 |

### W7 · 观测与运维

| 需求 | 做法 |
|---|---|
| **重跑一次 check** | ★ PR 页面的 "Re-run jobs" **只对 Actions 生效** → Cloud Build 去控制台 **History → Retry**，或 `gcloud builds triggers run <TRIGGER> --region=<REGION> --branch=<PR分支>` |
| **失败排查** | `gcloud builds log <BUILD_ID>`；本地复现 = `make test`（同一套命令） |
| **"没跑" vs "跑了红"** | 两种 API 都查（check-runs + status）；巡检脚本区分 `not_run` / `failed` |
| **告警** | Cloud Build 失败通知（Cloud Monitoring / Pub/Sub）+ 巡检告警 |
| **漂移巡检** | 定期核对"required context 列表" vs "实际能产出这些 context 的 trigger 列表" → 不一致就告警 |

### W8 · 清账（P5）

- 全仓 grep：还有谁引用了被废弃的 `.github/workflows/pr-checks.yml`？
- GHE 的 required status checks 里，有没有**已经没有任何 trigger 会产出**的 context？
  → 有 = **所有 PR 永久卡住**（静默灾难）。
- Actions 已全禁 → 仓库里那两个 workflow 文件（`pr-checks.yml` / `validate-ip-list.yml`）**要不要删**？
  → 建议：**移到 `docs/` 或标注"已弃用"**，别留一个"看起来还在跑"的 workflow（误导 + 漂移）。

### W9 · 灰度与下发顺序

1. **单仓库 + 单 trigger + 不设 required** → 跑通并故意搞红一次。
2. **三个 trigger 全上 + 三条 check 都出现** → 名字确认并固化到配置文件。
3. **把 context 写进 required**（先 classic branch protection，`strict=true`）。
4. **观察 1–2 周**（有多少 PR 被拦、误报率）。
5. **再考虑升到组织级 ruleset**（一次下发全组织；★ 组织级配错 = 全组织一起卡，只有 org owner 能改）。

---

## 4. CI 配置资产：三个 build config 样例

> ★ **可以直接抄**。位置建议：`ci-simulation/pr-ci-*.yaml`（路径相对仓库根目录，trigger 里就用这个路径）。

### 4.1 公共约定

| 约定 | 值 | 理由 |
|---|---|---|
| builder 镜像 | 按检查类型选**自带工具链**的镜像 | 免安装、版本固定 |
| YAML 检查 | `ruby:3.3` | ★ ruby 标准库自带 YAML，**零安装** |
| Shell/Python 检查 | `python:3.11`（full） | 自带 bash + python3 + git |
| 清单结构检查 | `ruby:3.3` | 同上 |
| 工作目录 | `dir: 'ci-simulation'` | 与现有 `ci-test.yaml` 一致 |
| 工具路径 | `TOOLS_BIN_DIR=/workspace/ci-simulation/.tools/bin` + `PATH` | 与现有约定一致 |

### 4.2 `pr-ci-yaml.yaml`（对应 check「YAML 语法校验」）

```yaml
# ci-simulation/pr-ci-yaml.yaml —— Check ①：YAML 语法校验（增量）
#
# ★ 设计要点：
#   1. builder 镜像选 ruby:3.3 —— 标准库自带 YAML，**不需要任何安装**
#   2. 只校验"本次改动的文件"（清单来自 changed.txt，由触发/回写层准备）
#   3. Helm 模板（{{ .Values.x }}）不是合法 YAML → 排除 */templates/*
steps:
  - name: 'ruby:3.3'
    id: 'yaml-syntax'
    dir: 'ci-simulation'
    entrypoint: bash
    args: ['-c', 'make test-yaml']
    env:
      - 'PATH=/workspace/ci-simulation/.tools/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
    timeout: '300s'
options:
  machineType: 'E2_HIGHCPU_8'
  diskSizeGb: '10'
  logging: 'CLOUD_LOGGING_ONLY'
```

### 4.3 `pr-ci-script.yaml`（对应 check「Shell / Python 语法校验」）

```yaml
# ci-simulation/pr-ci-script.yaml —— Check ②：Shell / Python 语法校验（增量）
#
# ★ python:3.11 (full) 自带 bash + python3 + git → 同样零安装
steps:
  - name: 'python:3.11'
    id: 'script-syntax'
    dir: 'ci-simulation'
    entrypoint: bash
    args: ['-c', 'make test-script']
    env:
      - 'PATH=/workspace/ci-simulation/.tools/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
    timeout: '300s'
options:
  machineType: 'E2_HIGHCPU_8'
  diskSizeGb: '10'
  logging: 'CLOUD_LOGGING_ONLY'
```

### 4.4 `pr-ci-manifest.yaml`（对应 check「示例清单结构自检」）

```yaml
# ci-simulation/pr-ci-manifest.yaml —— Check ③：K8s 清单结构自检
steps:
  - name: 'ruby:3.3'
    id: 'manifest-structure'
    dir: 'ci-simulation'
    entrypoint: bash
    args: ['-c', 'make test-manifest']
    env:
      - 'PATH=/workspace/ci-simulation/.tools/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
    timeout: '300s'
options:
  machineType: 'E2_HIGHCPU_8'
  diskSizeGb: '10'
  logging: 'CLOUD_LOGGING_ONLY'
```

### 4.5 Makefile 要加的三个 target

> ★ 与现有 Makefile 的风格保持一致（每个 target 末尾打印 `[test-xxx] OK`）。

```makefile
# ── 内容门禁（企业版 PR check 用；本地和 CI 跑同一条命令）────────────
CHANGED_FILE_LIST ?= /workspace/changed.txt   # CI 注入；本地可手工指定

test-yaml: ## YAML 语法校验（只查本次改动；跳过 Helm 模板）
	@ruby -ryaml -e '\
	  files = File.readlines(ENV.fetch("CHANGED_FILE_LIST", "/tmp/changed.txt")).map(&:strip).reject(&:empty?);\
	  files = files.select { |f| f.end_with?(".yml", ".yaml") }.reject { |f| f.include?("/templates/") };\
	  bad = [];\
	  files.each do |f|\
	    next unless File.exist?(f);\
	    begin; YAML.parse_file(f); puts "OK   #{f}";\
	    rescue Psych::SyntaxError => e; bad << "#{f}: #{e.message}"; end;\
	  end;\
	  if bad.empty?; puts "✅ #{files.size} 个 YAML 文件语法全部正确";\
	  else; bad.each { |b| puts "❌ #{b}" }; exit 1; end'
	@echo "[test-yaml] OK"

test-script: ## Shell / Python 语法校验（只查本次改动）
	@for f in $$(grep -E '\.sh$$' $(CHANGED_FILE_LIST) 2>/dev/null); do \
	  [ -f "$$f" ] || continue; bash -n "$$f" && echo "OK   $$f" || exit 1; \
	done
	@for f in $$(grep -E '\.py$$' $(CHANGED_FILE_LIST) 2>/dev/null); do \
	  [ -f "$$f" ] || continue; python3 -m py_compile "$$f" && echo "OK   $$f" || exit 1; \
	done
	@echo "✅ 本次改动的 shell / python 语法正确"
	@echo "[test-script] OK"

test-manifest: ## K8s 清单结构自检（apiVersion / kind / metadata.name）
	@ruby -ryaml -e '\
	  files = Dir.glob("charts/**/*.yaml") + Dir.glob("demo/pr-check-actions/yaml-samples/k8s-*.yaml");\
	  bad = [];\
	  files.each do |f|\
	    doc = YAML.load_file(f);\
	    missing = [];\
	    missing << "apiVersion" unless doc.is_a?(Hash) && doc["apiVersion"];\
	    missing << "kind"       unless doc.is_a?(Hash) && doc["kind"];\
	    missing << "metadata.name" unless doc.is_a?(Hash) && doc.dig("metadata", "name");\
	    bad << "#{f}: 缺少 #{missing.join(", ")}" unless missing.empty?;\
	  end;\
	  if bad.empty?; puts "✅ #{files.size} 个清单结构正确";\
	  else; bad.each { |b| puts "❌ #{b}" }; exit 1; end'
	@echo "[test-manifest] OK"
```

> ⚠️ **`test-manifest` 是"常驻"检查**（扫全目录），**不是增量** ——
> 这与现在 Actions 版的行为一致（check ③ 就是常驻的）。

### 4.6 增量清单怎么进到 build 里（三种，按可行性排序）

| 方式 | 做法 | 需要什么 |
|---|---|---|
| **① 触发时注入**（★ 架构 B） | 薄层服务拿到 PR 号 → 调 `GET /repos/{o}/{r}/pulls/{n}/files` → 写进 `/workspace/changed.txt` 或作为 substitution | 薄层服务 + token |
| **② build 内自己算**（架构 A） | build 里用 token 调 API 拿文件列表 → 写 `changed.txt` → 再跑 `make test-yaml` | GHE token（Secret Manager）+ PR 号（substitution） |
| **③ git diff** | build 里 `git diff --name-only <base>...HEAD` | base SHA（★ 需先验证 trigger 是否提供） |

★ **无论哪种，都要把"清单来源"写进文档** —— 否则半年后没人知道 `changed.txt` 是谁生成的。

---

## 5. 门禁下发

### 5.1 context 名从哪来

| 架构 | required status checks 里填什么 |
|---|---|
| A（3 trigger） | Cloud Build 实测出来的 context（§1.1 的输出），例如 `gcb/pr-ci-yaml` |
| B（自研回写器） | 你自己定的名字：`YAML 语法校验` / `Shell / Python 语法校验` / `示例清单结构自检` |

★ **把名字固化在一处**（如 `ci-simulation/check-names.yaml`），门禁配置和文档都引用它。

### 5.2 配置命令（GHES）

```bash
# 先看现状
gh api --hostname <ghe-host> /api/v3/repos/<ORG>/<REPO>/branches/main/protection \
  --jq '.required_status_checks'

# 加上三条（名字必须与实际产出的**一字不差**）
gh api --hostname <ghe-host> -X PUT \
  /api/v3/repos/<ORG>/<REPO>/branches/main/protection \
  -F 'required_status_checks[strict]=true' \
  -F 'required_status_checks[contexts][]=<实测 context 1>' \
  -F 'required_status_checks[contexts][]=<实测 context 2>' \
  -F 'required_status_checks[contexts][]=<实测 context 3>' \
  -F 'enforce_admins=true' \
  -F 'required_pull_request_reviews[required_approving_review_count]=1' \
  -F 'required_pull_request_reviews[dismiss_stale_reviews]=true'
```

> ⚠️ **必须逐字符一致**：大小写、空格、斜杠。
> ★ **填之前必须真的跑过一次**拿到名字（§1.1），**不要照抄文档里的示例字符串**。

### 5.3 classic vs ruleset

| | Classic branch protection | Ruleset |
|---|---|---|
| GHES 兼容性 | ★ **任何版本都行** | 需要 GHES **3.13+**（★ 部署前验证） |
| 组织级下发 | ❌ 逐仓库 | ✅ 一次全组织 |
| 组织级规则谁能改 | 仓库 admin | ★ **只有 org owner**（配错 = 全组织卡死） |
| 建议 | ★ **试点阶段用这个** | 试点稳定后再上组织级 |

---

## 6. 不可信输入与安全

| 风险 | 后果 | 缓解 |
|---|---|---|
| **PR 篡改 build config** | PR 分支的 `pr-ci-yaml.yaml` 被改成"永远成功" | ★ build config **只从 main/可信分支读**（或用 inline config）；门禁不能只信 build 的结论 |
| **PR 挂生产 secrets** | 密钥外泄 | PR build 用**最小权限 SA**，不挂生产 secret |
| **PR 代码在你们环境里跑** | 逃逸/挖矿 | Cloud Build 用**临时 VM**（比自建 runner 隔离好）；不挂 kubeconfig；限制出网 |
| **fork PR 不触发** | required check 永不上报 → PR 永久卡住 | W4 兜底（巡检 + 补写失败）；或**明确不支持 fork PR**（写进贡献指南） |
| **谁能改 trigger** | 绕过门禁 | trigger / SA 权限收敛到平台组；建 trigger 进审计 |

---

## 7. 观测与运维

| 需求 | 做法 |
|---|---|
| 失败排查 | `gcloud builds log <BUILD_ID>`；**本地复现 = `make test`**（同一套命令，这是 `ci-simulation` 的核心价值） |
| 重跑 | 控制台 History → Retry；或 `gcloud builds triggers run <TRIGGER> --region=<REGION> --branch=<PR分支>` |
| 没跑 vs 跑红 | 两种 API 都查 + 巡检脚本区分 |
| 告警 | Cloud Build 失败 → Cloud Monitoring/Pub/Sub；巡检"缺 check 的 PR" → 告警 |
| 漂移巡检 | 定期比对"required context 列表" vs "实际产出者（trigger / 回写器）列表" |

---

## 8. 端到端验收清单

```bash
# ① 三个 trigger 都在，且指向正确的 config
gcloud builds triggers list --region=<REGION> --project=<PROJECT>
gcloud builds triggers describe pr-ci-yaml     --region=<REGION> --format='value(github,name,buildConfig)'
gcloud builds triggers describe pr-ci-script   --region=<REGION> --format='value(github,name,buildConfig)'
gcloud builds triggers describe pr-ci-manifest --region=<REGION> --format='value(github,name,buildConfig)'

# ② PR 上三条 check 都在，且名字已知
gh pr checks <PR_NUMBER> --repo <ORG>/<REPO>
gh api --hostname <ghe-host> /api/v3/repos/<ORG>/<REPO>/commits/<SHA>/check-runs \
  --jq '.check_runs[] | {name, conclusion}'

# ③ 故意搞坏 → 必须变红（而且是"那一条"红）
#    改一个缩进错的 yaml → 期望只有「YAML 语法校验」红
#    改一个语法错的 .sh    → 期望只有「Shell / Python 语法校验」红

# ④ 门禁生效：变红时真的合不进去
gh pr merge <PR_NUMBER> --squash   # 期望被拒

# ⑤ 兜底：临时停掉 trigger 再提 PR → 不能无限等待
gcloud builds triggers update pr-ci-yaml --region=<REGION> --disabled
#   → 期望：巡检在 N 分钟内告警 / 补写失败 check

# ⑥ 仓库级清理：Actions 已禁，workflow 文件别留"看起来还在跑"的
git ls-files '.github/workflows/'
```

★ **验收的判定标准只有一句**：
> **"故意提交一个坏 YAML，PR 上出现一条红叉，且这个 PR 合不进去。"**
> 做到这一条，链路就算通了；其余都是优化。

---

## 9. 排错手册

| 症状 | 根因 | 处理 |
|---|---|---|
| **PR 开了但没有 build** | webhook 方向不通 / trigger 的 `pullRequestPattern` 没匹配目标分支 / region 不一致 | 放行 GHE 出网到 `cloudbuild.googleapis.com`；核对 trigger 描述 |
| **build 创建了但拉不到源码** | Google → GHE 不通 | Service Directory / PSC / 公网暴露；放行 `35.199.192.0/19` |
| `x509: certificate signed by unknown authority` | GHE 自签 CA | `--ssl-ca-file=ca.pem`（≤10KB, PEM） |
| `installationState` 不是 `COMPLETE` | App 没装完 / SAML 未授权 | 点 describe 给的链接补完 |
| **build 成功但 PR 上没有 check** | ★ 回写没发生 | 查 App 权限（Checks / Commit statuses = R&W）、App 是否勾了目标 repo；**两种 API 都查** |
| **PR 上 check 名字和门禁里填的对不上** | 平台生成的名字与预期不同 | ★ 以 `gh api .../check-runs` 实测为准，重新填 |
| **PR 永远 Waiting for status** | required check 永不上报（trigger 没触发/被删/名字不匹配） | ★ 巡检告警；核对 required context 与实际产出者 |
| **PR 页面看不到 check 标签** | 查的是 commit status 而不是 check run（API 两套） | 用 `gh api .../status` 再查一次 |
| **本地过了 CI 挂** | 环境差异（工具链版本） | 用固定 builder 镜像；本地用同一个镜像跑 |
| **增量清单为空 → check 绿但什么都没查** | 清单来源失效（PR 号/substitution 没传进来） | 把"本次检查了 N 个文件"打印进 build 输出 |
| **build 里执行了 PR 分支的恶意脚本** | PR 可改 build config | build config 只从可信分支读；PR build 用最小权限 SA |
| **re-run 按钮点了没反应** | "Re-run jobs" 只对 Actions 生效 | Cloud Build 控制台 History → Retry |
| **`/gcbrun` 没反应** | `--comment-control` 设置或平台限制 | 显式设 `--comment-control=COMMENTS_DISABLED`，改用手动触发 |

---

## 10. 风险与回滚

| 风险 | 影响 | 回滚 |
|---|---|---|
| **required check 永不上报** | 全员 PR 卡死 | ★ **上线前先跑 §8 的 ⑤ 兜底验收**；紧急时把 required contexts 清空（恢复成"不拦"） |
| **组织级 ruleset 配错** | 全组织一起卡死，只有 org owner 能改 | 预先约定熔断人 + 一条 PUT 命令清空 contexts |
| **build config 被 PR 篡改** | 门禁形同虚设 | config 只从可信分支读；漂移巡检 |
| **Cloud Build 配额/费用** | 多 trigger × 每次 push | 巡检时忽略已被新 push 取代的旧 build；按需减 trigger |
| **GHE 到 GCP 的网络抖动** | 随机失败 | 巡检 + 重跑；必要时临时降级为"非 required" |
| **Actions 全禁后遗留 workflow** | 误导 + 漂移 | W8 清账 |

★ **上线纪律**：
1. 先不设 required → 观察 → 再设；
2. 设了之后**必须有人盯着**；
3. **保留"一键拆掉 required contexts"的命令**（贴在值班手册里）。

---

## 11. 工作量与排期建议

| 阶段 | 内容 | 人日（估） | 产出 |
|---|---|---|---|
| **S0** | 复核 F1–F6（尤其 F6 回写 + context 名） | 0.5 | 事实源：context 名字 |
| **S1** | 三个 build config + Makefile 三个 target + 本地跑通 | 1 | `ci-simulation/pr-ci-*.yaml` |
| **S2** | 建 3 个 trigger，PR 上跑出 3 条 check，故意搞红一次 | 0.5 | PR 上可见的三条 check |
| **S3** | 增量清单来源打通（验证 PR 号/base SHA） | 0.5–1 | `changed.txt` 来源确定 |
| **S4** | 门禁下发（classic）+ 验收 | 0.5 | 合不进去 |
| **S5** | 兜底（巡检脚本 + 告警） | 1 | 不会无限等待 |
| **S6** | （可选）架构 B：薄层触发器 + 回写器 | 2–3 | 三条同名 check + 完全可控 |
| **S7** | 清账 + 灰度到组织级 ruleset | 0.5 | 治理面收敛 |

★ **最小可用组合 = S0 + S1 + S2 + S4 ≈ 2.5 人日**（不含兜底 S5）。
★ **不建议一上来就做 S6**（架构 B）—— 先用架构 A 跑通，拿到真实 context 名再判断值不值。

---

## 12. 待确认清单

| # | 问题 | 影响 |
|---|---|---|
| Q1 | GHE 的**形态**（Cloud / 自建 Server）与版本？ | ruleset 可用性（3.13+）、API base、network 方案 |
| Q2 | 现在的 webhook 具体是**官方 trigger** 还是别的接法？ | 决定 F3/F4 怎么验 |
| Q3 | PR trigger 下能拿到 **PR 号 / base SHA** 吗？ | 增量清单方案（W5） |
| Q4 | Cloud Build 回写到 GHE 的是 **check run** 还是 **commit status**？名字是什么？ | required context 填什么 |
| Q5 | 门禁**必须保持现在的三个中文 context 名**，还是可以用 `gcb/*`？ | 决定要不要做架构 B（S6） |
| Q6 | 是否需要支持 **fork PR**？ | W6 + 兜底设计 |
| Q7 | 有没有**内部 CI**（Jenkins/Tekton）？ | 备选执行器 + 回写器托管位置 |
| Q8 | 生产 SA / 权限边界怎么划？ | W6 安全设计 |

---

## 13. 关联文档

| 主题 | 文档 |
|---|---|
| ★ **本文的上游**（为什么"换执行器"就行 / 四层模型 / 四条路线） | [ci-simulation-enterprise.md](ci-simulation-enterprise.md) |
| ★ Cloud Build 触发 GitHub（含 **GHES Server 专章 §7**、坑速查表 §7.6） | [how-to-github-trigger-cloud-build.md](file:///Users/lex/git/knowledge/gcp/gcp-cloud-build/how-to-github-trigger-cloud-build.md) |
| ★ Cloud Build 做 PR 门禁（§4 Check 回写机制 / §4.4 多 check 的三种做法） | [how-to-pr-checks-with-cloud-build.md](file:///Users/lex/git/knowledge/gcp/gcp-cloud-build/how-to-pr-checks-with-cloud-build.md) |
| ★ 现有 Cloud Build 样例（Makefile + ci-test.yaml + 四个 step） | [ci-simulation/README.md](README.md) |
| ★ 现有三条 check 与门禁存档 JSON | [demo/pr-check-actions/README.md](../demo/pr-check-actions/README.md) |
| ★ 自研 App（**架构 B 的薄层可复用**：webhook + GHE client + check writer） | [cr-check/README.md](../cr-check/README.md) |
| 无 Actions 替代矩阵 | [19-no-actions-alternative-matrix.md](file:///Users/lex/git/knowledge/gcp/ucp/argocd-topics/gh-enterprise/19-no-actions-alternative-matrix.md) |

---

## 附：一页纸总结

> **你已经打通了"PR → Cloud Build"。剩下四件事：**
>
> | # | 干什么 | 关键点 |
> |---|---|---|
> | **W1** | 让 build 跑**你要的检查** | 新建 3 个 build config（YAML/脚本/清单），Makefile 加 3 个 target |
> | **W2** | 决定 **check 叫什么名字** | ★ **一次 build = 一条 check**；要三条 → 3 个 trigger（名字由平台定）**或**自研回写器（名字自己定） |
> | **W3** | **变硬门禁** | required status checks 填**实测**名字，一字不差；先 classic 后 ruleset |
> | **W4** | **兜底** | 没跑起来时**不能无限等待** → 巡检 + 补写失败 check |
>
> **最小可用 ≈ 2.5 人日；先跑架构 A（0 行代码），拿到真实 context 名再决定要不要自研回写器。**
> **验收标准只有一句：故意提交一个坏 YAML → PR 上出现红叉 → 这个 PR 合不进去。**
