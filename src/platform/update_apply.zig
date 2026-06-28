//! Cross-platform dispatch for applying a downloaded update in place.
//! Only macOS implements an in-place swap today; other targets report
//! unsupported so the UI falls back to the manual "saved to Downloads" prompt.
const std = @import("std");
const builtin = @import("builtin");

const impl = switch (builtin.os.tag) {
    .macos => @import("update_apply_macos.zig"),
    .windows => @import("update_apply_windows.zig"),
    else => @import("update_apply_unsupported.zig"),
};

/// True when this platform can swap the running app in place.
pub fn isSupported() bool {
    return builtin.os.tag == .macos;
}

/// Apply the update at `dmg_path` to the bundle that `exe_path` lives in.
/// On success the platform impl has launched a detached helper and the caller
/// MUST quit so the helper can swap and relaunch. On error the caller falls
/// back to the manual prompt; the running app is left untouched.
pub fn applyUpdate(allocator: std.mem.Allocator, dmg_path: []const u8, exe_path: []const u8) !void {
    return impl.applyUpdate(allocator, dmg_path, exe_path);
}
