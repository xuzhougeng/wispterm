//! Where sync files live: a WebDAV collection (坚果云/Jianguoyun, Nextcloud,
//! Synology, InfiniCloud, …) or a local folder that a drive client (OneDrive,
//! iCloud Drive, Dropbox) uploads for us. Both expose the same three calls on
//! names relative to the sync root (`wispterm-sync.json`, `history/<id>.wsync`);
//! the data is already sealed by sync/crypto.zig before it gets here.
const std = @import("std");
const http_client = @import("../platform/http_client.zig");
const platform_atomic_file = @import("../platform/atomic_file.zig");

/// Largest file sync reads back (one agent-history session can be big).
pub const MAX_FILE_BYTES: usize = 64 * 1024 * 1024;

pub const Transport = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// null = the file does not exist.
        get: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!?[]u8,
        put: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8, data: []const u8) anyerror!void,
        /// A missing file is not an error.
        delete: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!void,
    };

    pub fn get(self: Transport, allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
        return self.vtable.get(self.ctx, allocator, name);
    }

    pub fn put(self: Transport, allocator: std.mem.Allocator, name: []const u8, data: []const u8) !void {
        return self.vtable.put(self.ctx, allocator, name, data);
    }

    pub fn delete(self: Transport, allocator: std.mem.Allocator, name: []const u8) !void {
        return self.vtable.delete(self.ctx, allocator, name);
    }
};

// ---------------------------------------------------------------------------
// Synced folder
// ---------------------------------------------------------------------------

pub const Folder = struct {
    root: []const u8,

    pub fn transport(self: *Folder) Transport {
        return .{ .ctx = self, .vtable = &folder_vtable };
    }

    fn pathFor(self: *Folder, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
        const native = try allocator.dupe(u8, name);
        defer allocator.free(native);
        if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, native, '/', std.fs.path.sep);
        return std.fs.path.join(allocator, &.{ self.root, native });
    }

    fn get(ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!?[]u8 {
        const self: *Folder = @ptrCast(@alignCast(ctx));
        try self.checkRoot();
        const p = try self.pathFor(allocator, name);
        defer allocator.free(p);
        return std.fs.cwd().readFileAlloc(allocator, p, MAX_FILE_BYTES) catch |err| switch (err) {
            error.FileNotFound => null,
            else => err,
        };
    }

    fn put(ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8, data: []const u8) anyerror!void {
        const self: *Folder = @ptrCast(@alignCast(ctx));
        const p = try self.pathFor(allocator, name);
        defer allocator.free(p);
        if (std.fs.path.dirname(p)) |dir| try std.fs.cwd().makePath(dir);
        try platform_atomic_file.writeFileReplaceSafe(p, data);
    }

    fn delete(ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!void {
        const self: *Folder = @ptrCast(@alignCast(ctx));
        const p = try self.pathFor(allocator, name);
        defer allocator.free(p);
        std.fs.cwd().deleteFile(p) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    /// A drive folder that is not mounted (unplugged disk, signed-out client)
    /// must read as an error, not as "empty drive" that would re-upload all.
    fn checkRoot(self: *Folder) !void {
        var dir = std.fs.cwd().openDir(self.root, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.SyncFolderMissing,
            else => return err,
        };
        dir.close();
    }

    const folder_vtable: Transport.VTable = .{ .get = get, .put = put, .delete = delete };
};

// ---------------------------------------------------------------------------
// WebDAV
// ---------------------------------------------------------------------------

pub const FetchFn = *const fn (allocator: std.mem.Allocator, request: http_client.Request) anyerror!http_client.Response;

pub const WebDav = struct {
    allocator: std.mem.Allocator,
    /// `https://host/dav` without a trailing slash.
    base_url: []u8,
    /// Percent-encoded remote folder path, e.g. `WispTerm` or `a/b`; may be empty.
    folder: []u8,
    /// `Basic …` header value; wiped on deinit.
    authorization: []u8,
    fetch_fn: FetchFn = http_client.fetch,
    timeout_ms: u32 = 30_000,
    /// HTTP status of the last failed request, for the status message.
    last_status: u16 = 0,

    pub fn init(allocator: std.mem.Allocator, url: []const u8, folder: []const u8, username: []const u8, password: []const u8) !WebDav {
        const trimmed = std.mem.trimRight(u8, std.mem.trim(u8, url, " \t\r\n"), "/");
        if (!std.ascii.startsWithIgnoreCase(trimmed, "https://") and !std.ascii.startsWithIgnoreCase(trimmed, "http://")) return error.InvalidSyncUrl;
        _ = std.Uri.parse(trimmed) catch return error.InvalidSyncUrl;
        const base_url = try allocator.dupe(u8, trimmed);
        errdefer allocator.free(base_url);
        const encoded_folder = try encodePath(allocator, std.mem.trim(u8, folder, " \t/\\"));
        errdefer allocator.free(encoded_folder);

        const credentials = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ username, password });
        defer {
            std.crypto.secureZero(u8, credentials);
            allocator.free(credentials);
        }
        const enc = std.base64.standard.Encoder;
        const authorization = try allocator.alloc(u8, "Basic ".len + enc.calcSize(credentials.len));
        @memcpy(authorization[0.."Basic ".len], "Basic ");
        _ = enc.encode(authorization["Basic ".len..], credentials);
        return .{ .allocator = allocator, .base_url = base_url, .folder = encoded_folder, .authorization = authorization };
    }

    pub fn deinit(self: *WebDav) void {
        std.crypto.secureZero(u8, self.authorization);
        self.allocator.free(self.authorization);
        self.allocator.free(self.folder);
        self.allocator.free(self.base_url);
        self.* = undefined;
    }

    pub fn transport(self: *WebDav) Transport {
        return .{ .ctx = self, .vtable = &webdav_vtable };
    }

    /// URL of a file, or of a collection when `name` is empty or ends in `/`.
    pub fn urlFor(self: *const WebDav, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
        const encoded = try encodePath(allocator, name);
        defer allocator.free(encoded);
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, self.base_url);
        try out.append(allocator, '/');
        if (self.folder.len > 0) {
            try out.appendSlice(allocator, self.folder);
            try out.append(allocator, '/');
        }
        try out.appendSlice(allocator, encoded);
        if (name.len > 0 and name[name.len - 1] == '/' and out.items[out.items.len - 1] != '/') try out.append(allocator, '/');
        return out.toOwnedSlice(allocator);
    }

    fn request(self: *WebDav, allocator: std.mem.Allocator, method: http_client.Method, url: []const u8, body: []const u8) !http_client.Response {
        const headers = [_]http_client.Header{
            .{ .name = "Authorization", .value = self.authorization },
            // NSURLSession may otherwise answer a GET from its cache.
            .{ .name = "Cache-Control", .value = "no-cache" },
            .{ .name = "Content-Type", .value = "application/octet-stream" },
        };
        return self.fetch_fn(allocator, .{
            .method = method,
            .url = url,
            .headers = if (method == .PUT) &headers else headers[0..2],
            .body = body,
            .timeout_ms = self.timeout_ms,
        });
    }

    fn fail(self: *WebDav, status: u16) anyerror {
        self.last_status = status;
        return switch (status) {
            401, 403 => error.SyncAuthFailed,
            404, 409 => error.SyncFolderMissing,
            507 => error.SyncDriveFull,
            else => error.SyncServerError,
        };
    }

    fn get(ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!?[]u8 {
        const self: *WebDav = @ptrCast(@alignCast(ctx));
        const url = try self.urlFor(allocator, name);
        defer allocator.free(url);
        var response = try self.request(allocator, .GET, url, "");
        const status = response.status;
        if (status >= 200 and status <= 299) return response.body;
        response.deinit(allocator);
        return if (status == 404) null else self.fail(status);
    }

    fn put(ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8, data: []const u8) anyerror!void {
        const self: *WebDav = @ptrCast(@alignCast(ctx));
        const url = try self.urlFor(allocator, name);
        defer allocator.free(url);
        var status = try self.putOnce(allocator, url, data);
        if (status == 409 or status == 404) {
            // The folder does not exist yet: create it level by level, retry once.
            try self.makeCollections(allocator, name);
            status = try self.putOnce(allocator, url, data);
        }
        if (status < 200 or status > 299) return self.fail(status);
    }

    fn putOnce(self: *WebDav, allocator: std.mem.Allocator, url: []const u8, data: []const u8) !u16 {
        var response = try self.request(allocator, .PUT, url, data);
        defer response.deinit(allocator);
        return response.status;
    }

    fn delete(ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!void {
        const self: *WebDav = @ptrCast(@alignCast(ctx));
        const url = try self.urlFor(allocator, name);
        defer allocator.free(url);
        var response = try self.request(allocator, .DELETE, url, "");
        defer response.deinit(allocator);
        switch (response.status) {
            200...299, 404 => {},
            else => return self.fail(response.status),
        }
    }

    /// MKCOL the remote folder and every parent of `name` inside it.
    fn makeCollections(self: *WebDav, allocator: std.mem.Allocator, name: []const u8) !void {
        var paths: std.ArrayListUnmanaged([]const u8) = .empty;
        defer paths.deinit(allocator);
        var folder_parts = std.mem.splitScalar(u8, self.folder, '/');
        var end: usize = 0;
        while (folder_parts.next()) |part| {
            if (part.len == 0) continue;
            end = @intFromPtr(part.ptr) - @intFromPtr(self.folder.ptr) + part.len;
            try paths.append(allocator, self.folder[0..end]);
        }
        const dir_end = std.mem.lastIndexOfScalar(u8, name, '/') orelse 0;
        var dir_parts = std.mem.splitScalar(u8, name[0..dir_end], '/');
        var dirs: std.ArrayListUnmanaged(u8) = .empty;
        defer dirs.deinit(allocator);
        var dir_ends: std.ArrayListUnmanaged(usize) = .empty;
        defer dir_ends.deinit(allocator);
        while (dir_parts.next()) |part| {
            if (part.len == 0) continue;
            if (dirs.items.len > 0) try dirs.append(allocator, '/');
            try dirs.appendSlice(allocator, part);
            try dir_ends.append(allocator, dirs.items.len);
        }

        for (paths.items) |folder_path| {
            const url = try std.fmt.allocPrint(allocator, "{s}/{s}/", .{ self.base_url, folder_path });
            defer allocator.free(url);
            try self.mkcol(allocator, url);
        }
        for (dir_ends.items) |dir_end_i| {
            const sub = try std.fmt.allocPrint(allocator, "{s}/", .{dirs.items[0..dir_end_i]});
            defer allocator.free(sub);
            const url = try self.urlFor(allocator, sub);
            defer allocator.free(url);
            try self.mkcol(allocator, url);
        }
    }

    fn mkcol(self: *WebDav, allocator: std.mem.Allocator, url: []const u8) !void {
        var response = try self.request(allocator, .MKCOL, url, "");
        defer response.deinit(allocator);
        switch (response.status) {
            // Created, or already there (405 Method Not Allowed / some 301s).
            200...299, 301, 405 => {},
            else => return self.fail(response.status),
        }
    }

    const webdav_vtable: Transport.VTable = .{ .get = get, .put = put, .delete = delete };
};

/// Percent-encode each `/`-separated segment (RFC 3986 unreserved kept).
pub fn encodePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const hex = "0123456789ABCDEF";
    for (path) |ch| {
        const keep = std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '.' or ch == '_' or ch == '~' or ch == '/';
        if (keep) {
            try out.append(allocator, ch);
        } else {
            try out.appendSlice(allocator, &.{ '%', hex[ch >> 4], hex[ch & 0x0f] });
        }
    }
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// In-memory drive for tests (also used by engine tests)
// ---------------------------------------------------------------------------

pub const Memory = struct {
    allocator: std.mem.Allocator,
    files: std.StringArrayHashMapUnmanaged([]u8) = .empty,
    puts: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Memory {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Memory) void {
        var it = self.files.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.files.deinit(self.allocator);
    }

    pub fn transport(self: *Memory) Transport {
        return .{ .ctx = self, .vtable = &memory_vtable };
    }

    fn get(ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!?[]u8 {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        const data = self.files.get(name) orelse return null;
        return try allocator.dupe(u8, data);
    }

    fn put(ctx: *anyopaque, _: std.mem.Allocator, name: []const u8, data: []const u8) anyerror!void {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        self.puts += 1;
        const copy = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(copy);
        if (self.files.getEntry(name)) |entry| {
            self.allocator.free(entry.value_ptr.*);
            entry.value_ptr.* = copy;
            return;
        }
        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);
        try self.files.put(self.allocator, key, copy);
    }

    fn delete(ctx: *anyopaque, _: std.mem.Allocator, name: []const u8) anyerror!void {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        const kv = self.files.fetchOrderedRemove(name) orelse return;
        self.allocator.free(kv.key);
        self.allocator.free(kv.value);
    }

    const memory_vtable: Transport.VTable = .{ .get = get, .put = put, .delete = delete };
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// A tiny WebDAV server: collections must exist before a PUT (409 otherwise),
/// like Nextcloud and 坚果云.
const FakeDav = struct {
    var files: std.StringArrayHashMapUnmanaged([]u8) = .empty;
    var collections: std.StringArrayHashMapUnmanaged(void) = .empty;
    var log: std.ArrayListUnmanaged(u8) = .empty;
    var require_auth: []const u8 = "";

    fn reset() void {
        const a = std.testing.allocator;
        var it = files.iterator();
        while (it.next()) |e| {
            a.free(e.key_ptr.*);
            a.free(e.value_ptr.*);
        }
        files.deinit(a);
        files = .empty;
        for (collections.keys()) |k| a.free(k);
        collections.deinit(a);
        collections = .empty;
        log.deinit(a);
        log = .empty;
    }

    fn fetch(allocator: std.mem.Allocator, req: http_client.Request) anyerror!http_client.Response {
        const a = std.testing.allocator;
        try log.writer(a).print("{s} {s}\n", .{ http_client.methodName(req.method), req.url });
        if (require_auth.len > 0) {
            var ok = false;
            for (req.headers) |h| {
                if (std.mem.eql(u8, h.name, "Authorization") and std.mem.eql(u8, h.value, require_auth)) ok = true;
            }
            if (!ok) return .{ .status = 401, .body = try allocator.alloc(u8, 0) };
        }
        const status: u16 = switch (req.method) {
            .GET => if (files.get(req.url)) |data| return .{ .status = 200, .body = try allocator.dupe(u8, data) } else 404,
            .PUT => blk: {
                if (!collections.contains(parentOf(req.url))) break :blk 409;
                const copy = try a.dupe(u8, req.body);
                if (files.getEntry(req.url)) |e| {
                    a.free(e.value_ptr.*);
                    e.value_ptr.* = copy;
                } else {
                    try files.put(a, try a.dupe(u8, req.url), copy);
                }
                break :blk 201;
            },
            .DELETE => blk: {
                const kv = files.fetchOrderedRemove(req.url) orelse break :blk 404;
                a.free(kv.key);
                a.free(kv.value);
                break :blk 204;
            },
            .MKCOL => blk: {
                if (collections.contains(req.url)) break :blk 405;
                const trimmed = req.url[0 .. req.url.len - 1];
                if (!collections.contains(parentOf(trimmed))) break :blk 409;
                try collections.put(a, try a.dupe(u8, req.url), {});
                break :blk 201;
            },
            .POST => 405,
        };
        return .{ .status = status, .body = try allocator.alloc(u8, 0) };
    }

    /// `https://h/dav/a/b` -> `https://h/dav/a/`
    fn parentOf(url: []const u8) []const u8 {
        const slash = std.mem.lastIndexOfScalar(u8, url, '/') orelse return url;
        return url[0 .. slash + 1];
    }
};

test "sync webdav builds encoded URLs under the remote folder" {
    const allocator = std.testing.allocator;
    var dav = try WebDav.init(allocator, " https://dav.jianguoyun.com/dav/ ", "/我的 Sync/", "me@example.com", "app-pass");
    defer dav.deinit();
    const url = try dav.urlFor(allocator, "history/abc.wsync");
    defer allocator.free(url);
    try std.testing.expectEqualStrings("https://dav.jianguoyun.com/dav/%E6%88%91%E7%9A%84%20Sync/history/abc.wsync", url);
    const root = try dav.urlFor(allocator, "");
    defer allocator.free(root);
    try std.testing.expectEqualStrings("https://dav.jianguoyun.com/dav/%E6%88%91%E7%9A%84%20Sync/", root);
    try std.testing.expect(std.mem.startsWith(u8, dav.authorization, "Basic "));
    try std.testing.expectError(error.InvalidSyncUrl, WebDav.init(allocator, "dav.example.com", "x", "u", "p"));
}

test "sync webdav creates missing folders on first upload and reads files back" {
    const allocator = std.testing.allocator;
    defer FakeDav.reset();
    try FakeDav.collections.put(std.testing.allocator, try std.testing.allocator.dupe(u8, "https://h/dav/"), {});
    var dav = try WebDav.init(allocator, "https://h/dav", "WispTerm/sub", "u", "p");
    defer dav.deinit();
    dav.fetch_fn = FakeDav.fetch;
    const t = dav.transport();

    try std.testing.expect((try t.get(allocator, "history/a.wsync")) == null);
    try t.put(allocator, "history/a.wsync", "sealed");
    const back = (try t.get(allocator, "history/a.wsync")).?;
    defer allocator.free(back);
    try std.testing.expectEqualStrings("sealed", back);
    try std.testing.expect(std.mem.indexOf(u8, FakeDav.log.items, "MKCOL https://h/dav/WispTerm/\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, FakeDav.log.items, "MKCOL https://h/dav/WispTerm/sub/\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, FakeDav.log.items, "MKCOL https://h/dav/WispTerm/sub/history/\n") != null);

    try t.delete(allocator, "history/a.wsync");
    try t.delete(allocator, "history/a.wsync"); // already gone: fine
    try std.testing.expect((try t.get(allocator, "history/a.wsync")) == null);
}

test "sync webdav reports a rejected login" {
    const allocator = std.testing.allocator;
    defer {
        FakeDav.reset();
        FakeDav.require_auth = "";
    }
    FakeDav.require_auth = "Basic nope";
    var dav = try WebDav.init(allocator, "https://h/dav", "W", "u", "wrong");
    defer dav.deinit();
    dav.fetch_fn = FakeDav.fetch;
    try std.testing.expectError(error.SyncAuthFailed, dav.transport().get(allocator, "wispterm-sync.json"));
    try std.testing.expectEqual(@as(u16, 401), dav.last_status);
}

test "sync folder transport writes nested files and treats a missing root as an error" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    var folder = Folder{ .root = root };
    const t = folder.transport();
    try t.put(allocator, "history/x.wsync", "abc");
    const back = (try t.get(allocator, "history/x.wsync")).?;
    defer allocator.free(back);
    try std.testing.expectEqualStrings("abc", back);
    try std.testing.expect((try t.get(allocator, "missing")) == null);
    try t.delete(allocator, "history/x.wsync");
    try t.delete(allocator, "history/x.wsync");

    const gone = try std.fs.path.join(allocator, &.{ root, "not-mounted" });
    defer allocator.free(gone);
    var missing = Folder{ .root = gone };
    try std.testing.expectError(error.SyncFolderMissing, missing.transport().get(allocator, "wispterm-sync.json"));
}

test "sync transport declarations compile" {
    std.testing.refAllDecls(@This());
}
