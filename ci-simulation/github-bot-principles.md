# GitHub Bot 概念梳理 —— "Bot" 到底是什么、和 GitHub App 的区别、怎么加、背后原理

> 关联阅读：本文与 `ci-simulation/openshift-ci-prow-enterprise.md`（GitHub App 剖解）、
> `ci-simulation/ci-simulation-enterprise.md`（GHES 上的 PR 门禁）、
> `cr-check/`（本仓库的 Go 实现，已经在用 GitHub App 鉴权）是同一条线索上的三块拼图。

---

## 0. TL;DR（先看这 8 条）

1. **"Bot" 不是 GitHub 上的一等公民**，它只是口语统称，底层实际是三种不同的东西：
   **bot user（机器账号）**、**GitHub App**、**GitHub Actions 内置身份**。
2. 你在 `Settings → Collaborators and teams` 里看到的 `pull-report-bot`，是**第一种**：
   一个真实的 GitHub 用户账号，被你邀请成了仓库 collaborator，role 选 write。
3. **给 role ≠ 给权限给"服务"**。role 给的是"这个账号"，账号背后握着的凭据才是服务真正用的东西
   （一般是 PAT，fine-grained 或 classic）。
4. **GitHub App 走的是完全不同的入口**：`Settings → Developer settings → GitHub Apps`，装到 org/repo，
   **不能被"邀请为 collaborator"**。App 身份显示成 `your-app[bot]`。
5. App 的权限是**细粒度**的（`pull_requests: write`、`checks: write`、`contents: read`…），
   不是 Read/Write/Maintain/Admin 这种粗粒度角色。
6. App 的凭据链是：**App ID + PEM 私钥 → 签 JWT → 换 installation token（有效期 1 小时）→ 调 API**。
   cr-check 里的 `internal/gh/client.go` 已经在干这件事（用 `ghinstallation` 自动续期）。
7. App 还能**被 webhook 推送事件**（`pull_request`、`check_run`…），bot user 只能轮询。
8. 企业规范：**CI / 报告类机器人一律用 GitHub App**，禁止个人 PAT；权限最小化，token 不落盘。

---

## 1. 先把名词掰开：GitHub 上到底有几种"机器人"

| 你看到的名字 | 真实身份 | 归属 | 权限授予方式 | 凭据 |
|---|---|---|---|---|
| `pull-report-bot`（被加进 collaborator 的） | **bot user（机器账号）** | 一个真实 user account | Settings → Collaborators and teams → 加人 + 选 role | PAT / SSH Key |
| `dependabot[bot]`、`renovate[bot]` | bot user（老派）**或** App（新版） | 同上 | 同上 / Install App | PAT / App token |
| `my-report-app[bot]` | **GitHub App installation** | App 本体 | Install App 到 org/repo + 勾 permission | installation token |
| `github-actions[bot]` | **Actions 内置身份** | GitHub 平台 | 仓库自带，无需授权 | workflow 里自动注入的 `GITHUB_TOKEN` |
| `ci-runner[bot]`（自建 Actions runner） | GitHub Actions 身份 | 平台 | 同上 | `GITHUB_TOKEN` |

**一句话区分法：**

- 名字**不带方括号**、能在 `Settings → Collaborators` 里被邀请 → **bot user**。
- 名字**带 `[bot]` 且出现在仓库 Settings → Apps 列表里** → **GitHub App**。

> ⚠️ 注意：App 身份**不能**通过 collaborator 邀请来授权。你在 collaborator 列表里找不到 `xxx[bot]`，
> 因为 App 的权限模型是"安装 + 授权 permission"，不是"邀请 + 给 role"。
> 如果一个 PR 里要求你"授权某个 bot"，先确认它到底是 user 还是 App：
> 点它头像 → 是不是 App 页面的 App 卡片；或者直接看仓库 `Settings → Apps`。

---

## 2. 你遇到的场景，逐字拆解

> "PR 里会添加一个 Bot，我需要去 Settings → Collaborators and teams 找到它，给它 write 权限，
> 它就能把我的报告贴到 PR 上。"

这句话背后发生了 5 件事：

### 2.1 这个 bot 是一个 GitHub 用户账号

`pull-report-bot` 注册时用了某个邮箱（常常是 `<id>+pull-report-bot@users.noreply.github.com`）。
GitHub 上**机器账号和人账号没有类型上的区别**，只有命名约定。

### 2.2 你把它邀请进仓库

`Settings → Collaborators and teams → Add people → 输入 bot 用户名 → 选 role → Add`。

- role 档位：`Read` / `Triage` / `Write` / `Maintain` / `Admin`。
- **Write 意味着**：可以 push 分支、建 PR、开 issue、写评论、改标签、**触发 workflow**（workflow 权限跟着写权限走）。
- bot 必须**接受邀请**才生效（bot 账号也得有邮箱去收邀请）；如果它是通过 PAT 自动化点的确认，会很快。

### 2.3 role 到底授给了谁？

给了 **`pull-report-bot` 这个 user**。GitHub 内部就是往仓库的 collaborator 列表加一行：
`{user_id: pull-report-bot, role: write}`。

### 2.4 bot 背后那台服务拿什么说话？

它手里有 **PAT**。两种：

| | classic PAT | fine-grained PAT |
|---|---|---|
| 归属 | 一个 user | 一个 user + 一批 repo |
| 权限粒度 | 粗（`repo`、`write:discussion`…） | 细（逐 permission 勾） |
| 有效期 | 可设，但常"永不过期" | 可强制过期（最长 1 年） |
| 推荐度 | ❌ 别用 | ✅ 用这个 |

调用时：`Authorization: Bearer ghp_xxx`（或 `github_pat_xxx`）。
**GitHub 看到 token 属于哪个 user，就把操作审计记到那个 user 名下** → PR 上评论显示为 `pull-report-bot`。

### 2.5 它怎么把报告贴到 PR？

GitHub 的 PR 评论其实是 **issue comment**：

```
POST /repos/{owner}/{repo}/issues/{pr_number}/comments
{"body": "## 报告内容 ..."}
```

所以只需要 `issues: write` 就能贴（老式 PAT 是 `repo` 或 `public_repo` scope；fine-grained 是
`Issues → Read and write`，或 `Pull requests → Read and write` 也行）。

---

## 3. Bot user 与 GitHub App 的本质区别

| 维度 | bot user + collaborator role | GitHub App |
|---|---|---|
| 本质 | 一个**人账号**，权限来自 collaborator role | 一个**应用身份**，权限来自 permission 勾选 |
| 加入方式 | 邀请（需接受） | Install App（一次性授权，立即生效） |
| 权限粒度 | 5 档粗角色（Read→Admin） | 几十项细 permission（contents、checks、pull_requests、statuses、deployments…） |
| 多仓库 | 一个一个 repo 邀请 | 装到 org，可选 All repos / Selected repos，之后**批量改** |
| 凭据 | PAT（长期） | **installation token（1 小时有效，现签现用）** |
| 事件推送 | ❌ 只能轮询 API | ✅ webhook（pull_request、check_run、installation…） |
| 审计归属 | 那个 user 名下（看起来像个人干的） | **App 名下**（`my-app[bot]`），能区分是谁的锅 |
| 撤权粒度 | 改 role | 卸载 App = 所有 repo 的 token 立刻失效 |
| 能否被当人 review | ✅ 可以（也占 approve 配额） | ❌ App 自动 approve 会被 branch protection 拒 |
| 能否代表你 commit | ✅（配 SSH key） | ✅（contents: write + 走 App token） |
| 组织策略 | 常被"禁止第三方 PAT / 禁止外部协作者"打断 | 天然合规，App 由 org 批准 |
| 适合场景 | 少量仓库、老脚本、个人工具 | **CI、多仓库、组织级服务（正解）** |

**再补一句 GitHub 官方态度**：GitHub 现在的新官方 bot（Dependabot、CodeQL、Actions）都往 App 迁移，
因为 App 能做到"安装即可用 + 权限可审计 + 令牌自动过期"。老 bot user 只是历史包袱。

---

## 4. 背后的原理：GitHub 的身份与鉴权三层

### 4.1 三层结构

```
用户身份层    user account  (人 / bot user / GitHub 的系统账号)
应用身份层    GitHub App    (app-slug[bot])  —— 不属于任何人，属于"应用"
令牌层        token         (PAT / installation token / GITHUB_TOKEN)
```

所有 API 调用最终只认 **token**。token 决定"你能不能做这件事"和"这次操作记在谁名下"。

### 4.2 链路 A —— bot user 走 PAT

```
bot 服务 ──Bearer PAT──▶ api.github.com
                          └─ token → 解析出 user = pull-report-bot
                             └─ 查该 user 在 repo 的 role（write）→ 放行
```

- **role 是仓库侧的 ACL**，token 只是"我是我"的证明。
- 所以"给它 write" = 在该 repo 的 ACL 里给它 write。**换到别的 repo 就没有权限**，除非再邀请一次。

### 4.3 链路 B —— GitHub App 换 installation token（三步握手）

```
① App 私钥(PEM) + App ID ──签 JWT(RS256, exp≤10min)──▶
② POST /app/installations/{installation_id}/access_tokens  (带 JWT)
   ◀── installation_access_token (ghs_xxx, 有效期 1h, 权限 = 安装授权 ∩ 仓库允许)
③ 用 ghs_xxx 调 API ──▶ 身份 = my-app[bot]
```

**JWT payload 长这样：**

```json
{ "iat": 1700000000, "exp": 1700000600, "iss": "123456" }   // iss = App ID
```

**三个关键点：**

1. JWT 只证明"我是这个 App"，**不携带仓库权限**。
2. installation token 的权限 = **安装时勾的 permission ∩ 仓库当前的分支/环境限制**。
   所以"App 申请 contents: write" ≠ "一定能 push"（受 branch protection / rulesets 约束）。
3. token 1 小时过期 → 客户端要么缓存续期（`ghinstallation` 自动做），要么每次现签。

**cr-check 里已经封装好了：**

```go
// cr-check/internal/gh/client.go
tr, err := ghinstallation.NewKeyFromFile(nil, f.appID, installationID, f.privateKeyPath)
// ghinstallation 内部完成 JWT → installation token 的换取与 1h 过期续期
c := gogithub.NewClient(&http.Client{Transport: tr})
```

这就是为什么 cr-check 不需要任何 PAT —— 全部靠 App 的 `installation_id`（从 webhook payload 里取）。

### 4.4 webhook 的原理

- App 设置里配 `Webhook URL` + `Webhook secret`。
- 事件发生时 GitHub **POST** 一个 JSON 到你的 URL，头里带：
  - `X-GitHub-Event: pull_request`
  - `X-GitHub-Delivery: <uuid>`（幂等键）
  - `X-Hub-Signature-256: sha256=<hmac>`
- **必须校验签名**：用 secret 对**原始 body** 做 HMAC-SHA256，比对 header；不一致直接丢弃。
  （这就是 `cr-check/internal/webhook/handler.go` 在做的事。）
- `pull_request` 事件 payload 里带 `installation.id` → 你的服务据此换 token 操作那个仓库。

### 4.5 为什么 bot 的评论能出现在 PR 上

评论、review、check 都是"以某个身份写下的普通 API 写入"，GitHub 只关心 token 的权限够不够。
bot 没有特殊通道；它写出的 comment 在页面上就是一条普通 comment（作者显示为 bot）。

---

## 5. 怎么添加一个 Bot —— 三条路线

### 路线 A：接一个现成的 bot user（你现在的做法）

1. `Settings → Collaborators and teams → Add people`
2. 填 bot 用户名 → 选 role（报告类用 `Write` 就够；要它 push 报告文件才需要写权限）
3. `Add` → bot 接受邀请
4. ⚠️ 如果组织开了"限制邀请外部协作者 / 只能邀请 org 成员"，这一步会失败。

**什么时候这条路是对的**：bot 是**别人已经写好的服务**（第三方 SaaS 或公司内部已有工具），你只是启用它。

### 路线 B：自己注册一个 bot user（不推荐但最省事）

1. 注册 GitHub 账号（用 `+alias@users.noreply.github.com` 这类独立邮箱）
2. 建 **fine-grained PAT**：限定仓库 + 勾 `Pull requests: Read and write` / `Issues: Read and write` / `Metadata: Read`
3. 服务里带上这个 PAT 调 API
4. 要它 commit 的话再加 SSH key 到该账号

**为什么不推荐**：审计上永远显示成"某个个人账号"，人离职了权限还在，token 难管。
企业仓库里通常还会被安全策略直接禁止。

### 路线 C：建一个 GitHub App（★ 正解，也是"Bot 的标准形态"）

**Step 1｜创建 App**

`Settings → Developer settings → GitHub Apps → New GitHub App`

| 表单项 | 怎么填 | 说明 |
|---|---|---|
| App name | `pull-report-bot` | 全局唯一，只能小写连字符 |
| Homepage / Description | 你的服务地址 | 必填 |
| Webhook URL | `https://your-svc/hooks/github` | 收事件；本地调试可用隧道 |
| Webhook secret | 随机 32 字节 | **用来验签，别泄露** |
| Permissions → Repository permissions | 见下方速查表 | 只勾要用的 |
| Subscribe to events | `Pull request`、`Check run`（可选） | 或 "Only send me specific events" |
| Where can it be installed? | `Only on your account` / `Only on organizations` | |
| Expiration | 有效期（最长 12 个月） | 到期要续，不然全挂 |

**Step 2｜生成私钥**

`Generate a private key` → 下载 `*.pem`（**只能下载一次**），连同
`App ID`、`Client ID`、`Client secret` 一起存进 K8s Secret / Vault。

**Step 3｜安装到仓库**

- App 页面 → `Install App` → 选 org → 选 `Only select repositories` → 勾目标 repo
- 安装后页面会显示 **Installation ID**（一串数字）→ 这就是换 token 要用的那个 ID
- 也可以在 `Settings → Apps` 里看到它，点 `Configure` 能**改权限 / 增删仓库**，比 collaborator 方便得多

**Step 4｜拿 token 跑起来**

```bash
# ① 用私钥签 JWT（生产请用代码，别手搓）
JWT=$(<用 openssl 或代码生成，iss=AppID, exp=now+600>)

# ② 换 installation token
curl -s -X POST \
  -H "Authorization: Bearer $JWT" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/app/installations/$INSTALLATION_ID/access_tokens
# → { "token": "ghs_xxx", "expires_at": "...", "permissions": {...} }

# ③ 用它贴 PR 评论
curl -s -X POST \
  -H "Authorization: Bearer ghs_xxx" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/OWNER/REPO/issues/123/comments \
  -d '{"body":"## 报告"}'
```

**Go 里怎么写（cr-check 已有的写法）**

```go
import (
    "github.com/bradleyfalzon/ghinstallation/v2"
    gogithub "github.com/google/go-github/v88/github"
)

// installationID 来自 webhook payload 的 installation.id
tr, err := ghinstallation.NewKeyFromFile(nil, appID, installationID, "/etc/secrets/app.pem")
if err != nil { return err }
client := gogithub.NewClient(&http.Client{Transport: tr})

// 贴评论（PR 评论走 issue comment API）
_, _, err = client.Issues.CreateComment(ctx, "OWNER", "REPO", prNumber, &gogithub.IssueComment{
    Body: gogithub.String("## 报告\n..."),
})
```

> `ghinstallation` 的价值：自动缓存 installation token 并在 1h 过期前换新，你不用自己管过期时间。

**Step 5｜验证清单**

```
□ App 已 install 到目标 repo（Settings → Apps 能看到）
□ 勾的 permission 足够（发评论 = Issues/Pull requests: write）
□ webhook 收到的 body 验签通过
□ payload 里拿到 installation.id
□ 用 installation token 调 /user 确认返回类型是 "Bot" 且 app_slug 正确
□ token 过期行为已验证（等 1h 或手动 revoke）
□ 私钥在 K8s Secret 里，代码和日志都不落明文
```

---

## 6. 权限速查表（报告类 bot 的最小权限）

| 想做的事 | App Permission | 备注 |
|---|---|---|
| 读 PR 内容/分支/代码 | `Contents: Read`、`Pull requests: Read` | Metadata 默认只读且必选 |
| 在 PR 里贴报告 | `Issues: Read & write` 或 `Pull requests: Read & write` | PR 评论走 issues API |
| 上报 check / 门禁 | `Checks: Read & write` | cr-check 的核心 |
| 上报 commit status | `Statuses: Read & write` | 老的 status API |
| 提交/推送代码 | `Contents: Read & write` | 还要能过 branch protection |
| 创建 PR / 改分支 | `Pull requests: Read & write` | |
| 读组织成员 | `Members: Read` | |
| 部署 | `Deployments: Read & write` | |

> **反模式**：报告类 bot 只要"读代码 + 写评论"，却申请了 `contents: write`。
> 权限要按"最小可用"给，App 权限是它的**上限**，不是它想干什么就干什么。

---

## 7. 企业规范建议（可以直接抄进团队 wiki）

1. **CI / 机器人一律 GitHub App**，禁止用个人 PAT 跑流水线。
2. App 权限最小化；报告类 bot 不给 `contents: write`。
3. `installation token` 只在内存里用，**不写磁盘、不进日志**（日志里打前 6 位即可）。
4. Webhook **必须验签**（HMAC-SHA256，常量时间比较）。
5. 定期在 `Settings → Developer settings → GitHub Apps` 巡检：
   哪些 App 装在 org 上、装在哪些 repo、权限多大、有没有孤儿安装。
6. App 的 private key 要能轮换；写进 K8s Secret + 定期换。
7. `dependabot`/`renovate` 这类第三方 bot 也要登记台账。

---

## 8. 常见误区 Q&A

**Q：Bot 的 PR 评论能自动 approve 吗？**

A：人账号型 bot 可以（还占 approve 配额）；App 型 bot 的自动 approve 会被 branch protection 拒
（GitHub 规定 App 不能满足 required review）。

**Q：我把 bot 从 collaborator 删了，它手里的 PAT 还能用吗？**

A：PAT 本身还有效，但 ACL 里没了 → 对该仓库的权限立即失效（这是"授权在仓库侧"的关键点）。

**Q：App 和 bot user 能同时用吗？**

A：能，但审计会很乱。建议新服务一律 App，老服务逐步迁移。

**Q：为什么我的 bot 收到 webhook 却没权限？**

A：九成是 **permission 勾少了**。App 的权限是"安装时授权"的上限，
去 `Settings → Apps → Configure` 补勾，不用重装。

**Q：GHES（企业版）上 App 在哪建？**

A：在**实例内部** `https://<your-ghe-host>/settings/developers` 建，不是在 github.com 建。
而且 GitHub.com 上的 App **装不到** GHES 上，两者体系独立。

**Q：App 需要公网入口吗？**

A：需要能被 GitHub 回调的 URL。内网场景用隧道 / ingress，
见 `ci-simulation/openshift-ci-prow-enterprise.md` 里 Prow 的做法。

---

## 9. 和本仓库已有内容的关系

| 已有文件 | 和本文的关系 |
|---|---|
| `ci-simulation/openshift-ci-prow-enterprise.md` | 讲的是 **App 侧**（Prow 作为 App 装到 org），本文补齐 **user 侧**（bot user 是什么） |
| `ci-simulation/ci-simulation-enterprise.md` | GHES 上的 PR 门禁链路，App 权限与 events 的落地 |
| `ci-simulation/ci-simulation-enterprise-cloud-build.md` | Cloud Build 如何上报 check |
| `cr-check/internal/gh/client.go` | **本仓库里 App 鉴权的真实代码**（JWT → installation token） |
| `cr-check/internal/webhook/handler.go` | webhook 验签 + 取 installation.id |
| `cr-check/internal/check/writer.go` | 用 installation token 上报 check（checks: write） |
| `demo/pr-check-actions/` | 不用 App 的最简替代方案（GitHub Actions 内置 GITHUB_TOKEN） |
