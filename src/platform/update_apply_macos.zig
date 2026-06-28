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

/// Mount the DMG, verify the new app's signature, stage a detached helper, and
/// launch it. On success the helper is running and the caller MUST quit. Any
/// failure before launch detaches the DMG (if mounted) and returns an error;
/// the running app is left untouched.
pub fn applyUpdate(allocator: std.mem.Allocator, dmg_path: []const u8, exe_path: []const u8) !void {
    const bundle = resolveAppBundle(exe_path) orelse return error.NotInAppBundle;

    const mount_point = try attachDmg(allocator, dmg_path);
    defer allocator.free(mount_point);
    errdefer detachQuiet(allocator, mount_point);

    const new_app = try std.fs.path.join(allocator, &.{ mount_point, "WispTerm.app" });
    defer allocator.free(new_app);
    std.fs.accessAbsolute(new_app, .{}) catch return error.AppNotFoundInDmg;

    try verifyCodesign(allocator, new_app);

    const script_path = try writeHelperScript(allocator, new_app, bundle, mount_point);
    defer allocator.free(script_path);

    // Helper now owns the mount point (it detaches after the swap), so do NOT
    // run the errdefer detach past this point.
    try launchHelper(allocator, script_path);
}

/// Run `hdiutil attach` and return the mount point (caller frees).
/// ponytail: parse the "/Volumes/..." token from text output instead of
/// -plist; our volume name ("WispTerm") has no spaces or newlines.
fn attachDmg(allocator: std.mem.Allocator, dmg_path: []const u8) ![]u8 {
    const res = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "/usr/bin/hdiutil", "attach", "-nobrowse", "-readonly", dmg_path },
        .max_output_bytes = 64 * 1024,
    });
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);
    if (res.term != .Exited or res.term.Exited != 0) return error.DmgMountFailed;

    const idx = std.mem.indexOf(u8, res.stdout, "/Volumes/") orelse return error.DmgMountFailed;
    var end = idx;
    while (end < res.stdout.len and res.stdout[end] != '\n' and res.stdout[end] != '\r') end += 1;
    const mp = std.mem.trimRight(u8, res.stdout[idx..end], " \t");
    return allocator.dupe(u8, mp);
}

fn detachQuiet(allocator: std.mem.Allocator, mount_point: []const u8) void {
    const res = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "/usr/bin/hdiutil", "detach", mount_point, "-quiet" },
        .max_output_bytes = 4 * 1024,
    }) catch return;
    allocator.free(res.stdout);
    allocator.free(res.stderr);
}

/// Verify the downloaded app's signature (download integrity). Mandatory.
fn verifyCodesign(allocator: std.mem.Allocator, app_path: []const u8) !void {
    const res = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "/usr/bin/codesign", "--verify", "--deep", "--strict", app_path },
        .max_output_bytes = 16 * 1024,
    });
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);
    if (res.term != .Exited or res.term.Exited != 0) return error.CodesignVerifyFailed;
}

/// Render the helper to a temp file and return its path (caller frees).
fn writeHelperScript(allocator: std.mem.Allocator, new_app: []const u8, dst_app: []const u8, mount_point: []const u8) ![]u8 {
    const pid = std.c.getpid();
    const script = try renderHelperScript(allocator, pid, new_app, dst_app, mount_point);
    defer allocator.free(script);

    const tmp = std.mem.trimRight(u8, std.posix.getenv("TMPDIR") orelse "/tmp", "/");
    const path = try std.fmt.allocPrint(allocator, "{s}/wispterm-update-{d}.sh", .{ tmp, pid });
    errdefer allocator.free(path);

    var f = try std.fs.createFileAbsolute(path, .{ .mode = 0o755 });
    defer f.close();
    try f.writeAll(script);
    return path;
}

/// Launch the helper fully detached so it survives this process exiting.
/// `nohup ... &` inside `sh -c` backgrounds and reparents the job; the outer
/// shell returns immediately. The script path is our temp path (no quotes).
fn launchHelper(allocator: std.mem.Allocator, script_path: []const u8) !void {
    const cmd = try std.fmt.allocPrint(allocator, "nohup /bin/sh '{s}' >/dev/null 2>&1 &", .{script_path});
    defer allocator.free(cmd);

    var child = std.process.Child.init(&.{ "/bin/sh", "-c", cmd }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    _ = child.wait() catch {}; // outer sh exits at once after backgrounding
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
