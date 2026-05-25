const std = @import("std");
const pty_command = @import("pty_command.zig");
const platform_wsl = @import("wsl.zig");

pub fn wslHomeCommand() []const u8 {
    return "printf %s \"$HOME\"";
}

/// Run a command inside the default WSL distro and capture stdout.
pub fn wslExec(allocator: std.mem.Allocator, command: []const u8) ?[]u8 {
    const argv = pty_command.wslExecArgv(command);
    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return null;

    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(allocator);

    const stdout = child.stdout orelse {
        _ = child.wait() catch {};
        return null;
    };
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = stdout.read(&buf) catch break;
        if (n == 0) break;
        output.appendSlice(allocator, buf[0..n]) catch break;
    }

    const term = child.wait() catch return null;
    const ok = switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
    if (!ok) return null;

    return output.toOwnedSlice(allocator) catch null;
}

pub fn wslPathExpr(buf: *[1024]u8, path: []const u8) ?[]const u8 {
    return shellPathExpr(buf, path);
}

pub fn shellPathExpr(buf: *[1024]u8, path: []const u8) ?[]const u8 {
    var pos: usize = 0;
    if (std.mem.eql(u8, path, "~")) {
        if (!appendLiteral(buf, &pos, "\"$HOME\"")) return null;
        return buf[0..pos];
    }
    if (std.mem.startsWith(u8, path, "~/")) {
        if (!appendLiteral(buf, &pos, "\"$HOME\"/")) return null;
        if (!appendShellQuoted(buf, &pos, path[2..])) return null;
        return buf[0..pos];
    }
    if (!appendShellQuoted(buf, &pos, path)) return null;
    return buf[0..pos];
}

pub fn shellQuote(buf: *[1024]u8, arg: []const u8) ?[]const u8 {
    var pos: usize = 0;
    if (!appendShellQuoted(buf, &pos, arg)) return null;
    return buf[0..pos];
}

pub fn localPathForTerminalPaste(
    allocator: std.mem.Allocator,
    launch_kind: pty_command.LaunchKind,
    local_path: []const u8,
) ?[]u8 {
    switch (launch_kind) {
        .wsl => if (platform_wsl.hostPathToGuestPathAlloc(allocator, local_path) catch null) |guest_path| return guest_path,
        .local, .ssh => {},
    }
    return allocator.dupe(u8, local_path) catch null;
}

fn appendLiteral(buf: *[1024]u8, pos: *usize, text: []const u8) bool {
    if (pos.* + text.len > buf.len) return false;
    @memcpy(buf[pos.*..][0..text.len], text);
    pos.* += text.len;
    return true;
}

fn appendShellQuoted(buf: *[1024]u8, pos: *usize, arg: []const u8) bool {
    if (pos.* >= buf.len) return false;
    buf[pos.*] = '\'';
    pos.* += 1;

    for (arg) |ch| {
        if (ch == '\'') {
            const escaped = "'\\''";
            if (!appendLiteral(buf, pos, escaped)) return false;
        } else {
            if (pos.* >= buf.len) return false;
            buf[pos.*] = ch;
            pos.* += 1;
        }
    }

    if (pos.* >= buf.len) return false;
    buf[pos.*] = '\'';
    pos.* += 1;
    return true;
}

test "platform remote file shell paths keep home expandable and quote literals" {
    var buf: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("\"$HOME\"", shellPathExpr(&buf, "~").?);
    try std.testing.expectEqualStrings("\"$HOME\"/'README.md'", shellPathExpr(&buf, "~/README.md").?);
    try std.testing.expectEqualStrings("'/home/me/README.md'", shellPathExpr(&buf, "/home/me/README.md").?);
    try std.testing.expectEqualStrings("'/tmp/it'\\''s here'", shellQuote(&buf, "/tmp/it's here").?);
}

test "platform remote file exposes WSL command helpers" {
    var buf: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("\"$HOME\"", wslPathExpr(&buf, "~").?);
    try std.testing.expectEqualStrings("printf %s \"$HOME\"", wslHomeCommand());

    const exec_info = @typeInfo(@TypeOf(wslExec)).@"fn";
    try std.testing.expectEqual(@as(usize, 2), exec_info.params.len);
    try std.testing.expect(exec_info.params[0].type.? == std.mem.Allocator);
    try std.testing.expect(exec_info.params[1].type.? == []const u8);
    try std.testing.expect(exec_info.return_type.? == ?[]u8);
}

test "platform remote file adapts local paste paths by terminal launch kind" {
    const allocator = std.testing.allocator;

    const wsl_path = localPathForTerminalPaste(allocator, .wsl, "C:\\Users\\me\\image.png").?;
    defer allocator.free(wsl_path);
    try std.testing.expectEqualStrings("/mnt/c/Users/me/image.png", wsl_path);

    const local_path = localPathForTerminalPaste(allocator, .local, "C:\\Users\\me\\image.png").?;
    defer allocator.free(local_path);
    try std.testing.expectEqualStrings("C:\\Users\\me\\image.png", local_path);
}
