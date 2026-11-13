#!/usr/bin/env bash
#
# kitty-send.sh — 用 Kitty 图形协议把一张图片画进当前终端。
#
# 用法:
#   kitty-send.sh IMAGE.png [COLS] [ROWS]
#
# - IMAGE 必须已经是 PNG / JPEG。
# - COLS / ROWS 可选：按单元格计算的显示尺寸，省略则按图片原始像素大小显示。
#
# 原理:
#   Kitty 图形协议用 APC 转义序列传图:
#     ESC _ G <控制数据> ; <base64 负载> ESC \
#   负载必须分块发送，每块不超过 4096 字节，最后一块用 m=0 收尾。
#
# stdout 就是终端，所以直接把输出重定向或管道给终端即可。

set -euo pipefail

image="${1:-}"
cols="${2:-0}"
rows="${3:-0}"

if [ -z "$image" ]; then
  echo "usage: kitty-send.sh IMAGE.png [COLS] [ROWS]" >&2
  exit 2
fi
if [ ! -r "$image" ]; then
  echo "kitty-send: 读不到 $image" >&2
  exit 1
fi

# 控制数据: a=T 直接显示, f=100 表示 PNG, t=d 表示负载是 base64 直接数据
meta="a=T,f=100,t=d"
if [ "$cols" -gt 0 ] 2>/dev/null; then meta="$meta,c=$cols"; fi
if [ "$rows" -gt 0 ] 2>/dev/null; then meta="$meta,r=$rows"; fi

tmp="$(mktemp -t kitty-send.XXXXXX)"
trap 'rm -f "$tmp"' EXIT

base64 < "$image" | tr -d '\n' | fold -w 4096 > "$tmp"
total="$(wc -l < "$tmp" | tr -d ' ')"
[ "$total" -gt 0 ] || { echo "kitty-send: $image 是空文件" >&2; exit 1; }

i=0
while IFS= read -r chunk; do
  [ -n "$chunk" ] || continue
  i=$((i + 1))
  if [ "$i" -lt "$total" ]; then m=1; else m=0; fi
  if [ "$i" -eq 1 ]; then
    # 第一块带完整控制数据，之后的块只带 m。
    printf '\033_G%s,m=%s;%s\033\\' "$meta" "$m" "$chunk"
  else
    printf '\033_Gm=%s;%s\033\\' "$m" "$chunk"
  fi
done < "$tmp"
