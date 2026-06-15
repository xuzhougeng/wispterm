[English](README.md) | 简体中文

# WispTerm

<p>
<a href="https://github.com/xuzhougeng/wispterm/releases"><img src="https://img.shields.io/badge/Windows-supported-0078D4" alt="Windows supported"></a>
<a href="https://github.com/xuzhougeng/wispterm/releases"><img src="https://img.shields.io/badge/macOS-supported-000000" alt="macOS supported"></a>
<a href="https://github.com/xuzhougeng/wispterm/releases"><img src="https://img.shields.io/badge/Linux-experimental-FCC624" alt="Linux experimental"></a>
<a href="https://github.com/xuzhougeng/wispterm/blob/main/LICENSE"><img src="https://img.shields.io/github/license/xuzhougeng/wispterm" alt="License"></a>
<br>
<a href="https://github.com/xuzhougeng/wispterm/stargazers"><img src="https://img.shields.io/github/stars/xuzhougeng/wispterm?style=social" alt="Stars"></a>
<a href="https://github.com/xuzhougeng/wispterm/releases"><img src="https://img.shields.io/github/v/release/xuzhougeng/wispterm?include_prereleases" alt="Release"></a>
<a href="https://github.com/xuzhougeng/wispterm/releases"><img src="https://img.shields.io/github/downloads/xuzhougeng/wispterm/total" alt="Downloads"></a>
<a href="https://github.com/xuzhougeng/wispterm/commits/main"><img src="https://img.shields.io/github/last-commit/xuzhougeng/wispterm" alt="Last commit"></a>
</p>

**WispTerm**（原名 Phantty）是一个面向远程开发与 AI 智能体工作流的跨平台终端工作区。它用 Zig 编写，终端模拟由 [libghostty-vt](https://github.com/ghostty-org/ghostty) 驱动。

> [!NOTE]
> WispTerm 提供 **Windows** 与 **macOS**（Apple Silicon 与 Intel）版本。**Linux**
> 移植仍在进行中（见 [TODO.md](TODO.md)）。

## 功能特性

- **Ghostty 的终端模拟** —— 使用 libghostty-vt 进行 VT 解析与终端状态管理
- **DirectWrite 字体发现** —— 按名称查找系统字体，并对缺失字符做逐字形回退
- **FreeType 渲染** —— 高质量字形栅格化，采用 Ghostty 风格的字体度量
- **Sprite 渲染** —— 制表线、块元素、盲文点阵、Powerline 符号
- **主题支持** —— 兼容 Ghostty 主题文件，内置 450+ 主题（默认：Poimandres）
- **背景图与着色器** —— 壁纸混合，外加 Ghostty 兼容的 GLSL 后处理
- **分屏与标签页** —— 横/纵向分屏、标签栏、焦点跟随鼠标、均分尺寸
- **文件浏览器与预览** —— 浏览本地、WSL、SSH 文件；无需离开终端即可预览 Markdown / 文本 / 表格 / 图片 / PDF
- **内嵌浏览器面板** —— 在侧边 WebView2 面板或默认浏览器中打开网址，并为 profile 会话提供持久的 SSH 回环端口转发
- **SSH 端口转发管理器** —— 在专用标签页中静默管理本地与反向 SSH 转发规则
- **AI 智能体会话** —— 启动 OpenAI 兼容的智能体标签页，配置 profile、恢复历史，导出完整或精简的 Markdown 对话记录
- **AI 历史浏览器** —— 浏览本地、WSL 与 SSH 上的 Codex / Claude Code / Reasonix 历史，并从原始项目目录恢复会话
- **Kitty 图形协议** —— 通过 `imgcat.py` / `pdfcat.py` 在远程 shell 中内联显示图片和 PDF
- **可选的远程访问** —— 通过 Cloudflare 托管的中继分享会话密钥（默认关闭）

## 文档

- [配置](docs/configuration.md)
- [文件浏览器与预览](docs/file-explorer.md)
- [AI 智能体会话](docs/ai-agent.md)
- [媒体、背景图与内联远程图片](docs/media.md)
- [SSH 端口转发](docs/port-forwarding.md)
- [开发、架构、打包与发布](docs/development.md)
- [常见问题](docs/faq.md)

> 注：上述文档目前均为英文。

## 构建

Windows（PowerShell）：

```powershell
zig build                         # 开发用 Debug 构建
zig build -Doptimize=ReleaseFast  # 用于分发的 ReleaseFast 构建
Remove-Item -Recurse -Force .\zig-out, .\.zig-cache -ErrorAction SilentlyContinue
```

macOS（需要 macOS 13+ 与 Zig 0.15.2）：

```bash
zig build macos-app -Dtarget=aarch64-macos   # Apple Silicon 的 .app 包（Intel 用 x86_64-macos）
open zig-out/bin/WispTerm.app                  # 启动构建好的应用
```

`Makefile` 可能仍作为便捷封装存在，但常规的 Windows 开发应使用 PowerShell 与直接的
`zig` 命令。

架构、打包与发布细节见[开发、架构、打包与发布](docs/development.md)。

## 使用

在 Windows 上运行 `wispterm.exe`；在 macOS 上运行 `WispTerm.app/Contents/MacOS/wispterm`
（或直接启动 `WispTerm.app` —— 传入 CLI 参数需要使用二进制路径）。

```bash
wispterm [options]

选项：
  --font, -f <name>            设置字体（默认：内嵌回退字体）
  --font-style <style>         字体字重（默认：regular）
                                可选：thin, extra-light, light, regular,
                                      medium, semi-bold, bold, extra-bold, black
  --cursor-style <style>       光标形状（默认：block）
                                可选：block, bar, underline, block_hollow
  --cursor-style-blink <bool>  启用光标闪烁（默认：true）
  --theme <path>               加载一个 Ghostty 主题文件
  --background-image <path>    渲染在终端背后的图片文件
  --background-opacity <0..1>  主题/单元格背景的不透明度（默认：1.0）
  --background-image-mode <m>  fill | fit | center | tile（默认：fill）
  --window-height <rows>       初始窗口高度（单位：行；默认：0=自动，最小：4）
  --window-width <cols>        初始窗口宽度（单位：列；默认：0=自动，最小：10）
  --quake-mode <bool>          启用 Quake 风格下拉模式（默认：true）
  --keybind <binding>          配置快捷键，例如 global:ctrl+backquote=toggle_quake
  --config <path>              使用此文件作为主配置
  --config-path <path>         --config 的别名
  --config-file <path>         包含另一个配置文件（前缀 ? 表示可选）
  --version, -v                打印 WispTerm 版本并退出
  --show-config-path           打印解析出的主配置路径
  --list-fonts                 列出可用的系统字体
  --list-themes                列出可用的主题
  --test-font-discovery        测试 DirectWrite 字体发现
  --help, -h                   显示帮助
```

配置文件细节见[配置](docs/configuration.md)。

## 键盘快捷键

应用级默认组合键定义在 [`src/keybind.zig`](src/keybind.zig)，可在配置文件中用重复的
`keybind = ...` 行重新映射。一些模态/编辑器局部按键仍由获得焦点的浮层优先处理
（命令中心导航、会话启动器编辑、AI 聊天输入等）。

重映射示例：

```text
keybind = alt+f10=toggle_command_palette
keybind = global:ctrl+backquote=toggle_quake
```

如果想清除全部默认绑定并从头重建，请在自定义绑定前加上 `keybind = clear`。要确认正在
运行的桌面版本，打开命令中心（Windows 上 `Ctrl+Shift+P`，macOS 上 `Cmd+Shift+P`），输入
`version` 并回车。

> **macOS 修饰键映射：** 多数快捷键用 **Cmd** 代替 Ctrl、用 **Opt** 代替 Alt。有两个例外
> 保留 Ctrl 以避免与系统快捷键冲突：**Ctrl+`**（Quake —— `Cmd+`` 是系统窗口切换器）以及
> **Ctrl+Tab** / **Ctrl+Shift+Tab**（标签切换 —— `Cmd+Tab` 是系统应用切换器）。

| 操作 | Windows / Linux | macOS |
| ---- | --------------- | ----- |
| 显示/隐藏 Quake 下拉窗口 | **Ctrl+`** | **Ctrl+`** |
| 打开命令中心 | **Ctrl+Shift+P** | **Cmd+Shift+P** |
| 新建会话（会话启动器） | **Ctrl+Shift+T** | **Cmd+Shift+T** |
| 新建窗口 | **Ctrl+Shift+N** | **Cmd+Shift+N** |
| 切换标签侧边栏 | **Ctrl+Shift+B** | **Cmd+Shift+B** |
| 向右分屏 | **Ctrl+Shift++** | **Cmd+Shift++** |
| 向下分屏 | **Ctrl+Shift+-** | **Cmd+Shift+-** |
| 切换文件浏览器侧边栏 | **Ctrl+Shift+Alt+E** | **Cmd+Shift+Opt+E** |
| 切换 AI Copilot 侧边栏（当前终端） | **Ctrl+Shift+A** | **Cmd+Shift+A** |
| 预览文件（终端内 Ctrl/Cmd 单击，或文件浏览器中双击） | Ctrl 单击 | Cmd 单击 |
| 在图库中查看上一张 / 下一张图片或 PDF（预览面板聚焦时） | Left / Right | Left / Right |
| PDF 预览上一页 / 下一页（PDF 预览面板聚焦时） | PageUp / PageDown | PageUp / PageDown |
| 下载 SSH 远程文件 | 在 SSH 输出中 Ctrl+Shift 单击路径 | 在 SSH 输出中 Cmd+Shift 单击路径 |
| 关闭聚焦的面板、标签页或窗口 | **Ctrl+Shift+W** | **Cmd+Shift+W** |
| 最大化或还原窗口 | **Alt+Enter** | **Opt+Enter** |
| 增大 / 减小字号 | **Ctrl++** / **Ctrl+-** | **Cmd++** / **Cmd+-** |
| 复制终端选区或 AI 聊天选区/记录 | **Ctrl+Shift+C** | **Cmd+Shift+C** |
| 从上一次终端单击锚点开始选择 | 在终端文本上 Shift 单击 | 在终端文本上 Shift 单击 |
| 选择 AI 回答的一部分 | 拖选 AI 回答文本 | 拖选 AI 回答文本 |
| 选择并复制 AI 回答的一部分 | Shift 拖选 AI 回答文本 | Shift 拖选 AI 回答文本 |
| 选择 AI 聊天输入；输入为空时选择整段记录 | 在 AI 聊天中 **Ctrl+A** | 在 AI 聊天中 **Cmd+A** |
| 复制 AI 聊天选区或完整记录 | 在 AI 聊天中 **Ctrl+C** | 在 AI 聊天中 **Cmd+C** |
| 删除选中的已保存智能体会话 | 在智能体历史中 **D** / **Delete** | 在智能体历史中 **D** / **Delete** |
| 编辑 AI 历史筛选条件 | 在 AI 历史中输入 / Backspace | 在 AI 历史中输入 / Backspace |
| 移动选中的 AI 历史会话 | AI 历史中 Up / Down | AI 历史中 Up / Down |
| 恢复选中的 AI 历史会话 | AI 历史中 Enter | AI 历史中 Enter |
| 预览选中的 AI 历史记录 | AI 历史中 Space | AI 历史中 Space |
| 刷新本地 AI 历史扫描 | 本地 AI 历史中 **R** | 本地 AI 历史中 **R** |
| 编辑 AI 聊天输入光标 | Left/Right/Home/End/Delete/Backspace | Left/Right/Home/End/Delete/Backspace |
| 停止进行中的 AI 聊天或智能体请求 | 工作时在 AI 聊天中按 **Esc** | 工作时在 AI 聊天中按 **Esc** |
| 复制选区（右键） | 右键点击选区 | 右键点击选区 |
| 粘贴文本 | **Ctrl+V** | **Cmd+V** |
| 粘贴剪贴板图片 | **Ctrl+Shift+V** | **Cmd+Shift+V** |
| 把焦点移到相邻面板 | **Alt** + 方向键 | **Opt** + 方向键 |
| 按编号聚焦面板 1–9 | **Ctrl+1**–**9** | **Cmd+1**–**9** |
| 聚焦上一个面板（循环） | **Ctrl+Shift+[** | **Cmd+Shift+[** |
| 聚焦下一个面板（循环） | **Ctrl+Shift+]** | **Cmd+Shift+]** |
| 均分分屏尺寸 | **Ctrl+Shift+Z** | **Cmd+Shift+Z** |
| 下一个标签页 | **Ctrl+Tab** | **Ctrl+Tab** |
| 上一个标签页 | **Ctrl+Shift+Tab** | **Ctrl+Shift+Tab** |
| 切换到标签页 1–9 | **Alt+1**–**9** | **Opt+1**–**9** |
| 打开配置文件 | **Ctrl+,** | **Cmd+,** |

## AI 聊天 Markdown 导出

在活动的 AI 聊天或智能体标签页中，用 `Ctrl+Shift+P` 打开命令中心并运行：

- `Export AI Chat Markdown` —— 保存完整对话记录，包括思考过程、工具细节与用量元数据。
- `Export AI Chat Markdown Clean` —— 保存适合发布的 Markdown 文件，只含用户输入与最终的 AI 回答。

WispTerm 会弹出一个带 `.md` 文件名的保存对话框。保存后，保存路径会被复制到剪贴板。

## 用于下载与上传的 SSH 当前目录

仅当远程 shell 通过 OSC 7 报告其当前目录时，WispTerm 才能从 SSH 终端输出中下载一个相对
文件路径，并把拖入的文件上传到交互式 SSH shell 的当前目录。这与 Ghostty shell 集成所用的
终端约定相同。

如果缺少 OSC 7，辅助的 `ssh.exe` / `scp.exe` 命令会开启一个全新的 SSH 会话，通常看到的是
登录目录，而非你在交互式 shell 里 `cd` 进的目录。这种情况下 WispTerm 会显示
`SSH cwd unknown; click for setup`，而不是去猜 `~/file`。

把下面的某段加入远程 shell 的启动文件，然后开启一个新的 WispTerm SSH 会话。

Bash，加入 `~/.bashrc`：

```bash
__wispterm_report_cwd() {
  printf '\033]7;file://%s%s\a' "${HOSTNAME:-localhost}" "$PWD"
}
PROMPT_COMMAND="__wispterm_report_cwd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
```

Zsh，加入 `~/.zshrc`：

```zsh
__wispterm_report_cwd() {
  printf '\033]7;file://%s%s\a' "${HOST:-localhost}" "$PWD"
}
autoload -Uz add-zsh-hook
add-zsh-hook chpwd __wispterm_report_cwd
add-zsh-hook precmd __wispterm_report_cwd
```

Fish，加入 `~/.config/fish/config.fish`：

```fish
function __wispterm_report_cwd --on-variable PWD
    printf '\e]7;file://%s%s\a' (hostname) (string escape --style=url $PWD)
end
__wispterm_report_cwd
```

## 致谢

- 原始项目：[arya-s/phantty](https://github.com/arya-s/phantty) —— Zig + libghostty-vt
的基础与 Windows 终端核心。WispTerm 在此基础上构建，并在其上叠加了更多特性：内嵌
WebView2 浏览器面板、带 Markdown/文本/表格/图片/PDF 预览的文件浏览器、可导出 Markdown 的
AI 智能体会话、可选的远程访问客户端、Kitty 图形图片协议支持，以及可配置的背景图。
- 终端模拟：[ghostty-org/ghostty](https://github.com/ghostty-org/ghostty)，通过
`libghostty-vt`。
- 图片解码：[stb_image](https://github.com/nothings/stb)（通过 ghostty 依赖随附）。

## 许可证

MIT

## Star History

<a href="https://star-history.com/#xuzhougeng/wispterm&Date">
  <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=xuzhougeng/wispterm&type=Date" />
</a>

## 引用

Xu, Z.-G. (2026). *WispTerm* (Version 1.20.0) [Computer software]. Zenodo.
https://doi.org/10.5281/zenodo.20660542
