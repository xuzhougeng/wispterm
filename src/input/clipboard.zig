//! Clipboard, paste, and file drop handling for AppWindow input.

const std = @import("std");
const AppWindow = @import("../AppWindow.zig");
const file_explorer = AppWindow.file_explorer;
const browser_panel = AppWindow.browser_panel;
const overlays = AppWindow.overlays;
const scp = @import("../scp.zig");
const win32_backend = @import("../apprt/win32.zig");
const Surface = @import("../Surface.zig");
const selection_unit = @import("../selection_unit.zig");

const CF_TEXT: win32_backend.UINT = 1;
const CF_DIB: win32_backend.UINT = 8;
const CF_UNICODETEXT: win32_backend.UINT = 13;
const CF_DIBV5: win32_backend.UINT = 17;
const BI_RGB: u32 = 0;
const BI_BITFIELDS: u32 = 3;
const GDIP_OK: win32_backend.INT = 0;
const PNG_ENCODER_CLSID: win32_backend.GUID = .{
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

fn isPasteStripByte(byte: u8) bool {
    return switch (byte) {
        0x00, // NUL
        0x08, // BS
        0x05, // ENQ
        0x04, // EOT
        0x1B, // ESC
        0x7F, // DEL
        0x03, // VINTR (Ctrl+C)
        0x1C, // VQUIT (Ctrl+\)
        0x15, // VKILL (Ctrl+U)
        0x1A, // VSUSP (Ctrl+Z)
        0x11, // VSTART (Ctrl+Q)
        0x13, // VSTOP (Ctrl+S)
        0x17, // VWERASE (Ctrl+W)
        0x16, // VLNEXT (Ctrl+V)
        0x12, // VREPRINT (Ctrl+R)
        0x0F, // VDISCARD (Ctrl+O)
        => true,
        else => false,
    };
}

fn pasteNeedsMutation(data: []const u8, bracketed: bool) bool {
    for (data) |byte| {
        if (isPasteStripByte(byte)) return true;
        if (!bracketed and byte == '\n') return true;
    }
    return false;
}

fn mutatePasteData(data: []u8, bracketed: bool) void {
    for (data) |*byte| {
        if (isPasteStripByte(byte.*)) {
            byte.* = ' ';
        } else if (!bracketed and byte.* == '\n') {
            byte.* = '\r';
        }
    }
}

/// Write data to the PTY's input pipe (us -> child stdin).
pub fn writeToPty(surface: *Surface, data: []const u8) void {
    surface.queuePtyWrite(data);
}

pub fn writePasteToPty(surface: *Surface, allocator: std.mem.Allocator, data: []const u8) void {
    const bracketed = surface.terminal.modes.get(.bracketed_paste);
    var owned: ?[]u8 = null;
    var body = data;
    if (pasteNeedsMutation(data, bracketed)) {
        owned = allocator.dupe(u8, data) catch return;
        mutatePasteData(owned.?, bracketed);
        body = owned.?;
    }
    defer {
        if (owned) |buf| allocator.free(buf);
    }

    if (bracketed) {
        writeToPty(surface, "\x1b[200~");
        writeToPty(surface, body);
        writeToPty(surface, "\x1b[201~");
    } else {
        writeToPty(surface, body);
    }
}

fn clipboardTempDir(allocator: std.mem.Allocator) ?[]u8 {
    if (std.process.getEnvVarOwned(allocator, "TEMP")) |v| return v else |_| {}
    if (std.process.getEnvVarOwned(allocator, "TMP")) |v| return v else |_| {}
    if (std.process.getEnvVarOwned(allocator, "LOCALAPPDATA")) |v| {
        return std.fs.path.join(allocator, &.{ v, "Temp" }) catch {
            allocator.free(v);
            return null;
        };
    } else |_| {}
    return null;
}

fn clipboardImagePath(allocator: std.mem.Allocator) ?[]u8 {
    const temp_dir = clipboardTempDir(allocator) orelse return null;
    defer allocator.free(temp_dir);

    const ts = std.time.milliTimestamp();
    return std.fmt.allocPrint(allocator, "{s}\\phantty-clipboard-{d}.png", .{ temp_dir, ts }) catch null;
}

fn quotePathForPaste(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    if (std.mem.indexOfAny(u8, path, " \t\"") == null) return allocator.dupe(u8, path) catch null;
    return std.fmt.allocPrint(allocator, "\"{s}\"", .{path}) catch null;
}

fn windowsPathToWslPath(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    if (path.len < 3 or path[1] != ':' or (path[2] != '\\' and path[2] != '/')) return null;
    const drive = std.ascii.toLower(path[0]);
    if (drive < 'a' or drive > 'z') return null;

    const out_len = 6 + path.len - 2; // "/mnt/<drive>" plus the path after "C:"
    const out = allocator.alloc(u8, out_len) catch return null;
    @memcpy(out[0..5], "/mnt/");
    out[5] = drive;
    for (path[2..], 6..) |ch, i| {
        out[i] = if (ch == '\\') '/' else ch;
    }
    return out;
}

fn clipboardImageBasename(path: []const u8) []const u8 {
    var start: usize = 0;
    for (path, 0..) |ch, i| {
        if (ch == '\\' or ch == '/') start = i + 1;
    }
    return path[start..];
}

fn joinUnixPath(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) ?[]u8 {
    if (dir.len == 0 or std.mem.eql(u8, dir, ".")) return allocator.dupe(u8, name) catch null;
    if (std.mem.eql(u8, dir, "/")) return std.fmt.allocPrint(allocator, "/{s}", .{name}) catch null;
    const base = std.mem.trimRight(u8, dir, "/");
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, name }) catch null;
}

const SshDropRemoteDir = struct {
    path: []u8,
    used_fallback_pwd: bool,
};

fn resolveSshDropRemoteDir(allocator: std.mem.Allocator, osc7_cwd: ?[]const u8, fallback_pwd: []const u8) !SshDropRemoteDir {
    if (osc7_cwd) |cwd| {
        if (cwd.len > 0) {
            return .{
                .path = try allocator.dupe(u8, cwd),
                .used_fallback_pwd = false,
            };
        }
    }

    const trimmed = std.mem.trim(u8, fallback_pwd, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyRemoteDir;
    return .{
        .path = try allocator.dupe(u8, trimmed),
        .used_fallback_pwd = true,
    };
}

test "ssh drop remote dir marks fallback when OSC 7 cwd is missing" {
    const resolved = try resolveSshDropRemoteDir(std.testing.allocator, null, " /home/user\r\n");
    defer std.testing.allocator.free(resolved.path);

    try std.testing.expectEqualStrings("/home/user", resolved.path);
    try std.testing.expect(resolved.used_fallback_pwd);
}

test "ssh drop remote dir prefers OSC 7 cwd without fallback warning" {
    const resolved = try resolveSshDropRemoteDir(std.testing.allocator, "/srv/app", "/home/user\n");
    defer std.testing.allocator.free(resolved.path);

    try std.testing.expectEqualStrings("/srv/app", resolved.path);
    try std.testing.expect(!resolved.used_fallback_pwd);
}

fn shellSingleQuoteForPaste(allocator: std.mem.Allocator, text: []const u8) ?[]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    out.append(allocator, '\'') catch return null;
    for (text) |ch| {
        if (ch == '\'') {
            out.appendSlice(allocator, "'\\''") catch return null;
        } else {
            out.append(allocator, ch) catch return null;
        }
    }
    out.append(allocator, '\'') catch return null;
    return out.toOwnedSlice(allocator) catch null;
}

fn remoteClipboardImagePath(allocator: std.mem.Allocator, local_path: []const u8) ?[]u8 {
    const basename = clipboardImageBasename(local_path);
    if (basename.len == 0) return null;
    return std.fmt.allocPrint(allocator, "/tmp/{s}", .{basename}) catch null;
}

fn sshAskPassScriptPath(allocator: std.mem.Allocator) ?[]u8 {
    const temp_dir = clipboardTempDir(allocator) orelse return null;
    defer allocator.free(temp_dir);

    return std.fmt.allocPrint(allocator, "{s}\\phantty-ssh-askpass.cmd", .{temp_dir}) catch null;
}

fn ensureSshAskPassScript(allocator: std.mem.Allocator) ?[]u8 {
    const path = sshAskPassScriptPath(allocator) orelse return null;
    errdefer allocator.free(path);

    const file = std.fs.createFileAbsolute(path, .{ .truncate = true }) catch return null;
    defer file.close();

    file.writeAll(
        "@echo off\r\n" ++
            "powershell.exe -NoLogo -NoProfile -Command \"[Console]::Out.Write($env:PHANTTY_SSH_PASSWORD)\"\r\n",
    ) catch return null;
    return path;
}

fn uploadClipboardImageForSsh(allocator: std.mem.Allocator, surface: *const Surface, local_path: []const u8) ?[]u8 {
    const conn = surface.ssh_connection orelse {
        std.debug.print("SSH image paste skipped: no SSH profile metadata for this surface\n", .{});
        return null;
    };

    const remote_path = remoteClipboardImagePath(allocator, local_path) orelse return null;
    var keep_remote_path = false;
    defer if (!keep_remote_path) allocator.free(remote_path);

    var spec_buf: [512]u8 = undefined;
    const destination = scp.remoteSpec(&spec_buf, &conn, remote_path);

    const result = scp.transfer(allocator, &conn, local_path, destination);
    if (result != .ok) {
        std.debug.print("SSH image upload failed\n", .{});
        return null;
    }

    keep_remote_path = true;
    return remote_path;
}

fn imagePathForSurfacePaste(allocator: std.mem.Allocator, surface: *const Surface, path: []const u8) ?[]u8 {
    switch (surface.launch_kind) {
        .wsl => if (windowsPathToWslPath(allocator, path)) |wsl_path| return wsl_path,
        .ssh => return uploadClipboardImageForSsh(allocator, surface, path),
        .windows => {},
    }
    return allocator.dupe(u8, path) catch null;
}

fn readClipboardUnicodeText(allocator: std.mem.Allocator, hmem: *anyopaque) ?[]u8 {
    const ptr = win32_backend.GlobalLock(hmem) orelse return null;
    defer _ = win32_backend.GlobalUnlock(hmem);

    const data: [*]const u16 = @ptrCast(@alignCast(ptr));
    var len: usize = 0;
    while (data[len] != 0) : (len += 1) {}
    if (len == 0) return null;

    const raw = std.unicode.utf16LeToUtf8Alloc(allocator, data[0..len]) catch return null;
    defer allocator.free(raw);
    return normalizeClipboardText(allocator, raw) catch null;
}

fn readClipboardAnsiText(allocator: std.mem.Allocator, hmem: *anyopaque) ?[]u8 {
    const ptr = win32_backend.GlobalLock(hmem) orelse return null;
    defer _ = win32_backend.GlobalUnlock(hmem);

    const data: [*]const u8 = @ptrCast(ptr);
    var len: usize = 0;
    while (data[len] != 0) : (len += 1) {}
    if (len == 0) return null;

    return normalizeClipboardText(allocator, data[0..len]) catch null;
}

fn normalizeClipboardText(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
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

test "clipboard text normalizes Windows newlines before paste encoding" {
    const text = try normalizeClipboardText(std.testing.allocator, "a\r\nb\rc\nd");
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("a\nb\nc\nd", text);
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

fn saveClipboardDibAsPng(allocator: std.mem.Allocator, hmem: *anyopaque) ?[]u8 {
    const total_size = win32_backend.GlobalSize(hmem);
    if (total_size < @sizeOf(BitmapInfoHeader)) return null;

    const ptr = win32_backend.GlobalLock(hmem) orelse return null;
    defer _ = win32_backend.GlobalUnlock(hmem);

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

    const startup_input: win32_backend.GdiplusStartupInput = .{
        .GdiplusVersion = 1,
        .DebugEventCallback = null,
        .SuppressBackgroundThread = 0,
        .SuppressExternalCodecs = 0,
    };
    var gdip_token: usize = 0;
    if (win32_backend.GdiplusStartup(&gdip_token, &startup_input, null) != GDIP_OK) return null;
    defer win32_backend.GdiplusShutdown(gdip_token);

    const info_ptr: *const anyopaque = @ptrCast(dib.ptr);
    const data_ptr: *const anyopaque = @ptrCast(dib[pixel_offset..].ptr);
    var bitmap: ?*win32_backend.GpBitmap = null;
    if (win32_backend.GdipCreateBitmapFromGdiDib(info_ptr, data_ptr, &bitmap) != GDIP_OK) return null;
    const gdip_bitmap = bitmap orelse return null;
    defer _ = win32_backend.GdipDisposeImage(gdip_bitmap);

    if (win32_backend.GdipSaveImageToFile(gdip_bitmap, out_path_w.ptr, &PNG_ENCODER_CLSID, null) != GDIP_OK) return null;
    keep_out_path = true;
    return out_path;
}

fn saveClipboardImageToTemp(allocator: std.mem.Allocator) ?[]u8 {
    const hmem = win32_backend.GetClipboardData(CF_DIBV5) orelse win32_backend.GetClipboardData(CF_DIB) orelse return null;
    return saveClipboardDibAsPng(allocator, hmem);
}

fn pasteSavedClipboardImage(surface: *Surface, allocator: std.mem.Allocator, image_path: []const u8) bool {
    const target_path = imagePathForSurfacePaste(allocator, surface, image_path) orelse return false;
    defer allocator.free(target_path);

    const pasted = quotePathForPaste(allocator, target_path) orelse return false;
    defer allocator.free(pasted);

    std.debug.print("Pasting clipboard image path: {s}\n", .{target_path});
    writePasteToPty(surface, allocator, pasted);
    return true;
}

pub fn handleFileDrop(local_path: []const u8, x: i32, _: i32) bool {
    if (handleFileExplorerDrop(local_path, x)) return true;
    return handleSshTerminalFileDrop(local_path);
}

fn handleFileExplorerDrop(local_path: []const u8, x: i32) bool {
    const win = AppWindow.g_window orelse return false;
    if (!file_explorer.g_visible or file_explorer.g_mode != .remote) return false;

    const panel_x: i32 = win.sidebar_width;
    const panel_right: i32 = panel_x + @as(i32, @intFromFloat(file_explorer.width()));
    if (x < panel_x or x >= panel_right) return false;

    file_explorer.uploadFile(local_path);
    return true;
}

fn handleSshTerminalFileDrop(local_path: []const u8) bool {
    const surface = AppWindow.activeSurface() orelse return false;
    if (surface.launch_kind != .ssh) return false;
    const conn = surface.ssh_connection orelse return false;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const remote_dir_info = if (surface.getCwd()) |cwd|
        resolveSshDropRemoteDir(allocator, cwd, "") catch return true
    else blk: {
        const pwd = scp.sshExec(allocator, &conn, "pwd") orelse {
            std.debug.print("SSH file drop upload skipped: no remote cwd for active SSH surface\n", .{});
            return true;
        };
        defer allocator.free(pwd);
        break :blk resolveSshDropRemoteDir(allocator, null, pwd) catch return true;
    };
    defer allocator.free(remote_dir_info.path);
    const remote_dir = remote_dir_info.path;
    if (remote_dir_info.used_fallback_pwd) overlays.showSshCwdFallbackPrompt();

    const filename = clipboardImageBasename(local_path);
    if (filename.len == 0) return true;

    const remote_path = joinUnixPath(allocator, remote_dir, filename) orelse return true;
    defer allocator.free(remote_path);

    var spec_buf: [512]u8 = undefined;
    const destination = scp.remoteSpec(&spec_buf, &conn, remote_dir);
    std.debug.print("SSH file drop upload: {s} -> {s}\n", .{ local_path, destination });
    if (!file_explorer.uploadLocalFileToRemoteSpec(local_path, destination, filename, &conn)) {
        std.debug.print("SSH file drop upload failed to start\n", .{});
        return true;
    }

    const pasted = shellSingleQuoteForPaste(allocator, remote_path) orelse return true;
    defer allocator.free(pasted);
    writePasteToPty(surface, allocator, pasted);
    return true;
}

// --- Clipboard (Win32 native) ---

fn selectionSurfaceForClipboard() ?*Surface {
    if (AppWindow.activeTab()) |tb| {
        var selected_surface: ?*Surface = null;
        var it = tb.tree.iterator();
        while (it.next()) |entry| {
            if (!entry.surface.selection.active) continue;
            if (entry.handle == tb.focused) return entry.surface;
            if (selected_surface == null) selected_surface = entry.surface;
        }
        if (selected_surface) |surface| return surface;
    }
    return AppWindow.activeSurface();
}

pub fn activeTerminalSelectionExists() bool {
    const surface = selectionSurfaceForClipboard() orelse return false;
    return surface.selection.active;
}

pub fn handleConfiguredRightClick() void {
    switch (AppWindow.g_right_click_action) {
        .ignore => {},
        .copy => copySelectionToClipboard(),
        .paste => pasteFromClipboard(),
        .copy_or_paste => {
            if (activeTerminalSelectionExists()) {
                copySelectionToClipboard();
            } else {
                pasteFromClipboard();
            }
        },
    }
}

pub fn copyTextToClipboard(text: []const u8) bool {
    const allocator = AppWindow.g_allocator orelse return false;
    const win = AppWindow.g_window orelse return false;
    if (text.len == 0) return false;

    const utf16 = std.unicode.utf8ToUtf16LeAllocZ(allocator, text) catch return false;
    defer allocator.free(utf16);

    // Win32 clipboard takes ownership of the moveable global handle after SetClipboardData.
    if (win32_backend.OpenClipboard(win.hwnd) == 0) return false;
    defer _ = win32_backend.CloseClipboard();
    _ = win32_backend.EmptyClipboard();

    const size = (utf16.len + 1) * @sizeOf(u16);
    const hmem = win32_backend.GlobalAlloc(0x0002, size) orelse return false; // GMEM_MOVEABLE
    const ptr = win32_backend.GlobalLock(hmem) orelse return false;
    const dest: [*]u16 = @ptrCast(@alignCast(ptr));
    @memcpy(dest[0..utf16.len], utf16);
    dest[utf16.len] = 0;
    _ = win32_backend.GlobalUnlock(hmem);

    return win32_backend.SetClipboardData(CF_UNICODETEXT, hmem) != null;
}

pub fn copyAiChatToClipboard(chat: *AppWindow.ai_chat.Session) void {
    const allocator = AppWindow.g_allocator orelse return;
    const text = chat.allocClipboardText(allocator) catch return;
    defer allocator.free(text);
    if (text.len == 0) return;
    if (copyTextToClipboard(text)) {
        overlays.showCopyToast(text.len);
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
        std.debug.print("Copied {} AI chat bytes to clipboard\n", .{text.len});
    }
}

pub fn copyAiChatMessageToClipboard(chat: *AppWindow.ai_chat.Session, message_index: usize) void {
    const allocator = AppWindow.g_allocator orelse return;
    const text = chat.allocMessageClipboardText(allocator, message_index) catch return;
    defer allocator.free(text);
    if (text.len == 0) return;
    if (copyTextToClipboard(text)) {
        overlays.showCopyToast(text.len);
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
        std.debug.print("Copied {} AI chat message bytes to clipboard\n", .{text.len});
    }
}

pub fn copySelectionToClipboard() void {
    const surface = selectionSurfaceForClipboard() orelse return;
    const allocator = AppWindow.g_allocator orelse return;

    if (!surface.selection.active) return;

    var start_row = surface.selection.start_row;
    var start_col = surface.selection.start_col;
    var end_row = surface.selection.end_row;
    var end_col = surface.selection.end_col;

    if (start_row > end_row or (start_row == end_row and start_col > end_col)) {
        std.mem.swap(usize, &start_row, &end_row);
        std.mem.swap(usize, &start_col, &end_col);
    }

    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(allocator);

    // Lock while reading terminal cells
    surface.render_state.mutex.lock();
    const screen = surface.terminal.screens.active;
    const grid_cols = @max(@as(usize, 1), @as(usize, @intCast(surface.size.grid.cols)));
    var row: usize = start_row;
    while (row <= end_row) : (row += 1) {
        const row_start_col = if (row == start_row) start_col else 0;
        var row_end_col = if (row == end_row) end_col else grid_cols - 1;
        if (row_start_col >= grid_cols) continue;
        row_end_col = @min(row_end_col, grid_cols - 1);
        if (row_start_col > row_end_col) continue;

        const row_text_start = text.items.len;
        var col: usize = row_start_col;
        while (col <= row_end_col) : (col += 1) {
            const cell_data = screen.pages.getCell(.{ .screen = .{
                .x = @intCast(col),
                .y = @intCast(row),
            } }) orelse continue;

            // Skip spacer cells for wide characters — the actual codepoint
            // lives in the head cell; spacers are layout-only.
            const wide_val: u2 = @intFromEnum(cell_data.cell.wide);
            if (wide_val == 2 or wide_val == 3) continue; // spacer_tail / spacer_head

            const cp = cell_data.cell.codepoint();
            if (cp == 0 or cp == ' ') {
                text.append(allocator, ' ') catch continue;
            } else {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(@intCast(cp), &buf) catch continue;
                text.appendSlice(allocator, buf[0..len]) catch continue;

                // Append grapheme cluster continuation codepoints (emoji ZWJ sequences, etc.)
                if (cell_data.cell.hasGrapheme()) {
                    const page = &cell_data.node.data;
                    if (page.lookupGrapheme(cell_data.cell)) |extra_cps| {
                        for (extra_cps) |ecp| {
                            const elen = std.unicode.utf8Encode(@intCast(ecp), &buf) catch continue;
                            text.appendSlice(allocator, buf[0..elen]) catch {};
                        }
                    }
                }
            }
        }
        text.items.len = row_text_start + selection_unit.trimTrailingClipboardSpaces(text.items[row_text_start..]).len;
        if (row < end_row) {
            text.appendSlice(allocator, "\r\n") catch {};
        }
    }
    surface.render_state.mutex.unlock();

    if (text.items.len == 0) return;

    if (copyTextToClipboard(text.items)) {
        overlays.showCopyToast(text.items.len);
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
        std.debug.print("Copied {} bytes to clipboard\n", .{text.items.len});
    }
}

pub fn pasteFromClipboard() void {
    const surface = AppWindow.activeSurface() orelse return;
    const win = AppWindow.g_window orelse return;
    const allocator = AppWindow.g_allocator orelse return;

    if (win32_backend.OpenClipboard(win.hwnd) == 0) return;
    defer {
        _ = win32_backend.CloseClipboard();
    }

    if (win32_backend.GetClipboardData(CF_UNICODETEXT)) |hmem| {
        const text = readClipboardUnicodeText(allocator, hmem) orelse return;
        defer allocator.free(text);
        if (text.len > 0) {
            std.debug.print("Pasting {} UTF-8 bytes from clipboard\n", .{text.len});
            writePasteToPty(surface, allocator, text);
        }
        return;
    }

    if (win32_backend.GetClipboardData(CF_TEXT)) |hmem| {
        const text = readClipboardAnsiText(allocator, hmem) orelse return;
        defer allocator.free(text);
        if (text.len > 0) {
            std.debug.print("Pasting {} ANSI bytes from clipboard\n", .{text.len});
            writePasteToPty(surface, allocator, text);
        }
        return;
    }
}

pub fn pasteClipboardIntoBrowserUrlBar() bool {
    const win = AppWindow.g_window orelse return false;
    const allocator = AppWindow.g_allocator orelse return false;

    if (win32_backend.OpenClipboard(win.hwnd) == 0) return false;
    defer {
        _ = win32_backend.CloseClipboard();
    }

    if (win32_backend.GetClipboardData(CF_UNICODETEXT)) |hmem| {
        const text = readClipboardUnicodeText(allocator, hmem) orelse return false;
        defer allocator.free(text);
        browser_panel.appendUrlBarText(text);
        return text.len > 0;
    }

    if (win32_backend.GetClipboardData(CF_TEXT)) |hmem| {
        const text = readClipboardAnsiText(allocator, hmem) orelse return false;
        defer allocator.free(text);
        browser_panel.appendUrlBarText(text);
        return text.len > 0;
    }

    return false;
}

pub fn pasteClipboardIntoSessionLauncher() bool {
    const win = AppWindow.g_window orelse return false;
    const allocator = AppWindow.g_allocator orelse return false;

    if (win32_backend.OpenClipboard(win.hwnd) == 0) return false;
    defer {
        _ = win32_backend.CloseClipboard();
    }

    if (win32_backend.GetClipboardData(CF_UNICODETEXT)) |hmem| {
        const text = readClipboardUnicodeText(allocator, hmem) orelse return false;
        defer allocator.free(text);
        return overlays.sessionLauncherPasteText(text);
    }

    if (win32_backend.GetClipboardData(CF_TEXT)) |hmem| {
        const text = readClipboardAnsiText(allocator, hmem) orelse return false;
        defer allocator.free(text);
        return overlays.sessionLauncherPasteText(text);
    }

    return false;
}

pub fn pasteFromClipboardIntoAiChat(chat: *AppWindow.ai_chat.Session) void {
    const win = AppWindow.g_window orelse return;
    const allocator = AppWindow.g_allocator orelse return;

    if (win32_backend.OpenClipboard(win.hwnd) == 0) return;
    defer {
        _ = win32_backend.CloseClipboard();
    }

    if (win32_backend.GetClipboardData(CF_UNICODETEXT)) |hmem| {
        const text = readClipboardUnicodeText(allocator, hmem) orelse return;
        defer allocator.free(text);
        chat.appendInputText(text);
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
        return;
    }

    if (win32_backend.GetClipboardData(CF_TEXT)) |hmem| {
        const text = readClipboardAnsiText(allocator, hmem) orelse return;
        defer allocator.free(text);
        chat.appendInputText(text);
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
        return;
    }
}

pub fn pasteImageFromClipboard() void {
    const surface = AppWindow.activeSurface() orelse return;
    const win = AppWindow.g_window orelse return;
    const allocator = AppWindow.g_allocator orelse return;

    if (win32_backend.OpenClipboard(win.hwnd) == 0) return;
    var clipboard_open = true;
    defer if (clipboard_open) {
        _ = win32_backend.CloseClipboard();
    };

    const image_path = saveClipboardImageToTemp(allocator) orelse return;
    defer allocator.free(image_path);
    _ = win32_backend.CloseClipboard();
    clipboard_open = false;

    _ = pasteSavedClipboardImage(surface, allocator, image_path);
}

pub fn writeTextToActivePty(text: []const u8) void {
    const surface = AppWindow.activeSurface() orelse return;
    writeToPty(surface, text);
}

pub fn writeTextToSurfacePty(surface: *Surface, text: []const u8) void {
    writeToPty(surface, text);
}
