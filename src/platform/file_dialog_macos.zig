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

extern fn wispterm_macos_open_file_dialog(title: [*:0]const u8, allowed_exts: ?[*:0]const u8) ?[*:0]u8;
extern fn wispterm_macos_save_file_dialog(
    title: [*:0]const u8,
    initial_dir: ?[*:0]const u8,
    default_filename: ?[*:0]const u8,
    allowed_exts: ?[*:0]const u8,
    default_ext: ?[*:0]const u8,
) ?[*:0]u8;
extern fn wispterm_macos_pick_folder_dialog(title: [*:0]const u8) ?[*:0]u8;
extern fn wispterm_macos_services_free(ptr: ?*anyopaque) void;

pub fn windowOwner(native_window: usize) Owner {
    return .{ .native_window = native_window };
}

pub fn openFile(allocator: std.mem.Allocator, request: OpenRequest) ?[]u8 {
    _ = request.owner;
    const title = allocator.dupeZ(u8, request.title) catch return null;
    defer allocator.free(title);

    const allowed = joinAllowedExtensions(allocator, request.filters);
    defer if (allowed) |a| allocator.free(a);

    const raw = wispterm_macos_open_file_dialog(
        title.ptr,
        if (allowed) |a| a.ptr else null,
    ) orelse return null;
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
    const title = allocator.dupeZ(u8, request.title) catch return null;
    defer allocator.free(title);
    const initial_dir = if (request.initial_dir) |dir| allocator.dupeZ(u8, dir) catch return null else null;
    defer if (initial_dir) |dir| allocator.free(dir);
    const default_filename = if (request.default_filename) |name| allocator.dupeZ(u8, name) catch return null else null;
    defer if (default_filename) |name| allocator.free(name);

    const allowed = joinAllowedExtensions(allocator, request.filters);
    defer if (allowed) |a| allocator.free(a);
    const default_ext = if (request.default_extension) |ext| allocator.dupeZ(u8, ext) catch return null else null;
    defer if (default_ext) |ext| allocator.free(ext);

    const raw = wispterm_macos_save_file_dialog(
        title.ptr,
        if (initial_dir) |dir| dir.ptr else null,
        if (default_filename) |name| name.ptr else null,
        if (allowed) |a| a.ptr else null,
        if (default_ext) |ext| ext.ptr else null,
    ) orelse return null;
    defer wispterm_macos_services_free(raw);
    return allocator.dupe(u8, std.mem.span(raw)) catch null;
}

/// Convert dialog filter patterns ("*.md", "*.png;*.jpg", "*.*") into a
/// ';'-joined, deduplicated, NUL-terminated list of bare extensions the bridge
/// hands to NSOpenPanel/NSSavePanel.allowedFileTypes. Wildcard-only filters
/// ("*.*", "*") contribute nothing, so an all-files request yields null (no
/// type restriction) — matching the Windows backend, which defaults to the
/// first concrete filter and treats "*.*" as unrestricted.
fn joinAllowedExtensions(allocator: std.mem.Allocator, filters: []const Filter) ?[:0]u8 {
    return joinAllowedExtensionsImpl(allocator, filters) catch null;
}

fn joinAllowedExtensionsImpl(allocator: std.mem.Allocator, filters: []const Filter) !?[:0]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    for (filters) |filter| {
        var it = std.mem.tokenizeAny(u8, filter.pattern, ";,");
        while (it.next()) |token| {
            const ext = extensionFromPattern(token) orelse continue;
            if (containsExtension(out.items, ext)) continue;
            if (out.items.len > 0) try out.append(allocator, ';');
            try out.appendSlice(allocator, ext);
        }
    }

    if (out.items.len == 0) {
        out.deinit(allocator);
        return null;
    }
    return try out.toOwnedSliceSentinel(allocator, 0);
}

/// Extract a bare extension from one glob token, or null when the token is a
/// wildcard (`*`, `*.*`) or otherwise carries no concrete extension.
fn extensionFromPattern(token: []const u8) ?[]const u8 {
    var t = std.mem.trim(u8, token, " \t");
    if (std.mem.startsWith(u8, t, "*.")) {
        t = t[2..];
    } else if (std.mem.startsWith(u8, t, ".")) {
        t = t[1..];
    } else if (std.mem.eql(u8, t, "*")) {
        return null;
    }
    if (t.len == 0) return null;
    // Still wildcarded (e.g. "*" left from "*.*") → not a concrete extension.
    if (std.mem.indexOfAny(u8, t, "*?") != null) return null;
    return t;
}

fn containsExtension(joined: []const u8, ext: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, joined, ';');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ext)) return true;
    }
    return false;
}

test "macOS file dialog derives allowed extensions from filter patterns" {
    const a = std.testing.allocator;

    {
        const filters = [_]Filter{
            .{ .name = "Markdown (*.md)", .pattern = "*.md" },
            .{ .name = "All Files (*.*)", .pattern = "*.*" },
        };
        const exts = joinAllowedExtensions(a, &filters) orelse return error.ExpectedExtensions;
        defer a.free(exts);
        try std.testing.expectEqualStrings("md", exts);
    }
    {
        const filters = [_]Filter{.{ .name = "Images", .pattern = "*.png;*.jpg;*.jpeg" }};
        const exts = joinAllowedExtensions(a, &filters) orelse return error.ExpectedExtensions;
        defer a.free(exts);
        try std.testing.expectEqualStrings("png;jpg;jpeg", exts);
    }
    {
        // All-files-only → no type restriction.
        const filters = [_]Filter{.{ .name = "All Files", .pattern = "*.*" }};
        try std.testing.expect(joinAllowedExtensions(a, &filters) == null);
    }
    {
        // Duplicate extensions across filters collapse to one.
        const filters = [_]Filter{
            .{ .name = "MD", .pattern = "*.md" },
            .{ .name = "MD bare", .pattern = "md" },
        };
        const exts = joinAllowedExtensions(a, &filters) orelse return error.ExpectedExtensions;
        defer a.free(exts);
        try std.testing.expectEqualStrings("md", exts);
    }
}
