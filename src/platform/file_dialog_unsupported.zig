const std = @import("std");

pub const Owner = struct {
    native_window: ?usize = null,
};

pub const Filter = struct {
    name: []const u8,
    pattern: []const u8,
};

pub const OpenRequest = struct {
    owner: Owner = .{},
    title: []const u8,
    filters: []const Filter,
};

pub const SaveRequest = struct {
    owner: Owner = .{},
    title: []const u8,
    initial_dir: ?[]const u8 = null,
    default_filename: ?[]const u8 = null,
    default_extension: ?[]const u8 = null,
    filters: []const Filter,
};

pub fn windowOwner(native_window: usize) Owner {
    return .{ .native_window = native_window };
}

pub fn openFile(allocator: std.mem.Allocator, request: OpenRequest) ?[]u8 {
    _ = allocator;
    _ = request;
    return null;
}

pub fn saveFile(allocator: std.mem.Allocator, request: SaveRequest) ?[]u8 {
    _ = allocator;
    _ = request;
    return null;
}

pub fn pickFolder(allocator: std.mem.Allocator, request: OpenRequest) ?[]u8 {
    _ = allocator;
    _ = request;
    return null;
}
