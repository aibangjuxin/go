#!/usr/bin/env bash
#
# word-card.sh — 生成一张"已消音"的词卡 PNG。
#
# 用法:
#   word-card.sh OUT.png TERM [NOTE] [LABEL]
#
# - TERM  : 想让卡片显示的词，调用方自己决定消音成什么样（例如 s**t）
# - NOTE  : 上下文说明，语气 / 出处 / 为什么不能直说
# - LABEL : 卡片顶部的小标签，默认 "AGENT OUTPUT · CENSORED"
#
# 之所以先消音再调用：调用方（代理）不需要把原词写进命令行，
# 也就不会把原词留在自己的对话记录里。
#
# 依赖: rsvg-convert（没有就退回 ImageMagick 的 magick）

set -euo pipefail

out="${1:-}"
term="${2:-}"
note="${3:-}"
label="${4:-AGENT OUTPUT · CENSORED}"

if [ -z "$out" ] || [ -z "$term" ]; then
  echo "usage: word-card.sh OUT.png TERM [NOTE] [LABEL]" >&2
  exit 2
fi

xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

label_x="$(xml_escape "$label")"
term_x="$(xml_escape "$term")"
note_x="$(xml_escape "$note")"

svg="$(mktemp -t word-card.XXXXXX).svg"
trap 'rm -f "$svg"' EXIT

cat > "$svg" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" width="760" height="230" viewBox="0 0 760 230">
  <rect x="0" y="0" width="760" height="230" rx="16" fill="#12141a"/>
  <rect x="0" y="0" width="760" height="7" rx="3.5" fill="#e05252"/>
  <text x="30" y="58" font-family="Menlo, Hiragino Sans GB, PingFang SC, monospace" font-size="19" fill="#8b93a7">${label_x}</text>
  <text x="30" y="140" font-family="Menlo, Hiragino Sans GB, PingFang SC, monospace" font-size="62" font-weight="bold" fill="#f2f4f8">${term_x}</text>
  <text x="30" y="196" font-family="Menlo, Hiragino Sans GB, PingFang SC, monospace" font-size="21" fill="#c3c9d6">${note_x}</text>
</svg>
EOF

if command -v rsvg-convert >/dev/null 2>&1; then
  rsvg-convert -o "$out" "$svg"
elif command -v magick >/dev/null 2>&1; then
  magick "$svg" "$out"
elif command -v convert >/dev/null 2>&1; then
  convert "$svg" "$out"
else
  echo "word-card: 需要 rsvg-convert 或 ImageMagick" >&2
  exit 1
fi

echo "$out"
