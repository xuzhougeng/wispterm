//! Shared SCP/SSH command helpers.
//!
//! Provides reusable functions for executing scp and ssh commands using
//! the SshConnection metadata from Surface.zig. Used by both the clipboard
//! image paste path and the file explorer remote operations.

const std = @import("std");
const builtin = @import("builtin");
const ssh_connection = @import("ssh_connection.zig");
const SshConnection = ssh_connection.SshConnection;
const platform_dirs = @import("platform/dirs.zig");
const platform_process = @import("platform/process.zig");
const platform_pty_command = @import("platform/pty_command.zig");

/// Result of a transfer operation.
pub const TransferResult = enum { ok, failed, spawn_error, cancelled };

pub const TransferControl = struct {
    cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mutex: std.Thread.Mutex = .{},
    child_id: ?std.process.Child.Id = null,

    pub fn cancel(self: *TransferControl) void {
        self.cancel_requested.store(true, .release);
        self.terminateRegisteredChild();
    }

    pub fn cancelRequested(self: *const TransferControl) bool {
        return self.cancel_requested.load(.acquire);
    }

    fn registerChild(self: *TransferControl, child_id: std.process.Child.Id) void {
        self.mutex.lock();
        self.child_id = child_id;
        const should_terminate = self.cancel_requested.load(.acquire);
        self.mutex.unlock();

        if (should_terminate) platform_process.terminateChild(child_id);
    }

    fn clearChild(self: *TransferControl, child_id: std.process.Child.Id) void {
        self.mutex.lock();
        if (self.child_id) |registered| {
            if (registered == child_id) self.child_id = null;
        }
        self.mutex.unlock();
    }

    fn terminateRegisteredChild(self: *TransferControl) void {
        self.mutex.lock();
        const child_id = self.child_id;
        self.mutex.unlock();

        if (child_id) |id| platform_process.terminateChild(id);
    }
};

/// Build the scp argv up to (but excluding) the src/dst path arguments.
/// Returns the count of arguments written into `argv_buf`. Pure/testable.
fn buildScpFlagArgs(
    argv_buf: *[40][]const u8,
    conn: *const SshConnection,
    control_path: ?[]const u8,
    legacy_protocol: bool,
    recursive: bool,
) usize {
    var argc: usize = 0;
    argv_buf[argc] = platform_pty_command.scpExecutableName();
    argc += 1;
    argv_buf[argc] = "-q";
    argc += 1;
    if (recursive) {
        argv_buf[argc] = "-r";
        argc += 1;
    }
    if (legacy_protocol) {
        argv_buf[argc] = "-O";
        argc += 1;
    }
    return appendSshOptions(argv_buf, argc, conn, .scp, control_path);
}

/// Run `scp src dst` with proper SSH auth options from the connection.
/// `src` and `dst` are scp-style paths (local or user@host:remote).
pub fn transfer(allocator: std.mem.Allocator, conn: *const SshConnection, src: []const u8, dst: []const u8) TransferResult {
    var control: TransferControl = .{};
    return transferWithControl(allocator, conn, src, dst, &control);
}

pub fn transferWithControl(allocator: std.mem.Allocator, conn: *const SshConnection, src: []const u8, dst: []const u8, control: *TransferControl) TransferResult {
    return transferImpl(allocator, conn, src, dst, control, false);
}

/// Recursively transfer a directory with `scp -r`. Falls back through the
/// legacy scp protocol (`-O`) but NOT the ssh `cat` stream (which cannot
/// transfer directories).
pub fn transferDirWithControl(allocator: std.mem.Allocator, conn: *const SshConnection, src: []const u8, dst: []const u8, control: *TransferControl) TransferResult {
    return transferImpl(allocator, conn, src, dst, control, true);
}

fn transferImpl(allocator: std.mem.Allocator, conn: *const SshConnection, src: []const u8, dst: []const u8, control: *TransferControl, recursive: bool) TransferResult {
    var askpass_path: ?[]const u8 = null;
    defer if (askpass_path) |p| allocator.free(p);
    var env_map: ?std.process.EnvMap = null;
    defer if (env_map) |*map| map.deinit();

    if (conn.usesPasswordAuth()) {
        askpass_path = platform_process.ensureSshAskPassScript(allocator) orelse return .spawn_error;
        env_map = std.process.getEnvMap(allocator) catch return .spawn_error;
        if (env_map) |*map| {
            platform_process.putSshAskPassEnv(map, askpass_path.?, conn.password()) catch return .spawn_error;
        }
    }

    // Windows OpenSSH's ControlMaster support relies on Unix-domain socket
    // semantics that fail here with "getsockname failed: Not a socket".
    // Keep helper SSH/SCP calls independent; the real interactive SSH session
    // remains untouched.
    const control_path: ?[]const u8 = null;

    const env_ptr: ?*std.process.EnvMap = if (env_map) |*map| map else null;
    const default_result = runScpTransfer(allocator, conn, src, dst, control_path, env_ptr, false, recursive, control);
    if (default_result == .ok or default_result == .spawn_error or default_result == .cancelled) return default_result;

    std.debug.print("SCP default mode failed; retrying legacy scp protocol (-O)\n", .{});
    const legacy_result = runScpTransfer(allocator, conn, src, dst, control_path, env_ptr, true, recursive, control);
    if (legacy_result == .ok or legacy_result == .spawn_error or legacy_result == .cancelled) return legacy_result;

    // The ssh `cat` stream fallback only handles single files; directories have
    // no further fallback after both scp modes fail.
    if (recursive) return legacy_result;

    std.debug.print("SCP legacy mode failed; retrying over ssh stream\n", .{});
    return runSshStreamTransfer(allocator, conn, src, dst, control_path, env_ptr, control);
}

/// Build a remote scp path: "user@host:path"
pub fn remoteSpec(buf: *[512]u8, conn: *const SshConnection, remote_path: []const u8) []const u8 {
    const user = conn.user();
    const host = conn.host();
    var pos: usize = 0;
    @memcpy(buf[pos..][0..user.len], user);
    pos += user.len;
    buf[pos] = '@';
    pos += 1;
    @memcpy(buf[pos..][0..host.len], host);
    pos += host.len;
    buf[pos] = ':';
    pos += 1;
    @memcpy(buf[pos..][0..remote_path.len], remote_path);
    pos += remote_path.len;
    return buf[0..pos];
}

// ============================================================================
// Internal helpers
// ============================================================================

const PortMode = enum { ssh, scp };

fn runScpTransfer(
    allocator: std.mem.Allocator,
    conn: *const SshConnection,
    src: []const u8,
    dst: []const u8,
    control_path: ?[]const u8,
    env_map: ?*std.process.EnvMap,
    legacy_protocol: bool,
    recursive: bool,
    control: *TransferControl,
) TransferResult {
    if (control.cancelRequested()) return .cancelled;

    var argv_buf: [40][]const u8 = undefined;
    var argc = buildScpFlagArgs(&argv_buf, conn, control_path, legacy_protocol, recursive);

    argv_buf[argc] = src;
    argc += 1;
    argv_buf[argc] = dst;
    argc += 1;

    std.debug.print("SCP: {s} -> {s}\n", .{ src, dst });
    var child = std.process.Child.init(argv_buf[0..argc], allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;
    if (env_map) |map| child.env_map = map;
    child.create_no_window = true;
    child.spawn() catch |err| {
        std.debug.print("SCP spawn failed: {}\n", .{err});
        return .spawn_error;
    };
    const child_id = child.id;
    control.registerChild(child_id);
    defer control.clearChild(child_id);

    var stderr_output: ?[]u8 = null;
    defer if (stderr_output) |stderr| allocator.free(stderr);
    if (child.stderr) |stderr| {
        stderr_output = stderr.readToEndAlloc(allocator, 16 * 1024) catch null;
    }

    const term = child.wait() catch return .failed;
    if (control.cancelRequested()) return .cancelled;
    const result: TransferResult = switch (term) {
        .Exited => |code| if (code == 0) .ok else .failed,
        else => .failed,
    };
    if (result != .ok) {
        logProcessFailure(if (legacy_protocol) "SCP -O failed" else "SCP failed", stderr_output);
    }
    return result;
}

fn appendSshExecPrefix(
    argv_buf: *[40][]const u8,
    conn: *const SshConnection,
    control_path: ?[]const u8,
    dest_buf: *[280]u8,
) usize {
    var argc: usize = 0;
    argv_buf[argc] = platform_pty_command.sshExecutableName();
    argc += 1;

    argc = appendSshOptions(argv_buf, argc, conn, .ssh, control_path);
    argv_buf[argc] = "-T";
    argc += 1;

    // user@host
    const dest_len = conn.user().len + 1 + conn.host().len;
    @memcpy(dest_buf[0..conn.user().len], conn.user());
    dest_buf[conn.user().len] = '@';
    @memcpy(dest_buf[conn.user().len + 1 ..][0..conn.host().len], conn.host());
    argv_buf[argc] = dest_buf[0..dest_len];
    argc += 1;
    return argc;
}

const DrainResult = enum { complete, exceeded };

const DrainPipesResult = struct {
    stdout: DrainResult,
    stderr: DrainResult,
};

/// Read `reader` (anything with `read([]u8) !usize`) appending to `list`,
/// storing at most `max` bytes. The first byte beyond `max` yields
/// `.exceeded`: with `stop_on_exceed` the read loop aborts immediately (the
/// caller is expected to kill the producing child), otherwise the reader is
/// still drained to EOF so a child blocked on a full pipe can finish —
/// only storage stops.
fn drainCapped(
    reader: anytype,
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(u8),
    max: usize,
    stop_on_exceed: bool,
) !DrainResult {
    var exceeded = false;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try reader.read(&buf);
        if (n == 0) break;
        const take = @min(n, max - list.items.len);
        if (take > 0) try list.appendSlice(allocator, buf[0..take]);
        if (n > take) {
            exceeded = true;
            if (stop_on_exceed) return .exceeded;
        }
    }
    return if (exceeded) .exceeded else .complete;
}

fn DrainThreadCtx(comptime Reader: type) type {
    return struct {
        reader: Reader,
        allocator: std.mem.Allocator,
        list: *std.ArrayListUnmanaged(u8),
        max: usize,
        stop_on_exceed: bool,
        result: DrainResult = .complete,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            self.result = drainCapped(
                self.reader,
                self.allocator,
                self.list,
                self.max,
                self.stop_on_exceed,
            ) catch |err| {
                self.err = err;
                return;
            };
        }
    };
}

fn drainOutputPipesCapped(
    stdout_reader: anytype,
    stderr_reader: anytype,
    allocator: std.mem.Allocator,
    stdout_list: *std.ArrayListUnmanaged(u8),
    max_stdout: usize,
    stderr_list: *std.ArrayListUnmanaged(u8),
    max_stderr: usize,
) !DrainPipesResult {
    const StderrDrain = DrainThreadCtx(@TypeOf(stderr_reader));
    var stderr_ctx = StderrDrain{
        .reader = stderr_reader,
        .allocator = allocator,
        .list = stderr_list,
        .max = max_stderr,
        .stop_on_exceed = false,
    };
    const stderr_thread = try std.Thread.spawn(.{}, StderrDrain.run, .{&stderr_ctx});

    var stdout_err: ?anyerror = null;
    const stdout_result = drainCapped(stdout_reader, allocator, stdout_list, max_stdout, true) catch |err| blk: {
        stdout_err = err;
        break :blk DrainResult.exceeded;
    };

    stderr_thread.join();
    if (stderr_ctx.err) |err| return err;
    if (stdout_err) |err| return err;
    return .{
        .stdout = stdout_result,
        .stderr = stderr_ctx.result,
    };
}

/// Default ceiling for captured remote stdout: enough for any directory
/// listing / pwd, while bounding memory if a remote command unexpectedly
/// streams gigabytes. Callers that read whole files (e.g. PDF/image previews,
/// whose documents can exceed this) must use `sshExecCapped` with a cap sized
/// to their own read limit — otherwise ssh is killed mid-transfer.
pub const SSH_EXEC_MAX_STDOUT_BYTES: usize = 16 * 1024 * 1024;
/// stderr is diagnostics only; keep the first chunk for the error log.
const SSH_EXEC_MAX_STDERR_BYTES: usize = 16 * 1024;

/// Convert a caller timeout (ms) into a watchdog wait (ns). null = no watchdog
/// (0 disables it, preserving the historical unbounded behavior). Clamps to a
/// 120 s ceiling so a bad value can't effectively remove the cap.
pub fn watchdogTimeoutNs(timeout_ms: u64) ?u64 {
    if (timeout_ms == 0) return null;
    const clamped: u64 = @min(timeout_ms, WATCHDOG_CLAMP_MS);
    return clamped * std.time.ns_per_ms;
}

/// Ceiling for the ssh exec watchdog: a caller timeout above this is clamped so a
/// bad value can't effectively disable the kill.
const WATCHDOG_CLAMP_MS: u64 = 120_000;

pub const ExecOpts = struct {
    /// Hard wall-clock cap in ms. 0 = no watchdog (default). On expiry the ssh
    /// child is killed so a post-connect hang becomes a bounded failure.
    timeout_ms: u64 = 0,
};

const ExecWatchdog = struct {
    child: *std.process.Child,
    timeout_ns: u64,
    cancel: std.Thread.ResetEvent = .{},

    fn run(self: *ExecWatchdog) void {
        self.cancel.timedWait(self.timeout_ns) catch {
            // Timed out: kill by raw OS handle so the blocked stdout read sees
            // EOF and child.wait() can reap. (Does NOT touch Child state, so it
            // can't race the main thread's wait()/kill().)
            killChildRaw(self.child);
        };
    }
};

fn killChildRaw(child: *std.process.Child) void {
    switch (builtin.os.tag) {
        .windows => std.os.windows.TerminateProcess(child.id, 1) catch {},
        else => std.posix.kill(child.id, std.posix.SIG.KILL) catch {},
    }
}

/// Stop the watchdog and join it. MUST be called before any child.wait()/kill()
/// so the watchdog cannot fire on an already-reaped (and possibly recycled) pid.
fn disarmWatchdog(wd: *ExecWatchdog, thread: *?std.Thread) void {
    if (thread.*) |t| {
        wd.cancel.set();
        t.join();
        thread.* = null;
    }
}

/// Run `ssh user@host "<command>"` and capture stdout.
/// Returns allocated output slice on success, null on failure
/// (including stdout exceeding the default capture cap).
pub fn sshExec(allocator: std.mem.Allocator, conn: *const SshConnection, command: []const u8) ?[]u8 {
    return sshExecCapped(allocator, conn, command, SSH_EXEC_MAX_STDOUT_BYTES);
}

/// sshExec with an explicit stdout cap. If the remote command produces more
/// than `max_stdout_bytes`, the ssh child is killed and null is returned —
/// callers get a clean failure instead of an unbounded allocation (or, worse,
/// silently truncated file content that could be written back).
///
/// Preserved signature (no watchdog): used as a function pointer
/// (`SshExecCappedFn` in src/input/preview_source.zig). New callers that need a
/// wall-clock cap call `sshExecCappedOpts` directly.
pub fn sshExecCapped(allocator: std.mem.Allocator, conn: *const SshConnection, command: []const u8, max_stdout_bytes: usize) ?[]u8 {
    return sshExecCappedOpts(allocator, conn, command, max_stdout_bytes, .{});
}

/// sshExecCapped plus an optional wall-clock watchdog (see `ExecOpts`). On
/// timeout a background thread kills the ssh child by its raw OS handle so a
/// post-connect hang on the UI thread becomes a bounded failure.
pub fn sshExecCappedOpts(allocator: std.mem.Allocator, conn: *const SshConnection, command: []const u8, max_stdout_bytes: usize, opts: ExecOpts) ?[]u8 {
    var askpass_path: ?[]const u8 = null;
    defer if (askpass_path) |p| allocator.free(p);
    var env_map: ?std.process.EnvMap = null;
    defer if (env_map) |*map| map.deinit();

    if (conn.usesPasswordAuth()) {
        askpass_path = platform_process.ensureSshAskPassScript(allocator) orelse return null;
        env_map = std.process.getEnvMap(allocator) catch return null;
        if (env_map) |*map| {
            platform_process.putSshAskPassEnv(map, askpass_path.?, conn.password()) catch return null;
        }
    }

    const control_path: ?[]const u8 = null;

    var argv_buf: [40][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = platform_pty_command.sshExecutableName();
    argc += 1;

    argc = appendSshOptions(&argv_buf, argc, conn, .ssh, control_path);

    // user@host
    var dest_buf: [280]u8 = undefined;
    const dest_len = conn.user().len + 1 + conn.host().len;
    @memcpy(dest_buf[0..conn.user().len], conn.user());
    dest_buf[conn.user().len] = '@';
    @memcpy(dest_buf[conn.user().len + 1 ..][0..conn.host().len], conn.host());
    argv_buf[argc] = dest_buf[0..dest_len];
    argc += 1;

    argv_buf[argc] = command;
    argc += 1;

    var child = std.process.Child.init(argv_buf[0..argc], allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    // Capture stderr so a failed remote exec surfaces the real ssh error
    // (auth failure, host key, timeout) instead of a silent null.
    child.stderr_behavior = .Pipe;
    if (env_map) |*map| child.env_map = map;
    child.create_no_window = true;
    child.spawn() catch |err| {
        std.debug.print("sshExec: spawn failed: {}\n", .{err});
        return null;
    };

    // Wall-clock watchdog: kills the ssh child by raw OS handle on expiry so a
    // hung post-connect read can't block the caller forever. disarmWatchdog must
    // run before every child.wait()/child.kill() below (the defer is an
    // idempotent safety net for any early return that skips a wait).
    var wd = ExecWatchdog{ .child = &child, .timeout_ns = 0 };
    var wd_thread: ?std.Thread = null;
    if (watchdogTimeoutNs(opts.timeout_ms)) |ns| {
        wd.timeout_ns = ns;
        wd_thread = std.Thread.spawn(.{}, ExecWatchdog.run, .{&wd}) catch null;
    }
    defer disarmWatchdog(&wd, &wd_thread); // safety net; explicit disarms below run first

    // Read stdout, bounded: a runaway/oversized remote command must not grow
    // memory without limit. On exceed, kill ssh rather than read on.
    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(allocator);

    const stdout = child.stdout orelse {
        disarmWatchdog(&wd, &wd_thread);
        _ = child.wait() catch {};
        return null;
    };
    child.stdout = null;
    defer stdout.close();

    var stderr_text: std.ArrayListUnmanaged(u8) = .empty;
    defer stderr_text.deinit(allocator);
    const stderr = child.stderr orelse {
        disarmWatchdog(&wd, &wd_thread);
        _ = child.wait() catch {};
        return null;
    };
    child.stderr = null;
    defer stderr.close();

    const StderrDrain = DrainThreadCtx(@TypeOf(stderr));
    var stderr_ctx = StderrDrain{
        .reader = stderr,
        .allocator = allocator,
        .list = &stderr_text,
        .max = SSH_EXEC_MAX_STDERR_BYTES,
        .stop_on_exceed = false,
    };
    const stderr_thread = std.Thread.spawn(.{}, StderrDrain.run, .{&stderr_ctx}) catch |err| {
        std.debug.print("sshExec: stderr drain thread spawn failed: {}\n", .{err});
        disarmWatchdog(&wd, &wd_thread);
        _ = child.kill() catch {};
        return null;
    };

    const stdout_drain = drainCapped(stdout, allocator, &output, max_stdout_bytes, true) catch .exceeded;
    if (stdout_drain == .exceeded) {
        std.debug.print("sshExec: stdout exceeded {d} bytes; killing ssh\n", .{max_stdout_bytes});
        disarmWatchdog(&wd, &wd_thread);
        _ = child.kill() catch {};
        stderr_thread.join();
        return null;
    }

    stderr_thread.join();
    if (stderr_ctx.err) |err| {
        std.debug.print("sshExec: stderr drain failed: {}\n", .{err});
    }

    disarmWatchdog(&wd, &wd_thread);
    const term = child.wait() catch return null;
    const ok = switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        std.debug.print("sshExec: ssh exited non-zero (term={any}); stderr: {s}\n", .{ term, stderr_text.items });
        return null;
    }

    return output.toOwnedSlice(allocator) catch null;
}

fn runSshStreamTransfer(
    allocator: std.mem.Allocator,
    conn: *const SshConnection,
    src: []const u8,
    dst: []const u8,
    control_path: ?[]const u8,
    env_map: ?*std.process.EnvMap,
    control: *TransferControl,
) TransferResult {
    if (remotePathFromSpec(conn, dst)) |remote_path| {
        return sshStreamUpload(allocator, conn, src, remote_path, control_path, env_map, control);
    }
    if (remotePathFromSpec(conn, src)) |remote_path| {
        return sshStreamDownload(allocator, conn, remote_path, dst, control_path, env_map, control);
    }
    return .failed;
}

fn remotePathFromSpec(conn: *const SshConnection, spec: []const u8) ?[]const u8 {
    const user = conn.user();
    const host = conn.host();
    const prefix_len = user.len + 1 + host.len + 1;
    if (spec.len < prefix_len) return null;
    if (!std.mem.eql(u8, spec[0..user.len], user)) return null;
    if (spec[user.len] != '@') return null;
    if (!std.mem.eql(u8, spec[user.len + 1 .. user.len + 1 + host.len], host)) return null;
    if (spec[user.len + 1 + host.len] != ':') return null;
    return spec[prefix_len..];
}

fn localBasename(path: []const u8) []const u8 {
    var start: usize = 0;
    for (path, 0..) |ch, i| {
        if (ch == '\\' or ch == '/') start = i + 1;
    }
    return path[start..];
}

fn appendSlice(buf: *[2048]u8, pos: *usize, text: []const u8) bool {
    if (pos.* + text.len > buf.len) return false;
    @memcpy(buf[pos.*..][0..text.len], text);
    pos.* += text.len;
    return true;
}

fn appendShellQuote(buf: *[2048]u8, pos: *usize, arg: []const u8) bool {
    if (pos.* >= buf.len) return false;
    buf[pos.*] = '\'';
    pos.* += 1;
    for (arg) |ch| {
        if (ch == '\'') {
            if (!appendSlice(buf, pos, "'\\''")) return false;
        } else {
            if (pos.* >= buf.len) return false;
            buf[pos.*] = ch;
            pos.* += 1;
        }
    }
    if (pos.* >= buf.len) return false;
    buf[pos.*] = '\'';
    pos.* += 1;
    return true;
}

fn buildUploadCommand(buf: *[2048]u8, remote_path: []const u8, local_path: []const u8) ?[]const u8 {
    var pos: usize = 0;
    const basename = localBasename(local_path);
    if (basename.len == 0) return null;

    if (!appendSlice(buf, &pos, "if test -d ")) return null;
    if (!appendShellQuote(buf, &pos, remote_path)) return null;
    if (!appendSlice(buf, &pos, "; then cat > ")) return null;
    if (!appendShellQuote(buf, &pos, remote_path)) return null;
    if (!appendSlice(buf, &pos, "/")) return null;
    if (!appendShellQuote(buf, &pos, basename)) return null;
    if (!appendSlice(buf, &pos, "; else cat > ")) return null;
    if (!appendShellQuote(buf, &pos, remote_path)) return null;
    if (!appendSlice(buf, &pos, "; fi")) return null;
    return buf[0..pos];
}

fn buildDownloadCommand(buf: *[2048]u8, remote_path: []const u8) ?[]const u8 {
    var pos: usize = 0;
    if (!appendSlice(buf, &pos, "cat -- ")) return null;
    if (!appendShellQuote(buf, &pos, remote_path)) return null;
    return buf[0..pos];
}

/// Build `cat -- '<path>'` to stream a remote file's bytes to stdout.
pub fn buildRemoteReadCommand(buf: *[2048]u8, path: []const u8) ?[]const u8 {
    var pos: usize = 0;
    if (!appendSlice(buf, &pos, "cat -- ")) return null;
    if (!appendShellQuote(buf, &pos, path)) return null;
    return buf[0..pos];
}

/// Build `cat > '<tmp>' && mv -- '<tmp>' '<path>'` for an atomic remote write
/// (content arrives on stdin).
pub fn buildRemoteWriteCommand(buf: *[2048]u8, path: []const u8, tmp: []const u8) ?[]const u8 {
    var pos: usize = 0;
    if (!appendSlice(buf, &pos, "cat > ")) return null;
    if (!appendShellQuote(buf, &pos, tmp)) return null;
    if (!appendSlice(buf, &pos, " && mv -- ")) return null;
    if (!appendShellQuote(buf, &pos, tmp)) return null;
    if (!appendSlice(buf, &pos, " ")) return null;
    if (!appendShellQuote(buf, &pos, path)) return null;
    return buf[0..pos];
}

/// Read a remote file via `ssh ... cat`. Returns owned bytes, null on
/// failure — including files larger than `max_bytes`, mirroring the local
/// read_file cap. Failing outright (instead of truncating) matters: a
/// truncated read that is later written back would corrupt the remote file.
pub fn sshReadFile(allocator: std.mem.Allocator, conn: *const SshConnection, path: []const u8, max_bytes: usize) ?[]u8 {
    var buf: [2048]u8 = undefined;
    const cmd = buildRemoteReadCommand(&buf, path) orelse return null;
    return sshExecCapped(allocator, conn, cmd, max_bytes);
}

/// Write `content` to a remote file atomically (temp + mv) via `ssh ... cat >`.
pub fn sshWriteFile(allocator: std.mem.Allocator, conn: *const SshConnection, path: []const u8, content: []const u8) bool {
    var tmp_buf: [600]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.wispterm.tmp", .{path}) catch return false;
    var cmd_buf: [2048]u8 = undefined;
    const cmd = buildRemoteWriteCommand(&cmd_buf, path, tmp) orelse return false;
    return sshExecStdin(allocator, conn, cmd, content);
}

/// Run `ssh user@host "<command>"` piping `stdin_bytes` to the remote stdin.
/// Returns true on exit code 0. Mirrors `sshExec`'s askpass env setup.
fn sshExecStdin(allocator: std.mem.Allocator, conn: *const SshConnection, command: []const u8, stdin_bytes: []const u8) bool {
    var askpass_path: ?[]const u8 = null;
    defer if (askpass_path) |p| allocator.free(p);
    var env_map: ?std.process.EnvMap = null;
    defer if (env_map) |*map| map.deinit();

    if (conn.usesPasswordAuth()) {
        askpass_path = platform_process.ensureSshAskPassScript(allocator) orelse return false;
        env_map = std.process.getEnvMap(allocator) catch return false;
        if (env_map) |*map| {
            platform_process.putSshAskPassEnv(map, askpass_path.?, conn.password()) catch return false;
        }
    }

    const control_path: ?[]const u8 = null;

    var argv_buf: [40][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = platform_pty_command.sshExecutableName();
    argc += 1;

    argc = appendSshOptions(&argv_buf, argc, conn, .ssh, control_path);

    // user@host
    var dest_buf: [280]u8 = undefined;
    const dest_len = conn.user().len + 1 + conn.host().len;
    @memcpy(dest_buf[0..conn.user().len], conn.user());
    dest_buf[conn.user().len] = '@';
    @memcpy(dest_buf[conn.user().len + 1 ..][0..conn.host().len], conn.host());
    argv_buf[argc] = dest_buf[0..dest_len];
    argc += 1;

    argv_buf[argc] = command;
    argc += 1;

    var child = std.process.Child.init(argv_buf[0..argc], allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;
    if (env_map) |*map| child.env_map = map;
    child.create_no_window = true;
    child.spawn() catch |err| {
        std.debug.print("sshExecStdin: spawn failed: {}\n", .{err});
        return false;
    };

    if (child.stdin) |stdin| {
        var in = stdin;
        platform_process.writeAllToPipe(in, stdin_bytes) catch {};
        in.close();
        child.stdin = null;
    }

    var stderr_output: ?[]u8 = null;
    defer if (stderr_output) |stderr| allocator.free(stderr);
    if (child.stderr) |stderr| {
        stderr_output = stderr.readToEndAlloc(allocator, 16 * 1024) catch null;
    }

    const term = child.wait() catch return false;
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn openLocalRead(path: []const u8) ?std.fs.File {
    if (std.fs.path.isAbsolute(path)) return std.fs.openFileAbsolute(path, .{}) catch null;
    return std.fs.cwd().openFile(path, .{}) catch null;
}

fn createLocalWrite(path: []const u8) ?std.fs.File {
    if (std.fs.path.isAbsolute(path)) return std.fs.createFileAbsolute(path, .{ .truncate = true }) catch null;
    return std.fs.cwd().createFile(path, .{ .truncate = true }) catch null;
}

fn sshStreamUpload(
    allocator: std.mem.Allocator,
    conn: *const SshConnection,
    local_path: []const u8,
    remote_path: []const u8,
    control_path: ?[]const u8,
    env_map: ?*std.process.EnvMap,
    control: *TransferControl,
) TransferResult {
    if (control.cancelRequested()) return .cancelled;

    var file = openLocalRead(local_path) orelse return .failed;
    defer file.close();

    var command_buf: [2048]u8 = undefined;
    const command = buildUploadCommand(&command_buf, remote_path, local_path) orelse return .failed;

    var argv_buf: [40][]const u8 = undefined;
    var dest_buf: [280]u8 = undefined;
    var argc = appendSshExecPrefix(&argv_buf, conn, control_path, &dest_buf);
    argv_buf[argc] = command;
    argc += 1;

    var child = std.process.Child.init(argv_buf[0..argc], allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;
    if (env_map) |map| child.env_map = map;
    child.create_no_window = true;
    child.spawn() catch return .spawn_error;
    const child_id = child.id;
    control.registerChild(child_id);
    defer control.clearChild(child_id);

    var write_ok = true;
    if (child.stdin) |stdin| {
        var in = stdin;
        var buf: [16 * 1024]u8 = undefined;
        while (true) {
            if (control.cancelRequested()) {
                write_ok = false;
                break;
            }
            const n = file.read(&buf) catch {
                write_ok = false;
                break;
            };
            if (n == 0) break;
            platform_process.writeAllToPipe(in, buf[0..n]) catch {
                write_ok = false;
                break;
            };
        }
        in.close();
        // child.stdin still owns the same fd; nulling it prevents
        // Child.cleanupStreams from closing it again during wait() and
        // crashing on EBADF (Zig's posix.close treats EBADF as unreachable).
        child.stdin = null;
    } else {
        write_ok = false;
    }

    var stderr_output: ?[]u8 = null;
    defer if (stderr_output) |stderr| allocator.free(stderr);
    if (child.stderr) |stderr| {
        stderr_output = stderr.readToEndAlloc(allocator, 16 * 1024) catch null;
    }

    const term = child.wait() catch return .failed;
    if (control.cancelRequested()) return .cancelled;
    if (!write_ok) {
        logProcessFailure("SSH stream upload write failed", stderr_output);
        return .failed;
    }

    const result: TransferResult = switch (term) {
        .Exited => |code| if (code == 0) .ok else .failed,
        else => .failed,
    };
    if (result != .ok) logProcessFailure("SSH stream upload failed", stderr_output);
    return result;
}

fn sshStreamDownload(
    allocator: std.mem.Allocator,
    conn: *const SshConnection,
    remote_path: []const u8,
    local_path: []const u8,
    control_path: ?[]const u8,
    env_map: ?*std.process.EnvMap,
    control: *TransferControl,
) TransferResult {
    if (control.cancelRequested()) return .cancelled;

    var file = createLocalWrite(local_path) orelse return .failed;
    defer file.close();

    var command_buf: [2048]u8 = undefined;
    const command = buildDownloadCommand(&command_buf, remote_path) orelse return .failed;

    var argv_buf: [40][]const u8 = undefined;
    var dest_buf: [280]u8 = undefined;
    var argc = appendSshExecPrefix(&argv_buf, conn, control_path, &dest_buf);
    argv_buf[argc] = command;
    argc += 1;

    var child = std.process.Child.init(argv_buf[0..argc], allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    if (env_map) |map| child.env_map = map;
    child.create_no_window = true;
    child.spawn() catch return .spawn_error;
    const child_id = child.id;
    control.registerChild(child_id);
    defer control.clearChild(child_id);

    if (child.stdout) |stdout| {
        var buf: [16 * 1024]u8 = undefined;
        while (true) {
            if (control.cancelRequested()) break;
            const n = stdout.read(&buf) catch break;
            if (n == 0) break;
            file.writeAll(buf[0..n]) catch return .failed;
        }
    }

    var stderr_output: ?[]u8 = null;
    defer if (stderr_output) |stderr| allocator.free(stderr);
    if (child.stderr) |stderr| {
        stderr_output = stderr.readToEndAlloc(allocator, 16 * 1024) catch null;
    }

    const term = child.wait() catch return .failed;
    if (control.cancelRequested()) return .cancelled;
    const result: TransferResult = switch (term) {
        .Exited => |code| if (code == 0) .ok else .failed,
        else => .failed,
    };
    if (result != .ok) logProcessFailure("SSH stream download failed", stderr_output);
    return result;
}

fn logProcessFailure(label: []const u8, stderr_output: ?[]const u8) void {
    if (stderr_output) |stderr| {
        const trimmed = std.mem.trim(u8, stderr, " \t\r\n");
        if (trimmed.len > 0) {
            std.debug.print("{s}: {s}\n", .{ label, trimmed });
            return;
        }
    }
    std.debug.print("{s}\n", .{label});
}

fn appendSshOptions(
    argv_buf: *[40][]const u8,
    start_argc: usize,
    conn: *const SshConnection,
    port_mode: PortMode,
    control_path: ?[]const u8,
) usize {
    var argc = start_argc;
    argv_buf[argc] = "-o";
    argc += 1;
    argv_buf[argc] = "StrictHostKeyChecking=accept-new";
    argc += 1;
    argv_buf[argc] = "-o";
    argc += 1;
    argv_buf[argc] = "ConnectTimeout=8";
    argc += 1;
    if (conn.usesPasswordAuth()) {
        argv_buf[argc] = "-o";
        argc += 1;
        argv_buf[argc] = "PreferredAuthentications=publickey,password,keyboard-interactive";
        argc += 1;
        argv_buf[argc] = "-o";
        argc += 1;
        argv_buf[argc] = "NumberOfPasswordPrompts=1";
        argc += 1;
    } else {
        argv_buf[argc] = "-o";
        argc += 1;
        argv_buf[argc] = "BatchMode=yes";
        argc += 1;
    }
    if (conn.usesIdentityFile()) {
        argv_buf[argc] = "-i";
        argc += 1;
        argv_buf[argc] = conn.identityFile();
        argc += 1;
    }
    if (conn.legacy_algorithms) {
        argv_buf[argc] = "-o";
        argc += 1;
        argv_buf[argc] = "HostkeyAlgorithms=+ssh-rsa,ssh-dss";
        argc += 1;
        argv_buf[argc] = "-o";
        argc += 1;
        argv_buf[argc] = "PubkeyAcceptedAlgorithms=+ssh-rsa,ssh-dss";
        argc += 1;
        argv_buf[argc] = "-o";
        argc += 1;
        argv_buf[argc] = "KexAlgorithms=+diffie-hellman-group14-sha1,diffie-hellman-group1-sha1";
        argc += 1;
        argv_buf[argc] = "-o";
        argc += 1;
        argv_buf[argc] = "Ciphers=+aes128-cbc,3des-cbc";
        argc += 1;
    }
    if (conn.port().len > 0) {
        argv_buf[argc] = switch (port_mode) {
            .ssh => "-p",
            .scp => "-P",
        };
        argc += 1;
        argv_buf[argc] = conn.port();
        argc += 1;
    }
    if (control_path) |path| {
        argv_buf[argc] = "-o";
        argc += 1;
        argv_buf[argc] = "ControlMaster=auto";
        argc += 1;
        argv_buf[argc] = "-o";
        argc += 1;
        argv_buf[argc] = "ControlPersist=10m";
        argc += 1;
        argv_buf[argc] = "-o";
        argc += 1;
        argv_buf[argc] = path;
        argc += 1;
    }
    // Detect a dead post-connect session (ConnectTimeout only covers connect).
    // ~10 s to give up: ServerAliveInterval=5 x ServerAliveCountMax=2.
    argv_buf[argc] = "-o";
    argc += 1;
    argv_buf[argc] = "ServerAliveInterval=5";
    argc += 1;
    argv_buf[argc] = "-o";
    argc += 1;
    argv_buf[argc] = "ServerAliveCountMax=2";
    argc += 1;
    return argc;
}

fn sshControlPathOption(allocator: std.mem.Allocator) ?[]u8 {
    const temp_raw = platform_dirs.tempDir(allocator) catch return null;
    defer allocator.free(temp_raw);

    const trimmed = std.mem.trimRight(u8, temp_raw, "\\/");
    if (trimmed.len == 0) return null;

    var normalized: std.ArrayListUnmanaged(u8) = .empty;
    defer normalized.deinit(allocator);
    normalized.appendSlice(allocator, "ControlPath=") catch return null;
    for (trimmed) |ch| {
        normalized.append(allocator, if (ch == '\\') '/' else ch) catch return null;
    }
    normalized.appendSlice(allocator, "/wispterm-ssh-%C") catch return null;
    return normalized.toOwnedSlice(allocator) catch null;
}

// ============================================================================
// Tests
// ============================================================================

test "remoteSpec builds user@host:path" {
    var conn: SshConnection = .{};
    @memcpy(conn.user_buf[0..4], "root");
    conn.user_len = 4;
    @memcpy(conn.host_buf[0..11], "example.com");
    conn.host_len = 11;

    var buf: [512]u8 = undefined;
    const result = remoteSpec(&buf, &conn, "/home/data/file.txt");
    try std.testing.expectEqualStrings("root@example.com:/home/data/file.txt", result);
}

test "remoteSpec with empty path" {
    var conn: SshConnection = .{};
    @memcpy(conn.user_buf[0..5], "admin");
    conn.user_len = 5;
    @memcpy(conn.host_buf[0..7], "srv.lan");
    conn.host_len = 7;

    var buf: [512]u8 = undefined;
    const result = remoteSpec(&buf, &conn, "");
    try std.testing.expectEqualStrings("admin@srv.lan:", result);
}

test "remotePathFromSpec matches connection" {
    var conn: SshConnection = .{};
    @memcpy(conn.user_buf[0..10], "xuzhougeng");
    conn.user_len = 10;
    @memcpy(conn.host_buf[0..11], "10.10.87.92");
    conn.host_len = 11;

    const path = remotePathFromSpec(&conn, "xuzhougeng@10.10.87.92:/tmp/image.png") orelse unreachable;
    try std.testing.expectEqualStrings("/tmp/image.png", path);
    try std.testing.expect(remotePathFromSpec(&conn, "other@10.10.87.92:/tmp/image.png") == null);
}

test "appendShellQuote escapes single quotes" {
    var buf: [2048]u8 = undefined;
    var pos: usize = 0;
    try std.testing.expect(appendShellQuote(&buf, &pos, "/tmp/it's here.png"));
    try std.testing.expectEqualStrings("'/tmp/it'\\''s here.png'", buf[0..pos]);
}

fn containsArg(args: []const []const u8, needle: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, needle)) return true;
    }
    return false;
}

test "buildScpFlagArgs includes -r only for recursive transfers" {
    var conn: SshConnection = .{};
    conn.password_auth = false;
    conn.port_len = 0;

    var argv_buf: [40][]const u8 = undefined;

    // argv_buf is reused, so each build's slice must be asserted before the
    // next call overwrites it.
    const argc_file = buildScpFlagArgs(&argv_buf, &conn, null, false, false);
    try std.testing.expect(!containsArg(argv_buf[0..argc_file], "-r"));
    try std.testing.expect(containsArg(argv_buf[0..argc_file], "-q"));

    const argc_dir = buildScpFlagArgs(&argv_buf, &conn, null, false, true);
    try std.testing.expect(containsArg(argv_buf[0..argc_dir], "-r"));
    try std.testing.expect(containsArg(argv_buf[0..argc_dir], "-q"));

    // -O appears for legacy, and combines with -r for recursive+legacy
    const argc_legacy = buildScpFlagArgs(&argv_buf, &conn, null, true, false);
    try std.testing.expect(containsArg(argv_buf[0..argc_legacy], "-O"));
    try std.testing.expect(!containsArg(argv_buf[0..argc_legacy], "-r"));

    const argc_both = buildScpFlagArgs(&argv_buf, &conn, null, true, true);
    try std.testing.expect(containsArg(argv_buf[0..argc_both], "-r"));
    try std.testing.expect(containsArg(argv_buf[0..argc_both], "-O"));
}

test "buildUploadCommand handles target directories" {
    var buf: [2048]u8 = undefined;
    const command = buildUploadCommand(&buf, "/tmp", "C:\\Users\\me\\image.png") orelse unreachable;
    try std.testing.expectEqualStrings("if test -d '/tmp'; then cat > '/tmp'/'image.png'; else cat > '/tmp'; fi", command);
}

test "appendSshOptions key-based auth" {
    var conn: SshConnection = .{};
    conn.password_auth = false;
    conn.port_len = 0;

    var argv_buf: [40][]const u8 = undefined;
    const argc = appendSshOptions(&argv_buf, 0, &conn, .ssh, null);
    // Strict + ConnectTimeout + BatchMode (6) + ServerAliveInterval/CountMax (4) = 10
    try std.testing.expectEqual(@as(usize, 10), argc);
    try std.testing.expectEqualStrings("BatchMode=yes", argv_buf[5]);
    try std.testing.expectEqualStrings("ServerAliveInterval=5", argv_buf[7]);
    try std.testing.expectEqualStrings("ServerAliveCountMax=2", argv_buf[9]);
}

test "appendSshOptions password auth" {
    var conn: SshConnection = .{};
    conn.password_auth = true;
    conn.port_len = 0;

    var argv_buf: [40][]const u8 = undefined;
    const argc = appendSshOptions(&argv_buf, 0, &conn, .ssh, null);
    // Strict + ConnectTimeout + Preferred + NumPasswords (8) + ServerAlive (4) = 12
    try std.testing.expectEqual(@as(usize, 12), argc);
    try std.testing.expectEqualStrings("NumberOfPasswordPrompts=1", argv_buf[7]);
}

test "appendSshOptions with ssh port" {
    var conn: SshConnection = .{};
    conn.password_auth = false;
    @memcpy(conn.port_buf[0..4], "2222");
    conn.port_len = 4;

    var argv_buf: [40][]const u8 = undefined;
    const argc = appendSshOptions(&argv_buf, 0, &conn, .ssh, null);
    // 6 (base key-auth) + 2 (-p 2222) + 4 (ServerAlive) = 12
    try std.testing.expectEqual(@as(usize, 12), argc);
    try std.testing.expectEqualStrings("-p", argv_buf[6]);
    try std.testing.expectEqualStrings("2222", argv_buf[7]);
}

test "appendSshOptions with scp port" {
    var conn: SshConnection = .{};
    conn.password_auth = false;
    @memcpy(conn.port_buf[0..4], "2222");
    conn.port_len = 4;

    var argv_buf: [40][]const u8 = undefined;
    const argc = appendSshOptions(&argv_buf, 0, &conn, .scp, null);
    // 6 (base key-auth) + 2 (-P 2222) + 4 (ServerAlive) = 12
    try std.testing.expectEqual(@as(usize, 12), argc);
    try std.testing.expectEqualStrings("-P", argv_buf[6]);
    try std.testing.expectEqualStrings("2222", argv_buf[7]);
}

test "appendSshOptions with control path" {
    var conn: SshConnection = .{};
    conn.password_auth = false;
    conn.port_len = 0;

    var argv_buf: [40][]const u8 = undefined;
    const argc = appendSshOptions(&argv_buf, 0, &conn, .ssh, "ControlPath=C:/Temp/wispterm-ssh-%C");
    // 6 (base key-auth) + 6 (control path) + 4 (ServerAlive) = 16
    try std.testing.expectEqual(@as(usize, 16), argc);
    try std.testing.expectEqualStrings("ControlMaster=auto", argv_buf[7]);
    try std.testing.expectEqualStrings("ControlPersist=10m", argv_buf[9]);
    try std.testing.expectEqualStrings("ControlPath=C:/Temp/wispterm-ssh-%C", argv_buf[11]);
}

test "appendSshOptions includes legacy algorithms when enabled" {
    var conn: SshConnection = .{};
    conn.password_auth = false;
    conn.legacy_algorithms = true;

    var argv_buf: [40][]const u8 = undefined;
    const argc = appendSshOptions(&argv_buf, 0, &conn, .ssh, null);
    // 6 (base key-auth) + 8 (legacy algorithms) + 4 (ServerAlive) = 18
    try std.testing.expectEqual(@as(usize, 18), argc);
    try std.testing.expectEqualStrings("HostkeyAlgorithms=+ssh-rsa,ssh-dss", argv_buf[7]);
    try std.testing.expectEqualStrings("PubkeyAcceptedAlgorithms=+ssh-rsa,ssh-dss", argv_buf[9]);
    try std.testing.expectEqualStrings("KexAlgorithms=+diffie-hellman-group14-sha1,diffie-hellman-group1-sha1", argv_buf[11]);
    try std.testing.expectEqualStrings("Ciphers=+aes128-cbc,3des-cbc", argv_buf[13]);
}

test "buildRemoteReadCommand quotes the path" {
    var buf: [2048]u8 = undefined;
    const cmd = buildRemoteReadCommand(&buf, "/tmp/a b.txt").?;
    try std.testing.expectEqualStrings("cat -- '/tmp/a b.txt'", cmd);
}

test "buildRemoteWriteCommand builds an atomic temp+mv" {
    var buf: [2048]u8 = undefined;
    const cmd = buildRemoteWriteCommand(&buf, "/tmp/a.txt", "/tmp/a.txt.tmp").?;
    try std.testing.expectEqualStrings("cat > '/tmp/a.txt.tmp' && mv -- '/tmp/a.txt.tmp' '/tmp/a.txt'", cmd);
}

/// Test stand-in for a pipe: serves `data` in chunks of at most `chunk` bytes.
const FakePipeReader = struct {
    data: []const u8,
    chunk: usize,
    pos: usize = 0,

    fn read(self: *FakePipeReader, buf: []u8) !usize {
        const remaining = self.data[self.pos..];
        if (remaining.len == 0) return 0;
        const n = @min(@min(buf.len, remaining.len), self.chunk);
        @memcpy(buf[0..n], remaining[0..n]);
        self.pos += n;
        return n;
    }
};

test "drainCapped reads everything when under the cap" {
    var reader = FakePipeReader{ .data = "hello world", .chunk = 4 };
    var list: std.ArrayListUnmanaged(u8) = .empty;
    defer list.deinit(std.testing.allocator);

    const result = try drainCapped(&reader, std.testing.allocator, &list, 64, true);

    try std.testing.expectEqual(DrainResult.complete, result);
    try std.testing.expectEqualStrings("hello world", list.items);
}

test "drainCapped stops at the cap when asked to abort on exceed" {
    var reader = FakePipeReader{ .data = "x" ** 100, .chunk = 7 };
    var list: std.ArrayListUnmanaged(u8) = .empty;
    defer list.deinit(std.testing.allocator);

    const result = try drainCapped(&reader, std.testing.allocator, &list, 10, true);

    try std.testing.expectEqual(DrainResult.exceeded, result);
    try std.testing.expect(list.items.len <= 10);
    // Aborted: the reader must NOT have been drained to EOF.
    try std.testing.expect(reader.pos < reader.data.len);
}

test "drainCapped keeps draining to EOF when storage is capped" {
    var reader = FakePipeReader{ .data = "y" ** 100, .chunk = 7 };
    var list: std.ArrayListUnmanaged(u8) = .empty;
    defer list.deinit(std.testing.allocator);

    const result = try drainCapped(&reader, std.testing.allocator, &list, 10, false);

    try std.testing.expectEqual(DrainResult.exceeded, result);
    try std.testing.expectEqualStrings("y" ** 10, list.items);
    // Fully drained so a child blocked on the pipe can exit.
    try std.testing.expectEqual(reader.data.len, reader.pos);
}

test "drainCapped output exactly at the cap is complete" {
    var reader = FakePipeReader{ .data = "z" ** 10, .chunk = 3 };
    var list: std.ArrayListUnmanaged(u8) = .empty;
    defer list.deinit(std.testing.allocator);

    const result = try drainCapped(&reader, std.testing.allocator, &list, 10, true);

    try std.testing.expectEqual(DrainResult.complete, result);
    try std.testing.expectEqualStrings("z" ** 10, list.items);
}

const StderrSignalReader = struct {
    data: []const u8,
    started: *std.atomic.Value(bool),
    pos: usize = 0,

    fn read(self: *StderrSignalReader, buf: []u8) !usize {
        self.started.store(true, .release);
        const remaining = self.data[self.pos..];
        if (remaining.len == 0) return 0;
        const n = @min(buf.len, remaining.len);
        @memcpy(buf[0..n], remaining[0..n]);
        self.pos += n;
        return n;
    }
};

const StdoutRequiresStderrReader = struct {
    data: []const u8,
    stderr_started: *std.atomic.Value(bool),
    pos: usize = 0,

    fn read(self: *StdoutRequiresStderrReader, buf: []u8) !usize {
        var spins: usize = 0;
        while (!self.stderr_started.load(.acquire) and spins < 200) : (spins += 1) {
            std.Thread.sleep(std.time.ns_per_ms);
        }
        if (!self.stderr_started.load(.acquire)) return error.StderrNotDrained;
        const remaining = self.data[self.pos..];
        if (remaining.len == 0) return 0;
        const n = @min(buf.len, remaining.len);
        @memcpy(buf[0..n], remaining[0..n]);
        self.pos += n;
        return n;
    }
};

test "drainOutputPipesCapped starts stderr draining before waiting for stdout EOF" {
    var stderr_started = std.atomic.Value(bool).init(false);
    var stdout = StdoutRequiresStderrReader{ .data = "out", .stderr_started = &stderr_started };
    var stderr = StderrSignalReader{ .data = "err", .started = &stderr_started };
    var stdout_list: std.ArrayListUnmanaged(u8) = .empty;
    defer stdout_list.deinit(std.testing.allocator);
    var stderr_list: std.ArrayListUnmanaged(u8) = .empty;
    defer stderr_list.deinit(std.testing.allocator);

    const result = try drainOutputPipesCapped(
        &stdout,
        &stderr,
        std.testing.allocator,
        &stdout_list,
        64,
        &stderr_list,
        64,
    );

    try std.testing.expectEqual(DrainPipesResult{ .stdout = .complete, .stderr = .complete }, result);
    try std.testing.expectEqualStrings("out", stdout_list.items);
    try std.testing.expectEqualStrings("err", stderr_list.items);
}

test "watchdogTimeoutNs: 0 disables the watchdog" {
    try std.testing.expectEqual(@as(?u64, null), watchdogTimeoutNs(0));
}

test "watchdogTimeoutNs: converts ms to ns and clamps to the ceiling" {
    try std.testing.expectEqual(@as(?u64, 5_000 * std.time.ns_per_ms), watchdogTimeoutNs(5_000));
    try std.testing.expectEqual(@as(?u64, 120_000 * std.time.ns_per_ms), watchdogTimeoutNs(10_000_000));
}
