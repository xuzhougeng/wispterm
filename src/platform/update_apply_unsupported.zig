//! Stub for platforms with no in-place updater. Report unsupported so the
//! UI keeps today's manual download behavior.
const std = @import("std");

pub fn applyUpdate(allocator: std.mem.Allocator, dmg_path: []const u8, exe_path: []const u8) !void {
    _ = allocator;
    _ = dmg_path;
    _ = exe_path;
    return error.UpdateInstallUnsupported;
}
