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
