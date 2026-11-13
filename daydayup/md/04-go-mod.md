# Day 04 · go.mod：Go 项目的"依赖身份证"

> 一句话：**go.mod 不是代码，是一份声明清单**——它写着"我这个项目叫什么名字、需要用哪些外部库、各自什么版本"。

配合项目实例讲解：[`cr-check/go.mod`](file:///Users/lex/git/go/cr-check/go.mod)

---

## 目标

- [ ] 知道 go.mod 是"声明"而不是"调用"
- [ ] 能逐行读懂 `cr-check/go.mod`
- [ ] 搞懂 `require` / `// indirect` / `go 1.27.3` 是什么意思
- [ ] 知道 go.sum 是干嘛的
- [ ] 会用 `go mod tidy` / `go get` / `go mod why`

---

## 一、先纠正一个常见误解

你原话是：

> 这是引用了当前项目或者是一些外部项目的一些构包

方向对了一半，但有个关键差别：

| 你以为 | 实际 |
|---|---|
| go.mod 里"调用"了这些包 | go.mod 里**只是写下了名字和版本** |
| 代码就在 go.mod 里 | 代码**不在** go.mod 里，go.mod 只是一张"购物清单" |
| 写了就会自动下载 | 写了之后需要 `go mod download` / 构建时才真正下载到本地缓存 |

打个比方：

- **go.mod** = 购物清单（写着要买 5 斤米、2 斤面）
- **go.sum** = 小票 + 防伪码（证明买到的没被掉包）
- **GOPATH/pkg/mod 缓存目录** = 冰箱（真正放着货的地方）
- **`import` 语句** = 你在厨房里实际伸手去拿哪样东西

所以 go.mod 属于 **声明式（declarative）** 的东西：它只描述"世界应该长什么样"，真正干活的是 Go 工具链（`go build` / `go run`）根据它去把依赖下载、编译、链接。

---

## 二、逐行读 cr-check/go.mod

原始文件长这样：

```go
module github.com/acme/cr-check

go 1.27.3

require (
	github.com/bradleyfalzon/ghinstallation/v2 v2.19.0
	github.com/google/go-github/v88 v88.0.0
	github.com/prometheus/client_golang v1.25.0
	github.com/redis/go-redis/v9 v9.23.0
	sigs.k8s.io/yaml v1.6.0
)

require (
	github.com/beorn7/perks v1.0.1 // indirect
	// ... 还有一串 indirect
)
```

### 1. `module github.com/acme/cr-check` —— 我的身份证

这一行声明**本项目自己的模块路径（module path）**。

它的作用有两个：

1. **给本项目一个全局唯一名字**。别人 import 你项目里的包时，写的就是这个名字。
2. **它是本项目内部 import 路径的"根"**。看 `cmd/server/main.go`：

   ```go
   import (
       "github.com/acme/cr-check/internal/audit"
       "github.com/acme/cr-check/internal/check"
       "github.com/acme/cr-check/internal/observability"
       // ...
   )
   ```

   规律是：**项目内目录路径 = module 路径 + 相对目录**。
   所以 `internal/observability/metrics.go` 这个文件的导入路径就是
   `github.com/acme/cr-check/internal/observability`。

   > 换句话说，module 这一行相当于给项目"定了根目录"。改了它，项目里**所有** import 路径都得跟着改，所以定下来就别乱动。

2. 注意 `github.com/acme/cr-check` 只是个**占位名**（acme 是常见的假公司名）。它看起来像 GitHub 地址，但**并不要求真的托管在 GitHub**。别人 clone 不到也没关系——只有当你 `go get` 一个**外部**模块时，那个路径才必须真实可访问。

3. 有个 Go 官方的小福利：如果 module 路径是 `github.com/你的用户名/你的仓库名`，那么 `go get` 它的时候，Go 工具会默认去 GitHub 拉代码。`acme` 显然是假的，所以这个项目目前只能本地用。

### 2. `go 1.27.3` —— 语言版本声明

声明这个项目**至少需要 Go 1.27.3** 工具链来编译。

- 里面的 `1.27.3` 是 Go 1.21 之后的新写法：从那时起 `go` 指令既表示"语言版本"，也表示"**最低工具链版本**"。
  - 如果你本地装的是 go1.27.3 → 完全 OK
  - 如果你本地是 go1.25 → 报 `go.mod requires go >= 1.27.3 (running go 1.25.x)`
  - 如果你本地是 go1.28 → 也能跑（高版本能编译低版本声明的项目）
- 它还会**锁住语言特性**。比如你在 `go 1.16` 的项目里写 `for i := range 10`（1.22 才有的 range-over-int）会直接编译报错，即使你用的是新工具链。

> 本机版本刚好一致：`go version go1.27.3 darwin/arm64`。

### 3. `require (...)` —— 依赖清单

`require` = "我需要这些包"。两段是因为 Go 会区分两类：

#### 第一段：直接依赖（direct）

这些是**你的代码 import 过的**。对照 cr-check 的源码：

| 依赖 | 代码里在哪用 | 干什么的 |
|---|---|---|
| `github.com/bradleyfalzon/ghinstallation/v2 v2.19.0` | `internal/gh/client.go` | GitHub App 安装态认证：帮你把 App 私钥换成 installation token，并自动在过期前续期 |
| `github.com/google/go-github/v88 v88.0.0` | `internal/gh/client.go`、`internal/check/writer.go` | GitHub REST API 的官方 Go 客户端（发评论、改 PR 之类） |
| `github.com/prometheus/client_golang v1.25.0` | `internal/observability/metrics.go` | Prometheus 指标埋点 + `/metrics` HTTP 端点 |
| `github.com/redis/go-redis/v9 v9.23.0` | `internal/queue/queue.go` | Redis 客户端（这里是队列） |
| `sigs.k8s.io/yaml v1.6.0` | `internal/config/config.go` | 解析 YAML 配置文件 |

#### 第二段：间接依赖（indirect）

带 `// indirect` 注释的，表示**你的代码没有直接 import 它，但你的直接依赖需要它**。

典型的传递依赖链：

```
你的项目 cr-check
  └── prometheus/client_golang        （直接依赖）
        ├── prometheus/common         ← indirect
        ├── prometheus/client_model   ← indirect
        ├── prometheus/procfs         ← indirect
        ├── beorn7/perks              ← indirect
        ├── cespare/xxhash/v2         ← indirect
        ├── go.uber.org/atomic        ← indirect
        └── protobuf (google.golang.org/protobuf) ← indirect
```

再往下一层还有 `golang.org/x/sys`、`go.yaml.in/yaml/v2` 等，也是被上面这些间接依赖拉进来的。

> **关键点**：`// indirect` 不是"你不该用"，只是"**你直接 import 了它**"这件事不成立。代码里你照样可以 `import "github.com/prometheus/common/expfmt"`，只要你手写进第一段（或跑 `go mod tidy` 让 Go 自动挪过去）。

### 4. 版本号 `v2.19.0` / `v88.0.0` —— 语义化版本

Go 用 [SemVer](https://semver.org/) 三段式：`主版本.次版本.修订号`

- `v1.25.0` → 次版本递增 = **向后兼容的新功能**（可自动升级）
- `v1.25.1` → 修订号递增 = **只修 bug**（可自动升级）
- `v2.0.0` → 主版本递增 = **有破坏性改动**（必须改代码，所以路径后面加了 `/v2`）

### 5. 路径里的 `/v2`、`/v88`、`/v9` —— 大版本后缀

这是 Go 的硬性规定：

> **当模块主版本 ≥ 2 时，必须在模块路径末尾加上 `/vN`。**

所以你会看到这些奇怪的路径：

| 写法 | 含义 |
|---|---|
| `github.com/redis/go-redis/v9` | go-redis 的**第 9 个大版本** |
| `github.com/google/go-github/v88` | go-github 的**第 88 个大版本** |
| `github.com/bradleyfalzon/ghinstallation/v2` | ghinstallation 的第 2 个大版本 |
| `sigs.k8s.io/yaml v1.6.0` | 主版本还是 1，所以路径里**不加**后缀 |

初学者常见困惑："为什么 go-github 要到 v88？"——因为这个库把 GitHub API 的每个版本都当大版本迭代，GitHub REST API 本身变化频繁，这样能保证老代码不被新 API 悄悄改坏。

另外注意 `sigs.k8s.io/yaml` 这个域名不是 `github.com/...`，但它**确实托管在 GitHub**（`sigs.k8s.io` 是 Kubernetes 社区的专用域名，指向 GitHub 上的 `kubernetes-sigs/yaml` 仓库）。域名 ≠ 托管平台。

### 6. 完整的 `require` 语法

一行依赖其实是三段：

```
github.com/redis/go-redis/v9   v9.23.0
└──────── 模块路径 ───────────┘  └─版本─┘
        （去哪拿）              （拿哪个版本）
```

还有一种你暂时用不到但会遇到的形式：

```go
require (
	github.com/foo/bar v1.2.3 // indirect
	github.com/baz/qux v0.0.0-20240101120000-abcdef123456 // 伪版本
	github.com/old/pkg v1.0.0 => github.com/fork/pkg v1.5.0 // 替换
)
```

- **伪版本** `v0.0.0-2024...-abcdef`：依赖还没打 tag，Go 就用提交时间 + 提交哈希生成一个临时版本号
- **replace**（`=>`）：把你依赖的某个库**换成另一个**（常用于 fork 私有版本，或强制降级某个有 bug 的依赖）

---

## 三、go.sum：防伪装的"小票"

和 go.mod 并排躺在项目根目录，本项目有 55 行。

```
github.com/bradleyfalzon/ghinstallation/v2 v2.19.0 h1:KQfD+43pR...
github.com/bradleyfalzon/ghinstallation/v2 v2.19.0/go.mod h1:fe5ECIhCdEn...
```

- 每一行 = 某个模块版本的**哈希校验值**（`h1:` 开头）
- 每个模块版本通常有**两行**：一行是模块 zip 包的哈希，一行是该模块 `go.mod` 文件的哈希（`/go.mod` 后缀）
- 作用：**供应链安全**。Go 会核对下载内容的哈希和 go.sum 里记录的是否一致，不一致就拒绝编译，防止有人偷偷改你依赖的代码

> go.sum **不用手写**，也**不要手动改**。它由 `go mod tidy` / `go mod download` 自动维护。go.sum 里出现某个模块不代表你一定用到它——它可能只是"某个依赖的依赖的 go.mod 被读过"，所以 go.sum 的条目通常**比 go.mod 多**。

---

## 四、依赖从哪来？—— 本地缓存

`go env GOMODCACHE` 的输出（本机）：

```
/Users/lex/go/pkg/mod
```

这就是依赖真正"住"的地方。你可以进去看看：

```
cd /Users/lex/go/pkg/mod
ls github.com/redis/     # → go-redis@v9.23.0
ls github.com/prometheus/ # → client_golang@v1.25.0 ...
```

看目录名能发现 Go 的一个重要约定：**模块在缓存里的文件夹名带 `@版本号`**。同一个模块的不同版本可以同时共存，不会互相覆盖。

所以完整链路是：

```
go.mod 写 "我要 go-redis v9.23.0"
    ↓  go build / go run / go mod download
从 GOPROXY 下载到 /Users/lex/go/pkg/mod/github.com/redis/go-redis/v9@v9.23.0/
    ↓
用 go.sum 校验哈希对不对
    ↓
编译时从缓存目录取源码，链接进你的二进制
```

`GOPROXY`（本机是 `https://proxy.golang.org,direct`）就是"去哪下载"的中转站。`direct` 表示代理挂了就去源站（GitHub）直接拉。国内网络访问 proxy.golang.org 慢，常见做法是配一个国内镜像：

```bash
go env -w GOPROXY=https://goproxy.cn,direct
```

---

## 五、日常命令（够用就行）

| 命令 | 作用 | 什么时候用 |
|---|---|---|
| `go mod tidy` | **同步 go.mod 和 go.sum**：删掉没用到的依赖、补上漏掉的依赖、整理 indirect | 最常用。写完代码、提交前跑一次 |
| `go get github.com/foo/bar@v1.2.3` | 拉一个新依赖进 go.mod 并下载 | 想引入一个新库 |
| `go mod download` | 只下载不修改 go.mod | CI 里预热缓存，加速构建 |
| `go mod why github.com/foo/bar` | 查为什么需要这个依赖 | 排查依赖冲突、清理无用依赖 |
| `go mod graph` | 打印依赖树 | 看传递依赖全貌 |
| `go list -m all` | 列出所有模块（含间接） | 查版本 |
| `go mod verify` | 校验已下载模块的哈希 | 安全检查 |
| `go mod vendor` | 把依赖复制到项目内 `vendor/` 目录 | 内网环境无法联网时 |

### 典型工作流

```bash
# 1. 引入新依赖
go get github.com/google/uuid@latest

# 2. 写代码 import 它

# 3. 清理并同步（这一步会删掉你没用到的 require）
go mod tidy

# 4. 提交 go.mod + go.sum 两个文件
git add go.mod go.sum && git commit -m "chore: add dependency"
```

> ⚠️ **两个文件都要提交**。只提交 go.mod 不提交 go.sum，别人 clone 下来会构建失败。

---

## 六、和 "本地调用" 的关系（回答你的原问题）

你说"一般是做本地调用的吗？还是定义的？"

准确答案是：**它是定义的（声明），但通过它实现了一种"本地调用"的错觉。**

展开说：

1. **Go 没有"全局安装包"这一步**。别的语言（Python 的 `pip install`、Node 的 `npm install`）会把包装到一个全局环境里，你的项目通过环境变量去找它。Go 不是这样——**每个项目都有自己独立的依赖版本清单**。这就是 go.mod 存在的根本原因。

2. **同一个库可以在不同项目里用不同版本，互不干扰**。项目 A 用 `go-redis v9.23.0`，项目 B 用 `go-redis v9.10.0`，完全没冲突。

3. **本项目内部包的"调用"也是靠 module 路径串起来的**。`cmd/server/main.go` 里写：

   ```go
   import "github.com/acme/cr-check/internal/check"
   ```

   Go 工具看到这是**本项目 module 路径的前缀**，就明白：这不是外部库，去本地目录 `internal/check/` 找。找的是本地文件，**不需要下载任何东西**。

   这就是为什么 `internal/` 目录下的包外面的人 import 不到——Go 编译器会直接报错，这是语言级保护（只有以 `github.com/acme/cr-check/` 开头的导入路径才能进 `internal/`）。

4. 对外部包（`github.com/redis/go-redis/v9`），Go 查本地 module 路径前缀**不匹配**，于是去 `go.mod` 的 require 里找版本 → 去缓存目录找源码 → 编译进你的二进制。

---

## 七、module 路径一定要在互联网上真实存在吗？

**不需要。** 这是初学者最常见的误解。

### 7.1 你自己的项目：不要求存在

`module github.com/acme/cr-check` 里的 `acme/cr-check` **完全可以是编造的**。

Go 工具链把「**主模块**（你正在开发的这个项目）」和「**依赖模块**（你引用的别人家的库）」区别对待：

- 主模块的路径**永远不会被下载、不会做网络解析**，它只是一个本地命名空间
- 只有依赖模块才需要真的能拉到源码

我实测了一下（`/tmp/gotest-fake`）：

```bash
$ cat go.mod
module github.com/totally-nonexistent/this-repo-does-not-exist-xyz
go 1.27.3

$ GOPROXY=off go build ./...
✅ 构建成功（完全没有联网，连 GOPROXY 都关掉了）
```

**结论：只要你自己 `go build` / `go run` / `go test`，module 路径写什么都能跑。** 这也是为什么学习阶段可以随便起名字。

### 7.2 什么时候才要求它"真实存在"？

只有当**别人要把你的项目当依赖拉走**的时候：

```bash
go get github.com/acme/cr-check
```

这时 Go 会去解析这个路径。你实测会看到（我刚跑的真实报错）：

```
go: module github.com/acme/cr-check: git ls-remote -q --end-of-options https://github.com/acme/cr-check
    in /Users/lex/go/pkg/mod/cache/vcs/68fee9183...:
    exit status 128:
    fatal: could not read Username for 'https://github.com': terminal prompts disabled
Confirm the import path was entered correctly.
```

翻译：Go 先问 `proxy.golang.org`（代理）→ 代理说「没有这个模块」→ 降级直接问 GitHub → GitHub 发现 `github.com/acme/cr-check` 这个仓库不存在（或者是私有的），于是反过来问你要用户名密码。

### 7.3 GitHub 路径 vs 自定义域名：两条路

| 路径长这样 | Go 怎么找源码 |
|---|---|
| `github.com/用户/仓库` | Go **内置规则**：直接去 `https://github.com/用户/仓库` 拉 git。仓库必须真实存在（公开的，或你有权限的私库） |
| `golang.org/x/tools`、`k8s.io/api`、`sigs.k8s.io/yaml` | Go 先对该域名发 HTTP 请求 `https://域名/路径?go-get=1`，读页面里的 `<meta name="go-import" content="...">` 标签，从里面读出真正的仓库地址 |

第二种叫 **vanity import（自定义导入路径）**，机制是网站返回一个 HTML 头：

```html
<meta name="go-import" content="sigs.k8s.io/yaml git https://github.com/kubernetes-sigs/yaml">
```

含义拆解：

```
sigs.k8s.io/yaml   ← 这个前缀下的所有子路径都归我管
git                ← 用 git 协议
https://github.com/kubernetes-sigs/yaml  ← 实际仓库在这
```

所以 `sigs.k8s.io/yaml` 虽然域名不是 github，但源码**确实**来自 GitHub。`golang.org/x/...` 同理（实际在 `go.googlesource.com`）。

**结论：路径里的域名不一定等于托管平台**，但路径最终必须能映射到一个真实可访问的源码仓库。

### 7.4 那我该怎么选路径？

三条实用原则：

1. **起个你真能控制的路径**。以后想开源/给同事用时不用改名。
   - 想放 GitHub：`github.com/你的用户名/你的仓库名`
   - 公司内部：`github.com/公司名/内部仓库名`（私有库也行，同事 clone 有权限就能用）
   - 完全不发布：`example.com/随便起` 也行（像现在的 `acme/cr-check`）

2. **⚠️ 千万别占用别人的公开路径**。如果你写 `module github.com/google/go-github`，那 `go get` 会拉到**真的 google 那个库**，而不是你的代码。这种"静默拉到错误代码"是最难查的坑。

3. **路径一旦定下来就别改**。因为项目里所有 import 路径都带这个前缀：

   ```
   改 module 路径 = 项目里每个 import 都要跟着改
   ```

   改法（一般用工具）：

   ```bash
   # 全项目替换 module 路径
   grep -rl "github.com/acme/cr-check" --include="*.go" . | xargs sed -i '' 's|github.com/acme/cr-check|github.com/新路径|g'
   ```

   注意 `internal/` 目录的导入权限是**基于路径前缀**判定的，改名时别只改一半。

### 7.5 私有仓库怎么办？

私有模块本身没问题，但要让 Go 知道"别去公共代理、也别查公共校验库"：

```bash
# GOPRIVATE 同时覆盖 GONOPROXY 和 GONOSUMDB
go env -w GOPRIVATE=github.com/我的公司/*

# 私有仓库的 git 凭据：走 git 自己那套
git config --global url."https://oauth2:TOKEN@github.com/".insteadOf "https://github.com/"
# 或者用 ~/.netrc
```

### 7.6 多仓库联动的标准姿势：`replace`

如果你想把模块路径指向一个**本地目录**（而不是线上仓库），用 `replace`：

```go
// go.mod
module github.com/acme/cr-check

require github.com/acme/cr-check-lib v0.0.0

replace github.com/acme/cr-check-lib => ../cr-check-lib
```

效果：任何人 clone 你的仓库后，一条 `go mod tidy` + `replace` 就能把旁边的目录接进来，**完全不需要那个库真的存在于互联网上**。这正是 Go 官方用来做单仓多模块（monorepo）的标准手段。

---

## 八、常见坑速查

| 坑 | 症状 | 解法 |
|---|---|---|
| 忘了提交 go.sum | 别人 clone 后 `missing go.sum entry` | `go mod tidy` 后两个文件一起提交 |
| module 路径写了别人的公开仓库 | `go get` 静默拉到别人的代码 | 用自己控制的路径，或加 `replace` 指到本地 |
| 改了 module 路径但只改了一半 | 部分 import 报 `no required module provides package` | `grep -rl` 全量替换后重新 `go mod tidy` |
| 手动删了 go.mod 的 require | 编译报 `no required module provides package` | `go mod tidy` 自动补回 |
| go 版本对不上 | `go.mod requires go >= 1.27.3` | 升级本地 Go，或调低 go.mod 里的版本 |
| 依赖了大版本 v1 但代码按 v2 写 | API 找不到 | 改 import 路径带 `/v2`，或降级代码 |
| 依赖冲突（两个库要求不同版本） | `ambiguous import` / MVS 选了不兼容的版本 | 用 `replace` 强制统一 |
| vendor 目录过期 | 构建行为和 go.mod 不一致 | `go mod vendor` 重新生成 |
| 本机 GOFLAGS/GOPROXY 是全局的 | 换公司环境编译失败 | `go env -w` 改的是全局配置，注意别污染团队 |

### 依赖冲突是怎么解决的？—— MVS（最小版本选择）

当 A 库要 `x v1.2.0`、B 库要 `x v1.5.0` 时，Go 选 **v1.5.0**（取所有要求里最高的那个），这个算法叫 Minimal Version Selection。

意思就是：**Go 不会自动降级**。如果你需要降级，得手动写 `replace`。

---

## 九、一张图记住全部

```
┌─────────────────────────────────────────────┐
│  cr-check/                                   │
│                                             │
│   go.mod  ────┐  声明：我叫 X，我要 A v1, B v2 │
│   go.sum  ────┤  校验：这些内容的哈希是 xxx   │
│               │                             │
│   cmd/server/main.go                        │
│   internal/check/...                        │
│               │                             │
│   import "github.com/acme/cr-check/internal/check"  ← 本地包
│   import "github.com/redis/go-redis/v9"            ← 外部包
└───────────────┼─────────────────────────────┘
                ↓ go build / go run
      ┌─────────────────────────┐
      │ Go 工具链读 go.mod      │
      │ 去 GOPROXY 下载         │
      │ 校验 go.sum 哈希        │
      │ 缓存到 GOMODCACHE       │
      └──────────┬──────────────┘
                 ↓
        编译成二进制文件
```

---

## 自测

- [ ] 我能解释 `module` 那一行的两个作用
- [ ] 我能解释为什么 `go-redis` 路径里有 `/v9` 而 `sigs.k8s.io/yaml` 没有
- [ ] 我知道 `// indirect` 是什么意思，以及为什么 `go mod tidy` 会动它
- [ ] 我能说出 go.sum 和 go.mod 的区别
- [ ] 我知道依赖源码实际躺在哪个目录
- [ ] 我能解释为什么项目内部包 import 时不需要下载任何东西
- [ ] 我知道自己的 module 路径**不需要**在互联网上真实存在，以及什么时候才会被要求存在
- [ ] 我知道 `github.com/...` 和 `sigs.k8s.io/...` 两种路径 Go 分别怎么找源码

---

## 相关

- [`../base/practice/03-go-toolchain.md`](../base/practice/03-go-toolchain.md) —— 工具链手册
- [`../base/00-index.md`](../base/00-index.md) —— 核心概念速查（基于 cr-check 项目）
- 官方文档：[Go Modules Reference](https://go.dev/ref/mod) / [Module 版本和后缀](https://go.dev/ref/mod#major-version-suffixes)
