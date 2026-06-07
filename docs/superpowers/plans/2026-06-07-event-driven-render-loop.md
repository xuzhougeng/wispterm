# 事件驱动主循环（阶段 1）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 WispTerm 主渲染循环从"每个 vsync 无条件全量渲染"改为"事件驱动 + 脏门控"，使空闲/失焦/后台时主线程 CPU 降到接近 0。

**Architecture:** 在主线程内（不引入渲染线程）新增：(1) 纯逻辑脏门控模块 `render_gate.zig` 判定"本帧是否需要渲染"并计算阻塞超时；(2) `NSApp postEvent` 跨线程唤醒，使 PTY/IO 线程产出数据时能唤醒阻塞的主循环；(3) 直接查询 `occlusionState`/`isKeyWindow` 做可见性/焦点分级。主循环不需渲染时阻塞在带超时的事件泵上，被事件或唤醒打断后重新评估。

**Tech Stack:** Zig + Objective-C（AppKit / Metal），comptime 选择的平台 backend。

参考 spec：[docs/superpowers/specs/2026-06-07-event-driven-render-loop-design.md](../specs/2026-06-07-event-driven-render-loop-design.md)

---

## 关键前提（已核实）

- 主循环：`src/AppWindow.zig` 的 `pub fn run`，`while (running)` 在 5672；循环末尾 5996-6001 `endFrame` + `swapBuffers`，**当前无任何 sleep / 帧节流 / 脏门控**。
- `g_force_rebuild`（`AppWindow.zig:2826-2827`，threadlocal bool，默认 true）+ `g_cells_valid`：几乎所有交互/UI 变更（input.zig 上百处、overlay 打开、focus 变化）已设 `g_force_rebuild=true`。脏门控把它当一票通过来源即可，**无需改这些站点**。
- `surface.dirty`（`Surface.zig:193`，`std.atomic.Value(bool)`，默认 true）：IO 线程标脏（`ReadThread.zig:119`、`termio/Thread.zig:172`），当前主循环不读，只有 `RendererThread.zig:116` 在 `swap(false)` 消费（但 RendererThread 不真渲染）。
- 光标闪烁：`g_cursor_blink`（threadlocal bool）、`CURSOR_BLINK_INTERVAL_MS=600`；`updateCursorBlinkForRenderer(rend)`（`AppWindow.zig:2896`）只翻转 renderer 字段、**不设任何 dirty**。失焦不停。→ blink 必须作为独立"到点该翻转"唤醒源。
- AI 流式：`ai_chat.Session.request_inflight`（`ai_chat.zig:538`）；流式时后台线程追加 token **不设脏**。→ 门控必须在 AI session `request_inflight` 时强制渲染。
- 事件泵：comptime 选 backend（`window_backend.zig:18-26`）；`Window` 是 struct；`g_window: ?*window_backend.Window`（`AppWindow.zig:503`，threadlocal）。`pumpAppEvents(timeout)` → `wispterm_macos_app_pump_events`（`bridge:1104`，`untilDate:` 已支持阻塞，windowless）。
- 跨线程唤醒：**完全不存在**（`postEvent`/`CFRunLoop`/`performSelectorOnMainThread` 全零命中）。`NSApp` 直接用全局宏，`finishLaunching` 已在 `wispterm_macos_app_ensure`（`bridge:200`）调用，`postEvent:atStart:` 可用。
- IO 线程只持有 `*Surface`，Surface 无任何 window/backend/app 引用 → 唤醒只能走**全局**通道（postEvent 是 app 级，主线程醒来后重评所有 surface）。
- occlusion/focus delegate 全缺失，但 `[state->window occlusionState]` / `isKeyWindow` / `isMiniaturized` 可随时直接查询；NSWindow 经 `handle → WispTermMacWindowState* → state->window`（模板 `wispterm_macos_window_ns_window`，`bridge:1060`）。

## 测试与构建命令（macOS）

- 纯逻辑单测（零项目依赖）：`zig test src/appwindow/render_gate.zig`
- 构建 macOS app：`zig build macos-app -Dtarget=aarch64-macos`
- 注意：默认 `zig build` 目标是 Windows；`zig build test` 在 macOS 有 pre-existing link gap。native 行为靠"构建 + 运行 + 活动监视器观察 CPU"手动验证。

## File Structure

| 文件 | 职责 | 动作 |
|---|---|---|
| `src/appwindow/render_gate.zig` | 纯逻辑：`RenderSignals`/`frameNeedsRender` + `TimeoutInputs`/`computeBlockTimeoutMs`，零项目依赖、可独立单测 | 新建 |
| `src/renderer/overlays.zig` | 新增 `anyOverlayActive(now)` 聚合查询（overlays.zig 内的所有可见态 + 时间动画 toast） | 修改 |
| `src/platform/window_macos_bridge.m` | 新增 `wispterm_macos_post_wakeup`、`wispterm_macos_window_visible`、`wispterm_macos_window_is_key` | 修改 |
| `src/platform/window_macos.zig` | extern 声明 + 模块级 `postWakeup()` | 修改 |
| `src/platform/window_backend_macos.zig` | `Window.isVisible()`；`pollEvents` 刷新真实 `focused` | 修改 |
| `src/platform/window_backend.zig` | 抽象层 `isVisible(window)`、模块级 `postWakeup()` | 修改 |
| `src/platform/window_windows.zig`、`window_unsupported.zig` | `postWakeup()` no-op stub | 修改 |
| `src/platform/window_backend_windows.zig`、`window_backend_unsupported.zig` | `Window.isVisible()` 返回 true stub | 修改 |
| `src/termio/ReadThread.zig`、`src/termio/Thread.zig` | 标 dirty 后调 `window_backend.postWakeup()` | 修改 |
| `src/RendererThread.zig` | 停用 `surface.dirty` 消费（避免与主循环互吃） | 修改 |
| `src/AppWindow.zig` | 主循环集成脏门控 + 阻塞泵 + 渲染后清 dirty + 失焦停 blink | 修改 |

---

## Task 1: 纯逻辑脏门控模块 render_gate.zig

**Files:**
- Create: `src/appwindow/render_gate.zig`

- [ ] **Step 1: 写失败测试 + 模块骨架**

创建 `src/appwindow/render_gate.zig`（先只写类型 + 空实现 + 测试，让测试先失败）：

```zig
//! 纯逻辑脏门控：判定"本帧是否需要渲染"以及空闲时阻塞多久。
//! 刻意零项目依赖（只用 std），便于 `zig test src/appwindow/render_gate.zig` 独立单测。
const std = @import("std");

/// 窗口可见性/焦点分级。
pub const Visibility = enum {
    focused, // 可见且为 key window
    unfocused_visible, // 可见但非 key
    hidden, // 被遮挡 / 最小化 / 后台不可见
};

/// 一帧是否需要渲染的所有信号（采集自主循环）。
pub const RenderSignals = struct {
    force_rebuild: bool, // g_force_rebuild（交互/UI 变更，一票通过）
    any_surface_dirty: bool, // 任一可见 surface.dirty（PTY 输出）
    cursor_blink_due: bool, // 到达光标翻转点（仅聚焦且开启闪烁）
    ai_streaming: bool, // 任一相关 AI session.request_inflight
    overlay_active: bool, // 任一 overlay/面板/时间动画活动
};

/// 空闲阻塞超时计算的输入。
pub const TimeoutInputs = struct {
    visibility: Visibility,
    cursor_blink_enabled: bool, // g_cursor_blink 且聚焦
    ms_until_next_blink: i64, // 距下次光标翻转的毫秒数
};

/// 分级超时上限（毫秒）。保证 void tick（loop/watch、异步加载）定期被驱动。
pub const CAP_FOCUSED_MS: i64 = 100;
pub const CAP_UNFOCUSED_MS: i64 = 250;
pub const CAP_HIDDEN_MS: i64 = 500;
/// 阻塞超时下限，避免过度唤醒。
pub const MIN_TIMEOUT_MS: i64 = 16;

pub fn frameNeedsRender(s: RenderSignals) bool {
    return false; // 占位：让测试先失败
}

pub fn computeBlockTimeoutMs(in: TimeoutInputs) i64 {
    return 0; // 占位：让测试先失败
}

test "frameNeedsRender: 任一信号为真即需渲染" {
    const base = RenderSignals{
        .force_rebuild = false,
        .any_surface_dirty = false,
        .cursor_blink_due = false,
        .ai_streaming = false,
        .overlay_active = false,
    };
    try std.testing.expect(!frameNeedsRender(base));

    var s = base;
    s.force_rebuild = true;
    try std.testing.expect(frameNeedsRender(s));

    s = base;
    s.any_surface_dirty = true;
    try std.testing.expect(frameNeedsRender(s));

    s = base;
    s.cursor_blink_due = true;
    try std.testing.expect(frameNeedsRender(s));

    s = base;
    s.ai_streaming = true;
    try std.testing.expect(frameNeedsRender(s));

    s = base;
    s.overlay_active = true;
    try std.testing.expect(frameNeedsRender(s));
}

test "computeBlockTimeoutMs: 分级上限" {
    try std.testing.expectEqual(@as(i64, CAP_FOCUSED_MS), computeBlockTimeoutMs(.{
        .visibility = .focused,
        .cursor_blink_enabled = false,
        .ms_until_next_blink = 999,
    }));
    try std.testing.expectEqual(@as(i64, CAP_UNFOCUSED_MS), computeBlockTimeoutMs(.{
        .visibility = .unfocused_visible,
        .cursor_blink_enabled = false,
        .ms_until_next_blink = 999,
    }));
    try std.testing.expectEqual(@as(i64, CAP_HIDDEN_MS), computeBlockTimeoutMs(.{
        .visibility = .hidden,
        .cursor_blink_enabled = false,
        .ms_until_next_blink = 999,
    }));
}

test "computeBlockTimeoutMs: 光标临近翻转时收紧，但不低于下限" {
    // 聚焦 + blink 还有 40ms 翻转 → 取 40
    try std.testing.expectEqual(@as(i64, 40), computeBlockTimeoutMs(.{
        .visibility = .focused,
        .cursor_blink_enabled = true,
        .ms_until_next_blink = 40,
    }));
    // blink 仅剩 3ms → 收到下限 16
    try std.testing.expectEqual(@as(i64, MIN_TIMEOUT_MS), computeBlockTimeoutMs(.{
        .visibility = .focused,
        .cursor_blink_enabled = true,
        .ms_until_next_blink = 3,
    }));
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `zig test src/appwindow/render_gate.zig`
Expected: FAIL（`frameNeedsRender`/`computeBlockTimeoutMs` 返回占位值，断言不通过）

- [ ] **Step 3: 实现 frameNeedsRender 与 computeBlockTimeoutMs**

替换两个占位实现：

```zig
pub fn frameNeedsRender(s: RenderSignals) bool {
    return s.force_rebuild or
        s.any_surface_dirty or
        s.cursor_blink_due or
        s.ai_streaming or
        s.overlay_active;
}

pub fn computeBlockTimeoutMs(in: TimeoutInputs) i64 {
    var t: i64 = switch (in.visibility) {
        .focused => CAP_FOCUSED_MS,
        .unfocused_visible => CAP_UNFOCUSED_MS,
        .hidden => CAP_HIDDEN_MS,
    };
    if (in.cursor_blink_enabled and in.ms_until_next_blink > 0) {
        t = @min(t, in.ms_until_next_blink);
    }
    return @max(MIN_TIMEOUT_MS, t);
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `zig test src/appwindow/render_gate.zig`
Expected: PASS（3 个 test 全通过）

- [ ] **Step 5: 提交**

```bash
git add src/appwindow/render_gate.zig
git commit -m "feat(render-loop): pure render-gate logic (frameNeedsRender + timeout)"
```

---

## Task 2: overlays.anyOverlayActive() 聚合查询

**Files:**
- Modify: `src/renderer/overlays.zig`（在文件末尾的 pub 函数区新增；紧邻已有 `anyBlockingOverlayVisible`，约 5418）

- [ ] **Step 1: 新增 anyOverlayActive**

在 `overlays.zig` 内 `anyBlockingOverlayVisible`（约 5418）之后新增。`now` 由调用方传入 `std.time.milliTimestamp()`：

```zig
/// 脏门控用：是否有任何 overlay / 面板 / 时间动画处于活动状态。
/// 与 `anyBlockingOverlayVisible`（仅模态遮挡 webview）不同 —— 这里要尽量全，
/// 漏判会导致 overlay 动画卡住，所以宁可多列。`now` = std.time.milliTimestamp()。
pub fn anyOverlayActive(now: i64) bool {
    // 打开态 overlay
    if (commandPaletteVisible()) return true;
    if (commandPaletteAgentHistoryVisible()) return true;
    if (settingsPageVisible()) return true;
    if (sessionLauncherVisible()) return true;
    if (whatsNewVisible()) return true;
    if (windowCloseConfirmVisible()) return true;
    if (restoreDefaultsConfirmVisible()) return true;
    if (transferCancelConfirmVisible()) return true;
    if (jupyter_picker.isVisible()) return true;
    if (startup_shortcuts.g_startup_shortcuts_visible) return true;
    if (browser_panel.urlBarFocused()) return true;

    // 时间动画：到期前每帧需持续渲染
    if (now < g_copy_toast_until_ms) return true;
    if (g_transfer_toast_sticky or now < g_transfer_toast_until_ms) return true;
    if (now < g_update_prompt_until_ms) return true;
    if (now < g_close_shortcut_confirm_until_ms) return true;
    if (now < g_remote_key_copied_until_ms) return true;
    if (now < resize.g_split_resize_overlay_until) return true;

    // FPS 叠层开启时每秒刷新
    if (g_debug_fps) return true;

    return false;
}
```

> 注：以上符号均为 `overlays.zig` 内既有定义（getter 见 spec 块5；`g_*_until_ms` 计时字段、`g_transfer_toast_sticky`、`g_debug_fps`、`resize.g_split_resize_overlay_until`、子模块 `jupyter_picker`/`startup_shortcuts`/`browser_panel`）。若某符号在当前作用域需经子模块前缀访问，按文件内既有引用方式补前缀；不要新增字段。`file_explorer` / `markdown_preview` 的可见性在别的模块，留到主循环 Task 7 单独 OR，不放这里。

- [ ] **Step 2: 编译验证（无独立单测，靠整体构建）**

Run: `zig build macos-app -Dtarget=aarch64-macos`
Expected: 编译通过（若报某符号未定义/需前缀，按报错补正确的模块前缀，仅限符号路径，不改语义）。

- [ ] **Step 3: 提交**

```bash
git add src/renderer/overlays.zig
git commit -m "feat(render-loop): add overlays.anyOverlayActive() for render gate"
```

---

## Task 3: 跨线程唤醒 postWakeup（native + 抽象层 + stubs）

**Files:**
- Modify: `src/platform/window_macos_bridge.m`（在 `wispterm_macos_app_pump_events` 之后，约 1124 之后新增）
- Modify: `src/platform/window_macos.zig`（extern 声明 + 模块级 `postWakeup`）
- Modify: `src/platform/window_backend.zig`（模块级 `postWakeup`）
- Modify: `src/platform/window_windows.zig`、`src/platform/window_unsupported.zig`（no-op stub）

- [ ] **Step 1: native postEvent 唤醒函数**

在 `window_macos_bridge.m` 的 `wispterm_macos_app_pump_events`（约 1104-1124）之后新增。这是 GLFW `glfwPostEmptyEvent` 同款模式，`postEvent:atStart:` 可从任意线程安全调用：

```objc
// Wake the main thread's -nextEventMatchingMask: (used by the idle render loop)
// from any thread, by posting an application-defined NSEvent. Safe off-main.
void wispterm_macos_post_wakeup(void) {
    @autoreleasepool {
        NSEvent *event = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                            location:NSMakePoint(0, 0)
                                       modifierFlags:0
                                           timestamp:0
                                        windowNumber:0
                                             context:nil
                                             subtype:0
                                               data1:0
                                               data2:0];
        if (event != nil) [NSApp postEvent:event atStart:NO];
    }
}
```

- [ ] **Step 2: Zig extern + 模块级包装**

在 `window_macos.zig` 的 extern 区（约 49-52）补声明：

```zig
extern fn wispterm_macos_post_wakeup() void;
```

在 `window_macos.zig` 适当的 pub 区新增（紧邻 `pumpAppEvents`，约 257）：

```zig
/// 从任意线程唤醒阻塞中的主线程事件泵。
pub fn postWakeup() void {
    wispterm_macos_post_wakeup();
}
```

- [ ] **Step 3: 抽象层模块级函数**

在 `window_backend.zig` 的 `pumpAppEvents`（约 255）之后新增：

```zig
/// 从任意线程唤醒阻塞中的主线程事件泵（app 级，无需 window 句柄）。
pub fn postWakeup() void {
    platform_window.postWakeup();
}
```

- [ ] **Step 4: 非 macOS stub**

在 `window_windows.zig` 与 `window_unsupported.zig` 各新增（紧邻它们的 `pumpAppEvents`，分别约 214 / 170）：

```zig
pub fn postWakeup() void {}
```

- [ ] **Step 5: 编译验证**

Run: `zig build macos-app -Dtarget=aarch64-macos`
Expected: 编译通过。

- [ ] **Step 6: 提交**

```bash
git add src/platform/window_macos_bridge.m src/platform/window_macos.zig src/platform/window_backend.zig src/platform/window_windows.zig src/platform/window_unsupported.zig
git commit -m "feat(render-loop): cross-thread main-loop wakeup via NSApp postEvent"
```

---

## Task 4: 可见性/焦点直接查询（occlusion / key window）

**Files:**
- Modify: `src/platform/window_macos_bridge.m`（新增两个查询函数，照 `wispterm_macos_window_ns_window`（1060）模板）
- Modify: `src/platform/window_backend_macos.zig`（extern + `isVisible()` + `pollEvents` 刷新 `focused`）
- Modify: `src/platform/window_backend.zig`（`isVisible(window)`）
- Modify: `src/platform/window_backend_windows.zig`、`src/platform/window_backend_unsupported.zig`（`isVisible` stub）

- [ ] **Step 1: native 查询函数**

在 `window_macos_bridge.m` 的 `wispterm_macos_window_ns_window`（1060-1064）之后新增。保守策略：取不到当作可见/聚焦（宁可多渲染）：

```objc
// True iff the window is on-screen (not occluded) and not miniaturized.
bool wispterm_macos_window_visible(void *handle) {
    WispTermMacWindowState *state = wispterm_macos_state(handle);
    if (state == NULL || state->window == NULL) return true;
    NSWindowOcclusionState occ = [state->window occlusionState];
    bool visible = (occ & NSWindowOcclusionStateVisible) != 0;
    bool miniaturized = [state->window isMiniaturized];
    return visible && !miniaturized;
}

// True iff the window is the key window (has keyboard focus).
bool wispterm_macos_window_is_key(void *handle) {
    WispTermMacWindowState *state = wispterm_macos_state(handle);
    if (state == NULL || state->window == NULL) return true;
    return [state->window isKeyWindow] ? true : false;
}
```

- [ ] **Step 2: backend_macos extern + isVisible + 刷新 focused**

在 `window_backend_macos.zig` 的 extern 区（紧邻 `wispterm_macos_window_close_requested` 等，约 119）补：

```zig
extern fn wispterm_macos_window_visible(handle: NativeHandle) bool;
extern fn wispterm_macos_window_is_key(handle: NativeHandle) bool;
```

在 `Window` 结构体的方法区新增（紧邻 `swapBuffers`，约 225）：

```zig
    pub fn isVisible(self: *Window) bool {
        return wispterm_macos_window_visible(self.hwnd);
    }
```

修改 `pollEvents`（215-223），让 `focused` 反映真实 key 状态（当前永远是默认 true）。在 `self.refreshGeometry();` 之后加一行：

```zig
    pub fn pollEvents(self: *Window) bool {
        wispterm_macos_window_poll(self.hwnd);
        self.drainMessageEvents();
        self.drainFileDropEvents();
        self.drainInputEvents();
        self.refreshGeometry();
        self.focused = wispterm_macos_window_is_key(self.hwnd);
        self.close_requested = self.close_requested or wispterm_macos_window_close_requested(self.hwnd);
        return !self.close_requested;
    }
```

- [ ] **Step 3: 抽象层 isVisible**

在 `window_backend.zig` 的 `isFocused`（约 321）之后新增：

```zig
pub fn isVisible(window: *Window) bool {
    return window.isVisible();
}
```

- [ ] **Step 4: 非 macOS stub**

在 `window_backend_windows.zig` 与 `window_backend_unsupported.zig` 的 `Window` 结构体内各新增（紧邻它们的 `swapBuffers`）：

```zig
    pub fn isVisible(self: *Window) bool {
        _ = self;
        return true;
    }
```

- [ ] **Step 5: 编译 + 手动验证焦点查询**

Run: `zig build macos-app -Dtarget=aarch64-macos`
Expected: 编译通过。
手动：运行 app，点击其它应用使其失焦 —— 现有逻辑 `AppWindow.zig:5755`（`if (window_focused != focused) g_force_rebuild=true`）现在会真正在失焦/聚焦切换时各触发一次重建（此前 `focused` 恒 true，从不触发）。确认切换焦点时界面无异常（不闪、不卡）。

- [ ] **Step 6: 提交**

```bash
git add src/platform/window_macos_bridge.m src/platform/window_backend_macos.zig src/platform/window_backend.zig src/platform/window_backend_windows.zig src/platform/window_backend_unsupported.zig
git commit -m "feat(render-loop): query window visibility/key state (occlusion, isKeyWindow)"
```

---

## Task 5: IO/PTY 线程标 dirty 后唤醒主循环

**Files:**
- Modify: `src/termio/ReadThread.zig`（119 之后）
- Modify: `src/termio/Thread.zig`（172 之后）

- [ ] **Step 1: ReadThread 标脏后唤醒**

在 `ReadThread.zig` 顶部 import 区加（若尚无）：

```zig
const window_backend = @import("../platform/window_backend.zig");
```

在 `processOutput`（109-120）末尾 `surface.dirty.store(true, .release);` 之后加一行：

```zig
    surface.dirty.store(true, .release);
    window_backend.postWakeup();
```

- [ ] **Step 2: termio/Thread 标脏后唤醒**

在 `Thread.zig` 顶部 import 区加（若尚无）：

```zig
const window_backend = @import("../platform/window_backend.zig");
```

在 `applyResize`（151-173）末尾 `surface.dirty.store(true, .release);` 之后加一行：

```zig
    surface.dirty.store(true, .release);
    window_backend.postWakeup();
```

- [ ] **Step 3: 编译 + 手动验证**

Run: `zig build macos-app -Dtarget=aarch64-macos`
Expected: 编译通过。
手动：运行 app，在终端里 `ls`、`cat` 大文件、`top`，确认输出实时刷新无延迟（此步骤本身不省 CPU，省 CPU 在 Task 7；此处只验证唤醒链通畅，输出不卡）。

- [ ] **Step 4: 提交**

```bash
git add src/termio/ReadThread.zig src/termio/Thread.zig
git commit -m "feat(render-loop): wake main loop on PTY output / resize"
```

---

## Task 6: RendererThread 停用 surface.dirty 消费

**Files:**
- Modify: `src/RendererThread.zig`（114-118）

**原因：** Task 7 让主循环以 `surface.dirty.swap(false)` 消费脏位；若 RendererThread 仍 `swap(false)`，两者互吃脏位会导致丢帧。RendererThread 当前不真渲染，停掉它对 dirty 的消费即可（保留它的光标计时存在，避免牵动其它逻辑）。

- [ ] **Step 1: 移除 dirty 消费**

把 `RendererThread.zig:114-118`：

```zig
        // Check if the surface is dirty (PTY output received)
        // If so, signal that we need a redraw
        if (self.surface.dirty.swap(false, .acq_rel)) {
            self.renderer.markDirty();
        }
```

改为（不再消费 surface.dirty，留给主循环）：

```zig
        // surface.dirty is now consumed by the main render loop (event-driven
        // render gate). RendererThread must NOT swap it here or it would steal
        // the dirty bit from the main loop. Cursor-blink timing stays above.
```

- [ ] **Step 2: 编译验证**

Run: `zig build macos-app -Dtarget=aarch64-macos`
Expected: 编译通过（若 `self.renderer` 因此变为未使用导致告警/报错，保留 `_ = self;` 或按编译器提示处理，不删字段）。

- [ ] **Step 3: 提交**

```bash
git add src/RendererThread.zig
git commit -m "refactor(render-loop): stop RendererThread consuming surface.dirty"
```

---

## Task 7: 主循环集成脏门控 + 阻塞泵 + 渲染后清 dirty

**Files:**
- Modify: `src/AppWindow.zig`（主循环 `run`：新增 import、采集信号、门控分支；渲染后清 dirty）

- [ ] **Step 1: 顶部 import render_gate**

在 `AppWindow.zig` 顶部 import 区新增：

```zig
const render_gate = @import("appwindow/render_gate.zig");
```

- [ ] **Step 2: 新增门控辅助函数**

在 `AppWindow.zig` 内（如 `markAllRenderersDirty` 附近，约 4670 之后）新增三个 helper。门控专用的 blink 计时全局变量也在此声明：

```zig
/// 门控专用：上次因光标闪烁而渲染的时间戳（驱动聚焦空闲时每 600ms 一帧）。
threadlocal var g_gate_last_blink_render: i64 = 0;

/// 任一可见 surface 是否有未消费的脏位（PTY 输出）。只 load 不清除。
fn anySurfaceDirtyLoad() bool {
    for (0..tab.g_tab_count) |ti| {
        if (tab.g_tabs[ti]) |tb| {
            var it = tb.tree.iterator();
            while (it.next()) |entry| {
                if (entry.surface.dirty.load(.acquire)) return true;
            }
        }
    }
    return false;
}

/// 渲染后清除所有 surface 的脏位。
fn clearAllSurfaceDirty() void {
    for (0..tab.g_tab_count) |ti| {
        if (tab.g_tabs[ti]) |tb| {
            var it = tb.tree.iterator();
            while (it.next()) |entry| {
                _ = entry.surface.dirty.swap(false, .acq_rel);
            }
        }
    }
}

/// 活动 tab 是否有 AI 会话正在流式输出（chat 或 copilot）。
fn aiStreamingActive() bool {
    if (activeAiChat()) |sess| {
        if (sess.request_inflight) return true;
    }
    if (tab.g_tabs[active_tab_state.g_active_tab]) |tb| {
        if (tb.copilot_session) |sess| {
            if (sess.request_inflight) return true;
        }
    }
    return false;
}
```

> 注：`activeAiChat()`、`active_tab_state.g_active_tab`、`TabState.copilot_session`、`Session.request_inflight` 均为既有 API（spec 块5/块6）。若 `copilot_session` 字段类型非 optional，按其真实类型调整解包；不要改其定义。

- [ ] **Step 3: 在主循环渲染前插入门控分支**

定位主循环里"最小化跳过"那段（`AppWindow.zig:5761-5764`）：

```zig
        if (window_backend.isMinimized(win) or fb_width <= 0 or fb_height <= 0) {
            std.Thread.sleep(16 * std.time.ns_per_ms);
            continue;
        }
```

在它**之后、`gpu.gl_init.g_draw_call_count = 0;`（5766）之前**插入门控逻辑：

```zig
        // ---- 事件驱动脏门控 ----
        const gate_now = std.time.milliTimestamp();
        const visible = window_backend.isVisible(win);
        const vis: render_gate.Visibility = if (!visible)
            .hidden
        else if (window_focused)
            .focused
        else
            .unfocused_visible;

        // 光标闪烁仅在聚焦时驱动；失焦/不可见停闪以省唤醒。
        const blink_enabled = g_cursor_blink and vis == .focused;
        const blink_due = blink_enabled and
            (gate_now - g_gate_last_blink_render >= CURSOR_BLINK_INTERVAL_MS);

        const signals = render_gate.RenderSignals{
            .force_rebuild = g_force_rebuild,
            .any_surface_dirty = anySurfaceDirtyLoad(),
            .cursor_blink_due = blink_due,
            .ai_streaming = aiStreamingActive(),
            .overlay_active = overlays.anyOverlayActive(gate_now) or
                file_explorer.isVisibleForActiveTab() or
                markdown_preview_panel.isVisibleForActiveTab(),
        };

        if (!render_gate.frameNeedsRender(signals)) {
            const ms_until_blink = if (blink_enabled)
                CURSOR_BLINK_INTERVAL_MS - (gate_now - g_gate_last_blink_render)
            else
                CURSOR_BLINK_INTERVAL_MS;
            const timeout_ms = render_gate.computeBlockTimeoutMs(.{
                .visibility = vis,
                .cursor_blink_enabled = blink_enabled,
                .ms_until_next_blink = ms_until_blink,
            });
            window_backend.pumpAppEvents(@as(f64, @floatFromInt(timeout_ms)) / 1000.0);
            continue;
        }
        if (blink_due) g_gate_last_blink_render = gate_now;
        // ---- 门控通过，正常渲染 ----
```

- [ ] **Step 4: 渲染后清 dirty**

在主循环末尾 `window_backend.swapBuffers(win);`（6000）之后、`}`（6001 循环结束）之前加：

```zig
        window_backend.swapBuffers(win);
        clearAllSurfaceDirty();
```

- [ ] **Step 5: 编译验证**

Run: `zig build macos-app -Dtarget=aarch64-macos`
Expected: 编译通过。若 `overlays`/`file_explorer`/`markdown_preview_panel`/`activeAiChat`/`active_tab_state` 等在 `run` 作用域的引用名与既有用法不一致，按文件内既有调用方式对齐（这些模块在 AppWindow.zig 已被大量使用，参照现有调用）。

- [ ] **Step 6: 手动验证（核心 — CPU 与功能）**

运行 `zig build macos-app -Dtarget=aarch64-macos`，启动 app，用活动监视器 / `top -pid <pid>` 观察主进程 CPU：

1. **聚焦空闲**（终端无输出、无 overlay）：CPU 应从 ~73% 降到个位数（光标每 600ms 一帧）。
2. **失焦**（点其它 app）：CPU 应进一步降到接近 0（光标停闪、无唤醒源）。
3. **遮挡 / 最小化**：CPU ≈ 0。
4. **终端持续输出**（`yes`、`top`、`htop`）：渲染正常实时，CPU 与输出量相称。
5. **功能回归**：光标闪烁正常；打开命令面板/设置页/文件浏览器/Markdown 预览，动画与交互正常不卡；复制触发 toast，toast 正常出现并到期消失；AI 流式回复时文字持续刷新不卡住；resize 窗口正常。

逐项确认，任一卡顿/不刷新即记录现象（很可能是某变化来源未纳入信号）并回到 Task 2 / Step 2-3 补该来源。

- [ ] **Step 7: 提交**

```bash
git add src/AppWindow.zig
git commit -m "feat(render-loop): event-driven main loop with render gate + blocking pump"
```

---

## Task 8: 失焦停光标闪烁的视觉确认与收尾

**Files:**
- 无新增改动（失焦停闪已在 Task 7 Step 3 的 `blink_enabled = ... and vis == .focused` 实现）；本任务是验收与可选回退点。

- [ ] **Step 1: 验证失焦时光标行为**

运行 app，聚焦时光标闪烁；切到其它 app 后，终端光标应停止闪烁（保持显示，不再翻转）。这与 macOS 终端习惯一致，且消除了失焦时的周期性唤醒。

- [ ] **Step 2: 最终 CPU 验收对照 spec §10**

对照 spec 验收标准逐条记录改造前/后 CPU：
- 聚焦空闲：个位数%（含 600ms blink 帧）
- 失焦/遮挡/最小化：≈ 0
- 持续输出：与输出量相称
- 输入/输出无可感延迟；所有 overlay 动画正常

- [ ] **Step 3: 提交（若有任何收尾微调）**

```bash
git add -A
git commit -m "chore(render-loop): finalize phase-1 event-driven loop"
```

---

## Self-Review（计划作者已执行）

**Spec 覆盖：**
- M1 阻塞事件泵 → Task 7 Step 3（`pumpAppEvents(timeout)`）。
- M2 跨线程唤醒 → Task 3 + Task 5。
- M3 保守脏门控 → Task 1（逻辑）+ Task 2（overlay 来源）+ Task 7（采集与集成）。
- M4 超时驱动定时 → Task 1（`computeBlockTimeoutMs`）+ Task 7 Step 3。
- M5 occlusion/focus 桥接 → Task 4（直接查询，独立函数，阶段 2 可复用）。
- M6 tick 周期保证 → Task 1 分级上限（focused 100 / unfocused 250 / hidden 500ms，均 < loop/watch 分钟级间隔）+ Task 7 覆盖分析（file explorer→overlay_active、ai_loop→ai_streaming、SSH→surface.dirty）。
- 变化来源清单 → Task 2 + Task 7 Step 3 信号采集。
- RendererThread 互吃协调 → Task 6。

**占位扫描：** 无 TBD/TODO；所有代码步骤含完整代码；手动验证步骤给出具体操作与预期。

**类型一致性：** `RenderSignals`/`TimeoutInputs`/`Visibility`/`frameNeedsRender`/`computeBlockTimeoutMs`/`anyOverlayActive`/`postWakeup`/`isVisible`/`anySurfaceDirtyLoad`/`clearAllSurfaceDirty`/`aiStreamingActive` 在定义与调用处命名一致；`CURSOR_BLINK_INTERVAL_MS` 复用 AppWindow 既有常量。

**已知实现期需对照（非阻塞）：** 各模块符号在主循环作用域的精确引用前缀、`copilot_session` 的 optional 性、`overlays.zig` 内子模块前缀 —— 均在对应步骤注明"按文件内既有用法对齐"，因这些模块在目标文件已被大量使用。
