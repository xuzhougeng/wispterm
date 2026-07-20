const std = @import("std");
const builtin = @import("builtin");
const platform_dirs = @import("dirs.zig");

/// Mutex name for single-instance detection (session-local, per-user).
const MUTEX_NAME = "Local\\WispTerm-SingleInstance";

/// Discovery file written by the first instance so second instances can
/// find the IPC port.
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

// ── Discovery file ──────────────────────────────────────────────────────────

const Discovery = struct {
    port: u16,

    fn filePath(allocator: std.mem.Allocator) ![]const u8 {
        return platform_dirs.pathInConfigDir(allocator, DISCOVERY_BASENAME);
    }

    fn write(allocator: std.mem.Allocator, info: Discovery) !void {
        const path = try filePath(allocator);
        defer allocator.free(path);
        const body = try std.fmt.allocPrint(allocator, "{{\"port\":{d}}}", .{info.port});
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
        return .{ .port = @intCast(port_v.integer) };
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
        else => {
            return .first;
        },
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

const READ_TIMEOUT_MS: u32 = 3000;

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

    pub fn start(allocator: std.mem.Allocator) !*Server {
        const address = try std.net.Address.parseIp4("127.0.0.1", 0);
        var listener = try address.listen(.{ .reuse_address = true });
        errdefer listener.deinit();

        const port = listener.listen_address.getPort();
        try Discovery.write(allocator, .{ .port = port });
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
        const cwd = self.pending_cwd orelse return null;
        self.pending_cwd = null;
        self.pending_cwd_ready.store(false, .release);
        return cwd;
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
        setReadTimeout(stream.handle, READ_TIMEOUT_MS);

        var buf: [MAX_PATH_BYTES]u8 = undefined;
        var buf_len: usize = 0;

        while (buf_len < buf.len) {
            const n = stream.read(buf[buf_len..]) catch break;
            if (n == 0) break;
            buf_len += n;
            if (std.mem.indexOfScalar(u8, buf[0..buf_len], '\n') != null) break;
        }

        // Remove trailing newline
        var cwd_len = buf_len;
        if (cwd_len > 0 and buf[cwd_len - 1] == '\n') cwd_len -= 1;

        if (cwd_len == 0) return;

        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();
        if (self.pending_cwd) |old| self.allocator.free(old);
        self.pending_cwd = self.allocator.dupe(u8, buf[0..cwd_len]) catch return;
        self.pending_cwd_ready.store(true, .release);
    }
};

/// Best-effort read timeout for the IPC connection.
fn setReadTimeout(handle: std.net.Stream.Handle, ms: u32) void {
    if (builtin.os.tag == .windows) {
        const ws2 = std.os.windows.ws2_32;
        const timeout: u32 = ms;
        _ = ws2.setsockopt(handle, ws2.SOL.SOCKET, ws2.SO.RCVTIMEO, @ptrCast(&timeout), @sizeOf(u32));
    }
}

// ── Client (second instance) ────────────────────────────────────────────────

/// Connect to the running instance and forward the given path (or the current
/// working directory, when path is null). Returns false if the running instance
/// could not be reached.
pub fn forwardCwd(allocator: std.mem.Allocator, path: ?[]const u8) bool {
    const info = Discovery.read(allocator) catch return false;
    if (info == null) return false;

    const addr = std.net.Address.parseIp4("127.0.0.1", info.?.port) catch return false;
    var stream = std.net.tcpConnectToAddress(addr) catch return false;
    defer stream.close();

    // Resolve to absolute path so the first instance has the same directory,
    // regardless of which CWD its process was launched in.
    var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
    const payload = if (path) |p|
        std.fs.realpath(p, &resolved_buf) catch p
    else
        std.process.getCwd(&resolved_buf) catch return false;

    stream.writeAll(payload) catch return false;
    stream.writeAll("\n") catch return false;

    return true;
}
