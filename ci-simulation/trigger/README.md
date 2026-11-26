# trigger/ —— PR 校验 + 自动回填 report（可落地的模板）

> **它解决什么问题**
>
> 第一版的 CI：PR 提交后，GitHub 上出现几个 ✅（YAML 语法、Shell 语法、Helm 渲染），
> 但**看不到每一项的结论、没有失败详情、也没有跳转到 Cloud Build 的链接**。
>
> 这一版：在**同一个 Cloud Build trigger** 里加一层"加工"，
> 把每个 step 的结果收集成结构化数据 → 渲染成 markdown report → 幂等地贴回 PR →
> 并在 report 里给出 Cloud Build 控制台链接，形成闭环。
>
> 相关的概念篇：[`pull-report-bot-flow.md`](../pull-report-bot-flow.md)（全链路）
> Trigger 能做什么的完整梳理：[`cloud-build-trigger-guide.md`](../cloud-build-trigger-guide.md)

---

## 1. 目录结构

```
trigger/
├── README.md                    ← 你正在看的这份
├── cloudbuild.yaml              ← build config（6 个 step：装依赖 → 4 个校验 → report）
├── trigger-github-pr.yaml       ← 2nd gen GitHub App trigger 配置（PR 事件）
├── trigger-webhook.yaml         ← Webhook trigger 配置（自建中转那条路）
├── Makefile                     ← 本地演练：make demo / make list / make check
├── samples/                     ← 样例结果（本地看 report 长什么样）
└── scripts/
    ├── ci_step.sh               ← 校验 step 的统一包装器（★ 核心）
    ├── ci_result.py             ← 结果读写 + 红绿判定
    ├── render_report.py         ← 结果 JSON → markdown report
    ├── post_report.py           ← report 回填 PR（marker 幂等）
    ├── install_deps.sh          ← 幂等装 helm / pyyaml
    ├── lib_changed.sh           ← 算"本次 PR 改了哪些文件"
    └── checks/
        ├── yaml_syntax.sh
        ├── shell_syntax.sh
        ├── helm_lint.sh
        └── helm_template.sh
```

---

## 2. ★ 三个关键设计

### 2.1 校验失败**不中断**构建 → 才会有报告

Cloud Build 的 step 一旦返回非 0，**后续 step 不会执行**。
如果 YAML 校验直接 `exit 1`，那么"生成 report"那一步根本跑不到 → PR 上还是什么都没有。

所以：每个校验 step 都用 `ci_step.sh` 包一层，**它永远 exit 0**，
把真实退出码翻译成结构化结果：

```
命令退出码 0  → passed
命令退出码 77 → skipped（本次没有需要检查的文件）
其它          → failed
```

真正决定"这次 build 绿还是红"的，是**最后一个 report step**：
它汇总所有结果 → 渲染 → 回填 → 然后 `ci_result.py check`（有 failed 就 exit 1）。

★ 换句话说：**先出报告，再判红绿**。

### 2.2 report 用 marker 做幂等更新

每次 push 都会触发一次构建，如果每次都新建一条评论，PR 页面会被几十条 report 淹没。
所以评论正文里带一个隐藏 marker：

```markdown
<!-- pull-report-bot:report -->
```

`post_report.py` 先 `GET` 这个 PR 的评论列表找带 marker 的那条：
- 找到 → `PATCH`（更新）
- 没找到 → `POST`（新建）

### 2.3 只检查"本次改动的文件"

理由见 [`../demo/pr-check-actions/README.md`](../demo/pr-check-actions/README.md)：
全仓库扫描会让历史遗留错误**永远红**，久而久之大家就学会无视它 —— 这是 CI 最常见的死法。
`lib_changed.sh` 默认做增量（`git diff origin/$BASE_BRANCH...HEAD`），拿不到 base 时才退化成全量。

---

## 3. 跑起来看看（本地，不用 GCP）

```bash
cd ci-simulation/trigger
make demo     # 用样例结果渲染一份 report
make list     # 看每个 step 的结果
make check    # 判定红绿（有 failed 就 exit 1）
make post     # 演练回填（没 token 就只打印 payload）
```

`make demo` 输出的 report 就是最终贴到 PR 里的样子：

```markdown
<!-- pull-report-bot:report -->
## pull-report-bot · PR 123 校验报告

❌ **2 passed / 1 failed / 1 skipped** —— 有检查未通过

| 检查项 | 结果 | 耗时 | 说明 |
|---|---|---|---|
| YAML 语法校验 | ✅ passed | 0.6s | 3 个 YAML 文件语法通过（3 个文件） |
| Shell 语法校验 | ❌ failed | 0.3s | 1/2 个 shell 文件语法错误（2 个文件） |
| Helm lint | ⏭️ skipped | 0.1s | 本次没有 Helm chart 改动 |
| Helm 渲染 | ✅ passed | 2.4s | 1 个 chart 渲染成功（1 个文件） |

<details><summary>失败详情</summary>

**Shell 语法校验**

```bash
FAIL scripts/ops/deploy.sh
     scripts/ops/deploy.sh: line 18: syntax error near unexpected token 'fi'
```

</details>

<sub>仓库 `acme/platform` · 分支 `feat/example` → `main` · commit `1a2b3c4` · trigger `pr-validate-with-report`</sub>

🔗 [查看 Cloud Build 构建与完整日志](https://console.cloud.google.com/cloud-build/builds;region=us-central1/demo-build-id?project=acme-proj)
```

---

## 4. 落到你们环境（5 步）

### Step 1 · 把目录搬进目标仓库

把 `trigger/` 整个目录拷到你们仓库（下面假设放 `ci-simulation/trigger/`），
然后改 `cloudbuild.yaml` 里三处路径（都要带 `/workspace/` 前缀）：
- `RESULT_DIR=/workspace/ci-simulation/trigger/artifacts/results`
- `TOOLS_BIN_DIR=/workspace/ci-simulation/trigger/.tools/bin`
- `PYTHONPATH=/workspace/ci-simulation/trigger/.tools/py`

以及每个 step 的 `dir:`（相对 `/workspace`）。

### Step 2 · 建服务账号 + 授权

```bash
PROJECT_ID=your-project
SA=cloudbuild-pr@$PROJECT_ID.iam.gserviceaccount.com

gcloud iam service-accounts create $SA --display-name="Cloud Build PR 校验"

# 触发构建 + 读日志 + 存 artifact
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:$SA" \
  --role="roles/cloudbuild.builds.editor"
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:$SA" \
  --role="roles/logging.logWriter"
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:$SA" \
  --role="roles/storage.objectAdmin"        # 只有要存 artifact 才需要
```

★ **只有 trigger 上指定的 SA 会用于触发构建**；
build config 里写的 `serviceAccount` 在 trigger 场景下会被忽略。

### Step 3 · 放回填用的 token（Secret Manager）

```bash
printf '%s' "$YOUR_GITHUB_TOKEN" | gcloud secrets create github-pr-report-token --data-file=-
# 已经建过就加个版本：
printf '%s' "$YOUR_GITHUB_TOKEN" | gcloud secrets versions add github-pr-report-token --data-file=-

# 让 SA 能读这个 secret
gcloud secrets add-iam-policy-binding github-pr-report-token \
  --member="serviceAccount:cloudbuild-pr@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"
```

token 需要 `issues: write`（贴/改 PR 评论）权限。
如果你们用的是 GitHub App，就用 installation token（1h 过期，需要续期逻辑，见
[`../github-bot-principles.md`](../github-bot-principles.md)）。

### Step 4 · 建 GitHub 连接 + 建 trigger

```bash
# 4.1 建 GitHub 连接（Developer Connect，2nd gen 需要）
gcloud developer-connect connections create \
  --connection-connection-id=my-conn \
  --location=us-central1 \
  --github-repository-config="github.owner=YOUR_ORG,github.repositoryName=YOUR_REPO" \
  --service-account=projects/$PROJECT_ID/serviceAccounts/developer-connect@$PROJECT_ID.iam.gserviceaccount.com

# 4.2 建 trigger（build config 指向仓库里的路径）
gcloud builds triggers create github \
  --trigger-config=ci-simulation/trigger/trigger-github-pr.yaml \
  --region=us-central1
```

建之前要先把 `trigger-github-pr.yaml` 里的占位符换掉：
`YOUR_ORG` / `YOUR_REPO` / `installationId` / `CONNECTION_NAME` / `PROJECT_ID`。

### Step 5 · 把它设成 required check

1. 先提一个 PR，确认 PR 页面出现那条 check（名字就是 trigger 里的 build config 名）。
2. `gh api repos/OWNER/REPO/branches/main/protection` 看当前 required checks。
3. 把这条 check 加进 required status checks。
4. ★ **确认它在每一个 PR 上都会上报**（不要加 `paths` 过滤），否则 PR 会永远 BLOCKED。

---

## 5. 想再加工 report？改哪里

| 想做的事 | 改哪里 |
|---|---|
| 加一个新检查项 | 新建 `scripts/checks/xxx.sh` + 在 `cloudbuild.yaml` 里加一个 step |
| 改报告表格的样式 | `scripts/render_report.py` 的 `render()` |
| 换 bot 名字 | trigger 的 `substitutions._REPORT_BOT_NAME` |
| 换评论标记 | 环境变量 `REPORT_MARKER` |
| 把 report 存到 GCS | `cloudbuild.yaml` 的 `artifacts.objects` |
| 每个检查项单独出一条 check | 在 report step 里调 GitHub Check Runs API（`checks: write`） |

---

## 6. 已知边界

- **check 只有一条**（整个 build 一条），不是每个检查项一条。
  要"每个检查项一条 check"需要在 report step 里额外创建 Check Run。
- **并发**：同一个 PR 连续 push 两次会有两个 build 并行跑，老的可能后完成 → 覆盖新结果。
  稳妥做法：触发时带上 `head.sha`，回填前比对 PR 当前 sha，不一致就丢弃。
- **GHES**：把 `GITHUB_API` 改成 `https://ghe.example.com/api/v3`，
  并在 trigger 里用 `github.enterpriseConfigResourceName` 指向 GHES 连接。
