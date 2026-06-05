# 文件浏览器与预览

*[English](File-Explorer) · 中文*

> 在侧边面板浏览本地、WSL 与 SSH 文件，并在不离开终端的情况下预览 Markdown、文本、表格和图片。

## 打开文件浏览器

按 `Ctrl+Shift+Alt+E` 打开左侧文件浏览器。它跟随当前活动环境：

- Windows shell 浏览本地 Windows 路径。
- WSL 会话通过 `wsl.exe` 浏览默认 WSL 发行版。
- WispTerm SSH profile 会话通过 OpenSSH 辅助命令浏览远程主机。

## 预览文件

用以下两种方式之一打开右侧预览面板：

- 按住 `Ctrl`（macOS 上 `Cmd`）并点击终端输出中的 `.md`、`.txt`、`.csv`、`.tsv`、
  源代码或脚本文件（含 R 脚本 `.r` / `.R`）或受支持的图片文件，**或**
- 在文件浏览器里双击受支持的文件。

各类型的渲染：

- **Markdown** —— 标题、列表、引用块、代码块、行内代码、链接和分隔线。
- **文本 / 代码 / 脚本** —— 以纯文本显示（`.r`、`.R`、`.py`、`.zig`、`.sh`、`.json` 等）。
- **CSV / TSV** —— 以网格表格显示。
- **图片** —— PNG、JPEG、GIF、BMP、WebP 直接解码到面板中。

## 用默认应用打开文件

按住 `Ctrl`（macOS 上 `Cmd`）并**右键点击**本地终端中的文件路径，即可用操作系统为
该文件类型注册的默认应用打开它（Linux 上 `xdg-open`，macOS 上 `open`，Windows 上系统
注册的处理程序）。

此功能仅适用于本地终端 —— 本地应用无法打开 SSH 与 WSL 路径，因此在那些会话中
`Ctrl`+右键会回退到配置的 `right-click-action`（复制/粘贴），见 [[配置|Configuration-zh]]。
不按 `Ctrl` 的普通右键始终执行配置的 `right-click-action`。

## 调整大小、滚动与缩放

- 拖动浏览器与预览面板的内侧边缘可调整大小。
- Markdown、文本、CSV、TSV 预览支持鼠标滚轮滚动；CSV/TSV 单元格内容放不下时，悬停会
  显示更大的弹窗。
- 图片预览支持滚轮缩放，放大后可拖动平移。
- `Ctrl+Shift+W` 会先关闭预览面板，再关闭分屏。

## 下载远程文件

在 SSH profile 会话中，按住 `Ctrl+Shift`（macOS 上 `Cmd+Shift`）悬停在终端输出里的
文件路径上使其加下划线，然后点击即可把该远程文件下载到 `%USERPROFILE%\Downloads`。
下载在后台进行。

## SSH 元数据要求

远程预览与下载需要 WispTerm 的 SSH profile 元数据，因此仅支持从内置 SSH 启动器发起的
会话。在本地 shell 里手动敲 `ssh user@host` 仍被当作那个本地 shell，无法使用远程文件
预览 —— 见 [[SSH 与远程开发|SSH-Remote-Development-zh]]。

---
*另见：[[SSH 与远程开发|SSH-Remote-Development-zh]] · [[浏览器与 Jupyter 面板|Browser-Jupyter-Panel-zh]]*
