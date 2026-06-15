const std = @import("std");
const platform_dirs = @import("dirs.zig");

pub const Owner = struct {
    native_window: ?usize = null,
};

extern fn wispterm_macos_clipboard_write_text(text: [*:0]const u8) bool;
extern fn wispterm_macos_clipboard_copy_text() ?[*:0]u8;
extern fn wispterm_macos_clipboard_image_png_path(dir: [*:0]const u8) ?[*:0]u8;
extern fn wispterm_macos_services_free(ptr: ?*anyopaque) void;

pub fn windowOwner(native_window: usize) Owner {
    return .{ .native_window = native_window };
}

pub fn writeText(allocator: std.mem.Allocator, owner: Owner, text: []const u8) bool {
    _ = owner;
    const normalized = normalizeText(allocator, text) catch return false;
    defer allocator.free(normalized);
    const text_z = allocator.dupeZ(u8, normalized) catch return false;
    defer allocator.free(text_z);
    return wispterm_macos_clipboard_write_text(text_z.ptr);
}

pub fn readText(allocator: std.mem.Allocator, owner: Owner) ?[]u8 {
    _ = owner;
    const raw = wispterm_macos_clipboard_copy_text() orelse return null;
    defer wispterm_macos_services_free(raw);
    return allocator.dupe(u8, std.mem.span(raw)) catch null;
}

pub fn readImageAsPngTemp(allocator: std.mem.Allocator, owner: Owner) ?[]u8 {
    _ = owner;
    const dir = platform_dirs.tempDir(allocator) catch return null;
    defer allocator.free(dir);
    const dir_z = allocator.dupeZ(u8, dir) catch return null;
    defer allocator.free(dir_z);

    const raw = wispterm_macos_clipboard_image_png_path(dir_z.ptr) orelse return null;
    defer wispterm_macos_services_free(raw);
    return allocator.dupe(u8, std.mem.span(raw)) catch null;
}

pub fn normalizeText(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, text.len);

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\r') {
            try out.append(allocator, '\n');
            i += 1;
            if (i < text.len and text[i] == '\n') i += 1;
            continue;
        }

        try out.append(allocator, text[i]);
        i += 1;
    }

    return out.toOwnedSlice(allocator);
}
