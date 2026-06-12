//! 纯逻辑节流器：限制 agent 检测（`agent_detector.detect`，对最近输出做几十个
//! 子串扫描）的执行频率。PTY 洪峰输出时 ReadThread 每个数据块都跑一次检测会在持有
//! render 锁的情况下烧掉大量 CPU；这里把它限到每 interval 至多一次（leading edge），
//! 被跳过的块置 pending，由 UI 线程在主循环里调 `flush` 补一次 trailing 检测，
//! 保证输出停止后检测结果仍会收敛（如 Claude Code 审批菜单作为最后一块输出到达）。
//!
//! 线程模型：`noteOutput`/`flush` 都必须在持有 surface.render_state.mutex 时调用；
//! `pendingPeek` 是无锁快速路径（atomic），供 UI 线程决定是否值得拿锁。
//! 刻意零项目依赖（只用 std），便于 `zig test src/agent_detect_throttle.zig` 独立单测。
const std = @import("std");

pub const Throttle = struct {
    /// 两次检测之间的最小间隔。
    pub const interval_ms: i64 = 100;

    /// 上次实际执行检测的时间戳（ms）。0 表示从未执行过。
    last_ms: i64 = 0,
    /// 有输出块被跳过、检测结果已过期，等待 flush 补扫。
    pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// 新输出到达。返回 true 表示现在就该执行检测（调用方随后执行并视为已检测）。
    /// 返回 false 表示本块被节流，已置 pending。
    pub fn noteOutput(self: *Throttle, now_ms: i64) bool {
        if (now_ms - self.last_ms >= interval_ms or self.last_ms == 0) {
            self.last_ms = now_ms;
            self.pending.store(false, .release);
            return true;
        }
        self.pending.store(true, .release);
        return false;
    }

    /// UI 线程的补扫机会。仅当存在被跳过的检测且间隔已到时返回 true
    /// （调用方随后执行检测）。
    pub fn flush(self: *Throttle, now_ms: i64) bool {
        if (!self.pending.load(.acquire)) return false;
        if (now_ms - self.last_ms < interval_ms) return false;
        self.last_ms = now_ms;
        self.pending.store(false, .release);
        return true;
    }

    /// 无锁查看是否有待补扫的检测（UI 线程快速路径，避免无谓拿锁）。
    pub fn pendingPeek(self: *const Throttle) bool {
        return self.pending.load(.acquire);
    }
};

test "noteOutput: 首块立即检测" {
    var t: Throttle = .{};
    try std.testing.expect(t.noteOutput(5));
    try std.testing.expect(!t.pendingPeek());
}

test "noteOutput: 间隔内的后续块被节流并置 pending" {
    var t: Throttle = .{};
    try std.testing.expect(t.noteOutput(1000));
    try std.testing.expect(!t.noteOutput(1000 + Throttle.interval_ms - 1));
    try std.testing.expect(t.pendingPeek());
}

test "noteOutput: 间隔到达后再次立即检测并清除 pending" {
    var t: Throttle = .{};
    _ = t.noteOutput(1000);
    _ = t.noteOutput(1050);
    try std.testing.expect(t.pendingPeek());
    try std.testing.expect(t.noteOutput(1000 + Throttle.interval_ms));
    try std.testing.expect(!t.pendingPeek());
}

test "flush: 无 pending 时不补扫" {
    var t: Throttle = .{};
    _ = t.noteOutput(1000);
    try std.testing.expect(!t.flush(1000 + Throttle.interval_ms * 2));
}

test "flush: pending 且间隔未到时等待" {
    var t: Throttle = .{};
    _ = t.noteOutput(1000);
    _ = t.noteOutput(1050);
    try std.testing.expect(!t.flush(1099));
    try std.testing.expect(t.pendingPeek());
}

test "flush: pending 且间隔已到时补扫一次后清除" {
    var t: Throttle = .{};
    _ = t.noteOutput(1000);
    _ = t.noteOutput(1050);
    try std.testing.expect(t.flush(1000 + Throttle.interval_ms));
    try std.testing.expect(!t.pendingPeek());
    // 再 flush 不重复执行
    try std.testing.expect(!t.flush(1000 + Throttle.interval_ms * 2));
}
