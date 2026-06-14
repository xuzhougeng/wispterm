const std = @import("std");
const build_options = @import("build_options");
const platform_dirs = @import("platform/dirs.zig");
const platform_update_package = @import("platform/update_package.zig");
const update_check = @import("update_check.zig");

pub fn runtimePackage(webview_enabled: bool, has_embedded_browser_payload: bool) update_check.ReleasePackage {
    return platform_update_package.runtimePackage(webview_enabled, has_embedded_browser_payload);
}

pub fn defaultPackage() update_check.ReleasePackage {
    return platform_update_package.defaultPackage();
}

pub fn currentPackage(allocator: std.mem.Allocator) !update_check.ReleasePackage {
    return platform_update_package.currentPackage(allocator, build_options.webview);
}

/// Absolute path the release asset is saved to: the user's Downloads folder
/// joined with the asset's original file name (e.g. the release `.zip`).
pub fn downloadDestPath(allocator: std.mem.Allocator, asset_name: []const u8) ![]u8 {
    const downloads = try platform_dirs.downloadsDir(allocator);
    defer allocator.free(downloads);
    return try std.fs.path.join(allocator, &.{ downloads, asset_name });
}

fn siblingTempPath(allocator: std.mem.Allocator, path: []const u8, suffix: []const u8) ![]u8 {
    return try std.mem.concat(allocator, u8, &.{ path, suffix });
}

/// Download `url` to `dest_path`, overwriting any existing file with that name.
/// Writes to a `.part` sibling first and renames into place so a failed or
/// interrupted download never leaves a truncated file at `dest_path`.
pub fn downloadAsset(allocator: std.mem.Allocator, url: []const u8, dest_path: []const u8) !void {
    return downloadAssetAccept(allocator, url, dest_path, null);
}

/// Like `downloadAsset`, but additionally sends an `Accept: <accept>` header when
/// `accept != null`. Used to fetch GitHub file contents via the Contents API
/// (`Accept: application/vnd.github.raw`) so downloads stay on the api.github.com
/// host instead of raw.githubusercontent.com.
pub fn downloadAssetAccept(allocator: std.mem.Allocator, url: []const u8, dest_path: []const u8, accept: ?[]const u8) !void {
    if (std.fs.path.dirname(dest_path)) |dir_path| {
        try std.fs.cwd().makePath(dir_path);
    }

    const temp_path = try siblingTempPath(allocator, dest_path, ".part");
    defer allocator.free(temp_path);
    std.fs.deleteFileAbsolute(temp_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    errdefer std.fs.deleteFileAbsolute(temp_path) catch {};

    var client: std.http.Client = .{
        .allocator = allocator,
        .write_buffer_size = 16 * 1024,
    };
    defer client.deinit();

    // `extra_headers` is externally owned and must outlive the fetch; this local
    // array does (the fetch completes within this function).
    var accept_buf: [1]std.http.Header = undefined;
    var extra_headers: []const std.http.Header = &.{};
    if (accept) |acc| {
        accept_buf[0] = .{ .name = "Accept", .value = acc };
        extra_headers = accept_buf[0..1];
    }

    const status = blk: {
        var out = try std.fs.createFileAbsolute(temp_path, .{ .truncate = true });
        errdefer out.close();
        var file_buf: [16 * 1024]u8 = undefined;
        var writer = out.writer(&file_buf);

        const response = try client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .keep_alive = false,
            .headers = .{ .user_agent = .{ .override = "wispterm" } },
            .extra_headers = extra_headers,
            .response_writer = &writer.interface,
        });
        try writer.end();
        out.close();
        break :blk response.status;
    };
    if (status != .ok) return error.DownloadFailed;

    // Replace any earlier download of the same release sitting in Downloads.
    std.fs.deleteFileAbsolute(dest_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try std.fs.renameAbsolute(temp_path, dest_path);
}

/// HTTP GET `url` into an owned byte slice (caller frees). Errors on non-200 or
/// a body larger than `max_bytes`. Network I/O — not unit-tested, validated
/// manually like `downloadAsset`. Mirrors the body-collection idiom of
/// `skill_update.fetchTreeJson`.
pub fn httpGetAlloc(allocator: std.mem.Allocator, url: []const u8, max_bytes: usize) ![]u8 {
    var client: std.http.Client = .{
        .allocator = allocator,
        .write_buffer_size = 16 * 1024,
    };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();

    const response = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .keep_alive = false,
        .headers = .{ .user_agent = .{ .override = "wispterm" } },
        .response_writer = &body.writer,
    });
    if (response.status != .ok) return error.HttpStatus;

    var list = body.toArrayList();
    errdefer list.deinit(allocator);
    if (list.items.len > max_bytes) return error.ResponseTooLarge;
    return list.toOwnedSlice(allocator);
}

test "update_install: download destination is the asset name inside Downloads" {
    const allocator = std.testing.allocator;
    const dest = downloadDestPath(allocator, "wispterm-windows-portable-v0.28.0.zip") catch |err| {
        // Environments without a resolvable Downloads dir cannot exercise this.
        try std.testing.expect(err == error.NoDownloadsPath);
        return;
    };
    defer allocator.free(dest);

    try std.testing.expect(std.fs.path.isAbsolute(dest));
    try std.testing.expect(std.mem.endsWith(u8, dest, "wispterm-windows-portable-v0.28.0.zip"));
    const parent = std.fs.path.dirname(dest) orelse return error.MissingParent;
    try std.testing.expect(std.mem.endsWith(u8, parent, "Downloads"));
}
