# 配置

*[English](Configuration) · 中文*

> 配置文件在哪里、CLI 参数如何与之配合，以及完整的配置项参考。

WispTerm 使用兼容 Ghostty 的配置格式 —— 纯 `key = value` 键值对。

## 配置文件位置

主配置路径按以下顺序解析：

1. `--config <path>` 或 `--config-path <path>`
2. 可执行文件旁的 `wispterm.conf`（便携配置，仅 Windows）
3. 平台配置目录：
   - **Windows：** `%APPDATA%\wispterm\config`
   - **macOS：** `~/Library/Application Support/wispterm/config`
   - **Linux：** `$XDG_CONFIG_HOME/wispterm/config`（回退 `~/.config/wispterm/config`）

按 `open_config`（`Ctrl+,`，macOS 上 `Cmd+,`）在编辑器中打开配置，或运行
`wispterm --show-config-path` 打印解析出的路径。

## CLI 与文件

CLI 参数覆盖配置文件的值（后者优先级低、后写覆盖先写）。`config-file = extra.conf`
和 `--config-file extra.conf` 用于包含额外的配置文件（路径前加 `?` 表示可选）；它们
**不会**改变主配置路径。

## 配置示例

```text
font-family = Cascadia Code
font-style = regular
font-size = 14
cursor-style = bar
cursor-style-blink = true
theme = Poimandres
window-height = 32
window-width = 120
quake-mode = false
keybind = global:ctrl+backquote=toggle_quake
keybind = ctrl+shift+p=toggle_command_palette
scrollback-limit = 10000000
url-open-mode = embedded
custom-shader = path/to/shader.glsl
background-image = C:\Users\me\Pictures\wallpaper.png   # Windows；macOS 用 /Users/me/Pictures/wallpaper.png
background-opacity = 0.85
background-image-mode = fill
config-file = extra.conf
auto-update-check = true
focus-follows-mouse = false
remote-enabled = false
```

## 配置项参考

| 配置项 | 默认值 | 说明 |
| --- | --- | --- |
| `font-family` | *(无)* | 字体族名称（未设置时回退到内置字体） |
| `font-style` | `regular` | 字重：`thin`、`extra-light`、`light`、`regular`、`medium`、`semi-bold`、`bold`、`extra-bold`、`black` |
| `font-size` | `12` | 字号（磅） |
| `cursor-style` | `block` | 光标形状：`block`、`bar`、`underline`、`block_hollow` |
| `cursor-style-blink` | `true` | 启用光标闪烁 |
| `theme` | *(无)* | 主题名或绝对路径（内置 453 款 Ghostty 主题） |
| `custom-shader` | *(无)* | GLSL 后处理着色器路径 |
| `background-image` | *(无)* | 渲染在终端背后的图片路径（PNG/JPG/BMP/GIF/TGA） |
| `background-opacity` | `1.0` | 主题色调覆盖在壁纸上的不透明度（0.0 = 只见图片，1.0 = 图片被遮住） |
| `background-image-mode` | `fill` | 图片缩放：`fill`、`fit`、`center`、`tile` |
| `window-height` | `0`（自动） | 初始高度（单元格数，最小 4，0 = 自动 80×24） |
| `window-width` | `0`（自动） | 初始宽度（单元格数，最小 10，0 = 自动 80×24） |
| `quake-mode` | `false` | 以 Quake 下拉终端方式启动；`toggle_quake` 在保留状态的前提下隐藏/显示它 |
| `keybind` | 默认值 | 配置应用级快捷键（可重复）。语法 `[global:]modifier+key=action`；`keybind = clear` 清空全部默认 |
| `scrollback-limit` | `10000000` | 回滚缓冲上限（字节） |
| `focus-follows-mouse` | `false` | 焦点跟随鼠标所在面板，无需点击 |
| `url-open-mode` | `embedded` | 网址在哪打开：`embedded` 在可用时使用右侧浏览器面板（仅 Windows）；`system-browser` 始终用系统默认浏览器。两种方式下 SSH loopback 网址都会保持本地端口转发存活 |
| `restore-tabs-on-startup` | `false` | 关闭时持久化标签/分屏布局（`session.json`），下次启动重建。SSH 密码永不持久化，重连会再次提示。`--cwd` 覆盖会跳过恢复 |
| `auto-update-check` | `true` | 启动后检查 GitHub Releases，有新版时提示 |
| `config-file` | *(无)* | 包含另一个配置文件（前缀 `?` 表示可选） |
| `remote-enabled` | `false` | 为本实例启动共享出站 RemoteClient —— 见 [[远程访问|Remote-Access-zh]] |
| `remote-server-url` | *(无)* | Cloudflare relay 地址，例如 `https://remote.example.com` |
| `remote-server-fingerprint` | *(无)* | 用于服务端身份固定的预期 relay 指纹 |
| `remote-device-name` | *(无)* | 随 WispTerm 配对发送的友好设备名 |
| `remote-session-key` | *(无)* | 固定的远程会话密钥基；之后并发的实例使用 `_1`、`_2`… |
| `ssh-legacy-algorithms` | `false` | 为老旧 SSH 服务追加兼容选项（ssh-rsa、旧 KEX、CBC）—— 见 [[SSH 与远程开发|SSH-Remote-Development-zh]] |
| `copy-on-select` | `false` | 自动复制终端选区 —— 见 [[AI 副驾与智能体|AI-Copilot-zh]] |
| `right-click-action` | *(无)* | `paste`，或 `copy-or-paste`（有选区时复制，否则粘贴） |
| `confirm-close-running-program` | `true` | 关闭正在运行全屏 TUI 的面板/标签前先确认 |

## 热重载

许多改动无需重启即可生效：保存配置（或用 `Ctrl+,` 热重载），WispTerm 会重新读取。
清空某个值（如 `background-image`）即可移除其效果。

---
*另见：[[主题与外观|Themes-Appearance-zh]] · [[键盘快捷键|Keyboard-Shortcuts-zh]] · [[远程访问|Remote-Access-zh]]*
