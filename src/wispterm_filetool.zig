//! wispterm-filetool — tiny remote-side helper for WispTerm SSH file edits.
const std = @import("std");
const remote_filetool = @import("agent/remote_filetool.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len == 2 and std.mem.eql(u8, args[1], "--help")) {
        try stdoutAll(USAGE);
        return;
    }
    const parsed = parseArgs(args[1..]) orelse {
        try stderrAll(USAGE);
        std.process.exit(2);
    };

    var stdin = std.fs.File.stdin();
    const request = stdin.readToEndAlloc(allocator, remote_filetool.max_request_bytes) catch {
        try stdoutAll("error BadRequest\n");
        std.process.exit(1);
    };
    defer allocator.free(request);

    const out = if (std.mem.eql(u8, parsed.command, remote_filetool.edit_check_command))
        try remote_filetool.handleEditCheckAlloc(allocator, parsed.path, request, true)
    else if (std.mem.eql(u8, parsed.command, remote_filetool.edit_count_command))
        try remote_filetool.handleEditCheckAlloc(allocator, parsed.path, request, false)
    else if (std.mem.eql(u8, parsed.command, remote_filetool.edit_apply_command))
        try remote_filetool.handleEditApplyAlloc(allocator, parsed.path, request)
    else {
        try stderrAll(USAGE);
        std.process.exit(2);
    };
    defer allocator.free(out);

    try stdoutAll(out);
    if (!std.mem.startsWith(u8, out, "ok ")) std.process.exit(1);
}

const ParsedArgs = struct {
    command: []const u8,
    path: []const u8,
};

fn parseArgs(args: []const []const u8) ?ParsedArgs {
    if (args.len != 3) return null;
    if (!std.mem.eql(u8, args[1], "--")) return null;
    return .{ .command = args[0], .path = args[2] };
}

fn stdoutAll(s: []const u8) !void {
    try std.fs.File.stdout().deprecatedWriter().writeAll(s);
}

fn stderrAll(s: []const u8) !void {
    try std.fs.File.stderr().deprecatedWriter().writeAll(s);
}

const USAGE =
    \\wispterm-filetool — remote-side helper for WispTerm SSH edit_file
    \\
    \\Usage:
    \\  wispterm-filetool edit-check -- <path>
    \\  wispterm-filetool edit-count -- <path>
    \\  wispterm-filetool edit-apply -- <path>
    \\
;

test "wispterm-filetool parses command separator and path" {
    const args = [_][]const u8{ "edit-check", "--", "/tmp/a b.txt" };
    const parsed = parseArgs(&args).?;
    try std.testing.expectEqualStrings("edit-check", parsed.command);
    try std.testing.expectEqualStrings("/tmp/a b.txt", parsed.path);
}
