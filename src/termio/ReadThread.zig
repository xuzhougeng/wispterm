/// Blocking PTY reader thread.
///
/// Runs a tight blocking read loop on the PTY output stream, processing VT
/// data under the render lock.
///
/// This is critical for resize: some PTY backends emit a redraw when the grid
/// size changes. The pending read on this thread keeps output draining while
/// the writer thread applies the resize.
///
/// Shutdown is delegated to the platform PTY backend.
const std = @import("std");
const Surface = @import("../Surface.zig");
const render_diagnostics = @import("../render_diagnostics.zig");
const window_backend = @import("../platform/window_backend.zig");

const READ_BUF_SIZE = 4096;
const VISIBLE_SUMMARY_MAX = 512;
const CONTROL_SUMMARY_MAX = 1024;

const ResizeOutputWindow = enum {
    none,
    active,
    grace,
};

pub fn threadMain(surface: *Surface) void {
    var buf: [READ_BUF_SIZE]u8 = undefined;
    var resize_pending: std.ArrayListUnmanaged(u8) = .empty;
    defer resize_pending.deinit(surface.allocator);

    while (!surface.exited.load(.acquire)) {
        const bytes_read = surface.pty.readOutput(&buf) catch |err| {
            switch (err) {
                // Backend interrupted the blocking read. Retry unless we're shutting down.
                error.ReadInterrupted => continue,

                // Pipe closed — child process exited
                error.BrokenPipe => {
                    surface.exited.store(true, .release);
                    return;
                },

                // Any other error — exit
                else => {
                    std.debug.print("ReadThread: read error: {}\n", .{err});
                    surface.exited.store(true, .release);
                    return;
                },
            }
        };
        if (bytes_read == 0) {
            surface.exited.store(true, .release);
            return;
        }

        const data = buf[0..bytes_read];

        const resize_window = currentResizeOutputWindow(surface);
        if (resize_window != .none) {
            logResizeOutput(surface, if (resize_window == .active) "read-active" else "read-grace", data, null);
            resize_pending.appendSlice(surface.allocator, data) catch {
                resize_pending.clearRetainingCapacity();
            };
            drainResizeOutput(surface, &resize_pending, &buf);
            if (resize_pending.items.len == 0) continue;
            processResizePending(
                surface,
                &resize_pending,
                if (surface.resize_in_progress.load(.acquire)) "process-active" else "process-after-resize",
            );
            continue;
        }

        if (resize_pending.items.len > 0) {
            processResizePending(surface, &resize_pending, "process-flush");
        }

        sendRemoteOutput(surface, data);
        processOutput(surface, data);
    }
}

fn drainResizeOutput(
    surface: *Surface,
    pending: *std.ArrayListUnmanaged(u8),
    scratch: *[READ_BUF_SIZE]u8,
) void {
    while (!surface.exited.load(.acquire)) {
        const resize_window = currentResizeOutputWindow(surface);
        if (resize_window == .none) return;

        const available = surface.pty.outputAvailable() orelse return;

        if (available == 0) {
            if (resize_window == .grace) return;
            std.Thread.sleep(std.time.ns_per_ms);
            continue;
        }

        const to_read = @min(available, scratch.len);
        const bytes_read = surface.pty.readOutput(scratch[0..to_read]) catch |err| switch (err) {
            error.ReadInterrupted => continue,
            else => return,
        };

        if (bytes_read == 0) return;

        const data = scratch[0..bytes_read];
        logResizeOutput(surface, "drain-active", data, available);
        pending.appendSlice(surface.allocator, data) catch {
            pending.clearRetainingCapacity();
            return;
        };
    }
}

fn processResizePending(surface: *Surface, pending: *std.ArrayListUnmanaged(u8), phase: []const u8) void {
    if (pending.items.len == 0) return;
    defer pending.clearRetainingCapacity();

    if (resizeOutputDropPhase(surface, pending.items)) |drop_phase| {
        logResizeOutput(surface, drop_phase, pending.items, null);
        return;
    }

    logResizeOutput(surface, phase, pending.items, null);
    sendRemoteOutput(surface, pending.items);
    processOutput(surface, pending.items);
}

fn sendRemoteOutput(surface: *Surface, data: []const u8) void {
    if (surface.remote_client) |client| {
        client.sendOutput(surface.remote_id[0..], data);
    }
}

fn processOutput(surface: *Surface, data: []const u8) void {
    if (data.len == 0) return;

    surface.render_state.mutex.lock();
    defer surface.render_state.mutex.unlock();

    surface.resetOscBatch();
    surface.feedVtWithWispTermImageFallback(data);
    surface.scanForOscTitle(data);
    surface.noteAgentOutput(data);
    surface.dirty.store(true, .release);
    window_backend.postWakeup();
}

fn resizeOutputDropPhase(surface: *Surface, data: []const u8) ?[]const u8 {
    if (looksLikeHostResizeRedraw(data)) return "drop-host-redraw";
    if (surface.launch_kind != .ssh) return null;
    if (currentResizeOutputWindow(surface) != .none) return "drop-ssh-resize-window";
    return null;
}

fn currentResizeOutputWindow(surface: *Surface) ResizeOutputWindow {
    if (surface.resize_in_progress.load(.acquire)) return .active;
    if (surface.launch_kind != .ssh) return .none;

    const until_ms = surface.resize_output_suppress_until_ms.load(.acquire);
    if (until_ms <= 0) return .none;
    if (std.time.milliTimestamp() <= until_ms) return .grace;
    return .none;
}

fn looksLikeHostResizeRedraw(data: []const u8) bool {
    if (data.len < 16) return false;

    var cursor_hide = false;
    var cursor_show = false;
    var resize_report = false;
    var home_near_start = false;
    var csi_count: usize = 0;
    var clear_line_count: usize = 0;
    var newline_count: usize = 0;
    var sgr_count: usize = 0;

    var i: usize = 0;
    while (i < data.len) {
        switch (data[i]) {
            0x0a => newline_count += 1,
            0x1b => {
                if (i + 1 < data.len and data[i + 1] == '[') {
                    if (findCsiFinal(data, i + 2)) |j| {
                        csi_count += 1;
                        const params = data[i + 2 .. j];
                        switch (data[j]) {
                            'l' => {
                                if (std.mem.eql(u8, params, "?25")) cursor_hide = true;
                            },
                            'h' => {
                                if (std.mem.eql(u8, params, "?25")) cursor_show = true;
                            },
                            'H', 'f' => {
                                if (isHomeCursor(params) and i <= 64) home_near_start = true;
                            },
                            'K' => clear_line_count += 1,
                            'm' => sgr_count += 1,
                            't' => {
                                if (std.mem.startsWith(u8, params, "8;")) resize_report = true;
                            },
                            else => {},
                        }
                        i = j;
                    }
                }
            },
            else => {},
        }
        i += 1;
    }

    if (!cursor_hide or !home_near_start) return false;

    const line_redraw =
        clear_line_count >= 4 or
        (clear_line_count >= 2 and newline_count >= 2) or
        (newline_count >= 8 and csi_count >= 4) or
        (sgr_count >= 8 and csi_count >= 16 and data.len >= 256);
    if (!line_redraw) return false;

    return cursor_show or resize_report or data.len >= 256;
}

fn isHomeCursor(params: []const u8) bool {
    return params.len == 0 or
        std.mem.eql(u8, params, "1;1") or
        std.mem.eql(u8, params, "1;") or
        std.mem.eql(u8, params, ";1");
}

fn logResizeOutput(surface: *Surface, phase: []const u8, data: []const u8, available: ?usize) void {
    if (!render_diagnostics.enabled()) return;

    var visible_buf: [VISIBLE_SUMMARY_MAX]u8 = undefined;
    var control_buf: [CONTROL_SUMMARY_MAX]u8 = undefined;
    const visible = summarizeVisible(&visible_buf, data);
    const controls = summarizeControls(&control_buf, data);
    const available_value: isize = if (available) |v| @intCast(v) else -1;

    render_diagnostics.log(
        "resize-output {s} seq={} len={} active={} available={} sample=\"{s}\" controls=\"{s}\"",
        .{
            phase,
            surface.resize_diag_seq.load(.acquire),
            data.len,
            surface.resize_in_progress.load(.acquire),
            available_value,
            visible,
            controls,
        },
    );
}

fn summarizeVisible(buf: *[VISIBLE_SUMMARY_MAX]u8, data: []const u8) []const u8 {
    var len: usize = 0;
    var consumed: usize = 0;

    for (data) |byte| {
        if (len >= buf.len - 8) break;
        consumed += 1;
        switch (byte) {
            0x08 => appendSlice(buf, &len, "\\b"),
            0x09 => appendSlice(buf, &len, "\\t"),
            0x0a => appendSlice(buf, &len, "\\n"),
            0x0d => appendSlice(buf, &len, "\\r"),
            0x1b => appendSlice(buf, &len, "<ESC>"),
            0x20...0x7e => appendByte(buf, &len, byte),
            else => appendHexByte(buf, &len, byte),
        }
    }

    if (consumed < data.len) appendSlice(buf, &len, "...");
    return buf[0..len];
}

fn summarizeControls(buf: *[CONTROL_SUMMARY_MAX]u8, data: []const u8) []const u8 {
    var len: usize = 0;
    var cr: usize = 0;
    var lf: usize = 0;
    var bs: usize = 0;
    var bel: usize = 0;
    var esc: usize = 0;
    var csi: usize = 0;
    var osc: usize = 0;
    var tokens: usize = 0;
    var truncated = false;

    var i: usize = 0;
    while (i < data.len) {
        const byte = data[i];
        switch (byte) {
            0x07 => bel += 1,
            0x08 => bs += 1,
            0x0a => lf += 1,
            0x0d => cr += 1,
            0x1b => {
                esc += 1;
                if (i + 1 < data.len and data[i + 1] == '[') {
                    const final_index = findCsiFinal(data, i + 2);
                    if (final_index) |j| {
                        csi += 1;
                        if (tokens < 32 and len < buf.len - 48) {
                            appendControlSeparator(buf, &len, tokens);
                            appendSlice(buf, &len, "CSI ");
                            appendAsciiLimited(buf, &len, data[i + 2 .. j], 28);
                            appendByte(buf, &len, data[j]);
                            tokens += 1;
                        } else {
                            truncated = true;
                        }
                        i = j;
                    }
                } else if (i + 1 < data.len and data[i + 1] == ']') {
                    osc += 1;
                    const end_index = findOscEnd(data, i + 2) orelse data.len;
                    if (tokens < 32 and len < buf.len - 48) {
                        appendControlSeparator(buf, &len, tokens);
                        appendOscToken(buf, &len, data[i + 2 .. end_index]);
                        tokens += 1;
                    } else {
                        truncated = true;
                    }
                    i = end_index;
                }
            },
            else => {},
        }
        i += 1;
    }

    if (truncated) appendSlice(buf, &len, " ...");
    appendFmt(
        buf,
        &len,
        " | counts cr={} lf={} bs={} bel={} esc={} csi={} osc={}",
        .{ cr, lf, bs, bel, esc, csi, osc },
    );
    return buf[0..len];
}

fn findCsiFinal(data: []const u8, start: usize) ?usize {
    var i = start;
    while (i < data.len) : (i += 1) {
        if (data[i] >= 0x40 and data[i] <= 0x7e) return i;
    }
    return null;
}

fn findOscEnd(data: []const u8, start: usize) ?usize {
    var i = start;
    while (i < data.len) : (i += 1) {
        if (data[i] == 0x07) return i;
        if (data[i] == 0x1b and i + 1 < data.len and data[i + 1] == '\\') return i;
    }
    return null;
}

fn appendOscToken(buf: *[CONTROL_SUMMARY_MAX]u8, len: *usize, body: []const u8) void {
    appendSlice(buf, len, "OSC ");
    const semi = std.mem.indexOfScalar(u8, body, ';') orelse @min(body.len, 16);
    appendAsciiLimited(buf, len, body[0..semi], 16);
    appendFmt(buf, len, " len={}", .{body.len});
}

fn appendControlSeparator(buf: *[CONTROL_SUMMARY_MAX]u8, len: *usize, tokens: usize) void {
    if (tokens != 0) appendSlice(buf, len, " ; ");
}

fn appendAsciiLimited(buf: anytype, len: *usize, text: []const u8, limit: usize) void {
    const n = @min(text.len, limit);
    for (text[0..n]) |byte| {
        if (byte >= 0x20 and byte <= 0x7e) {
            appendByte(buf, len, byte);
        } else {
            appendByte(buf, len, '?');
        }
    }
    if (text.len > limit) appendSlice(buf, len, "...");
}

fn appendFmt(buf: anytype, len: *usize, comptime fmt: []const u8, args: anytype) void {
    if (len.* >= buf.len) return;
    const out = std.fmt.bufPrint(buf[len.*..], fmt, args) catch {
        appendSlice(buf, len, "...");
        return;
    };
    len.* += out.len;
}

fn appendSlice(buf: anytype, len: *usize, text: []const u8) void {
    if (len.* >= buf.len) return;
    const n = @min(text.len, buf.len - len.*);
    @memcpy(buf[len.* .. len.* + n], text[0..n]);
    len.* += n;
}

fn appendByte(buf: anytype, len: *usize, byte: u8) void {
    if (len.* >= buf.len) return;
    buf[len.*] = byte;
    len.* += 1;
}

fn appendHexByte(buf: anytype, len: *usize, byte: u8) void {
    const hex = "0123456789ABCDEF";
    appendSlice(buf, len, "\\x");
    appendByte(buf, len, hex[byte >> 4]);
    appendByte(buf, len, hex[byte & 0x0f]);
}

test "resize redraw classifier matches host full-screen snapshot" {
    const sample =
        "\x1b[?25l" ++
        "\x1b[8;34;51t" ++
        "\x1b[H" ++
        "line one\x1b[K\r\n" ++
        "line two\x1b[K\r\n" ++
        "line three\x1b[K\r\n" ++
        "line four\x1b[K\r\n" ++
        "\x1b[12;8H" ++
        "\x1b[?25h";

    try std.testing.expect(looksLikeHostResizeRedraw(sample));
}

test "resize redraw classifier matches local cmd snapshot" {
    const sample =
        "\x1b[?25l" ++
        "\x1b[8;49;94t" ++
        "\x1b[H" ++
        "Microsoft Windows [Version 10.0.26200.8524]\x1b[K\r\n" ++
        "(c) Microsoft Corporation. All rights reserved.\x1b[K\r\n" ++
        "\x1b[K\r\n" ++
        "C:\\Users\\AF\\Downloads\\wispterm-issue-171-panel-min-cols-v3>\x1b[K\r\n" ++
        "\x1b[K\r\n" ++
        "\x1b[K\r\n" ++
        "\x1b[K\r\n";

    try std.testing.expect(looksLikeHostResizeRedraw(sample));
}

test "resize redraw classifier matches wsl prompt snapshot" {
    const sample =
        "\x1b[?25l" ++
        "\x1b[H" ++
        "wsl: detected localhost proxy configuration\x1b[K\r\n" ++
        "azhenfan@OMENLaptop:~$ ls\x1b[K\r\n" ++
        "\x1b[34m\x1b[1mR\x1b[m  \x1b[36m\x1b[1mbaidunetdiskdownload\x1b[m\x1b[K\r\n" ++
        "\x1b[34m\x1b[1mcode\x1b[m  \x1b[31m\x1b[40m\x1b[1mDesktop\x1b[m\x1b[K\r\n" ++
        "\x1b[34m\x1b[1mDocuments\x1b[m  \x1b[31m\x1b[40m\x1b[1mDownloads\x1b[m\x1b[K\r\n" ++
        "\x1b[34m\x1b[1mMusic\x1b[m  \x1b[34m\x1b[1mPictures\x1b[m  \x1b[34m\x1b[1mVideos\x1b[m\x1b[K\r\n" ++
        "\x1b[34m\x1b[1mworkspace\x1b[m  \x1b[36m\x1b[1mproject-output\x1b[m\x1b[K\r\n" ++
        "azhenfan@OMENLaptop:~$ \x1b[K\r\n" ++
        "\x1b[K\r\n";

    try std.testing.expect(looksLikeHostResizeRedraw(sample));
}

test "resize redraw classifier rejects ordinary output" {
    try std.testing.expect(!looksLikeHostResizeRedraw("line one\r\nline two\r\n"));
    try std.testing.expect(!looksLikeHostResizeRedraw("\x1b[32muser@host\x1b[m:~$ "));
}

test "resize redraw classifier requires a multi-line repaint profile" {
    const prompt_repaint = "\x1b[?25l\x1b[Huser@host:~$ \x1b[K\x1b[?25h";
    try std.testing.expect(!looksLikeHostResizeRedraw(prompt_repaint));
}

test "resize redraw classifier matches long colorized prompt snapshot" {
    const fragment = "\x1b[32m\x1b[1muser@host\x1b[m:\x1b[34m\x1b[1m~/very/long/path\x1b[m$ ";
    const sample =
        "\x1b[?25l" ++
        "\x1b[32m" ++
        "\x1b[1m" ++
        "\x1b[H" ++
        fragment ++ fragment ++ fragment ++ fragment ++
        fragment ++ fragment ++ fragment ++ fragment;

    try std.testing.expect(looksLikeHostResizeRedraw(sample));
}
