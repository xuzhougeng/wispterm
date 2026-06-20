# 常见问题与排障

*[English](FAQ) · 中文*

> 关于提权、远程访问、配置与平台支持的常见问题。

## 为什么我的 shell 不是以管理员身份运行？（Windows）

WispTerm 不会自行给 shell 提权。shell 继承运行中 `wispterm.exe` 进程的权限级别。普通方式
启动 WispTerm（双击或非提权快捷方式）得到的是标准权限令牌 —— 即便你的账户属于
Administrators 组（UAC 拆分令牌）。

## 如何运行管理员 shell？（Windows）

- **以管理员身份运行 WispTerm：** 右键 `wispterm.exe` 或其快捷方式，选择
  **以管理员身份运行**。通过 UAC 批准后，新标签会继承提权令牌。
- **仅单独开一个提权窗口：** 在任意 shell 里运行 `Start-Process pwsh -Verb RunAs`
  （或 `powershell`）。它在 UAC 之后启动一个新的提权进程，不会替换当前标签。

没有受支持的方法能在不新建进程、不经 UAC 同意的情况下，把已有的非提权 shell 提升为提权。

## Codex / Claude Code 里鼠标滚轮、滚动条失效？（Windows 10）

较老的 Windows 10 自带的 ConPTY 控制台宿主不转发现代鼠标输入，因此 **Codex**、
**Claude Code** 这类全屏 TUI 应用在终端里会失去滚轮滚动和滚动条交互。

解决办法：使用 **`wispterm-windows-portable-compat-*.zip`** 发布包（v1.19.0 起提供）。
它在 `wispterm.exe` 旁边捆绑了现代版 `conpty.dll` + `OpenConsole.exe`；只要这两个文件
存在，WispTerm 默认就会优先使用捆绑版（`windows-conpty = auto`，即默认值）。如需强制
使用系统自带 ConPTY，设置 `windows-conpty = system` —— 见 [[配置|Configuration-zh]]。

重要：**请把整个 zip 完整解压到一个文件夹，并从该文件夹运行 `wispterm.exe`**，让
`conpty.dll` 和 `OpenConsole.exe` 始终在 exe 旁边。如果直接在压缩包里双击运行
`wispterm.exe`（资源管理器只会把 exe 解压到临时目录），这两个文件就不在旁边，
WispTerm 会静默回退到系统自带 ConPTY，滚轮/滚动条又会失效。

## 选中文本会打断程序（出现 ^C），或“复制”其实没复制成功？

如果在终端里选中文本会打断正在运行的程序（出现 `^C`、命令被取消，或被踢出
**Codex** / **Claude Code**），或者复制提示成功但粘贴出来的是*之前*的剪贴板内容，
原因几乎都是后台运行的**“划词翻译 / 选中即复制”类工具**——常见的有：有道词典
划词翻译、欧路词典、QTranslate，以及某些鼠标/触摸板驱动或剪贴板管理器。

这类工具在检测到鼠标选中文本后，会**合成一个 Ctrl+C 按键**去抓取选中的文字。在普通
GUI 程序里 Ctrl+C 表示“复制”，但**在终端里 Ctrl+C 是中断键（SIGINT）**，于是就打断了
正在运行的程序。它们很多还会在读取后**还原你原来的剪贴板**，所以你在终端里真正想复制时，
会看到“已复制”却粘不出内容。

为什么 conhost / Windows Terminal 没事，WispTerm 会中招？因为前两者通过 **UI
Automation（UIA）** 暴露了终端文本和选区，这类工具直接用 UIA 读选区、根本不发 Ctrl+C。
WispTerm 目前还没有 UIA 文本源，工具只能退化到 Ctrl+C 这条老路。

解决办法：关闭该工具的“选中即复制 / 划词”功能（有道词典：设置 → 取词划词 → 关闭划词
翻译），或把 WispTerm 加入其例外，或直接退出该工具。想确认是不是后台工具在作怪，可以用
**Shift + 方向键**（只用键盘、不碰鼠标）选中文本：如果这样不会触发中断，那就是指针设备/
划词类工具导致的。

## 低配置电脑上 WispTerm 很卡或窗口黑屏？（弱核显）

Windows 上 WispTerm 默认通过 DXGI flip-model 交换链呈现画面。在核显较弱的机器上
（典型如 Win11 轻薄本），这条路径可能明显偏慢（v1.18.0），v1.19.0 甚至可能让窗口黑屏。

自 **v1.19.1** 起，WispTerm 会自动识别持续过慢或已损坏的呈现路径：升级后**第一次**启动
可能仍卡顿一次，从**下一次**启动开始，应用会在这台机器上永久切换到经典 GDI 呈现 ——
卡顿和黑屏同时消失。使用独立显卡或外接显卡则完全不会走到慢路径。

也可以随时手动关闭：设置 `wispterm-d3d-present = false` —— 见 [[配置|Configuration-zh]]。

## 如何不中断当前对话切换 AI 模型？

在 AI Chat 标签或 Copilot 侧栏中输入 `/model` 可打开已保存 profile 选择器，输入
`/model <name>` 可按 profile 名直接切换，也可以使用中文别名 `/模型`。你还可以点击聊天/
Copilot 头部的模型标签。

切换只影响当前会话，不会改变全局默认 profile，也不会覆盖磁盘上的已保存 profile。
WispTerm 会让新模型在后台总结此前对话，并把交接内容显示为可折叠的 **Conversation
summary / 上文摘要** 卡片；如果摘要失败，则保留完整原始历史。

## 怎么生成诊断报告？

Windows 发布包已经内置 `wispterm-diagnostics` skill。正常反馈问题时，打开 WispTerm
的 AI Chat 标签或 Copilot 侧栏，让这个内置 skill 收集环境、分析问题，并生成可直接贴到
GitHub issue 的 Markdown：

如果没有这个 skill，或版本较旧，可以先打开 **Skill Center** 从 GitHub 下载/更新最新技能。

```text
$wispterm-diagnostics
Problem type: ssh-disconnect
Symptom: SSH Profile 空闲 5-10 分钟后断开，显示 "Connection reset"。
Repro steps: 连接保存的 SSH profile，空闲等待，然后运行 ls。
What I already tried: 外部 ssh.exe 加 ServerAliveInterval 后不断。
```

如果问题类型明确，请在提示里写上更具体的 problem type：

- `ssh-image-preview`：SSH 图片预览失败，但 Markdown/文本预览正常。
- `html-preview`：本地、WSL 或 SSH 环境里的 `.html` 预览 / 浏览器面板失败。
- `ssh-disconnect`：SSH 掉线，并出现 `ssh_packet_write_poll`、`eother`
  或空闲后的 `Connection reset` 等错误。
- `startup/crash`、`rendering/DPI`、`high-cpu`、`keyboard/input`、
  `selection/copy/scrolling`、`SSH/SCP`、`file explorer`、
  `WebView2/browser panel`、`updater` 或 `remote console`。

skill 会输出 Markdown 报告，包含 WispTerm 版本、发布包文件、Windows/OpenSSH/WebView2/GPU
信息、脱敏后的配置、相关日志、你的现象/复现步骤和针对该问题的下一步排查建议。公开发布前
请先检查内容；不要在公开 issue 中包含密码、私钥、token 或 crash dump。

兜底方式：如果 WispTerm 无法启动，或 AI Agent 不可用，再从已解压/安装的 WispTerm
目录手动运行诊断脚本。该目录需要包含 `plugins\skills\wispterm-diagnostics`：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\plugins\skills\wispterm-diagnostics\scripts\collect_wispterm_diagnostics.ps1 -ProblemType "other"
```

## 怎么反馈崩溃或卡死？（Windows 调试版本）

每个 Windows 版本在 [Releases](https://github.com/xuzhougeng/wispterm/releases) 页面都会附带一个
**`wispterm-windows-debug-<版本>.zip`**。它是带控制台、开了额外安全检查的版本，会把日志写到
`%APPDATA%\wispterm\wispterm-debug.log`（崩溃时还会写 `crash-<时间戳>.txt`）。遇到难以复现的问题
—— 比如打开微信连接时崩溃，或 Ctrl+点击远程文件时卡死 —— 下载它、复现问题，然后把
`wispterm-debug.log`（以及任何 `crash-*.txt`）附在反馈里。

如果问题是 Ctrl+点击预览或浏览器面板失败，调试日志里还会出现以 `preview-diagnostic`
开头、可以直接复制的单行记录。复现后，如果完整日志太大，可以只把附近这些
`preview-diagnostic` 行贴到 issue 里。它们覆盖预览路径解析、异步文件读取、图片解码、
HTML server 启动、SSH 浏览器隧道、URL 路由和内嵌浏览器面板。

## 为什么远程在手机上镜像本地终端尺寸？

WispTerm Remote 镜像本地窗口，因为桌面应用是终端状态的唯一真相来源 —— 本地 PTY、VT 状态、
回滚、光标和分屏布局都在那里捕获，再以流的方式发送到浏览器。移动端 UI 可以聚焦单个画面，
但目前不会创建独立的、手机尺寸的终端网格。见 [[远程访问|Remote-Access-zh]]。

## 我的配置在哪里？怎么热重载？

运行 `wispterm --show-config-path` 打印解析出的路径，或按 `Ctrl+,`（macOS 上 `Cmd+,`）
在编辑器中打开。保存文件即可让多数改动无需重启生效。完整说明与配置项参考见
[[配置|Configuration-zh]]。

## 有 Linux 版本吗？

有，但仍是实验性质。Release 页面会提供 Linux x86_64 AppImage，供社区测试。它内置
SDL3，适合早期反馈，但 Linux 移植尚不视为稳定版本。建议从终端启动，这样启动或图形错误
会直接显示出来。

---
*另见：[[配置|Configuration-zh]] · [[远程访问|Remote-Access-zh]] · [[首页|Home-zh]]*
