# 11 · net/http（Web 服务端与客户端）

> 一句话：**Go 的 `net/http` 是标准库自带的完整 HTTP 框架**，
> 服务端、客户端、路由、中间件、超时、优雅关闭全都有，**不需要第三方框架**。
> cr-check 就是一个纯标准库的 webhook 服务。

---

## 1. 服务端：Handler 接口

```go
type Handler interface {
    ServeHTTP(ResponseWriter, *Request)
}
```

**只要实现了这个方法，就是一个 Handler。** 这就是"隐式接口"的威力。

cr-check 的 `webhook.Handler`：

```go
// internal/webhook/handler.go
func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
    if r.Method != http.MethodPost {
        writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "只接受 POST"})
        return
    }
    ...
}
```

挂到路由上：

```go
mux := http.NewServeMux()
mux.Handle("POST /github/webhook", handler)
```

**★ 关键点：`handler` 的类型是 `*webhook.Handler`，
但 `mux.Handle` 要的是 `http.Handler` —— Go 自动做了隐式接口转换。**
这就是为什么 `Handler` 里不用写 `var _ http.Handler = (*Handler)(nil)`。

---

## 2. ★ 路由：Go 1.22+ 的方法+路径模式

Go 1.22 之前要用第三方库（gorilla/mux、chi）才能路由。
Go 1.22+ **标准库自带了**：

```go
mux := http.NewServeMux()

mux.Handle("POST /github/webhook", handler)        // 方法 + 精确路径
mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
    w.WriteHeader(http.StatusOK)
    _, _ = w.Write([]byte("ok\n"))
})
mux.HandleFunc("GET /metrics", metrics.Handler())
mux.HandleFunc("GET /mock/cr/{number}", mockCR.Handler("/mock/cr/"))  // 路径参数
```

cr-check 的 go.mod 是 `go 1.27.3`，可以直接用。

### 模式语法速查

| 写法 | 含义 |
|---|---|
| `"/"` | 匹配所有（未匹配的都会落到这里） |
| `"/healthz"` | 精确路径 |
| `"GET /healthz"` | 限定方法 |
| `"/mock/cr/{number}"` | 路径参数 → `r.PathValue("number")` |
| `"GET /"` | 只匹配 GET 的根路径 |
| `"GET /{$}"` | 只匹配根路径（`/` 的精确形式） |

> ★ **注意**：`"/"` 是"前缀匹配"，能匹配所有路径；
> 要精确匹配根路径得写 `"GET /{$}"`。
> cr-check 里用的是老写法自己处理：

```go
mux.HandleFunc("GET /", func(w http.ResponseWriter, r *http.Request) {
    if r.URL.Path != "/" {
        http.NotFound(w, r)
        return
    }
    ...
})
```

### ★ 方法不匹配的 405

Go 1.22+ 的 ServeMux 会**自动**返回 `405 Method Not Allowed`
（而不是 404），并设置 `Allow` 头。这比手写判断更省事。

---

## 3. Request / ResponseWriter

### Request 里最常用的字段

```go
r.Method        // "POST"
r.URL.Path      // "/github/webhook"
r.Header.Get("X-GitHub-Event")
r.Context()     // ★ 请求级 ctx
r.Body          // io.ReadCloser
r.RemoteAddr
r.PathValue("number")  // Go 1.22+ 路径参数
```

### ResponseWriter 的正确用法

```go
// internal/webhook/handler.go
func writeJSON(w http.ResponseWriter, status int, body any) {
    w.Header().Set("Content-Type", "application/json; charset=utf-8")
    w.WriteHeader(status)                    // ★ 只能调一次，且要在 Write 之前
    enc := json.NewEncoder(w)
    enc.SetIndent("", "  ")
    _ = enc.Encode(body)
}
```

**★ 三个坑**：

1. **`WriteHeader` 只能调一次**，第二次会打日志 "superfluous WriteHeader call"
2. **`WriteHeader` 必须在 `Write` 之前**，否则第一次 `Write` 会隐式发 200
3. **忘记设 Content-Type** → 浏览器/客户端会猜，可能拿到 `text/plain`

---

## 4. ★ 中间件（Middleware）

Go 没有 gin/echo 那种"中间件数组"，但模式很固定：

```go
// 中间件 = func(http.Handler) http.Handler
func Logging(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        start := time.Now()
        next.ServeHTTP(w, r)
        slog.Info("request", "method", r.Method, "path", r.URL.Path, "cost", time.Since(start))
    })
}
```

用起来：

```go
mux := http.NewServeMux()
mux.Handle("POST /github/webhook", handler)

srv := &http.Server{
    Addr:    cfg.Server.Addr,
    Handler: Logging(mux),      // ★ 包一层
}
```

> ★ **cr-check 目前没有中间件层**，
> 但生产化时通常要加：panic recovery、请求日志、trace id 注入、鉴权。
> 这也是 [10-error.md](10-error.md) 里提到的 recover 中间件该放的地方。

### ★ 写中间件时注意：要包装 ResponseWriter 才能拿到状态码

```go
type statusRecorder struct {
    http.ResponseWriter
    status int
}

func (r *statusRecorder) WriteHeader(code int) {
    r.status = code
    r.ResponseWriter.WriteHeader(code)
}
```

> ★ 包装了 `ResponseWriter` 就**丢掉了 `http.Flusher` / `Hijacker` / `Pusher`**，
> 对 SSE/WebSocket 有影响。生产框架一般会提供 `httpsnoop` 这类工具包处理。

---

## 5. ★ 超时：四个层次

**Go 1.20+ 的 `http.Server` 有四个独立的超时**，缺一个就可能被慢连接打挂：

```go
// cmd/server/main.go
srv := &http.Server{
    Addr:              cfg.Server.Addr,
    Handler:           mux,
    ReadHeaderTimeout: 10 * time.Second,   // ★ 读请求头超时（防 slowloris）
    WriteTimeout:      30 * time.Second,   // ★ 写响应超时
    IdleTimeout:       60 * time.Second,   // ★ keep-alive 空闲超时
}
```

| 配置 | 不设会怎样 |
|---|---|
| `ReadHeaderTimeout` | 客户端连上不发请求头 → **goroutine 挂死** |
| `WriteTimeout` | 客户端不读响应 → 服务端一直写 |
| `IdleTimeout` | keep-alive 连接堆积 → FD 耗尽 |
| `ReadTimeout` | 读请求体超时（慢速上传） |

> ★ **只设 `WriteTimeout` 不设 `ReadHeaderTimeout` 是最常见的漏洞**。
> Go 官方文档明确说：
> "ReadHeaderTimeout ... If zero, the value of ReadTimeout is used. To set a deadline for reading the entire request, set ReadTimeout."

### ★ 服务端超时的坑

`WriteTimeout` 是**从请求头读完开始算**的。
如果 handler 里要处理很长的任务（这里就是判定流程），30 秒可能不够。
cr-check 的对策是：**webhook 快速 ACK，判定放后台队列**。

```go
// internal/webhook/handler.go
if !h.SyncEval {
    job := queue.Job{...}
    if !h.Queue.Push(job) { ... }
    writeJSON(w, http.StatusAccepted, map[string]any{"status": "queued", ...})
    return
}
```

> ★ 这正是 `server.syncEval` 配置项存在的原因，
> 注释里写得很清楚：**"生产必须 false —— 先 ACK 再异步，避免超过 GitHub 的 10 秒投递预算。"**

---

## 6. ★ 优雅关闭

```go
// cmd/server/main.go
ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
defer stop()

go func() {
    if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
        logger.Error("HTTP 服务退出", "err", err)
        stop()
    }
}()

<-ctx.Done()
logger.Info("收到退出信号，开始优雅关闭")
shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
defer cancel()
return srv.Shutdown(shutdownCtx)
```

**★ `Shutdown` 做了什么**：
1. 关闭 listener（不再接受新连接）
2. **等所有在途请求跑完**
3. 超时（10 秒）后强制关闭

**★ `Shutdown` vs `Close`**

| | 行为 |
|---|---|
| `Shutdown(ctx)` | 等在途请求完成（优雅） |
| `Close()` | 立刻断掉所有连接（粗暴） |

> ★ k8s 部署时**建议配 `preStop` hook + `terminationGracePeriodSeconds`**，
> 否则 Pod 被 SIGTERM 后立刻被强杀，在途请求会断掉。
>
> ⚠️ **cr-check 目前是一个缺口**：`deploy/deployment.yaml` 里
> 探针、resources、PDB 都配全了，但**没有 `preStop` / `terminationGracePeriodSeconds`**，
> 而代码里的 `srv.Shutdown(shutdownCtx)` 最多等 10 秒 ——
> 这段时间完全可能被 k8s 的默认 30 秒宽限期直接砍掉。
> 补上：
> ```yaml
> lifecycle:
>   preStop:
>     exec:
>       command: ["sleep", "5"]     # 先让 Endpoints 更新完，再开始关
> terminationGracePeriodSeconds: 40
> ```

---

## 7. HTTP 客户端

```go
// internal/crplatform/crplatform.go
type HTTPClient struct {
    baseURL string
    token   string
    path    string
    aliases map[string][]string
    http    *http.Client          // ★ 复用 client
}

func NewHTTPClient(baseURL, token, path string, timeout time.Duration, aliases map[string][]string) *HTTPClient {
    return &HTTPClient{
        baseURL: strings.TrimRight(baseURL, "/"),
        ...
        http: &http.Client{Timeout: timeout},
    }
}
```

### ★ 三条客户端铁律

**铁律 1：★ 不要每次请求都 new 一个 `http.Client`**

```go
// ❌❌❌ 千万别这样
resp, err := (&http.Client{Timeout: 5 * time.Second}).Get(url)
```

原因：`http.Client` 内部维护了**连接池**。
每次 new 一个 = 每次新建 TCP 连接 + TLS 握手 → **性能灾难 + 端口耗尽**。

正确做法：**在结构体里存一个 client，全局复用**（cr-check 就是这么做的）。

**铁律 2：请求必须带 ctx**

```go
req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
resp, err := c.http.Do(req)
```

**铁律 3：必须 close body**

```go
defer func() { _ = resp.Body.Close() }()
```

> ★ **不 Close 会导致连接泄漏**：
> body 不读完也不关，连接永远不释放 → 最终 `too many open files`。

---

## 8. ★ 状态码：webhook 场景的语义

cr-check 里的状态码选择很有讲究，值得学：

| 场景 | 状态码 | 位置 |
|---|---|---|
| 判定完成 | `200 OK` | `handlePullRequest` 同步模式 |
| 已入队，等后台处理 | `202 Accepted` | 异步模式 |
| 验签失败 | `401 Unauthorized` | `ServeHTTP` |
| payload 解析失败 | `400 Bad Request` | `handlePullRequest` |
| 方法不对 | `405 Method Not Allowed` | `ServeHTTP` |
| **队列满** | `503 Service Unavailable` | `handlePullRequest` |

**★ 为什么队列满要返回 503？**

GitHub 的 webhook 投递失败会**自动重投**。
返回 503 = 明确告诉 GitHub"我现在不行，待会儿再来"；
返回 200 = GitHub 认为成功了，事件就**永久丢失**。

这和 cr-check 的定时重扫机制是配套的（重扫是最后一道兜底）。

### ★ 幂等：返回 200 + duplicate 而不是 4xx

```go
// internal/webhook/handler.go
} else if seen {
    h.Metrics.WebhookRejected.WithLabelValues("duplicate").Inc()
    writeJSON(w, http.StatusOK, map[string]any{
        "status": "duplicate", "reason": "该 delivery id 已处理过", "delivery_id": delivery,
    })
    return
}
```

重复投递是**正常情况**，不是错误 → 返回 200，
否则 GitHub 会一直重投。

---

## 9. ★ 探针接口

k8s 部署必须有两个探针：

```go
// cmd/server/main.go
mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
    w.WriteHeader(http.StatusOK)
    _, _ = w.Write([]byte("ok\n"))
})

mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, r *http.Request) {
    // readiness 要包含"能拿到 installation token"，
    // 否则私钥/网络故障时 Pod 仍然 Ready → 请求全失败
    ready := map[string]any{"ready": true, "mode": mode}
    if mode == "real" {
        ready["github_credentials"] = cfg.HasGitHubCredentials()
        ready["cr_platform"] = cfg.HasCRPlatform()
    }
    webhook.WriteJSON(w, http.StatusOK, ready)
})
```

| 探针 | 语义 | 失败后果 |
|---|---|---|
| `/healthz`（liveness） | 进程还活着吗 | **重启** Pod |
| `/readyz`（readiness） | 现在能接流量吗 | **摘出** Endpoints，不重启 |

> ★ **★ 关键区别**：liveness 失败 = 重启；readiness 失败 = 暂时不派流量。
>
> **千万别把"依赖不可用"写进 liveness** ——
> CR 平台挂了导致 liveness 失败 → Pod 被反复重启 → 雪上加霜。
> 依赖状态应该放 readiness。

---

## 10. 一句话总结

> **Go 的 HTTP = 标准库全家桶，不用框架。**
> - 实现 `ServeHTTP` 就是 Handler，隐式满足 `http.Handler`
> - Go 1.22+ 的 ServeMux 支持 `"POST /path/{param}"` 模式
> - 中间件模式 = `func(http.Handler) http.Handler`
> - **客户端要复用、要带 ctx、要关 body**
> - **`http.Server` 四个超时 + `Shutdown` 优雅关闭**
> - webhook 状态码有讲究：503 让对方重试，200 让对方别重试

---

## 11. 自测题

1. 为什么 `webhook.Handler` 不需要写 `var _ http.Handler = (*Handler)(nil)` 这样的断言？
2. `mux.Handle("/x", h)` 和 `mux.Handle("GET /x", h)` 的区别？后者对 `POST /x` 返回什么？
3. 为什么每次请求都 `&http.Client{}` 是性能灾难？
4. `WriteTimeout` 30 秒和 GitHub 的 10 秒投递预算有什么关系？cr-check 怎么解决的？
5. `/healthz` 和 `/readyz` 失败时，k8s 分别会做什么？为什么依赖检查要放 readiness？
6. 队列满时返回 503 而不是 200，是为了让谁做什么？

---

上一篇：[10-error.md](10-error.md) ｜ 下一篇：[12-json.md](12-json.md) ｜ 回到 [00-index.md](00-index.md)
