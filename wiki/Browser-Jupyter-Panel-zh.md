# 浏览器与 Jupyter 面板

*[English](Browser-Jupyter-Panel) · 中文*

> 不离开终端，在侧边面板里打开网页。

## 内嵌浏览器面板

在带内嵌浏览器后端的构建上（Windows 为 WebView2，macOS 为 WKWebView），WispTerm
可以在右侧面板显示网页：

- 打开命令中心（`Ctrl+Shift+P`），运行 **Toggle Browser**。
- `Ctrl` 点击（macOS 上 `Cmd` 点击）终端输出里的 `http://` 或 `https://` 网址，即可
  在面板中打开。
- 点击面板的地址栏输入新地址，按 `Enter` 跳转。
- 拖动面板左边缘可调整宽度。

不带内嵌浏览器支持的构建，或没有可用浏览器运行时的环境，会改在系统默认
浏览器中打开网址。内嵌面板与 Copilot 侧栏、Markdown 预览共用右侧槽位，因此打开其一会
隐藏其它。

## 网址在哪打开

`url-open-mode` 控制网址在哪打开：

- `embedded`（默认）—— 可用时使用右侧浏览器面板。
- `system-browser` —— 始终用系统默认浏览器打开。

在 SSH profile 会话中，loopback 网址会通过自动建立、两种模式共享的本地 SSH 隧道打开 ——
见 [[SSH 与远程开发|SSH-Remote-Development-zh]]。

## Jupyter

从一个专用面板连接远程 Jupyter notebook 的功能**仍在开发中**，尚未进入发布版本。目前可
像打开任何 Web 应用那样打开 Jupyter 网址：在远程主机上启动 Jupyter，然后 `Ctrl`/`Cmd`
点击它打印的 `http://localhost:<port>/?token=...` 网址 —— WispTerm 会自动通过 SSH 转发
该 loopback 端口（见 [[SSH 与远程开发|SSH-Remote-Development-zh]]）。

---
*另见：[[SSH 与远程开发|SSH-Remote-Development-zh]] · [[文件浏览器与预览|File-Explorer-zh]]*
