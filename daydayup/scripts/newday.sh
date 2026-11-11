#!/usr/bin/env bash
# 生成「下一天」的练习骨架：代码目录 + 文档 + 索引条目
#
# 用法：
#   ./scripts/newday.sh            # 主题留空
#   ./scripts/newday.sh slices     # 主题 = slices
#   TOPIC="slice 与 append" ./scripts/newday.sh

set -euo pipefail

cd "$(dirname "$0")/.."

TOPIC="${1:-${TOPIC:-}}"

# ---- 1. 算下一个天数 ----------------------------------------------------
next=1
for d in d[0-9][0-9]; do
  [ -d "$d" ] || continue
  n=$((10#${d#d}))
  [ "$n" -ge "$next" ] && next=$((n + 1))
done

NN=$(printf "%02d" "$next")
DIR="d${NN}"

# 文档文件名：主题转成 keby-case（只保留 ASCII 字母数字，中文主题回退到 topic）
if [ -n "$TOPIC" ]; then
  SLUG=$(printf '%s' "$TOPIC" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '\n' | grep -v '^$' | tr '\n' '-' | sed 's/-$//')
  [ -z "$SLUG" ] && SLUG="topic"
else
  SLUG="topic"
fi
DOC="md/${NN}-${SLUG}.md"

if [ -e "$DIR" ] || [ -e "$DOC" ]; then
  echo "✗ ${DIR} 或 ${DOC} 已存在，先改主题名或删掉旧的"
  exit 1
fi

# ---- 2. 代码骨架 --------------------------------------------------------
mkdir -p "$DIR"

cat > "${DIR}/main.go" <<EOF
package main

import "fmt"

// TODO: 今天是 Day ${NN}${TOPIC:+ · ${TOPIC}}

func main() {
	fmt.Println("Day ${NN}: ${TOPIC:-开始}")
}
EOF

cat > "${DIR}/main_test.go" <<EOF
package main

import "testing"

// TODO: 把今天学的技巧写成断言
func TestDay${NN}(t *testing.T) {
	t.Log("Day ${NN} 还没写测试")
}
EOF

# ---- 3. 文档骨架 --------------------------------------------------------
cat > "$DOC" <<EOF
# Day ${NN} · ${TOPIC:-待定}

> 一句话：今天要掌握的技巧是 ______。

## 目标

- [ ] 学会：______
- [ ] 能用一句话解释：______

## 代码

对应代码目录：[\`../${DIR}/\`](../${DIR}/)

\`\`\`bash
make run DAY=${DIR}   # 跑示例
make test             # 跑测试
\`\`\`

## 笔记

### 关键点

\`\`\`go
// 在这里贴代码
\`\`\`

### 坑 / 容易错的地方

| 坑 | 症状 | 解法 |
|---|---|---|
|  |  |  |

## 自测

- [ ] 我能不看笔记复现出来
- [ ] 我知道为什么这么写，而不只是照抄
EOF

# ---- 4. 写进索引 --------------------------------------------------------
INDEX="md/README.md"
if [ -f "$INDEX" ] && grep -q '<!-- AUTO-INDEX -->' "$INDEX"; then
  # 在 AUTO-INDEX 标记前插入一行
  tmp=$(mktemp)
  awk -v row="| ${NN} | [${NN}-${SLUG}.md](${NN}-${SLUG}.md) | ${TOPIC:-待定} | [\`d${NN}/\`](../d${NN}/) |" '
    /<!-- AUTO-INDEX -->/ { print row }
    { print }
  ' "$INDEX" > "$tmp"
  mv "$tmp" "$INDEX"
fi

echo "✅ 建好了："
echo "   ${DIR}/main.go"
echo "   ${DIR}/main_test.go"
echo "   ${DOC}"
echo ""
echo "下一步："
echo "   vim ${DOC}          # 写今天的笔记"
echo "   vim ${DIR}/main.go  # 写今天的代码"
echo "   make test           # 跑测试"
