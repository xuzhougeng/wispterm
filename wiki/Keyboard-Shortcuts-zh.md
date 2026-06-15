# 键盘快捷键

*[English](Keyboard-Shortcuts) · 中文*

> 默认的应用级快捷键、如何重映射，以及完整的动作列表。

## 快捷键工作方式

WispTerm 采用 Ghostty 的 `keybind = trigger=action` 风格。在
[[配置文件|Configuration-zh]]里追加多行 `keybind = ...`：

```text
keybind = ctrl+shift+p=toggle_command_palette
keybind = ctrl+shift+t=new_session
keybind = global:ctrl+backquote=toggle_quake
```

- **触发语法：** `[global:]modifier+key=action`。
- **`global:` 前缀**注册系统级热键（Windows 上是 Win32 hotkey，macOS 上是
  CGEventTap）—— Quake 模式用它，从而即使 WispTerm 没获得焦点也能触发。
- **修饰键：** `ctrl`、`shift`、`alt`，以及 `win`（Windows）/ `cmd`（macOS）。
- **常用键名：** 字母、数字、`f1`–`f24`、`backquote`、`comma`、`plus`、`minus`、
  `bracket_left`、`bracket_right`、`enter`、`tab`、`escape`、方向键。
- 在自定义绑定**之前**放一行 `keybind = clear` 可清空全部默认绑定。

> **macOS：** 下文默认应用级快捷键把 `Ctrl` 迁移为 `Cmd`（例如命令面板是
> `Cmd+Shift+P`）。Quake 在所有平台都保持 `Ctrl+backquote`，因为 `Cmd+backquote`
> 是 macOS 的窗口循环切换键。

## 默认快捷键

| 快捷键（Windows/Linux） | 动作 | 作用 |
| --- | --- | --- |
| `Ctrl+backquote`（全局） | `toggle_quake` | 显示/隐藏 Quake 下拉窗口 |
| `Ctrl+Shift+P` | `toggle_command_palette` | 打开命令中心 |
| `Ctrl+Shift+T` | `new_session` | 打开会话启动器（shell / Copilot / Sessions） |
| `Ctrl+Shift+N` | `new_window` | 新建窗口 |
| `Ctrl+Shift++` | `split_right` | 向右分屏当前面板 |
| `Ctrl+Shift+-` | `split_down` | 向下分屏当前面板 |
| `Ctrl+Shift+B` | `toggle_sidebar` | 切换侧边栏 |
| `Ctrl+Shift+A` | `toggle_ai_copilot` | 在终端上切换 Copilot 侧栏 |
| `Ctrl+Shift+Alt+E` | `toggle_file_explorer` | 切换文件浏览器 |
| `Ctrl+Shift+W` | `close_panel_or_tab` | 关闭当前面板/标签 |
| `Alt+Enter` | `toggle_maximize` | 最大化/还原当前面板 |
| `Ctrl++`（不按 Shift） | `font_size_increase` | 增大字号 |
| `Ctrl+-` | `font_size_decrease` | 减小字号 |
| `Ctrl+Shift+C` | `copy` | 复制选区 |
| `Ctrl+V` | `paste` | 粘贴 |
| `Ctrl+Shift+V` | `paste_image` | 粘贴剪贴板图片（到 Copilot） |
| `Alt+←/→/↑/↓` | `focus_left/right/up/down` | 在分屏面板间移动焦点 |
| `Ctrl+Shift+[` / `Ctrl+Shift+]` | `focus_previous` / `focus_next` | 循环切换面板焦点 |
| `Ctrl+Shift+Z` | `equalize_splits` | 把分屏重置为等比 |
| `Ctrl+Tab` / `Ctrl+Shift+Tab` | `next_tab` / `previous_tab` | 切换标签 |
| `Alt+1` … `Alt+9` | `switch_tab_1` … `switch_tab_9` | 跳到第 N 个标签 |
| `Ctrl+1` … `Ctrl+9` | `focus_panel_1` … `focus_panel_9` | 聚焦第 N 个分屏面板 |
| `Ctrl+,` | `open_config` | 在编辑器中打开配置文件 |

## 鼠标与手势

有些操作只能用鼠标完成，不通过 `keybind` 绑定：

- **重命名标签：** 双击标签标题，输入新名称，再按 `Enter` 确认或 `Escape` 取消。
- **交换两个面板：** 按住 `Alt` 并用左键把一个面板拖到另一个面板上即可互换内容。
- **预览/打开文件路径：** 按住 `Ctrl`（macOS 上 `Cmd`）左键点击文件路径可预览，右键点击
  可用默认应用打开（仅本地终端）。PDF 预览面板聚焦时，`PageUp` / `PageDown` 翻页。
  见 [[文件浏览器与预览|File-Explorer-zh]]。
- **调整面板大小：** 拖动两个面板之间的分隔线。
- **重排标签：** 在侧栏（`Ctrl+Shift+B`）里把标签上下拖动。
- **新建/关闭标签：** 点 `+` 按钮新建；点标签上的 `×` 或中键点击标签可关闭。

## 完整动作列表

所有可绑定的应用级动作：

`toggle_quake`、`toggle_command_palette`、`new_window`、`new_session`、
`split_right`、`split_down`、`toggle_file_explorer`、`toggle_sidebar`、`toggle_ai_copilot`、
`close_panel_or_tab`、`toggle_maximize`、`font_size_increase`、
`font_size_decrease`、`copy`、`paste`、`paste_image`、`focus_left`、
`focus_right`、`focus_up`、`focus_down`、`focus_previous`、`focus_next`、
`equalize_splits`、`next_tab`、`previous_tab`、`switch_tab_1` … `switch_tab_9`、
`focus_panel_1` … `focus_panel_9`、`open_config`。

## 重映射示例

```text
keybind = clear                              # 先清空全部默认
keybind = alt+f10=toggle_command_palette
keybind = ctrl+shift+t=new_session
keybind = global:ctrl+backquote=toggle_quake
```

## 浮层局部按键

有些按键会先被当前获得焦点的浮层处理 —— 命令中心、会话启动器、Copilot 输入框各自会在
应用级绑定生效前先吃掉自己的导航与编辑按键。这些 modal 按键无法通过 `keybind` 重映射。

---
*另见：[[配置|Configuration-zh]] · [[标签、分屏与面板|Tabs-Splits-Panels-zh]]*
