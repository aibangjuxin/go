# kitty-draw — 在 Rex 窗格里画图

用 [Kitty 图形协议](https://sw.kovidgoyal.net/kitty/graphics-protocol/) 把图片直接画进终端。

Rex 终端内建 Ghostty，支持 Kitty 图形协议，所以任何 Rex 窗格都能接收图片。

## 为什么需要它

代理经常要处理"不能直接写出来"的内容：构建日志里的脏话、用户粘贴的冒犯性词、
代码注释里的咒骂。复述它会把原词留在对话记录和 shell 历史里。

这套工具的思路是：**原词不出现在任何命令行或对话里，只画一张消音后的卡片**，
让用户看到"大概在说什么"，同时保持记录干净。

## 脚本

| 脚本 | 作用 |
| --- | --- |
| `kitty-send.sh IMAGE.png [COLS] [ROWS]` | 把 PNG/JPEG 通过 Kitty 图形协议写到 stdout（stdout 就是终端） |
| `word-card.sh OUT.png TERM [NOTE] [LABEL]` | 生成一张"已消音"词卡 PNG。`TERM` 由调用方先消音好，原词不进命令行 |
| `rex-draw.sh IMAGE.png [LABEL] [COLS]` | 在当前窗格右边开一个分屏，把图片画进去，然后原地等待 |

## 快速上手

```bash
# 1. 画一张消音词卡
./tools/kitty-draw/word-card.sh /tmp/card.png "s**t" "语气: 愤怒 · 出自 build.log:42"

# 2. 在右边开一个分屏，把卡片画进去
./tools/kitty-draw/rex-draw.sh /tmp/card.png "draw" 46
```

分屏会停在 `while :; do sleep 3600; done`，用户看完 `Ctrl+C` 关掉即可。

想画别的东西（架构图、报错截图、ASCII 渲染的图），直接给 `rex-draw.sh` 一张 PNG 即可：

```bash
rsvg-convert -o /tmp/arch.svg.png /tmp/arch.svg   # 或者 magick / 任何 PNG 生成器
./tools/kitty-draw/rex-draw.sh /tmp/arch.svg.png "arch" 60
```

## 协议要点

Kitty 图形协议用 APC 转义序列传图：

```
ESC _ G <控制数据> ; <base64 负载> ESC \
```

- `a=T` 传输并显示，`f=100` 表示 PNG，`t=d` 表示负载是 base64 直接数据
- `c=` / `r=` 是按单元格算的显示列数 / 行数
- 负载必须分块，每块 ≤ 4096 字节（且除最后一块外都是 4 的倍数），最后一块用 `m=0` 收尾

`kitty-send.sh` 就是这段协议的实现，没有额外依赖。

## 依赖

- `rex` CLI 与 Rex 终端（内建 Ghostty，支持 Kitty 图形协议）
- `rsvg-convert`（或 ImageMagick 的 `magick` / `convert`）—— 只有 `word-card.sh` 需要
- `jq` —— 只有 `rex-draw.sh` 在拿不到 `$REX_SESSION` / `$REX_BLOCK` 时需要

## 排查

画面没出来时，先确认终端认这个协议：

```sh
printf '\033_Ga=q,i=42,f=100,t=d;%s\033\\' "$(base64 < img.png | tr -d '\n')"
```

Rex 窗格会回一行 `ESC_Gi=42;OK`。没有回复说明这个终端不支持 Kitty 图形协议。

Rex 端的服务端日志在 `rex whoami --json` 的 `log_path` 字段里，图形相关的报错会以
`kitty graphics protocol error` 出现。
