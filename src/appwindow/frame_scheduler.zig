//! 纯逻辑光标闪烁调度：把主循环里「这一帧光标是否到翻转点」「距下次翻转还有多久」
//! 这段无副作用的时间算术抽出来，作为 render_gate 之外的一个独立纯决策。
//!
//! render_gate 负责"任一信号为真即渲染"和"空闲阻塞超时上限"；这里只回答光标定时器
//! 这一个子问题——blink 是否启用、本帧是否到翻转点、以及喂给 render_gate
//! computeBlockTimeoutMs 的 ms_until_next_blink。两者组合而非重复。
//!
//! 刻意零项目依赖（只用 std），且不 `@import` AppWindow.zig，便于
//! `zig test src/appwindow/frame_scheduler.zig` 独立单测，并满足分层守卫。
const std = @import("std");

/// 光标定时器决策的全部输入（采集自主循环）。
pub const BlinkInputs = struct {
    cursor_blink_enabled: bool, // g_cursor_blink 配置项
    focused: bool, // 本帧窗口可见且为聚焦态（vis == .focused）
    now_ms: i64, // 本帧时间戳（std.time.milliTimestamp）
    last_blink_render_ms: i64, // 上次因 blink 渲染的时间戳（g_gate_last_blink_render）
    interval_ms: i64, // 翻转周期（CURSOR_BLINK_INTERVAL_MS）
};

/// 光标定时器决策结果。
pub const BlinkDecision = struct {
    /// blink 是否启用：配置开启且当前聚焦。决定 due/ms_until 的语义分支。
    enabled: bool,
    /// 本帧是否到达翻转点——需要为光标翻转再渲染一帧。
    due: bool,
    /// 距下次翻转的毫秒数；喂给 render_gate.computeBlockTimeoutMs 收紧空闲超时。
    /// 未启用时退化为整个周期（与历史行为一致）。
    ms_until_next: i64,
};

/// 纯函数：从显式输入推导光标闪烁决策。无平台/事件循环调用、无全局读写。
///
/// 与抽取前主循环逐字等价：
///   enabled       = cursor_blink_enabled and focused
///   due           = enabled and (now - last >= interval)
///   ms_until_next = if (enabled) interval - (now - last) else interval
pub fn decideBlink(in: BlinkInputs) BlinkDecision {
    const enabled = in.cursor_blink_enabled and in.focused;
    const elapsed = in.now_ms - in.last_blink_render_ms;
    const due = enabled and (elapsed >= in.interval_ms);
    const ms_until_next = if (enabled) in.interval_ms - elapsed else in.interval_ms;
    return .{
        .enabled = enabled,
        .due = due,
        .ms_until_next = ms_until_next,
    };
}

const INTERVAL: i64 = 600; // 与 AppWindow CURSOR_BLINK_INTERVAL_MS 对齐，仅供测试

test "decideBlink: 配置关闭时永不启用，ms_until 退化为整周期" {
    const d = decideBlink(.{
        .cursor_blink_enabled = false,
        .focused = true,
        .now_ms = 10_000,
        .last_blink_render_ms = 0,
        .interval_ms = INTERVAL,
    });
    try std.testing.expect(!d.enabled);
    try std.testing.expect(!d.due);
    // 即便已远超一个周期，关闭时也只回整周期（不暴露已逝时间）
    try std.testing.expectEqual(INTERVAL, d.ms_until_next);
}

test "decideBlink: 非聚焦时不启用" {
    const d = decideBlink(.{
        .cursor_blink_enabled = true,
        .focused = false,
        .now_ms = 10_000,
        .last_blink_render_ms = 0,
        .interval_ms = INTERVAL,
    });
    try std.testing.expect(!d.enabled);
    try std.testing.expect(!d.due);
    try std.testing.expectEqual(INTERVAL, d.ms_until_next);
}

test "decideBlink: 聚焦且到达周期 → due，ms_until 为非正（已过点）" {
    // last=0, now=600, interval=600 → elapsed=600 >= 600 → due
    const d = decideBlink(.{
        .cursor_blink_enabled = true,
        .focused = true,
        .now_ms = 600,
        .last_blink_render_ms = 0,
        .interval_ms = INTERVAL,
    });
    try std.testing.expect(d.enabled);
    try std.testing.expect(d.due);
    // 600 - 600 = 0（与抽取前算术一致；render_gate 的 MIN 下限在那边夹）
    try std.testing.expectEqual(@as(i64, 0), d.ms_until_next);
}

test "decideBlink: 聚焦但未到周期 → 不 due，ms_until 为剩余时间" {
    // last=0, now=560, interval=600 → elapsed=560 < 600 → 还差 40
    const d = decideBlink(.{
        .cursor_blink_enabled = true,
        .focused = true,
        .now_ms = 560,
        .last_blink_render_ms = 0,
        .interval_ms = INTERVAL,
    });
    try std.testing.expect(d.enabled);
    try std.testing.expect(!d.due);
    try std.testing.expectEqual(@as(i64, 40), d.ms_until_next);
}

test "decideBlink: 边界——恰好等于一个周期算 due（>=）" {
    const d = decideBlink(.{
        .cursor_blink_enabled = true,
        .focused = true,
        .now_ms = 1_200,
        .last_blink_render_ms = 600,
        .interval_ms = INTERVAL,
    });
    try std.testing.expect(d.due);
    try std.testing.expectEqual(@as(i64, 0), d.ms_until_next);
}
