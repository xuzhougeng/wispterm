//! In-app benchmark scenarios + run scheduler (pure logic, fast-suite unit-tested).
//!
//! Each scenario is a synthetic VT payload fed to the active surface every frame
//! while the renderer is measured. `scroll-flood` reuses the CPU CLI's exact
//! payload (`TerminalStream.generatePayload`) so the two reports are comparable;
//! `unicode-heavy` stresses the glyph atlas / wide-cell path with CJK + emoji.
//!
//! The `Schedule` is the per-run state machine: warmup frames (atlas/rasterizer
//! settle) are discarded, then a fixed wall-clock window of samples is collected
//! per scenario. Kept pure (no clock, no Surface) so it unit-tests without a
//! window — the driver threads `std.time` and the surface feed through it.

const std = @import("std");
const payload = @import("payload.zig");

pub const ScenarioId = enum {
    scroll_flood,
    unicode_heavy,

    pub fn name(self: ScenarioId) []const u8 {
        return switch (self) {
            .scroll_flood => "scroll-flood",
            .unicode_heavy => "unicode-heavy",
        };
    }
};

pub const all_scenarios = [_]ScenarioId{ .scroll_flood, .unicode_heavy };

/// Per-scenario tuning. Durations are wall-clock milliseconds the caller feeds
/// from `std.time.milliTimestamp`; warmup is a frame count.
pub const ScenarioConfig = struct {
    warmup_frames: u32 = 30,
    duration_ms: u64 = 5000,
    /// Bytes of VT generated per scenario (fed each frame).
    payload_bytes: usize = 64 * 1024,
};

pub const Schedule = struct {
    cfg: ScenarioConfig,
    /// Index into `all_scenarios` of the current scenario.
    idx: usize = 0,
    /// Frames remaining in the current scenario's warmup.
    warmup_left: u32,
    /// Wall-clock ms the current scenario's measure window started, or null
    /// while still in warmup.
    measure_start_ms: ?i64 = null,
    done: bool = false,

    pub fn init(cfg: ScenarioConfig) Schedule {
        return .{ .cfg = cfg, .warmup_left = cfg.warmup_frames };
    }

    pub fn currentScenario(self: Schedule) ?ScenarioId {
        if (self.done) return null;
        return all_scenarios[self.idx];
    }

    /// Observe one frame's wall clock. Advances warmup/measure state and returns
    /// `true` when this frame falls inside the measure window (i.e. the caller
    /// should record a latency sample for it). Sample storage is owned by the
    /// driver, not the schedule — this stays a pure state machine.
    pub fn observeFrame(self: *Schedule, now_ms: i64) bool {
        if (self.done) return false;
        if (self.measure_start_ms == null) {
            if (self.warmup_left > 0) {
                self.warmup_left -= 1;
                if (self.warmup_left == 0) self.measure_start_ms = now_ms;
                return false;
            }
            // warmup_frames == 0: open the measure window on this frame.
            self.measure_start_ms = now_ms;
        }
        return true;
    }

    /// True when the current scenario's measure window has elapsed. The caller
    /// captures the just-finished scenario's samples, then calls `advance()`.
    pub fn shouldFinishScenario(self: Schedule, now_ms: i64) bool {
        const start = self.measure_start_ms orelse return false;
        return now_ms - start >= @as(i64, @intCast(self.cfg.duration_ms));
    }

    /// Move to the next scenario (or mark done).
    pub fn advance(self: *Schedule) void {
        self.idx += 1;
        if (self.idx >= all_scenarios.len) {
            self.done = true;
        } else {
            self.warmup_left = self.cfg.warmup_frames;
            self.measure_start_ms = null;
        }
    }
};

/// Generate the payload for a scenario. Caller owns the returned bytes.
/// `cols` sizes the printable line width (scroll-flood) or the cell budget
/// (unicode-heavy); both keep the per-frame feed cost bounded and comparable.
pub fn generateScenarioPayload(
    allocator: std.mem.Allocator,
    scenario: ScenarioId,
    cols: usize,
    payload_bytes: usize,
) ![]u8 {
    return switch (scenario) {
        .scroll_flood => try payload.generateScrollFlood(allocator, cols, payload_bytes),
        .unicode_heavy => try payload.generateUnicode(allocator, cols, payload_bytes),
    };
}

test "scenarios: all_scenarios lists scroll-flood and unicode-heavy" {
    try std.testing.expectEqual(@as(usize, 2), all_scenarios.len);
    try std.testing.expectEqual(ScenarioId.scroll_flood, all_scenarios[0]);
    try std.testing.expectEqual(ScenarioId.unicode_heavy, all_scenarios[1]);
    try std.testing.expectEqualStrings("scroll-flood", ScenarioId.scroll_flood.name());
    try std.testing.expectEqualStrings("unicode-heavy", ScenarioId.unicode_heavy.name());
}

test "scenarios: scroll-flood payload matches the shared generator shape" {
    const allocator = std.testing.allocator;
    const data = try generateScenarioPayload(allocator, .scroll_flood, 40, 512);
    defer allocator.free(data);
    try std.testing.expect(data.len >= 256 and data.len <= 1024);
    try std.testing.expect(std.mem.indexOf(u8, data, "\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "\x1b[3") != null);
}

test "scenarios: unicode-heavy payload contains CJK and emoji" {
    const allocator = std.testing.allocator;
    const data = try generateScenarioPayload(allocator, .unicode_heavy, 40, 1024);
    defer allocator.free(data);
    try std.testing.expect(std.mem.indexOf(u8, data, "中") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "😀") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "\x1b[3") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "\r\n") != null);
}

test "Schedule: warmup frames are discarded, then measure window opens" {
    var sch = Schedule.init(.{ .warmup_frames = 3, .duration_ms = 1000, .payload_bytes = 64 });

    try std.testing.expectEqual(@as(?ScenarioId, .scroll_flood), sch.currentScenario());
    // 3 warmup frames discarded; the 3rd opens the measure window.
    try std.testing.expect(sch.observeFrame(0) == false);
    try std.testing.expect(sch.observeFrame(0) == false);
    try std.testing.expect(sch.observeFrame(0) == false);
    try std.testing.expect(sch.measure_start_ms != null);
    // Next frame is the first measured one.
    try std.testing.expect(sch.observeFrame(10) == true);
    try std.testing.expect(!sch.shouldFinishScenario(20));
    try std.testing.expectEqual(@as(?ScenarioId, .scroll_flood), sch.currentScenario());
}

test "Schedule: advances to next scenario and finishes" {
    var sch = Schedule.init(.{ .warmup_frames = 0, .duration_ms = 100, .payload_bytes = 64 });

    // warmup_frames=0 → measure opens immediately, first frame is measured.
    try std.testing.expect(sch.observeFrame(0) == true);
    try std.testing.expect(!sch.shouldFinishScenario(0));
    // Cross the 100ms deadline → advance to unicode-heavy.
    try std.testing.expect(sch.observeFrame(101) == true);
    try std.testing.expect(sch.shouldFinishScenario(101));
    sch.advance();
    try std.testing.expectEqual(@as(?ScenarioId, .unicode_heavy), sch.currentScenario());
    try std.testing.expect(!sch.done);

    // Second scenario: open, then cross deadline → done.
    try std.testing.expect(sch.observeFrame(101) == true);
    try std.testing.expect(sch.observeFrame(300) == true);
    try std.testing.expect(sch.shouldFinishScenario(300));
    sch.advance();
    try std.testing.expect(sch.done);
    try std.testing.expectEqual(@as(?ScenarioId, null), sch.currentScenario());
}

test "Schedule: observeFrame after done is a no-op" {
    var sch = Schedule.init(.{ .warmup_frames = 0, .duration_ms = 1, .payload_bytes = 8 });
    // Drive both scenarios to completion (2 scenarios × 1ms window).
    _ = sch.observeFrame(0); // scroll-flood opens
    _ = sch.observeFrame(10); // crosses 1ms → finish
    sch.advance();
    _ = sch.observeFrame(10); // unicode-heavy opens
    _ = sch.observeFrame(20); // crosses 1ms → finish
    sch.advance();
    try std.testing.expect(sch.done);
    try std.testing.expect(sch.observeFrame(30) == false);
}
