# 文件浏览器手动刷新（File Explorer Manual Refresh）

- 状态：已确认，待实现
- 日期：2026-06-07
- 关联 issue：[wispterm#169](https://github.com/xuzhougeng/wispterm/issues/169)

## 背景与问题

文件浏览器（Remote Explorer / File Explorer，快捷键 `Ctrl+Shift+Alt+E`）会列出远程或本地目录的文件。上传新文件时能立即显示，但**当外部进程（如 Claude Code）在当前目录新建文件时，列表不会更新**，即使反复触发快捷键也仍是旧列表。

该问题不限于某一平台，local（macOS/Windows）、WSL、remote（SSH）三种模式都存在。

### 根因

`file_explorer.syncPanelForTerminalTarget`（`src/file_explorer.zig:301`）开头有守卫：

```zig
pub fn syncPanelForTerminalTarget(target: TerminalPanelTarget) void {
    if (terminalTargetMatchesCurrentState(target)) return;  // 目录/连接未变 → 直接返回
    ...
}
```

当目录路径 / SSH 连接没有变化时直接 `return`，**根本不重新执行目录扫描**，因此列表始终是缓存的旧内容。这是三种模式共同的 stale 根源。

此外，`Ctrl+Shift+Alt+E` 是"开/关"切换：浏览器已打开时再按一次是**关闭**，并不会刷新；关闭后再打开因目标未变又命中上面的守卫，所以也不刷新。

## 目标

提供**手动刷新**能力，三种模式（local / WSL / remote）一致可用，包含三个触发入口：

1. 文件浏览器头部新增一个**可点击的刷新按钮**（类似已有的关闭"x"按钮）。
2. 浏览器获得焦点时的**键盘快捷键**（`Ctrl/Cmd+R`，附加 `F5`）。
3. **关闭后重新打开**（`Ctrl+Shift+Alt+E` 两次）也强制刷新。

### 非目标（YAGNI）

- 不做自动文件监听 / file-watcher（明确只做手动刷新）。
- 不做"保留展开状态的增量合并刷新"。刷新采用**简单重建**：重读根目录列表，已展开的子目录会折叠。
- 不新增底部图例栏。

## 设计

### 核心组件：`file_explorer.refresh()`

新增一个三模式通用、尽量保留选中项的强制刷新函数。

行为：

1. 记录当前选中项的**路径**（而非索引）与当前滚动偏移 `g_scroll_offset`。
2. 调用现有 `file_explorer.rescan()`。`rescan()` 内部已按 `g_mode` 自动分派：
   - `local` / `wsl`：**同步**重读目录（`loadBackendEntries` → `file_backend.list`）。
   - `remote`：转 `rescanRemote()`，**异步**后台 `ssh ls`，结果在 `tickAsync` 的 `.rescan` 任务完成时回填。
   - `rescan()` 会重置 `g_entry_count=0`、`g_scroll_offset=0`、`g_selected=null`，并从根目录重建（子目录折叠）。
3. **选中/滚动恢复**：
   - 同步模式（local/wsl）：`rescan()` 返回后列表已就绪，立即在新 `g_entries` 中按记录的路径找回选中项设置 `g_selected`，并把滚动偏移 clamp 回有效范围。
   - 异步模式（remote）：把"待恢复路径 + 滚动偏移"暂存到一个 threadlocal（如 `g_refresh_keep_path` / `g_refresh_keep_path_len` / `g_refresh_keep_scroll` / `g_refresh_restore_pending`）。在 `tickAsync` 处理 `.rescan` 任务完成、列表回填之后，调用恢复逻辑并清空 pending。**不可**在 remote 下立即再次发起扫描，否则会因已有任务在跑而得到 `.blocked`（"SSH list busy"）误报。
   - 找不到对应路径时（文件已被删除/重命名）则不设选中、滚动归零，自然降级。
4. 触发一次短暂状态反馈（复用现有 `setTransferStatus`，如 "Refreshed"），让用户知道操作已生效（remote 已有异步状态提示流程可沿用）。

> 注：恢复选中/滚动的"待恢复"状态只由 `refresh()` 设置；其它调用 `rescan()` 的路径（如切 tab 同步）不设置，因此不会错误地把旧选中带到新目标。

### 触发入口

#### ① 刷新按钮（新增 UI）

照搬浏览器面板已有的刷新按钮模板（`hitTestBrowserRefreshButton` / `refreshBrowserPanel` / `overlays.zig` 的刷新图标绘制）。文件浏览器头部当前只有关闭按钮（`panelHeaderButtonRect` 的 index 0，最右），刷新按钮放在 **index 1**（关闭按钮左侧）。

- **命中测试**（`src/input.zig`）：新增 `hitTestFileExplorerRefreshButton(x, y)`，返回 `hit_test.panelHeaderSecondButton(fileExplorerHeaderLayout() orelse return false, x, y)`。`fileExplorerHeaderLayout()` 返回的 `PanelHeaderLayout` 的 `close_btn_w` / `close_margin` 由结构体默认值提供，**无需改动 layout**。
- **点击分发**（`src/input.zig` 约 3199 行的 press 分支，紧邻 `hitTestFileExplorerCloseButton`）：
  ```zig
  if (hitTestFileExplorerRefreshButton(xpos, ypos)) {
      file_explorer.refresh();
      AppWindow.g_force_rebuild = true;
      AppWindow.g_cells_valid = false;
      return;
  }
  ```
  注意顺序需在 close 命中判断之后或之前，确保两个按钮矩形不重叠（index 0 与 index 1 由 `panelHeaderButtonRect` 的 stride 自动错开）。
- **渲染**（`src/renderer/file_explorer_renderer.zig`）：
  - 新增 `headerRefreshRect(panel_x, panel_w)`，用 `hit_test.panelSecondButtonRect`（index 1）定位。
  - 新增 `renderHeaderRefreshButton(...)`，结构对照现有 `renderHeaderCloseButton`：用 `panelHeaderSecondButton` 判断 hover 并绘制 hover 背景，再用 4 个 `ui_pipeline.fillQuad` / `fillQuadAlpha` 手绘刷新图标（与 `overlays.zig` 浏览器刷新图标的画法一致）。
  - 在 `render()` 中调用 `renderHeaderRefreshButton`，与 `renderHeaderCloseButton` 并列。
  - 确保头部标题文本（"LOCAL"/"WSL"/"REMOTE"）的宽度上限排除**两个**按钮的区域，避免重叠。

#### ② 键盘快捷键

在 `handleFileExplorerKey`（`src/input.zig:2086` 的 normal navigation switch）中：

- 现有 `0x52`（'R'）分支：无修饰键 = 重命名（保持）。增加 `(ev.ctrl or ev.super) and !ev.alt and !ev.shift` → `file_explorer.refresh()` 并返回 `true`（即 `Ctrl+R` / `Cmd+R`）。
- 新增 `platform_input.key_f5` 分支 → `file_explorer.refresh()`。
- `src/platform/input_events.zig` 增加常量 `pub const key_f5: KeyCode = 0x74;`（Windows VK_F5）。F5 作为附加键；`Ctrl/Cmd+R` 走字母键码（与现有 'R'/'S' 一致，跨平台已验证可用）为主键。若某平台未投递 F5 功能键，`Ctrl/Cmd+R` 与按钮仍覆盖需求。

#### ③ 关闭重开强制刷新

给 `syncPanelForTerminalTarget` 增加 `force: bool` 参数，守卫在 `force` 时跳过：

```zig
pub fn syncPanelForTerminalTarget(target: TerminalPanelTarget, force: bool) void {
    const matches = terminalTargetMatchesCurrentState(target);
    if (matches and !force) return;
    if (!matches) applyTerminalTargetState(target);
    if (matches and force) {
        refresh();                 // 重开同一目标 → 强制刷新并保留选中
    } else {
        switch (target) {
            .remote => rescanRemote(),
            .wsl, .local => if (g_root_path_len > 0) rescan(),
        }
    }
}
```

沿调用链透传 `force`：

- `AppWindow.syncVisibleFileExplorerForActiveTab(force: bool)`
- `AppWindow.syncFileExplorerToActiveTerminalSurface(force: bool)`（内部对 remote/wsl/local 三分支调用 `syncPanelForTerminalTarget(target, force)`）

调用点（共 4 处）：

| 位置 | force | 说明 |
|------|-------|------|
| `src/input.zig:438`（`toggleFileExplorer` 打开时） | `true` | 打开/重开都强制刷新 |
| `src/AppWindow.zig:2483` | `false` | 自动同步，保持切 tab 不重复扫描 |
| `src/AppWindow.zig:2507` | `false` | 同上 |
| `src/AppWindow.zig:2905`（`syncVisibleFileExplorerForActiveTab` 内部） | 透传参数 | — |

AI tab 分支（`syncPanelForTabKind` / agent history）不受 `force` 影响，保持原样。

## 影响文件

- `src/file_explorer.zig`：新增 `refresh()`、异步恢复逻辑、`tickAsync` 中 `.rescan` 完成后的恢复 hook、`syncPanelForTerminalTarget` 的 `force` 参数与守卫调整。
- `src/input.zig`：`hitTestFileExplorerRefreshButton`、press 分发、`handleFileExplorerKey` 的 `Ctrl/Cmd+R` 与 `F5`、`toggleFileExplorer` 传 `force=true`。
- `src/renderer/file_explorer_renderer.zig`：`headerRefreshRect`、`renderHeaderRefreshButton`、标题宽度上限调整。
- `src/AppWindow.zig`：两个 sync 辅助函数的 `force` 透传，三个调用点传参。
- `src/platform/input_events.zig`：`key_f5` 常量。

## 验证

- **macOS 本地 tab**：在 cwd 下用 shell/外部程序 `touch newfile` → 点刷新按钮 / 按 `Ctrl+R`（或 `Cmd+R`）/ 关闭再开，`newfile` 出现。
- **WSL tab**：同上。
- **SSH tab**：同上，重点验证 (a) 异步刷新完成后**选中项按路径恢复**、滚动位置正确；(b) 连续刷新不出现 "SSH list busy" 误报。
- **回归**：切 tab 不应触发额外扫描（自动同步点仍 `force=false`）；重命名键 'R'（无修饰）行为不变；关闭按钮行为不变。
- **构建/测试**：`zig build test`（fast suite，macOS 可链接通过）+ `zig build macos-app -Dtarget=aarch64-macos` 构建通过。新增 hit-test 几何可参照 `src/input/hit_test.zig` 现有 `panelHeaderButton` 测试补充用例。
