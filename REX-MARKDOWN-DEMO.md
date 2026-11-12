# Rex Markdown 预览演示

这是一份用于验证 **Rex Markdown for Pi** 的 Markdown 文件。

## 一、功能列表

- **标题**、**粗体**、*斜体*、`行内代码`
- 有序列表：
  1. 点击 Pi 里的链接
  2. Rex 右侧自动开分屏
  3. 预览里按 `Ctrl+Q` 关闭

## 二、表格

| 组件 | 作用 | 状态 |
| --- | --- | --- |
| `rex-markdown.ts` | Pi 扩展，改写显示层链接 | ✅ |
| `Rex Markdown.app` | macOS `rex-md:` 协议 handler | ✅ |
| `terminal-browser` | 渲染 Markdown（Kitty graphics） | ✅ |

## 三、代码块

```bash
rex whoami --json
node ~/.pi/tools/rex-markdown/open.mjs "rex-md://open/<ticket>"
```

## 四、引用与链接

> 这是一个引用块，用来验证渲染是否正常。

里面还有一个[相对链接](./README.md)，以及一个[网页链接](https://example.com)。

---

*生成时间：2026-11-12 · 用于点击测试*
