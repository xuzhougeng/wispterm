//! Lightweight opt-in UI performance timing helpers.

const std = @import("std");

const ENV_NAME = "PHANTTY_UI_PERF";

threadlocal var g_checked: bool = false;
threadlocal var g_enabled: bool = false;

pub const Span = struct {
    label: []const u8,
    start_ns: i128 = 0,
    active: bool = false,

    pub fn end(self: Span) void {
        if (!self.active) return;
        const elapsed_ns = std.time.nanoTimestamp() - self.start_ns;
        const elapsed_us: u64 = if (elapsed_ns > 0) @intCast(@divTrunc(elapsed_ns, 1000)) else 0;
        std.debug.print("[ui-perf] {s}: {d}us\n", .{ self.label, elapsed_us });
    }
};

pub fn begin(label: []const u8) Span {
    if (!enabled()) return .{ .label = label };
    return .{
        .label = label,
        .start_ns = std.time.nanoTimestamp(),
        .active = true,
    };
}

pub fn enabled() bool {
    if (g_checked) return g_enabled;
    g_checked = true;

    const value = std.process.getEnvVarOwned(std.heap.page_allocator, ENV_NAME) catch {
        g_enabled = false;
        return g_enabled;
    };
    defer std.heap.page_allocator.free(value);

    g_enabled = parseEnabledValue(value);
    return g_enabled;
}

fn parseEnabledValue(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return std.mem.eql(u8, trimmed, "1") or
        std.ascii.eqlIgnoreCase(trimmed, "true") or
        std.ascii.eqlIgnoreCase(trimmed, "yes") or
        std.ascii.eqlIgnoreCase(trimmed, "on");
}

test "ui perf enabled parser accepts common truthy values" {
    try std.testing.expect(parseEnabledValue("1"));
    try std.testing.expect(parseEnabledValue("true"));
    try std.testing.expect(parseEnabledValue("TRUE"));
    try std.testing.expect(parseEnabledValue("yes"));
    try std.testing.expect(parseEnabledValue("on"));
}

test "ui perf enabled parser rejects empty and falsey values" {
    try std.testing.expect(!parseEnabledValue(""));
    try std.testing.expect(!parseEnabledValue("0"));
    try std.testing.expect(!parseEnabledValue("false"));
    try std.testing.expect(!parseEnabledValue("off"));
    try std.testing.expect(!parseEnabledValue("anything-else"));
}
