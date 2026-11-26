# GitHub Webhook 深入 —— 原理、你们的实际链路、以及它和 App / Trigger 的关系

> **本文回答三个问题**
>
> 1. GitHub 仓库里配置的 **Webhook** 到底是怎么工作的？谁发、发给谁、带什么、失败怎么办？
> 2. 你们现在的链路（仓库 hooks → Cloud Build）**完整长什么样**？中间到底有没有 Cloud Run？
> 3. 它**不是 GitHub App**，那"App 型的 trigger"和"webhook 型的 trigger"到底差在哪、要不要换？
>
> 交叉阅读：[`github-bot-principles.md` `4.4](github-bot-principles.md)（Bot / App 原理）·
> [`pull-report-bot-flow.md`](pull-report-bot-flow.md)（你们的全链路）·
> [`cloud-build-trigger-guide.md`](cloud-build-trigger-guide.md)（Trigger 能做什么）·
> [`trigger/`](trigger/README.md)（可落地模板）

---

## 0. TL;DR

1. **仓库级 Webhook 确实不是 App**。它没有 installation、没有 permission、没有 token，
   只会"**把事件 POST 给你指定的 URL**"。想回写 PR，还得另外准备凭据（PAT / App token）。
2. **一次投递 = 一个普通 HTTP POST**：GitHub 把事件 JSON 推给你的 Payload URL，
   带上 `X-GitHub-Event` / `X-GitHub-Delivery` / `X-Hub-Signature-256` 等头。
3. **你的服务必须在 10 秒内返回 2xx**，否则 GitHub 判定投递失败（连接被掐断）。
4. **Cloud Build 的 webhook trigger 只是一个"接收器"**：它给你一个
   **URL（里面带 Cloud Build 生成的 API key + 你选的 secret）**，
   有人 POST 进来它就起一次构建。
5. ★ **webhook trigger 和 repository trigger 的关键差异**：
   **webhook trigger 不认识 GitHub**，所以**不会自动把 build 状态回写成 GitHub 的 check**；
   而 repository trigger（GitHub App 型）会。
   → **这正是"你们必须自己写 report 回 PR"的原因**：
   webhook 这条路上，没人替你回写。
6. ★ **官方建议**：要"仓库事件 → 构建"，优先用 **repository trigger（GitHub App 型）**；
   webhook trigger 更适合"非 GitHub 源"或"自己中转"。

---

## 1. 先把四个容易混的名字摆正

| 名字 | 在哪 | 是什么 | 有权限吗 |
|---|---|---|---|
| **仓库 Webhook**（本文主角） | GitHub：Settings → Webhooks | 一个"事件 → POST 到某个 URL"的配置 | ❌ 只送事件，不能读/写仓库 |
| **GitHub App 的 webhook** | GitHub：App 设置 → Webhooks | 同上，但属于某个 App 的安装 | ✅ App 有 permission，可换 installation token |
| **Cloud Build webhook trigger** | GCP：Triggers | 一个"收到 POST → 起一次构建"的接收器 | ✅ 用 GCP 服务账号身份跑构建 |
| **你们的中转服务（可能是 Cloud Run）** | 你们的代码 | 收事件 → 改参数 → 触发构建 → 回写 PR | ✅ 自己拿 token 去写 GitHub |

★ 你说"hooks 里配的就是连到我们 Cloud Run 的 trigger" —— 这句话有两种可能，**必须先分清**：

- **可能 A（直连）**：Payload URL = **Cloud Build 的 webhook trigger 地址**
  （`https://cloudbuild.googleapis.com/...`，不是 Cloud Run）。
- **可能 B（经中转）**：Payload URL = **你们自己 Cloud Run 服务的地址**，
  由它去调 `gcloud builds submit --trigger=...`。

两者的差别很大：
**A 里没有任何你们自己的服务**（所以"谁把 report 写回 PR"就成了必须在 build 里解决的事）；
**B 里 Cloud Run 就是那个"翻译 + 回写"的中枢**（这就是 pull-report-bot 的位置）。

★ 判定方法（30 秒）：
到 GitHub 仓库 Settings → Webhooks → 点开那条 webhook，看 **Payload URL 的域名**：
`cloudbuild.googleapis.com` → A；你们自己的域名 / `run.app` → B。

---

## 2. 仓库 Webhook 的配置项，逐个是什么意思

GitHub：仓库 → **Settings → Webhooks → Add webhook**

| 配置项 | 你会填什么 | 作用 | 坑 |
|---|---|---|---|
| **Payload URL** | 目标地址（Cloud Build trigger URL 或你们服务地址） | 事件往这儿 POST | ★ URL 本身带凭据时，**等于凭据泄露在 URL 里**（GitHub 官方明确警告不要在 URL 放敏感信息） |
| **Content type** | `application/json`（推荐） 或 `application/x-www-form-urlencoded` | 请求体格式 | 用 form-urlencoded 时，body 是 `payload=<urlencoded json>`，**验签要算在原始 body 上** |
| **Secret** | 一串随机字符串 | 用 HMAC 给每次投递签名 | 填了才有 `X-Hub-Signature-256` |
| **SSL verification** | 保持开启 | 校验目标证书 | 自签名证书要关掉（**别在公网这么干**） |
| **Which events** | "Just the push event" / "Send me everything" / 自选 | 订阅哪些事件 | ★ "Send me everything" 会把你不需要的事件也推过来，噪音大、容易误触发 |
| **Active** | 勾选框 | 关掉就不再投递 | 排查时的开关 |
| **Test / Ping / Redeliver** | 按钮 | 发一个 `ping` 事件验证连通；重投某次投递 | ping 事件要能正常返回 2xx |

---

## 3. ★ 一次投递的完整生命周期（原理核心）

```
① 事件发生
   例：有人 push / 提 PR
        │
② GitHub 组装投递
   · body   = 事件 JSON（pull_request 事件里含 action、PR、commit、仓库信息…）
   · headers= 见下表
        │
③ HTTP POST → Payload URL
   Content-Type: application/json
   X-GitHub-Event: pull_request          ← 事件类型
   X-GitHub-Delivery: 72d3162e-...       ← 本次投递的唯一 GUID（幂等键）
   X-GitHub-Hook-ID: 292430182          ← 哪条 webhook 配置发的
   X-GitHub-Hook-Installation-Target-Type: repository
   X-GitHub-Hook-Installation-Target-ID: 79929171
   User-Agent: GitHub-Hookshot/044aadd   ← 固定前缀
   X-Hub-Signature: sha1=...             ← 老签名（兼容用），别用
   X-Hub-Signature-256: sha256=<hmac>    ← ★ 用这个
        │
④ 你的服务
   · 先算 HMAC-SHA256(原始 body, secret)，和头比对 → 不一致就丢弃（401/403）
   · 再看 X-GitHub-Event 是不是你关心的
   · 干活（起构建 / 写队列）
   · ★ 必须在 10 秒内返回 2xx
        │
⑤ GitHub 记录投递结果
   仓库 Settings → Webhooks → 该条 webhook → Recent Deliveries
   能看到 status code、请求头、请求体、响应体
```

**签名算法（必须一模一样）**

```
expected = "sha256=" + hex( HMAC_SHA256( key = secret, msg = 原始请求体字节 ) )
header    = request.headers["X-Hub-Signature-256"]
比较时用**常量时间比较**（防时序攻击）
```

★ 三个最容易写错的点：
1. 算的是**原始 body 字节**，不是"解析成 JSON 再重新序列化"。
2. 比较的是**整个头**（含 `sha256=` 前缀），别只比 hex。
3. **先验签，再看 event，再干活**。顺序反了就成了"未经验证的攻击者能触发你的构建"。

**失败与重试**

- 超过 **10 秒**没返回 2xx → GitHub **断开连接**，这次投递算失败。
- 失败投递可以在 **Recent Deliveries** 里看到，并可手动 **Redeliver**。
- ★ **重投的 `X-GitHub-Delivery` 和原来一样** → 所以它**不能**当"每次处理都不同"的键；
  幂等要么用"处理过就跳过"的记录表，要么允许重复处理（你的场景里 report 是幂等覆盖，天然安全）。

**其他已确认的限制**

- **payload 上限 25 MB**：超过就**直接不投递**（不是截断）。
  一次性 push 很多分支/tag 时可能触发。
- **`sender` 可能是 `ghost` 用户**：内部流程触发、或 `check_run`/`check_suite` 这类没有 API actor 的事件，
  `sender.login == "ghost"`。**不要假设 sender 一定是人。**
- **`installation` 字段只有 GitHub App 的 webhook 才有**；
  仓库级 webhook 的 payload 里没有它 → **你没法用它换 installation token**（这就是"仓库 webhook 不能代表 App 身份"的直接体现）。

---

## 4. 收端：Cloud Build 的 webhook trigger 到底做了什么

官方定义：**"用 webhook trigger 来认证并接收进来的 webhook 事件"**。

```
gcloud builds triggers create webhook \
  --name=pr-validate-webhook \
  --secret=projects/PROJECT_ID/secrets/pr-webhook-secret/versions/latest \
  --build-config=ci-simulation/trigger/cloudbuild.yaml \
  --region=us-central1
```

**它的工作方式**

| 环节 | 说明 |
|---|---|
| **secret** | 存在 **Secret Manager** 里。控制台可以选"新建 secret（Cloud Build 生成）"或"用已有的"。 |
| **Webhook URL** | 建完控制台会给一个 **Webhook URL 预览**：**URL 里带 Cloud Build 生成的 API key 和你选的 secret**。把它填进 GitHub 的 Payload URL 即可。 |
| **谁调它** | 任何人 POST 到这个 URL（带对 secret）就起一次构建。→ **secret 就是唯一的防线**。 |
| **代码从哪来** | 两种：a) 指定 Cloud Build repository（2nd gen）或 `gitFileSource`；b) **inline build config**（不指定仓库，构建脚本里自己 clone）。 |
| **身份** | trigger 上的 `serviceAccount`（★ build config 里写的 serviceAccount 在 trigger 场景下会被忽略）。 |
| **权限** | Cloud Build service agent `service-${PROJECT_NUMBER}@gcp-sa-cloudbuild.iam.gserviceaccount.com` 需要 Secret Accessor（控制台会自动授）。 |

★ **一个容易搞混的官方结论**（`Accessing GitHub from a build` 原话）：
> You need to use Secret Manager to connect to private GitHub repositories **only when running manual builds**.
> When you run builds using Cloud Build triggers, you can **automatically connect to any private repository you own**
> without storing your credentials in Secret Manager.

→ 也就是说：**clone 代码**这件事，trigger 触发的构建是**自动搞定**的，
你存进 Secret Manager 的那个 token **只用于"回写 GitHub"**（贴 report、上报 check）。
这正好解释了"父 build / 子 build 里到底需不需要 token"这个问题
只出现在"回写"这一段，而不是 clone 那段。

★ **最重要的差异（决定你们的架构）**

| | repository trigger（GitHub App 型） | webhook trigger |
|---|---|---|
| GitHub 侧怎么装的 | 装 Cloud Build 的 **GitHub App** | 仓库 Settings → **Webhooks** 填 URL |
| **build 状态自动回写 GitHub check** | ✅ 会（这就是你在 PR 看到的 check） | ❌ **不会**（Cloud Build 根本不知道 GitHub） |
| 日志链接回传 GitHub | ✅ `includeBuildLogs` | ❌ |
| 能拿到 PR 号等事件字段 | ✅ 直接作为 substitution | ⚠️ webhook trigger 不理解 GitHub 事件；要么自己解析 payload，要么用 inline build 里自己拉 |
| 代码来源 | Cloud Build repository（GitHub 连接） | inline 或自己 clone |
| 官方推荐度 | ★ **仓库事件首选** | 非 GitHub 源 / 自建中转 |

★ **所以"你们必须自己写 report 回 PR"这件事，在架构上是被 webhook trigger 决定的**：
**这条路上 Cloud Build 不会替你回写状态**，只能由 build 内部（或中转服务）调 GitHub API 完成。

---

## 5. 你们实际的完整链路（两种架构）

### 架构 A · 直连（Payload URL = Cloud Build trigger 地址）

```
 开发者
   │ push / 提 PR
   ▼
 GitHub 仓库
   │ ① 事件发生
   │ ② POST payload + X-Hub-Signature-256
   ▼
 Cloud Build webhook trigger        ← URL 自带 API key + secret
   │ ③ 校验 secret → 起一次 build
   ▼
 Cloud Build build（build config）
   ├─ clone 代码（gitConfig / inline 自己 clone）
   ├─ 跑 YAML / Shell / Helm 校验
   ├─ 跑 report step：调 GitHub API（用 bot token）
   │    ├─ POST/PATCH issue comment  ← ★ 这条链接就是 pull-report-bot 的 report
   │    └─ POST check run / status   ← PR 上的 ✅/❌ 也得自己写
   └─ 结束
```

★ 特点：**没有你们自己的常驻服务**，全部逻辑在 build 里。
代价：**report 要能被 GitHub 看到，必须由 build 自己去写**（这正是 trigger 模板里 report step 的意义）。

### 架构 B · 经中转（Payload URL = 你们 Cloud Run / 自己的服务）

```
 GitHub 仓库
   │ POST payload + 签名
   ▼
 你们的中转服务（Cloud Run）
   ├─ 验签（HMAC-SHA256）
   ├─ 解析 payload：PR 号、head.sha、目标分支
   ├─ 决定"这次要不要跑"（增量、跳过、限流）
   ├─ 触发构建：gcloud builds submit --trigger=TRIGGER --substitutions=...
   └─ build 结束后回写 report（用 bot token 调 GitHub API）
```

★ 特点：多一层，但**多了三个能力**：
① 自己决定跑什么（增量/跳过/防抖）；② build 的触发参数可以自由改写；
③ **回写 report 的逻辑在你们自己手里，不用把 token 塞进 build**。

★ **判断你们是哪一种**：看 Payload URL 的域名（见第 1 节）。
另外你提到"PR 上能看到几个校验通过" —— **在架构 A 下这必须由 build 自己写 check**；
在架构 B 下可以由中转服务写。**这一点也需要核对**。

---

## 6. ★ 事件选什么？（最小订阅原则）

GitHub 官方最佳实践第一条就是：**只订阅你真正需要的事件**。

| 你的需求 | 该订阅的事件 | action |
|---|---|---|
| 提 PR 触发校验 | `pull_request` | `opened` / `synchronize`（又 push 了） |
| 往 main 合入后触发 | `push` | 分支 = main |
| 定时跑 | `schedule` | 仓库级 webhook **不支持**（需要 App 或外部调度） |
| 拿到 check 结果 | `check_run` / `check_suite` | `completed` |
| 让"重新跑一次"成为可能 | `pull_request` + 评论里带 `/gcbrun` 的处理逻辑 | — |

★ **不要选 "Send me everything"**：会把 issue、star、fork 等事件也推过来，
噪音大，还容易误触发构建。

★ `pull_request` 有 6 种 action：`opened` / `synchronize` / `reopened` / `edited` / `closed` / `ready_for_review`。
**只认 `opened` 和 `synchronize`**（并忽略 bot 自己发起的 PR 事件，否则会死循环）。

---

## 7. 安全清单（照着抄）

| # | 做法 | 为什么 |
|---|---|---|
| 1 | **Payload URL 里不放任何凭据** | GitHub 官方明确警告：URL 会进日志、进 Referer、进代理记录 |
| 2 | 用 **secret + `X-Hub-Signature-256`** 验签 | 这是"确认这次投递真的来自 GitHub"的唯一手段 |
| 3 | **先验签、再看 event、再干活** | 顺序反了 = 未验证的攻击者可以触发构建 |
| 4 | **secret 用高熵随机串**，存在 Secret Manager / Vault | 弱 secret = 可伪造投递 |
| 5 | **10 秒内返回 2xx**，重活丢队列 | 慢 = GitHub 断连 = 判定失败 = 重复投递 |
| 6 | 用 **HTTPS** 且**开启 SSL 校验** | 中间人可改 payload |
| 7 | 可选：把 **GitHub 的 IP 加进白名单** | `GET https://api.github.com/meta` 拿当前 IP 段（会变，要定期更新） |
| 8 | **用 `X-GitHub-Delivery` 做幂等** | 防重放 / 防重复处理 |
| 9 | **只订阅需要的事件** | 减少攻击面与噪音 |
| 10 | **不要在 payload 里传凭据** | payload 会被记录在 Recent Deliveries 页面 |

---

## 8. 排障清单（按现象查）

| 现象 | 先查什么 |
|---|---|
| webhook 配了但构建没起来 | ① Recent Deliveries 里有没有这次投递？② status code 是不是 2xx？③ Cloud Build 里有没有新 build？ |
| 收到 401/403 | secret 不匹配（Cloud Build URL 里的 secret 和 trigger 里的 secret 版本要一致） |
| 签名校验总是失败 | 算的 body 不是**原始字节**；或用了 `X-Hub-Signature`(SHA-1) 而不是 `-256`；或中间有代理改了 body |
| 同一事件被处理多次 | 10 秒没返回 → GitHub 判失败 → 重投；或中转服务重试逻辑没做幂等 |
| 事件根本没到 | "Which events" 没勾对 / Active 关了 / payload > 25MB 被丢弃 / Payload URL 域名拼错 |
| PR 上没有 check | ★ **webhook trigger 不会自动回写** → 必须自己调 Checks/Statuses API |
| PR 永远 BLOCKED | required check 从未上报（触发条件没覆盖到这次 PR）—— 见 [`demo/pr-check-actions/README.md`](../demo/pr-check-actions/README.md) |
| 本地调不到自己的 webhook | 用 **smee.io** 之类的 webhook 代理把本地端口暴露出去（GitHub 官方文档推荐做法） |

---

## 9. 验证清单（你们环境里跑一遍）

```bash
# 1. 看仓库里到底配了哪些 webhook（能看到 Payload URL 的域名 → 判断架构 A 还是 B）
gh api repos/OWNER/REPO/hooks --jq '.[] | {id, active, events, url: .config.url}'

# 2. 看某条 webhook 最近几次投递（状态码、请求头、响应）
gh api repos/OWNER/REPO/hooks/HOOK_ID/deliveries --jq '.[] | {id, event, status_code, delivered_at}'

# 3. 手动打一次 Cloud Build webhook trigger（验证 secret 链路）
curl -X POST -H 'Content-Type: application/json' \
  -d '{"ref":"refs/heads/main"}' \
  'https://cloudbuild.googleapis.com/build/v1/projects/PROJECT/locations/REGION/triggers/TRIGGER:webhook?secret=XXX'

# 4. 看 trigger 到底长什么样
gcloud builds triggers describe pr-validate-webhook --region=REGION --format=yaml
```

★ 第 1 条命令的输出里，如果 URL 里有 `?secret=` 或类似参数，
**说明凭据在 URL 里**（Cloud Build trigger 就是这样）→ 那个 URL 就是"能起构建的钥匙"，
**必须按机密对待**（别贴到群里、别写进公开仓库）。

---

## 10. 最后一张表：三种接法怎么选

| | 仓库 Webhook + webhook trigger | 仓库 Webhook + 自建中转 | GitHub App + repository trigger |
|---|---|---|---|
| GitHub 侧配置 | Webhooks 填 URL | Webhooks 填自己服务 | 装 App |
| 需要常驻服务 | ❌ | ✅ | ❌ |
| build 状态自动回写 check | ❌ | ❌（自己写） | ✅ |
| 事件筛选/改写能力 | 弱 | ★ 强 | 中（分支正则 + 文件过滤 + CEL） |
| token 放在哪 | build 里（Secret Manager） | 中转服务里 | App 的 installation token |
| 典型适用 | 简单直连、事件少 | 内部中台、复杂策略 | ★ 官方推荐的仓库事件方案 |
| 你们现在 | **很可能是这个** | 你描述的"连 Cloud Run"也可能是这个 | 还没用（但 Cloud Build 已支持） |

★ **建议（按性价比）**：
1. **短期**：继续用 webhook trigger，把 report 逻辑放进 build（模板 `trigger/` 就是这么写的）——
   改动最小、见效最快。
2. **中期**：如果你们已经有那个"Cloud Run 中转"，把 **验签 + 事件筛选 + 幂等** 放进中转层，
   build 只负责"跑测试"。
3. **长期**：如果想要"PR 上自动出现 check + 日志链接 + 不用自己回写状态"，
   就换成 **GitHub App + repository trigger**（官方推荐路径），report 仍然可以保留（做成额外信息）。

---

## 11. 参考

- GitHub：Webhook events and payloads
  `https://docs.github.com/en/webhooks/webhook-events-and-payloads`
- GitHub：Best practices for using webhooks
  `https://docs.github.com/en/webhooks/using-webhooks/best-practices-for-using-webhooks`
- GitHub：Handling webhook deliveries
  `https://docs.github.com/en/webhooks/using-webhooks/handling-webhook-deliveries`
- Google Cloud：Automate builds in response to webhook events
  `https://cloud.google.com/build/docs/automating-builds/create-webhook-triggers`
- Google Cloud：Accessing GitHub from a build（trigger 自动连仓库 / Secret Manager 的边界）
  `https://cloud.google.com/build/docs/access-github-from-build`
- 本仓库：[`trigger/trigger-webhook.yaml`](trigger/trigger-webhook.yaml)（webhook trigger 配置模板）·
  [`cloud-build-trigger-guide.md`](cloud-build-trigger-guide.md)（Trigger 能力全表）·
  [`pull-report-bot-flow.md`](pull-report-bot-flow.md)（你们的链路全貌）·
  [`github-bot-principles.md`](github-bot-principles.md)（Bot / App 原理）
