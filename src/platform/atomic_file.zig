//! Replace-safe file writes for persisted application state.

const std = @import("std");
const builtin = @import("builtin");

pub const WriteOptions = struct {
    mode: std.fs.File.Mode = std.fs.File.default_mode,
    sync_file: bool = false,
    sync_parent_dir: bool = false,
};

/// Write `data` to `path` through `std.fs.AtomicFile`.
///
/// Keeps platform-specific replacement semantics and temporary file cleanup
/// details out of callers that only need a durable replace-safe write.
pub fn writeFileReplaceSafe(path: []const u8, data: []const u8) !void {
    try writeFileReplaceSafeWithOptions(path, data, .{});
}

/// Same as `writeFileReplaceSafe`, with opt-in sync knobs for state that needs
/// stronger power-loss durability than the default crash-safe replace.
pub fn writeFileReplaceSafeWithOptions(path: []const u8, data: []const u8, options: WriteOptions) !void {
    var write_buffer: [0]u8 = .{};
    var atomic = try std.fs.cwd().atomicFile(path, .{
        .mode = options.mode,
        .make_path = true,
        .write_buffer = &write_buffer,
    });
    defer atomic.deinit();
    try atomic.file_writer.file.writeAll(data);
    try atomic.flush();
    if (options.sync_file) try atomic.file_writer.file.sync();
    try atomic.renameIntoPlace();
    if (options.sync_parent_dir) syncParentDir(path);
}

fn syncParentDir(path: []const u8) void {
    if (builtin.os.tag == .windows) return;
    const parent = std.fs.path.dirname(path) orelse ".";
    var dir = std.fs.cwd().openDir(parent, .{}) catch return;
    defer dir.close();
    const rc = std.posix.system.fsync(dir.fd);
    switch (std.posix.errno(rc)) {
        .SUCCESS, .INVAL, .ROFS => return,
        else => return,
    }
}

test "platform atomic file replaces existing contents" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "state.json" });
    defer std.testing.allocator.free(path);

    try writeFileReplaceSafe(path, "old");
    try writeFileReplaceSafe(path, "new");

    const got = try tmp.dir.readFileAlloc(std.testing.allocator, "state.json", 16);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("new", got);
}

test "platform atomic file creates parent directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "nested", "state.json" });
    defer std.testing.allocator.free(path);

    try writeFileReplaceSafe(path, "new");

    const got = try tmp.dir.readFileAlloc(std.testing.allocator, "nested/state.json", 16);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("new", got);
}

test "platform atomic file preserves requested file mode" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "secret.json" });
    defer std.testing.allocator.free(path);

    try writeFileReplaceSafeWithOptions(path, "secret", .{ .mode = 0o600 });

    const stat = try tmp.dir.statFile("secret.json");
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o600), stat.mode & 0o777);
}

test "platform atomic file optional sync path writes successfully" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "durable.json" });
    defer std.testing.allocator.free(path);

    try writeFileReplaceSafeWithOptions(path, "durable", .{ .sync_file = true, .sync_parent_dir = true });

    const got = try tmp.dir.readFileAlloc(std.testing.allocator, "durable.json", 16);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("durable", got);
}
