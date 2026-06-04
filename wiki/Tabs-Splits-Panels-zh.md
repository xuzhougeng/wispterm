# 标签、分屏与面板

*[English](Tabs-Splits-Panels) · 中文*

> 用标签和分屏组织多个终端，在面板间切换焦点，并使用 Quake 下拉模式。

> 在 macOS 上，下文的应用级快捷键用 **`Cmd`** 代替 `Ctrl`（Quake 在所有平台都保持
> `Ctrl+backquote`）。重映射方式见 [[键盘快捷键|Keyboard-Shortcuts-zh]]。

## 标签与分屏的区别

**标签**是标签栏上各自独立的会话；**分屏**把一个标签切分成多个共享该标签的终端面板。
用标签隔开不相关的工作，用分屏把相关终端并排显示。

## 创建与切换分屏

- **分屏当前面板：** `Ctrl+Shift+O`（`split_right`）。
- **在面板间移动焦点：** `Alt+←` / `Alt+→` / `Alt+↑` / `Alt+↓`。
- **循环切换焦点：** `Ctrl+Shift+[`（上一个）与 `Ctrl+Shift+]`（下一个）。
- **均分大小：** `Ctrl+Shift+Z`（`equalize_splits`）把该标签内所有分屏重置为等比。
- **最大化当前面板：** `Alt+Enter`（`toggle_maximize`）把它放大铺满整个标签，再按一次还原。

拖动分屏之间的分隔线可以调整两侧面板大小。

## 按编号聚焦面板

按 `Ctrl+1` … `Ctrl+9` 可直接跳到活动标签中的**第 N 个分屏面板**。面板按屏幕位置编号
—— 行优先，从左上到右下。如果该编号处没有面板，按键会落到终端本身，这样在没分屏时
依赖 `Ctrl+<数字>` 的程序仍能正常使用。

## 交换面板

按住 **`Alt`** 并用**左键拖动**一个面板到另一个面板上即可交换二者内容。布局拓扑保持
不变 —— 只是两个面板里的终端互换了位置。拖动时目标面板会以高亮强调色边框标示。

## 焦点跟随鼠标

在配置里设 `focus-follows-mouse = true`，焦点会跟随鼠标所在面板，无需点击。默认**关闭**。

## Quake 下拉模式

Quake 模式把 WispTerm 变成用全局热键切换的下拉终端。`toggle_quake` 绑定
（`Ctrl+backquote`，即 `` ` `` 键，注册为系统级热键）会在保留终端状态的前提下隐藏/显示
同一个窗口，并且 WispTerm 会跨重启记住 Quake 窗口的大小与位置。

Quake 模式**默认关闭**。在配置里用 `quake-mode = true`，或命令行 `--quake-mode true`
启用。

## 关闭标签与分屏

`Ctrl+Shift+W`（`close_panel_or_tab`）关闭当前面板；当它是最后一个面板时则关闭整个
标签。当面板正在运行全屏 TUI（任何切到备用屏的程序，如 `vim`、`htop`）时，WispTerm
会先弹出确认。用 `confirm-close-running-program = false` 可关闭该确认（默认开启）。

---
*另见：[[键盘快捷键|Keyboard-Shortcuts-zh]] · [[快速上手|Getting-Started-zh]]*
