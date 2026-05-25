const std = @import("std");
const platform_pty_command = @import("pty_command.zig");

pub fn hostPathToGuestPathAlloc(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    if (path.len < 3 or path[1] != ':' or (path[2] != '\\' and path[2] != '/')) return null;
    const drive = std.ascii.toLower(path[0]);
    if (drive < 'a' or drive > 'z') return null;

    const out_len = 6 + path.len - 2; // "/mnt/<drive>" plus the path after "C:"
    const out = try allocator.alloc(u8, out_len);
    @memcpy(out[0..5], "/mnt/");
    out[5] = drive;
    for (path[2..], 6..) |ch, i| {
        out[i] = if (ch == '\\') '/' else ch;
    }
    return out;
}

fn writeNativeUnit(out: anytype, idx: usize, ch: u8) void {
    out[idx] = @intCast(ch);
}

fn guestPathToNativePath(guest_path: []const u8, out: anytype) ?usize {
    if (guest_path.len >= 7 and std.mem.startsWith(u8, guest_path, "/mnt/")) {
        const drive_letter = guest_path[5];
        if (drive_letter >= 'a' and drive_letter <= 'z') {
            writeNativeUnit(out, 0, std.ascii.toUpper(drive_letter));
            writeNativeUnit(out, 1, ':');
            var out_idx: usize = 2;

            const rest = guest_path[6..];
            for (rest) |ch| {
                if (out_idx >= out.len - 1) break;
                writeNativeUnit(out, out_idx, if (ch == '/') '\\' else ch);
                out_idx += 1;
            }
            writeNativeUnit(out, out_idx, 0);
            return out_idx;
        }
    }

    if (guest_path.len > 0 and guest_path[0] == '/') {
        const distro = defaultDistroName() orelse return null;
        const prefix = "\\\\wsl.localhost\\";
        var out_idx: usize = 0;

        for (prefix) |ch| {
            if (out_idx >= out.len - 1) return null;
            writeNativeUnit(out, out_idx, ch);
            out_idx += 1;
        }
        for (distro) |ch| {
            if (out_idx >= out.len - 1) return null;
            writeNativeUnit(out, out_idx, ch);
            out_idx += 1;
        }
        for (guest_path) |ch| {
            if (out_idx >= out.len - 1) break;
            writeNativeUnit(out, out_idx, if (ch == '/') '\\' else ch);
            out_idx += 1;
        }

        writeNativeUnit(out, out_idx, 0);
        return out_idx;
    }

    return null;
}

/// Convert a WSL guest path to a host-accessible path.
fn guestPathToHostPath(guest_path: []const u8, out: *[260]u16) ?usize {
    return guestPathToNativePath(guest_path, out);
}

pub fn guestPathToNativeCwd(guest_path: []const u8, out: *platform_pty_command.CwdBuffer) ?platform_pty_command.CwdSlice {
    const len = guestPathToNativePath(guest_path, out) orelse return null;
    _ = platform_pty_command.cwdFromBuffer(out, len) orelse return null;
    return out[0..len];
}

pub fn guestPathToLocalPathUtf8(
    guest_path: []const u8,
    native_buf: *platform_pty_command.CwdBuffer,
    utf8_buf: []u8,
) ?[]const u8 {
    const native = guestPathToNativeCwd(guest_path, native_buf) orelse return null;
    const cwd = platform_pty_command.cwdFromBuffer(native_buf, native.len) orelse return null;
    return platform_pty_command.cwdToUtf8(utf8_buf, cwd);
}

fn defaultDistroName() ?[]const u8 {
    const Static = struct {
        threadlocal var cached: bool = false;
        threadlocal var distro_buf: [64]u8 = undefined;
        threadlocal var distro_len: usize = 0;
    };

    if (Static.cached) {
        if (Static.distro_len > 0) return Static.distro_buf[0..Static.distro_len];
        return null;
    }
    Static.cached = true;

    var child = std.process.Child.init(&.{ "wsl.exe", "--list", "--quiet" }, std.heap.page_allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return null;

    const stdout = child.stdout orelse {
        _ = child.wait() catch {};
        return null;
    };
    var buf: [256]u8 = undefined;
    const n = stdout.read(&buf) catch 0;
    _ = child.wait() catch {};
    if (n == 0) return null;

    var i: usize = 0;
    var out_idx: usize = 0;
    while (i + 1 < n and out_idx < Static.distro_buf.len) {
        const lo = buf[i];
        const hi = buf[i + 1];

        if (i == 0 and lo == 0xFF and hi == 0xFE) {
            i += 2;
            continue;
        }
        if (lo == '\r' or lo == '\n' or lo == 0) break;

        if (hi == 0 and lo >= 0x20 and lo < 0x7F) {
            Static.distro_buf[out_idx] = lo;
            out_idx += 1;
        }
        i += 2;
    }

    if (out_idx == 0) return null;
    Static.distro_len = out_idx;
    return Static.distro_buf[0..out_idx];
}

test "platform WSL converts Windows paths for WSL sessions" {
    const allocator = std.testing.allocator;

    const normal = (try hostPathToGuestPathAlloc(allocator, "C:\\Users\\me\\image.png")).?;
    defer allocator.free(normal);
    try std.testing.expectEqualStrings("/mnt/c/Users/me/image.png", normal);

    const slash = (try hostPathToGuestPathAlloc(allocator, "D:/work/a b.txt")).?;
    defer allocator.free(slash);
    try std.testing.expectEqualStrings("/mnt/d/work/a b.txt", slash);

    try std.testing.expect((try hostPathToGuestPathAlloc(allocator, "\\\\server\\share")) == null);
}

test "platform WSL converts mounted guest paths to host paths" {
    var out: [260]u16 = undefined;
    const len = guestPathToHostPath("/mnt/c/Users/me/project", &out).?;

    var utf8: [260]u8 = undefined;
    const utf8_len = try std.unicode.utf16LeToUtf8(&utf8, out[0..len]);
    try std.testing.expectEqualStrings("C:\\Users\\me\\project", utf8[0..utf8_len]);
}

test "platform WSL exposes converted local paths as UTF-8" {
    var native_buf: platform_pty_command.CwdBuffer = undefined;
    var utf8_buf: [260]u8 = undefined;

    const local = guestPathToLocalPathUtf8("/mnt/c/Users/me/project", &native_buf, &utf8_buf).?;
    try std.testing.expectEqualStrings("C:\\Users\\me\\project", local);
}
