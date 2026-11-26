# Cloud Build 的 Parent Build / Child Build —— 是什么、怎么用、你们的场景要不要

> **一句话**
> **child build = 由另一个 build 触发的 build。**
> "父子"是**运行时**产生的关系（不是两个 yaml 之间的静态关系），
> 而"parent build"就是那个发起触发的 build。
>
> 交叉阅读：[`pull-report-bot-flow.md`](pull-report-bot-flow.md)（你们的全链路，本文把它展开成父子版）·
> [`cloud-build-trigger-guide.md`](cloud-build-trigger-guide.md)（Trigger 能做什么）·
> [`github-webhook-deep-dive.md`](github-webhook-deep-dive.md)（事件怎么进来的）

---

## 0. TL;DR

1. **父子是 build 与 build 之间的关系**，不是 trigger 与 trigger 之间的关系。
2. **产生方式只有一种**：在**父 build 内部**执行
   `gcloud builds triggers run CHILD_TRIGGER --region=REGION`
   （或调 API `projects.triggers.run`）→ 被 run 的那个 trigger 就产生一个 **child build**。
3. ★ **`gcloud builds submit --config=xxx` 产生的是"独立 build"，不是 child build**
   —— 它没有父，不会出现在控制台的父子层级里。
4. **为什么要拆**：扇出（一次事件 → 多条并行流水线）、环境晋级（校验过才部署）、职责分离
   （编排 vs 执行）、跨项目复用。
5. ★ **对你们的 report 场景：目前不需要父子。**
   现在"一个 build 跑 4 个校验 step"是**最简单**的形态；
   拆成父子会立刻带来三个新问题：多个 report 要自己合并、子 build 失败要自己汇总、
   父子之间传参要显式设计。**先别拆**，除非出现"扇出"或"环境晋级"的需求。
6. 父子各自**独立计费、独立超时、独立日志**，控制台会按层级展示。

---

## 1. 先把三个词分清

| 词 | 是什么 | 生命周期 |
|---|---|---|
| **build** | 一次具体执行（有 build id、日志、红绿） | 一次性 |
| **trigger** | "什么事件 → 跑哪个 build config"的规则 | 长期存在 |
| **parent / child** | **两个 build 之间的运行时关系**：child 是被 parent 触发的 | 一次执行期间建立 |

★ 容易混的点：
**"trigger A 触发了 build B，B 又触发了 build C"** —— 这时
**B 是 parent，C 是 child**；而 A 只是 B 的"触发者"，**不是 B 的 parent**。
parent 的定义是"**发起 child build 的那个 build**"，不是"最早触发链路的那个"。

---

## 2. 父子是怎么建立起来的

### 2.1 唯一的建立方式：在父 build 里 run 一个 trigger

```bash
# 在父 build 的某个 step 里执行（不是在你本地终端执行！）
gcloud builds triggers run CHILD_TRIGGER_NAME --region=REGION \
  --substitutions _PR_NUMBER=123,_SHA=abc123
```

（`gcloud builds triggers run` 的可用参数：`--region`、`--substitutions`、
`--branch` / `--sha` / `--tag`，本机 gcloud 526 实测。）

**对应的官方 API（v1）**

```
POST https://cloudbuild.googleapis.com/v1/projects/{projectId}/locations/{region}/triggers/{triggerId}:run
Body: RepoSource {
  branchName / tagName / commitSha / dir,   # 跑哪个 ref
  substitutions: { ... }                    # ★ 这次运行用的变量覆盖
}
→ 返回 Operation（异步创建 build）
```

官方对该方法的描述（原话）：
> Runs a `BuildTrigger` at a particular source revision.
> To run a regional or global trigger, use the POST request that includes the **location endpoint** in the path
> (ex. `v1/projects/{projectId}/locations/{region}/triggers/{triggerId}:run`).
> The POST request that does not include the location endpoint in the path can **only** be used when running global triggers.

★ **`RepoSource.substitutions` 的官方描述**：
> "Optional. Substitutions to use in a triggered build. **Should only be used with RunBuildTrigger**"

→ 这就是"父 → 子 传参"的**官方位置**：不是环境变量自动继承，而是 run 的时候显式带 substitutions
（或子 build 里自己去查 PR 状态）。

★ **"在父 build 内部执行"是关键**：
这样这次 run 才是"由一个 build 发起"的（而不是你在本地终端手动 run），
控制台会把新 build 挂在**发起方 build** 下面，形成父子层级。
★ 注意：v1 API 的 Build 资源里**并没有** parent/child 字段（见 §2.3），
所以这个层级是**控制台的呈现**，不是 API 里的资源关系。

### 2.2 父子关系的形状

```
 事件(PR) ──▶ trigger ──▶ build A  (parent)
                            │
                            ├─ run trigger ─▶ build B (child 1)  ──▶ 自己的 steps
                            ├─ run trigger ─▶ build C (child 2)  ──▶ 自己的 steps
                            └─ run trigger ─▶ build D (child 3)  ──▶ 自己的 steps
```

★ child 可以**只有一个**，也可以**扇出多个**（每个 run 一次）。
child 也可以**再有 child**（孙子构建）—— 但层级越深，排查越难。

### 2.3 什么**不是**父子

| 写法 | 用到的 API | 是不是父子 |
|---|---|---|
| 父 build 里 `gcloud builds triggers run CHILD_TRIGGER` | `projects.triggers.run` | ✅ 是（child build） |
| 父 build 里 `gcloud builds submit --config=child.yaml` | `projects.builds.create` | ❌ 不是（独立 build） |
| 同一个 trigger 因为两次事件各跑了一次 | `projects.triggers.run`（两次） | ❌ 不是（两个平级 build） |
| 一个 build 里并行跑多个 step | 无 | ❌ 不是（是 step，不是 build） |

★ **API 层面的诚实说明（本次联网核实）**：
Cloud Build v1 的 **Build 资源里没有 parent / child 字段**，
只有一个 `buildTriggerId`（官方描述：
"The ID of the `BuildTrigger` that triggered this build, **if it was triggered automatically**."）。
→ 也就是说：**"父子"是控制台的呈现方式，不是 API 里的资源关系**；
判定一个 build 是不是"子构建"，要看它是不是由 `projects.triggers.run` 产生的，
以及控制台里它是否挂在父 build 下面。

---

## 3. 为什么要拆成父子（四种真实动机）

| 动机 | 典型场景 | 拆完之后的好处 |
|---|---|---|
| **扇出** | 一次 PR 事件 → N 条互不相关的流水线（前端/后端/文档/镜像） | 每条独立超时、独立重试、独立配额；一条挂了不影响别的 |
| **环境晋级** | 校验通过 → 部署 staging → 人工确认 → 部署 prod | 每一级都是独立可审计的 build；prod 的触发条件天然由上一级成功来保证 |
| **职责分离** | 一个 build 负责"判定 + 编排"，另一个负责"真正的重活" | 判定逻辑（快、便宜）与执行逻辑（慢、贵）分开，后者可以换实现不改编排 |
| **跨项目 / 跨团队** | 平台团队提供通用 trigger，业务仓库只写 build config | 通用逻辑集中维护；子 build 甚至可以跑在**另一个项目**（需要父 build 的 SA 有权限） |

★ 反过来，**不该拆**的情况：
只是"步骤多了一点" → **一个 build 多几个 step** 就行（你们现在的形态）；
只是想"让报告好看点" → 拆了只会让 report 更难合并。

---

## 4. ★ 放进你们的场景：三种形态的时序图

### 4.1 形态一 · 你们现在的样子（单 build，**推荐保持**）

（这就是 [`pull-report-bot-flow.md`](pull-report-bot-flow.md) `2 的原图，逻辑不变）

```
 开发者        GitHub           webhook/中转       Cloud Build(GCP)      pull-report-bot
   │            │                   │                    │                   │
   │ 提 PR      │                   │                    │                   │
   ├───────────▶│                   │                    │                   │
   │            │ ① pull_request   │                    │                   │
   │            ├──────────────────▶│                    │                   │
   │            │                   │ ② 提取 PR 信息    │                   │
   │            │                   │ ③ 触发 build      │                   │
   │            │                   ├───────────────────▶│                   │
   │            │                   │                    │ ④ 同一个 build 内 │
   │            │                   │                    │   · YAML 校验     │
   │            │                   │                    │   · bash -n       │
   │            │                   │                    │   · helm lint     │
   │            │                   │                    │   · helm template │
   │            │                   │                    │   · report        │
   │            │                   │ ⑤ 拉结果          │                   │
   │            │                   │◀───────────────────┤                   │
   │            │                   │ ⑥ 渲染 report     │                   │
   │            │ ⑦ POST comment    │                    │                   │
   │            │◀───────────────────────────────────────────────────────┤
   │ ⑧ 看到 report                    │                    │                   │
```

★ **只有一个 build**：report 就是这一个 build 的自然产物，天然完整、天然一条评论、不会有"谁先谁后"的问题。

### 4.2 形态二 · 拆成 parent + child（**扇出型**）

```
 开发者        GitHub           webhook/中转       Cloud Build(GCP)              pull-report-bot
   │            │                   │                    │                          │
   │ 提 PR      │                   │                    │                          │
   ├───────────▶│                   │                    │                          │
   │            │ ① pull_request   │                    │                          │
   │            ├──────────────────▶│                    │                          │
   │            │                   │ ② 触发 build      │                          │
   │            │                   ├───────────────────▶│                          │
   │            │                   │                    │  PARENT BUILD (编排)      │
   │            │                   │                    │  ├─ 判定：要不要跑、跑什么 │
   │            │                   │                    │  ├─ run child trigger ×N  │
   │            │                   │                    │  │    ├─▶ CHILD 1: YAML   │
   │            │                   │                    │  │    ├─▶ CHILD 2: Shell  │
   │            │                   │                    │  │    └─▶ CHILD 3: Helm   │
   │            │                   │                    │  └─ 汇总各 child 结果    │
   │            │                   │                    │      → 渲染 report        │
   │            │ ⑦ POST comment    │                    │                          │
   │            │◀─────────────────────────────────────────────────────────────────────┤
   │ ⑧ 看到 report                    │                    │                          │
```

★ **父 build 要额外做三件事**（这就是拆开的代价）：
1. **等所有 child 跑完**（轮询 `gcloud builds list` 或用 API 查）—— 父不能提前结束，
   否则你拿不全结果。
2. **合并多个 child 的结果**成一份 report（谁写这个合并逻辑，就是新的复杂度）。
3. **决定 child 的参数**（哪些文件、哪个 chart）并显式传下去。

★ 好处：每个检查项**独立超时、独立失败**，一个 Helm 检查卡住不会拖垮 YAML 检查；
而且每个 child 在控制台里是一条独立记录，排查时能直接点进去看。

### 4.3 形态三 · parent + child（**环境晋级型**）

```
  PR 事件 ──▶ PARENT BUILD: 跑校验（YAML/Shell/Helm）→ report 回填 PR
                    │  (成功才继续)
                    ▼  run child trigger
                CHILD BUILD: 构建镜像 + 部署到 staging
                    │  (成功 + 人工确认)
                    ▼  run child trigger
                CHILD BUILD: 部署到 prod
```

★ 这个形态里，"PR 校验"就是 parent，"部署"就是 child。
好处是**"校验不过就不可能部署"这件事由 build 层级保证**，而不是靠谁的判断。

---

## 5. 真要拆的话，怎么做（可操作）

### 5.1 建一个专用的 child trigger

```bash
gcloud builds triggers create github \
  --name=child-helm-validate \
  --repository=projects/PROJECT/locations/REGION/connections/CONN/repositories/REPO \
  --branch-pattern=".*" \
  --build-config=ci-simulation/trigger/child-helm.yaml \
  --region=REGION \
  --substitutions=_ROLE=child
```

★ child trigger 的分支条件可以放宽（`.*`），因为"要不要跑"由父 build 决定。

### 5.2 父 build 里 run 它

```yaml
# 父 build config 里的一个 step
- name: 'gcr.io/google.com/cloudsdktool/cloud-sdk:slim'
  id: 'fan-out'
  entrypoint: bash
  args:
    - -c
    - |
        set -uo pipefail
        gcloud builds triggers run child-helm-validate \
          --region=REGION \
          --project=PROJECT_ID \
          --substitutions=_PR_NUMBER=$_PR_NUMBER,_SHA=$COMMIT_SHA
          # ★ CLI 的 --substitutions 最终落到 API 的 RepoSource.substitutions
          #   （官方描述：Should only be used with RunBuildTrigger）
  env:
    - 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
  waitFor: ['checks-done']
```

### 5.3 三个必须注意的点

| # | 点 | 说明 |
|---|---|---|
| 1 | **权限** | 父 build 的**服务账号**要能在目标项目里"run trigger"（`roles/cloudbuild.builds.editor` 级别）。父 SA 权限不够 → 子构建根本起不来，报的是 403。 |
| 2 | **参数传递** | 子构建**不会自动继承**父 build 的全部环境变量；要么用 `--substitutions` 显式传，要么在子 build 里自己重新查 PR 状态。 |
| 3 | **等待与合并** | 父 build 结束前要把 child 的结果收齐并合并；否则 report 会缺项。 |

---

## 6. 父子 vs 多 step vs 多 trigger（选型表）

| | 一个 build 多 step（你们现在） | parent + child | 多个独立 trigger |
|---|---|---|---|
| 触发一次事件产生几个 build | 1 | 1 + N | N |
| 报告怎么来 | **一个 build 一个 report，最简单** | 要**自己合并 N 份结果** | N 个 build 要自己汇总 |
| 某一步卡住 | 整个 build 卡住 | 只影响那一个 child | 同左 |
| 独立超时/重试 | ❌ | ✅ 每个 child 各自 | ✅ |
| 参数传递 | 同一进程内，最直接 | 要显式设计 | 各 trigger 自己带 |
| 控制台可读性 | 一个 build，步骤列表 | 父子层级，一眼看清 | 平级多个 |
| 适合 | **步骤不多、彼此有依赖** | **扇出 / 环境晋级 / 跨项目** | 多条互不相干的流水线 |

★ **给你们的结论**：
当前"3 个校验 + 1 个 report"是**典型的"一个 build 多 step"**场景，**不要拆**。
等到出现下面任一情况再考虑拆：
① 某个检查要跑很久（>10 分钟），拖慢其他检查；
② 要按仓库/模块跑不同的检查集合（扇出）；
③ 校验通过后还要往下走一条部署流水线（环境晋级）。

---

## 7. 坑

1. ★ **`gcloud builds submit` ≠ child build**：
   用它产生的 build **没有父**，控制台不显示层级，"父失败子不跑"这类语义也没有。
2. **父 build 提前结束 → 子结果收不齐**：
   父是"触发 + 汇总"的角色，**必须等 child 结束**再出 report。
3. **父 SA 权限不足** → 子构建起不来（403），但父本身是绿的 → 看起来"成功但没结果"。
4. **多次 push → 父子树会重复**：同一个 PR 连续 push 两次 → 两棵父子树并行跑，
   老的可能后完成 → 覆盖新结果（和 [`pull-report-bot-flow.md`](pull-report-bot-flow.md) 里的并发坑同源）。
5. **计费与配额**：每个 build 都独立算 VM、算超时、算配额。拆成 4 个 build = 4 份开销。
6. **日志散落**：排查一个"到底哪一步失败"的问题，要在父子两层里跳。
7. **父 build 失败时子 build 是否被抑制**：本次联网核实**没有找到官方文档页**
   （历史上的 `/build/docs/automating-builds/child-builds` 现已 404，
   当前 Cloud Build 文档导航里也没有 child build 专页）；
   而 v1 API 的 Build 资源里也**没有父子字段**，只有 `buildTriggerId`。
   → **结论：这条语义属于控制台行为，必须在你们环境里实测**。
   **验证方法**：故意让父 build 失败一次，看子 build 有没有被创建/执行，把结果记下来。
   （如果父失败也会跑子，那"前置条件"就得由父在**代码里显式判断**再决定要不要 run child。）
   ★ **无论实测结果如何，都建议在父 build 里显式判断**——不要把关键门禁寄托在未文档化的行为上。

---

## 8. 验证清单

```bash
# 1. 看看有哪些 trigger（父子都是 trigger，父子关系不在这里体现）
gcloud builds triggers list --region=REGION

# 2. 跑一次 trigger（如果在 build 内部跑 → 就是 child）
gcloud builds triggers run TRIGGER_NAME --region=REGION --substitutions=_X=1

# 3. 看某次 build 的详情（关注 buildTriggerId / 是否有父）
gcloud builds describe BUILD_ID --region=REGION --format=yaml

# 4. 看最近哪些 build 失败了
gcloud builds list --region=REGION --filter="status=FAILURE" --limit=10
```

★ 控制台里看父子层级最快：
Builds 页面 → 点开某个 build → **Build history / 层级视图**（父子会缩进显示）。

---

## 9. ★ 本次联网核对的官方口径（清单）

| 官方来源 | 核对到的结论 |
|---|---|
| Cloud Build v1 API（`cloudbuild.googleapis.com/$discovery/rest?version=v1`） | `projects.triggers.run` = `POST v1/projects/{projectId}/locations/{region}/triggers/{triggerId}:run`；request body = **RepoSource**；`RepoSource.substitutions` = "Substitutions to use in a triggered build. Should only be used with RunBuildTrigger"；**Build 资源没有 parent/child 字段**，只有 `buildTriggerId` |
| `gcloud builds triggers run --help`（本机 526） | 参数：`--region` / `--substitutions` / `--branch` / `--sha` / `--tag` |
| Creating and managing build triggers（官方指南） | ① Git 仓库构建走 **shallow clone**：只 checkout 触发构建的那个 commit，**不检出其他分支和历史**；② 提交信息含 `[skip ci]` / `[ci skip]` → **不触发构建**，之后想跑要在 Triggers 页点 **Run**；③ **仓库改名后必须手动更新 trigger 里的仓库名**（Cloud Build 不会重定向） |
| Automate builds by using Cloud Build（官方 quickstart） | trigger 触发的构建所需 IAM：`roles/cloudbuild.builds.editor`、`roles/storage.objectUser`、`roles/storage.bucketViewer`、`roles/cloudbuild.connectionAdmin` |
| View build results for triggers（官方） | Trigger 详情页有 **Recent trigger status / Commit / Failed Step / Build history（最近 20 次柱状图）/ Average duration** |
| `/build/docs/automating-builds/child-builds` | **404**（历史页面已下线）→ 父子语义的权威依据目前只剩控制台行为 |

---

## 10. 交叉引用

- [`pull-report-bot-flow.md`](pull-report-bot-flow.md) —— 你们的全链路（本文第 4.1 节就是它的展开版）
- [`cloud-build-trigger-guide.md`](cloud-build-trigger-guide.md) —— Trigger 能做的 12 件事、字段速查
- [`github-webhook-deep-dive.md`](github-webhook-deep-dive.md) —— 事件怎么进到 Cloud Build
- [`trigger/`](trigger/README.md) —— 可落地模板（当前是"单 build 多 step"形态）
