# Cloud Build Trigger 深入 —— 它到底能做什么

> 这篇回答一个问题：**Cloud Build 的 trigger 是不是只能"事件来了跑一次构建"？**
>
> 答案：**不是**。Trigger 是"事件 → 一次构建"这条规则上的**全部可配置项**。
> 而"把 PR 校验结果加工成 report 回填到 PR"这件事，
> **只改 build config**（也就是 trigger 指向的那个 yaml）就能做到，不需要另起一个服务。
>
> 配套可落地模板：[`trigger/`](trigger/README.md) · 场景篇：[`pull-report-bot-flow.md`](pull-report-bot-flow.md)

---

## 0. TL;DR

1. **Trigger 是一条规则**：什么事件 → 跑哪个 build config → 用什么身份 → 跑在哪。
2. **Trigger 有 8 类**（github / webhook / manual / pubsub / csr / gitlab / bitbucket…），
   字段名不同，能力边界一样。
3. **1st gen / 2nd gen / Developer Connect** 三代，字段名不同（`filename` vs `gitFileSource`）。
4. ★ **最关键的一条认知**：
   **"report"不是 trigger 的功能，是 build config 的功能**。
   trigger 只负责"触发 + 传参 + 过滤 + 回传日志"；
   report 是 **build 的最后一个 step**。
   但两者绑在一起（trigger 指向 build config），所以"改 build config"在体感上就等于"在 trigger 里加工"。
5. Trigger 自带的 4 个能力直接命中你的需求：
   - `includeBuildLogs` → **GitHub 上直接出现 Cloud Build 日志链接**
   - `substitutions` → 把 PR 号 / commit / 仓库名带进构建（report 里要用的就是它们）
   - `substitutions` → 一个 trigger 也能分环境（dev / staging / prod）
   - `commentControl` → 公共仓库可以要求 `/gcbrun` 才跑，省算力

---

## 1. Trigger 在体系里的位置

```
  GitHub 事件                Cloud Build                       你的代码
  ───────────                ───────────                       ────────
  pull_request  ──┐
  push           ──┼──▶  TRIGGER  ──▶  BUILD  ──▶  build config ──▶ steps
  tag            ──┘   (规则/过滤/       (一次构建)   (yaml)
  comment        ──▶    变量/身份/        │             │
                       日志回传)          │             ├─ install-deps
                                          │             ├─ YAML 校验
                                          │             ├─ Shell 校验
                                          │             ├─ Helm lint/template
                                          │             └─ report  ◀── 最后一步，产出你要的那张表
                                          │
                                          └──▶ 状态回传 GitHub（check run）
```

**Trigger ≠ Build ≠ Build config**，三者别混：

| | 是什么 | 谁创建 | 改它的影响 |
|---|---|---|---|
| **Trigger** | "什么事件触发、跑什么、什么身份"的**规则** | `gcloud builds triggers create` | 影响触发条件与变量 |
| **Build** | 一次具体执行（有 build id、有日志、有红绿） | trigger 自动产生 / `gcloud builds submit` | 一次性的 |
| **Build config** | **一个 yaml**，描述这次构建跑哪些 step | 你写在仓库里 | ★ 改它 = 改"CI 做什么"，**trigger 指向它** |

★ 所以你们的诉求"在 trigger 里做加工出 report"，准确说是：
**在 trigger 指向的那个 build config 里加一个 report step**（模板见 `trigger/cloudbuild.yaml`）。

---

## 2. Trigger 类型全景

`gcloud builds triggers create` 的子命令（gcloud 526 实测）：

| 子命令 | 触发源 | 典型用途 |
|---|---|---|
| `github` | GitHub 事件（push / PR / tag） | ★ 你们在用的这个 |
| `webhook` | 任意 HTTP webhook（带 secret 校验） | 内部流水线 / Gerrit / 自建中转 |
| `manual` | 手动 `gcloud builds triggers run` | 兜底重跑 |
| `pubsub` | Pub/Sub 消息 | 事件总线驱动 |
| `cloud-source-repositories` | CSR 仓库事件 | 老一代内部仓库 |
| `gitlab` / `bitbucket-cloud` / `bitbucket-data-center` / `bitbucketserver` | 对应 Git 服务 | 多 Git 平台 |

★ 字段名不同，但**能力边界一样**：
都是"事件类型 + 分支过滤 + build config + 服务账号 + substitutions + 日志/产物"。

---

## 3. 1st gen / 2nd gen / Developer Connect 的差别

官方文档把这三代并列展示，实质差别在**"仓库怎么被引用"**：

| | 1st gen | 2nd gen | Developer Connect |
|---|---|---|---|
| 仓库引用 | `github.owner` + `github.name` | `github.owner/name/installationId` + `gitFileSource` | Developer Connect 连接里的 repository |
| build config 位置 | `filename: "cloudbuild.yaml"` | `gitFileSource.path` | 同 2nd gen |
| 需要连接吗 | 不需要 | 需要 GitHub 连接 + 装 Cloud Build 的 GitHub App | 需要 |
| region | 可用 global | ★ **不支持 global**，必须指定 region | 同 2nd gen |
| `--repository` | — | `projects/P/locations/R/connections/C/repositories/X` | — |

★ 官方文档原话（值得记）：
> **只有 trigger 上指定的 service account 会被用于构建**；
> build config 里写的 serviceAccount，在 trigger 场景下会被**忽略**。

---

## 4. ★ Trigger 能做的 12 件事

（字段名取自 Cloud Build v1 API 的 `BuildTrigger` 资源定义）

| # | 能力 | 字段 | 说明 |
|---|---|---|---|
| 1 | **决定何时触发** | `github.pullRequest.branch` / `github.push.branch` / `github.push.tag` | RE2 正则；`invertRegex` 可以取反 |
| 2 | **决定跑什么** | `filename`（1st gen）/ `gitFileSource.path`（2nd gen）/ `build`（内联）/ `autodetect` | autodetect 的优先级：cloudbuild.yaml → .yml → .json → Dockerfile |
| 3 | **文件级过滤** | `includedFiles` / `ignoredFiles` | glob（支持 `**`）；"只改文档就别跑 CI" |
| 4 | **表达式过滤** | `filter` | CEL 表达式，2nd gen 才有 |
| 5 | **评论控制** | `github.pullRequest.commentControl` | 要 `/gcbrun` 才跑 / 不用跑 / 禁用评论触发 |
| 6 | **人工审批** | `approvalConfig` / `--require-approval` | 构建先挂起等人批 |
| 7 | **传变量** | `substitutions`（trigger 级）+ build 级 + 内置 | 一套代码分环境就靠它 |
| 8 | **日志回传 GitHub** | `includeBuildLogs` | ★ `INCLUDE_BUILD_LOGS_WITH_STATUS` → build 结束后 PR 的 check 上出现日志链接 |
| 9 | **执行身份** | `serviceAccount` | 权限、计费、审计都挂在它身上 |
| 10 | **运行位置** | `--region` / build 的 `options.pool` | 私有池（无公网）时 region 必须和池一致 |
| 11 | **产物与日志去向** | build 的 `artifacts` / `logsBucket` / `options.logging` | report.md 也能落一份到 GCS |
| 12 | **元数据与开关** | `tags` / `disabled` / `description` | tags 方便按团队统计；`disabled: true` 临时停用而不删 |

配套的日常运维命令：
```
gcloud builds triggers list
gcloud builds triggers describe TRIGGER_NAME
gcloud builds triggers run TRIGGER_NAME --region=REGION     # 手动跑一次
gcloud builds triggers delete TRIGGER_NAME
gcloud builds list --filter="status=FAILURE"
gcloud builds log BUILD_ID                                  # 看完整日志
gcloud builds describe BUILD_ID --format='value(logUrl)'    # ★ 官方控制台链接
gcloud builds cancel BUILD_ID
```

---

## 5. 内置 substitution 全清单

trigger 触发的 build 里，这些变量**自动存在**（不需要自己定义）：

| 变量 | 含义 |
|---|---|
| `$PROJECT_ID` / `$PROJECT_NUMBER` | 当前项目 |
| `$LOCATION` | 构建所在 region |
| `$BUILD_ID` | 本次构建 id（report 里拼控制台链接要用） |
| `$TRIGGER_NAME` | 触发它的 trigger 名 |
| `$COMMIT_SHA` / `$REVISION_ID` / `$SHORT_SHA` | 本次构建的 commit |
| `$REPO_NAME` / `$REPO_FULL_NAME` | 仓库名 / owner+repo |
| `$BRANCH_NAME` / `$TAG_NAME` / `$REF_NAME` | 分支 / tag / ref |
| `$TRIGGER_BUILD_CONFIG_PATH` | build config 在仓库里的路径 |
| `$SERVICE_ACCOUNT` / `$SERVICE_ACCOUNT_EMAIL` | 本次构建用的服务账号 |
| `$_HEAD_BRANCH` / `$_BASE_BRANCH` | ★ **PR 专属**：源分支 / 目标分支 |
| `$_HEAD_REPO_URL` | ★ **PR 专属**：源仓库地址（fork 时有用） |
| `$_PR_NUMBER` | ★ **PR 专属**：PR 号 |

★ **两个关键机制**：

1. **`options.automapSubstitutions: true`** → 把这些变量**全部变成环境变量**，
   step 里直接 `$BUILD_ID` / `$_PR_NUMBER` 就能用，不用到处写 `${_PR_NUMBER}`。
2. **dynamic substitutions**（trigger 触发的 build **永远开启**，且不可关闭）：
   可以在变量里做 bash 风格字符串操作，例如
   `${_BRANCH//\//-}`（把分支里的 `/` 换成 `-`）。

★ **报告要用的三个变量，正好全在里面**：PR 号（`$_PR_NUMBER`）、构建 id（`$BUILD_ID`）、
项目与 region（`$PROJECT_ID` / `$LOCATION`）。这就是"不需要另起服务"的底气。

---

## 6. ★ 在 trigger 这条链路上"加工出 report"的 5 种做法

按"侵入性从小到大"排：

| # | 做法 | 改动位置 | 适合 |
|---|---|---|---|
| 1 | **build config 末尾加一个 report step** | 只改 yaml | ★ 你们已经在做的（模板见 `trigger/`） |
| 2 | **`includeBuildLogs`** | 只改 trigger | 想要"PR 上直接跳到 Cloud Build 日志"，最省事 |
| 3 | **post-build step**（build config 的 `postSteps`） | 只改 yaml | 无论前面成功失败都要做的事（上传产物、清理） |
| 4 | **artifacts + GCS** | 只改 yaml | report 落一份到 GCS，便于追溯与跨 PR 对比 |
| 5 | **`options.pubsubTopic` / build 状态通知** | build config | 把结果外接给别的系统（自建服务、告警） |

★ 这 5 种**都在 build config 里**（第 2 种在 trigger 里），
**不需要单独部署一个"report 服务"** —— 这是你们方案最省事的地方。

> 唯一必须"外部授权"的点：把内容**写回 GitHub** 需要 token。
> 模板用 Secret Manager 注入 `GITHUB_TOKEN`（`availableSecrets.secretEnv`），
> token 需要 `issues: write`。

---

## 7. Trigger 字段速查（按 API 资源整理）

**顶层（BuildTrigger）**

| 字段 | 类型 | 说明 |
|---|---|---|
| `name` / `description` | string | 名字（项目内唯一）、说明 |
| `disabled` | bool | true = 永不自动触发（临时停用） |
| `serviceAccount` | string | 执行身份 |
| `filename` | string | 1st gen：build config 路径 |
| `gitFileSource` | {path, repository, revision, repoType} | 2nd gen：build config 在哪个仓库哪个路径 |
| `build` | Build | 内联 build config（不落仓库） |
| `autodetect` | bool | 自动探测 cloudbuild.yaml / Dockerfile |
| `eventType` | enum | 显式指定事件类型 |
| `filter` | string | CEL 表达式过滤（2nd gen） |
| `includeBuildLogs` | enum | `INCLUDE_BUILD_LOGS_WITH_STATUS` / `..._ONLY` |
| `includedFiles` / `ignoredFiles` | string[] | glob 过滤 |
| `substitutions` | map | 自定义变量（键必须 `^_[A-Z0-9_]+$`） |
| `approvalConfig` | object | 人工审批配置 |
| `tags` | string[] | 标签（便于统计/检索） |
| `github` | GitHubEventsConfig | GitHub 触发器配置 |
| `webhookConfig` | {secret, state} | Webhook 触发器（secret 用于校验请求） |
| `pubsubConfig` | {topic, serviceAccountEmail} | Pub/Sub 触发器 |
| `sourceToBuild` | {repoName, branchName, tagName, commitSha, dir} | 非 SCM 触发器指定代码来源 |
| `triggerTemplate` | {branchName, tagName, commitSha, pullRequest, push} | 1st gen 的触发条件 |

**GitHub 事件配置（GitHubEventsConfig）**

| 字段 | 说明 |
|---|---|
| `owner` / `name` | 仓库 owner 和名字 |
| `installationId` | 发出事件的 GitHub App 安装 id（2nd gen） |
| `enterpriseConfigResourceName` | GHES 连接（企业版） |
| `push.branch` / `push.tag` / `push.invertRegex` | push 事件的分支/tag 正则 |
| `pullRequest.branch` | PR 的**目标分支**正则（`^main$`） |
| `pullRequest.commentControl` | 评论控制：`/gcbrun` 才跑 / 不用跑 / 禁用 |

---

## 8. 坑与限制（实测/文档确认）

1. **PR 关掉会自动取消构建**：官方文档明确 —— 由 GitHub App PR trigger 触发的构建，
   **PR 关闭时会取消正在跑的构建**；但**合并 PR 不会取消**还在排队的构建。
2. **step 失败会中断后续 step** → 所以校验必须"永不失败"（模板里的 `ci_step.sh` 就是为此）。
3. **trigger 的 serviceAccount 会覆盖 build config 里的** → 权限只按 trigger 上那个算。
4. **2nd gen 不支持 global region** → `--region` 必填，且私有池的 region 要和 trigger 一致。
5. **公开仓库：任何有 read 权限的人提 PR 都能触发构建** → 用 `approvalConfig` 人工审批，
   或用 `commentControl` 要求 `/gcbrun`。
6. **required check 必须每个 PR 都上报** → 触发条件里加 `paths` 过滤 = PR 永远 BLOCKED
   （"check 从未上报"和"check 红了"在 PR 上长得一样）。
7. **同一 PR 连续 push 会并行跑多个 build** → 老的可能后完成，把新结果覆盖成旧结果。
   稳妥解法：回填前比对 PR 当前 head.sha。
8. **Webhook trigger 必须带对 secret** → 这是"谁都能触发你的构建"的唯一防线。
9. **日志默认只进 Cloud Logging** → 要长期留档就配 `logsBucket` 或 `options.logging`。
10. **`gcloud builds submit` 手动跑时，内置变量要自己给**：
    `$TRIGGER_NAME` / `$COMMIT_SHA` / `$REPO_NAME` 等可以 `--substitutions` 手动指定。

---

## 9. 动手实验清单（10 个小实验，建议按顺序做）

| # | 实验 | 命令 / 操作 | 你会看到 |
|---|---|---|---|
| 1 | 看官方有哪些 trigger 类型 | `gcloud builds triggers create --help` | 8 个子命令 |
| 2 | 看某 trigger 的完整配置 | `gcloud builds triggers describe NAME --format=yaml` | 所有字段 |
| 3 | 手动跑一次 trigger | `gcloud builds triggers run NAME --region=R` | 一次新 build |
| 4 | 看内置变量真值 | 在 build 里 `env | sort` | `$_PR_NUMBER`、`$BUILD_ID`… |
| 5 | 验证 automapSubstitutions | build 里 `echo $BUILD_ID` | 直接是值 |
| 6 | 让 report 带 PR 号 | report step 里 `echo $_PR_NUMBER` | PR 号 |
| 7 | 让 GitHub 上出现日志链接 | trigger 加 `includeBuildLogs` | check 上有 View logs |
| 8 | 只改文档不触发 | trigger 加 `includedFiles: ["**/*.md"]` | 改 yaml 不触发 |
| 9 | 校验失败仍然出报告 | 故意写坏 yaml 提 PR | 有报告，且 build 变红 |
| 10 | 拿到官方控制台链接 | `gcloud builds describe BUILD_ID --format='value(logUrl)'` | 可直接贴进 report |

---

## 10. 参考

- 官方 API（本文字段以它为准）：
  `https://cloud.google.com/cloud-build/docs/api/reference/rest/v1/projects.triggers`
- 官方指南（GitHub trigger）：
  `https://cloud.google.com/build/docs/automating-builds/create-github-app-triggers`
- 官方指南（substitution）：
  `https://cloud.google.com/build/docs/configuring-builds/substitute-variable-values`
- 本仓库：[`trigger/`](trigger/README.md)（可落地模板）·
  [`pull-report-bot-flow.md`](pull-report-bot-flow.md)（场景全链路）·
  [`github-bot-principles.md`](github-bot-principles.md)（Bot / App 原理）
