# CR Check · 测试手册（test-manual.md）

> 目标：**不写一行 Go 代码**，用 `curl` 把 cr-check 的每一条判定规则、每一个入口分支、
> 每一种异常路径都能**复现 + 断言**。
>
> 被测对象：`/Users/lex/git/go/cr-check`（自研 GitHub App：CR Check）
> 代码与配置说明见 `cr-check/README.md`，本文只讲**怎么测、怎么断言**。

---

## 📌 先跑这个：自动化脚本

本文所有用例都有一个**可执行的自动化版本**：[`test-manual.sh`](test-manual.sh)

```bash
cd /Users/lex/git/go/base/practice
./test-manual.sh              # 全量跑：自己编译、自己起服务、逐条验证、打印覆盖矩阵
```

脚本会：

1. **自建环境**：编译被测服务 → 分配空闲端口 → 拉起 mock 实例（固定时间落在维护窗口内）
2. **逐条执行**：每个用例都打印「请求头 → 请求体 → HTTP 状态 → 响应体 → 断言表达式 → 期望值 / 实际值」
3. **多实例切换**：验签、异步模式、扩展 mock、窗口边界各自独立起服务（端口自动顺延）
4. **收尾**：打印「接口覆盖矩阵」（端点 × 场景 × 用例数 × 结果）+ 用例明细 + 汇总

```bash
./test-manual.sh                       # 全量
ONLY=rules ./test-manual.sh            # 只跑某一阶段
ONLY=rules|boot|http|sign|async|extra|window|obs
./test-manual.sh -k 19000              # 指定基础端口
KEEP_LOGS=1 ./test-manual.sh           # 保留临时目录与所有服务日志
```

退出码 `0` = 全通过，`1` = 有失败 → 可直接挂 CI 冒烟。

> 本文下面内容是**脚本每一步背后的原理与期望值说明** —— 想理解某个用例为什么这样设计时看这里；
> 想快速验证一遍，直接跑脚本。

---

## 0. TL;DR · 一张速查表

| 想验证什么 | 一行命令 |
|---|---|
| 全绿（CR 1234 合规） | `./scripts/send-test-event.sh 1234` |
| 状态不对（R3） | `./scripts/send-test-event.sh 5678` |
| 环境不对（R5） | `./scripts/send-test-event.sh 1111` |
| 审批不足（R4） | `./scripts/send-test-event.sh 2222` |
| CR 过期（R6） | `./scripts/send-test-event.sh 3333` |
| 平台故障（fail-closed） | `./scripts/send-test-event.sh 9999` |
| 非受管分支（直接忽略） | `./scripts/send-test-event.sh 1234 feature/x` |
| 原始 curl（完整 payload） | 见 [§4](#4-原始-curl-模板) |

**★ 最重要的一条**：维护窗口是 `Mon–Fri 02:00–04:00`。
用真实时间跑，**永远会红**（R6w 失败）。想看到全绿，**必须**用 `-now` 固定时间：

```bash
go run ./cmd/server -config config/policy.yaml -mode mock -addr :8081 -sync-eval \
  -now "2025-01-06T03:00:00+08:00"
```

---

## 1. 前置准备

### 1.1 依赖工具

| 工具 | 用途 | 检查 |
|---|---|---|
| `jq` | 解析 JSON 断言 | `jq --version` |
| `uuidgen` | 生成唯一 delivery id | `uuidgen` |
| `openssl` | 算 HMAC 签名 | `openssl version` |
| `go` | 起服务 | `go version`（需 ≥ 1.22，代码用了 `http.ServeMux` 的方法路由） |

### 1.2 启动服务（三选一）

```bash
cd /Users/lex/git/go/cr-check
```

**A. 固定时间落在维护窗口内 —— 测"全绿"用这个（推荐）**

```bash
go run ./cmd/server -config config/policy.yaml -mode mock -addr :8081 -sync-eval \
  -now "2025-01-06T03:00:00+08:00"
```

**B. 真实时间 —— 测"窗口外被拦"用这个**

```bash
go run ./cmd/server -config config/policy.yaml -mode mock -addr :8081 -sync-eval
```

**C. 带 webhook secret —— 测验签用这个**

```bash
WEBHOOK_SECRET=topsecret go run ./cmd/server -config config/policy.yaml -mode mock \
  -addr :8081 -sync-eval -now "2025-01-06T03:00:00+08:00"
```

启动成功长这样：

```json
{"level":"INFO","msg":"启动 CR Check","mode":"mock","addr":":8081","check":"cr/prod-validation","managed_branches":["release/prd","release/prod"],"sync_eval":true,"github_configured":false,"cr_platform_configured":false}
{"level":"INFO","msg":"mock 模式：使用内置假 CR 平台","crs":6}
```

### 1.3 ⚠️ 端口占用

`air`（live reload）会把服务跑在 8081。**再起一个实例会静默抢占失败**，
表现是"我明明加了 `-now`，结果窗口判定还是用真实时间"。

```bash
lsof -ti tcp:8081          # 看谁占着
kill $(lsof -ti tcp:8081)  # 腾位置
```

或者**换端口**（推荐，最省事）：

```bash
go run ./cmd/server -config config/policy.yaml -mode mock -addr :8099 -sync-eval \
  -now "2025-01-06T03:00:00+08:00"
export ADDR=http://localhost:8099     # 后面所有脚本都读 ADDR
```

> **★ 端口冲突的坑**：服务**先打印 "HTTP 服务已启动"，再打印 "地址已占用"**。
> 日志里两行挨着，看到 "已启动" 别急着以为成功了，要往下看有没有 `服务退出`。

### 1.4 mock 数据速查（`config/policy.yaml` 的 `mock.crs`）

| CR 号 | 状态 | 审批人 | 目标环境 | 有效期 | 用来测 |
|---|---|---|---|---|---|
| `1234` | Implement | bob, carol | prd | 2020→2035 | **合规基线** |
| `5678` | Draft | bob | prd | 2020→2035 | R3 状态 + R4 审批不足 |
| `1111` | Approved | bob, carol | **prod** | 2020→2035 | R5 环境不匹配 |
| `2222` | Approved | **bob** | prd | 2020→2035 | R4 审批不足 |
| `3333` | Approved | bob, carol | prd | 2020→**2021** | R6 已过期 |
| `9999` | — | — | — | — | **平台故障**（system_error） |
| `8888` | （不存在） | — | — | — | R2 变更单不存在 |

> `8888` 故意**不放进 mock**，用来测"CR 不存在"。

---

## 2. 测试工具函数（先贴进终端，后面全部复用）

把下面这段存成 `~/cr-test-lib.sh`，每个终端 `source` 一次：

```bash
# ============ cr-check 测试工具库 ============
ADDR="${ADDR:-http://localhost:8081}"
CR_DIR="/Users/lex/git/go/cr-check"

# 生成一个 PR webhook payload
# 用法: gen_pr <action> <base_ref> <labels_json> <body> [pr_number] [head_sha]
gen_pr() {
  local action="$1" base="$2" labels="$3" body="$4" prnum="${5:-42}"
  local sha="${6:-a1b2c3d4e5f6789012345678901234567890abcdef}"
  cat <<EOF
{
  "action": "${action}",
  "number": ${prnum},
  "pull_request": {
    "number": ${prnum},
    "title": "feat(api): 新增订单查询接口",
    "body": "${body}",
    "base": { "ref": "${base}", "repo": { "full_name": "acme/platform" } },
    "head": { "sha": "${sha}" },
    "user": { "login": "alice" },
    "labels": ${labels}
  },
  "repository": { "name": "platform", "full_name": "acme/platform", "owner": { "login": "acme" } },
  "installation": { "id": 98765432 }
}
EOF
}

# 发一个 PR 事件（唯一 delivery id）
# 用法: post_pr <action> <base> <labels_json> <body> [pr_number] [sha]
post_pr() {
  local f; f=$(mktemp)
  gen_pr "$@" > "$f"
  curl -s -X POST "${ADDR}/github/webhook" \
    -H 'X-GitHub-Event: pull_request' \
    -H "X-GitHub-Delivery: t-$(uuidgen)" \
    -H 'Content-Type: application/json' \
    --data-binary "@${f}"
  rm -f "$f"
}

# 只打印结论摘要（断言用）
brief() { jq -c '{status,conclusion,ok,system_error,cr_number,failed_rules}'; }

# 只打印失败规则的说明
why()   { jq -r '.rules[]? | select(.passed==false) | "\(.id): \(.message)"'; }
```

**★ 为什么必须用 `--data-binary "@文件"` 而不是 `--data-binary "$VAR"`**：

```bash
BODY=$(cat testdata/pr-event.json)          # ← 命令替换会吃掉末尾换行
curl ... --data-binary "$BODY"               # ← 发出去的字节 ≠ 文件字节
```

一旦服务端开了 `WEBHOOK_SECRET`，签名就对不上 → **401**。
`@文件` 形式保证"签名的字节"和"发出去的字节"完全一致。

---

## 3. 判定规则用例（TC-R\*）

> 统一前置：服务以 `-now "2025-01-06T03:00:00+08:00"`（周一 03:00，在窗口内）启动。
> 这样**除被测规则外，其它规则都是绿的**，失败集合就是干净的证据。

### 3.1 快速批量跑（先跑这个看全局）

```bash
cd /Users/lex/git/go/cr-check
for cr in 1234 5678 1111 2222 3333 9999 8888; do
  printf "%-6s => " "$cr"
  ./scripts/send-test-event.sh "$cr" 2>/dev/null | sed -n '/^{/,$p' | brief
done
```

**期望输出（实测）**：

```
1234   => {"status":"evaluated","conclusion":"success","ok":true,"system_error":false,"cr_number":"1234","failed_rules":null}
5678   => {"status":"evaluated","conclusion":"failure","ok":false,"system_error":false,"cr_number":"5678","failed_rules":["R3","R4"]}
1111   => {"status":"evaluated","conclusion":"failure","ok":false,"system_error":false,"cr_number":"1111","failed_rules":["R5"]}
2222   => {"status":"evaluated","conclusion":"failure","ok":false,"system_error":false,"cr_number":"2222","failed_rules":["R4"]}
3333   => {"status":"evaluated","conclusion":"failure","ok":false,"system_error":false,"cr_number":"3333","failed_rules":["R6"]}
9999   => {"status":"evaluated","conclusion":"failure","ok":false,"system_error":true,"cr_number":"9999","failed_rules":null}
8888   => {"status":"evaluated","conclusion":"failure","ok":false,"system_error":false,"cr_number":"8888","failed_rules":["R2","R3","R4","R5","R6"]}
```

### 3.2 TC-R1 · PR 没带变更单号 → 必失败

**目的**：没有 label `cr/<编号>`、body 里也没有 `Change-Request:` → R1 + R1a 不通过。

```bash
post_pr opened release/prd '[{"name":"feature"}]' "普通描述，没有变更单号" | brief
```

期望：

```json
{"status":"evaluated","conclusion":"failure","ok":false,"system_error":false,"cr_number":"","failed_rules":["R1","R1a","R2","R3","R4","R5","R6"]}
```

失败说明：

```
R1: PR 未携带变更单号（需要 label `cr/<编号>`，或 body 里写 `Change-Request: <编号>`）
R1a: 没有解析到任何变更单号
```

> **★ 为什么 R2~R6 也一起红？**
> 因为 CR 号没解析出来 → 平台查不到 → `CR == nil` → R2/R3/R4/R5/R6 全部无法判定。
> 这是**collect-all** 设计：一次把所有问题列出来，而不是让你改一个提交一次、撞下一个。

### 3.3 TC-R1a · 两个变更单号（冲突） → 必失败

**目的**：一个 PR 只能关联**一个**变更单；不同载体给出不同编号 = 冲突，**不能静默取优先级最高的**。

```bash
# 载体冲突：label = 1234，body = 5678
post_pr opened release/prd '[{"name":"cr/1234"}]' "Change-Request: 5678" | why
```

期望：

```
R1a: 不同载体给出了**不同**的变更单号 [1234 5678]（1234（来自 label:cr/1234）, 5678（来自 body））—— 这是冲突，必须先修正
```

多个 label 同理：

```bash
post_pr opened release/prd '[{"name":"cr/1234"},{"name":"cr/5678"}]' "无 body 标记" | why
```

### 3.4 TC-R1b · 只有 body 标记（无 label） → 应当**通过**

```bash
post_pr opened release/prd '[{"name":"feature"}]' "Change-Request: 1234" | brief
```

期望：`{"conclusion":"success","ok":true,"failed_rules":null}`

> 两个载体**都支持**：label 是主路径，body marker 是兜底路径（兼容老习惯）。

### 3.5 TC-R1c · label 格式不合法 → 视为没带

```bash
# "cr/" 后面没有编号，不匹配 labelPattern ^cr/[0-9A-Za-z._-]+$
post_pr opened release/prd '[{"name":"cr/"}]' "x" | jq -r '.rules[0].message'
```

期望：`PR 未携带变更单号（需要 label `cr/<编号>`，或 body 里写 `Change-Request: <编号>`）`

### 3.6 TC-R2 · 变更单在平台上不存在 → 必失败

```bash
./scripts/send-test-event.sh 8888 2>/dev/null | sed -n '/^{/,$p' | why
```

期望：

```
R2: 变更单 8888 在 CR 管理平台上不存在
R3: 变更单不存在，无法判断状态
R4: 变更单不存在，无法检查审批
R5: 变更单不存在，无法比对目标环境
R6: 变更单不存在，无法检查有效期
```

> **★ 语义区分（很重要）**：
> `R2` 失败 = **业务不通过**（CR 确实不存在）→ 结论 `failure`；
> 平台 5xx/超时 = **系统异常** → 同样 `failure`，但 `system_error=true`。
> 两者都 fail-closed，但**告警口径不同**。

### 3.7 TC-R3 · 状态不是 approved/implement → 必失败

```bash
./scripts/send-test-event.sh 5678 2>/dev/null | sed -n '/^{/,$p' | why
```

期望：

```
R3: 变更单 5678 当前状态为 `draft`，需要 approved / implement
```

### 3.8 TC-R4 · 审批不足 → 必失败

```bash
./scripts/send-test-event.sh 2222 2>/dev/null | sed -n '/^{/,$p' | why
```

期望：

```
R4: 变更单 2222 的审批人只有 1 位（bob），需要至少 2 位
```

（`minApprovals: 2`，来自 `config/policy.yaml` 的 `cr.minApprovals`）

### 3.9 TC-R4b/R4c · 审批人不在白名单 / 提单人自审批 → 必失败

**这两个用例默认 mock 里没有**，需要临时加两条数据。建一个扩展配置：

```bash
cd /Users/lex/git/go/cr-check
cp config/policy.yaml /tmp/policy-extra.yaml
cat >> /tmp/policy-extra.yaml <<'YAML'

    # ❌ 审批人不在白名单 → R4
    - number: "4444"
      status: Implement
      requester: alice
      approvers: [bob, mallory]
      targetEnv: prd
      validFrom: "2020-01-01T00:00:00+08:00"
      validTo: "2035-12-31T23:59:59+08:00"
      url: https://cr.example.com/cr/4444

    # ❌ 提单人自己审批 → R4
    - number: "5555"
      status: Implement
      requester: alice
      approvers: [alice, bob]
      targetEnv: prd
      validFrom: "2020-01-01T00:00:00+08:00"
      validTo: "2035-12-31T23:59:59+08:00"
      url: https://cr.example.com/cr/5555

    # ❌ 平台返回未知状态 → 规范化 unknown → R3（fail-closed）
    - number: "6666"
      status: "ApprovedForImplementation"
      requester: alice
      approvers: [bob, carol]
      targetEnv: prd
      validFrom: "2020-01-01T00:00:00+08:00"
      validTo: "2035-12-31T23:59:59+08:00"
      url: https://cr.example.com/cr/6666

    # ❌ 尚未生效 → R6
    - number: "7777"
      status: Implement
      requester: alice
      approvers: [bob, carol]
      targetEnv: prd
      validFrom: "2030-01-01T00:00:00+08:00"
      validTo: "2035-12-31T23:59:59+08:00"
      url: https://cr.example.com/cr/7777
YAML

go run ./cmd/server -config /tmp/policy-extra.yaml -mode mock -addr :8097 -sync-eval \
  -now "2025-01-06T03:00:00+08:00"
```

（另开终端，`export ADDR=http://localhost:8097`）

```bash
ADDR=http://localhost:8097 ./scripts/send-test-event.sh 4444 | sed -n '/^{/,$p' | why
# R4: 审批人 mallory 不在授权名单内（bob, carol, dave）

ADDR=http://localhost:8097 ./scripts/send-test-event.sh 5555 | sed -n '/^{/,$p' | why
# R4: 提单人 alice 不能审批自己的变更单

ADDR=http://localhost:8097 ./scripts/send-test-event.sh 6666 | sed -n '/^{/,$p' | why
# R3: 变更单 6666 当前状态为 `unknown`，需要 approved / implement

ADDR=http://localhost:8097 ./scripts/send-test-event.sh 7777 | sed -n '/^{/,$p' | why
# R6: 变更单 7777 尚未生效（生效时间 2030-01-01T00:00:00+08:00，当前 2025-01-06T03:00:00+08:00）
```

> **★ TC-R3-unknown 是最重要的安全用例**：
> 平台新增了一个状态 `ApprovedForImplementation`，我们没在 `statusAliases` 里配 →
> 规范化成 `unknown` → **不在白名单 → 不通过**。
> 漏配的后果是"门禁失效"，所以这条必须进回归。

### 3.10 TC-R5 · 目标环境与分支不匹配 → 必失败

```bash
# CR 1111 的 targetEnv 是 prod，PR 打到 release/prd（对应 prd）
./scripts/send-test-event.sh 1111 | sed -n '/^{/,$p' | why
```

期望：

```
R5: 变更单 1111 的目标环境是 `prod`，但本 PR 的目标分支 `release/prd` 对应 `prd`
```

反向验证（CR 1234 是 prd，打到 `release/prod` → 同样 R5 失败）：

```bash
./scripts/send-test-event.sh 1234 release/prod | sed -n '/^{/,$p' | why
```

### 3.11 TC-R6 · CR 过期 / 未生效 → 必失败

```bash
./scripts/send-test-event.sh 3333 | sed -n '/^{/,$p' | why
```

期望：

```
R6: 变更单 3333 已过期（有效期至 2021-01-01T00:00:00+08:00，当前 2025-01-06T03:00:00+08:00）
```

> **★ R6 与 R6w 是两个独立的时间条件**：
> R6 = "这张 CR 还能用吗"（CR 自己的有效期）；
> R6w = "现在允许部署吗"（固定发布时段）。两者都要满足。

### 3.12 TC-R6w · 维护窗口 → 必失败（真实时间）

**目的**：这是**最容易被误判"服务坏了"**的一条。

```bash
# 服务用真实时间启动（不加 -now）
./scripts/send-test-event.sh 1234 | sed -n '/^{/,$p' | why
```

期望：

```
R6w: 当前不在维护窗口内（窗口：Mon,Tue,Wed,Thu,Fri 02:00-04:00 (Asia/Shanghai)，当前 2026-11-11 14:50:05 CST）
```

> **★ 这是正确行为，不是 bug**。窗口是 `02:00–04:00`，你在下午测当然被拦。
> 唯一的"bug 信号"是：加了 `-now` 之后**还是**报真实时间 → 那就是端口被占/服务没重启（见 §1.3）。

### 3.13 TC-R7 · 同一个 CR 被两个 PR 占用 → 必失败

**目的**：防止同一个变更单被两个 PR 重复上线。

```bash
# 先用 PR#42 占用 CR 1234
post_pr opened release/prd '[{"name":"cr/1234"}]' "x" 42 > /dev/null
# 再用 PR#99 用同一个 CR
post_pr opened release/prd '[{"name":"cr/1234"}]' "x" 99 | why
```

期望：

```
R7: 变更单 1234 已被 acme/platform#42 占用（防重复上线）
```

> **★ 占用表是进程内存里的**，服务重启就清空，且**永不释放**（不区分 PR 是否已关）。
> 这是"防重复上线"的兜底，不是持久化的一致性约束。

---

## 4. 原始 curl 模板

### 4.1 用仓库自带的 payload（最简）

```bash
cd /Users/lex/git/go/cr-check

curl -s -X POST http://localhost:8081/github/webhook \
  -H 'X-GitHub-Event: pull_request' \
  -H "X-GitHub-Delivery: $(uuidgen)" \
  -H 'Content-Type: application/json' \
  --data-binary "@testdata/pr-event.json" | jq
```

> **★ 必须在 `cr-check/` 目录下执行**。在父目录（`git/go/`）执行会报：
> ```
> curl: option --data: error encountered when reading a file
> ```
> 因为 `testdata/` 在 `cr-check/` 下面。
>
> **从任何目录都能跑的方式**：
> ```bash
> make -C /Users/lex/git/go/cr-check probe     # 用 $(CURDIR) 拼绝对路径
> ```
> 或者用绝对路径：
> ```bash
> curl -s -X POST http://localhost:8081/github/webhook \
>   -H 'X-GitHub-Event: pull_request' \
>   -H "X-GitHub-Delivery: $(uuidgen)" \
>   -H 'Content-Type: application/json' \
>   --data-binary "@/Users/lex/git/go/cr-check/testdata/pr-event.json" | jq
> ```

### 4.2 完整响应结构（TC-R1a0 · 合规基线）

```bash
./scripts/send-test-event.sh 1234 | sed -n '/^{/,$p' | jq
```

```json
{
  "status": "evaluated",
  "event": "pull_request",
  "action": "opened",
  "repo": "acme/platform",
  "pr": 42,
  "head_sha": "a1b2c3d4e5f6789012345678901234567890abcdef",
  "base_ref": "release/prd",
  "env": "prd",
  "cr_number": "1234",
  "conclusion": "success",
  "ok": true,
  "system_error": false,
  "failed_rules": null,
  "delivery_id": "demo-1234-1794379728490616000",
  "rules": [
    { "id": "R1",  "passed": true, "message": "解析到变更单号：1234（来自 label:cr/1234）" },
    { "id": "R1a", "passed": true, "message": "变更单号唯一" },
    { "id": "R2",  "passed": true, "message": "变更单 1234 存在" },
    { "id": "R3",  "passed": true, "message": "变更单 1234 状态为 `implement`（可执行）" },
    { "id": "R4",  "passed": true, "message": "审批充分：bob, carol" },
    { "id": "R5",  "passed": true, "message": "目标环境匹配：`prd`" },
    { "id": "R6",  "passed": true, "message": "变更单 1234 在有效期内（有效期至 2035-12-31T23:59:59+08:00）" },
    { "id": "R6w", "passed": true, "message": "当前在维护窗口内：Mon,Tue,Wed,Thu,Fri 02:00-04:00 (Asia/Shanghai)" },
    { "id": "R7",  "passed": true, "message": "变更单 1234 未被其他 PR 占用" }
  ],
  "summary": "### ✅ 变更单校验通过\n\n- **变更单**：`1234`\n..."
}
```

**`summary` 就是 GitHub 上 check run 显示的内容**（Markdown 表格）。

### 4.3 `make` 快捷方式

```bash
make -C /Users/lex/git/go/cr-check probe              # 打一发默认事件（CR 1234）
make -C /Users/lex/git/go/cr-check event CR=5678       # 指定 CR 号
```

---

## 5. 入口协议用例（TC-HTTP-\*）

### 5.1 TC-HTTP-01 · 非受管分支 → 直接忽略，**不产生 check**

```bash
post_pr opened feature/x '[{"name":"cr/1234"}]' "x" | jq -c .
```

期望：

```json
{"status":"ignored","reason":"base 分支不在受管清单内","base_ref":"feature/x","managed_branches":["release/prd","release/prod"]}
```

> **★ 为什么"忽略"是对的**：非生产分支不需要变更单；产生 check 会污染 PR 列表、消耗配额。
> **断言方式**：看服务日志里**没有** `check run written`，且 `/internal/registry` 里**没有**这个 PR。

### 5.2 TC-HTTP-02 · 幂等：同一个 delivery id 发两次

```bash
ID="dup-$(uuidgen)"
for i in 1 2; do
  curl -s -X POST "${ADDR}/github/webhook" \
    -H 'X-GitHub-Event: pull_request' \
    -H "X-GitHub-Delivery: ${ID}" \
    -H 'Content-Type: application/json' \
    --data-binary "@/Users/lex/git/go/cr-check/testdata/pr-event.json" | jq -c '{status,reason,delivery_id}'
done
```

期望：

```json
{"status":"evaluated","reason":null,"delivery_id":"dup-xxx"}
{"status":"duplicate","reason":"该 delivery id 已处理过","delivery_id":"dup-xxx"}
```

> **★ GitHub 会重投 webhook**（3xx/超时/网络抖动时最多重试 3 次）。
> 没有幂等 = 同一个 PR 判定 4 次 = check 记录翻倍、审计流水翻倍。
>
> **注意**：不传 `X-GitHub-Delivery` 头 → **不做幂等**（每次都处理）。

### 5.3 TC-HTTP-03 · 事件白名单

```bash
# 未订阅的事件
curl -s -X POST "${ADDR}/github/webhook" \
  -H 'X-GitHub-Event: push' -H "X-GitHub-Delivery: $(uuidgen)" \
  -H 'Content-Type: application/json' --data-binary '{}' | jq -c .
# → {"event":"push","reason":"事件类型未订阅: push","status":"ignored"}

# ping 事件（保存 Webhook URL 时 GitHub 会发）→ 总是接受
curl -s -X POST "${ADDR}/github/webhook" \
  -H 'X-GitHub-Event: ping' -H "X-GitHub-Delivery: $(uuidgen)" \
  -H 'Content-Type: application/json' --data-binary '{"zen":"Keep it logically awesome."}' | jq -c .
# → {"status":"pong"}
```

### 5.4 TC-HTTP-04 · action 白名单

**会触发判定**的 action：
`opened` / `synchronize` / `reopened` / `labeled` / `unlabeled` / `ready_for_review` / `edited`

```bash
post_pr closed release/prd '[{"name":"cr/1234"}]' "x" | jq -c .
# → {"status":"ignored","reason":"action 不触发判定: closed","action":"closed"}
```

> **★ 为什么 `closed` 不判定**：PR 都关了，判它干什么？还会往 check 上写结论。
> **注意**：`labeled` **在**白名单里 → 加/删 `cr/xxx` label 会立即重判（这是"改了 label 就重跑"的关键路径）。

### 5.5 TC-HTTP-05 · 坏 payload → 400

```bash
curl -s -i -X POST "${ADDR}/github/webhook" \
  -H 'X-GitHub-Event: pull_request' -H "X-GitHub-Delivery: $(uuidgen)" \
  -H 'Content-Type: application/json' --data-binary 'not-json' | head -1
# → HTTP/1.1 400 Bad Request
```

响应体：`{"error":"解析 payload 失败: invalid character 'o' in literal null (expecting 'u')"}`

### 5.6 TC-HTTP-06 · GET 请求 → 404（不是 405！）

```bash
curl -s -i "${ADDR}/github/webhook" | head -3
# → HTTP/1.1 404 Not Found
# → 404 page not found
```

> **★ 为什么不是 405**：路由注册的是 Go 1.22+ 的方法路由 `POST /github/webhook`，
> 而 `GET /` 又是个能匹配所有路径的子树模式 —— Go 的 ServeMux 选了 `GET /`，
> 它内部对非 `/` 的路径返回 `404`。代码里那个 `405` 分支实际上**不可达**。
> （不是 bug，但要知道，免得误判"服务挂了"。）

### 5.7 TC-HTTP-07 · 生产形态：异步模式返回 202

生产必须 `syncEval=false`（先 ACK 再异步判定，避免超过 GitHub 的 10 秒投递预算）。

```bash
# 模拟：mode=real（需要凭据占位）+ 不开 -sync-eval
GITHUB_APP_ID=1 GITHUB_APP_INSTALLATION_ID=1 GITHUB_APP_PRIVATE_KEY_PATH=/tmp/fake.pem \
  go run ./cmd/server -config config/policy.yaml -mode real -addr :8096 &
```

```bash
curl -s -i -X POST http://localhost:8096/github/webhook \
  -H 'X-GitHub-Event: pull_request' -H "X-GitHub-Delivery: $(uuidgen)" \
  -H 'Content-Type: application/json' \
  --data-binary "@/Users/lex/git/go/cr-check/testdata/pr-event.json" | tail -1
```

期望（HTTP **202**）：

```json
{"status":"queued","pr":42,"repo":"platform","head_sha":"a1b2c3d4e5f6789012345678901234567890abcdef"}
```

> 注意：`mode=mock` 时 `main.go` 会**强制** `syncEval=true`，所以 mock 模式**测不到** `queued` 分支。

### 5.8 TC-SIGN · 验签（webhook secret）

**前置**：服务端用 `WEBHOOK_SECRET=topsecret` 启动。

```bash
BODY_FILE=/Users/lex/git/go/cr-check/testdata/pr-event.json

# ① 不带签名 → 401
curl -s -X POST "${ADDR}/github/webhook" \
  -H 'X-GitHub-Event: pull_request' -H "X-GitHub-Delivery: $(uuidgen)" \
  -H 'Content-Type: application/json' --data-binary "@${BODY_FILE}" | jq -c .
# → {"error":"webhook 签名校验失败: 缺少 X-Hub-Signature-256"}

# ② 错误签名 → 401
curl -s -X POST "${ADDR}/github/webhook" \
  -H 'X-GitHub-Event: pull_request' -H "X-GitHub-Delivery: $(uuidgen)" \
  -H 'Content-Type: application/json' \
  -H 'X-Hub-Signature-256: sha256=deadbeef' --data-binary "@${BODY_FILE}" | jq -c .
# → {"error":"webhook 签名校验失败"}

# ③ 正确签名 → 200 evaluated
SIG="sha256=$(openssl dgst -sha256 -hmac topsecret -r < "${BODY_FILE}" | cut -d' ' -f1)"
curl -s -X POST "${ADDR}/github/webhook" \
  -H 'X-GitHub-Event: pull_request' -H "X-GitHub-Delivery: $(uuidgen)" \
  -H 'Content-Type: application/json' \
  -H "X-Hub-Signature-256: ${SIG}" --data-binary "@${BODY_FILE}" | brief
# → {"status":"evaluated","conclusion":"success",...}
```

> **★ 签名必须对"文件原始字节"计算**。用 `$(cat file)` 拿到变量再发，末尾换行会丢 → 401。

---

## 6. 韧性 / fail-closed 用例（TC-RES-\*）

### 6.1 TC-RES-01 · CR 平台故障 → **系统异常**，绝不 success

```bash
./scripts/send-test-event.sh 9999 | sed -n '/^{/,$p' | jq '{conclusion,ok,system_error,failed_rules,summary}'
```

期望：

```json
{
  "conclusion": "failure",
  "ok": false,
  "system_error": true,
  "failed_rules": null,
  "summary": "### ⚠️ 门禁系统异常，本次判定未完成\n\n**这不是你的 PR 有问题**，是门禁服务没能完成判定。\n\n错误：`simulated CR platform timeout`\n\n已触发告警。系统恢复后会自动重评；急需放行请联系平台组走人工审批。\n"
}
```

**★ 两条铁律的验证点**：

| 铁律 | 断言 |
|---|---|
| ① 平台不可用 → `conclusion` 必须是 `failure` | `.conclusion == "failure"` |
| ① 平台不可用 → **绝不能**是 `success` / `neutral` / `skipped` | GitHub 把 `skipped`/`neutral` 当作**通过** → 写了等于开门 |
| ① 平台不可用 → `system_error == true`，**且 `failed_rules` 为空** | 系统异常不是"某条规则不通过"，是"没判完" |
| ① 平台不可用 → 服务端**打了告警日志** | 日志出现 `⚠️ 门禁系统异常（fail-closed），需要人工介入` |

```bash
# 断言告警日志
grep "门禁系统异常" 服务日志 | tail -1
```

### 6.2 TC-RES-02 · 未知状态 → 按"不通过"处理

见 [§3.9](#39-tc-r4br4c--审批人不在白名单--提单人自审批--必失败) 的 `6666`：
`status: "ApprovedForImplementation"` → `unknown` → R3 失败。

### 6.3 TC-RES-03 · 写 check 失败要能被发现

mock 模式写的是日志型 writer，**不会**失败。真实模式写 GitHub Checks API 失败时：

- 服务端日志：`写 check 结论失败 err=...`
- 指标：`cr_check_github_api_errors_total{code="check_write"}` 递增

```bash
curl -s "${ADDR}/metrics" | grep cr_check_github_api_errors_total
```

> **★ "读到了但没写出去"必须是一个独立告警**，不能靠"PR 上没绿标"这种间接现象发现。

### 6.4 TC-RES-04 · 定时重扫（兜底）

```bash
# 立即触发一次重扫
curl -s -X POST "${ADDR}/internal/recheck" | jq -c .
# → {"status":"recheck done","prs":2,"flipped":0}
```

**为什么必须有它**：GitHub 的 required status check 是**按 head SHA 查已存在的结论**，
不会在 merge 时刻重新执行规则。场景：

```
10:00  CR 有效 → 判定 success ✅
10:05  维护窗口关闭
10:30  有人点 Merge
       GitHub 看到 head SHA 上有个绿 check → 放行 ❌❌❌
```

**断言"重扫确实扫到了 PR"**：

```bash
# 先登记一个受管 PR
post_pr opened release/prd '[{"name":"cr/1234"}]' "x" 42 > /dev/null

curl -s -X POST "${ADDR}/internal/recheck" | jq -c .
# → {"status":"recheck done","prs":1,"flipped":0}

curl -s "${ADDR}/metrics" | grep cr_check_recheck_scanned_total
# cr_check_recheck_scanned_total 1     ← 扫到了 1 个 PR
```

**★ 关于 `flipped`（结论翻转）指标**：

```bash
curl -s "${ADDR}/metrics" | grep cr_check_recheck_flipped_total
```

本地**很难把它测成非 0**，原因是：

| 条件 | 本地行为 |
|---|---|
| `-now` 固定时间 | 两次判定用同一时刻 → 窗口判定结果不变 → 不翻转 |
| mock CR 数据静态 | CR 状态/有效期不变 → 不翻转 |
| registry 在**进程内存**里 | 重启服务 → PR 登记被清空 → 重扫扫不到任何东西 |

所以 `flipped_total` 在本地恒为 0 是**正确行为**。
它的真实用途在生产：CR 数据会变、维护窗口会开闭、时间会流逝 ——
此时"重扫结论与上次 webhook 结论不同"就说明**有 webhook 事件丢了**。

> **★ 结论**：`flipped_total` 是**生产健康指标**，不是本地功能测试项。
> 本地只需断言"重扫能扫到已登记的 PR"（`prs > 0`、`scanned_total` 递增）。

---

## 7. 可观测性用例（TC-OBS-\*）

| 端点 | 命令 | 用途 |
|---|---|---|
| `GET /` | `curl -s http://localhost:8081/` | 首页：运行模式、check 名、受管分支、端点清单 |
| `GET /healthz` | `curl -s http://localhost:8081/healthz` | 存活探针 → `ok` |
| `GET /readyz` | `curl -s http://localhost:8081/readyz \| jq` | 就绪探针 → `{"mode":"mock","ready":true}` |
| `GET /internal/policy` | `curl -s http://localhost:8081/internal/policy \| jq` | **脱敏后的生效配置**（排查"规则为什么没生效"） |
| `GET /internal/last-check` | `curl -s http://localhost:8081/internal/last-check \| jq` | 最近一次 check 写入内容 |
| `GET /internal/audit` | `curl -s http://localhost:8081/internal/audit \| jq` | 最近 50 条审计流水 |
| `GET /internal/registry` | `curl -s http://localhost:8081/internal/registry \| jq` | 已登记的受管 PR 快照 |
| `GET /metrics` | `curl -s http://localhost:8081/metrics \| grep cr_check` | Prometheus 指标 |
| `GET /mock/cr/{n}` | `curl -s http://localhost:8081/mock/cr/1234 \| jq` | 看 mock CR 原始数据（仅 mock 模式） |

### 7.1 TC-OBS-01 · 生效配置（脱敏）

```bash
curl -s http://localhost:8081/internal/policy | jq
```

```json
{
  "checkName": "cr/prod-validation",
  "timezone": "Asia/Shanghai",
  "managedBranches": ["release/prd", "release/prod"],
  "branchEnvMap": {"": "dev", "main": "prd", "release/prd": "prd", "release/prod": "prod"},
  "allowedStatuses": ["approved", "implement"],
  "minApprovals": 2,
  "labelPattern": "^cr/[0-9A-Za-z._-]+$",
  "bodyMarker": "Change-Request:",
  "webhookSecretSet": false,
  "githubConfigured": false,
  "crPlatformSet": false
}
```

> **★ 排查"为什么规则没生效"时，先跑这一条** —— 它打印的是**环境变量覆盖之后**的最终生效值。

### 7.2 TC-OBS-02 · mock CR 平台原始数据

```bash
curl -s http://localhost:8081/mock/cr/1234 | jq
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8081/mock/cr/9999   # 500（模拟故障）
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8081/mock/cr/8888   # 404（不存在）
```

> ⚠️ `GET /mock/cr/`（列表）**不可达**（404）—— 路由注册的是 `/mock/cr/{number}`，
> 空段不匹配。只能一个一个查。

### 7.3 TC-OBS-03 · 审计流水

```bash
curl -s http://localhost:8081/internal/audit | jq '.[-1]'
```

```json
{
  "ts": "2026-11-11T14:49:26.497581+08:00",
  "kind": "evaluation",
  "repo": "acme/platform",
  "pr": 42,
  "head_sha": "a1b2c3d4...",
  "base_ref": "release/prd",
  "env": "prd",
  "cr_number": "9999",
  "conclusion": "failure",
  "system_error": true,
  "delivery_id": "demo-9999-...",
  "source": "webhook"
}
```

`source` 取值：`webhook`（同步）/ `webhook-async`（异步 worker）/ `recheck`（定时重扫）。

### 7.4 TC-OBS-04 · 关键指标

```bash
curl -s http://localhost:8081/metrics | grep '^cr_check'
```

| 指标 | 含义 | 什么时候看 |
|---|---|---|
| `cr_check_evaluations_total{result="success\|failure"}` | 判定总数 | 门禁整体通过率 |
| `cr_check_rule_failed_total{rule_id="R3"}` | **哪条规则最常拦人** | 优化提示文案 / 判断规则是否太严 |
| `cr_check_crplatform_requests_total{result="ok\|error\|skipped"}` | CR 平台调用 | 平台稳定性 |
| `cr_check_webhook_rejected_total{reason="bad_signature\|duplicate\|..."}` | 被拒的 webhook | 签名配置对不对 / 重投率 |
| `cr_check_recheck_flipped_total` | **重扫时结论翻转次数** | 事件丢失率（最重要的健康指标） |
| `cr_check_evaluation_duration_seconds` | 判定耗时 P99 | 决定 `syncEval` 是否安全 |
| `cr_check_checks_written_total` | 写 check 次数 | 与判定数对比 → 差值 = 写失败 |
| `cr_check_queue_depth` | 异步队列积压 | 容量不足 |

### 7.5 TC-OBS-05 · registry（登记的受管 PR）

```bash
curl -s http://localhost:8081/internal/registry | jq -c '.[] | {pr:(.pr.Owner+"/"+.pr.Repo+"#"+(.pr.Number|tostring)), base:.pr.BaseRef, labels:.pr.Labels, last:.last_conclusion}'
```

```json
{"pr":"acme/platform#42","base":"release/prd","labels":["cr/9999","feature"],"last":"failure"}
{"pr":"acme/platform#99","base":"release/prd","labels":["cr/1234"],"last":"failure"}
```

> **★ `labels` 会被同 PR 的后续事件覆盖** —— 上例里 PR#42 的 labels 已经是最后一次事件的了。

---

## 8. 维护窗口边界用例（TC-WIN-\*）

窗口定义：`days: [Mon,Tue,Wed,Thu,Fri]`, `start: "02:00"`, `end: "04:00"`, `tz: Asia/Shanghai`，
**左闭右开 `[start, end)`**。

> **★ `-now` 是启动参数，不是请求参数** —— 每个边界值要**各起一个实例**。

| 用例 | `-now` | 期望 R6w | 启动命令（端口换着来） |
|---|---|---|---|
| TC-WIN-01 周一 02:00:00（**起点含**） | `2025-01-06T02:00:00+08:00` | ✅ 通过 | `-addr :8091` |
| TC-WIN-02 周一 03:59:59 | `2025-01-06T03:59:59+08:00` | ✅ 通过 | `-addr :8092` |
| TC-WIN-03 周一 04:00:00（**终点不含**） | `2025-01-06T04:00:00+08:00` | ❌ 失败 | `-addr :8093` |
| TC-WIN-04 周六 03:00 | `2025-01-11T03:00:00+08:00` | ❌ 失败 | `-addr :8094` |
| TC-WIN-05 周日 03:00 | `2025-01-05T03:00:00+08:00` | ❌ 失败 | `-addr :8095` |

一条龙跑完：

```bash
cd /Users/lex/git/go/cr-check
declare -a CASES=(
  "8091|2025-01-06T02:00:00+08:00|周一02:00起点(闭)"
  "8092|2025-01-06T03:59:59+08:00|周一03:59:59"
  "8093|2025-01-06T04:00:00+08:00|周一04:00终点(开)"
  "8094|2025-01-11T03:00:00+08:00|周六"
  "8095|2025-01-05T03:00:00+08:00|周日"
)
for c in "${CASES[@]}"; do
  IFS='|' read -r port now desc <<< "$c"
  go run ./cmd/server -config config/policy.yaml -mode mock -addr ":$port" -sync-eval -now "$now" &
  sleep 1.5
  printf "%-22s => " "$desc"
  ADDR="http://localhost:$port" ./scripts/send-test-event.sh 1234 2>/dev/null \
    | sed -n '/^{/,$p' | jq -r '"R6w=" + (.rules[]|select(.id=="R6w")|.passed|tostring)'
  kill %1 2>/dev/null; wait 2>/dev/null
done
```

**实测期望**：

```
周一02:00起点(闭)       => R6w=true
周一03:59:59           => R6w=true
周一04:00终点(开)       => R6w=false
周六                   => R6w=false
周日                   => R6w=false
```

> **跨零点窗口**（`start > end`，如 `22:00 → 02:00`）代码里已实现
> （`Window.Contains` 的 else 分支处理"前一天延续到今天"），
> 但**当前 policy.yaml 里没有这种窗口**，要测得自己加配置。

---

## 9. 一键回归脚本

把下面存成 `cr-check/scripts/regression.sh`（或 `/tmp/regression.sh`），
**每次改完代码跑一遍**。

```bash
#!/usr/bin/env bash
# cr-check 回归测试：起服务 → 跑用例 → 比对期望 → 汇总
set -uo pipefail
cd /Users/lex/git/go/cr-check

PORT=${PORT:-8099}
NOW="2025-01-06T03:00:00+08:00"
PASS=0; FAIL=0

go run ./cmd/server -config config/policy.yaml -mode mock -addr ":$PORT" -sync-eval -now "$NOW" \
  > /tmp/cr-regression.log 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
sleep 2

ADDR="http://localhost:$PORT"
export ADDR

# 断言函数: assert <名称> <jq表达式> <期望> <CR号> [base分支]
assert() {
  local name="$1" expr="$2" want="$3" cr="$4" base="${5:-release/prd}" got
  got=$(./scripts/send-test-event.sh "$cr" "$base" 2>/dev/null \
        | sed -n '/^{/,$p' | jq -r "$expr")
  if [ "$got" = "$want" ]; then
    printf "  ✅ %-46s %s\n" "$name" "$got"; PASS=$((PASS+1))
  else
    printf "  ❌ %-46s got=%s want=%s\n" "$name" "$got" "$want"; FAIL=$((FAIL+1))
  fi
}

echo "── 规则判定 ──"
assert "R1 合规基线全绿"        '.conclusion'                    "success" 1234
assert "R3 Draft 状态"          '.failed_rules|join(",")'       "R3,R4"   5678
assert "R5 环境不匹配"          '.failed_rules|join(",")'       "R5"      1111
assert "R4 审批不足"            '.failed_rules|join(",")'       "R4"      2222
assert "R6 过期"                '.failed_rules|join(",")'       "R6"      3333
assert "R2 变更单不存在"        '.failed_rules|join(",")'       "R2,R3,R4,R5,R6" 8888

echo "── fail-closed ──"
assert "平台故障 → failure"     '.conclusion'                    "failure" 9999
assert "平台故障 → system_error" '.system_error'                 "true"    9999
assert "平台故障 → 非 success"  '(.conclusion!="success")|tostring' "true" 9999

echo "── 入口协议 ──"
assert "非受管分支 → ignored"   '.status'                        "ignored" 1234 feature/x

echo "── 结果 ──"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
```

跑法：

```bash
chmod +x /tmp/regression.sh && /tmp/regression.sh
```

**期望输出**：

```
── 规则判定 ──
  ✅ R1 合规基线全绿                            success
  ✅ R3 Draft 状态                              R3,R4
  ✅ R5 环境不匹配                              R5
  ✅ R4 审批不足                                R4
  ✅ R6 过期                                    R6
  ✅ R2 变更单不存在                            R2,R3,R4,R5,R6
── fail-closed ──
  ✅ 平台故障 → failure                         failure
  ✅ 平台故障 → system_error                    true
  ✅ 平台故障 → 非 success                      true
── 入口协议 ──
  ✅ 非受管分支 → ignored                       ignored
── 结果 ──
PASS=10 FAIL=0
```

> 退出码 `0` = 全通过，`1` = 有失败 → 可以直接挂到 CI 上当冒烟测试。

---

## 10. 常见坑速查

| 现象 | 原因 | 解决 |
|---|---|---|
| `curl: option --data: error encountered when reading a file` | 在 `cr-check/` 目录外用了相对路径 `testdata/pr-event.json` | 用 `make -C ... probe` 或绝对路径 |
| 加了 `-now` 但窗口判定还用真实时间 | 端口被 `air` 的实例占了，新实例 bind 失败 | `lsof -ti tcp:8081` 杀掉，或换端口 |
| 一直报 `R6w 当前不在维护窗口内` | 真实时间在 `02:00–04:00` 之外 | **这是正确行为**，用 `-now` 固定到窗口内 |
| 401 签名校验失败 | `--data-binary "$BODY"`（变量）丢了末尾换行 | 改用 `--data-binary "@文件"` |
| 响应里没有 `conclusion` 字段 | 返回的是 `{status:"ignored"}` 或 `{status:"duplicate"}` | 看 `status` 字段 |
| `GET /github/webhook` 返回 404 而不是 405 | Go 1.22 ServeMux 方法路由 + `GET /` 子树模式 | 已知行为，不是故障 |
| `/mock/cr/` 列表 404 | 只注册了 `/mock/cr/{number}` | 一个一个查 |
| `failed_rules` 是 `null` 而不是 `[]` | Go 里空切片 `nil` 序列化 | 用 `.failed_rules // [] \| join(",")` |
| R7 莫名失败 | 进程内占用表：同 CR 号被别的 PR 用过 | 重启服务清表 |
| payload 里 body 含 `"` 或 `$` 时 JSON 坏了 | `gen_pr` 用的是**未加引号的 heredoc**（`<<EOF`），shell 会展开 `$`、反引号 | body 里避免用 `"`；或改成把 body 从文件读入 |
| `post_pr` 返回空 | `ADDR` 没设成你实际启动的端口 | `export ADDR=http://localhost:8099` |

---

## 11. 上生产前的 checklist

```
□  checkName 与 GitHub 分支保护里的 required status check 逐字符一致（含斜杠）
□  Webhook URL 可达；保存时 GitHub 发的 ping 返回 {"status":"pong"}
□  WEBHOOK_SECRET 已设置，且签名不对时被拒（401）
□  syncEval = false（生产先 ACK 再异步判定）
□  幂等用 Redis（不是进程内 Map —— 多副本下等于没有幂等）
□  维护窗口与发布流程的实际时段对齐（现在写死 02:00–04:00）
□  CR 平台状态白名单 + statusAliases 已覆盖平台当前所有状态
      ★ 平台新增状态 → 补 statusAliases（漏配 = 那个状态一律不通过）
□  minApprovals / allowedApprovers 与组织实际审批流程对齐
□  重扫间隔（默认 300s）小于"事件丢失到人工发现"的容忍时间
□  指标已接入：cr_check_recheck_flipped_total > 0 就说明有事件丢了
□  cr_check_github_api_errors_total 持续为 0
□  cr_check_evaluation_duration_seconds P99 < GitHub 的 10 秒投递预算
□  审计日志落盘（-audit-file），留存期满足合规要求
□  GitHub App 权限最小化：Metadata:Read + Pull requests:Read + Checks:Write
      ★ 绝不给 Contents:Write
□  分支保护的 required check 绑定来源 App = CR Check（防同名 check 伪造）
□  跑一遍本文 §9 的回归脚本 + §8 的窗口边界
```

---

## 12. 相关文档

| 主题 | 文档 |
|---|---|
| **自动化测试脚本**（本文全部用例的可执行版本） | [test-manual.sh](test-manual.sh) |
| cr-check 代码 / 规则 / 部署总览 | `cr-check/README.md` |
| 本地调试姿势（air / dlv / 固定时间复现） | [01-local-debug.md](01-local-debug.md) |
| 配置注入与部署（YAML vs env、Secret） | [02-config-and-deploy.md](02-config-and-deploy.md) |
| 测试工具链（gotestsum / golangci-lint） | [03-go-toolchain.md](03-go-toolchain.md) |
| 实践笔记索引 | [README.md](README.md) |
