# AI Chat 双击 ESC 对话回溯（Rewind Picker）设计

日期：2026-05-31

## 背景与动机

AI Agent 面板生成中按一次 ESC 会调用 `stopRequest()` 停止生成
（`src/ai_chat.zig:1334`）。停止后，本轮的用户消息以及流式到一半的 AI 回复 /
工具卡片仍残留在 `Session.messages` 里（`finishStoppedRequest`，
`src/ai_chat.zig:2833` 不会删除它们），导致对话历史出现"半截 / 悬空"的怪异状态。

需要一个"回溯"机制：让用户能把对话回退到之前某条用户消息发送之前的状态，并把那条
提示词放回输入框以便编辑后重发。参照 Claude Code 的"双击 ESC 回溯"体验。

## 目标

1. **单次 ESC**：保持现有行为不变。
   - 生成中 → 停止生成。
   - 空闲且有选区 → 清除选区。
2. **快速双击 ESC（空闲时）**：弹出回溯选择器（rewind picker）。
3. **选择器内**：↑/↓ 选择历史中的某条用户消息，Enter 确认回溯，Esc/其它键取消。
4. **确认回溯**：删除所选用户消息及其之后的所有消息，把该消息文本回填到输入框
   （光标置末尾），不自动重发，并同步磁盘历史。

## 非目标

- 不在生成进行中打开选择器（规避与流式写入线程的数据竞争）。
- 不做"撤销/重做"栈，不持久化回溯历史，回溯不可逆。
- 不复用 command-center 的 agent 会话 picker（那是跨会话 resume，语义不同）。
- 不改 `/resume`、审批弹窗等其它键位。

## 交互语义

ESC 处理（改造 `Session.handleKeyWithWrapCols`，`src/ai_chat.zig:1301`）：

| 场景 | 按键 | 行为 |
|---|---|---|
| 选择器已开 | ↑ / ↓ | 移动选中项（拦截，不落到光标/建议逻辑） |
| 选择器已开 | Enter | 确认回溯 |
| 选择器已开 | Esc / 其它键 | 关闭选择器，不改动对话 |
| 生成中 | 单次 ESC | `stopRequest()`（保持现有，**不**判定双击） |
| 空闲 + 有选区 | 单次 ESC | `clearSelection()`（保持现有） |
| 空闲 + 有回溯点 | 快速双击 ESC | 打开选择器 |
| 空闲 + 无回溯点 | ESC | 沿用空闲单次 ESC 行为，不打开 |

### 双击判定

- `Session` 新增 `last_esc_ms: i64 = 0`。
- ESC 到来时取 `now`，若 `last_esc_ms != 0 and (now - last_esc_ms) <=
  DOUBLE_ESC_WINDOW_MS`（`DOUBLE_ESC_WINDOW_MS = 400`），判定为双击 →
  在满足"空闲 + 有回溯点 + 选择器未开"时打开选择器，并把 `last_esc_ms` 归零（避免
  三连击误触发）。否则按单次 ESC 处理，并记录 `last_esc_ms = now`。
- **生成中 (`request_inflight`) 的 ESC 只停止，不参与双击判定**，也不更新
  `last_esc_ms`（停止后对话变空闲，用户再双击 ESC 才进入选择器）。

### 时间可测试性

- 新增仅测试用字段 `now_ms_override: ?i64 = null`。
- handler 内 `const now = self.now_ms_override orelse std.time.milliTimestamp();`。
- 测试通过设置 `now_ms_override` 模拟两次 ESC 的时间差，无需真实时钟。

## 数据模型

### 回溯点（rewind point）

回溯点 = `Session.messages` 中所有 `role == .user` 的消息，按出现顺序排列。不额外
分配存储，渲染与确认时直接遍历 `messages.items`。

提供查询辅助。从 ESC handler 调用的 `rewindPointCount()` **内部自行加锁**（与
`hasSelection()`，`src/ai_chat.zig:1391` 一致）；持锁内部使用另提供 `...Locked` 版本。

- `rewindPointCount() usize`：用户消息条数（公开、内部加锁）。
- `rewindPointMessageIndexLocked(n) usize`：第 `n` 个回溯点在 `messages` 中的索引。
- `rewindPointPreviewLocked(n) []const u8`：第 `n` 个回溯点内容（渲染层截断为单行）。

### 选择器状态（Session 新增字段）

```zig
rewind_open: bool = false,
rewind_selected: usize = 0,   // 第几个回溯点（0..count-1）
last_esc_ms: i64 = 0,
now_ms_override: ?i64 = null, // 测试用
```

默认选中**最近一条**用户消息（`rewind_selected = count - 1`），使"双击 + Enter"即
撤销上一轮（最常见路径），↑ 往更早翻。

## 关键函数

新增于 `src/ai_chat.zig`（`Session` 方法）：

- `fn openRewindPicker(self) void`：在 `!request_inflight && rewindPointCount() > 0`
  时置 `rewind_open = true`、`rewind_selected = count - 1`、清除选区。
- `fn closeRewindPicker(self) void`：置 `rewind_open = false`。
- `fn moveRewindSelection(self, delta: i32) void`：在 `[0, count)` 内移动选中项
  （到边界停住，不回绕）。
- `fn confirmRewind(self) void`：执行回溯（见下）。

### confirmRewind 逻辑（持锁）

```
锁定 mutex
if request_inflight: 解锁返回（不应发生，防御）
count = rewindPointCount(); if count == 0: closeRewindPicker(); 解锁返回
sel = min(rewind_selected, count - 1)
idx = rewindPointMessageIndex(sel)
text = dup(messages.items[idx].content)        // 先取副本，rollback 会释放原消息
setInputTextLocked(text)                         // 回填输入框，光标置末尾
rollbackMessagesFromLocked(idx)                  // 删除 idx 及其后所有消息
free(text)
rewind_open = false
scroll_px = 1_000_000                            // 滚到底
history_change = captureHistoryChangeLocked()
解锁 mutex
notifyHistoryChange(history_change)
```

辅助 `setInputTextLocked(text)`：清空 `input_buf` 后写入 `text`（截断到
`INPUT_PROMPT_MAX_BYTES`，`src/ai_chat.zig:39`），`input_cursor = input_len`，重置
输入滚动与建议状态（参照 `clearSubmittedInputLocked`，`src/ai_chat.zig:2101`）。

复用现有 `rollbackMessagesFromLocked`（`src/ai_chat.zig:2110`）删除消息。

### handleKeyWithWrapCols 改造

在 `handleApprovalKey` 之后、其它分支之前插入选择器拦截：

```zig
if (self.rewind_open) {
    switch (ev.key) {
        .arrow_up => self.moveRewindSelection(-1),
        .arrow_down => self.moveRewindSelection(1),
        .enter => self.confirmRewind(),
        else => self.closeRewindPicker(), // esc 及其它键一律关闭
    }
    return;
}
```

`.escape` 分支改为：

```zig
.escape => {
    const now = self.now_ms_override orelse std.time.milliTimestamp();
    if (self.request_inflight) {
        self.stopRequest();           // 生成中：仅停止，不参与双击
    } else if (self.last_esc_ms != 0 and now - self.last_esc_ms <= DOUBLE_ESC_WINDOW_MS
               and self.rewindPointCount() > 0 and !self.hasSelection()) {
        self.last_esc_ms = 0;
        self.openRewindPicker();
    } else {
        self.clearSelection();
        self.last_esc_ms = now;
    }
},
```

说明：双击优先级低于"清除选区"——若当前有选区，单次 ESC 先清选区（保持现有手感），
之后再双击才进选择器。

## 渲染

在 `src/renderer/ai_chat_renderer.zig` 新增 `renderRewindPicker(session, layout)`，
复刻 `renderComposerSuggestions`（`src/renderer/ai_chat_renderer.zig:1135`）的弹层
样式：

- 位置：输入框上方（同 suggestions 的 `popup_x / popup_y`）。
- 内容：逐行列出每个回溯点的单行预览（截断），选中项高亮（左侧 accent 竖条 +
  底色）。顺序按对话时间排列，**最近一条在最底部**（紧邻输入框，符合聊天流方向，
  也与 `renderComposerSuggestions` 中索引 0 在底部的绘制方向一致）。默认选中最底部
  （最新）一条。
- 顶部一行提示：`↑↓ 选择 · Enter 回退 · Esc 取消`。
- 行数较多时设上限（如最多 8 行）并对列表做窗口化滚动，保证选中项可见。

在 `render()` 主流程中：当 `session.rewind_open` 为真时绘制选择器，并与 composer
suggestions 互斥（选择器开时不画 suggestions）。

## 错误处理

- `setInputTextLocked` 的 dup 失败：回退操作中止，保留对话不变，状态置 "Out of
  memory"，关闭选择器。
- 回溯点为 0：`openRewindPicker` 不打开；`confirmRewind` 直接关闭返回。
- 防御：`confirmRewind` 在 `request_inflight` 时直接返回（正常流程不会触发，因为
  选择器仅在空闲打开）。

## 测试（`src/ai_chat.zig` 内 test 块）

1. 双击窗口内（`now_ms_override` 控制）→ `rewind_open == true`。
2. 两次 ESC 间隔超过窗口 → 不打开，沿用单次 ESC 行为。
3. 生成中 (`request_inflight = true`) 单次 ESC → `request_stopping == true`，
   `rewind_open == false`（沿用既有 "escape stops in-flight request" 测试，新增断言
   不打开选择器）。
4. 选择器开 + ↑/↓ → `rewind_selected` 正确变化且不越界。
5. 选择器开 + Enter → `messages` 截断到选中用户消息之前，输入框内容等于该消息文本，
   `rewind_open == false`。
6. 选择器开 + Esc → 关闭，`messages` 不变，输入框不变。
7. 空对话双击 → 不打开。
8. 有选区时单次 ESC → 先清选区不打开选择器。

## 涉及文件

- `src/ai_chat.zig`：Session 字段、ESC/选择器键处理、回溯点查询、`confirmRewind`、
  `setInputTextLocked`、`DOUBLE_ESC_WINDOW_MS`、测试。
- `src/renderer/ai_chat_renderer.zig`：`renderRewindPicker` 及 `render()` 接入。
