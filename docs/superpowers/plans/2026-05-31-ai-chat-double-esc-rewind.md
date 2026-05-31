# AI Chat 双击 ESC 对话回溯 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 AI Agent 面板里，单次 ESC 仍按现状停止生成 / 清选区，空闲时快速双击 ESC 弹出"回溯选择器"，用 ↑/↓ 选历史中某条用户消息，Enter 把对话回退到该条之前并将其文本回填输入框（不自动重发）。

**Architecture:** 全部交互逻辑放在 `Session`（`src/ai_chat.zig`）：新增几个状态字段、回溯点查询、选择器开关/移动/确认方法，并改造 `handleKeyWithWrapCols` 的按键分发；渲染层 `src/renderer/ai_chat_renderer.zig` 新增 `renderRewindPicker` 复刻现有 `renderComposerSuggestions` 弹层样式。逻辑可用结构体字面量 `Session` 做纯单元测试，渲染靠编译 + 手动验证。

**Tech Stack:** Zig；项目自带 `zig build`（debug 编译）/ `zig build test-full`（含 `ai_chat.zig` 测试的完整套件）。注意 `ai_chat.zig` 不在 `zig build test` 的快套件里，验证本计划的单测必须用 `zig build test-full`。

---

## File Structure

- `src/ai_chat.zig` — 唯一的逻辑改动点：`Session` 字段、常量 `DOUBLE_ESC_WINDOW_MS`、回溯点查询、`setInputTextLocked`、`openRewindPicker`/`closeRewindPicker`/`moveRewindSelection`/`confirmRewind`、`handleKeyWithWrapCols` 改造、全部新单测。
- `src/renderer/ai_chat_renderer.zig` — `renderRewindPicker` 新函数 + 在 `render()` 末尾按 `session.rewind_open` 接入（与 `renderComposerSuggestions` 互斥）。

约定（已核实现状）：
- `render()` 在 `src/renderer/ai_chat_renderer.zig:138` 持有 `session.mutex`，故渲染层直接读 `session.messages.items` / `session.rewind_*` 字段，**不**加锁。
- `handleKeyWithWrapCols`（`src/ai_chat.zig:1301`）**不**持锁，读 `request_inflight` 等裸字段、子方法各自加锁。新增供它调用的 `rewindPointCount()` 自行加锁。
- `Session.deinit()`（`src/ai_chat.zig:931`）结尾 `allocator.destroy(self)`，仅用于 `Session.init` 的堆对象。**测试一律用结构体字面量 `Session{ .allocator = a }`，手动释放 messages，不调用 deinit。**
- `history_on_change` 默认 null 时 `captureHistoryChangeLocked` 返回 null、`notifyHistoryChange` 为 no-op，测试无泄漏。

---

## Task 1: Session 状态字段、常量与回溯点查询

**Files:**
- Modify: `src/ai_chat.zig`（字段插入 `:734` 之后；常量近 `:39`；helper 近 `:2110` 区域；测试加到文件末尾 test 区）

- [ ] **Step 1: 加常量**

在 `src/ai_chat.zig` 现有常量区（`const INPUT_PROMPT_MAX_BYTES ...` 同段，约 `:39`）下方加：

```zig
/// 两次 ESC 间隔不超过此毫秒数时判定为"双击"，用于打开回溯选择器。
const DOUBLE_ESC_WINDOW_MS: i64 = 400;
```

- [ ] **Step 2: 加 Session 字段**

在 `src/ai_chat.zig:734`（`transcript_selection: ?TranscriptSelection = null,`）之后插入：

```zig
    // 双击 ESC 回溯选择器（rewind picker）。
    // last_esc_ms 为上一次 ESC 的时间戳（0 = 无）；空闲时若两次 ESC 间隔
    // <= DOUBLE_ESC_WINDOW_MS 则打开选择器。rewind_selected 是回溯点序号
    // （0 = 最早的用户消息，count-1 = 最近一条）。now_ms_override 为测试时钟。
    rewind_open: bool = false,
    rewind_selected: usize = 0,
    last_esc_ms: i64 = 0,
    now_ms_override: ?i64 = null,
```

- [ ] **Step 3: 加回溯点查询 helper**

在 `rollbackMessagesFromLocked`（`src/ai_chat.zig:2110`）紧邻其后插入：

```zig
    /// 对话中 role == .user 的消息条数（回溯点数量）。持锁内部版本。
    fn rewindPointCountLocked(self: *Session) usize {
        var n: usize = 0;
        for (self.messages.items) |msg| {
            if (msg.role == .user) n += 1;
        }
        return n;
    }

    /// 供 ESC handler（未持锁）调用：自行加锁返回回溯点数量。
    pub fn rewindPointCount(self: *Session) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.rewindPointCountLocked();
    }

    /// 第 n 个回溯点在 messages 中的索引（n 为 0-based 用户消息序号）。
    /// 调用方需保证 n < rewindPointCountLocked()。找不到返回 messages.items.len。
    fn rewindPointMessageIndexLocked(self: *Session, n: usize) usize {
        var seen: usize = 0;
        for (self.messages.items, 0..) |msg, i| {
            if (msg.role == .user) {
                if (seen == n) return i;
                seen += 1;
            }
        }
        return self.messages.items.len;
    }
```

- [ ] **Step 4: 写失败测试**

在 `src/ai_chat.zig` 文件末尾 test 区（紧跟 `test "ai chat escape stops in-flight request"` 之后即可）追加：

```zig
test "ai chat rewind point count and index map user messages" {
    const a = std.testing.allocator;
    var session = Session{ .allocator = a };
    defer {
        for (session.messages.items) |msg| msg.deinit(a);
        session.messages.deinit(a);
    }
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "first") });
    try session.messages.append(a, .{ .role = .assistant, .content = try a.dupe(u8, "reply-1") });
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "second") });

    try std.testing.expectEqual(@as(usize, 2), session.rewindPointCount());

    session.mutex.lock();
    defer session.mutex.unlock();
    try std.testing.expectEqual(@as(usize, 0), session.rewindPointMessageIndexLocked(0));
    try std.testing.expectEqual(@as(usize, 2), session.rewindPointMessageIndexLocked(1));
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `zig build test-full`
Expected: 编译通过、全部测试 PASS（含新测试 "ai chat rewind point count and index map user messages"）。

- [ ] **Step 6: 提交**

```bash
git add src/ai_chat.zig
git commit -m "feat(ai-chat): rewind picker state fields + rewind-point queries"
```

---

## Task 2: 输入框回填 + 选择器开关/移动/确认

**Files:**
- Modify: `src/ai_chat.zig`（helper 加在 `clearSubmittedInputLocked`（`:2101`）附近；测试加到末尾 test 区）

- [ ] **Step 1: 加 setInputTextLocked**

在 `clearSubmittedInputLocked`（`src/ai_chat.zig:2101`）紧邻其后插入。它复用既有 `insertInputBytesLocked`（`:2046`，会按 `input_buf` 容量截断、按 UTF-8 边界对齐、把 `input_cursor` 推到末尾）：

```zig
    /// 用 text 覆盖输入框内容，光标置于末尾。纯缓冲区操作、无 IO。
    fn setInputTextLocked(self: *Session, text: []const u8) void {
        self.input_len = 0;
        self.input_cursor = 0;
        self.input_scroll_row = 0;
        self.input_scroll_follow_cursor = true;
        self.suggestion_selected = 0;
        self.clearSelectionLocked();
        self.insertInputBytesLocked(text);
    }
```

- [ ] **Step 2: 加选择器开/关/移动方法**

在上一步函数之后继续插入：

```zig
    /// 打开回溯选择器：仅在空闲且至少有一个回溯点时；默认选中最近一条。
    pub fn openRewindPicker(self: *Session) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.request_inflight) return;
        const count = self.rewindPointCountLocked();
        if (count == 0) return;
        self.clearSelectionLocked();
        self.rewind_selected = count - 1;
        self.rewind_open = true;
    }

    pub fn closeRewindPicker(self: *Session) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.rewind_open = false;
    }

    /// 在 [0, count) 内移动选中项，到边界停住（不回绕）。
    pub fn moveRewindSelection(self: *Session, delta: i32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.rewind_open) return;
        const count = self.rewindPointCountLocked();
        if (count == 0) {
            self.rewind_open = false;
            return;
        }
        const cur: i64 = @intCast(@min(self.rewind_selected, count - 1));
        var next = cur + delta;
        if (next < 0) next = 0;
        const max_i: i64 = @intCast(count - 1);
        if (next > max_i) next = max_i;
        self.rewind_selected = @intCast(next);
    }
```

- [ ] **Step 3: 加 confirmRewind**

继续插入。注意顺序：先把选中用户消息的内容拷进输入框（`insertInputBytesLocked` 立即 memcpy），再 `rollbackMessagesFromLocked` 删除该消息及其后所有消息——故无需先 dupe，也无 OOM 路径：

```zig
    /// 确认回溯：把对话回退到选中用户消息之前，将其文本回填输入框，删除该
    /// 消息及其后所有消息，关闭选择器并同步历史。仅空闲时有效。
    pub fn confirmRewind(self: *Session) void {
        var history_change: ?PendingHistoryChange = null;
        self.mutex.lock();
        if (self.request_inflight or !self.rewind_open) {
            self.mutex.unlock();
            return;
        }
        const count = self.rewindPointCountLocked();
        if (count == 0) {
            self.rewind_open = false;
            self.mutex.unlock();
            return;
        }
        const sel = @min(self.rewind_selected, count - 1);
        const idx = self.rewindPointMessageIndexLocked(sel);
        if (idx >= self.messages.items.len) {
            self.rewind_open = false;
            self.mutex.unlock();
            return;
        }
        // insertInputBytesLocked 会立即把字节拷入 input_buf，随后 rollback 才释放
        // messages[idx]，两块缓冲区不重叠，安全。
        self.setInputTextLocked(self.messages.items[idx].content);
        self.rollbackMessagesFromLocked(idx);
        self.rewind_open = false;
        self.scroll_px = 1_000_000;
        history_change = self.captureHistoryChangeLocked();
        self.mutex.unlock();
        self.notifyHistoryChange(history_change);
    }
```

- [ ] **Step 4: 写失败测试**

在 test 区追加：

```zig
test "ai chat rewind open requires idle and points" {
    const a = std.testing.allocator;
    var session = Session{ .allocator = a };
    defer {
        for (session.messages.items) |msg| msg.deinit(a);
        session.messages.deinit(a);
    }

    // 无回溯点：不打开。
    session.openRewindPicker();
    try std.testing.expect(!session.rewind_open);

    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "one") });
    try session.messages.append(a, .{ .role = .assistant, .content = try a.dupe(u8, "r1") });
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "two") });

    // 生成中：不打开。
    session.request_inflight = true;
    session.openRewindPicker();
    try std.testing.expect(!session.rewind_open);

    // 空闲：打开，默认选中最近一条（序号 count-1）。
    session.request_inflight = false;
    session.openRewindPicker();
    try std.testing.expect(session.rewind_open);
    try std.testing.expectEqual(@as(usize, 1), session.rewind_selected);
}

test "ai chat rewind move selection clamps" {
    const a = std.testing.allocator;
    var session = Session{ .allocator = a };
    defer {
        for (session.messages.items) |msg| msg.deinit(a);
        session.messages.deinit(a);
    }
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "one") });
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "two") });
    session.openRewindPicker(); // selected = 1
    session.moveRewindSelection(1); // clamp at top
    try std.testing.expectEqual(@as(usize, 1), session.rewind_selected);
    session.moveRewindSelection(-1);
    try std.testing.expectEqual(@as(usize, 0), session.rewind_selected);
    session.moveRewindSelection(-1); // clamp at 0
    try std.testing.expectEqual(@as(usize, 0), session.rewind_selected);
}

test "ai chat confirm rewind truncates and restores composer" {
    const a = std.testing.allocator;
    var session = Session{ .allocator = a };
    defer {
        for (session.messages.items) |msg| msg.deinit(a);
        session.messages.deinit(a);
    }
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "first prompt") });
    try session.messages.append(a, .{ .role = .assistant, .content = try a.dupe(u8, "first reply") });
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "second prompt") });
    try session.messages.append(a, .{ .role = .assistant, .content = try a.dupe(u8, "partial") });

    session.openRewindPicker(); // selected = 1 (最近一条 "second prompt", idx 2)
    session.confirmRewind();

    // 删除 idx 2 及之后：仅剩前两条。
    try std.testing.expectEqual(@as(usize, 2), session.messages.items.len);
    try std.testing.expect(!session.rewind_open);
    try std.testing.expectEqualStrings("second prompt", session.input());

    // 回退到更早一条。
    session.openRewindPicker(); // 现在 count = 1, selected = 0 (idx 0)
    session.moveRewindSelection(-1);
    session.confirmRewind();
    try std.testing.expectEqual(@as(usize, 0), session.messages.items.len);
    try std.testing.expectEqualStrings("first prompt", session.input());
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `zig build test-full`
Expected: 全部 PASS，新增三个 rewind 测试通过。

- [ ] **Step 6: 提交**

```bash
git add src/ai_chat.zig
git commit -m "feat(ai-chat): rewind picker open/move/confirm + composer restore"
```

---

## Task 3: ESC 双击判定与选择器按键分发

**Files:**
- Modify: `src/ai_chat.zig`（`handleKeyWithWrapCols`，`:1301`-`:1350`；测试加到末尾 test 区）

- [ ] **Step 1: 选择器打开时拦截按键**

在 `handleKeyWithWrapCols` 开头、`if (self.handleApprovalKey(ev)) return;`（`src/ai_chat.zig:1302`）之后插入：

```zig
        if (self.rewind_open) {
            switch (ev.key) {
                .arrow_up => self.moveRewindSelection(-1),
                .arrow_down => self.moveRewindSelection(1),
                .enter => self.confirmRewind(),
                else => self.closeRewindPicker(), // Esc 及其它键一律关闭
            }
            return;
        }
```

- [ ] **Step 2: 改造 `.escape` 分支**

把现有（`src/ai_chat.zig:1334`-`1340`）：

```zig
            .escape => {
                if (self.request_inflight) {
                    self.stopRequest();
                } else {
                    self.clearSelection();
                }
            },
```

替换为（清选区是独立动作、**不**计入双击计时——与设计文档"有选区先清选区，之后再双击才进选择器"一致）：

```zig
            .escape => {
                const now = self.now_ms_override orelse std.time.milliTimestamp();
                if (self.request_inflight) {
                    // 生成中：仅停止，不参与双击；停止后变空闲再双击才进选择器。
                    self.stopRequest();
                    self.last_esc_ms = 0;
                } else if (self.hasSelection()) {
                    // 有选区：单次 ESC 先清选区（保持现有手感），且不计入双击计时——
                    // 清选区之后需要重新双击才进选择器。
                    self.clearSelection();
                    self.last_esc_ms = 0;
                } else if (self.last_esc_ms != 0 and
                    now - self.last_esc_ms <= DOUBLE_ESC_WINDOW_MS and
                    self.rewindPointCount() > 0)
                {
                    self.last_esc_ms = 0;
                    self.openRewindPicker();
                } else {
                    // 无选区的单次 ESC：记录时间以备双击。
                    self.last_esc_ms = now;
                }
            },
```

- [ ] **Step 3: 写失败测试**

在 test 区追加。用 `now_ms_override` 控制两次 ESC 的时间差，避免依赖真实时钟：

```zig
test "ai chat double esc opens rewind picker when idle" {
    const a = std.testing.allocator;
    var session = Session{ .allocator = a };
    defer {
        for (session.messages.items) |msg| msg.deinit(a);
        session.messages.deinit(a);
    }
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "hi") });

    session.now_ms_override = 1000;
    session.handleKey(.{ .key = input_key.Key.escape }); // 第一次：记录时间
    try std.testing.expect(!session.rewind_open);

    session.now_ms_override = 1000 + DOUBLE_ESC_WINDOW_MS; // 窗口内
    session.handleKey(.{ .key = input_key.Key.escape });
    try std.testing.expect(session.rewind_open);
}

test "ai chat slow double esc does not open rewind picker" {
    const a = std.testing.allocator;
    var session = Session{ .allocator = a };
    defer {
        for (session.messages.items) |msg| msg.deinit(a);
        session.messages.deinit(a);
    }
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "hi") });

    session.now_ms_override = 1000;
    session.handleKey(.{ .key = input_key.Key.escape });
    session.now_ms_override = 1000 + DOUBLE_ESC_WINDOW_MS + 1; // 超窗口
    session.handleKey(.{ .key = input_key.Key.escape });
    try std.testing.expect(!session.rewind_open);
}

test "ai chat esc during generation only stops and does not open picker" {
    const a = std.testing.allocator;
    var session = Session{ .allocator = a };
    defer {
        for (session.messages.items) |msg| msg.deinit(a);
        session.messages.deinit(a);
    }
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "hi") });
    session.request_inflight = true;

    session.now_ms_override = 1000;
    session.handleKey(.{ .key = input_key.Key.escape });
    session.now_ms_override = 1100;
    session.handleKey(.{ .key = input_key.Key.escape });
    try std.testing.expect(!session.rewind_open);
    try std.testing.expect(session.request_stopping);
}

// 方向约定：rewind_selected 0=最早、count-1=最近。moveRewindSelection(-1)（arrow_up）
// 朝更早、(+1)（arrow_down）朝更近。openRewindPicker 后 selected=count-1（最近）。
test "ai chat rewind picker arrow and enter via handleKey" {
    const a = std.testing.allocator;
    var session = Session{ .allocator = a };
    defer {
        for (session.messages.items) |msg| msg.deinit(a);
        session.messages.deinit(a);
    }
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "alpha") });
    try session.messages.append(a, .{ .role = .assistant, .content = try a.dupe(u8, "ra") });
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "beta") });

    session.openRewindPicker(); // selected = 1 ("beta")
    session.handleKey(.{ .key = input_key.Key.arrow_up }); // -1 -> 0 ("alpha")
    try std.testing.expectEqual(@as(usize, 0), session.rewind_selected);
    session.handleKey(.{ .key = input_key.Key.enter });
    try std.testing.expect(!session.rewind_open);
    try std.testing.expectEqual(@as(usize, 0), session.messages.items.len);
    try std.testing.expectEqualStrings("alpha", session.input());
}

test "ai chat rewind picker esc closes without change" {
    const a = std.testing.allocator;
    var session = Session{ .allocator = a };
    defer {
        for (session.messages.items) |msg| msg.deinit(a);
        session.messages.deinit(a);
    }
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "keep") });
    session.openRewindPicker();
    session.handleKey(.{ .key = input_key.Key.escape });
    try std.testing.expect(!session.rewind_open);
    try std.testing.expectEqual(@as(usize, 1), session.messages.items.len);
}

// 清选区是独立动作、不计入双击计时：ESC 清选区后需要重新双击才开选择器。
test "ai chat esc clearing selection does not prime rewind double-tap" {
    const a = std.testing.allocator;
    var session = Session{ .allocator = a };
    defer {
        for (session.messages.items) |msg| msg.deinit(a);
        session.messages.deinit(a);
    }
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "hi") });
    session.transcript_select_all = true; // 制造一个选区

    session.now_ms_override = 1000;
    session.handleKey(.{ .key = input_key.Key.escape }); // 清选区，不计时
    try std.testing.expect(!session.transcript_select_all);
    try std.testing.expectEqual(@as(i64, 0), session.last_esc_ms);

    session.now_ms_override = 1100;
    session.handleKey(.{ .key = input_key.Key.escape }); // 仅 arming，不开
    try std.testing.expect(!session.rewind_open);

    session.now_ms_override = 1200;
    session.handleKey(.{ .key = input_key.Key.escape }); // 窗口内 → 打开
    try std.testing.expect(session.rewind_open);
}

// 生成中的 ESC 不作为双击起点：停止后变空闲，需要重新双击才开选择器。
test "ai chat double esc after stop opens rewind picker" {
    const a = std.testing.allocator;
    var session = Session{ .allocator = a };
    defer {
        for (session.messages.items) |msg| msg.deinit(a);
        session.messages.deinit(a);
    }
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "hi") });

    session.request_inflight = true;
    session.now_ms_override = 1000;
    session.handleKey(.{ .key = input_key.Key.escape }); // 停止；last_esc_ms 归零
    try std.testing.expectEqual(@as(i64, 0), session.last_esc_ms);

    session.request_inflight = false; // 模拟已停止变空闲
    session.now_ms_override = 1100;
    session.handleKey(.{ .key = input_key.Key.escape }); // arming，不开
    try std.testing.expect(!session.rewind_open);
    session.now_ms_override = 1200;
    session.handleKey(.{ .key = input_key.Key.escape }); // 窗口内 → 打开
    try std.testing.expect(session.rewind_open);
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `zig build test-full`
Expected: 全部 PASS，包含 7 个新 ESC/选择器测试，且既有 "ai chat escape stops in-flight request" 仍 PASS。

- [ ] **Step 5: 提交**

```bash
git add src/ai_chat.zig
git commit -m "feat(ai-chat): double-ESC opens rewind picker; picker key dispatch"
```

---

## Task 4: 渲染回溯选择器

**Files:**
- Modify: `src/renderer/ai_chat_renderer.zig`（新函数加在 `renderComposerSuggestions`（`:1135`）附近；接入点在 `render()` 末尾 `:332`）

- [ ] **Step 1: 加 renderRewindPicker 与 firstLine**

在 `src/renderer/ai_chat_renderer.zig` 的 `renderComposerSuggestions`（`:1135`）函数之前或之后插入。复刻该函数的弹层配色/边框；行号沿用 `SUGGESTION_*` 常量（`:57`-`:61`）。`render()` 持锁，故直接读 `session.messages.items`：

```zig
const REWIND_MAX_ROWS: usize = 8;

fn firstLine(text: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    return text[0..end];
}

fn renderRewindPicker(session: *ai_chat.Session, layout: InputLayout) void {
    var total: usize = 0;
    for (session.messages.items) |msg| {
        if (msg.role == .user) total += 1;
    }
    if (total == 0) return;

    const selected = @min(session.rewind_selected, total - 1);
    const visible = @min(total, REWIND_MAX_ROWS);

    // 以"recency"（0 = 最近一条，显示在最底部、紧邻输入框）做窗口化，
    // 保证选中项可见。
    const selected_r = total - 1 - selected;
    var r_lo: usize = 0;
    if (selected_r >= visible) r_lo = selected_r - visible + 1;
    if (r_lo > total - visible) r_lo = total - visible;

    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const popup_w = @min(layout.field_w, SUGGESTION_MAX_W);
    const popup_x = layout.field_x;
    const popup_y = layout.field_y + layout.field_h + SUGGESTION_GAP;
    const row_count: f32 = @floatFromInt(visible + 1); // +1 标题行
    const popup_h = SUGGESTION_PAD_Y * 2 + SUGGESTION_ROW_H * row_count;
    const popup_bg = mixColor(bg, fg, 0.085);
    const border = mixColor(bg, accent, 0.36);

    ui_pipeline.fillQuadAlpha(popup_x, popup_y, popup_w, popup_h, popup_bg, 0.98);
    ui_pipeline.fillQuadAlpha(popup_x, popup_y + popup_h - 1, popup_w, 1, border, 0.78);
    ui_pipeline.fillQuadAlpha(popup_x, popup_y, popup_w, 1, mixColor(bg, fg, 0.20), 0.82);
    ui_pipeline.fillQuadAlpha(popup_x, popup_y, 1, popup_h, mixColor(bg, fg, 0.16), 0.72);
    ui_pipeline.fillQuadAlpha(popup_x + popup_w - 1, popup_y, 1, popup_h, mixColor(bg, fg, 0.16), 0.72);

    const top = popup_y + popup_h - SUGGESTION_PAD_Y;

    // 标题行（最顶部）。
    const title_row_y = top - @as(f32, @floatFromInt(visible + 1)) * SUGGESTION_ROW_H;
    const title_text_y = title_row_y + @round((SUGGESTION_ROW_H - font.g_titlebar_cell_height) / 2);
    _ = titlebar.renderTextLimited(
        "rewind  ^v select  Enter confirm  Esc cancel",
        popup_x + 14,
        title_text_y,
        mixColor(bg, fg, 0.55),
        popup_w - 28,
    );

    var ord: usize = 0; // 用户消息序号（0 = 最早）
    for (session.messages.items) |msg| {
        if (msg.role != .user) continue;
        const this_ord = ord;
        ord += 1;
        const r = total - 1 - this_ord; // recency：0 = 最近
        if (r < r_lo or r >= r_lo + visible) continue;
        const row = r - r_lo; // 0 = 最底部（最近）
        const row_y = top - @as(f32, @floatFromInt(row + 1)) * SUGGESTION_ROW_H;
        if (this_ord == selected) {
            ui_pipeline.fillQuadAlpha(popup_x + 4, row_y + 2, popup_w - 8, SUGGESTION_ROW_H - 4, mixColor(bg, accent, 0.18), 0.90);
            ui_pipeline.fillQuadAlpha(popup_x + 4, row_y + 2, 3, SUGGESTION_ROW_H - 4, accent, 0.82);
        }
        const text_y = row_y + @round((SUGGESTION_ROW_H - font.g_titlebar_cell_height) / 2);
        _ = titlebar.renderTextLimited(
            firstLine(msg.content),
            popup_x + 14,
            text_y,
            if (this_ord == selected) mixColor(fg, accent, 0.14) else fg,
            popup_w - 28,
        );
    }
}
```

> 标题行文案用 ASCII（`^v`、`Enter`、`Esc`）以避免字形/编码不确定性；手动验证后若字体支持可改 `↑↓`。

- [ ] **Step 2: 在 render() 接入（与建议列表互斥）**

把 `src/renderer/ai_chat_renderer.zig:332` 的：

```zig
    renderComposerSuggestions(session, layout);
```

替换为：

```zig
    if (session.rewind_open) {
        renderRewindPicker(session, layout);
    } else {
        renderComposerSuggestions(session, layout);
    }
```

- [ ] **Step 3: 编译检查**

Run: `zig build`
Expected: 编译成功，无未使用变量 / 类型错误（debug 构建产出 `zig-out/`）。

- [ ] **Step 4: 跑完整测试确认无回归**

Run: `zig build test-full`
Expected: 全部 PASS（渲染无单测，此步确认逻辑改动未回归）。

- [ ] **Step 5: 手动验证（自定义验证步骤）**

启动应用，打开 AI Agent 面板并产生几轮对话：
1. 生成中按一次 ESC → 停止（状态 "Stopped"），不弹选择器。
2. 空闲时快速双击 ESC → 弹出选择器；列表里**最近一条在最底部**、紧邻输入框，选中项有 accent 高亮。
3. ↑/↓ 移动选中（到边界停住），↑ 朝更早、↓ 朝更近。
4. Enter → 对话回退到所选条之前，该条文本回填到 "Ask Agent" 输入框，选择器关闭。
5. 打开后按 Esc 或其它键 → 关闭、对话不变。
6. 两次 ESC 间隔较慢（>400ms）→ 不弹选择器。

若第 2 步顺序观感颠倒（最近一条在顶部），把 Step 1 中 `row` 计算改成正向（`row = (visible - 1) - (r - r_lo)`）即可翻转，再重跑 `zig build`。

- [ ] **Step 6: 提交**

```bash
git add src/renderer/ai_chat_renderer.zig
git commit -m "feat(ai-chat): render double-ESC rewind picker overlay"
```

---

## Self-Review（计划作者已执行）

**Spec 覆盖：**
- 单次 ESC 现状（停止 / 清选区）→ Task 3 Step 2 保留分支。
- 双击判定（400ms 窗口、可测时钟）→ Task 1（常量+字段）、Task 3（判定逻辑+测试）。
- 生成中只停止不开选择器 → Task 3 Step 2 + "esc during generation only stops" 测试。
- 选择器状态/默认选中最近 → Task 1 字段、Task 2 openRewindPicker + 测试。
- 回溯点 = 用户消息、↑↓ 选择 → Task 1 查询 helper、Task 2 moveRewindSelection、Task 3 按键分发。
- 确认回溯：截断 + 回填输入框、不自动重发、同步历史 → Task 2 confirmRewind + 测试。
- 渲染弹层（标题行、最近在底、高亮、窗口化）→ Task 4。
- 测试清单（双击/超窗/生成中/导航/确认/取消/空对话/有选区）→ 分散在 Task 1-3。
  - "空对话双击不开" 由 Task 2 "open requires idle and points" 覆盖（openRewindPicker 对 count==0 不开），且 Task 3 ESC 分支带 `rewindPointCount() > 0` 守卫。
  - "有选区先清选区" 由 Task 3 ESC 分支 `!self.hasSelection()` 守卫覆盖（逻辑已实现；如需显式断言可在 Task 3 追加一例，非必需）。

**占位符扫描：** 无 TBD/TODO；每个代码步骤均含完整可编译代码。

**类型/命名一致性：** `rewindPointCountLocked`/`rewindPointCount`/`rewindPointMessageIndexLocked`/`setInputTextLocked`/`openRewindPicker`/`closeRewindPicker`/`moveRewindSelection`/`confirmRewind`/`renderRewindPicker`/`firstLine` 在各 Task 间引用一致；字段 `rewind_open`/`rewind_selected`/`last_esc_ms`/`now_ms_override` 与常量 `DOUBLE_ESC_WINDOW_MS`/`REWIND_MAX_ROWS` 一致。复用既有：`rollbackMessagesFromLocked`、`insertInputBytesLocked`、`clearSelectionLocked`、`captureHistoryChangeLocked`、`notifyHistoryChange`、`hasSelection`、`stopRequest`、`clearSelection`、`input_key.Key`、`PendingHistoryChange`。
