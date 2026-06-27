const std = @import("std");

pub const DEFAULT_DIR = "wispterm-files";

pub const PlanError = error{
    MissingWorkingDir,
    EmptySourcePath,
    EmptyDestinationName,
    UnsafeDestinationName,
    OutOfMemory,
};

pub const CopyPlan = struct {
    dest_path: []u8,

    pub fn deinit(self: CopyPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.dest_path);
    }
};

pub fn planDestination(
    allocator: std.mem.Allocator,
    working_dir: []const u8,
    source_path: []const u8,
    dest_name: ?[]const u8,
) PlanError!CopyPlan {
    if (working_dir.len == 0) return error.MissingWorkingDir;
    if (source_path.len == 0) return error.EmptySourcePath;

    const name = dest_name orelse basename(source_path);
    if (name.len == 0) return error.EmptyDestinationName;
    if (!isSafeDestinationName(name)) return error.UnsafeDestinationName;

    const dir = std.fs.path.join(allocator, &.{ working_dir, DEFAULT_DIR }) catch return error.OutOfMemory;
    defer allocator.free(dir);
    const dest_path = std.fs.path.join(allocator, &.{ dir, name }) catch return error.OutOfMemory;
    return .{ .dest_path = dest_path };
}

pub fn basename(path: []const u8) []const u8 {
    var start: usize = 0;
    for (path, 0..) |ch, i| {
        if (ch == '/' or ch == '\\') start = i + 1;
    }
    return path[start..];
}

pub fn isSafeDestinationName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |ch| {
        if (ch == '/' or ch == '\\' or ch == ':') return false;
    }
    return true;
}

test "agent file copy plans destination under wispterm-files" {
    const plan = try planDestination(std.testing.allocator, "/work/project", "/tmp/volcano_plot.png", null);
    defer plan.deinit(std.testing.allocator);
    const expected = try std.fs.path.join(std.testing.allocator, &.{ "/work/project", "wispterm-files", "volcano_plot.png" });
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, plan.dest_path);
}

test "agent file copy accepts safe destination names" {
    const plan = try planDestination(std.testing.allocator, "/work/project", "/tmp/volcano_plot.png", "plot.png");
    defer plan.deinit(std.testing.allocator);
    const expected = try std.fs.path.join(std.testing.allocator, &.{ "/work/project", "wispterm-files", "plot.png" });
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, plan.dest_path);
}

test "agent file copy rejects destination names with separators" {
    try std.testing.expectError(error.UnsafeDestinationName, planDestination(std.testing.allocator, "/work/project", "/tmp/volcano_plot.png", "../plot.png"));
    try std.testing.expectError(error.UnsafeDestinationName, planDestination(std.testing.allocator, "/work/project", "/tmp/volcano_plot.png", "nested/plot.png"));
}
