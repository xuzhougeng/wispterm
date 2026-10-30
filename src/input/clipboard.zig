//! Clipboard, paste, and file drop handling for AppWindow input.

const std = @import("std");
const AppWindow = @import("../AppWindow.zig");
const window_backend = @import("../platform/window_backend.zig");
const file_explorer = AppWindow.file_explorer;
const browser_panel = AppWindow.browser_panel;
const overlays = AppWindow.overlays;
const scp = @import("../ssh/scp.zig");
const platform_clipboard = @import("../platform/clipboard.zig");
const platform_remote_file = @import("../platform/remote_file.zig");
const Surface = @import("../Surface.zig");
const ghostty_vt = @import("ghostty-vt");
const file_drop_path = @import("file_drop_path.zig");
const ai_chat_composer_layout = @import("../assistant/conversation/composer_layout.zig");
const i18n = @import("../i18n.zig");

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
    if (data.len == 0) return;

    // Like Ghostty's completeClipboardPaste, snapshot the negotiated mode under
    // the same lock used by the PTY reader. Release it before allocating or
    // waiting for mailbox capacity so output processing can keep progressing.
    const bracketed = bracketed: {
        surface.render_state.mutex.lock();
        defer surface.render_state.mutex.unlock();
        break :bracketed surface.terminal.modes.get(.bracketed_paste);
    };
    pty_write_log.debug("paste: bracketed={} bytes={d}", .{ bracketed, data.len });

    if (bracketed) {
        // A paste is one input transaction. Three independent queue writes can
        // lose a fencepost under backpressure or interleave a terminal reply
        // with the body. Queue the entire frame or deliver none of it.
        const start = "\x1b[200~";
        const end = "\x1b[201~";
        const framed = std.mem.concat(allocator, u8, &.{ start, data, end }) catch |err| {
            pty_write_log.warn("could not encode paste: {s}", .{@errorName(err)});
            return;
        };
        defer allocator.free(framed);
        mutatePasteData(framed[start.len .. framed.len - end.len], true);
        writeToPty(surface, framed);
        return;
    }

    var owned: ?[]u8 = null;
    var body = data;
    if (pasteNeedsMutation(data, false)) {
        owned = allocator.dupe(u8, data) catch |err| {
            pty_write_log.warn("could not encode paste: {s}", .{@errorName(err)});
            return;
        };
        mutatePasteData(owned.?, false);
        body = owned.?;
    }
    defer {
        if (owned) |buf| allocator.free(buf);
    }

    writeToPty(surface, body);
}

fn initPasteTestSurface(surface: *Surface) !void {
    surface.allocator = std.testing.allocator;
    surface.terminal = try ghostty_vt.Terminal.init(std.testing.allocator, .{ .cols = 80, .rows = 24 });
    errdefer surface.terminal.deinit(std.testing.allocator);
    surface.render_state = @import("../renderer/State.zig").init(&surface.terminal);
    surface.mailbox = try @import("../termio/Mailbox.zig").init();
    surface.io_state_mutex = .{};
    surface.io_state = .running;
    surface.exited = std.atomic.Value(bool).init(false);
}

fn expectPasteTestWrite(surface: *Surface, expected: []const u8) !void {
    const msg = surface.mailbox.popWrite() orelse return error.MissingPaste;
    defer msg.deinit();
    switch (msg) {
        .write_small => |*payload| try std.testing.expectEqualStrings(expected, payload.data[0..payload.len]),
        .write_alloc => |payload| try std.testing.expectEqualStrings(expected, payload.data),
        else => return error.UnexpectedMessage,
    }
    try std.testing.expect(surface.mailbox.popWrite() == null);
}

test "paste uses negotiated mode and queues complete Vim multiline paste (issue 632)" {
    var surface: Surface = undefined;
    try initPasteTestSurface(&surface);
    defer surface.terminal.deinit(std.testing.allocator);
    defer surface.mailbox.deinit();
    var stream = Surface.VtStream.initAlloc(std.testing.allocator, Surface.VtHandler.init(&surface.terminal, &surface));
    defer stream.deinit();

    // Enable as Vim does, including a PTY read split in the middle of DECSET.
    stream.nextSlice("\x1b[?20");
    stream.nextSlice("04h");
    const script = "#SBATCH -w node01\n#SBATCH -c 24\n\nset -euo pipefail\n\n" ++
        "for f in \"$A\" \"$B\"; do\n    [[ -s \"$f\" ]] || exit 1\ndone\n";
    writePasteToPty(&surface, std.testing.allocator, script);
    try expectPasteTestWrite(&surface, "\x1b[200~" ++ script ++ "\x1b[201~");

    // Leaving Vim must restore ordinary paste, including LF -> CR conversion.
    stream.nextSlice("\x1b[?2004l");
    writePasteToPty(&surface, std.testing.allocator, "one\ntwo\n");
    try expectPasteTestWrite(&surface, "one\rtwo\r");
}

test "large bracketed paste retains framing and sanitizes embedded escape bytes" {
    var surface: Surface = undefined;
    try initPasteTestSurface(&surface);
    defer surface.terminal.deinit(std.testing.allocator);
    defer surface.mailbox.deinit();
    surface.terminal.modes.set(.bracketed_paste, true);

    const body = "  # comment\n\n" ** 40;
    writePasteToPty(&surface, std.testing.allocator, body ++ "\x1b[201~\x03");
    try expectPasteTestWrite(&surface, "\x1b[200~" ++ body ++ " [201~ \x1b[201~");
}

test "bracketed paste fits the last mailbox slot without losing its body or end marker" {
    var surface: Surface = undefined;
    try initPasteTestSurface(&surface);
    defer surface.terminal.deinit(std.testing.allocator);
    defer surface.mailbox.deinit();
    surface.terminal.modes.set(.bracketed_paste, true);

    const Message = @import("../termio/message.zig").Message;
    const filler = try Message.writeReq(std.testing.allocator, "x");
    var queued: usize = 0;
    while (surface.mailbox.sendWrite(filler) == .queued) queued += 1;
    const first = surface.mailbox.popWrite() orelse return error.MissingFiller;
    first.deinit();
    queued -= 1;

    writePasteToPty(&surface, std.testing.allocator, "#SBATCH\n\n    command\n");
    for (0..queued) |_| {
        const msg = surface.mailbox.popWrite() orelse return error.MissingFiller;
        msg.deinit();
    }
    try expectPasteTestWrite(&surface, "\x1b[200~#SBATCH\n\n    command\n\x1b[201~");
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
    if (handleFileExplorerDrop(local_path, x, y)) return true;
    if (handleAiChatFileDrop(local_path, x, y)) return true;
    return handleSshTerminalFileDrop(local_path);
}

fn handleAiChatFileDrop(local_path: []const u8, x: i32, y: i32) bool {
    const allocator = std.heap.page_allocator;
    const text = file_drop_path.formatDroppedPath(allocator, local_path) catch return false;
    defer allocator.free(text);
    return AppWindow.appendDroppedPathToChatAtPoint(text, x, y);
}

fn handleFileExplorerDrop(local_path: []const u8, x: i32, y: i32) bool {
    const win = AppWindow.g_window orelse return false;
    if (file_explorer.g_mode != .remote) return false;

    // Beside the sidebar or in the right dock: one shared panel rect.
    const size = window_backend.clientSize(win);
    const rect = AppWindow.fileExplorerPanelRect(size.width, size.height) orelse return false;
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    if (fx < rect.left or fx >= rect.right or fy < rect.top) return false;

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

/// Owned text of the given surface's active selection, or null when the
/// surface has no active selection or the selection is empty. Caller frees.
/// Holds the surface render-state lock while reading cells, so call it on the
/// UI thread only.
pub fn allocSelectionText(allocator: std.mem.Allocator, surface: *Surface) ?[]u8 {
    if (!surface.selection.active) return null;

    var start_row = surface.selection.start_row;
    var start_col = surface.selection.start_col;
    var end_row = surface.selection.end_row;
    var end_col = surface.selection.end_col;

    if (start_row > end_row or (start_row == end_row and start_col > end_col)) {
        std.mem.swap(usize, &start_row, &end_row);
        std.mem.swap(usize, &start_col, &end_col);
    }

    surface.render_state.mutex.lock();
    defer surface.render_state.mutex.unlock();
    const text = allocScreenSelectionText(
        allocator,
        surface.terminal.screens.active,
        start_col,
        start_row,
        end_col,
        end_row,
    ) orelse return null;
    if (text.len == 0) {
        allocator.free(text);
        return null;
    }
    return text;
}

fn allocScreenSelectionText(
    allocator: std.mem.Allocator,
    screen: *ghostty_vt.Screen,
    start_col: usize,
    start_row: usize,
    end_col: usize,
    end_row: usize,
) ?[]u8 {
    const start = screen.pages.pin(.{ .screen = .{
        .x = @intCast(start_col),
        .y = @intCast(start_row),
    } }) orelse return null;
    const end = screen.pages.pin(.{ .screen = .{
        .x = @intCast(end_col),
        .y = @intCast(end_row),
    } }) orelse return null;
    const text = screen.selectionString(allocator, .{
        .sel = ghostty_vt.Selection.init(start, end, false),
        .trim = false,
    }) catch return null;
    defer allocator.free(text);
    return std.mem.replaceOwned(u8, allocator, text, "\n", "\r\n") catch null;
}

/// Owned text of the active terminal selection (the focused surface's, or any
/// selected surface in the active tab), or null when nothing is selected.
/// Caller frees.
pub fn allocActiveSelectionText(allocator: std.mem.Allocator) ?[]u8 {
    const surface = selectionSurfaceForClipboard() orelse return null;
    return allocSelectionText(allocator, surface);
}

pub fn copySelectionToClipboard() void {
    const surface = selectionSurfaceForClipboard() orelse return;
    const allocator = AppWindow.g_allocator orelse return;

    const text = allocSelectionText(allocator, surface) orelse return;
    defer allocator.free(text);

    if (copyTextToClipboard(text)) {
        overlays.showCopyToast(text.len);
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
        std.debug.print("Copied {} bytes to clipboard\n", .{text.len});
    }
}

pub fn pasteFromClipboard() void {
    _ = pasteClipboardTextToActiveSurface();
}

/// Returns false when the clipboard held no text to paste.
fn pasteClipboardTextToActiveSurface() bool {
    const surface = AppWindow.activeSurface() orelse return false;
    const allocator = AppWindow.g_allocator orelse return false;
    const text = readClipboardText(allocator) orelse return false;
    defer allocator.free(text);

    if (text.len == 0) return false;
    std.debug.print("Pasting {} UTF-8 bytes from clipboard\n", .{text.len});
    writePasteToPty(surface, allocator, text);
    return true;
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

pub fn pasteClipboardIntoMcpForm() bool {
    const allocator = AppWindow.g_allocator orelse return false;
    const text = readClipboardText(allocator) orelse return false;
    defer allocator.free(text);

    return overlays.mcpServersPasteText(text);
}

pub fn pasteClipboardIntoPasswordStore() bool {
    const allocator = AppWindow.g_allocator orelse return false;
    const text = readClipboardText(allocator) orelse return false;
    defer {
        // The clipboard often holds the password being pasted.
        std.crypto.secureZero(u8, text);
        allocator.free(text);
    }
    return AppWindow.passwordStorePaste(text);
}

pub fn pasteClipboardIntoSyncPage() bool {
    const allocator = AppWindow.g_allocator orelse return false;
    const text = readClipboardText(allocator) orelse return false;
    defer {
        // Often the WebDAV app password or the sync passphrase.
        std.crypto.secureZero(u8, text);
        allocator.free(text);
    }
    return AppWindow.syncPagePaste(text);
}

pub fn pasteFromClipboardIntoAiChat(chat: *AppWindow.ai_chat.Session) void {
    _ = appendClipboardTextToAiChat(chat);
}

/// Returns false when the clipboard held no text to paste.
fn appendClipboardTextToAiChat(chat: *AppWindow.ai_chat.Session) bool {
    const allocator = AppWindow.g_allocator orelse return false;
    const text = readClipboardText(allocator) orelse return false;
    defer allocator.free(text);

    if (text.len == 0) return false;
    chat.appendInputText(text);
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
    return true;
}

/// Outcome of routing a pasted clipboard image to an AI chat composer.
pub const PastedImageOutcome = enum {
    attached,
    ignored_no_vision,
    too_large,
    /// The clipboard held an image, but it could not be read or attached.
    failed,
    /// The clipboard held no image; the caller falls back to text paste.
    no_image,
};

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

/// Toast for a Paste Image press in an AI chat composer, or null when the
/// composer already shows the result (the attached image's placeholder). Every
/// other outcome leaves the composer unchanged or holding text, so without a
/// toast an image-less clipboard looked exactly like a key that never landed.
pub fn pastedImageToast(outcome: PastedImageOutcome, pasted_text: bool, strings: *const i18n.Strings) ?[]const u8 {
    return switch (outcome) {
        .attached => null,
        .ignored_no_vision => strings.toast_paste_image_no_vision,
        .too_large => strings.toast_paste_image_too_large,
        .failed => strings.toast_paste_image_failed,
        .no_image => if (pasted_text) strings.toast_paste_image_pasted_text else strings.toast_paste_image_empty,
    };
}

test "pastedImageToast reports every outcome the composer does not show" {
    defer i18n.setLang(.en);
    i18n.setLang(.en);
    const en = i18n.s();
    try std.testing.expectEqual(@as(?[]const u8, null), pastedImageToast(.attached, false, en));
    try std.testing.expectEqualStrings(en.toast_paste_image_empty, pastedImageToast(.no_image, false, en).?);
    try std.testing.expectEqualStrings(en.toast_paste_image_pasted_text, pastedImageToast(.no_image, true, en).?);
    try std.testing.expectEqualStrings(en.toast_paste_image_failed, pastedImageToast(.failed, false, en).?);
    try std.testing.expectEqualStrings(en.toast_paste_image_too_large, pastedImageToast(.too_large, false, en).?);
    try std.testing.expectEqualStrings(en.toast_paste_image_no_vision, pastedImageToast(.ignored_no_vision, false, en).?);

    i18n.setLang(.zh_CN);
    try std.testing.expectEqualStrings("剪贴板里没有图片或文本", pastedImageToast(.no_image, false, i18n.s()).?);
}

test "encodeImageBase64 produces standard base64" {
    const out = try encodeImageBase64(std.testing.allocator, "ABC");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("QUJD", out);
}

/// Paste Image (Ctrl/Cmd+Shift+V) in an AI chat composer: attach the clipboard
/// image, else fall back to ordinary text paste, and toast whatever the
/// composer does not show by itself.
pub fn pasteImageOrTextIntoAiChat(chat: *AppWindow.ai_chat.Session) void {
    const outcome = pasteImageIntoAiChat(chat);
    const pasted_text = outcome == .no_image and appendClipboardTextToAiChat(chat);
    if (pastedImageToast(outcome, pasted_text, i18n.s())) |message| overlays.showStatusToast(message);
}

fn pasteImageIntoAiChat(chat: *AppWindow.ai_chat.Session) PastedImageOutcome {
    const allocator = AppWindow.g_allocator orelse return .no_image;
    const owner = clipboardOwner() orelse return .no_image;

    const image_path = platform_clipboard.readImageAsPngTemp(allocator, owner) orelse return .no_image;
    defer allocator.free(image_path);
    // The temp PNG belongs to us once read; remove it either way.
    defer std.fs.deleteFileAbsolute(image_path) catch {};

    const max_bytes = AppWindow.ai_chat.MAX_PASTED_IMAGE_BYTES;
    const bytes = std.fs.cwd().readFileAlloc(allocator, image_path, max_bytes + 1) catch |err| {
        std.debug.print("Chat image paste: could not read {s}: {s}\n", .{ image_path, @errorName(err) });
        return .failed;
    };
    defer allocator.free(bytes);

    const outcome = classifyPastedImage(chat.vision_enabled, bytes.len, max_bytes);
    switch (outcome) {
        .too_large => {
            std.debug.print("Chat image paste: image is {d} bytes, exceeds {d} cap — ignored\n", .{ bytes.len, max_bytes });
        },
        .ignored_no_vision => {
            std.debug.print("Chat image paste: vision disabled for this model \xe2\x80\x94 image ignored ({d} bytes)\n", .{bytes.len});
        },
        .attached => {
            const b64 = encodeImageBase64(allocator, bytes) catch return .failed;
            defer allocator.free(b64);
            chat.addPendingImage(b64, "image/png") catch {
                std.debug.print("Chat image paste: out of memory attaching image\n", .{});
                return .failed;
            };
            std.debug.print("Chat image paste: attached image ({d} bytes, {d} pending)\n", .{ bytes.len, chat.pendingImageCount() });
            var placeholder_buf: [32]u8 = undefined;
            if (ai_chat_composer_layout.pendingImagePlaceholder(chat.pendingImageCount(), &placeholder_buf)) |placeholder| {
                chat.appendInputText(placeholder);
            }
            AppWindow.g_force_rebuild = true;
            AppWindow.g_cells_valid = false;
        },
        .failed, .no_image => unreachable,
    }
    return outcome;
}

/// Paste Image in a terminal: paste the clipboard image's path, else fall back
/// to clipboard text. Ctrl+Shift+V doubles as a plain-text paste chord in many
/// terminals, so the text fallback stays quiet; only a press that pastes
/// nothing at all gets a toast.
pub fn pasteImageOrTextIntoTerminal() void {
    if (AppWindow.activeSurface() == null) return;
    if (pasteImageFromClipboard()) return;
    if (pasteClipboardTextToActiveSurface()) return;
    overlays.showStatusToast(i18n.s().toast_paste_image_empty);
}

/// Returns false only when the clipboard does not contain an image, allowing
/// Ctrl+Shift+V to fall back to ordinary text paste.
pub fn pasteImageFromClipboard() bool {
    const surface = AppWindow.activeSurface() orelse return false;
    const allocator = AppWindow.g_allocator orelse return false;
    const owner = clipboardOwner() orelse return false;

    const image_path = platform_clipboard.readImageAsPngTemp(allocator, owner) orelse return false;
    defer allocator.free(image_path);

    _ = pasteSavedClipboardImage(surface, allocator, image_path);
    return true;
}

pub fn writeTextToActivePty(text: []const u8) void {
    const surface = AppWindow.activeSurface() orelse return;
    writeToPty(surface, text);
}

pub fn writeTextToSurfacePty(surface: *Surface, text: []const u8) void {
    writeToPty(surface, text);
}

test "terminal selection copy unwraps visual line wrapping (issue 595)" {
    var terminal = try ghostty_vt.Terminal.init(std.testing.allocator, .{
        .cols = 8,
        .rows = 6,
        .max_scrollback = 64,
    });
    defer terminal.deinit(std.testing.allocator);

    var stream = terminal.vtStream();
    defer stream.deinit();
    const line = "PowerShell-long-output-remains-continuous";
    stream.nextSlice(line);

    const last = line.len - 1;
    const copied = allocScreenSelectionText(
        std.testing.allocator,
        terminal.screens.active,
        0,
        0,
        last % 8,
        last / 8,
    ) orelse return error.ExpectedSelectionText;
    defer std.testing.allocator.free(copied);

    try std.testing.expectEqualStrings(line, copied);
}

test "terminal selection copy preserves hard line breaks as CRLF" {
    var terminal = try ghostty_vt.Terminal.init(std.testing.allocator, .{
        .cols = 16,
        .rows = 3,
        .max_scrollback = 0,
    });
    defer terminal.deinit(std.testing.allocator);

    var stream = terminal.vtStream();
    defer stream.deinit();
    stream.nextSlice("first\r\nsecond");

    const copied = allocScreenSelectionText(
        std.testing.allocator,
        terminal.screens.active,
        0,
        0,
        "second".len - 1,
        1,
    ) orelse return error.ExpectedSelectionText;
    defer std.testing.allocator.free(copied);

    try std.testing.expectEqualStrings("first\r\nsecond", copied);
}
