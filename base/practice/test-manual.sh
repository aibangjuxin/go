#!/usr/bin/env bash
#
# ==============================================================================
#  cr-check 测试脚本（与同目录 test-manual.md 配套）
# ==============================================================================
#
#  这个脚本做三件事：
#    1) 自己编译、自己起服务、自己停服务（不需要你手动开终端）
#    2) 每一步都把过程打印出来：
#         怎么起的服务  →  发了什么请求  →  返回了什么  →  断言结论是什么
#    3) 最后打印「接口覆盖矩阵」：每个端点测没测、测了什么、结果如何
#
#  用法：
#    ./test-manual.sh                # 全量跑（推荐）
#    ./test-manual.sh -k 18081       # 指定基础端口（默认 18081，逐个递增）
#    KEEP_LOGS=1 ./test-manual.sh    # 跑完保留临时目录与所有服务日志
#    ONLY=rules ./test-manual.sh     # 只跑某一阶段（见下方 PHASE 列表）
#
#  阶段：
#    env      环境自检 + 编译
#    boot     启动主服务 + 探针/配置端点
#    rules    判定规则用例 R1..R7
#    http     入口协议用例（分支过滤/幂等/事件/action/坏包/方法）
#    sign     webhook 验签
#    async    生产形态：先 ACK 再异步（202 queued）
#    extra    扩展 mock 数据用例（白名单/自审批/未知状态/未生效）
#    window   维护窗口边界（开闭区间 + 周末）
#    obs      可观测性端点（audit/registry/last-check/metrics/recheck）
#    matrix   接口覆盖矩阵 + 汇总
#
#  退出码：0 = 全通过，1 = 有失败
#
# ==============================================================================

set -uo pipefail

# ── 基础配置 ─────────────────────────────────────────────────────────────────
CR_DIR="${CR_DIR:-/Users/lex/git/go/cr-check}"
CFG="$CR_DIR/config/policy.yaml"
BASE_PORT="${BASE_PORT:-}"
KEEP_LOGS="${KEEP_LOGS:-0}"
ONLY="${ONLY:-}"

WORK="$(mktemp -d)"
BIN="$WORK/cr-check"

PASS=0
FAIL=0
TOTAL=0
PIDS=()

# CASE_RESULTS: 每行 "case_id|PASS|FAIL"
CASE_RESULTS=""
# CASE_EP: 每行 "case_id|endpoint|result"（用例 → 端点映射）
CASE_EP=""
# CUR_EP: 当前正在验证的端点（供 check 家族登记用）
CUR_EP=""
# EP_TABLE: 每行 "endpoint|scenario|case_ids|result"
EP_TABLE=""
# 当前阶段（场景名）与该场景已收集的用例编号
CURRENT_SCENE=""
SCENE_CASES=""

# ── 颜色与输出 ───────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  C_RST=$'\033[0m'; C_B=$'\033[1m'; C_DIM=$'\033[2m'
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_BLU=$'\033[34m'; C_C=$'\033[36m'
else
  C_RST=""; C_B=""; C_DIM=""; C_R=""; C_G=""; C_Y=""; C_BLU=""; C_C=""
fi

section() {
  printf '\n%s%s%s\n' "${C_B}${C_BLU}" "════════════════════════════════════════════════════════════════════════════════════" "${C_RST}"
  printf '%s  %s%s\n' "${C_B}${C_BLU}" "$1" "${C_RST}"
  printf '%s%s%s\n' "${C_B}${C_BLU}" "════════════════════════════════════════════════════════════════════════════════════" "${C_RST}"
}

sub() {
  printf '\n%s── %s ─────────────────────────────────────────────%s\n' "${C_B}${C_C}" "$1" "${C_RST}"
}

step()  { printf '%s  ▶ %s%s\n' "${C_C}" "$1" "${C_RST}"; }
note()  { printf '%s    %s%s\n' "${C_DIM}" "$1" "${C_RST}"; }
info()  { printf '%s    · %s%s\n' "${C_B}" "$1" "${C_RST}"; }
warn()  { printf '%s    ! %s%s\n' "${C_Y}" "$1" "${C_RST}"; }
err()   { printf '%s    ✗ %s%s\n' "${C_R}" "$1" "${C_RST}"; }

pass() { # $1=case_id  $2=显示文本
  TOTAL=$((TOTAL+1)); PASS=$((PASS+1))
  printf '%s    ✅ PASS%s  %s\n' "${C_G}" "${C_RST}" "$2"
  CASE_RESULTS="${CASE_RESULTS}$1|PASS"$'\n'
  CASE_EP="${CASE_EP}$1|${CUR_EP}|PASS"$'\n'
}
fail() { # $1=case_id  $2=期望  $3=实际
  TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1))
  printf '%s    ❌ FAIL%s  %s\n' "${C_R}" "${C_RST}" "$1"
  printf '%s        期望: %s%s\n' "${C_DIM}" "$2" "${C_RST}"
  printf '%s        实际: %s%s\n' "${C_DIM}" "$3" "${C_RST}"
  CASE_RESULTS="${CASE_RESULTS}$1|FAIL"$'\n'
  CASE_EP="${CASE_EP}$1|${CUR_EP}|FAIL"$'\n'
}

# case_result 取某个用例的结果
case_result() {
  local cid="$1" line
  while IFS= read -r line; do
    case "$line" in
      "$cid|"*) printf '%s' "${line#*|}"; return ;;
    esac
  done <<EOF
$CASE_RESULTS
EOF
  printf 'UNKNOWN'
}

# cov 把一个「端点 × 场景」登记进覆盖矩阵
cov() { # $1=端点  $2=场景  $3=用例编号(逗号分隔)
  local ep="$1" scene="$2" cases="$3" res="PASS" c
  for c in $(printf '%s' "$cases" | tr ',' ' '); do
    [ "$(case_result "$c")" = "PASS" ] || res="FAIL"
  done
  EP_TABLE="${EP_TABLE}${ep}|${scene}|${cases}|${res}"$'\n'
}

# scene_begin 开始一个新场景
scene_begin() {
  CURRENT_SCENE="$1"
  SCENE_CASES=""
}

# scene_end 结束当前场景并登记进矩阵
scene_end() {
  local ep="$1"
  [ -n "$SCENE_CASES" ] && cov "$ep" "$CURRENT_SCENE" "$SCENE_CASES"
}

# 把多行文本缩进 8 空格
indent() { sed 's/^/        /'; }

# 漂亮打印 JSON
pretty() {
  if printf '%s' "$1" | jq . >/dev/null 2>&1; then
    printf '%s' "$1" | jq .
  else
    printf '%s' "$1"
  fi
}

# ── 清理 ─────────────────────────────────────────────────────────────────────
cleanup() {
  printf '\n'
  sub "清理"
  for p in ${PIDS[@]+"${PIDS[@]}"}; do
    if kill -0 "$p" 2>/dev/null; then
      kill "$p" 2>/dev/null
      wait "$p" 2>/dev/null
      note "已停止服务 pid=$p"
    fi
  done
  # 兜底：按二进制路径杀（BIN 是本次运行独有的临时路径，不会误伤别人的进程）
  if [ -n "${BIN:-}" ] && [ -f "$BIN" ]; then
    pkill -f "$BIN" 2>/dev/null && note "兜底清理：已按二进制路径终止残留进程"
  fi
  wait 2>/dev/null
  if [ "$KEEP_LOGS" = "1" ]; then
    info "日志保留在: $WORK"
  else
    rm -rf "$WORK"
    note "临时目录已清理（KEEP_LOGS=1 可保留）"
  fi
}
trap cleanup EXIT INT TERM

# ── 阶段开关 ─────────────────────────────────────────────────────────────────
want() {
  [ -z "$ONLY" ] && return 0
  [ "$ONLY" = "$1" ] && return 0
  return 1
}

# ── 参数解析 ─────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    -k|--port) BASE_PORT="$2"; shift 2 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "未知参数: $1"; exit 2 ;;
  esac
done

# ── 端口分配 ─────────────────────────────────────────────────────────────────
port_busy() { lsof -ti tcp:"$1" >/dev/null 2>&1; }

free_port() {
  local p="$1"
  while port_busy "$p"; do p=$((p+1)); done
  echo "$p"
}

if [ -z "$BASE_PORT" ]; then BASE_PORT=18081; fi
BASE_PORT=$(free_port "$BASE_PORT")

# 默认基地址（单阶段运行时可能没走过 ② 阶段）
BASE_URL="http://localhost:$BASE_PORT"
SAVE_BASE="$BASE_URL"

# ── 服务生命周期 ─────────────────────────────────────────────────────────────
# svc_start <名字> <端口> [额外参数...]
#   返回 0 = 启动成功并已通过健康检查
svc_start() {
  local name="$1" port="$2"; shift 2
  local log="$WORK/svc-$name.log"
  "$BIN" -config "$CFG" -addr ":$port" "$@" >"$log" 2>&1 &
  local pid=$!
  PIDS+=("$pid")
  echo "$pid" >"$WORK/svc-$name.pid"

  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50; do
    if curl -sf -m 2 "http://localhost:$port/healthz" >/dev/null 2>&1; then
      SVC_PID="$pid"; SVC_PORT="$port"; SVC_LOG="$log"; SVC_NAME="$name"
      return 0
    fi
    sleep 0.2
  done
  SVC_PID="$pid"; SVC_PORT="$port"; SVC_LOG="$log"; SVC_NAME="$name"
  return 1
}

svc_stop() {
  local pid="$1"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    note "服务 $2 (pid=$pid) 已停止"
  fi
}

svc_startup_log() {
  local log="$1"
  grep -E '"msg":"(启动 CR Check|mock 模式|定时重扫已启动|HTTP 服务已启动|使用固定时间|收到退出信号)' "$log" 2>/dev/null \
    | while IFS= read -r line; do printf '        %s\n' "$line"; done
}

# ── 请求执行 ─────────────────────────────────────────────────────────────────
# 全局：HDR_EVENT / HDR_DELIVERY / HDR_SIGNATURE / BASE_URL
# 输出：RESP_STATUS / RESP_BODY
RESP_STATUS=""
RESP_BODY=""
LAST_REQ_URL=""
LAST_REQ_METHOD=""
LAST_REQ_HEADERS=()
LAST_REQ_FILE=""

do_request() {
  local method="$1" path="$2" payload="$3"; shift 3
  local url="${BASE_URL}${path}"
  local args=(-s -m 20 -o "$WORK/.resp" -w '%{http_code}' -X "$method")

  if [ -n "${HDR_DELIVERY:-}" ]; then
    args+=(-H "X-GitHub-Delivery: ${HDR_DELIVERY}")
  fi
  if [ -n "${HDR_EVENT:-}" ]; then
    args+=(-H "X-GitHub-Event: ${HDR_EVENT}")
  fi
  args+=(-H 'Content-Type: application/json')
  if [ -n "${HDR_SIGNATURE:-}" ]; then
    args+=(-H "X-Hub-Signature-256: ${HDR_SIGNATURE}")
  fi
  if [ "$method" = "POST" ] && [ -n "$payload" ] && [ -f "$payload" ]; then
    args+=(--data-binary "@${payload}")
  fi

  LAST_REQ_URL="$url"
  LAST_REQ_METHOD="$method"
  LAST_REQ_FILE="$payload"

  RESP_STATUS="$(curl "${args[@]}" "$@" "$url")"
  RESP_BODY="$(cat "$WORK/.resp" 2>/dev/null)"
}

show_request() {
  info "请求: ${LAST_REQ_METHOD} ${LAST_REQ_URL}"
  local h
  for h in "${LAST_REQ_HEADERS[@]:-}"; do
    [ -n "$h" ] && printf '          %s\n' "$h"
  done
  if [ -n "$LAST_REQ_FILE" ] && [ -f "$LAST_REQ_FILE" ]; then
    printf '        %s请求体:%s\n' "${C_DIM}" "${C_RST}"
    pretty "$(cat "$LAST_REQ_FILE")" | indent
  fi
}

show_response() {
  printf '        %s── 响应 (HTTP %s) ──%s\n' "${C_DIM}" "${RESP_STATUS}" "${C_RST}"
  printf '%s\n' "$RESP_BODY" | indent
}

# ── payload 生成 ─────────────────────────────────────────────────────────────
# mkpayload <action> <base> <labels_json> <body> <pr_num> <head_sha> <输出文件>
mkpayload() {
  cat > "$7" <<EOF
{
  "action": "$1",
  "number": $5,
  "pull_request": {
    "number": $5,
    "title": "feat(api): 新增订单查询接口",
    "body": "$4",
    "base": { "ref": "$2", "repo": { "full_name": "acme/platform" } },
    "head": { "sha": "$6" },
    "user": { "login": "alice" },
    "labels": $3
  },
  "repository": { "name": "platform", "full_name": "acme/platform", "owner": { "login": "acme" } },
  "installation": { "id": 98765432 }
}
EOF
}

SHA="a1b2c3d4e5f6789012345678901234567890abcdef"

# ── 用例执行器 ───────────────────────────────────────────────────────────────
# tc <编号> <标题> <jq表达式> <期望值> <payload文件>
#   · 先打印请求 → 打印响应 → 再做断言
tc() {
  local id="$1" title="$2" expr="$3" expect="$4" pf="$5"
  local actual
  CUR_EP="POST /github/webhook"

  HDR_EVENT="pull_request"
  HDR_DELIVERY="t-$(uuidgen)"
  HDR_SIGNATURE=""
  LAST_REQ_HEADERS=("X-GitHub-Event: pull_request" "X-GitHub-Delivery: ${HDR_DELIVERY}" "Content-Type: application/json")

  do_request POST "/github/webhook" "$pf"

  printf '\n%s  ▶ %s · %s%s\n' "${C_B}" "$id" "$title" "${C_RST}"
  show_request
  show_response

  actual="$(printf '%s' "$RESP_BODY" | jq -r "$expr" 2>/dev/null)"
  printf '        %s── 断言 ──%s\n' "${C_DIM}" "${C_RST}"
  printf '        表达式: %s%s\n' "${C_DIM}" "$expr" "${C_RST}"
  printf '        期望值: %s%s\n' "${C_DIM}" "$expect" "${C_RST}"

  if [ "$actual" = "$expect" ]; then
    pass "$id" "${title}  实际: ${actual}"
  else
    fail "$id" "$expect" "${actual:-<空>}"
  fi
  SCENE_CASES="${SCENE_CASES}${SCENE_CASES:+,}${id}"
}
# 断言（非 webhook 用）  $1="CASE-ID  描述"
check() {
  local name="$1" expr="$2" expect="$3" body="$4"
  local cid="${name%% *}" desc="${name#* }"
  local actual
  actual="$(printf '%s' "$body" | jq -r "$expr" 2>/dev/null)"
  SCENE_CASES="${SCENE_CASES}${SCENE_CASES:+,}${cid}"
  if [ "$actual" = "$expect" ]; then
    pass "$cid" "${desc}  实际: ${actual}"
  else
    fail "$cid" "$expect" "${actual:-<空>}"
  fi
}

# 断言（纯文本响应，用来做字符串比较）
check_raw() {
  local name="$1" expect="$2" body="$3"
  local cid="${name%% *}" desc="${name#* }"
  local actual
  actual="$(printf '%s' "$body" | head -1)"
  SCENE_CASES="${SCENE_CASES}${SCENE_CASES:+,}${cid}"
  if [ "$actual" = "$expect" ]; then
    pass "$cid" "${desc}  实际: ${actual}"
  else
    fail "$cid" "$expect" "${actual:-<空>}"
  fi
}

# 断言（HTTP 状态码）
check_status() {
  local name="$1" expect="$2" actual="$3"
  local cid="${name%% *}" desc="${name#* }"
  SCENE_CASES="${SCENE_CASES}${SCENE_CASES:+,}${cid}"
  if [ "$actual" = "$expect" ]; then
    pass "$cid" "${desc}  实际: HTTP ${actual}"
  else
    fail "$cid" "HTTP ${expect}" "HTTP ${actual}"
  fi
}

# 断言（文本响应里包含某段内容）
check_has() {
  local name="$1" needle="$2" body="$3"
  local cid="${name%% *}" desc="${name#* }"
  SCENE_CASES="${SCENE_CASES}${SCENE_CASES:+,}${cid}"
  if printf '%s' "$body" | grep -q -- "$needle"; then
    pass "$cid" "${desc}  实际: 命中「${needle}」"
  else
    fail "$cid" "响应中包含「${needle}」" "未命中"
  fi
}

# ==============================================================================
# 阶段 ①  环境自检（编译是所有阶段的前提，所以无条件执行）
# ==============================================================================
if want env; then
section "①  环境自检"

  info "被测工程: $CR_DIR"
  if [ ! -d "$CR_DIR" ]; then
    err "目录不存在: $CR_DIR"; exit 1
  fi
  info "策略配置: $CFG"
  [ -f "$CFG" ] || { err "配置文件不存在"; exit 1; }

  for t in jq uuidgen openssl curl; do
    if command -v "$t" >/dev/null 2>&1; then
      v="$($t --version 2>&1 | head -1)"
      note "$(printf '%-10s ✅ %s' "$t" "$v")"
    else
      err "缺少命令: $t"
    fi
  done
  if command -v go >/dev/null 2>&1; then
    note "$(printf '%-10s ✅ %s' "go" "$(go version 2>&1 | head -1)")"
  else
    err "缺少命令: go"
  fi

  info "基础端口: $BASE_PORT（被占用会自动顺延）"
fi

# 编译（所有阶段的前提）
info "编译被测服务（一次编译，后续所有实例复用同一个二进制）"
if (cd "$CR_DIR" && go build -o "$BIN" ./cmd/server) 2>"$WORK/build.err"; then
  note "✅ 编译成功: $BIN"
else
  err "❌ 编译失败："
  cat "$WORK/build.err" | indent
  exit 1
fi

# ==============================================================================
# 阶段 ②  启动主服务 + 探针 / 配置端点
# ==============================================================================
PORT_MAIN=""
if want boot || want rules || want http || want obs; then
section "②  启动主服务（mock 模式 · 固定时间落在维护窗口内）"

  PORT_MAIN=$(free_port "$BASE_PORT")
  NOW_MAIN="2025-01-06T03:00:00+08:00"

  note "为什么加 -now：维护窗口是 Mon-Fri 02:00-04:00，真实时间跑必然被 R6w 拦下。"
  note "        -now 把「当前时间」固定到 2025-01-06(周一) 03:00 —— 窗口内，其它规则才是干净的绿。"

  step "启动服务："
  printf '        %s%s%s\n' "${C_DIM}" \
    "$BIN -config $CFG -mode mock -addr :$PORT_MAIN -sync-eval -now $NOW_MAIN" "${C_RST}"

  if svc_start main "$PORT_MAIN" -mode mock -sync-eval -now "$NOW_MAIN"; then
    info "✅ 服务已就绪（健康检查通过），pid=$SVC_PID 端口=$PORT_MAIN"
  else
    err "❌ 服务启动失败，日志："
    svc_startup_log "$SVC_LOG" | indent
    exit 1
  fi
  note "启动日志："
  svc_startup_log "$SVC_LOG" | indent

  BASE_URL="http://localhost:$PORT_MAIN"

  step "GET / —— 首页（确认服务加载了正确的配置）"
  scene_begin "首页（服务自述）"
  CUR_EP="GET /"
  do_request GET "/" ""
  LAST_REQ_HEADERS=()
  show_request
  show_response
  check_has "TC-BOOT-00  首页包含 check 名字与受管分支" "cr/prod-validation" "$RESP_BODY"
  scene_end "GET /"

  step "GET /healthz —— 存活探针"
  scene_begin "存活探针"
  CUR_EP="GET /healthz"
  do_request GET "/healthz" ""
  LAST_REQ_HEADERS=()
  show_request
  show_response
  check_raw "TC-BOOT-01  /healthz 返回 ok" "ok" "$RESP_BODY"
  scene_end "GET /healthz"

  step "GET /readyz —— 就绪探针"
  scene_begin "就绪探针"
  CUR_EP="GET /readyz"
  do_request GET "/readyz" ""
  LAST_REQ_HEADERS=()
  show_request
  show_response
  check "TC-BOOT-02  /readyz ready=true" '.ready' "true" "$RESP_BODY"
  scene_end "GET /readyz"

  step "GET /internal/policy —— 生效配置（脱敏）"
  scene_begin "生效配置（脱敏）"
  CUR_EP="GET /internal/policy"
  do_request GET "/internal/policy" ""
  LAST_REQ_HEADERS=()
  show_request
  show_response
  check "TC-BOOT-03  /internal/policy checkName" '.checkName' "cr/prod-validation" "$RESP_BODY"
  check "TC-BOOT-04  /internal/policy 受管分支" '.managedBranches|join(",")' "release/prd,release/prod" "$RESP_BODY"
  check "TC-BOOT-05  /internal/policy 状态白名单" '.allowedStatuses|join(",")' "approved,implement" "$RESP_BODY"
  scene_end "GET /internal/policy"
fi

# ==============================================================================
# 阶段 ③  判定规则用例
# ==============================================================================
if want rules; then
section "③  判定规则用例（R1 ~ R7）"

  note "mock 数据速查（来自 config/policy.yaml 的 mock.crs）："
  note "  1234 Implement/bob,carol/prd/长期有效   → 全绿基线"
  note "  5678 Draft/bob/prd                      → R3 状态 + R4 审批不足"
  note "  1111 Approved/bob,carol/prod            → R5 环境不匹配"
  note "  2222 Approved/bob/prd                   → R4 审批不足"
  note "  3333 Approved/bob,carol/prd/2021过期    → R6 过期"
  note "  9999 模拟平台超时                       → 系统异常 fail-closed"
  note "  8888 不存在于 mock                       → R2 变更单不存在"

  scene_begin "规则判定（同步）"

  sub "3.1 批量总览（先用自带脚本跑一遍看全局）"
  step "for cr in 1234 5678 1111 2222 3333 9999 8888; do ./scripts/send-test-event.sh \$cr; done"
  for cr in 1234 5678 1111 2222 3333 9999 8888; do
    out="$(ADDR="$BASE_URL" "$CR_DIR/scripts/send-test-event.sh" "$cr" 2>/dev/null | sed -n '/^{/,$p')"
    printf '        %-6s → %s%s\n' "$cr" \
      "$(printf '%s' "$out" | jq -c '{conclusion,ok,system_error,failed_rules}' 2>/dev/null)" "${C_RST}"
  done

  sub "3.2 TC-R1 · PR 没带变更单号"
  mkpayload opened release/prd '[{"name":"feature"}]' "普通描述，没有变更单号" 42 "$SHA" "$WORK/p-r1.json"
  tc "TC-R1" "PR 未携带变更单号 → R1/R1a 必失败" \
     '.failed_rules // [] | join(",")' "R1,R1a,R2,R3,R4,R5,R6" "$WORK/p-r1.json"

  sub "3.3 TC-R1a · 两个变更单号（载体冲突）"
  mkpayload opened release/prd '[{"name":"cr/1234"}]' "Change-Request: 5678" 42 "$SHA" "$WORK/p-r1a.json"
  tc "TC-R1a" "label 与 body 给出不同编号 → 冲突必须拒绝" \
     '.failed_rules // [] | join(",")' "R1a" "$WORK/p-r1a.json"
  note "失败说明：$(printf '%s' "$RESP_BODY" | jq -r '.rules[]? | select(.id=="R1a") | .message')"

  sub "3.4 TC-R1a2 · 多个 label 同号"
  mkpayload opened release/prd '[{"name":"cr/1234"},{"name":"cr/5678"}]' "无 body 标记" 42 "$SHA" "$WORK/p-r1a2.json"
  tc "TC-R1a2" "两个 label → 同样判冲突" \
     '.failed_rules // [] | join(",")' "R1a" "$WORK/p-r1a2.json"

  sub "3.5 TC-R1b · 只有 body 标记（无 label）→ 应当通过"
  mkpayload opened release/prd '[{"name":"feature"}]' "Change-Request: 1234" 42 "$SHA" "$WORK/p-r1b.json"
  tc "TC-R1b" "body marker 是合法的第二载体" \
     '.conclusion' "success" "$WORK/p-r1b.json"

  sub "3.6 TC-R1c · label 格式不合法（cr/ 后面没编号）"
  mkpayload opened release/prd '[{"name":"cr/"}]' "x" 42 "$SHA" "$WORK/p-r1c.json"
  tc "TC-R1c" "不匹配 labelPattern → 视为没带" \
     '.rules[0].passed' "false" "$WORK/p-r1c.json"

  sub "3.7 TC-R2 · 变更单在平台上不存在"
  mkpayload opened release/prd '[{"name":"cr/8888"}]' "x" 42 "$SHA" "$WORK/p-r2.json"
  tc "TC-R2" "CR 8888 不在 mock 里 → R2 起全红" \
     '.failed_rules // [] | join(",")' "R2,R3,R4,R5,R6" "$WORK/p-r2.json"

  sub "3.8 TC-R3 · 状态不是 approved/implement"
  mkpayload opened release/prd '[{"name":"cr/5678"}]' "x" 42 "$SHA" "$WORK/p-r3.json"
  tc "TC-R3" "CR 5678 是 Draft → R3 失败（同时 R4 也失败：只 1 位审批）" \
     '.failed_rules // [] | join(",")' "R3,R4" "$WORK/p-r3.json"
  note "R3 说明：$(printf '%s' "$RESP_BODY" | jq -r '.rules[]? | select(.id=="R3") | .message')"

  sub "3.9 TC-R4 · 审批不足"
  mkpayload opened release/prd '[{"name":"cr/2222"}]' "x" 42 "$SHA" "$WORK/p-r4.json"
  tc "TC-R4" "CR 2222 只有 bob 1 位审批 < minApprovals=2" \
     '.failed_rules // [] | join(",")' "R4" "$WORK/p-r4.json"
  note "R4 说明：$(printf '%s' "$RESP_BODY" | jq -r '.rules[]? | select(.id=="R4") | .message')"

  sub "3.10 TC-R5 · 目标环境与分支不匹配"
  mkpayload opened release/prd '[{"name":"cr/1111"}]' "x" 42 "$SHA" "$WORK/p-r5.json"
  tc "TC-R5" "CR 1111 targetEnv=prod，PR 目标分支 release/prd → prd" \
     '.failed_rules // [] | join(",")' "R5" "$WORK/p-r5.json"
  note "R5 说明：$(printf '%s' "$RESP_BODY" | jq -r '.rules[]? | select(.id=="R5") | .message')"

  sub "3.11 TC-R5b · 反向验证：prd 的 CR 打到 release/prod"
  mkpayload opened release/prod '[{"name":"cr/1234"}]' "x" 42 "$SHA" "$WORK/p-r5b.json"
  tc "TC-R5b" "CR 1234 是 prd，PR 目标分支 release/prod → prod" \
     '.failed_rules // [] | join(",")' "R5" "$WORK/p-r5b.json"

  sub "3.12 TC-R6 · CR 已过期"
  mkpayload opened release/prd '[{"name":"cr/3333"}]' "x" 42 "$SHA" "$WORK/p-r6.json"
  tc "TC-R6" "CR 3333 有效期至 2021-01-01，早于当前 2025-01-06" \
     '.failed_rules // [] | join(",")' "R6" "$WORK/p-r6.json"
  note "R6 说明：$(printf '%s' "$RESP_BODY" | jq -r '.rules[]? | select(.id=="R6") | .message')"

  sub "3.13 TC-R6w · 维护窗口（当前在窗口内）"
  mkpayload opened release/prd '[{"name":"cr/1234"}]' "x" 42 "$SHA" "$WORK/p-r6w.json"
  tc "TC-R6w" "当前 2025-01-06 03:00 落在 Mon-Fri 02:00-04:00 内" \
     '.rules[] | select(.id=="R6w") | .passed' "true" "$WORK/p-r6w.json"
  note "R6w 说明：$(printf '%s' "$RESP_BODY" | jq -r '.rules[]? | select(.id=="R6w") | .message')"

  sub "3.14 TC-R7 · 同一个 CR 被两个 PR 占用"
  mkpayload opened release/prd '[{"name":"cr/1234"}]' "x" 42 "$SHA" "$WORK/p-r7a.json"
  HDR_EVENT="pull_request"; HDR_DELIVERY="t-$(uuidgen)"; HDR_SIGNATURE=""
  LAST_REQ_HEADERS=("X-GitHub-Event: pull_request" "X-GitHub-Delivery: ${HDR_DELIVERY}" "Content-Type: application/json")
  do_request POST "/github/webhook" "$WORK/p-r7a.json"
  printf '\n%s  ▶ TC-R7a · 先用 PR#42 占用 CR 1234%s\n' "${C_B}" "${C_RST}"
  show_request; show_response
  note "→ 占用表已记录 CR 1234 属于 acme/platform#42"

  mkpayload opened release/prd '[{"name":"cr/1234"}]' "x" 99 "$SHA" "$WORK/p-r7b.json"
  tc "TC-R7" "PR#99 想用同一个 CR 1234 → R7 失败（防重复上线）" \
     '.failed_rules // [] | join(",")' "R7" "$WORK/p-r7b.json"
  note "R7 说明：$(printf '%s' "$RESP_BODY" | jq -r '.rules[]? | select(.id=="R7") | .message')"
  scene_end "POST /github/webhook"

  sub "3.15 TC-RES-01 · CR 平台故障 → fail-closed"
  scene_begin "平台故障 fail-closed"
  mkpayload opened release/prd '[{"name":"cr/9999"}]' "x" 42 "$SHA" "$WORK/p-9999.json"
  tc "TC-RES-01a" "平台故障 → conclusion 必须是 failure（绝不能 success）" \
     '.conclusion' "failure" "$WORK/p-9999.json"
  tc "TC-RES-01b" "平台故障 → system_error=true" \
     '.system_error' "true" "$WORK/p-9999.json"
  tc "TC-RES-01c" "平台故障 → failed_rules 为空（是「没判完」不是「某条规则不通过」）" \
     '.failed_rules == null' "true" "$WORK/p-9999.json"
  tc "TC-RES-01d" "平台故障 → summary 必须是系统异常话术" \
     '.summary | contains("门禁系统异常")' "true" "$WORK/p-9999.json"
  note "check 输出正文："
  printf '%s\n' "$RESP_BODY" | jq -r '.summary' | indent
  warn "★ 服务端必须同时打了告警日志："
  if grep -q "门禁系统异常" "$SVC_LOG"; then
    note "✅ 找到告警日志："
    grep "门禁系统异常" "$SVC_LOG" | tail -1 | indent
    pass "TC-RES-01e" "平台故障时有独立告警日志"
  else
    fail "TC-RES-01e" "日志中出现「门禁系统异常」" "未找到"
  fi
  SCENE_CASES="${SCENE_CASES}${SCENE_CASES:+,}TC-RES-01e"
  scene_end "POST /github/webhook"
fi

# ==============================================================================
# 阶段 ④  入口协议用例
# ==============================================================================
if want http; then
section "④  入口协议用例（分支过滤 / 幂等 / 事件 / action / 坏包 / 方法）"

  scene_begin "分支过滤（非受管分支直接忽略）"
  CUR_EP="POST /github/webhook"
  sub "4.1 TC-HTTP-01 · 非受管分支 → 直接忽略，不产生 check"
  mkpayload opened feature/x '[{"name":"cr/1234"}]' "x" 42 "$SHA" "$WORK/p-branch.json"
  tc "TC-HTTP-01" "base=feature/x 不在 managedBranches → ignored" \
     '.status' "ignored" "$WORK/p-branch.json"
  note "响应：$(printf '%s' "$RESP_BODY" | jq -c '{status,reason,base_ref,managed_branches}')"
  note "★ 断言要点：服务日志里不应出现 check run written，registry 里也不该有它"
  scene_end "POST /github/webhook"

  scene_begin "幂等（重复 delivery id）"
  CUR_EP="POST /github/webhook"
  sub "4.2 TC-HTTP-02 · 幂等：同一个 delivery id 发两次"
  DUP_ID="dup-$(uuidgen)"
  note "delivery id = $DUP_ID"
  for i in 1 2; do
    HDR_EVENT="pull_request"; HDR_DELIVERY="$DUP_ID"; HDR_SIGNATURE=""
    LAST_REQ_HEADERS=("X-GitHub-Event: pull_request" "X-GitHub-Delivery: ${HDR_DELIVERY}" "Content-Type: application/json")
    do_request POST "/github/webhook" "$CR_DIR/testdata/pr-event.json"
    printf '\n%s  ▶ 第 %s 次投递（相同 delivery id）%s\n' "${C_B}" "$i" "${C_RST}"
    show_request; show_response
    if [ "$i" = "1" ]; then
      check "TC-HTTP-02a  第一次投递 → evaluated" '.status' "evaluated" "$RESP_BODY"
    else
      check "TC-HTTP-02b  第二次投递 → duplicate（不重复处理）" '.status' "duplicate" "$RESP_BODY"
    fi
  done
  note "★ 为什么重要：GitHub 会重投 webhook（最多 3 次）。没有幂等 = 判定翻倍 / check 记录翻倍。"
  scene_end "POST /github/webhook"

  scene_begin "事件白名单 / ping"
  CUR_EP="POST /github/webhook"
  sub "4.3 TC-HTTP-03 · 事件白名单"
  HDR_EVENT="push"; HDR_DELIVERY="t-$(uuidgen)"; HDR_SIGNATURE=""
  LAST_REQ_HEADERS=("X-GitHub-Event: push" "X-GitHub-Delivery: ${HDR_DELIVERY}" "Content-Type: application/json")
  do_request POST "/github/webhook" "$WORK/p-r1.json"
  printf '\n%s  ▶ TC-HTTP-03a · 未订阅的事件 push%s\n' "${C_B}" "${C_RST}"
  show_request; show_response
  check "TC-HTTP-03a  未订阅事件 → ignored" '.status' "ignored" "$RESP_BODY"

  HDR_EVENT="ping"; HDR_DELIVERY="t-$(uuidgen)"; HDR_SIGNATURE=""
  LAST_REQ_HEADERS=("X-GitHub-Event: ping" "X-GitHub-Delivery: ${HDR_DELIVERY}" "Content-Type: application/json")
  do_request POST "/github/webhook" "$WORK/p-r1.json"
  printf '\n%s  ▶ TC-HTTP-03b · ping 事件（保存 Webhook URL 时 GitHub 会发）%s\n' "${C_B}" "${C_RST}"
  show_request; show_response
  check "TC-HTTP-03b  ping → pong" '.status' "pong" "$RESP_BODY"
  scene_end "POST /github/webhook"

  scene_begin "action 白名单"
  CUR_EP="POST /github/webhook"
  sub "4.4 TC-HTTP-04 · action 白名单"
  mkpayload closed release/prd '[{"name":"cr/1234"}]' "x" 42 "$SHA" "$WORK/p-closed.json"
  tc "TC-HTTP-04a" "action=closed 不触发判定" \
     '.status' "ignored" "$WORK/p-closed.json"
  note "触发判定的 action: opened / synchronize / reopened / labeled / unlabeled / ready_for_review / edited"
  note "★ labeled 在白名单里 → 加删 cr/xxx label 会立即重判"
  scene_end "POST /github/webhook"

  scene_begin "坏 payload（400）"
  CUR_EP="POST /github/webhook"
  sub "4.5 TC-HTTP-05 · 坏 payload → 400"
  HDR_EVENT="pull_request"; HDR_DELIVERY="t-$(uuidgen)"; HDR_SIGNATURE=""
  LAST_REQ_HEADERS=("X-GitHub-Event: pull_request" "X-GitHub-Delivery: ${HDR_DELIVERY}" "Content-Type: application/json")
  printf 'not-json' > "$WORK/p-bad.json"
  do_request POST "/github/webhook" "$WORK/p-bad.json"
  printf '\n%s  ▶ TC-HTTP-05 · 请求体不是合法 JSON%s\n' "${C_B}" "${C_RST}"
  show_request; show_response
  check_status "TC-HTTP-05   坏 payload → HTTP 400" "400" "$RESP_STATUS"
  scene_end "POST /github/webhook"

  scene_begin "方法不允许（GET → 404）"
  CUR_EP="GET /github/webhook"
  sub "4.6 TC-HTTP-06 · GET 方法"
  HDR_EVENT=""; HDR_DELIVERY=""; HDR_SIGNATURE=""
  LAST_REQ_HEADERS=()
  do_request GET "/github/webhook" ""
  printf '\n%s  ▶ TC-HTTP-06 · GET /github/webhook%s\n' "${C_B}" "${C_RST}"
  show_request; show_response
  note "★ 期望 404（不是 405）：路由是 Go 1.22+ 方法路由 POST /github/webhook，"
  note "  而 GET / 是能匹配所有路径的子树模式，ServeMux 选了它 → 内部返回 404。已知行为，不是故障。"
  scene_end "GET /github/webhook"

  scene_begin "无 delivery 头（不做幂等）"
  CUR_EP="POST /github/webhook"
  sub "4.7 TC-HTTP-08 · 不带 X-GitHub-Delivery → 不做幂等"
  HDR_EVENT="pull_request"; HDR_DELIVERY=""; HDR_SIGNATURE=""
  LAST_REQ_HEADERS=("X-GitHub-Event: pull_request" "Content-Type: application/json")
  do_request POST "/github/webhook" "$CR_DIR/testdata/pr-event.json"
  printf '\n%s  ▶ TC-HTTP-08 · 无 delivery 头%s\n' "${C_B}" "${C_RST}"
  show_request; show_response
  check "TC-HTTP-08   无 delivery 头 → 正常判定" '.status' "evaluated" "$RESP_BODY"
  scene_end "POST /github/webhook"
fi

# ==============================================================================
# 阶段 ⑤  webhook 验签
# ==============================================================================
if want sign; then
section "⑤  webhook 验签（需要单独起一个带 WEBHOOK_SECRET 的实例）"

  scene_begin "验签（缺签名/错签名/正确签名）"
  CUR_EP="POST /github/webhook"

  PORT_SIGN=$(free_port $((BASE_PORT+1)))
  step "启动服务："
  printf '        %sWEBHOOK_SECRET=topsecret %s -config %s -mode mock -addr :%s -sync-eval -now 2025-01-06T03:00:00+08:00%s\n' \
    "${C_DIM}" "$BIN" "$CFG" "$PORT_SIGN" "${C_RST}"
  if WEBHOOK_SECRET=topsecret svc_start sign "$PORT_SIGN" -mode mock -sync-eval -now "2025-01-06T03:00:00+08:00"; then
    info "✅ 服务已就绪，pid=$SVC_PID 端口=$PORT_SIGN"
  else
    err "服务启动失败"; svc_startup_log "$SVC_LOG" | indent
  fi
  SAVE_BASE="$BASE_URL"
  BASE_URL="http://localhost:$PORT_SIGN"

  BF="$CR_DIR/testdata/pr-event.json"

  sub "5.1 TC-SIGN-01 · 不带签名 → 401"
  HDR_EVENT="pull_request"; HDR_DELIVERY="t-$(uuidgen)"; HDR_SIGNATURE=""
  LAST_REQ_HEADERS=("X-GitHub-Event: pull_request" "X-GitHub-Delivery: ${HDR_DELIVERY}" "Content-Type: application/json")
  do_request POST "/github/webhook" "$BF"
  printf '\n%s  ▶ TC-SIGN-01 · 请求不带 X-Hub-Signature-256%s\n' "${C_B}" "${C_RST}"
  show_request; show_response
  check_status "TC-SIGN-01   缺签名 → HTTP 401" "401" "$RESP_STATUS"

  sub "5.2 TC-SIGN-02 · 错误签名 → 401"
  HDR_SIGNATURE="sha256=deadbeef"
  LAST_REQ_HEADERS=("X-GitHub-Event: pull_request" "X-GitHub-Delivery: ${HDR_DELIVERY}" "Content-Type: application/json" "X-Hub-Signature-256: ${HDR_SIGNATURE}")
  do_request POST "/github/webhook" "$BF"
  printf '\n%s  ▶ TC-SIGN-02 · 签名错误%s\n' "${C_B}" "${C_RST}"
  show_request; show_response
  check_status "TC-SIGN-02   错签名 → HTTP 401" "401" "$RESP_STATUS"

  sub "5.3 TC-SIGN-03 · 正确签名 → 200"
  note "签名必须对「文件原始字节」计算：openssl dgst -sha256 -hmac topsecret -r < 文件"
  SIG="sha256=$(openssl dgst -sha256 -hmac topsecret -r < "$BF" | cut -d' ' -f1)"
  HDR_SIGNATURE="$SIG"
  HDR_DELIVERY="t-$(uuidgen)"
  LAST_REQ_HEADERS=("X-GitHub-Event: pull_request" "X-GitHub-Delivery: ${HDR_DELIVERY}" "Content-Type: application/json" "X-Hub-Signature-256: ${HDR_SIGNATURE}")
  do_request POST "/github/webhook" "$BF"
  printf '\n%s  ▶ TC-SIGN-03 · 签名正确%s\n' "${C_B}" "${C_RST}"
  show_request; show_response
  check "TC-SIGN-03   正确签名 → conclusion=success" '.conclusion' "success" "$RESP_BODY"
  note "★ 坑：用 --data-binary \"\$(cat file)\"（变量形式）会丢掉末尾换行 → 签名对不上 → 401。"
  note "  必须用 --data-binary \"@文件\"，保证「签名的字节」=「发出去的字节」。"

  BASE_URL="$SAVE_BASE"
  scene_end "POST /github/webhook"
fi

# ==============================================================================
# 阶段 ⑥  生产形态：异步模式（先 ACK 再异步判定）
# ==============================================================================
if want async; then
section "⑥  生产形态：异步模式返回 202 queued"

  scene_begin "异步先 ACK（202 queued）"
  CUR_EP="POST /github/webhook"

  note "生产必须 syncEval=false —— 先 ACK 再后台判定，避免超过 GitHub 的 10 秒投递预算。"
  note "注意：mock 模式下 main.go 会强制 syncEval=true，所以测 queued 分支必须用 mode=real。"

  PORT_ASYNC=$(free_port $((BASE_PORT+2)))
  step "启动服务（用占位凭据进 real 模式；真实环境这里换成 GitHub App 私钥）："
  printf '        %sGITHUB_APP_ID=1 GITHUB_APP_INSTALLATION_ID=1 GITHUB_APP_PRIVATE_KEY_PATH=/tmp/fake.pem %s -mode real -addr :%s%s\n' \
    "${C_DIM}" "$BIN" "$PORT_ASYNC" "${C_RST}"
  echo "fake" > "$WORK/fake.pem"
  if GITHUB_APP_ID=1 GITHUB_APP_INSTALLATION_ID=1 GITHUB_APP_PRIVATE_KEY_PATH="$WORK/fake.pem" \
       svc_start async "$PORT_ASYNC" -mode real; then
    info "✅ 服务已就绪，pid=$SVC_PID 端口=$PORT_ASYNC"
  else
    err "服务启动失败"; svc_startup_log "$SVC_LOG" | indent
  fi

  SAVE_BASE="$BASE_URL"
  BASE_URL="http://localhost:$PORT_ASYNC"

  HDR_EVENT="pull_request"; HDR_DELIVERY="t-$(uuidgen)"; HDR_SIGNATURE=""
  LAST_REQ_HEADERS=("X-GitHub-Event: pull_request" "X-GitHub-Delivery: ${HDR_DELIVERY}" "Content-Type: application/json")
  do_request POST "/github/webhook" "$CR_DIR/testdata/pr-event.json"
  printf '\n%s  ▶ TC-ASYNC-01 · 异步模式下 webhook 立刻返回%s\n' "${C_B}" "${C_RST}"
  show_request; show_response
  check_status "TC-ASYNC-01  异步 → HTTP 202" "202" "$RESP_STATUS"
  check "TC-ASYNC-02  异步 → status=queued" '.status' "queued" "$RESP_BODY"
  note "★ 判定在后台 worker 里做；结果写进 GitHub check run，本地看不到。"
  note "  （本实例用的是假私钥，所以写 check 会失败，日志里会看到「写 check 结论失败」——"
  note "   这是预期内的，因为这里只验证「先 ACK」这个行为。）"

  BASE_URL="$SAVE_BASE"
  scene_end "POST /github/webhook"
fi

# ==============================================================================
# 阶段 ⑦  扩展 mock 数据用例
# ==============================================================================
if want extra; then
section "⑦  扩展 mock 数据用例（审批白名单 / 自审批 / 未知状态 / 未生效）"

  scene_begin "扩展 mock（白名单/自审批/未知状态/未生效）"

  note "默认 mock 里没有这四条，需要临时追加一份配置。生产上这些数据来自真实 CR 平台。"
  CFG_EXTRA="$WORK/policy-extra.yaml"
  cp "$CFG" "$CFG_EXTRA"
  cat >> "$CFG_EXTRA" <<'YAML'

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

    # ✅ 中文别名状态 → 规范化 implement → 通过
    - number: "8888"
      status: "实施中"
      requester: alice
      approvers: [bob, carol]
      targetEnv: prd
      validFrom: "2020-01-01T00:00:00+08:00"
      validTo: "2035-12-31T23:59:59+08:00"
      url: https://cr.example.com/cr/8888
YAML
  info "扩展配置已生成: $CFG_EXTRA"

  PORT_EXTRA=$(free_port $((BASE_PORT+3)))
  step "启动服务："
  printf '        %s -config %s -mode mock -addr :%s -sync-eval -now 2025-01-06T03:00:00+08:00%s\n' \
    "${C_DIM}" "$CFG_EXTRA" "$PORT_EXTRA" "${C_RST}"
  if svc_start extra "$PORT_EXTRA" -config "$CFG_EXTRA" -mode mock -sync-eval -now "2025-01-06T03:00:00+08:00"; then
    info "✅ 服务已就绪，pid=$SVC_PID 端口=$PORT_EXTRA"
  else
    err "服务启动失败"; svc_startup_log "$SVC_LOG" | indent
  fi

  SAVE_BASE="$BASE_URL"
  BASE_URL="http://localhost:$PORT_EXTRA"

  sub "7.1 TC-R4b · 审批人不在授权名单"
  mkpayload opened release/prd '[{"name":"cr/4444"}]' "x" 42 "$SHA" "$WORK/p-4444.json"
  tc "TC-R4b" "mallory 不在 allowedApprovers 里" \
     '.rules[] | select(.id=="R4") | .passed' "false" "$WORK/p-4444.json"
  note "R4 说明：$(printf '%s' "$RESP_BODY" | jq -r '.rules[]? | select(.id=="R4") | .message')"

  sub "7.2 TC-R4c · 提单人自己审批"
  mkpayload opened release/prd '[{"name":"cr/5555"}]' "x" 42 "$SHA" "$WORK/p-5555.json"
  tc "TC-R4c" "alice 既是提单人又审批了自己的 CR" \
     '.rules[] | select(.id=="R4") | .passed' "false" "$WORK/p-5555.json"
  note "R4 说明：$(printf '%s' "$RESP_BODY" | jq -r '.rules[]? | select(.id=="R4") | .message')"

  sub "7.3 TC-R3-unknown · 平台返回未映射的状态 → 规范化 unknown → 不通过"
  mkpayload opened release/prd '[{"name":"cr/6666"}]' "x" 42 "$SHA" "$WORK/p-6666.json"
  tc "TC-R3-unk" "status=ApprovedForImplementation 未配在 statusAliases → unknown" \
     '.rules[] | select(.id=="R3") | .passed' "false" "$WORK/p-6666.json"
  note "R3 说明：$(printf '%s' "$RESP_BODY" | jq -r '.rules[]? | select(.id=="R3") | .message')"
  warn "★ 这是最重要的安全用例：平台新增状态若没同步 statusAliases，那个状态一律不通过（fail-closed）。"
  warn "  漏配的后果是「门禁对该状态失效」→ 必须进回归。"

  sub "7.4 TC-R6b · CR 尚未生效"
  mkpayload opened release/prd '[{"name":"cr/7777"}]' "x" 42 "$SHA" "$WORK/p-7777.json"
  tc "TC-R6b" "validFrom=2030-01-01，晚于当前 2025-01-06" \
     '.rules[] | select(.id=="R6") | .passed' "false" "$WORK/p-7777.json"
  note "R6 说明：$(printf '%s' "$RESP_BODY" | jq -r '.rules[]? | select(.id=="R6") | .message')"

  sub "7.5 TC-R3-alias · 中文别名状态 → 通过"
  mkpayload opened release/prd '[{"name":"cr/8888"}]' "x" 42 "$SHA" "$WORK/p-8888.json"
  tc "TC-R3-ali" "status=实施中 → 别名映射到 implement → 通过" \
     '.conclusion' "success" "$WORK/p-8888.json"
  note "R3 说明：$(printf '%s' "$RESP_BODY" | jq -r '.rules[]? | select(.id=="R3") | .message')"

  BASE_URL="$SAVE_BASE"
  scene_end "POST /github/webhook"
fi

# ==============================================================================
# 阶段 ⑧  维护窗口边界
# ==============================================================================
if want window; then
section "⑧  维护窗口边界用例"

  scene_begin "维护窗口边界（开闭区间 + 周末）"

  note "窗口定义: days=[Mon..Fri] start=02:00 end=04:00 tz=Asia/Shanghai  【左闭右开 [start,end)】"
  note "-now 是启动参数不是请求参数 → 每个边界值各起一个实例。"

  sub "8.0 TC-WIN-00 · 真实时间（不加 -now）→ 必然被窗口拦下"
  PORT_W0=$(free_port $((BASE_PORT+4)))
  printf '        %s -config %s -mode mock -addr :%s -sync-eval   （无 -now）%s\n' "${C_DIM}" "$CFG" "$PORT_W0" "${C_RST}"
  if svc_start win0 "$PORT_W0" -mode mock -sync-eval; then
    info "✅ 服务已就绪，pid=$SVC_PID 端口=$PORT_W0"
    SAVE_BASE="$BASE_URL"; BASE_URL="http://localhost:$PORT_W0"
    mkpayload opened release/prd '[{"name":"cr/1234"}]' "x" 42 "$SHA" "$WORK/p-w0.json"
    tc "TC-WIN-00" "真实时间 → R6w 失败（这是正确行为，不是 bug）" \
       '.rules[] | select(.id=="R6w") | .passed' "false" "$WORK/p-w0.json"
    note "R6w 说明：$(printf '%s' "$RESP_BODY" | jq -r '.rules[]? | select(.id=="R6w") | .message')"
    BASE_URL="$SAVE_BASE"
    svc_stop "$SVC_PID" "win0"
  fi

  sub "8.1 边界矩阵"
  # 每行: 描述|now|期望 R6w
  CASES="
周一 02:00:00 起点（闭）|2025-01-06T02:00:00+08:00|true
周一 03:59:59 最后一秒|2025-01-06T03:59:59+08:00|true
周一 04:00:00 终点（开）|2025-01-06T04:00:00+08:00|false
周六 03:00|2025-01-11T03:00:00+08:00|false
周日 03:00|2025-01-05T03:00:00+08:00|false
"

  idx=0
  # ⚠️ 不用管道 + while（那会开子 shell，PASS/FAIL 计数传不回来）
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    desc="$(printf '%s' "$line" | cut -d'|' -f1)"
    now="$(printf '%s' "$line" | cut -d'|' -f2)"
    want_r6w="$(printf '%s' "$line" | cut -d'|' -f3)"
    idx=$((idx+1))
    port=$(free_port $((BASE_PORT+10+idx)))
    printf '\n        %s--- 边界 %s : %s （期望 R6w=%s）---%s\n' "${C_DIM}" "$idx" "$desc" "$want_r6w" "${C_RST}"
    printf '        %s%s -config %s -mode mock -addr :%s -sync-eval -now %s%s\n' \
      "${C_DIM}" "$BIN" "$CFG" "$port" "$now" "${C_RST}"
    if svc_start "win$idx" "$port" -mode mock -sync-eval -now "$now"; then
      SAVE_BASE="$BASE_URL"; BASE_URL="http://localhost:$port"
      mkpayload opened release/prd '[{"name":"cr/1234"}]' "x" 42 "$SHA" "$WORK/p-w$idx.json"
      tc "TC-WIN-0$idx" "$desc" \
         '.rules[] | select(.id=="R6w") | .passed' "$want_r6w" "$WORK/p-w$idx.json"
      BASE_URL="$SAVE_BASE"
      svc_stop "$SVC_PID" "win$idx"
    else
      fail "TC-WIN-0$idx" "服务启动成功" "启动失败"
    fi
  done <<EOF
$CASES
EOF
  scene_end "POST /github/webhook"
fi

# ==============================================================================
# 阶段 ⑨  可观测性端点
# ==============================================================================
if want obs; then
section "⑨  可观测性端点（audit / registry / last-check / metrics / recheck）"

  note "下面用的是主服务（第 ② 阶段起的那个）。"

  # 准备：先打两发事件（一个合规 + 一个不合规），把 last-check / audit / registry / metrics 填充上
  step "准备：发两发事件，让服务端产生判定/审计/指标（一个合规 + 一个不合规）"
  mkpayload opened release/prd '[{"name":"cr/1234"}]' "准备事件-合规" 42 "$SHA" "$WORK/p-obs-prep.json"
  mkpayload opened release/prd '[{"name":"cr/5678"}]' "准备事件-不合规" 42 "$SHA" "$WORK/p-obs-prep2.json"
  for pf in "$WORK/p-obs-prep.json" "$WORK/p-obs-prep2.json"; do
    HDR_EVENT="pull_request"; HDR_DELIVERY="t-$(uuidgen)"; HDR_SIGNATURE=""
    LAST_REQ_HEADERS=("X-GitHub-Event: pull_request" "X-GitHub-Delivery: ${HDR_DELIVERY}" "Content-Type: application/json")
    do_request POST "/github/webhook" "$pf"
    printf '        %s响应: %s%s\n' "${C_DIM}" \
      "$(printf '%s' "$RESP_BODY" | jq -c '{status,conclusion,cr_number,failed_rules}')" "${C_RST}"
  done
  note "→ 合规事件让 evaluations_total{result=\"success\"} 有值；不合规事件让 rule_failed_total 有值"

  sub "9.1 GET /internal/last-check —— 最近一次 check 写入"
  scene_begin "最近一次 check 写入"
  CUR_EP="GET /internal/last-check"
  do_request GET "/internal/last-check" ""
  LAST_REQ_HEADERS=()
  show_request; show_response
  check "TC-OBS-01   last-check 有 conclusion" '.conclusion != null' "true" "$RESP_BODY"
  check "TC-OBS-02   last-check 有 rules 明细" '.rules | length > 0' "true" "$RESP_BODY"
  scene_end "GET /internal/last-check"

  sub "9.2 GET /internal/audit —— 审计流水"
  scene_begin "审计流水"
  CUR_EP="GET /internal/audit"
  do_request GET "/internal/audit" ""
  LAST_REQ_HEADERS=()
  show_request; show_response
  check "TC-OBS-03   audit 至少有 1 条记录" 'length > 0' "true" "$RESP_BODY"
  note "最近一条：$(printf '%s' "$RESP_BODY" | jq -c '.[-1]')"
  note "字段说明: source=webhook(同步) / webhook-async(异步 worker) / recheck(定时重扫)"
  scene_end "GET /internal/audit"

  sub "9.3 GET /internal/registry —— 已登记的受管 PR"
  scene_begin "已登记的受管 PR"
  CUR_EP="GET /internal/registry"
  do_request GET "/internal/registry" ""
  LAST_REQ_HEADERS=()
  show_request; show_response
  check "TC-OBS-04   registry 至少有 1 个 PR" 'length > 0' "true" "$RESP_BODY"
  note "注意: 同一个 PR 的 labels 会被后续事件覆盖；last_conclusion 是上次判定结论。"
  scene_end "GET /internal/registry"

  sub "9.4 POST /internal/recheck —— 立即触发定时重扫"
  scene_begin "立即触发定时重扫"
  CUR_EP="POST /internal/recheck"
  HDR_EVENT=""; HDR_DELIVERY=""; HDR_SIGNATURE=""; LAST_REQ_HEADERS=()
  do_request POST "/internal/recheck" ""
  printf '\n%s  ▶ POST /internal/recheck%s\n' "${C_B}" "${C_RST}"
  show_request; show_response
  check "TC-OBS-05   recheck 返回 status" '.status' "recheck done" "$RESP_BODY"
  scene_end "POST /internal/recheck"

  sub "9.5 GET /metrics —— Prometheus 指标"
  scene_begin "Prometheus 指标"
  CUR_EP="GET /metrics"
  do_request GET "/metrics" ""
  LAST_REQ_HEADERS=()
  show_request
  note "关键指标（只看 cr_check_*）："
  printf '%s\n' "$RESP_BODY" | grep '^cr_check' | grep -v '_bucket' | indent
  check_has "TC-OBS-06   evaluations_total 有 success/failure 计数" 'cr_check_evaluations_total{result="success"}' "$RESP_BODY"
  check_has "TC-OBS-07   recheck_flipped_total 存在（本地恒为 0 是正确行为）" 'cr_check_recheck_flipped_total' "$RESP_BODY"
  check_has "TC-OBS-07b  rule_failed_total 按规则 ID 统计" 'cr_check_rule_failed_total{rule_id=' "$RESP_BODY"
  note "★ cr_check_recheck_flipped_total：重扫时结论发生翻转的次数 = 事件丢失率的量度。"
  note "  本地测不成非 0（-now 固定 + mock 数据静态 + registry 在内存），它是生产健康指标。"
  scene_end "GET /metrics"

  sub "9.6 GET /mock/cr/{number} —— 内置假 CR 平台"
  scene_begin "内置假 CR 平台（存在/故障/不存在）"
  CUR_EP="GET /mock/cr/{number}"
  for n in 1234 9999 8888; do
    do_request GET "/mock/cr/$n" ""
    LAST_REQ_HEADERS=()
    printf '\n        %s--- GET /mock/cr/%s → HTTP %s ---%s\n' "${C_DIM}" "$n" "$RESP_STATUS" "${C_RST}"
    printf '%s\n' "$RESP_BODY" | indent
    case "$n" in
      1234) check "TC-OBS-08   mock/cr/1234 存在" '.number' "1234" "$RESP_BODY" ;;
      9999) check_status "TC-OBS-09   mock/cr/9999 模拟故障 → HTTP 500" "500" "$RESP_STATUS" ;;
      8888) check_status "TC-OBS-10   mock/cr/8888 不存在 → HTTP 404" "404" "$RESP_STATUS" ;;
    esac
  done
  note "★ GET /mock/cr/（列表）不可达 —— 只注册了 /mock/cr/{number}，空段不匹配路由。"
  scene_end "GET /mock/cr/{number}"
fi

# ==============================================================================
# 阶段 ⑩  接口覆盖矩阵 + 汇总
# ==============================================================================
section "⑩  接口覆盖矩阵"

printf '%s%-26s %-30s %-5s %-6s%s\n' "${C_B}" "端点" "场景（测的是什么）" "用例" "结果" "${C_RST}"
printf '%s%s%s\n' "${C_DIM}" "──────────────────────────────────────────────────────────────────────────────────────" "${C_RST}"
while IFS='|' read -r ep scene cases res; do
  [ -z "$ep" ] && continue
  n=$(printf '%s' "$cases" | tr ',' '\n' | grep -c .)
  if [ "$res" = "PASS" ]; then
    printf '%-26s %-30s %-5s %s✅ PASS%s\n' "$ep" "$scene" "$n" "${C_G}" "${C_RST}"
  else
    printf '%-26s %-30s %-5s %s❌ FAIL%s\n' "$ep" "$scene" "$n" "${C_R}" "${C_RST}"
  fi
done <<EOF
$EP_TABLE
EOF

printf '\n%s用例明细（每个用例 → 归属端点 → 结果）%s\n' "${C_B}${C_C}" "${C_RST}"
printf '%s%-18s %-26s %s%s\n' "${C_B}" "用例" "端点" "结果" "${C_RST}"
printf '%s%s%s\n' "${C_DIM}" "──────────────────────────────────────────────────────────────────────────────────────" "${C_RST}"
while IFS='|' read -r cid ep res; do
  [ -z "$cid" ] && continue
  if [ "$res" = "PASS" ]; then
    printf '%-18s %-26s %s✅ PASS%s\n' "$cid" "$ep" "${C_G}" "${C_RST}"
  else
    printf '%-18s %-26s %s❌ FAIL%s\n' "$cid" "$ep" "${C_R}" "${C_RST}"
  fi
done <<EOF
$CASE_EP
EOF

printf '\n%s未覆盖端点（生产前需人工确认）：%s\n' "${C_B}${C_Y}" "${C_RST}"
cat <<'EOF'
  POST /github/webhook（event=pull_request_review）→ 本版本只订阅不处理，预期 ignored
  POST /github/webhook（event=check_run / merge_group / installation）→ 预期 ignored
  GitHub Checks API 写入（真实 check run 的创建/覆盖）→ 需要真实 App 凭据，本地只验到「读到了」
  真实 CR 平台 HTTP 客户端（重试/超时/5xx → system_error）→ 本地由 mock 9999 模拟
  Redis 幂等存储（queue.RedisStore）→ 本地走的是内存实现
EOF

section "汇总"
printf '  用例总数: %s%s%s\n' "${C_B}" "$TOTAL" "${C_RST}"
printf '  通过    : %s%s%s\n' "${C_G}" "$PASS" "${C_RST}"
if [ "$FAIL" -gt 0 ]; then
  printf '  失败    : %s%s%s\n' "${C_R}" "$FAIL" "${C_RST}"
else
  printf '  失败    : %s0%s\n' "${C_G}" "${C_RST}"
fi

if [ "$FAIL" -eq 0 ]; then
  printf '\n%s  ✅ 全部通过%s\n\n' "${C_B}${C_G}" "${C_RST}"
  exit 0
else
  printf '\n%s  ❌ 有 %s 条失败，用上面的「期望值 / 实际值」对照定位%s\n\n' "${C_B}${C_R}" "$FAIL" "${C_RST}"
  exit 1
fi
