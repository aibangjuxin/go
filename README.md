# Go 学习笔记

学习Go语言是一个很好的决定，因为它是一门简单而强大的编程语言。以下是一些系统学习Go语言的资源和建议：

官方文档：Go语言官方网站提供了全面的文档和教程，是学习Go的最佳起点。您可以从官方网站找到入门教程、语言规范、标准库文档等。

A Tour of Go：这是一个交互式的在线教程，由Go官方提供。您可以在https://tour.golang.org/welcome/1上访问它，逐步学习Go语言的基础知识。

Go by Example：Go by Example是一个以示例代码为主的学习资源，它覆盖了Go语言的各个方面，从基础到高级。

Go语言圣经：《Go语言圣经》（The Go Programming Language）是一本由Alan A.A. Donovan和Brian W. Kernighan撰写的书籍，它详细介绍了Go语言的各个方面。这本书是深入学习Go语言的好资源。

Go语言官方博客：Go语言官方博客经常发布有关语言和生态系统的最新信息和教程。您可以在官方博客上找到有用的文章。

Go Playground：Go Playground是一个在线的Go语言编程环境，您可以在其中编写、运行和共享Go代码片段，非常适合学习和尝试。

Go项目：参与开源Go项目可以加速学习过程，通过查看其他人的代码和贡献自己的代码，您可以获得实际的编程经验。您可以在GitHub上找到许多Go项目，并寻找感兴趣的项目来参与。

在线课程：有许多在线课程和教育平台提供关于Go语言的课程，例如Coursera、Udemy和edX。这些课程通常包括视频讲座、练习和项目。

Go的社区：加入Go语言社区，参与讨论、提问问题，并与其他Go开发者互动。社区是学习和成长的重要资源。

---

## 在 Rex 窗格里画图（Kitty 图形协议）

### 什么时候用

代理要处理的内容里出现**不能直接复述的词**时——构建日志里的脏话、用户粘贴的冒犯性词、
代码注释里的咒骂。原词只要出现在命令行或对话里，就会被留在 shell 历史、CI 日志和对话记录中。

这时候不要复述它，改为**在旁边的 Rex 窗格里画一张消音后的卡片**：
对话记录保持干净，用户照样看得到上下文。

Rex 终端内建 Ghostty，原生支持 [Kitty 图形协议](https://sw.kovidgoyal.net/kitty/graphics-protocol/)，
所以任何 Rex 窗格都能直接接收图片。

### 怎么用

```bash
# 1. 画一张已消音的词卡（TERM 由调用方先消音，原词不进命令行）
./tools/kitty-draw/word-card.sh /tmp/card.png "s**t" "语气: 愤怒 · 出自 build.log:42"

# 2. 在当前窗格右边开一个分屏，用 Kitty 图形协议把卡片画进去
./tools/kitty-draw/rex-draw.sh /tmp/card.png "draw" 46
```

分屏会停在原地等待，用户看完 `Ctrl+C` 关掉即可。
细节和协议说明见 [`tools/kitty-draw/README.md`](tools/kitty-draw/README.md)。

### 代理守的规矩

1. **原词不进命令行、不进对话。** 只传消音后的形式（`s**t`、`f***`），原词只留在代理的上下文里。
2. **卡片只示意"在说什么"。** 放语气、出处、上下文，不放可以直接复制的原词。
3. **一次一张。** 卡片是给人看的，不是日志；多张内容合成一张，说明文字写进 `NOTE`。
4. **画完即关。** 分屏里的进程等用户看完再 `Ctrl+C`，不要留一堆空窗格。
5. **别把图画在自己窗格里。** 用 `rex split` 在旁边开分屏，代理自己所在窗格保持不动。

### 不止脏话

同一套工具画任何 PNG 都行——架构图、报错截图、把命令输出渲染成图：

```bash
rsvg-convert -o /tmp/arch.png /tmp/arch.svg
./tools/kitty-draw/rex-draw.sh /tmp/arch.png "arch" 60
```
