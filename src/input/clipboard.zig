//! Clipboard, paste, and file drop handling for AppWindow input.

const std = @import("std");
const AppWindow = @import("../AppWindow.zig");
const file_explorer = AppWindow.file_explorer;
const browser_panel = AppWindow.browser_panel;
const overlays = AppWindow.overlays;
const scp = @import("../ssh/scp.zig");
const platform_clipboard = @import("../platform/clipboard.zig");
const platform_remote_file = @import("../platform/remote_file.zig");
const Surface = @import("../Surface.zig");
const selection_unit = @import("../selection_unit.zig");
const file_drop_path = @import("file_drop_path.zig");
const ai_chat_composer_layout = @import("../assistant/conversation/composer_layout.zig");

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

const pty_write_log = std.log.scoped(.pty_write);

/// Write data to the PTY's input pipe (us -> child stdin).
///
/// This is the keyboard/paste input boundary, so it is intentionally
/// fire-and-forget: there is no caller positioned to recover from backpressure.
/// queuePtyWrite still surfaces its outcome — on failure we log a visible
/// warning instead of silently swallowing input.
pub fn writeToPty(surface: *Surface, data: []const u8) void {
    surface.queuePtyWrite(data) catch |err| pty_write_log.warn(
        "dropped {d} bytes of input: {s}",
        .{ data.len, @errorName(err) },
    );
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

fn quotePathForPaste(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    if (std.mem.indexOfAny(u8, path, " \t\"") == null) return allocator.dupe(u8, path) catch null;
    return std.fmt.allocPrint(allocator, "\"{s}\"", .{path}) catch null;
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
        .ssh => return uploadClipboardImageForSsh(allocator, surface, path),
        .local, .wsl => return platform_remote_file.localPathForTerminalPaste(allocator, surface.launch_kind, path),
    }
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

const DeferredSshDropPaste = struct {
    allocator: std.mem.Allocator,
    surface_allocator: std.mem.Allocator,
    surface: *Surface,
    text: []u8,
};

fn deferredSshDropPasteSuccess(ctx: ?*anyopaque) void {
    const pending: *DeferredSshDropPaste = @ptrCast(@alignCast(ctx orelse return));
    writePasteToPty(pending.surface, pending.allocator, pending.text);
}

fn deferredSshDropPasteDestroy(ctx: ?*anyopaque) void {
    const pending: *DeferredSshDropPaste = @ptrCast(@alignCast(ctx orelse return));
    pending.surface.unref(pending.surface_allocator);
    pending.allocator.free(pending.text);
    pending.allocator.destroy(pending);
}

fn createDeferredSshDropPaste(surface: *Surface, text: []const u8) ?*DeferredSshDropPaste {
    const allocator = std.heap.page_allocator;
    const pending = allocator.create(DeferredSshDropPaste) catch return null;
    const owned_text = allocator.dupe(u8, text) catch {
        allocator.destroy(pending);
        return null;
    };
    pending.* = .{
        .allocator = allocator,
        .surface_allocator = surface.allocator,
        .surface = surface.ref(),
        .text = owned_text,
    };
    return pending;
}

pub fn handleFileDrop(local_path: []const u8, x: i32, y: i32) bool {
    if (handleFileExplorerDrop(local_path, x)) return true;
    if (handleAiChatFileDrop(local_path, x, y)) return true;
    return handleSshTerminalFileDrop(local_path);
}

fn handleAiChatFileDrop(local_path: []const u8, x: i32, y: i32) bool {
    const allocator = std.heap.page_allocator;
    const text = file_drop_path.formatDroppedPath(allocator, local_path) catch return false;
    defer allocator.free(text);
    return AppWindow.appendDroppedPathToChatAtPoint(text, x, y);
}

fn handleFileExplorerDrop(local_path: []const u8, x: i32) bool {
    const win = AppWindow.g_window orelse return false;
    if (!file_explorer.isVisibleForActiveTab() or file_explorer.g_mode != .remote) return false;

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

    const pasted = shellSingleQuoteForPaste(allocator, remote_path) orelse return true;
    defer allocator.free(pasted);

    const pending_paste = createDeferredSshDropPaste(surface, pasted) orelse return true;
    if (!file_explorer.uploadLocalFileToRemoteSpecWithCompletion(local_path, destination, filename, &conn, .{
        .context = pending_paste,
        .on_success = deferredSshDropPasteSuccess,
        .on_destroy = deferredSshDropPasteDestroy,
    })) {
        std.debug.print("SSH file drop upload failed to start\n", .{});
        return true;
    }

    return true;
}

// --- Clipboard (native window owner) ---

fn selectionSurfaceForClipboard() ?*Surface {
    if (AppWindow.activeTab()) |tb| {
        var selected_surface: ?*Surface = null;
        var it = tb.tree.surfaces();
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

fn clipboardOwner() ?platform_clipboard.Owner {
    const handle_bits = AppWindow.currentNativeHandleBits() orelse return null;
    return platform_clipboard.windowOwner(handle_bits);
}

fn readClipboardText(allocator: std.mem.Allocator) ?[]u8 {
    const owner = clipboardOwner() orelse return null;
    return platform_clipboard.readText(allocator, owner);
}

/// Public: read the system clipboard as owned text (caller frees), or null.
pub fn readClipboardTextOwned(allocator: std.mem.Allocator) ?[]u8 {
    return readClipboardText(allocator);
}

pub fn copyTextToClipboard(text: []const u8) bool {
    const allocator = AppWindow.g_allocator orelse return false;
    const owner = clipboardOwner() orelse return false;
    if (text.len == 0) return false;
    return platform_clipboard.writeText(allocator, owner, text);
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

pub fn copyAiChatCutToClipboard(chat: *AppWindow.ai_chat.Session) void {
    const allocator = AppWindow.g_allocator orelse return;
    const maybe_text = chat.cutInputSelection(allocator) catch return;
    const text = maybe_text orelse return;
    defer allocator.free(text);
    if (text.len == 0) return;
    if (copyTextToClipboard(text)) {
        overlays.showCopyToast(text.len);
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
        std.debug.print("Cut {} AI chat input bytes to clipboard\n", .{text.len});
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

/// Copy a single code block or table (a byte sub-range of a message) located by
/// the renderer's per-block copy button.
pub fn copyAiChatSpanToClipboard(chat: *AppWindow.ai_chat.Session, message_index: usize, start: usize, end: usize) void {
    const allocator = AppWindow.g_allocator orelse return;
    const text = chat.allocMessageSpanText(allocator, message_index, start, end) catch return;
    defer allocator.free(text);
    if (text.len == 0) return;
    if (copyTextToClipboard(text)) {
        overlays.showCopyToast(text.len);
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
        std.debug.print("Copied {} AI chat block bytes to clipboard\n", .{text.len});
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

    // Collect each selected row's text plus its soft-wrap flag, then join.
    // Soft-wrapped rows (a visually wrapped logical line, e.g. a long path)
    // must copy back as a single line — see selection_unit.joinSelectionRows.
    var rows: std.ArrayListUnmanaged(selection_unit.SelectionRow) = .empty;
    defer {
        for (rows.items) |r| allocator.free(r.text);
        rows.deinit(allocator);
    }

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

        var row_buf: std.ArrayListUnmanaged(u8) = .empty;
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
                row_buf.append(allocator, ' ') catch continue;
            } else {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(@intCast(cp), &buf) catch continue;
                row_buf.appendSlice(allocator, buf[0..len]) catch continue;

                // Append grapheme cluster continuation codepoints (emoji ZWJ sequences, etc.)
                if (cell_data.cell.hasGrapheme()) {
                    const page = &cell_data.node.data;
                    if (page.lookupGrapheme(cell_data.cell)) |extra_cps| {
                        for (extra_cps) |ecp| {
                            const elen = std.unicode.utf8Encode(@intCast(ecp), &buf) catch continue;
                            row_buf.appendSlice(allocator, buf[0..elen]) catch {};
                        }
                    }
                }
            }
        }

        // Read the soft-wrap flag in the same .screen coordinate space as the
        // cells above so it stays correct when the viewport is scrolled.
        const wraps_next = wn: {
            const pin = screen.pages.pin(.{ .screen = .{
                .x = 0,
                .y = @intCast(row),
            } }) orelse break :wn false;
            break :wn pin.rowAndCell().row.wrap;
        };

        const owned = row_buf.toOwnedSlice(allocator) catch {
            row_buf.deinit(allocator);
            continue;
        };
        rows.append(allocator, .{ .text = owned, .wraps_next = wraps_next }) catch {
            allocator.free(owned);
            continue;
        };
    }
    surface.render_state.mutex.unlock();

    const text = selection_unit.joinSelectionRows(allocator, rows.items) catch return;
    defer allocator.free(text);

    if (text.len == 0) return;

    if (copyTextToClipboard(text)) {
        overlays.showCopyToast(text.len);
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
        std.debug.print("Copied {} bytes to clipboard\n", .{text.len});
    }
}

pub fn pasteFromClipboard() void {
    const surface = AppWindow.activeSurface() orelse return;
    const allocator = AppWindow.g_allocator orelse return;
    const text = readClipboardText(allocator) orelse return;
    defer allocator.free(text);

    if (text.len > 0) {
        std.debug.print("Pasting {} UTF-8 bytes from clipboard\n", .{text.len});
        writePasteToPty(surface, allocator, text);
    }
}

pub fn pasteClipboardIntoBrowserUrlBar() bool {
    const allocator = AppWindow.g_allocator orelse return false;
    const text = readClipboardText(allocator) orelse return false;
    defer allocator.free(text);

    browser_panel.appendUrlBarText(text);
    return text.len > 0;
}

pub fn pasteClipboardIntoSessionLauncher() bool {
    const allocator = AppWindow.g_allocator orelse return false;
    const text = readClipboardText(allocator) orelse return false;
    defer allocator.free(text);

    return overlays.sessionLauncherPasteText(text);
}

pub fn pasteFromClipboardIntoAiChat(chat: *AppWindow.ai_chat.Session) void {
    const allocator = AppWindow.g_allocator orelse return;
    const text = readClipboardText(allocator) orelse return;
    defer allocator.free(text);

    chat.appendInputText(text);
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
}

/// Outcome of routing a pasted clipboard image to an AI chat composer.
pub const PastedImageOutcome = enum { attached, ignored_no_vision, too_large };

/// Decide what to do with a pasted image given the model's vision flag and the
/// decoded byte size. The size cap takes precedence so an oversized payload is
/// always rejected, vision or not.
pub fn classifyPastedImage(vision_enabled: bool, byte_len: usize, max_bytes: usize) PastedImageOutcome {
    if (byte_len > max_bytes) return .too_large;
    if (!vision_enabled) return .ignored_no_vision;
    return .attached;
}

test "classifyPastedImage routes by vision flag and size cap" {
    try std.testing.expectEqual(PastedImageOutcome.attached, classifyPastedImage(true, 100, 1000));
    try std.testing.expectEqual(PastedImageOutcome.ignored_no_vision, classifyPastedImage(false, 100, 1000));
    try std.testing.expectEqual(PastedImageOutcome.too_large, classifyPastedImage(true, 2000, 1000));
    // The size cap is checked before the vision flag.
    try std.testing.expectEqual(PastedImageOutcome.too_large, classifyPastedImage(false, 2000, 1000));
}

fn encodeImageBase64(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const out = try allocator.alloc(u8, encoder.calcSize(bytes.len));
    _ = encoder.encode(out, bytes);
    return out;
}

test "encodeImageBase64 produces standard base64" {
    const out = try encodeImageBase64(std.testing.allocator, "ABC");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("QUJD", out);
}

/// Ctrl+Shift+V target when an AI chat composer is focused: read a clipboard
/// image, and either attach it to the composer (vision models) or drop it with a
/// log + toast (non-vision models / oversized images).
pub fn pasteImageIntoAiChat(chat: *AppWindow.ai_chat.Session) void {
    const allocator = AppWindow.g_allocator orelse return;
    const owner = clipboardOwner() orelse return;

    const image_path = platform_clipboard.readImageAsPngTemp(allocator, owner) orelse return;
    defer allocator.free(image_path);
    // The temp PNG belongs to us once read; remove it either way.
    defer std.fs.deleteFileAbsolute(image_path) catch {};

    const max_bytes = AppWindow.ai_chat.MAX_PASTED_IMAGE_BYTES;
    const bytes = std.fs.cwd().readFileAlloc(allocator, image_path, max_bytes + 1) catch |err| {
        std.debug.print("Chat image paste: could not read {s}: {s}\n", .{ image_path, @errorName(err) });
        return;
    };
    defer allocator.free(bytes);

    switch (classifyPastedImage(chat.vision_enabled, bytes.len, max_bytes)) {
        .too_large => {
            std.debug.print("Chat image paste: image is {d} bytes, exceeds {d} cap — ignored\n", .{ bytes.len, max_bytes });
            overlays.showStatusToast("Image too large \xe2\x80\x94 ignored");
        },
        .ignored_no_vision => {
            std.debug.print("Chat image paste: vision disabled for this model \xe2\x80\x94 image ignored ({d} bytes)\n", .{bytes.len});
            overlays.showStatusToast("Vision off for this model \xe2\x80\x94 image ignored");
        },
        .attached => {
            const b64 = encodeImageBase64(allocator, bytes) catch return;
            defer allocator.free(b64);
            chat.addPendingImage(b64, "image/png") catch {
                std.debug.print("Chat image paste: out of memory attaching image\n", .{});
                return;
            };
            std.debug.print("Chat image paste: attached image ({d} bytes, {d} pending)\n", .{ bytes.len, chat.pendingImageCount() });
            var placeholder_buf: [32]u8 = undefined;
            if (ai_chat_composer_layout.pendingImagePlaceholder(chat.pendingImageCount(), &placeholder_buf)) |placeholder| {
                chat.appendInputText(placeholder);
            }
            AppWindow.g_force_rebuild = true;
            AppWindow.g_cells_valid = false;
        },
    }
}

pub fn pasteImageFromClipboard() void {
    const surface = AppWindow.activeSurface() orelse return;
    const allocator = AppWindow.g_allocator orelse return;
    const owner = clipboardOwner() orelse return;

    const image_path = platform_clipboard.readImageAsPngTemp(allocator, owner) orelse return;
    defer allocator.free(image_path);

    _ = pasteSavedClipboardImage(surface, allocator, image_path);
}

pub fn writeTextToActivePty(text: []const u8) void {
    const surface = AppWindow.activeSurface() orelse return;
    writeToPty(surface, text);
}

pub fn writeTextToSurfacePty(surface: *Surface, text: []const u8) void {
    writeToPty(surface, text);
}
