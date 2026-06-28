//! macOS in-place updater: mount the downloaded DMG, verify its signature,
//! and launch a detached shell helper that swaps the bundle once the running
//! app exits, then relaunches it. `applyUpdate` is added in a later task.
const std = @import("std");

/// Given an absolute executable path, return the enclosing `*.app` bundle path
/// (a slice of `exe_path`), or null when the executable is not inside a bundle
/// (e.g. a dev build run from zig-out/bin) — the caller then falls back to the
/// manual prompt.
pub fn resolveAppBundle(exe_path: []const u8) ?[]const u8 {
    var path = exe_path;
    while (true) {
        const base = std.fs.path.basename(path);
        if (std.mem.endsWith(u8, base, ".app")) return path;
        const parent = std.fs.path.dirname(path) orelse return null;
        if (parent.len >= path.len) return null; // reached root, no progress
        path = parent;
    }
}

/// Render the detached helper script. It waits for `pid` to exit, stages the
/// new bundle as `<dst>.new` (so a failed copy never deletes the working app),
/// swaps it into place, detaches the DMG, and relaunches. Caller owns the slice.
pub fn renderHelperScript(
    allocator: std.mem.Allocator,
    pid: i32,
    new_app: []const u8,
    dst_app: []const u8,
    mount_point: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\#!/bin/sh
        \\while kill -0 {d} 2>/dev/null; do sleep 0.2; done
        \\if ditto "{s}" "{s}.new"; then
        \\  rm -rf "{s}"
        \\  mv "{s}.new" "{s}"
        \\fi
        \\hdiutil detach "{s}" -quiet || true
        \\open "{s}"
        \\
    , .{ pid, new_app, dst_app, dst_app, dst_app, dst_app, mount_point, dst_app });
}

pub fn applyUpdate(allocator: std.mem.Allocator, dmg_path: []const u8, exe_path: []const u8) !void {
    _ = allocator;
    _ = dmg_path;
    _ = exe_path;
    return error.UpdateInstallUnsupported;
}

test "resolveAppBundle finds the .app for an executable inside a bundle" {
    const got = resolveAppBundle("/Applications/WispTerm.app/Contents/MacOS/WispTerm");
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("/Applications/WispTerm.app", got.?);
}

test "resolveAppBundle returns null for a bare binary (dev build)" {
    try std.testing.expect(resolveAppBundle("/Users/x/code/zig-out/bin/WispTerm") == null);
}

test "renderHelperScript embeds pid, swap, detach and relaunch" {
    const a = std.testing.allocator;
    const s = try renderHelperScript(a, 4321, "/Volumes/WispTerm/WispTerm.app", "/Applications/WispTerm.app", "/Volumes/WispTerm");
    defer a.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "kill -0 4321") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "ditto \"/Volumes/WispTerm/WispTerm.app\" \"/Applications/WispTerm.app.new\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "mv \"/Applications/WispTerm.app.new\" \"/Applications/WispTerm.app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "hdiutil detach \"/Volumes/WispTerm\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "open \"/Applications/WispTerm.app\"") != null);
}
