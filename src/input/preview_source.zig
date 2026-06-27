//! Preview path detection, source loading, and terminal preview commands.

const std = @import("std");
const Surface = @import("../Surface.zig");
const file_explorer = @import("../file_explorer.zig");
const markdown_preview = @import("../preview/markdown.zig");
const platform_remote_file = @import("../platform/remote_file.zig");
const scp = @import("../scp.zig");
const ui_perf = @import("../ui_perf.zig");
const preview_path = @import("preview_path.zig");
const ls_path_context = @import("ls_path_context.zig");

fn endsWithIgnoreCase(text: []const u8, suffix: []const u8) bool {
    if (text.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(text[text.len - suffix.len ..], suffix);
}

fn isPreviewImagePath(path: []const u8) bool {
    return markdown_preview.isImagePath(path);
}

pub const SourceKind = union(enum) {
    local,
    wsl,
    remote: Surface.SshConnection,
};

pub const looksLikePreviewPath = preview_path.looksLikePreviewPath;

fn appendShellQuoted(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    try list.append(allocator, '\'');
    for (text) |ch| {
        if (ch == '\'') {
            try list.appendSlice(allocator, "'\\''");
        } else {
            try list.append(allocator, ch);
        }
    }
    try list.append(allocator, '\'');
}

/// Result of a preview read. `bytes` is ALWAYS a standalone heap allocation owned
/// by the caller — it must be freed with the same allocator exactly once (never a
/// sub-slice of a larger live buffer). `truncated` is true when the file exceeded
/// the limit and only its head window was kept (text-like kinds; see
/// `markdown_preview.allowsTruncatedHead`) so a huge log is previewable as a
/// scrollable head instead of being refused.
pub const PreviewRead = struct { bytes: []u8, truncated: bool = false };

/// Length of the head to keep when truncating an over-limit text preview: bytes
/// up to and including the last newline within `limit`, so the final rendered
/// line isn't a partial line. Falls back to `limit` when no newline is in range.
fn truncatedHeadLen(data: []const u8, limit: usize) usize {
    const window = data[0..@min(limit, data.len)];
    if (std.mem.lastIndexOfScalar(u8, window, '\n')) |nl| return nl + 1;
    return window.len;
}

/// Apply the over-limit policy to a freshly read buffer (holding up to limit+1
/// bytes), taking ownership of `source`. Within the limit it is returned as-is.
/// Over the limit: when `allow_truncate`, the head window is kept and reported
/// as truncated; otherwise the buffer is freed and `error.PreviewTooLarge` is
/// surfaced (raster kinds, which can't be partially decoded).
fn finishPreviewRead(allocator: std.mem.Allocator, source: []u8, limit: usize, allow_truncate: bool) !PreviewRead {
    if (source.len <= limit) return .{ .bytes = source };
    if (!allow_truncate) {
        allocator.free(source);
        return error.PreviewTooLarge;
    }
    const keep = truncatedHeadLen(source, limit); // 1..=limit, so never resizes to 0
    // resize never moves the allocation, so source[0..keep] stays a freeable
    // standalone allocation (PreviewRead.bytes contract); fall back to a copy if
    // an in-place shrink is refused.
    if (allocator.resize(source, keep)) return .{ .bytes = source[0..keep], .truncated = true };
    const head = allocator.alloc(u8, keep) catch {
        allocator.free(source);
        return error.PreviewFailed;
    };
    @memcpy(head, source[0..keep]);
    allocator.free(source);
    return .{ .bytes = head, .truncated = true };
}

/// Read at most `max_bytes` from `file` into a fresh allocation, stopping at the
/// cap instead of failing on a larger file (unlike `readToEndAlloc`, which errors
/// with StreamTooLong). The returned buffer is sized to the bytes actually read,
/// so a huge log yields exactly its first `max_bytes` for the head-window policy.
fn readFileHeadAlloc(allocator: std.mem.Allocator, file: std.fs.File, max_bytes: usize) ![]u8 {
    const buf = allocator.alloc(u8, max_bytes) catch return error.PreviewFailed;
    var total: usize = 0;
    while (total < max_bytes) {
        const n = file.read(buf[total..]) catch {
            allocator.free(buf);
            return error.PreviewFailed;
        };
        if (n == 0) break;
        total += n;
    }
    if (total == max_bytes) return buf; // exact fit, no shrink needed
    if (total == 0) {
        // Empty file: free the over-sized buffer and hand back a real 0-length
        // allocation (returning buf[0..0] would leak the original mapping, since
        // free() uses the slice length).
        allocator.free(buf);
        return allocator.alloc(u8, 0) catch error.PreviewFailed;
    }
    // Shrink to the bytes actually read. Allocator.resize never moves the
    // allocation (it returns false only when it can't shrink in place), so a
    // successful resize leaves buf[0..total] freeable as-is; otherwise copy into
    // an exact-size buffer and release the original.
    if (allocator.resize(buf, total)) return buf[0..total];
    const out = allocator.alloc(u8, total) catch {
        allocator.free(buf);
        return error.PreviewFailed;
    };
    @memcpy(out, buf[0..total]);
    allocator.free(buf);
    return out;
}

pub fn readLocalPreviewSource(allocator: std.mem.Allocator, path: []const u8, limit: usize, allow_truncate: bool) !PreviewRead {
    const perf = ui_perf.begin("preview_source.read_local");
    defer perf.end();

    var file = blk: {
        if (std.fs.path.isAbsolute(path)) {
            break :blk std.fs.openFileAbsolute(path, .{}) catch return error.PreviewFailed;
        }
        break :blk std.fs.cwd().openFile(path, .{}) catch return error.PreviewFailed;
    };
    defer file.close();

    // Read up to limit+1 bytes: the +1 makes an over-limit file observable
    // (source.len > limit) so finishPreviewRead can truncate (text) or reject it.
    const source = try readFileHeadAlloc(allocator, file, limit + 1);
    return finishPreviewRead(allocator, source, limit, allow_truncate);
}

fn buildRemotePreviewReadCommand(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    var path_buf: [1024]u8 = undefined;
    const path_expr = platform_remote_file.shellPathExpr(&path_buf, path) orelse return error.PreviewFailed;
    return std.fmt.allocPrint(allocator, "head -c {} -- {s}", .{ limit + 1, path_expr });
}

/// Signature of `scp.sshExecCapped`, isolated so tests can inject a fake exec.
const SshExecCappedFn = *const fn (std.mem.Allocator, *const Surface.SshConnection, []const u8, usize) ?[]u8;

/// Stdout byte cap for an SSH preview read of at most `limit` bytes. The read
/// command is `head -c {limit+1}` (the +1 lets `source.len > limit` detect an
/// over-limit file), so the cap must admit exactly that much output. Sizing the
/// cap to the command's own truncation point means scp's "exceeded" guard can
/// never wrongly fire, while a genuinely too-large file is still flagged.
///
/// This MUST exceed scp's default 16 MiB cap (`scp.SSH_EXEC_MAX_STDOUT_BYTES`):
/// PDF (64 MiB) and image (32 MiB) preview limits are both larger, and using the
/// default `scp.sshExec` killed ssh mid-transfer for any >16 MiB document
/// ("sshExec: stdout exceeded 16777216 bytes; killing ssh").
pub fn sshPreviewStdoutCap(limit: usize) usize {
    return limit + 1;
}

fn readSshPreviewSourceWith(
    allocator: std.mem.Allocator,
    conn: *const Surface.SshConnection,
    path: []const u8,
    limit: usize,
    allow_truncate: bool,
    exec_fn: SshExecCappedFn,
) !PreviewRead {
    const command = buildRemotePreviewReadCommand(allocator, path, limit) catch return error.PreviewFailed;
    defer allocator.free(command);

    const source = exec_fn(allocator, conn, command, sshPreviewStdoutCap(limit)) orelse return error.PreviewFailed;
    return finishPreviewRead(allocator, source, limit, allow_truncate);
}

fn readSshPreviewSource(allocator: std.mem.Allocator, conn: *const Surface.SshConnection, path: []const u8, limit: usize, allow_truncate: bool) !PreviewRead {
    const perf = ui_perf.begin("preview_source.read_ssh");
    defer perf.end();

    return readSshPreviewSourceWith(allocator, conn, path, limit, allow_truncate, scp.sshExecCapped);
}

pub fn readRemotePreviewSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (!file_explorer.g_has_ssh_conn) return error.PreviewFailed;
    return (try readSshPreviewSource(allocator, &file_explorer.g_ssh_conn, path, markdown_preview.MAX_SOURCE_BYTES, false)).bytes;
}

pub fn readPreviewSourceForKind(allocator: std.mem.Allocator, source_kind: SourceKind, path: []const u8, kind: markdown_preview.Kind) !PreviewRead {
    const limit = markdown_preview.sourceLimit(kind);
    const allow_truncate = markdown_preview.allowsTruncatedHead(kind);
    return switch (source_kind) {
        .local => readLocalPreviewSource(allocator, path, limit, allow_truncate),
        .wsl => readWslPreviewSource(allocator, path, limit, allow_truncate),
        .remote => |conn| readSshPreviewSource(allocator, &conn, path, limit, allow_truncate),
    };
}

fn buildWslPreviewReadCommand(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    var path_buf: [1024]u8 = undefined;
    const path_expr = platform_remote_file.wslPathExpr(&path_buf, path) orelse return error.PreviewFailed;
    return std.fmt.allocPrint(allocator, "head -c {} -- {s}", .{ limit + 1, path_expr });
}

pub fn readWslPreviewSource(allocator: std.mem.Allocator, path: []const u8, limit: usize, allow_truncate: bool) !PreviewRead {
    const perf = ui_perf.begin("preview_source.read_wsl");
    defer perf.end();

    const command = buildWslPreviewReadCommand(allocator, path, limit) catch return error.PreviewFailed;
    defer allocator.free(command);

    const source = platform_remote_file.wslExec(allocator, command) orelse return error.PreviewFailed;
    return finishPreviewRead(allocator, source, limit, allow_truncate);
}

pub fn basenameForPreview(path: []const u8) []const u8 {
    var start: usize = 0;
    for (path, 0..) |ch, i| {
        if (ch == '/' or ch == '\\') start = i + 1;
    }
    return path[start..];
}

fn isUnixAbsoluteOrHome(path: []const u8) bool {
    return path.len > 0 and (path[0] == '/' or path[0] == '~');
}

fn joinUnixPreviewPath(allocator: std.mem.Allocator, cwd: []const u8, path: []const u8) ![]u8 {
    if (isUnixAbsoluteOrHome(path)) return allocator.dupe(u8, path);
    if (cwd.len == 0) return allocator.dupe(u8, path);
    if (std.mem.eql(u8, cwd, "/")) return std.fmt.allocPrint(allocator, "/{s}", .{path});
    const base = std.mem.trimRight(u8, cwd, "/");
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, path });
}

/// Remote command that prints the working directory of tmux's active pane.
/// Run over SSH when a relative path is clicked while tmux is attached: plain
/// tmux consumes OSC 7, so `surface.getCwd()` is frozen at the pre-tmux dir and
/// can't anchor the relative path. tmux errors (no server, not installed) go to
/// stderr, leaving stdout empty so the caller falls back to the OSC 7 cwd.
const TMUX_PANE_CWD_COMMAND = "tmux display-message -p '#{pane_current_path}'";

/// Bound the pane-cwd probe on the UI thread (mirrors the download dir probe):
/// a hung remote becomes a bounded delay + OSC 7 fallback, never a freeze.
const TMUX_CWD_PROBE_TIMEOUT_MS = 5_000;
/// A POSIX path is at most PATH_MAX (~4096); cap stdout there so junk output
/// can't drive an unbounded read.
const TMUX_CWD_MAX_STDOUT = 4096;

/// Parse the stdout of `TMUX_PANE_CWD_COMMAND`. Returns the pane's working
/// directory only when the output is a single, non-empty, absolute Unix path;
/// otherwise null (tmux not running, command-not-found, unexpanded format, or
/// error spew) so the caller keeps the OSC 7 cwd. The slice points into `output`.
fn parseTmuxPaneCwd(output: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, output, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (trimmed[0] != '/') return null; // relative result / error text / unexpanded format
    if (std.mem.indexOfScalar(u8, trimmed, '\n') != null) return null; // multi-line junk
    return trimmed;
}

/// Best-effort live cwd for an SSH surface whose OSC 7 cwd may be stale because
/// plain tmux is attached. Returns an owned absolute path only when tmux is
/// plausibly attached (alternate screen active) AND the remote query yields a
/// valid path; otherwise null so the caller uses the OSC 7 cwd. The probe runs
/// against tmux's *current* client, so with one attached session it targets the
/// pane the user is looking at; multiple concurrent tmux sessions on the same
/// host may resolve against the most-recently-active one.
fn sshPreviewCwd(allocator: std.mem.Allocator, surface: *Surface) ?[]u8 {
    if (!surface.isAltScreenActive()) return null;
    const conn = surface.ssh_connection orelse return null;
    const output = scp.sshExecCappedOpts(
        allocator,
        &conn,
        TMUX_PANE_CWD_COMMAND,
        TMUX_CWD_MAX_STDOUT,
        .{ .timeout_ms = TMUX_CWD_PROBE_TIMEOUT_MS },
    ) orelse return null;
    defer allocator.free(output);
    const path = parseTmuxPaneCwd(output) orelse return null;
    return allocator.dupe(u8, path) catch null;
}

fn resolveUnixTerminalPath(
    allocator: std.mem.Allocator,
    cwd: ?[]const u8,
    path: []const u8,
    require_cwd_for_relative: bool,
) ![]u8 {
    if (isUnixAbsoluteOrHome(path)) return allocator.dupe(u8, path);
    const current = cwd orelse {
        if (require_cwd_for_relative) return error.CwdUnavailable;
        return allocator.dupe(u8, path);
    };
    if (current.len == 0 and require_cwd_for_relative) return error.CwdUnavailable;
    return joinUnixPreviewPath(allocator, current, path);
}

test "preview_source: ssh relative paths require a reported cwd" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.CwdUnavailable, resolveUnixTerminalPath(allocator, null, "pp.pep.fa", true));

    const absolute = try resolveUnixTerminalPath(allocator, null, "/srv/project/data/sample.fa", true);
    defer allocator.free(absolute);
    try std.testing.expectEqualStrings("/srv/project/data/sample.fa", absolute);

    const home = try resolveUnixTerminalPath(allocator, null, "~/sample.fa", true);
    defer allocator.free(home);
    try std.testing.expectEqualStrings("~/sample.fa", home);

    const relative = try resolveUnixTerminalPath(allocator, "/srv/project/data", "sample.fa", true);
    defer allocator.free(relative);
    try std.testing.expectEqualStrings("/srv/project/data/sample.fa", relative);
}

test "preview_source: parseTmuxPaneCwd accepts a single absolute path and rejects everything else" {
    // Happy path: tmux prints the pane's cwd plus a trailing newline. The
    // surrounding whitespace is trimmed and the absolute path is returned.
    try std.testing.expectEqualStrings(
        "/data1/home/xzg/project/Plant-Root-Atlas-Project",
        parseTmuxPaneCwd("/data1/home/xzg/project/Plant-Root-Atlas-Project\n").?,
    );
    // CRLF and leading/trailing spaces are trimmed too.
    try std.testing.expectEqualStrings(
        "/srv/data",
        parseTmuxPaneCwd("  /srv/data\r\n").?,
    );

    // Empty / whitespace-only output (no tmux value) -> null, caller uses OSC 7.
    try std.testing.expect(parseTmuxPaneCwd("") == null);
    try std.testing.expect(parseTmuxPaneCwd("  \r\n") == null);
    // A relative result can't anchor a cwd -> reject.
    try std.testing.expect(parseTmuxPaneCwd("project/foo\n") == null);
    // tmux error spew leaks to stderr, but be defensive if it reaches stdout:
    // "no server running on /tmp/tmux-1000/default" starts with 'n', not '/'.
    try std.testing.expect(parseTmuxPaneCwd("no server running on /tmp/tmux-1000/default\n") == null);
    // Unexpanded format (ancient tmux) doesn't start with '/'.
    try std.testing.expect(parseTmuxPaneCwd("#{pane_current_path}\n") == null);
    // Multi-line output is junk, not a single path.
    try std.testing.expect(parseTmuxPaneCwd("/a\n/b\n") == null);
}

test "preview_source: tmux pane cwd command queries the active pane path" {
    try std.testing.expectEqualStrings(
        "tmux display-message -p '#{pane_current_path}'",
        TMUX_PANE_CWD_COMMAND,
    );
}

test "preview_source: ssh read cap admits head output and beats the default 16 MiB cap" {
    // The remote read command is `head -c {limit+1}`; the stdout cap must admit
    // that exact maximum.
    try std.testing.expectEqual(@as(usize, 1025), sshPreviewStdoutCap(1024));

    // Regression for "sshExec: stdout exceeded 16777216 bytes; killing ssh": the
    // PDF (64 MiB) and image (32 MiB) preview limits both exceed scp's default
    // 16 MiB stdout cap, so the default sshExec killed ssh for any >16 MiB file.
    // The preview cap must beat the default for both kinds.
    try std.testing.expect(sshPreviewStdoutCap(markdown_preview.MAX_PDF_SOURCE_BYTES) > scp.SSH_EXEC_MAX_STDOUT_BYTES);
    try std.testing.expect(sshPreviewStdoutCap(markdown_preview.MAX_IMAGE_SOURCE_BYTES) > scp.SSH_EXEC_MAX_STDOUT_BYTES);
}

test "preview_source: local read truncates an over-limit text file to a head window" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const content = "line1\nline2\nline3\nline4\n"; // 24 bytes, four 6-byte lines
    try tmp.dir.writeFile(.{ .sub_path = "big.log", .data = content });
    const path = try tmp.dir.realpathAlloc(allocator, "big.log");
    defer allocator.free(path);

    // Over the limit (12): reads 13 bytes, trims to the last newline within 12 ->
    // "line1\nline2\n" and reports truncated rather than refusing the file.
    const head = try readLocalPreviewSource(allocator, path, 12, true);
    defer allocator.free(head.bytes);
    try std.testing.expect(head.truncated);
    try std.testing.expectEqualStrings("line1\nline2\n", head.bytes);

    // Within the limit: full content, not truncated.
    const full = try readLocalPreviewSource(allocator, path, 1000, true);
    defer allocator.free(full.bytes);
    try std.testing.expect(!full.truncated);
    try std.testing.expectEqualStrings(content, full.bytes);

    // Raster policy (allow_truncate=false) still rejects an over-limit file.
    try std.testing.expectError(error.PreviewTooLarge, readLocalPreviewSource(allocator, path, 12, false));
}

test "preview_source: truncatedHeadLen keeps whole lines and falls back to limit" {
    // window = data[0..10] = "aa\nbb\ncc\nd"; last '\n' is at index 8, so the head
    // keeps "aa\nbb\ncc\n" (9 bytes) and drops the partial final line "dd".
    try std.testing.expectEqual(@as(usize, 9), truncatedHeadLen("aa\nbb\ncc\ndd", 10));
    // No newline within the window -> keep exactly `limit` bytes.
    try std.testing.expectEqual(@as(usize, 4), truncatedHeadLen("abcdefgh", 4));
    // Data shorter than the limit -> window is the whole input (here ending in a
    // newline at index 3, so the kept length is the full 4 bytes).
    try std.testing.expectEqual(@as(usize, 4), truncatedHeadLen("abc\n", 5));
}

test "preview_source: ssh preview sizes the exec cap to limit+1 and applies the over-limit policy" {
    const allocator = std.testing.allocator;
    const Fake = struct {
        var last_cap: usize = 0;
        var payload_len: usize = 0;
        var payload_byte: u8 = 'x';
        fn exec(a: std.mem.Allocator, _: *const Surface.SshConnection, _: []const u8, cap: usize) ?[]u8 {
            last_cap = cap;
            const buf = a.alloc(u8, payload_len) catch return null;
            @memset(buf, payload_byte);
            return buf;
        }
    };
    var conn: Surface.SshConnection = .{};

    // A document within the limit is returned, and the cap passed to ssh is the
    // command's own ceiling (limit+1) — NOT scp's default 16 MiB.
    Fake.payload_byte = 'x';
    Fake.payload_len = 10;
    const ok = try readSshPreviewSourceWith(allocator, &conn, "/srv/a.pdf", 64, false, Fake.exec);
    defer allocator.free(ok.bytes);
    try std.testing.expectEqual(@as(usize, 65), Fake.last_cap);
    try std.testing.expectEqual(@as(usize, 10), ok.bytes.len);
    try std.testing.expect(!ok.truncated);

    // Raster-style read (allow_truncate=false): an over-limit file is reported as
    // too_large rather than failing or silently truncating.
    Fake.payload_len = 65;
    try std.testing.expectError(
        error.PreviewTooLarge,
        readSshPreviewSourceWith(allocator, &conn, "/srv/a.pdf", 64, false, Fake.exec),
    );

    // Text-style read (allow_truncate=true): the same over-limit file becomes a
    // truncated head window instead of being refused. No newline -> keep `limit`.
    Fake.payload_len = 65;
    const head = try readSshPreviewSourceWith(allocator, &conn, "/srv/a.log", 64, true, Fake.exec);
    defer allocator.free(head.bytes);
    try std.testing.expectEqual(@as(usize, 64), head.bytes.len);
    try std.testing.expect(head.truncated);
}

pub fn resolveTerminalPreviewPath(allocator: std.mem.Allocator, surface: *Surface, path: []const u8, ls_prefix: ?[]const u8) ![]u8 {
    const joined = try ls_path_context.applyLsPrefix(allocator, path, ls_prefix);
    defer if (joined) |j| allocator.free(j);
    const eff = joined orelse path;

    return switch (surface.launch_kind) {
        .wsl => try resolveUnixTerminalPath(allocator, surface.getCwd() orelse "~", eff, false),
        .ssh => blk: {
            // Plain tmux consumes OSC 7, so surface.getCwd() can be a stale
            // pre-tmux dir (the login home). For a relative click, prefer a live
            // remote pane-cwd query and fall back to the OSC 7 cwd. Absolute/home
            // paths ignore cwd, so skip the round-trip for them.
            const remote_cwd: ?[]u8 = if (isUnixAbsoluteOrHome(eff)) null else sshPreviewCwd(allocator, surface);
            defer if (remote_cwd) |c| allocator.free(c);
            const cwd: ?[]const u8 = if (remote_cwd) |c| c else surface.getCwd();
            break :blk try resolveUnixTerminalPath(allocator, cwd, eff, true);
        },
        .local => blk: {
            if (std.fs.path.isAbsolute(eff) or (eff.len >= 2 and eff[1] == ':')) {
                break :blk try allocator.dupe(u8, eff);
            }
            // Resolve relative to the shell's CURRENT cwd, not its launch cwd:
            // the user may have `cd`'d, and shells like zsh don't emit OSC 7,
            // so we fall back to a live process-cwd query (see dupeCurrentCwd).
            const cwd = surface.dupeCurrentCwd(allocator) orelse {
                break :blk try allocator.dupe(u8, eff);
            };
            defer allocator.free(cwd);
            break :blk try std.fs.path.join(allocator, &.{ cwd, eff });
        },
    };
}

pub fn readTerminalPreviewSource(allocator: std.mem.Allocator, surface: *Surface, path: []const u8) ![]u8 {
    return switch (surface.launch_kind) {
        .wsl => (try readWslPreviewSource(allocator, path, markdown_preview.MAX_SOURCE_BYTES, false)).bytes,
        .ssh => blk: {
            const conn = surface.ssh_connection orelse {
                std.debug.print("Markdown preview over SSH needs WispTerm SSH connection metadata; manual ssh sessions are not supported yet\n", .{});
                return error.PreviewFailed;
            };
            break :blk (try readSshPreviewSource(allocator, &conn, path, markdown_preview.MAX_SOURCE_BYTES, false)).bytes;
        },
        .local => (try readLocalPreviewSource(allocator, path, markdown_preview.MAX_SOURCE_BYTES, false)).bytes,
    };
}

pub fn buildPreviewCommand(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    var cmd: std.ArrayListUnmanaged(u8) = .empty;

    if (endsWithIgnoreCase(path, ".pdf")) {
        cmd.appendSlice(allocator, "pdfcat ") catch {
            cmd.deinit(allocator);
            return null;
        };
    } else if (isPreviewImagePath(path)) {
        cmd.appendSlice(allocator, "imgcat ") catch {
            cmd.deinit(allocator);
            return null;
        };
    } else {
        cmd.appendSlice(allocator, "less ") catch {
            cmd.deinit(allocator);
            return null;
        };
    }
    appendShellQuoted(&cmd, allocator, path) catch {
        cmd.deinit(allocator);
        return null;
    };
    cmd.append(allocator, '\r') catch {
        cmd.deinit(allocator);
        return null;
    };
    return cmd.toOwnedSlice(allocator) catch {
        cmd.deinit(allocator);
        return null;
    };
}
