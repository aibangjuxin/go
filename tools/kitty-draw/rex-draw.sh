#!/usr/bin/env bash
#
# rex-draw.sh — 在当前 Rex 窗格旁边开一个分屏，用 Kitty 图形协议把图片画进去。
#
# 用法:
#   rex-draw.sh IMAGE.png [LABEL] [COLS]
#
# - IMAGE : PNG / JPEG
# - LABEL : 分屏标签（默认 "draw"）
# - COLS  : 图片占多少列宽（默认 46）
#
# 依赖: rex CLI、Rex 终端（内建 Ghostty，支持 Kitty 图形协议）

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
image="${1:-}"
label="${2:-draw}"
cols="${3:-46}"

if [ -z "$image" ]; then
  echo "usage: rex-draw.sh IMAGE.png [LABEL] [COLS]" >&2
  exit 2
fi
if [ ! -r "$image" ]; then
  echo "rex-draw: 读不到 $image" >&2
  exit 1
fi

command -v rex >/dev/null 2>&1 || { echo "rex-draw: 找不到 rex CLI" >&2; exit 1; }

session="${REX_SESSION:-}"
block="${REX_BLOCK:-}"
if [ -z "$session" ] || [ -z "$block" ]; then
  whoami="$(rex whoami --json)"
  session="$(printf '%s' "$whoami" | jq -r '.session_id // empty')"
  block="$(printf '%s' "$whoami" | jq -r '.block_id // empty')"
fi
[ -n "$session" ] && [ -n "$block" ] || { echo "rex-draw: 定位不到当前会话/窗格" >&2; exit 1; }

# 分屏里先画图，再原地等待，用户看够了自己 Ctrl+C 关掉。
# 传绝对路径，因为分屏的默认工作目录可能不是仓库根目录。
img_abs="$(cd "$(dirname "$image")" && pwd)/$(basename "$image")"

rex split -s "$session" -b "$block" --split=right --ratio 40 \
  --label "$label" --focus=false --json -- \
  sh -c "'$here/kitty-send.sh' '$img_abs' '$cols'; while :; do sleep 3600; done"
