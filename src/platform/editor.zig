const std = @import("std");
const builtin = @import("builtin");
const platform_process = @import("process.zig");

pub const Request = struct {
    path: []const u8,
};

pub const Command = struct {
    argv: [3][]const u8,
    len: usize,

    pub fn slice(self: *const Command) []const []const u8 {
        return self.argv[0..self.len];
    }
};

pub fn commandForTextFile(os_tag: std.Target.Os.Tag, path: []const u8) ?Command {
    return switch (os_tag) {
        .windows => .{ .argv = .{ "notepad.exe", path, "" }, .len = 2 },
        .macos => .{ .argv = .{ "open", "-t", path }, .len = 3 },
        .linux, .freebsd, .openbsd, .netbsd, .dragonfly => .{ .argv = .{ "xdg-open", path, "" }, .len = 2 },
        else => null,
    };
}

pub fn openTextFile(allocator: std.mem.Allocator, request: Request) bool {
    const command = commandForTextFile(builtin.os.tag, request.path) orelse return false;
    platform_process.spawnDetached(allocator, command.slice()) catch |err| {
        std.debug.print("open text file failed for {s}: {}\n", .{ request.path, err });
        return false;
    };
    return true;
}

test "platform editor selects a detached text editor command per OS" {
    const path = "C:/Users/alice/AppData/Roaming/phantty/config";

    const windows = commandForTextFile(.windows, path).?;
    try std.testing.expectEqual(@as(usize, 2), windows.len);
    try std.testing.expectEqualStrings("notepad.exe", windows.argv[0]);
    try std.testing.expectEqualStrings(path, windows.argv[1]);

    const macos = commandForTextFile(.macos, path).?;
    try std.testing.expectEqual(@as(usize, 3), macos.len);
    try std.testing.expectEqualStrings("open", macos.argv[0]);
    try std.testing.expectEqualStrings("-t", macos.argv[1]);
    try std.testing.expectEqualStrings(path, macos.argv[2]);

    const linux = commandForTextFile(.linux, path).?;
    try std.testing.expectEqual(@as(usize, 2), linux.len);
    try std.testing.expectEqualStrings("xdg-open", linux.argv[0]);
    try std.testing.expectEqualStrings(path, linux.argv[1]);
}
