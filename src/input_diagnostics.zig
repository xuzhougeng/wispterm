//! Opt-in input / PTY-write diagnostics.
//!
//! Captures exactly what bytes leave the terminal toward the PTY, plus the
//! mouse-reporting decisions the input layer makes. Built to investigate the
//! "selecting text in Codex emits a Ctrl+C (^C)" report: a clean `^C` at the
//! shell prompt means a literal 0x03 byte reached the PTY, and the cleanest way
//! to prove what is (or is not) being sent is to render every PTY write in
//! caret notation (0x03 -> "^C", ESC -> "^[") right at the write funnel.
//!
//! Enable with either the `WISPTERM_INPUT_DIAGNOSTICS=1` env var or the
//! `wispterm-debug-input = true` config key (see `enableFromConfig`). Logs go to
//! `%APPDATA%\wispterm\input-diagnostic.log` on Windows (and the matching
//! per-OS config dir elsewhere), mirroring `render_diagnostics.zig`.

const std = @import("std");
const platform_dirs = @import("platform/dirs.zig");

const ENV_NAME = "WISPTERM_INPUT_DIAGNOSTICS";
const LOG_BASENAME = "input-diagnostic.log";

threadlocal var g_checked: bool = false;
threadlocal var g_enabled: bool = false;
threadlocal var g_file_open: bool = false;
threadlocal var g_file: std.fs.File = undefined;
threadlocal var g_start_ms: i64 = 0;

/// Process-global override flipped on by the `wispterm-debug-input` config key.
/// Mirrors render_diagnostics: visible to every thread, consulted before the
/// (cached) env-var check so a config opt-in works even after a thread already
/// evaluated the env var as off.
var g_config_force = std.atomic.Value(bool).init(false);

/// Force diagnostics on from config. Call once, as early as the config is
/// available, so the very first input events are captured.
pub fn enableFromConfig(on: bool) void {
    if (on) g_config_force.store(true, .seq_cst);
}

pub fn enabled() bool {
    if (g_config_force.load(.seq_cst)) return true;
    if (g_checked) return g_enabled;
    g_checked = true;

    const value = std.process.getEnvVarOwned(std.heap.page_allocator, ENV_NAME) catch {
        g_enabled = false;
        return g_enabled;
    };
    defer std.heap.page_allocator.free(value);

    g_enabled = parseEnabledValue(value);
    return g_enabled;
}

pub fn log(comptime fmt: []const u8, args: anytype) void {
    if (!enabled()) return;

    const file = ensureFile() catch |err| {
        std.debug.print("[input-diag] failed to open log: {}\n", .{err});
        std.debug.print("[input-diag] " ++ fmt ++ "\n", args);
        return;
    };

    const now = std.time.milliTimestamp();
    const elapsed = if (g_start_ms == 0) 0 else now - g_start_ms;
    var write_buf: [4096]u8 = undefined;
    var writer = file.writerStreaming(&write_buf);
    writer.interface.print("[+{d}ms] ", .{elapsed}) catch return;
    writer.interface.print(fmt, args) catch return;
    writer.interface.writeAll("\n") catch return;
    writer.end() catch return;
}

/// Log one PTY write as caret notation + hex so it is unambiguous what reached
/// the child. `tag` names the call site / surface. Cheap no-op when disabled.
pub fn logPtyWrite(tag: []const u8, data: []const u8) void {
    if (!enabled()) return;
    var caret_buf: [256]u8 = undefined;
    var hex_buf: [256]u8 = undefined;
    const caret = caretEscape(data, &caret_buf);
    const hex = hexDump(data, &hex_buf);
    log("pty-write {s} len={d} caret=\"{s}\" hex={s}", .{ tag, data.len, caret, hex });
}

pub fn close() void {
    if (!g_file_open) return;
    g_file.close();
    g_file_open = false;
}

pub fn logFilePath(allocator: std.mem.Allocator) ![]const u8 {
    return platform_dirs.pathInConfigDir(allocator, LOG_BASENAME);
}

fn ensureFile() !*std.fs.File {
    if (g_file_open) return &g_file;

    const allocator = std.heap.page_allocator;
    const dir = try platform_dirs.configDir(allocator);
    defer allocator.free(dir);
    try std.fs.cwd().makePath(dir);

    const path = try std.fs.path.join(allocator, &.{ dir, LOG_BASENAME });
    defer allocator.free(path);

    g_file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    g_file_open = true;
    g_start_ms = std.time.milliTimestamp();
    var write_buf: [1024]u8 = undefined;
    var writer = g_file.writerStreaming(&write_buf);
    writer.interface.print(
        "WispTerm input diagnostics started timestamp_ms={d} env={s}\n",
        .{ g_start_ms, ENV_NAME },
    ) catch {};
    writer.end() catch {};
    return &g_file;
}

fn parseEnabledValue(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return std.mem.eql(u8, trimmed, "1") or
        std.ascii.eqlIgnoreCase(trimmed, "true") or
        std.ascii.eqlIgnoreCase(trimmed, "yes") or
        std.ascii.eqlIgnoreCase(trimmed, "on");
}

/// Render `data` in caret notation into `out`, returning the written slice.
/// Control bytes 0x00-0x1f become `^@`..`^_` (so 0x03 -> "^C", ESC -> "^["),
/// 0x7f becomes "^?", printable ASCII passes through, and any other byte is
/// shown as `\xHH`. Output is truncated to fit `out` with a trailing "…".
pub fn caretEscape(data: []const u8, out: []u8) []const u8 {
    var len: usize = 0;
    for (data) |b| {
        // Worst-case glyph is "\xHH" (4 bytes); keep room for a 3-byte "…".
        if (len + 4 > out.len) {
            const ell = "…";
            if (len + ell.len <= out.len) {
                @memcpy(out[len .. len + ell.len], ell);
                len += ell.len;
            }
            break;
        }
        if (b < 0x20) {
            out[len] = '^';
            out[len + 1] = b + 64; // 0x00 -> '@', 0x03 -> 'C', 0x1b -> '['
            len += 2;
        } else if (b == 0x7f) {
            out[len] = '^';
            out[len + 1] = '?';
            len += 2;
        } else if (b < 0x7f) {
            out[len] = b;
            len += 1;
        } else {
            const hex = "0123456789abcdef";
            out[len] = '\\';
            out[len + 1] = 'x';
            out[len + 2] = hex[b >> 4];
            out[len + 3] = hex[b & 0x0f];
            len += 4;
        }
    }
    return out[0..len];
}

/// Render `data` as space-separated two-digit hex into `out`, truncating with
/// "…" when it would overflow. Returns the written slice.
pub fn hexDump(data: []const u8, out: []u8) []const u8 {
    const hex = "0123456789abcdef";
    var len: usize = 0;
    for (data, 0..) |b, i| {
        const need: usize = if (i == 0) 2 else 3; // optional leading space
        if (len + need > out.len) {
            const ell = "…";
            if (len + ell.len <= out.len) {
                @memcpy(out[len .. len + ell.len], ell);
                len += ell.len;
            }
            break;
        }
        if (i != 0) {
            out[len] = ' ';
            len += 1;
        }
        out[len] = hex[b >> 4];
        out[len + 1] = hex[b & 0x0f];
        len += 2;
    }
    return out[0..len];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "input diagnostics enabled parser accepts common truthy values" {
    try std.testing.expect(parseEnabledValue("1"));
    try std.testing.expect(parseEnabledValue("true"));
    try std.testing.expect(parseEnabledValue("ON"));
}

test "input diagnostics enabled parser rejects empty and falsey values" {
    try std.testing.expect(!parseEnabledValue(""));
    try std.testing.expect(!parseEnabledValue("0"));
    try std.testing.expect(!parseEnabledValue("off"));
}

test "caretEscape renders a bare Ctrl+C as ^C" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("^C", caretEscape(&[_]u8{0x03}, &buf));
}

test "caretEscape renders an SGR mouse press, not a clean ^C" {
    var buf: [64]u8 = undefined;
    // ESC [ < 0 ; 2 4 ; 6 M  — what a mouse report actually looks like.
    const seq = "\x1b[<0;24;6M";
    try std.testing.expectEqualStrings("^[[<0;24;6M", caretEscape(seq, &buf));
}

test "caretEscape shows DEL and high bytes distinctly" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("^?\\xff", caretEscape(&[_]u8{ 0x7f, 0xff }, &buf));
}

test "caretEscape truncates with an ellipsis instead of overflowing" {
    var buf: [7]u8 = undefined; // room for two "^A" then the 3-byte ellipsis
    const out = caretEscape(&[_]u8{ 0x01, 0x01, 0x01, 0x01 }, &buf);
    try std.testing.expectEqualStrings("^A^A…", out);
}

test "hexDump space-separates bytes" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1b 5b 4d", hexDump("\x1b[M", &buf));
}
