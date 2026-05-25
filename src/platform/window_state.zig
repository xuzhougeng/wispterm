//! Window state persistence — save/restore window position across sessions.
//!
//! Saves the window position to a state file in the user's config directory
//! and restores it on next launch. Validates that the saved position is
//! on a visible monitor before applying.

const std = @import("std");
const platform_display = @import("display.zig");
const platform_dirs = @import("dirs.zig");

/// Saved window position state.
pub const WindowState = struct {
    x: i32,
    y: i32,
};

// Saved windowed position for restore (used by window state persistence)
pub threadlocal var g_windowed_x: c_int = 0;
pub threadlocal var g_windowed_y: c_int = 0;

/// Return the state file path in the platform config directory.
pub fn stateFilePath(allocator: std.mem.Allocator) ?[]const u8 {
    return platform_dirs.stateFilePath(allocator) catch null;
}

/// Load window state from the state file.
pub fn loadWindowState(allocator: std.mem.Allocator) ?WindowState {
    const path = stateFilePath(allocator) orelse return null;
    defer allocator.free(path);

    const data = std.fs.cwd().readFileAlloc(allocator, path, 4096) catch return null;
    defer allocator.free(data);

    var state = WindowState{ .x = 0, .y = 0 };
    var has_x = false;
    var has_y = false;

    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &[_]u8{ ' ', '\t', '\r' });
        if (trimmed.len == 0) continue;
        if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq| {
            const key = std.mem.trim(u8, trimmed[0..eq], &[_]u8{ ' ', '\t' });
            const val = std.mem.trim(u8, trimmed[eq + 1 ..], &[_]u8{ ' ', '\t' });
            if (std.mem.eql(u8, key, "window-x")) {
                state.x = std.fmt.parseInt(i32, val, 10) catch continue;
                has_x = true;
            } else if (std.mem.eql(u8, key, "window-y")) {
                state.y = std.fmt.parseInt(i32, val, 10) catch continue;
                has_y = true;
            }
        }
    }

    if (!has_x or !has_y) return null;

    // Check a point inside the restored frame, not just the saved origin.
    if (!platform_display.isPointOnAnyDisplay(state.x + 50, state.y + 50)) {
        std.debug.print("Saved window position ({}, {}) is off-screen, ignoring\n", .{ state.x, state.y });
        return null;
    }

    return state;
}

/// Save window state to the state file.
pub fn saveWindowState(allocator: std.mem.Allocator, state: WindowState) void {
    const path = stateFilePath(allocator) orelse return;
    defer allocator.free(path);

    var buf: [128]u8 = undefined;
    const content = std.fmt.bufPrint(&buf, "window-x = {d}\nwindow-y = {d}\n", .{
        state.x, state.y,
    }) catch return;

    if (std.fs.cwd().createFile(path, .{})) |file| {
        defer file.close();
        file.writeAll(content) catch {};
    } else |_| {}
}
