const std = @import("std");
const builtin = @import("builtin");
const platform_dirs = @import("dirs.zig");

/// Mutex name for single-instance detection (session-local, per-user).
const MUTEX_NAME = "Local\\WispTerm-SingleInstance";

/// Discovery file written by the first instance so second instances can
/// find the IPC port and verify the owning process is still alive.
const DISCOVERY_BASENAME = "single-instance.json";

const MAX_PATH_BYTES = 4096;

// ── Mutex (detection) ───────────────────────────────────────────────────────

var g_mutex_handle: ?std.os.windows.HANDLE = null;

fn createMutex() !void {
    if (g_mutex_handle != null) return;
    const name_w = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, MUTEX_NAME);
    defer std.heap.page_allocator.free(name_w);

    const handle = CreateMutexW(null, 0, name_w.ptr) orelse return error.CreateMutexFailed;
    if (std.os.windows.kernel32.GetLastError() == .ALREADY_EXISTS) {
        std.os.windows.CloseHandle(handle);
        return error.AlreadyExists;
    }
    g_mutex_handle = handle;
}

extern "kernel32" fn CreateMutexW(
    lpMutexAttributes: ?*anyopaque,
    bInitialOwner: std.os.windows.BOOL,
    lpName: std.os.windows.LPCWSTR,
) callconv(.winapi) ?std.os.windows.HANDLE;

/// Check whether a process with the given PID is still running.
/// Uses OpenProcess + WaitForSingleObject(0) (non-blocking).
fn isProcessAlive(pid: u32) bool {
    const SYNCHRONIZE: u32 = 0x00100000;
    const handle = OpenProcess(SYNCHRONIZE, 0, pid) orelse return false;
    defer std.os.windows.CloseHandle(handle);
    const WAIT_OBJECT_0: u32 = 0x00000000;
    const WAIT_TIMEOUT: u32 = 0x00000102;
    const result = WaitForSingleObject(handle, 0);
    return result == WAIT_TIMEOUT or result == WAIT_OBJECT_0;
}

extern "kernel32" fn OpenProcess(
    dwDesiredAccess: u32,
    bInheritHandle: std.os.windows.BOOL,
    dwProcessId: u32,
) callconv(.winapi) ?std.os.windows.HANDLE;

extern "kernel32" fn WaitForSingleObject(
    hHandle: std.os.windows.HANDLE,
    dwMilliseconds: u32,
) callconv(.winapi) u32;

extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;

// ── Discovery file ──────────────────────────────────────────────────────────

const Discovery = struct {
    port: u16,
    pid: u32,

    fn filePath(allocator: std.mem.Allocator) ![]const u8 {
        return platform_dirs.pathInConfigDir(allocator, DISCOVERY_BASENAME);
    }

    fn write(allocator: std.mem.Allocator, info: Discovery) !void {
        const path = try filePath(allocator);
        defer allocator.free(path);
        const body = try std.fmt.allocPrint(allocator, "{{\"port\":{d},\"pid\":{d}}}", .{ info.port, info.pid });
        defer allocator.free(body);
        if (std.fs.path.dirname(path)) |dir| std.fs.cwd().makePath(dir) catch {};
        std.fs.cwd().deleteFile(path) catch {};
        var file = try std.fs.cwd().createFile(path, .{ .mode = 0o600 });
        defer file.close();
        try file.writeAll(body);
    }

    fn read(allocator: std.mem.Allocator) !?Discovery {
        const path = try filePath(allocator);
        defer allocator.free(path);
        const content = std.fs.cwd().readFileAlloc(allocator, path, 4096) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer allocator.free(content);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidDiscovery;
        const port_v = parsed.value.object.get("port") orelse return error.InvalidDiscovery;
        if (port_v != .integer) return error.InvalidDiscovery;
        if (port_v.integer <= 0 or port_v.integer > 65535) return error.InvalidDiscovery;
        // pid is optional for backward compat with older discovery files,
        // but required for liveness checks when present.
        const pid_v = parsed.value.object.get("pid");
        const pid: u32 = if (pid_v) |v| switch (v) {
            .integer => |i| if (i <= 0) return error.InvalidDiscovery else @intCast(i),
            else => return error.InvalidDiscovery,
        } else 0;
        return .{ .port = @intCast(port_v.integer), .pid = pid };
    }

    fn remove(allocator: std.mem.Allocator) void {
        const path = filePath(allocator) catch return;
        defer allocator.free(path);
        std.fs.cwd().deleteFile(path) catch {};
    }
};

// ── Public API ──────────────────────────────────────────────────────────────

pub fn acquire(allocator: std.mem.Allocator) !@import("single_instance.zig").Role {
    _ = allocator;
    createMutex() catch |err| switch (err) {
        error.AlreadyExists => return .second,
        // If mutex creation fails for any other reason (access denied, etc.),
        // propagate the error rather than silently claiming first instance.
        else => return err,
    };
    return .first;
}

pub fn release(allocator: std.mem.Allocator) void {
    Discovery.remove(allocator);
    if (g_mutex_handle) |handle| {
        std.os.windows.CloseHandle(handle);
        g_mutex_handle = null;
    }
}

// ── IPC Server ──────────────────────────────────────────────────────────────

/// Cwd received from a second instance.
pub const IncomingCwd = struct {
    cwd: []u8,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    listener: std.net.Server,
    port: u16,
    thread: ?std.Thread,
    stop_flag: std.atomic.Value(bool),
    pending_mutex: std.Thread.Mutex,
    pending_cwd: ?[]u8,
    pending_cwd_ready: std.atomic.Value(bool),
    /// Set whenever any second instance connects, even if no CWD is forwarded.
    /// The UI thread checks this to bring the window to the foreground.
    pending_activate: std.atomic.Value(bool),

    pub fn start(allocator: std.mem.Allocator) !*Server {
        const address = try std.net.Address.parseIp4("127.0.0.1", 0);
        var listener = try address.listen(.{ .reuse_address = true });
        errdefer listener.deinit();

        const port = listener.listen_address.getPort();
        try Discovery.write(allocator, .{ .port = port, .pid = GetCurrentProcessId() });
        errdefer Discovery.remove(allocator);

        const self = try allocator.create(Server);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .listener = listener,
            .port = port,
            .thread = null,
            .stop_flag = std.atomic.Value(bool).init(false),
            .pending_mutex = .{},
            .pending_cwd = null,
            .pending_cwd_ready = std.atomic.Value(bool).init(false),
            .pending_activate = std.atomic.Value(bool).init(false),
        };
        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
        return self;
    }

    pub fn stop(self: *Server) void {
        if (self.thread == null) return;
        self.stop_flag.store(true, .release);
        if (std.net.Address.parseIp4("127.0.0.1", self.port)) |addr| {
            if (std.net.tcpConnectToAddress(addr)) |s| s.close() else |_| {}
        } else |_| {}
        self.thread.?.join();
        self.thread = null;
    }

    pub fn destroy(self: *Server) void {
        self.stop();
        self.listener.deinit();
        self.pending_mutex.lock();
        if (self.pending_cwd) |cwd| self.allocator.free(cwd);
        self.pending_mutex.unlock();
        self.allocator.destroy(self);
    }

    /// Non-blocking check for a pending cwd from a second instance.
    /// Returns null if none is available. Caller owns the returned slice.
    pub fn tryTakeCwd(self: *Server) ?[]u8 {
        if (!self.pending_cwd_ready.load(.acquire)) return null;
        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();
        const cwd = self.pending_cwd orelse {
            std.debug.print("[single-instance] tryTakeCwd: ready but pending_cwd is null\n", .{});
            return null;
        };
        self.pending_cwd = null;
        self.pending_cwd_ready.store(false, .release);
        std.debug.print("[single-instance] tryTakeCwd: returning '{s}'\n", .{cwd});
        return cwd;
    }

    /// Non-blocking check for a pending activate request from a second instance.
    /// Returns true if a second instance connected and the window should be
    /// brought to the foreground.
    pub fn tryTakeActivate(self: *Server) bool {
        const result = self.pending_activate.swap(false, .acq_rel);
        if (result) std.debug.print("[single-instance] tryTakeActivate: true\n", .{});
        return result;
    }

    fn acceptLoop(self: *Server) void {
        while (!self.stop_flag.load(.acquire)) {
            const conn = self.listener.accept() catch {
                if (self.stop_flag.load(.acquire)) return;
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            };
            defer conn.stream.close();
            if (self.stop_flag.load(.acquire)) return;
            self.handleConnection(conn.stream) catch {};
        }
    }

    fn handleConnection(self: *Server, stream: std.net.Stream) !void {
        // Use ws2_32.recv directly instead of stream.read — Zig 0.15.2's
        // std.net.Stream.read calls ReadFile on the socket handle, which
        // returns ERROR_INVALID_PARAMETER(87) on Windows.
        const ws2 = std.os.windows.ws2_32;

        var buf: [MAX_PATH_BYTES]u8 = undefined;
        var buf_len: usize = 0;

        while (buf_len < buf.len) {
            const recv_result = ws2.recv(stream.handle, buf[buf_len..].ptr, @intCast(buf.len - buf_len), 0);
            if (recv_result <= 0) {
                if (recv_result < 0) std.debug.print("[single-instance] recv error after {d} bytes: ws2_error={d}\n", .{ buf_len, ws2.WSAGetLastError() });
                break;
            }
            const n: usize = @intCast(recv_result);
            buf_len += n;
            if (std.mem.indexOfScalar(u8, buf[0..buf_len], '\n') != null) break;
        }

        // Remove trailing newline
        var cwd_len = buf_len;
        if (cwd_len > 0 and buf[cwd_len - 1] == '\n') cwd_len -= 1;

        std.debug.print("[single-instance] received {d} bytes (cwd_len={d}): '{s}'\n", .{ buf_len, cwd_len, buf[0..cwd_len] });

        // Always signal activation — a second instance connected, so the
        // window should be brought to the foreground regardless of whether
        // a CWD path was forwarded.
        self.pending_activate.store(true, .release);

        if (cwd_len == 0) return;

        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();
        if (self.pending_cwd) |old| self.allocator.free(old);
        self.pending_cwd = self.allocator.dupe(u8, buf[0..cwd_len]) catch return;
        self.pending_cwd_ready.store(true, .release);
        std.debug.print("[single-instance] pending_cwd set, ready=true\n", .{});
    }
};

// ── Client (second instance) ────────────────────────────────────────────────

/// Connect to the running instance and forward the given path (or the current
/// working directory, when path is null). Returns false if the running instance
/// could not be reached.
pub fn forwardCwd(allocator: std.mem.Allocator, path: ?[]const u8) bool {
    const info = Discovery.read(allocator) catch return false;
    if (info == null) return false;

    // Quick liveness check: if the PID from the discovery file is no longer
    // alive, the discovery file is stale (first instance crashed). Clean up
    // and return false so the caller can re-acquire the mutex.
    if (info.?.pid != 0 and !isProcessAlive(info.?.pid)) {
        Discovery.remove(allocator);
        return false;
    }

    const addr = std.net.Address.parseIp4("127.0.0.1", info.?.port) catch return false;
    var stream = std.net.tcpConnectToAddress(addr) catch return false;
    defer stream.close();

    // Forward the raw path argument as-is (do NOT resolve via realpath).
    // realpath resolves drive-relative paths like "e:" to the current
    // directory on that drive, which changes the semantics: the user typed
    // "e:" and expects the first instance's PTY to interpret it, just as
    // it would if the first instance received the argument directly.
    // When no path is provided, forward the process CWD.
    var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
    const payload = if (path) |p| p else std.process.getCwd(&resolved_buf) catch return false;

    // Use ws2_32.send directly — stream.writeAll calls WriteFile which fails
    // on socket handles (same issue as recv/ReadFile).
    const ws2 = std.os.windows.ws2_32;
    var send_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const combined = std.fmt.bufPrint(&send_buf, "{s}\n", .{payload}) catch return false;
    const send_result = ws2.send(stream.handle, combined.ptr, @intCast(combined.len), 0);
    if (send_result <= 0) return false;

    std.debug.print("[single-instance] forwardCwd: sent {d} bytes '{s}'\n", .{ payload.len, payload });
    return true;
}
