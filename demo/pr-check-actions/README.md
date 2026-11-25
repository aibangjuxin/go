# PR Checks —— 不接 Cloud Build 也能跑通"PR → Check"

这个目录演示的是 **PR 门禁这件事本身**，而不是 Cloud Build。

## 一句话

> PR 开了 → GitHub Actions 自动跑 → 每个 job 结束在 PR 的 **Checks** 标签下变成一条记录 →
> 把这些记录设成 **required status check** → 不绿就不让合并。

**Cloud Build 只是执行器之一**：
分支 [feat/shared-ci-test](../../ci-simulation/README.md) 用的是另一个执行器（Cloud Build + trigger），
两者在 PR 上产生的东西**长得一模一样**（都是一条 Check）。

| | GitHub Actions（本目录） | Cloud Build（另一个分支） |
| :--- | :--- | :--- |
| 谁来触发 | Actions（GitHub 原生） | Cloud Build trigger（pull_request 事件） |
| 在哪跑 | GitHub 托管 runner | GCP 的临时 VM |
| **PR 上产生几条 Check** | **每个 job 一条**（这里 3 条） | **一次 build 一条** |
| 失败怎么变红 | job 退出码非 0 | build 状态 FAILURE |
| 要不要连 GCP | **不要** | 要（装 GitHub App + 建 trigger） |

## 本目录有什么

```
.github/workflows/pr-checks.yml     # 三个 job = PR 上的三条 Check
demo/pr-check-actions/
├── README.md                       # 就是你正在看的这份
└── yaml-samples/                   # 被校验的示例清单
    ├── k8s-deployment.yaml
    ├── helm-values.yaml
    └── github-workflow.yml
```

## 三个 job 分别干什么

| Job | Check 名字 | 检查什么 | 用到什么工具 |
| :--- | :--- | :--- | :--- |
| ① | YAML 语法校验 | **本次改动里**的 `*.yml` / `*.yaml` 能不能被解析 | ruby 标准库（runner 自带） |
| ② | Shell / Python 语法校验 | **本次改动里**的 `bash -n` 检 shell、`py_compile` 检 python | bash / python3（runner 自带） |
| ③ | 示例清单结构自检 | 示例 K8s 清单有没有 apiVersion / kind / metadata.name | ruby 标准库 |

★ **全程零第三方依赖**：不装 marketplace action、不起容器、不连 GCP、不下载任何东西。
需要装东西的场景（要 helm、要 python 依赖）才用 Cloud Build 那种"自己装依赖"的执行器。

## 为什么是"增量检查"

只检查**本次 PR 改动的文件**，不去翻历史文件的旧账。

原因很实在：本仓库的 `base/git.sh` 里有一个**真实的 bash 语法错误**
（第 18 行的 `if` 少了 `fi`），
如果做全仓库扫描，这条 Check 会**永远红**，久而久之大家就只会无视它 —— 这正是 CI 最常见的死法。

★ 增量检查的代价：历史遗留的问题不会被自动发现。
所以"历史问题"要单独开一个 PR 修（本仓库那个 `base/git.sh` 就是该单独修的）。

## 本地怎么复现（不用 Actions）

```bash
# 先算出"本次改动的文件"
git diff --name-only --diff-filter=ACMR origin/main...HEAD > /tmp/changed.txt

# ① YAML 语法（顺便跳过 Helm 模板）
ruby -ryaml -e '
  files = File.readlines("/tmp/changed.txt").map(&:strip)
          .select { |f| f.end_with?(".yml", ".yaml") }
          .reject { |f| f.include?("/templates/") }
  files.each { |f| YAML.parse_file(f); puts "OK #{f}" }
'

# ② Shell / Python 语法
for f in $(grep -E '\.sh$' /tmp/changed.txt); do bash -n "$f"; done
for f in $(grep -E '\.py$' /tmp/changed.txt); do python3 -m py_compile "$f"; done

# ③ 清单结构
ruby -ryaml -e 'YAML.load_file("demo/pr-check-actions/yaml-samples/k8s-deployment.yaml")'
```

> ★ 这就是"**本地和 CI 跑同一套检查**"的价值：
> 评审人在本地就能复现 CI 的判定，不用等 CI 跑完才知道哪里错。

## 怎么让它变红（演示失败长什么样）

任选一处改坏，然后 push：

| 改哪里 | 哪条 Check 会红 |
| :--- | :--- |
| 在 `demo/pr-check-actions/yaml-samples/` 里加一个缩进写错的 `*.yaml` | ① YAML 语法校验 |
| 删掉 `k8s-deployment.yaml` 里的 `metadata.name` | ③ 示例清单结构自检 |
| 在任意 `*.sh` 里写一句语法错的 shell | ② Shell / Python 语法校验 |

## 一个已知边界

**Helm 模板（`{{ .Values.x }}`）不能用普通 YAML parser 校验** ——
它不是合法 YAML。这类文件要用 `helm lint` / `helm template` 校验，
这正是"要装依赖时改用 Cloud Build 执行器"的典型场景。

## 怎么把它变成硬门禁

PR 页面 → **Checks** 标签 → 记下 Check 名字（`gh pr checks <PR>` 也能看到）→
Settings → Branches → Branch protection rules → 对 `main` 勾 **Require status checks to pass** →
把三条 Check 勾上。之后 **Check 不绿就合不进去**。
