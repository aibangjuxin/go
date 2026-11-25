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
## 8. ★ 本次演示的实测结果（PR #12）

```
① 提 PR              -> Actions 自动触发，Checks 标签下出现 3 条记录（pending -> pass）
② 故意推一个坏 YAML  -> "YAML 语法校验" 变 fail（红叉），另外两条仍然 pass
③ 修好再推          -> 三条全部 pass
```

也就是说：**红 -> 绿**这两态你都能在 PR 页面上直接看到，不需要连 Cloud Build。

### 顺便发现的一个坑：PR 显示 BLOCKED 不一定是"你的 check 红了"

本仓库 `main` 的 branch protection 里，required status check 是 `validate-ip`
（就是仓库原有的那个 workflow）。而它的触发条件是：

```yaml
on:
  pull_request:
    paths:
      - '**/api_list.yaml'      # ← 只有改了这个文件才会跑
```

所以**任何没改 api_list.yaml 的 PR，这个 required check 根本不会上报**，
GitHub 就会一直显示 `mergeStateStatus: BLOCKED` ——
**"check 从未上报" 和 "check 跑了但是红的"，在 PR 上长得一样。**

★ 由此得到一条硬规则：
> **要设成 required 的 check，必须保证它在"每一个 PR"上都会上报。**
> 否则 PR 会永远卡住，而且看不出是哪一步卡住的。
> （修法：让 workflow 无条件跑；或者别把它设成 required。）

### 把这三条 Check 变成硬门禁

```bash
# 先看清楚 main 现在要求哪些 check
gh api repos/aibangjuxin/go/branches/main/protection --jq '.required_status_checks'

# 加上这三条（注意名字要和 PR 上显示的一字不差）
gh api -X PUT repos/aibangjuxin/go/branches/main/protection \\
  -F 'required_status_checks[strict]=true' \\
  -F 'required_status_checks[contexts][]=validate-ip' \\
  -F 'required_status_checks[contexts][]=YAML 语法校验' \\
  -F 'required_status_checks[contexts][]=Shell / Python 语法校验' \\
  -F 'required_status_checks[contexts][]=示例清单结构自检' \\
  -F 'enforce_admins=true' \\
  -F 'required_pull_request_reviews[required_approving_review_count]=1' \\
  -F 'required_pull_request_reviews[dismiss_stale_reviews]=true'
```

> ⚠️ 改之前想清楚：这是 **仓库级策略**，会影响所有 PR（包括自动同步过来的那些）。
> 建议先在别的分支上试，或者等团队确认。

