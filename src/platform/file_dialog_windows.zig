const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

const OFN_OVERWRITEPROMPT: windows.DWORD = 0x00000002;
const OFN_HIDEREADONLY: windows.DWORD = 0x00000004;
const OFN_NOCHANGEDIR: windows.DWORD = 0x00000008;
const OFN_PATHMUSTEXIST: windows.DWORD = 0x00000800;
const OFN_FILEMUSTEXIST: windows.DWORD = 0x00001000;
const OFN_EXPLORER: windows.DWORD = 0x00080000;
const OFN_ENABLESIZING: windows.DWORD = 0x00800000;

const OPENFILENAMEW = extern struct {
    lStructSize: windows.DWORD = @sizeOf(OPENFILENAMEW),
    hwndOwner: ?windows.HWND = null,
    hInstance: ?windows.HINSTANCE = null,
    lpstrFilter: ?[*:0]const windows.WCHAR = null,
    lpstrCustomFilter: ?[*]windows.WCHAR = null,
    nMaxCustFilter: windows.DWORD = 0,
    nFilterIndex: windows.DWORD = 0,
    lpstrFile: ?[*]windows.WCHAR = null,
    nMaxFile: windows.DWORD = 0,
    lpstrFileTitle: ?[*]windows.WCHAR = null,
    nMaxFileTitle: windows.DWORD = 0,
    lpstrInitialDir: ?[*:0]const windows.WCHAR = null,
    lpstrTitle: ?[*:0]const windows.WCHAR = null,
    Flags: windows.DWORD = 0,
    nFileOffset: windows.WORD = 0,
    nFileExtension: windows.WORD = 0,
    lpstrDefExt: ?[*:0]const windows.WCHAR = null,
    lCustData: windows.LPARAM = 0,
    lpfnHook: ?*const anyopaque = null,
    lpTemplateName: ?[*:0]const windows.WCHAR = null,
};

extern "comdlg32" fn GetOpenFileNameW(lpofn: *OPENFILENAMEW) callconv(.winapi) windows.BOOL;
extern "comdlg32" fn GetSaveFileNameW(lpofn: *OPENFILENAMEW) callconv(.winapi) windows.BOOL;

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
    return switch (builtin.os.tag) {
        .windows => openWindowsFile(allocator, request),
        else => null,
    };
}

pub fn saveFile(allocator: std.mem.Allocator, request: SaveRequest) ?[]u8 {
    return switch (builtin.os.tag) {
        .windows => saveWindowsFile(allocator, request),
        else => null,
    };
}

fn ownerHwnd(owner: Owner) ?windows.HWND {
    const bits = owner.native_window orelse return null;
    if (bits == 0) return null;
    return @ptrFromInt(bits);
}

fn openWindowsFile(allocator: std.mem.Allocator, request: OpenRequest) ?[]u8 {
    const max_file_chars = 32768;
    const file_buf = allocator.alloc(windows.WCHAR, max_file_chars) catch return null;
    defer allocator.free(file_buf);
    @memset(file_buf, 0);

    const title_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, request.title) catch return null;
    defer allocator.free(title_w);

    const filter_w = windowsFilter(allocator, request.filters) catch return null;
    defer allocator.free(filter_w);

    var ofn: OPENFILENAMEW = .{
        .hwndOwner = ownerHwnd(request.owner),
        .lpstrFilter = filter_w.ptr,
        .nFilterIndex = 1,
        .lpstrFile = file_buf.ptr,
        .nMaxFile = @intCast(file_buf.len),
        .lpstrTitle = title_w.ptr,
        .Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_EXPLORER | OFN_ENABLESIZING,
    };

    if (GetOpenFileNameW(&ofn) == 0) return null;
    return pathFromWindowsBuffer(allocator, file_buf);
}

fn saveWindowsFile(allocator: std.mem.Allocator, request: SaveRequest) ?[]u8 {
    const max_file_chars = 32768;
    const file_buf = allocator.alloc(windows.WCHAR, max_file_chars) catch return null;
    defer allocator.free(file_buf);
    @memset(file_buf, 0);

    if (request.default_filename) |default_filename| {
        const filename_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, default_filename) catch return null;
        defer allocator.free(filename_w);
        const filename_len = @min(filename_w.len, file_buf.len - 1);
        @memcpy(file_buf[0..filename_len], filename_w[0..filename_len]);
        file_buf[filename_len] = 0;
    }

    const title_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, request.title) catch return null;
    defer allocator.free(title_w);

    const filter_w = windowsFilter(allocator, request.filters) catch return null;
    defer allocator.free(filter_w);

    const initial_dir_w = if (request.initial_dir) |initial_dir|
        std.unicode.utf8ToUtf16LeAllocZ(allocator, initial_dir) catch return null
    else
        null;
    defer if (initial_dir_w) |buf| allocator.free(buf);

    const default_ext_w = if (request.default_extension) |default_extension|
        std.unicode.utf8ToUtf16LeAllocZ(allocator, default_extension) catch return null
    else
        null;
    defer if (default_ext_w) |buf| allocator.free(buf);

    var ofn: OPENFILENAMEW = .{
        .hwndOwner = ownerHwnd(request.owner),
        .lpstrFilter = filter_w.ptr,
        .nFilterIndex = 1,
        .lpstrFile = file_buf.ptr,
        .nMaxFile = @intCast(file_buf.len),
        .lpstrInitialDir = if (initial_dir_w) |buf| buf.ptr else null,
        .lpstrTitle = title_w.ptr,
        .Flags = OFN_OVERWRITEPROMPT |
            OFN_HIDEREADONLY |
            OFN_NOCHANGEDIR |
            OFN_PATHMUSTEXIST |
            OFN_EXPLORER |
            OFN_ENABLESIZING,
        .lpstrDefExt = if (default_ext_w) |buf| buf.ptr else null,
    };

    if (GetSaveFileNameW(&ofn) == 0) return null;
    return pathFromWindowsBuffer(allocator, file_buf);
}

fn windowsFilter(allocator: std.mem.Allocator, filters: []const Filter) ![:0]windows.WCHAR {
    const default_filters = [_]Filter{.{ .name = "All Files", .pattern = "*.*" }};
    const active_filters = if (filters.len == 0) default_filters[0..] else filters;

    var out: std.ArrayListUnmanaged(windows.WCHAR) = .empty;
    errdefer out.deinit(allocator);
    for (active_filters) |filter| {
        try appendUtf16ZPart(allocator, &out, filter.name);
        try appendUtf16ZPart(allocator, &out, filter.pattern);
    }
    return out.toOwnedSliceSentinel(allocator, 0);
}

fn appendUtf16ZPart(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(windows.WCHAR), value: []const u8) !void {
    const value_w = try std.unicode.utf8ToUtf16LeAlloc(allocator, value);
    defer allocator.free(value_w);
    try out.appendSlice(allocator, value_w);
    try out.append(allocator, 0);
}

fn pathFromWindowsBuffer(allocator: std.mem.Allocator, file_buf: []const windows.WCHAR) ?[]u8 {
    var len: usize = 0;
    while (len < file_buf.len and file_buf[len] != 0) : (len += 1) {}
    if (len == 0) return null;
    return std.unicode.utf16LeToUtf8Alloc(allocator, file_buf[0..len]) catch null;
}

test "platform file dialog exposes typed open and save APIs" {
    const owner = windowOwner(1234);
    const filters = [_]Filter{.{ .name = "All Files", .pattern = "*.*" }};

    const open_request = OpenRequest{
        .owner = owner,
        .title = "Upload file",
        .filters = &filters,
    };
    const save_request = SaveRequest{
        .owner = owner,
        .title = "Save Markdown",
        .default_filename = "chat.md",
        .default_extension = "md",
        .filters = &filters,
    };

    try std.testing.expectEqual(@as(?usize, 1234), owner.native_window);
    try std.testing.expectEqualStrings("Upload file", open_request.title);
    try std.testing.expectEqualStrings("chat.md", save_request.default_filename.?);
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(@TypeOf(openFile)).@"fn".params.len);
    try std.testing.expect(@typeInfo(@TypeOf(openFile)).@"fn".params[0].type.? == std.mem.Allocator);
    try std.testing.expect(@typeInfo(@TypeOf(openFile)).@"fn".params[1].type.? == OpenRequest);
    try std.testing.expect(@typeInfo(@TypeOf(openFile)).@"fn".return_type.? == ?[]u8);
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(@TypeOf(saveFile)).@"fn".params.len);
    try std.testing.expect(@typeInfo(@TypeOf(saveFile)).@"fn".params[0].type.? == std.mem.Allocator);
    try std.testing.expect(@typeInfo(@TypeOf(saveFile)).@"fn".params[1].type.? == SaveRequest);
    try std.testing.expect(@typeInfo(@TypeOf(saveFile)).@"fn".return_type.? == ?[]u8);
}
