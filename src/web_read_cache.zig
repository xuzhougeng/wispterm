//! Pure on-disk cache for `web_read` local-file conversions. Given a working dir,
//! a resolved file path, and the file bytes' hash, it computes where the cached
//! markdown lives and reads/writes it. No network, no Jina knowledge. Best-effort:
//! `read` returns null on any problem; `store` swallows all errors.
const std = @import("std");

const cache_dir_name = ".webread_cache";
const max_cache_file_bytes: usize = 64 * 1024 * 1024;

/// Lowercase hex SHA-256 of `bytes`, written into `out` (must be 64 bytes). Returns out.
pub fn sha256Hex(bytes: []const u8, out: *[64]u8) []const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
    return out[0..64];
}

/// Cache root: `<cache_dir>/.webread_cache` when cache_dir is non-empty, else
/// `<dirname(resolved_path)>/.webread_cache`. Caller frees.
pub fn cacheRoot(allocator: std.mem.Allocator, cache_dir: ?[]const u8, resolved_path: []const u8) ![]u8 {
    if (cache_dir) |cd| if (cd.len > 0) return std.fs.path.join(allocator, &.{ cd, cache_dir_name });
    const dir = std.fs.path.dirname(resolved_path) orelse ".";
    return std.fs.path.join(allocator, &.{ dir, cache_dir_name });
}

/// Cache file name: `<basename>.<sha16>.md` (sha16 = first 16 hex chars). Caller frees.
pub fn cacheFileName(allocator: std.mem.Allocator, basename: []const u8, hash_hex: []const u8) ![]u8 {
    const sha16 = hash_hex[0..@min(hash_hex.len, 16)];
    return std.fmt.allocPrint(allocator, "{s}.{s}.md", .{ basename, sha16 });
}

/// Full cache path = join(cacheRoot, cacheFileName(basename(resolved_path), hash)). Caller frees.
pub fn cachePath(allocator: std.mem.Allocator, cache_dir: ?[]const u8, resolved_path: []const u8, hash_hex: []const u8) ![]u8 {
    const root = try cacheRoot(allocator, cache_dir, resolved_path);
    defer allocator.free(root);
    const name = try cacheFileName(allocator, std.fs.path.basename(resolved_path), hash_hex);
    defer allocator.free(name);
    return std.fs.path.join(allocator, &.{ root, name });
}

/// Read a cache file. Returns owned content, or null on any error / empty file
/// (miss-or-unreadable both mean "no cache"). Caller frees the returned slice.
pub fn read(allocator: std.mem.Allocator, cache_path: []const u8) ?[]u8 {
    const file = std.fs.cwd().openFile(cache_path, .{}) catch return null;
    defer file.close();
    const content = file.readToEndAlloc(allocator, max_cache_file_bytes) catch return null;
    if (content.len == 0) {
        allocator.free(content);
        return null;
    }
    return content;
}

/// Best-effort: mkdir -p the parent dir, then atomically write `content`. All errors
/// are swallowed — caching must never fail the read.
pub fn store(cache_path: []const u8, content: []const u8) void {
    if (std.fs.path.dirname(cache_path)) |dir| std.fs.cwd().makePath(dir) catch return;
    var write_buffer: [0]u8 = .{};
    var atomic = std.fs.cwd().atomicFile(cache_path, .{ .write_buffer = &write_buffer }) catch return;
    defer atomic.deinit();
    atomic.file_writer.file.writeAll(content) catch return;
    atomic.finish() catch return;
}

test "sha256Hex matches the known empty-input vector" {
    var out: [64]u8 = undefined;
    const hex = sha256Hex("", &out);
    try std.testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", hex);
}

test "cacheRoot uses cache_dir when set, else the file's directory" {
    const a = std.testing.allocator;
    const with = try cacheRoot(a, "/work/proj", "/dl/x.pdf");
    defer a.free(with);
    try std.testing.expectEqualStrings("/work/proj/.webread_cache", with);
    const without = try cacheRoot(a, null, "/dl/x.pdf");
    defer a.free(without);
    try std.testing.expectEqualStrings("/dl/.webread_cache", without);
    const empty = try cacheRoot(a, "", "/dl/x.pdf");
    defer a.free(empty);
    try std.testing.expectEqualStrings("/dl/.webread_cache", empty);
}

test "cacheFileName is basename.sha16.md" {
    const a = std.testing.allocator;
    const name = try cacheFileName(a, "Gosai_Nature_24.pdf", "0123456789abcdef0123456789abcdef");
    defer a.free(name);
    try std.testing.expectEqualStrings("Gosai_Nature_24.pdf.0123456789abcdef.md", name);
}

test "store then read round-trips; missing and empty read as null" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);
    const cpath = try std.fs.path.join(a, &.{ root, ".webread_cache", "x.pdf.deadbeefdeadbeef.md" });
    defer a.free(cpath);

    store(cpath, "CACHED MARKDOWN");
    const got = read(a, cpath).?;
    defer a.free(got);
    try std.testing.expectEqualStrings("CACHED MARKDOWN", got);

    const missing = try std.fs.path.join(a, &.{ root, "nope.md" });
    defer a.free(missing);
    try std.testing.expect(read(a, missing) == null);

    try tmp.dir.writeFile(.{ .sub_path = "empty.md", .data = "" });
    const empty_path = try tmp.dir.realpathAlloc(a, "empty.md");
    defer a.free(empty_path);
    try std.testing.expect(read(a, empty_path) == null);
}
