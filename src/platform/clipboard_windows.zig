const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const platform_dirs = @import("dirs.zig");

const CF_TEXT: windows.UINT = 1;
const CF_DIB: windows.UINT = 8;
const CF_UNICODETEXT: windows.UINT = 13;
const CF_DIBV5: windows.UINT = 17;
const GMEM_MOVEABLE: windows.UINT = 0x0002;
const BI_RGB: u32 = 0;
const BI_BITFIELDS: u32 = 3;
const GDIP_OK: windows.INT = 0;
const PNG_ENCODER_CLSID: windows.GUID = .{
    .Data1 = 0x557CF406,
    .Data2 = 0x1A04,
    .Data3 = 0x11D3,
    .Data4 = .{ 0x9A, 0x73, 0x00, 0x00, 0xF8, 0x1E, 0xF3, 0x2E },
};

const BitmapInfoHeader = extern struct {
    biSize: u32,
    biWidth: i32,
    biHeight: i32,
    biPlanes: u16,
    biBitCount: u16,
    biCompression: u32,
    biSizeImage: u32,
    biXPelsPerMeter: i32,
    biYPelsPerMeter: i32,
    biClrUsed: u32,
    biClrImportant: u32,
};

const GpImage = opaque {};
const GpBitmap = GpImage;

const GdiplusStartupInput = extern struct {
    GdiplusVersion: windows.UINT,
    DebugEventCallback: ?*const anyopaque,
    SuppressBackgroundThread: windows.BOOL,
    SuppressExternalCodecs: windows.BOOL,
};

extern "user32" fn OpenClipboard(hWndNewOwner: ?windows.HWND) callconv(.winapi) windows.BOOL;
extern "user32" fn CloseClipboard() callconv(.winapi) windows.BOOL;
extern "user32" fn EmptyClipboard() callconv(.winapi) windows.BOOL;
extern "user32" fn SetClipboardData(uFormat: windows.UINT, hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "user32" fn GetClipboardData(uFormat: windows.UINT) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalAlloc(uFlags: windows.UINT, dwBytes: usize) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalLock(hMem: *anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(hMem: *anyopaque) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GlobalSize(hMem: *anyopaque) callconv(.winapi) usize;
extern "gdiplus" fn GdiplusStartup(
    token: *usize,
    input: *const GdiplusStartupInput,
    output: ?*anyopaque,
) callconv(.winapi) windows.INT;
extern "gdiplus" fn GdiplusShutdown(token: usize) callconv(.winapi) void;
extern "gdiplus" fn GdipCreateBitmapFromGdiDib(
    gdiBitmapInfo: *const anyopaque,
    gdiBitmapData: *const anyopaque,
    bitmap: *?*GpBitmap,
) callconv(.winapi) windows.INT;
extern "gdiplus" fn GdipSaveImageToFile(
    image: *GpImage,
    filename: [*:0]const windows.WCHAR,
    clsidEncoder: *const windows.GUID,
    encoderParams: ?*const anyopaque,
) callconv(.winapi) windows.INT;
extern "gdiplus" fn GdipDisposeImage(image: *GpImage) callconv(.winapi) windows.INT;

pub const Owner = struct {
    native_window: ?usize = null,
};

pub fn windowOwner(native_window: usize) Owner {
    return .{ .native_window = native_window };
}

pub fn writeText(allocator: std.mem.Allocator, owner: Owner, text: []const u8) bool {
    if (text.len == 0) return false;
    return switch (builtin.os.tag) {
        .windows => writeWindowsText(allocator, owner, text),
        else => false,
    };
}

pub fn readText(allocator: std.mem.Allocator, owner: Owner) ?[]u8 {
    return switch (builtin.os.tag) {
        .windows => readWindowsText(allocator, owner),
        else => null,
    };
}

pub fn readImageAsPngTemp(allocator: std.mem.Allocator, owner: Owner) ?[]u8 {
    return switch (builtin.os.tag) {
        .windows => readWindowsImageAsPngTemp(allocator, owner),
        else => null,
    };
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

fn ownerHwnd(owner: Owner) ?windows.HWND {
    const bits = owner.native_window orelse return null;
    if (bits == 0) return null;
    return @ptrFromInt(bits);
}

fn writeWindowsText(allocator: std.mem.Allocator, owner: Owner, text: []const u8) bool {
    const hwnd = ownerHwnd(owner) orelse return false;
    const utf16 = std.unicode.utf8ToUtf16LeAllocZ(allocator, text) catch return false;
    defer allocator.free(utf16);

    if (OpenClipboard(hwnd) == 0) return false;
    defer _ = CloseClipboard();
    _ = EmptyClipboard();

    const size = (utf16.len + 1) * @sizeOf(u16);
    const hmem = GlobalAlloc(GMEM_MOVEABLE, size) orelse return false;
    var transferred = false;
    defer {
        if (!transferred) _ = GlobalFree(hmem);
    }

    const ptr = GlobalLock(hmem) orelse return false;
    const dest: [*]u16 = @ptrCast(@alignCast(ptr));
    @memcpy(dest[0..utf16.len], utf16);
    dest[utf16.len] = 0;
    _ = GlobalUnlock(hmem);

    transferred = SetClipboardData(CF_UNICODETEXT, hmem) != null;
    return transferred;
}

fn readWindowsText(allocator: std.mem.Allocator, owner: Owner) ?[]u8 {
    if (OpenClipboard(ownerHwnd(owner)) == 0) return null;
    defer _ = CloseClipboard();

    if (GetClipboardData(CF_UNICODETEXT)) |hmem| {
        return readWindowsUnicodeText(allocator, hmem);
    }

    if (GetClipboardData(CF_TEXT)) |hmem| {
        return readWindowsAnsiText(allocator, hmem);
    }

    return null;
}

fn readWindowsUnicodeText(allocator: std.mem.Allocator, hmem: *anyopaque) ?[]u8 {
    const ptr = GlobalLock(hmem) orelse return null;
    defer _ = GlobalUnlock(hmem);

    const data: [*]const u16 = @ptrCast(@alignCast(ptr));
    var len: usize = 0;
    while (data[len] != 0) : (len += 1) {}
    if (len == 0) return null;

    const raw = std.unicode.utf16LeToUtf8Alloc(allocator, data[0..len]) catch return null;
    defer allocator.free(raw);
    return normalizeText(allocator, raw) catch null;
}

fn readWindowsAnsiText(allocator: std.mem.Allocator, hmem: *anyopaque) ?[]u8 {
    const ptr = GlobalLock(hmem) orelse return null;
    defer _ = GlobalUnlock(hmem);

    const data: [*]const u8 = @ptrCast(ptr);
    var len: usize = 0;
    while (data[len] != 0) : (len += 1) {}
    if (len == 0) return null;

    return normalizeText(allocator, data[0..len]) catch null;
}

fn readWindowsImageAsPngTemp(allocator: std.mem.Allocator, owner: Owner) ?[]u8 {
    if (OpenClipboard(ownerHwnd(owner)) == 0) return null;
    defer _ = CloseClipboard();

    const hmem = GetClipboardData(CF_DIBV5) orelse GetClipboardData(CF_DIB) orelse return null;
    return saveWindowsDibAsPng(allocator, hmem);
}

fn tempDir(allocator: std.mem.Allocator) ?[]const u8 {
    return platform_dirs.tempDir(allocator) catch null;
}

fn clipboardImagePath(allocator: std.mem.Allocator) ?[]u8 {
    const dir = tempDir(allocator) orelse return null;
    defer allocator.free(dir);

    const ts = std.time.milliTimestamp();
    return std.fmt.allocPrint(allocator, "{s}\\phantty-clipboard-{d}.png", .{ dir, ts }) catch null;
}

fn dibColorTableBytes(header: BitmapInfoHeader) usize {
    if (header.biBitCount > 8) return 0;
    const colors = if (header.biClrUsed != 0) header.biClrUsed else (@as(u32, 1) << @intCast(header.biBitCount));
    return @as(usize, colors) * 4;
}

fn dibMaskBytes(header: BitmapInfoHeader) usize {
    if (header.biCompression != BI_BITFIELDS) return 0;
    return if (header.biSize == @sizeOf(BitmapInfoHeader)) 12 else 0;
}

fn saveWindowsDibAsPng(allocator: std.mem.Allocator, hmem: *anyopaque) ?[]u8 {
    const total_size = GlobalSize(hmem);
    if (total_size < @sizeOf(BitmapInfoHeader)) return null;

    const ptr = GlobalLock(hmem) orelse return null;
    defer _ = GlobalUnlock(hmem);

    const bytes: [*]const u8 = @ptrCast(ptr);
    const dib = bytes[0..total_size];
    const header: *align(1) const BitmapInfoHeader = @ptrCast(dib.ptr);

    if (header.biSize < @sizeOf(BitmapInfoHeader) or header.biPlanes != 1) return null;
    if (header.biCompression != BI_RGB and header.biCompression != BI_BITFIELDS) return null;

    const pixel_offset = @as(usize, header.biSize) + dibColorTableBytes(header.*) + dibMaskBytes(header.*);
    if (pixel_offset > dib.len) return null;

    const out_path = clipboardImagePath(allocator) orelse return null;
    var keep_out_path = false;
    defer if (!keep_out_path) allocator.free(out_path);

    const out_path_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, out_path) catch return null;
    defer allocator.free(out_path_w);

    const startup_input: GdiplusStartupInput = .{
        .GdiplusVersion = 1,
        .DebugEventCallback = null,
        .SuppressBackgroundThread = 0,
        .SuppressExternalCodecs = 0,
    };
    var gdip_token: usize = 0;
    if (GdiplusStartup(&gdip_token, &startup_input, null) != GDIP_OK) return null;
    defer GdiplusShutdown(gdip_token);

    const info_ptr: *const anyopaque = @ptrCast(dib.ptr);
    const data_ptr: *const anyopaque = @ptrCast(dib[pixel_offset..].ptr);
    var bitmap: ?*GpBitmap = null;
    if (GdipCreateBitmapFromGdiDib(info_ptr, data_ptr, &bitmap) != GDIP_OK) return null;
    const gdip_bitmap = bitmap orelse return null;
    defer _ = GdipDisposeImage(gdip_bitmap);

    if (GdipSaveImageToFile(gdip_bitmap, out_path_w.ptr, &PNG_ENCODER_CLSID, null) != GDIP_OK) return null;
    keep_out_path = true;
    return out_path;
}

test "platform clipboard normalizes Windows newlines before paste encoding" {
    const text = try normalizeText(std.testing.allocator, "a\r\nb\rc\nd");
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("a\nb\nc\nd", text);
}

test "platform clipboard exposes text read write API with an opaque owner" {
    const owner = windowOwner(1234);

    try std.testing.expectEqual(@as(?usize, 1234), owner.native_window);
    try std.testing.expectEqual(@as(usize, 3), @typeInfo(@TypeOf(writeText)).@"fn".params.len);
    try std.testing.expect(@typeInfo(@TypeOf(writeText)).@"fn".params[0].type.? == std.mem.Allocator);
    try std.testing.expect(@typeInfo(@TypeOf(writeText)).@"fn".params[1].type.? == Owner);
    try std.testing.expect(@typeInfo(@TypeOf(writeText)).@"fn".params[2].type.? == []const u8);
    try std.testing.expect(@typeInfo(@TypeOf(writeText)).@"fn".return_type.? == bool);
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(@TypeOf(readText)).@"fn".params.len);
    try std.testing.expect(@typeInfo(@TypeOf(readText)).@"fn".params[0].type.? == std.mem.Allocator);
    try std.testing.expect(@typeInfo(@TypeOf(readText)).@"fn".params[1].type.? == Owner);
    try std.testing.expect(@typeInfo(@TypeOf(readText)).@"fn".return_type.? == ?[]u8);
}

test "platform clipboard exposes image paste as a temporary png path" {
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(@TypeOf(readImageAsPngTemp)).@"fn".params.len);
    try std.testing.expect(@typeInfo(@TypeOf(readImageAsPngTemp)).@"fn".params[0].type.? == std.mem.Allocator);
    try std.testing.expect(@typeInfo(@TypeOf(readImageAsPngTemp)).@"fn".params[1].type.? == Owner);
    try std.testing.expect(@typeInfo(@TypeOf(readImageAsPngTemp)).@"fn".return_type.? == ?[]u8);
}
