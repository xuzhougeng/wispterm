# WispTerm 使用 Wiki

*[English](Home) · 中文*

> WispTerm 是一个面向远程开发与 AI 智能体工作流的跨平台终端工作区。本 Wiki 是它的实操使用指南。

WispTerm（原名 **Phantty**）用 Zig 编写，终端模拟由
[libghostty-vt](https://github.com/ghostty-org/ghostty) 驱动。它集成了高性能终端、
标签与分屏、数百款主题、带预览的文件浏览器、内嵌浏览器面板，以及内置的 AI 副驾，
并对 SSH 与远程开发提供一流支持。

## 平台支持

WispTerm 提供 **Windows** 与 **macOS**（Apple Silicon 与 Intel）版本，**Linux**
移植仍在进行中，因此下文少数功能目前仅限 Windows 或 macOS —— 相关处都会注明。

## 功能一览

- **终端模拟** —— libghostty-vt 的 VT 解析、FreeType 字形渲染、精灵字符/制表符绘制。
- **主题与外观** —— 450+ 内置 Ghostty 主题、自定义字体、背景图、GLSL 着色器 → [[主题与外观|Themes-Appearance-zh]]
- **标签、分屏与面板** —— 横/竖分屏、焦点切换、面板交换、Quake 下拉模式 → [[标签、分屏与面板|Tabs-Splits-Panels-zh]]
- **文件浏览器与预览** —— 浏览本地、WSL 与 SSH 文件；预览 Markdown/文本/表格/图片 → [[文件浏览器与预览|File-Explorer-zh]]
- **SSH 与远程开发** —— profile 会话、远程文件下载、自动 loopback 端口转发 → [[SSH 与远程开发|SSH-Remote-Development-zh]]
- **端口转发与代理** —— 手动配置反向/本地 SSH 隧道；把本地代理共享给远程服务器 → [[端口转发与代理|Port-Forwarding-zh]]
- **AI 副驾与智能体** —— 兼容 OpenAI/Anthropic 的 profile、按标签的副驾侧栏、技能、历史与恢复 → [[AI 副驾与智能体|AI-Copilot-zh]]
- **浏览器与 Jupyter 面板** —— 在右侧 WebView 面板打开网址（Windows）→ [[浏览器与 Jupyter 面板|Browser-Jupyter-Panel-zh]]
- **内联图片** —— Kitty Graphics 协议；在远程 shell 里显示图片和 PDF → [[内联图片|Inline-Images-zh]]
- **可选远程访问** —— 通过 Cloudflare relay 共享会话，默认关闭 → [[远程访问|Remote-Access-zh]]

## 从这里开始

1. **[[安装|Installation-zh]]** —— 在 Windows 或 macOS 上下载并运行 WispTerm。
2. **[[快速上手|Getting-Started-zh]]** —— 首次启动、命令中心、标签与会话。
3. **[[配置|Configuration-zh]]** —— 配置文件在哪里、可以设置哪些项。

遇到问题？看看 **[[常见问题|FAQ-zh]]**。

---
*另见：[[安装|Installation-zh]] · [[快速上手|Getting-Started-zh]]*
