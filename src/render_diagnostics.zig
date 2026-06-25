//! Opt-in rendering/window geometry diagnostics.
//!
//! Enable with either the `WISPTERM_RENDER_DIAGNOSTICS=1` env var or the
//! `wispterm-debug-render = true` config key (see `enableFromConfig`). Logs go to
//! `%APPDATA%\wispterm\render-diagnostic.log` on Windows, matching the config
//! directory convention used elsewhere in the app.

const std = @import("std");
const platform_dirs = @import("platform/dirs.zig");

const ENV_NAME = "WISPTERM_RENDER_DIAGNOSTICS";
const LOG_BASENAME = "render-diagnostic.log";

threadlocal var g_checked: bool = false;
threadlocal var g_enabled: bool = false;
threadlocal var g_file_open: bool = false;
threadlocal var g_file: std.fs.File = undefined;
threadlocal var g_start_ms: i64 = 0;

/// Process-global override flipped on by the `wispterm-debug-render` config key.
/// Unlike the threadlocal env-var cache above, this is visible to every thread
/// that logs, and is consulted before the (cached) env-var check so a config
/// opt-in works even if a thread already evaluated the env var as off.
var g_config_force = std.atomic.Value(bool).init(false);

/// Force diagnostics on from config. Call once, as early as the config is
/// available (before any window/GL exists) so startup geometry is captured.
pub fn enableFromConfig(on: bool) void {
    if (on) g_config_force.store(true, .seq_cst);
}

pub fn enabled() bool {
    if (g_config_force.load(.seq_cst)) return true;
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

pub fn log(comptime fmt: []const u8, args: anytype) void {
    if (!enabled()) return;

    const file = ensureFile() catch |err| {
        std.debug.print("[render-diag] failed to open log: {}\n", .{err});
        std.debug.print("[render-diag] " ++ fmt ++ "\n", args);
        return;
    };

    const now = std.time.milliTimestamp();
    const elapsed = if (g_start_ms == 0) 0 else now - g_start_ms;
    var write_buf: [4096]u8 = undefined;
    var writer = file.writerStreaming(&write_buf);
    writer.interface.print("[+{d}ms] ", .{elapsed}) catch return;
    writer.interface.print(fmt, args) catch return;
    writer.interface.writeAll("\n") catch return;
    writer.end() catch return;
}

pub fn close() void {
    if (!g_file_open) return;
    g_file.close();
    g_file_open = false;
}

fn ensureFile() !*std.fs.File {
    if (g_file_open) return &g_file;

    const allocator = std.heap.page_allocator;
    const dir = try platform_dirs.configDir(allocator);
    defer allocator.free(dir);
    try std.fs.cwd().makePath(dir);

    const path = try std.fs.path.join(allocator, &.{ dir, LOG_BASENAME });
    defer allocator.free(path);

    g_file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    g_file_open = true;
    g_start_ms = std.time.milliTimestamp();
    var write_buf: [1024]u8 = undefined;
    var writer = g_file.writerStreaming(&write_buf);
    writer.interface.print(
        "WispTerm render diagnostics started timestamp_ms={d} env={s}\n",
        .{ g_start_ms, ENV_NAME },
    ) catch {};
    writer.end() catch {};
    return &g_file;
}

fn parseEnabledValue(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return std.mem.eql(u8, trimmed, "1") or
        std.ascii.eqlIgnoreCase(trimmed, "true") or
        std.ascii.eqlIgnoreCase(trimmed, "yes") or
        std.ascii.eqlIgnoreCase(trimmed, "on");
}

test "render diagnostics enabled parser accepts common truthy values" {
    try std.testing.expect(parseEnabledValue("1"));
    try std.testing.expect(parseEnabledValue("true"));
    try std.testing.expect(parseEnabledValue("TRUE"));
    try std.testing.expect(parseEnabledValue("yes"));
    try std.testing.expect(parseEnabledValue("on"));
}

test "render diagnostics enabled parser rejects empty and falsey values" {
    try std.testing.expect(!parseEnabledValue(""));
    try std.testing.expect(!parseEnabledValue("0"));
    try std.testing.expect(!parseEnabledValue("false"));
    try std.testing.expect(!parseEnabledValue("off"));
    try std.testing.expect(!parseEnabledValue("anything-else"));
}

test "enableFromConfig forces diagnostics on regardless of cached env check" {
    // Simulate a thread that already evaluated the env var as off.
    g_checked = true;
    g_enabled = false;
    defer {
        g_checked = false;
        g_enabled = false;
        g_config_force.store(false, .seq_cst);
    }
    try std.testing.expect(!enabled());
    enableFromConfig(false); // no-op
    try std.testing.expect(!enabled());
    enableFromConfig(true);
    try std.testing.expect(enabled());
}
