//! Replace-safe file writes for persisted application state.

const std = @import("std");

/// Write `data` to `path` through `std.fs.AtomicFile`.
///
/// Keeps platform-specific replacement semantics and temporary file cleanup
/// details out of callers that only need a durable replace-safe write.
pub fn writeFileReplaceSafe(path: []const u8, data: []const u8) !void {
    var write_buffer: [0]u8 = .{};
    var atomic = try std.fs.cwd().atomicFile(path, .{ .write_buffer = &write_buffer });
    defer atomic.deinit();
    try atomic.file_writer.file.writeAll(data);
    try atomic.finish();
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
