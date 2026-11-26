# ci-simulation —— 用 Cloud Build 给 PR 加 CI 门禁（最小可跑样例）

这个目录是 **一整套可运行的演示**：在 GitHub 上提一个 PR → Cloud Build 自动跑一遍这里的检查 →
PR 页面出现一条 **Check** → 设成 required 之后，红了就合不进去。

配套讲解文档（在另一个仓库）：
[how-to-pr-checks-with-cloud-build.md](https://github.com/aibangjuxin/knowledge/blob/main/gcp/gcp-cloud-build/how-to-pr-checks-with-cloud-build.md)

本目录相关的基础概念文档：
- [pull-report-bot-flow.md](pull-report-bot-flow.md) —— 企业内部 pull-report-bot 全链路：PR → webhook → Cloud Build → report
- [cloud-build-trigger-guide.md](cloud-build-trigger-guide.md) —— Cloud Build Trigger 深入：它到底能做什么
- [trigger/README.md](trigger/README.md) —— 可落地模板：PR 校验 + 自动回填 report（含脚本）
- [github-bot-principles.md](github-bot-principles.md) —— Bot / GitHub App 到底是什么、怎么加、背后原理
- [openshift-ci-prow-enterprise.md](openshift-ci-prow-enterprise.md) —— GitHub App 剖解 + GHES 上的 PR 门禁

---

## 1. 目录结构

```
ci-simulation/
├── Makefile                          # 统一入口：本地和 CI 跑的是同一条命令
├── ci-test.yaml                      # Cloud Build build config（trigger 指向它）
├── .gitignore
├── apps/foundation-apps.json         # "foundation apps" 输入清单
├── build/                            # 生成物（gitignore）
├── charts/ci-demo/                   # 最小 Helm chart（给 helm lint / template 用）
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/{configmap,service}.yaml
├── cluster/cluster-spec.json         # 集群规格（给 onboarding 测试用）
├── .tools/<os>-<arch>/bin/          # CI 装的工具（helm 等），按平台分目录（gitignore）
└── scripts/
    ├── utils/install_ci_dependencies.sh        # 幂等装 helm（落到 .tools）
    ├── utils/test_install_ci_dependencies.sh   # 断言"依赖装好了"
    ├── utils/prepare_foundation_apps.py        # 生成 build/foundation-apps.json
    ├── utils/test_prepare_foundation_apps.py   # 上面脚本的单测
    ├── 01-aoa-onboarding/test_checks.sh        # bash 断言组
    └── 02-cluster-onboarding/test_onboard_cluster.py  # 集群规格校验单测
```

## 2. 本地跑（不需要 GCP）

```bash
cd ci-simulation
make help
make test          # = test-helm + test-python + test-bash
```

单步跑：

```bash
make install-deps
make test-helm
make test-python
make test-bash
```

> ★ **本地和 CI 跑的是同一套命令**，这是这个样例最重要的设计：
> 评审人本地 `make test` 的结果，和 PR 上那条 Check 的结果**必须一致**。
> Makefile 是"CI 配置"和"检查逻辑"之间的解耦层。

## 3. 打通 GitHub → Cloud Build（一次性配置）

### 3.1 把仓库连到 Cloud Build

按 [how-to-github-trigger-cloud-build.md](https://github.com/aibangjuxin/knowledge/blob/main/gcp/gcp-cloud-build/how-to-github-trigger-cloud-build.md)
的 §4 / §5 走一遍（GitHub App 或 Developer Connect）。

### 3.2 建 PR trigger

```bash
gcloud builds triggers create github \
  --name=pr-ci-test \
  --region=asia-northeast1 \
  --repository=projects/<PROJECT_ID>/locations/asia-northeast1/connections/<CONN>/repositories/go \
  --pull-request-pattern='^main$' \
  --build-config=ci-simulation/ci-test.yaml \
  --service-account=projects/<PROJECT_ID>/serviceAccounts/gcb-ci@<PROJECT_ID>.iam.gserviceaccount.com \
  --comment-control=COMMENTS_DISABLED \
  --include-logs-with-status \
  --no-require-approval
```

> ★ 三个最容易踩的坑：
> 1. `--comment-control` **默认是 `COMMENTS_ENABLED`**，不显式写 `COMMENTS_DISABLED` 的话，
>    PR 开了也不会跑，必须有人敲 `/gcbrun`。
> 2. `--build-config` 的路径是**相对仓库根目录**的，所以是 `ci-simulation/ci-test.yaml`。
> 3. trigger 建好之后，**已经开着的 PR 不会自动补跑** —— 再 push 一个 commit（或关掉重开 PR）才会触发。

### 3.3 验证

```bash
# 提 PR 之后
gh pr checks <PR_NUMBER>

# 看 build
gcloud builds list --region=asia-northeast1 --limit=5
gcloud builds log <BUILD_ID> --region=asia-northeast1
```

## 4. ★ 实测踩过的 4 个坑（照抄 Cloud Build 的真实行为）

这四条都是在本机用 docker 按"每个 step 一个全新容器、共享 /workspace"的方式跑出来的，
**不照做，Cloud Build 上必挂**：

| # | 坑 | 现象 | 本仓库的解法 |
| :--- | :--- | :--- | :--- |
| 1 | **step 之间只有 /workspace 共享** | step1 用 apt-get 装的 `make`，step2 里 `make: command not found` | 工具装进 `.tools`；每个 step 的 `env` 显式把 `.tools/bin` 放进 `PATH` |
| 2 | **builder 镜像太干净** | `ubuntu:22.04` 里 make / curl / python3 一个都没有 | 改用 `python:3.11`（full）：自带 make / curl / python3 / git / tar |
| 3 | **curl 只在下载时需要** | 后续 step 里因为"没有 curl"直接失败 | 安装脚本改成：只有真的要下载 helm 时才检查 curl |
| 4 | **本地与 CI 抢同一个工具目录** | 本地 mac 装的 helm 被容器当成 linux 版执行 → exec format error | 工具目录按平台分：`.tools/<os>-<arch>/bin`；CI 用 `TOOLS_BIN_DIR` 固定成 `/workspace/ci-simulation/.tools/bin` |

## 5. 怎么"故意搞红"它

想看 Check 变红是什么效果，任选一处：

| 改哪里 | 会红在哪 |
| :--- | :--- |
| 把 `charts/ci-demo/templates/configmap.yaml` 写坏（比如 YAML 缩进错） | `test-helm` |
| 把 `apps/foundation-apps.json` 里的 `"syncPolicy"` 字段删掉 | `test-python` |
| 把 `cluster/cluster-spec.json` 里的 `requiredLabels` 删掉 | `test-python` + `test-bash` |
| 把 `scripts/01-aoa-onboarding/test_checks.sh` 里的断言改错 | `test-bash` |

改完 push，PR 上那条 Check 立刻变红，日志里能定位到失败在第几个 step。

## 6. 接入门禁（可选）

PR 页面 → **Checks** 标签 → 记下那条 check 的名字（`gh pr checks` 也能看到）→
仓库 Settings → Branches → Branch protection rules → 对 `main` 勾 **Require status checks to pass** →
把这条 check 勾上。此后 **Check 不绿就合不进去**。

> 本仓库 `main` 已经有 branch protection（required check = `validate-ip`、strict、1 个 review），
> 所以 **PR 现在还合不进去** —— 这正是"门禁"的样子。

## 7. 清理

```bash
make clean        # 删掉 build/ 和 .tools/
```

## 8. 配套文档（本地）

| 文档 | 讲什么 |
| :--- | :--- |
| [ci-simulation-enterprise.md](ci-simulation-enterprise.md) | 企业版（GHES）整体路线图：Actions 在 GHES 上的现实、路线 A 自研 App vs 路线 B 外部 CI |
| [ci-simulation-enterprise-cloud-build.md](ci-simulation-enterprise-cloud-build.md) | GHE × Cloud Build：把「PR → Check → 硬门禁」真正打通的工作分解（W1–W9） |
| [openshift-ci-prow-enterprise.md](openshift-ci-prow-enterprise.md) | OpenShift CI 的 GitHub App 剖解（源码可见性、为什么装了没反应）+ 自建 Prow 在 GHES 上的落地（★ 补上「GHES 没有 Actions」这个缺口） |
