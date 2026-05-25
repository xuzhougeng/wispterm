const std = @import("std");

pub const Owner = struct {
    native_window: ?usize = null,
};

pub fn windowOwner(native_window: usize) Owner {
    return .{ .native_window = native_window };
}

pub fn writeText(allocator: std.mem.Allocator, owner: Owner, text: []const u8) bool {
    _ = allocator;
    _ = owner;
    _ = text;
    return false;
}

pub fn readText(allocator: std.mem.Allocator, owner: Owner) ?[]u8 {
    _ = allocator;
    _ = owner;
    return null;
}

pub fn readImageAsPngTemp(allocator: std.mem.Allocator, owner: Owner) ?[]u8 {
    _ = allocator;
    _ = owner;
    return null;
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
