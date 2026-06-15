//! Opt-in (diagnostic-build) application diagnostics: a shared on-disk log fed
//! by std.log, plus crash capture (Zig panic + Windows unhandled exceptions).
//!
//! Only wired up when built with -Ddebug-console (see src/main.zig). The log is
//! written to <config-dir>/wispterm-debug.log with a single size-based rollover
//! to wispterm-debug.log.1; crash reports go to <config-dir>/crash-<ts>.txt.

const std = @import("std");
const builtin = @import("builtin");

pub const MAX_LOG_BYTES: usize = 8 * 1024 * 1024;

/// Assemble one log line into `buf` (no trailing newline). On overflow the line
/// is truncated to what fits rather than dropped. Format:
/// "[+<elapsed>ms] <LEVEL>(<scope>) <message>".
pub fn formatLine(
    buf: []u8,
    elapsed_ms: i64,
    level: []const u8,
    scope: []const u8,
    message: []const u8,
) []const u8 {
    return std.fmt.bufPrint(buf, "[+{d}ms] {s}({s}) {s}", .{ elapsed_ms, level, scope, message }) catch blk: {
        // Buffer too small for the full line: emit as much of the prefix as fits.
        const head = "[+? ] ";
        const n = @min(buf.len, head.len);
        @memcpy(buf[0..n], head[0..n]);
        break :blk buf[0..n];
    };
}

/// True when writing `incoming` bytes would push the file past `max`, so the
/// caller must roll over first. A first write (written == 0) never rolls over,
/// so a single line larger than `max` still lands (after at most one rollover).
pub fn shouldRollover(written: usize, incoming: usize, max: usize) bool {
    return written != 0 and written + incoming > max;
}

const platform_dirs = @import("platform/dirs.zig");
const build_options = @import("build_options");

const LOG_BASENAME = "wispterm-debug.log";
const LOG_BASENAME_PREV = "wispterm-debug.log.1";

var g_mutex: std.Thread.Mutex = .{};
var g_file: ?std.fs.File = null;
var g_written: usize = 0;
var g_start_ms: i64 = 0;
/// Config dir cached at first open so crash handlers (which may run mid-panic)
/// don't need to re-resolve it.
var g_dir: ?[]u8 = null;

/// Open (truncate) the log eagerly so an early crash still has a file. Safe to
/// call when not a diagnostic build — it just opens the file. Best-effort.
pub fn init() void {
    g_mutex.lock();
    defer g_mutex.unlock();
    _ = openLocked() catch {};
}

pub fn close() void {
    g_mutex.lock();
    defer g_mutex.unlock();
    if (g_file) |f| {
        f.close();
        g_file = null;
    }
}

/// std.Options.logFn: tee every std.log record to stderr (console build) and the
/// on-disk log. Best-effort: any failure silently degrades to stderr-only.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    std.log.defaultLog(level, scope, format, args); // stderr (visible in console build)

    g_mutex.lock();
    defer g_mutex.unlock();

    var msg_buf: [4000]u8 = undefined;
    const message = std.fmt.bufPrint(&msg_buf, format, args) catch msg_buf[0..msg_buf.len];

    const now = std.time.milliTimestamp();
    const elapsed = if (g_start_ms == 0) 0 else now - g_start_ms;
    var line_buf: [4200]u8 = undefined;
    const line = formatLine(&line_buf, elapsed, level.asText(), @tagName(scope), message);

    if (shouldRollover(g_written, line.len + 1, MAX_LOG_BYTES)) rolloverLocked();
    const file = openLocked() catch return;
    appendLocked(file, line);
    appendLocked(file, "\n");
}

fn appendLocked(file: std.fs.File, bytes: []const u8) void {
    file.writeAll(bytes) catch return;
    g_written += bytes.len;
}

/// Caller holds g_mutex. Opens (creating/truncating) the current log file.
fn openLocked() !std.fs.File {
    if (g_file) |f| return f;
    const a = std.heap.page_allocator;
    const dir = try platform_dirs.configDir(a);
    defer a.free(dir);
    if (g_dir == null) g_dir = a.dupe(u8, dir) catch null;
    std.fs.cwd().makePath(dir) catch {};
    const path = try std.fs.path.join(a, &.{ dir, LOG_BASENAME });
    defer a.free(path);
    const f = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    g_file = f;
    g_written = 0;
    // Stamp the session epoch once. A rollover reopen keeps the original start so
    // the [+Nms] elapsed clock stays monotonic across the whole session — timing
    // matters when this log is used to diagnose the ctrl+click freeze.
    if (g_start_ms == 0) g_start_ms = std.time.milliTimestamp();
    var hdr: [256]u8 = undefined;
    const head = std.fmt.bufPrint(&hdr, "WispTerm debug log started ts_ms={d} version={s}\n", .{ g_start_ms, build_options.app_version }) catch "";
    f.writeAll(head) catch {};
    g_written += head.len;
    return f;
}

/// Caller holds g_mutex. Rename current -> .1 (keeping one prior generation),
/// then drop the handle so the next openLocked() recreates a fresh file.
fn rolloverLocked() void {
    const a = std.heap.page_allocator;
    if (g_file) |f| {
        f.close();
        g_file = null;
    }
    const dir = g_dir orelse return;
    const cur = std.fs.path.join(a, &.{ dir, LOG_BASENAME }) catch return;
    defer a.free(cur);
    const prev = std.fs.path.join(a, &.{ dir, LOG_BASENAME_PREV }) catch return;
    defer a.free(prev);
    std.fs.cwd().deleteFile(prev) catch {};
    std.fs.cwd().rename(cur, prev) catch {};
    g_written = 0;
}

const win = std.os.windows;

/// std.debug.FullPanic hook: write a crash report, then chain to the default
/// panic so the process still aborts (and prints the trace to the console).
pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
    writeCrashReport(msg, first_trace_addr);
    std.debug.defaultPanic(msg, first_trace_addr);
}

/// Best-effort crash file at <config-dir>/crash-<ts>.txt. MUST NOT call into
/// logFn (g_mutex is non-reentrant and may already be held by the faulting
/// thread). Uses its own file handle.
pub fn writeCrashReport(msg: []const u8, first_trace_addr: ?usize) void {
    const a = std.heap.page_allocator;
    // g_dir is set once in openLocked() and never freed/reassigned, so this
    // lock-free read from the panic path is safe (we deliberately avoid g_mutex
    // here — a faulting thread may already hold it inside logFn).
    const dir = g_dir orelse (platform_dirs.configDir(a) catch return);
    // If g_dir was set, it's owned by the module; only free a fresh resolution.
    const owned_dir = g_dir == null;
    defer if (owned_dir) a.free(dir);
    std.fs.cwd().makePath(dir) catch {};

    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "crash-{d}.txt", .{std.time.milliTimestamp()}) catch return;
    const path = std.fs.path.join(a, &.{ dir, name }) catch return;
    defer a.free(path);

    const file = std.fs.createFileAbsolute(path, .{}) catch return;
    defer file.close();
    var wbuf: [4096]u8 = undefined;
    var w = file.writerStreaming(&wbuf);
    w.interface.print(
        "WispTerm crash\nversion: {s}\nmessage: {s}\n\nstack trace:\n",
        .{ build_options.app_version, msg },
    ) catch {};
    std.debug.dumpCurrentStackTraceToWriter(first_trace_addr, &w.interface) catch {};
    w.interface.flush() catch {};
}

/// Install OS-level crash capture. Currently the Windows unhandled-exception
/// filter for native (non-Zig) faults (D3D / WebView2 / win32 access
/// violations) that never reach Zig's panic. No-op elsewhere.
pub fn installCrashHandlers() void {
    if (builtin.os.tag == .windows) {
        _ = SetUnhandledExceptionFilter(winExceptionFilter);
    }
}

// Declared here (not in std) — mirrors the extern pattern in
// src/platform/clipboard_windows.zig. Only referenced on Windows, so the
// non-Windows build never links kernel32.
extern "kernel32" fn SetUnhandledExceptionFilter(
    filter: ?win.VECTORED_EXCEPTION_HANDLER,
) callconv(.winapi) ?win.VECTORED_EXCEPTION_HANDLER;

fn winExceptionFilter(info: *win.EXCEPTION_POINTERS) callconv(.winapi) c_long {
    var msg_buf: [64]u8 = undefined;
    const code = info.ExceptionRecord.ExceptionCode;
    const msg = std.fmt.bufPrint(&msg_buf, "native exception 0x{x}", .{code}) catch "native exception";
    writeCrashReport(msg, null);
    return win.EXCEPTION_CONTINUE_SEARCH; // let the OS crash normally
}

test "diag_log: formatLine assembles prefix, level, scope, message" {
    var buf: [128]u8 = undefined;
    const line = formatLine(&buf, 42, "info", "weixin", "QR login started");
    try std.testing.expectEqualStrings("[+42ms] info(weixin) QR login started", line);
}

test "diag_log: formatLine truncates instead of overflowing a small buffer" {
    var buf: [8]u8 = undefined;
    const line = formatLine(&buf, 42, "info", "weixin", "QR login started");
    try std.testing.expect(line.len <= buf.len);
}

test "diag_log: shouldRollover never fires on the first write" {
    try std.testing.expect(!shouldRollover(0, MAX_LOG_BYTES + 1, MAX_LOG_BYTES));
}

test "diag_log: shouldRollover fires once the cap would be exceeded" {
    try std.testing.expect(!shouldRollover(10, 5, 100));
    try std.testing.expect(shouldRollover(98, 5, 100));
}
