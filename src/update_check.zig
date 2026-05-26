const std = @import("std");
const platform_update_package = @import("platform/update_package.zig");
const release_package = @import("release_package.zig");

pub const latest_release_api_url = "https://api.github.com/repos/xuzhougeng/phantty/releases/latest";
pub const latest_release_page_url = "https://github.com/xuzhougeng/phantty/releases/latest";
pub const asset_name_buffer_len = 128;
pub const asset_download_url_buffer_len = 512;

pub const Order = enum { older, equal, newer, unknown };
pub const State = enum {
    idle,
    checking,
    up_to_date,
    update_available,
    downloading,
    downloaded,
    download_failed,
    failed,
};

pub const ReleasePlatform = release_package.Platform;
pub const ReleasePackage = release_package.Package;

pub const ReleaseAsset = struct {
    name: []const u8,
    download_url: []const u8,
    size: u64 = 0,
};

pub const ReleaseInfo = struct {
    tag_name: []const u8,
    html_url: []const u8,
    draft: bool,
    prerelease: bool,
    assets: []const ReleaseAsset = &.{},
    owned: bool = true,

    pub fn deinit(self: ReleaseInfo, allocator: std.mem.Allocator) void {
        if (!self.owned) return;
        allocator.free(self.tag_name);
        allocator.free(self.html_url);
        for (self.assets) |asset| {
            allocator.free(asset.name);
            allocator.free(asset.download_url);
        }
        allocator.free(self.assets);
    }
};

pub const CheckResult = struct {
    state: State,
    latest_version: []const u8 = "",
    release_url: []const u8 = "",
    asset_name: []const u8 = "",
    asset_download_url: []const u8 = "",
    asset_size: u64 = 0,
};

pub const CheckResultBuffers = struct {
    latest_version: []u8,
    release_url: []u8,
    asset_name: []u8,
    asset_download_url: []u8,
};

const Semver = struct {
    major: u32,
    minor: u32,
    patch: u32,
};

pub fn compareVersions(current_version: []const u8, latest_version: []const u8) Order {
    const current = parseSemver(current_version) orelse return .unknown;
    const latest = parseSemver(latest_version) orelse return .unknown;

    if (latest.major > current.major) return .newer;
    if (latest.major < current.major) return .older;
    if (latest.minor > current.minor) return .newer;
    if (latest.minor < current.minor) return .older;
    if (latest.patch > current.patch) return .newer;
    if (latest.patch < current.patch) return .older;
    return .equal;
}

fn parseSemver(raw: []const u8) ?Semver {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const version = if (trimmed.len > 0 and (trimmed[0] == 'v' or trimmed[0] == 'V')) trimmed[1..] else trimmed;
    if (version.len == 0) return null;

    var it = std.mem.splitScalar(u8, version, '.');
    const major_s = it.next() orelse return null;
    const minor_s = it.next() orelse return null;
    const patch_s = it.next() orelse return null;
    if (it.next() != null) return null;
    if (major_s.len == 0 or minor_s.len == 0 or patch_s.len == 0) return null;

    return .{
        .major = std.fmt.parseInt(u32, major_s, 10) catch return null,
        .minor = std.fmt.parseInt(u32, minor_s, 10) catch return null,
        .patch = std.fmt.parseInt(u32, patch_s, 10) catch return null,
    };
}

pub fn parseLatestRelease(allocator: std.mem.Allocator, bytes: []const u8) !ReleaseInfo {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidRelease;

    const tag_name = jsonString(root, "tag_name") orelse return error.InvalidRelease;
    const html_url = jsonString(root, "html_url") orelse return error.InvalidRelease;
    const tag_name_owned = try allocator.dupe(u8, tag_name);
    errdefer allocator.free(tag_name_owned);
    const html_url_owned = try allocator.dupe(u8, html_url);
    errdefer allocator.free(html_url_owned);
    const assets_owned = try parseAssets(allocator, root);
    errdefer freeAssets(allocator, assets_owned);

    return .{
        .tag_name = tag_name_owned,
        .html_url = html_url_owned,
        .draft = jsonBool(root, "draft"),
        .prerelease = jsonBool(root, "prerelease"),
        .assets = assets_owned,
        .owned = true,
    };
}

fn jsonString(root: std.json.Value, name: []const u8) ?[]const u8 {
    if (root != .object) return null;
    const value = root.object.get(name) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

fn jsonBool(root: std.json.Value, name: []const u8) bool {
    if (root != .object) return false;
    const value = root.object.get(name) orelse return false;
    return if (value == .bool) value.bool else false;
}

fn jsonInt(root: std.json.Value, name: []const u8) u64 {
    if (root != .object) return 0;
    const value = root.object.get(name) orelse return 0;
    return switch (value) {
        .integer => |v| if (v > 0) @intCast(v) else 0,
        else => 0,
    };
}

fn parseAssets(allocator: std.mem.Allocator, root: std.json.Value) ![]const ReleaseAsset {
    if (root != .object) return &.{};
    const value = root.object.get("assets") orelse return &.{};
    if (value != .array) return &.{};

    var out: std.ArrayListUnmanaged(ReleaseAsset) = .empty;
    errdefer {
        for (out.items) |asset| {
            allocator.free(asset.name);
            allocator.free(asset.download_url);
        }
        out.deinit(allocator);
    }

    for (value.array.items) |item| {
        if (item != .object) continue;
        const name = jsonString(item, "name") orelse continue;
        const url = jsonString(item, "browser_download_url") orelse continue;
        const name_owned = try allocator.dupe(u8, name);
        errdefer allocator.free(name_owned);
        const url_owned = try allocator.dupe(u8, url);
        errdefer allocator.free(url_owned);
        try out.append(allocator, .{
            .name = name_owned,
            .download_url = url_owned,
            .size = jsonInt(item, "size"),
        });
    }

    return try out.toOwnedSlice(allocator);
}

fn freeAssets(allocator: std.mem.Allocator, assets: []const ReleaseAsset) void {
    for (assets) |asset| {
        allocator.free(asset.name);
        allocator.free(asset.download_url);
    }
    allocator.free(assets);
}

pub fn selectReleaseAsset(release: ReleaseInfo, package: ReleasePackage) ?ReleaseAsset {
    for (release.assets) |asset| {
        if (platform_update_package.matchesAssetName(asset.name, release.tag_name, package)) return asset;
    }
    return null;
}

pub fn evaluateReleaseForPackage(current_version: []const u8, release: ReleaseInfo, package: ReleasePackage) CheckResult {
    if (release.draft or release.prerelease) return .{ .state = .up_to_date };

    return switch (compareVersions(current_version, release.tag_name)) {
        .newer => {
            const asset = selectReleaseAsset(release, package) orelse return .{
                .state = .failed,
                .latest_version = release.tag_name,
                .release_url = release.html_url,
            };
            return .{
                .state = .update_available,
                .latest_version = release.tag_name,
                .release_url = release.html_url,
                .asset_name = asset.name,
                .asset_download_url = asset.download_url,
                .asset_size = asset.size,
            };
        },
        .older, .equal, .unknown => .{ .state = .up_to_date },
    };
}

pub fn evaluateRelease(current_version: []const u8, release: ReleaseInfo) CheckResult {
    return evaluateReleaseForPackage(current_version, release, .{ .platform = .unsupported });
}

pub fn formatStatusMessage(buf: []u8, result: CheckResult) ![]const u8 {
    return switch (result.state) {
        .idle => std.fmt.bufPrint(buf, "", .{}),
        .checking => std.fmt.bufPrint(buf, "Checking for updates...", .{}),
        .up_to_date => std.fmt.bufPrint(buf, "Phantty is up to date", .{}),
        .update_available => std.fmt.bufPrint(buf, "Update available: {s}", .{result.latest_version}),
        .downloading => std.fmt.bufPrint(buf, "Downloading update...", .{}),
        .downloaded => std.fmt.bufPrint(buf, "Saved to Downloads - unzip to update", .{}),
        .download_failed => std.fmt.bufPrint(buf, "Update download failed", .{}),
        .failed => if (result.latest_version.len > 0 and result.release_url.len > 0)
            std.fmt.bufPrint(buf, "Manual update available: {s}", .{result.latest_version})
        else
            std.fmt.bufPrint(buf, "Update check failed", .{}),
    };
}

pub fn copyResult(
    result: CheckResult,
    buffers: CheckResultBuffers,
) CheckResult {
    const latest_version = copyExact(buffers.latest_version, result.latest_version) orelse return .{ .state = .failed };
    const release_url = copyExact(buffers.release_url, result.release_url) orelse return .{ .state = .failed };
    const asset_name = copyExact(buffers.asset_name, result.asset_name) orelse return .{ .state = .failed };
    const asset_download_url = copyExact(buffers.asset_download_url, result.asset_download_url) orelse return .{ .state = .failed };

    return .{
        .state = result.state,
        .latest_version = latest_version,
        .release_url = release_url,
        .asset_name = asset_name,
        .asset_download_url = asset_download_url,
        .asset_size = result.asset_size,
    };
}

fn copyExact(buf: []u8, value: []const u8) ?[]const u8 {
    if (value.len == 0) return "";
    if (buf.len < value.len) return null;
    @memcpy(buf[0..value.len], value);
    return buf[0..value.len];
}

pub fn fetchLatestRelease(
    allocator: std.mem.Allocator,
    current_version: []const u8,
    buffers: CheckResultBuffers,
) CheckResult {
    return fetchLatestReleaseForPackage(
        allocator,
        current_version,
        .{ .platform = .unsupported },
        buffers,
    );
}

pub fn fetchLatestReleaseForPackage(
    allocator: std.mem.Allocator,
    current_version: []const u8,
    package: ReleasePackage,
    buffers: CheckResultBuffers,
) CheckResult {
    var client: std.http.Client = .{
        .allocator = allocator,
        .write_buffer_size = 16 * 1024,
    };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();

    const response = client.fetch(.{
        .location = .{ .url = latest_release_api_url },
        .method = .GET,
        .keep_alive = false,
        .headers = .{
            .user_agent = .{ .override = "phantty" },
        },
        .response_writer = &body.writer,
    }) catch return .{ .state = .failed };
    if (response.status != .ok) return .{ .state = .failed };

    var list = body.toArrayList();
    defer list.deinit(allocator);

    const release = parseLatestRelease(allocator, list.items) catch return .{ .state = .failed };
    defer release.deinit(allocator);

    return copyResult(
        evaluateReleaseForPackage(current_version, release, package),
        buffers,
    );
}

test "update_check: compares semantic versions with optional v prefix" {
    try std.testing.expectEqual(Order.equal, compareVersions("0.23.2", "v0.23.2"));
    try std.testing.expectEqual(Order.newer, compareVersions("0.23.2", "v0.23.3"));
    try std.testing.expectEqual(Order.older, compareVersions("0.24.0", "v0.23.9"));
}

test "update_check: malformed versions are unknown" {
    try std.testing.expectEqual(Order.unknown, compareVersions("0.23.2-dev", "v0.23.3"));
    try std.testing.expectEqual(Order.unknown, compareVersions("0.23.2", "latest"));
}

test "update_check: parses latest release json" {
    const json =
        \\{"tag_name":"v0.23.3","html_url":"https://github.com/xuzhougeng/phantty/releases/tag/v0.23.3","draft":false,"prerelease":false}
    ;
    const release = try parseLatestRelease(std.testing.allocator, json);
    defer release.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("v0.23.3", release.tag_name);
    try std.testing.expectEqualStrings("https://github.com/xuzhougeng/phantty/releases/tag/v0.23.3", release.html_url);
    try std.testing.expect(!release.draft);
    try std.testing.expect(!release.prerelease);
}

test "update_check: decides when update is available" {
    const package = platform_update_package.packageForScenario(.baseline);
    var asset_name_buf: [asset_name_buffer_len]u8 = undefined;
    const asset_name = try platform_update_package.assetName("v0.23.3", package, &asset_name_buf);

    const release = ReleaseInfo{
        .tag_name = "v0.23.3",
        .html_url = "https://github.com/xuzhougeng/phantty/releases/tag/v0.23.3",
        .draft = false,
        .prerelease = false,
        .assets = &.{
            .{
                .name = asset_name,
                .download_url = "https://example.test/portable.zip",
                .size = 1234,
            },
        },
        .owned = false,
    };
    const result = evaluateReleaseForPackage("0.23.2", release, package);
    try std.testing.expectEqual(State.update_available, result.state);
}

test "update_check: formats update messages" {
    var buf: [96]u8 = undefined;
    const msg = try formatStatusMessage(&buf, .{
        .state = .update_available,
        .latest_version = "v0.23.3",
        .release_url = "https://github.com/xuzhougeng/phantty/releases/tag/v0.23.3",
    });
    try std.testing.expectEqualStrings("Update available: v0.23.3", msg);
}

test "update_check: manual failure message is stable" {
    var buf: [96]u8 = undefined;
    const msg = try formatStatusMessage(&buf, .{ .state = .failed });
    try std.testing.expectEqualStrings("Update check failed", msg);
}

test "update_check: download failure message is distinct from check failure" {
    var buf: [96]u8 = undefined;
    const msg = try formatStatusMessage(&buf, .{ .state = .download_failed });
    try std.testing.expectEqualStrings("Update download failed", msg);
}

test "update_check: downloaded message points at Downloads" {
    var buf: [96]u8 = undefined;
    const msg = try formatStatusMessage(&buf, .{ .state = .downloaded });
    try std.testing.expectEqualStrings("Saved to Downloads - unzip to update", msg);
}

test "update_check: copies result strings into caller buffers" {
    var version_buf: [16]u8 = undefined;
    var url_buf: [96]u8 = undefined;
    var asset_name_buf: [128]u8 = undefined;
    var asset_url_buf: [512]u8 = undefined;
    const copied = copyResult(.{
        .state = .update_available,
        .latest_version = "v0.23.3",
        .release_url = "https://github.com/xuzhougeng/phantty/releases/tag/v0.23.3",
        .asset_name = "selected-update.zip",
        .asset_download_url = "https://example.test/portable.zip",
        .asset_size = 1234,
    }, .{
        .latest_version = &version_buf,
        .release_url = &url_buf,
        .asset_name = &asset_name_buf,
        .asset_download_url = &asset_url_buf,
    });

    try std.testing.expectEqual(State.update_available, copied.state);
    try std.testing.expectEqualStrings("v0.23.3", copied.latest_version);
    try std.testing.expectEqualStrings("https://github.com/xuzhougeng/phantty/releases/tag/v0.23.3", copied.release_url);
    try std.testing.expectEqualStrings("selected-update.zip", copied.asset_name);
    try std.testing.expectEqualStrings("https://example.test/portable.zip", copied.asset_download_url);
    try std.testing.expectEqual(@as(u64, 1234), copied.asset_size);
}

test "update_check: copy result fails when asset buffers are too small" {
    var version_buf: [16]u8 = undefined;
    var url_buf: [96]u8 = undefined;
    var asset_name_buf: [8]u8 = undefined;
    var asset_url_buf: [12]u8 = undefined;
    const copied = copyResult(.{
        .state = .update_available,
        .latest_version = "v0.23.3",
        .release_url = "https://github.com/xuzhougeng/phantty/releases/tag/v0.23.3",
        .asset_name = "selected-update.zip",
        .asset_download_url = "https://example.test/portable.zip",
        .asset_size = 1234,
    }, .{
        .latest_version = &version_buf,
        .release_url = &url_buf,
        .asset_name = &asset_name_buf,
        .asset_download_url = &asset_url_buf,
    });

    try std.testing.expectEqual(State.failed, copied.state);
    try std.testing.expectEqualStrings("", copied.asset_name);
    try std.testing.expectEqualStrings("", copied.asset_download_url);
    try std.testing.expectEqual(@as(u64, 0), copied.asset_size);
}

test "update_check: selects portable asset for runtime flavor" {
    const tag_name = "v0.28.0";
    var portable_name_buf: [asset_name_buffer_len]u8 = undefined;
    var required_extra_name_buf: [asset_name_buffer_len]u8 = undefined;
    var no_embedded_browser_name_buf: [asset_name_buffer_len]u8 = undefined;
    const portable_package = platform_update_package.packageForScenario(.baseline);
    const required_extra_package = platform_update_package.packageForScenario(.with_required_embedded_browser_payload);
    const no_embedded_browser_package = platform_update_package.packageForScenario(.without_embedded_browser_payload);
    const portable_name = try platform_update_package.assetName(tag_name, portable_package, &portable_name_buf);
    const required_extra_name = try platform_update_package.assetName(tag_name, required_extra_package, &required_extra_name_buf);
    const no_embedded_browser_name = try platform_update_package.assetName(tag_name, no_embedded_browser_package, &no_embedded_browser_name_buf);

    const json = try std.fmt.allocPrint(std.testing.allocator,
        \\{{
        \\  "tag_name":"{s}",
        \\  "html_url":"https://github.com/xuzhougeng/phantty/releases/tag/{s}",
        \\  "draft":false,
        \\  "prerelease":false,
        \\  "assets":[
        \\    {{"name":"{s}","browser_download_url":"https://example.test/portable.zip","size":11}},
        \\    {{"name":"{s}","browser_download_url":"https://example.test/required-extra.zip","size":22}},
        \\    {{"name":"{s}","browser_download_url":"https://example.test/no-embedded-browser.zip","size":33}}
        \\  ]
        \\}}
    , .{
        tag_name,
        tag_name,
        portable_name,
        required_extra_name,
        no_embedded_browser_name,
    });
    defer std.testing.allocator.free(json);

    const release = try parseLatestRelease(std.testing.allocator, json);
    defer release.deinit(std.testing.allocator);

    const normal = selectReleaseAsset(release, portable_package) orelse return error.ExpectedAsset;
    try std.testing.expectEqualStrings(portable_name, normal.name);
    try std.testing.expectEqualStrings("https://example.test/portable.zip", normal.download_url);
    try std.testing.expectEqual(@as(u64, 11), normal.size);

    const required_extra = selectReleaseAsset(release, required_extra_package) orelse return error.ExpectedAsset;
    try std.testing.expectEqualStrings(required_extra_name, required_extra.name);

    const no_embedded_browser = selectReleaseAsset(release, no_embedded_browser_package) orelse return error.ExpectedAsset;
    try std.testing.expectEqualStrings(no_embedded_browser_name, no_embedded_browser.name);
}

test "update_check: update result includes selected asset fields" {
    const package = platform_update_package.packageForScenario(.with_required_embedded_browser_payload);
    var asset_name_buf: [asset_name_buffer_len]u8 = undefined;
    const asset_name = try platform_update_package.assetName("v0.28.0", package, &asset_name_buf);

    const release = ReleaseInfo{
        .tag_name = "v0.28.0",
        .html_url = "https://github.com/xuzhougeng/phantty/releases/tag/v0.28.0",
        .draft = false,
        .prerelease = false,
        .assets = &.{
            .{
                .name = asset_name,
                .download_url = "https://example.test/required-extra.zip",
                .size = 1234,
            },
        },
        .owned = false,
    };

    const result = evaluateReleaseForPackage("0.27.2", release, package);
    try std.testing.expectEqual(State.update_available, result.state);
    try std.testing.expectEqualStrings("v0.28.0", result.latest_version);
    try std.testing.expectEqualStrings(asset_name, result.asset_name);
    try std.testing.expectEqualStrings("https://example.test/required-extra.zip", result.asset_download_url);
    try std.testing.expectEqual(@as(u64, 1234), result.asset_size);
}

test "update_check: missing matching asset fails instead of changing flavor" {
    const available_package = platform_update_package.packageForScenario(.baseline);
    const requested_package = platform_update_package.packageForScenario(.with_required_embedded_browser_payload);
    var asset_name_buf: [asset_name_buffer_len]u8 = undefined;
    const asset_name = try platform_update_package.assetName("v0.28.0", available_package, &asset_name_buf);

    const release = ReleaseInfo{
        .tag_name = "v0.28.0",
        .html_url = "https://github.com/xuzhougeng/phantty/releases/tag/v0.28.0",
        .draft = false,
        .prerelease = false,
        .assets = &.{
            .{
                .name = asset_name,
                .download_url = "https://example.test/portable.zip",
                .size = 1234,
            },
        },
        .owned = false,
    };

    const result = evaluateReleaseForPackage("0.27.2", release, requested_package);
    try std.testing.expectEqual(State.failed, result.state);
    try std.testing.expectEqualStrings("v0.28.0", result.latest_version);
    try std.testing.expectEqualStrings("https://github.com/xuzhougeng/phantty/releases/tag/v0.28.0", result.release_url);
    try std.testing.expectEqualStrings("", result.asset_name);
    try std.testing.expectEqualStrings("", result.asset_download_url);
}
