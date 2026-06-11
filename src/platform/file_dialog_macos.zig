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

extern fn wispterm_macos_open_file_dialog(title: [*:0]const u8) ?[*:0]u8;
extern fn wispterm_macos_save_file_dialog(title: [*:0]const u8, initial_dir: ?[*:0]const u8, default_filename: ?[*:0]const u8) ?[*:0]u8;
extern fn wispterm_macos_pick_folder_dialog(title: [*:0]const u8) ?[*:0]u8;
extern fn wispterm_macos_services_free(ptr: ?*anyopaque) void;

pub fn windowOwner(native_window: usize) Owner {
    return .{ .native_window = native_window };
}

pub fn openFile(allocator: std.mem.Allocator, request: OpenRequest) ?[]u8 {
    _ = request.owner;
    _ = request.filters;
    const title = allocator.dupeZ(u8, request.title) catch return null;
    defer allocator.free(title);
    const raw = wispterm_macos_open_file_dialog(title.ptr) orelse return null;
    defer wispterm_macos_services_free(raw);
    return allocator.dupe(u8, std.mem.span(raw)) catch null;
}

pub fn pickFolder(allocator: std.mem.Allocator, request: OpenRequest) ?[]u8 {
    _ = request.owner;
    _ = request.filters;
    const title = allocator.dupeZ(u8, request.title) catch return null;
    defer allocator.free(title);
    const raw = wispterm_macos_pick_folder_dialog(title.ptr) orelse return null;
    defer wispterm_macos_services_free(raw);
    return allocator.dupe(u8, std.mem.span(raw)) catch null;
}

pub fn saveFile(allocator: std.mem.Allocator, request: SaveRequest) ?[]u8 {
    _ = request.owner;
    _ = request.default_extension;
    _ = request.filters;
    const title = allocator.dupeZ(u8, request.title) catch return null;
    defer allocator.free(title);
    const initial_dir = if (request.initial_dir) |dir| allocator.dupeZ(u8, dir) catch return null else null;
    defer if (initial_dir) |dir| allocator.free(dir);
    const default_filename = if (request.default_filename) |name| allocator.dupeZ(u8, name) catch return null else null;
    defer if (default_filename) |name| allocator.free(name);

    const raw = wispterm_macos_save_file_dialog(
        title.ptr,
        if (initial_dir) |dir| dir.ptr else null,
        if (default_filename) |name| name.ptr else null,
    ) orelse return null;
    defer wispterm_macos_services_free(raw);
    return allocator.dupe(u8, std.mem.span(raw)) catch null;
}
