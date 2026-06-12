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

## 低配置电脑上 WispTerm 很卡或窗口黑屏？（弱核显）

Windows 上 WispTerm 默认通过 DXGI flip-model 交换链呈现画面。在核显较弱的机器上
（典型如 Win11 轻薄本），这条路径可能明显偏慢（v1.18.0），v1.19.0 甚至可能让窗口黑屏。

自 **v1.19.1** 起，WispTerm 会自动识别持续过慢或已损坏的呈现路径：升级后**第一次**启动
可能仍卡顿一次，从**下一次**启动开始，应用会在这台机器上永久切换到经典 GDI 呈现 ——
卡顿和黑屏同时消失。使用独立显卡或外接显卡则完全不会走到慢路径。

也可以随时手动关闭：设置 `wispterm-d3d-present = false` —— 见 [[配置|Configuration-zh]]。

## 为什么远程在手机上镜像本地终端尺寸？

WispTerm Remote 镜像本地窗口，因为桌面应用是终端状态的唯一真相来源 —— 本地 PTY、VT 状态、
回滚、光标和分屏布局都在那里捕获，再以流的方式发送到浏览器。移动端 UI 可以聚焦单个画面，
但目前不会创建独立的、手机尺寸的终端网格。见 [[远程访问|Remote-Access-zh]]。

## 我的配置在哪里？怎么热重载？

运行 `wispterm --show-config-path` 打印解析出的路径，或按 `Ctrl+,`（macOS 上 `Cmd+,`）
在编辑器中打开。保存文件即可让多数改动无需重启生效。完整说明与配置项参考见
[[配置|Configuration-zh]]。

## 有 Linux 版本吗？

WispTerm 目前提供 **Windows** 与 **macOS** 版本。**Linux** 移植仍在进行中 —— 进展见
[`TODO.md`](https://github.com/xuzhougeng/wispterm/blob/main/TODO.md)。

---
*另见：[[配置|Configuration-zh]] · [[远程访问|Remote-Access-zh]] · [[首页|Home-zh]]*
