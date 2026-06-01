//! Window/UI state persistence — save/restore window geometry + onboarding flags
//! across sessions. Pure serialization/validation lives in window_state_codec.zig;
//! this module is the I/O layer (state file + display validation).

const std = @import("std");
const platform_display = @import("display.zig");
const platform_dirs = @import("dirs.zig");
const codec = @import("window_state_codec.zig");

pub const PersistedState = codec.PersistedState;

/// Saved window geometry for restore. `width`/`height` are framebuffer pixels and
/// are null when no valid size was stored.
pub const WindowState = struct {
    x: i32,
    y: i32,
    width: ?i32 = null,
    height: ?i32 = null,
};

// Last known windowed (non-maximized/fullscreen) top-left, in screen coords.
// Updated each frame while the window is windowed (see rememberWindowedPosition
// in AppWindow.zig) so the save-on-close path has a real position to persist when
// the window is closed while maximized or fullscreen.
pub threadlocal var g_windowed_x: i32 = 0;
pub threadlocal var g_windowed_y: i32 = 0;

/// Return the state file path in the platform config directory.
pub fn stateFilePath(allocator: std.mem.Allocator) ?[]const u8 {
    return platform_dirs.stateFilePath(allocator) catch null;
}

fn loadPersisted(allocator: std.mem.Allocator) codec.PersistedState {
    const path = stateFilePath(allocator) orelse return .{};
    defer allocator.free(path);
    const data = std.fs.cwd().readFileAlloc(allocator, path, 4096) catch return .{};
    defer allocator.free(data);
    return codec.parse(data);
}

fn savePersisted(allocator: std.mem.Allocator, state: codec.PersistedState) void {
    const path = stateFilePath(allocator) orelse return;
    defer allocator.free(path);
    var buf: [256]u8 = undefined;
    const content = codec.format(&buf, state) catch return;
    if (std.fs.cwd().createFile(path, .{})) |file| {
        defer file.close();
        file.writeAll(content) catch {};
    } else |_| {}
}

/// Load saved window geometry. Returns null unless a position is stored and its
/// restored frame lands on a visible monitor. Size is included only when stored
/// and non-degenerate.
pub fn loadWindowState(allocator: std.mem.Allocator) ?WindowState {
    const state = loadPersisted(allocator);
    const x = state.x orelse return null;
    const y = state.y orelse return null;

    // Check a point inside the restored frame, not just the saved origin.
    if (!platform_display.isPointOnAnyDisplay(x + 50, y + 50)) {
        std.debug.print("Saved window position ({}, {}) is off-screen, ignoring\n", .{ x, y });
        return null;
    }

    var result = WindowState{ .x = x, .y = y };
    if (state.width) |w| {
        if (state.height) |h| {
            if (codec.sizeIsValid(w, h)) {
                result.width = w;
                result.height = h;
            }
        }
    }
    return result;
}

/// Save window geometry (read-modify-write to preserve the onboarding flag).
/// `width`/`height` are framebuffer pixels; pass null to preserve the last saved
/// size (e.g. when saving while maximized/fullscreen).
pub fn saveWindowGeometry(allocator: std.mem.Allocator, x: i32, y: i32, width: ?i32, height: ?i32) void {
    const current = loadPersisted(allocator);
    savePersisted(allocator, codec.mergeGeometry(current, x, y, width, height));
}

/// Whether the first-launch AI-agent setup form has already been shown.
pub fn aiSetupPrompted(allocator: std.mem.Allocator) bool {
    return loadPersisted(allocator).ai_setup_prompted;
}

/// Record that the first-launch AI-agent setup form has been shown
/// (read-modify-write to preserve geometry). No-op if already set.
pub fn setAiSetupPrompted(allocator: std.mem.Allocator) void {
    var current = loadPersisted(allocator);
    if (current.ai_setup_prompted) return;
    current.ai_setup_prompted = true;
    savePersisted(allocator, current);
}
