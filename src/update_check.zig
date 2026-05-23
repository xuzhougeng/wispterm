const std = @import("std");

pub const latest_release_api_url = "https://api.github.com/repos/xuzhougeng/phantty/releases/latest";
pub const latest_release_page_url = "https://github.com/xuzhougeng/phantty/releases/latest";

pub const Order = enum { older, equal, newer, unknown };
pub const State = enum {
    idle,
    checking,
    up_to_date,
    update_available,
    downloading,
    extracting,
    ready_to_restart,
    installing,
    updated,
    failed,
};

pub const PortableFlavor = enum {
    portable,
    portable_webview2,
    portable_no_webview,
};

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

pub fn portableAssetName(tag_name: []const u8, flavor: PortableFlavor, buf: []u8) ![]const u8 {
    return switch (flavor) {
        .portable => std.fmt.bufPrint(buf, "phantty-windows-portable-{s}.zip", .{tag_name}),
        .portable_webview2 => std.fmt.bufPrint(buf, "phantty-windows-portable-webview2-{s}.zip", .{tag_name}),
        .portable_no_webview => std.fmt.bufPrint(buf, "phantty-windows-portable-no-webview-{s}.zip", .{tag_name}),
    };
}

pub fn selectPortableAsset(release: ReleaseInfo, flavor: PortableFlavor) ?ReleaseAsset {
    var expected_buf: [128]u8 = undefined;
    const expected = portableAssetName(release.tag_name, flavor, &expected_buf) catch return null;
    for (release.assets) |asset| {
        if (std.mem.eql(u8, asset.name, expected)) return asset;
    }
    return null;
}

pub fn evaluateReleaseForFlavor(current_version: []const u8, release: ReleaseInfo, flavor: PortableFlavor) CheckResult {
    if (release.draft or release.prerelease) return .{ .state = .up_to_date };

    return switch (compareVersions(current_version, release.tag_name)) {
        .newer => {
            const asset = selectPortableAsset(release, flavor) orelse return .{ .state = .failed };
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
    return evaluateReleaseForFlavor(current_version, release, .portable);
}

pub fn formatStatusMessage(buf: []u8, result: CheckResult) ![]const u8 {
    return switch (result.state) {
        .idle => std.fmt.bufPrint(buf, "", .{}),
        .checking => std.fmt.bufPrint(buf, "Checking for updates...", .{}),
        .up_to_date => std.fmt.bufPrint(buf, "Phantty is up to date", .{}),
        .update_available => std.fmt.bufPrint(buf, "Update available: {s}", .{result.latest_version}),
        .downloading => std.fmt.bufPrint(buf, "Downloading update...", .{}),
        .extracting => std.fmt.bufPrint(buf, "Preparing update...", .{}),
        .ready_to_restart => std.fmt.bufPrint(buf, "Update ready; restart to install", .{}),
        .installing => std.fmt.bufPrint(buf, "Installing update...", .{}),
        .updated => std.fmt.bufPrint(buf, "Update installed", .{}),
        .failed => std.fmt.bufPrint(buf, "Update check failed", .{}),
    };
}

pub fn copyResult(
    result: CheckResult,
    latest_version_buf: []u8,
    release_url_buf: []u8,
    asset_name_buf: []u8,
    asset_download_url_buf: []u8,
) CheckResult {
    return .{
        .state = result.state,
        .latest_version = copyBounded(latest_version_buf, result.latest_version),
        .release_url = copyBounded(release_url_buf, result.release_url),
        .asset_name = copyBounded(asset_name_buf, result.asset_name),
        .asset_download_url = copyBounded(asset_download_url_buf, result.asset_download_url),
        .asset_size = result.asset_size,
    };
}

fn copyBounded(buf: []u8, value: []const u8) []const u8 {
    if (buf.len == 0 or value.len == 0) return "";
    const len = @min(buf.len, value.len);
    @memcpy(buf[0..len], value[0..len]);
    return buf[0..len];
}

pub fn fetchLatestRelease(
    allocator: std.mem.Allocator,
    current_version: []const u8,
    latest_version_buf: []u8,
    release_url_buf: []u8,
    asset_name_buf: []u8,
    asset_download_url_buf: []u8,
) CheckResult {
    return fetchLatestReleaseForFlavor(
        allocator,
        current_version,
        .portable,
        latest_version_buf,
        release_url_buf,
        asset_name_buf,
        asset_download_url_buf,
    );
}

pub fn fetchLatestReleaseForFlavor(
    allocator: std.mem.Allocator,
    current_version: []const u8,
    flavor: PortableFlavor,
    latest_version_buf: []u8,
    release_url_buf: []u8,
    asset_name_buf: []u8,
    asset_download_url_buf: []u8,
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
        evaluateReleaseForFlavor(current_version, release, flavor),
        latest_version_buf,
        release_url_buf,
        asset_name_buf,
        asset_download_url_buf,
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
    const release = ReleaseInfo{
        .tag_name = "v0.23.3",
        .html_url = "https://github.com/xuzhougeng/phantty/releases/tag/v0.23.3",
        .draft = false,
        .prerelease = false,
        .assets = &.{
            .{
                .name = "phantty-windows-portable-v0.23.3.zip",
                .download_url = "https://example.test/portable.zip",
                .size = 1234,
            },
        },
        .owned = false,
    };
    const result = evaluateRelease("0.23.2", release);
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

test "update_check: copies result strings into caller buffers" {
    var version_buf: [16]u8 = undefined;
    var url_buf: [96]u8 = undefined;
    var asset_name_buf: [128]u8 = undefined;
    var asset_url_buf: [512]u8 = undefined;
    const copied = copyResult(.{
        .state = .update_available,
        .latest_version = "v0.23.3",
        .release_url = "https://github.com/xuzhougeng/phantty/releases/tag/v0.23.3",
        .asset_name = "phantty-windows-portable-v0.23.3.zip",
        .asset_download_url = "https://example.test/portable.zip",
        .asset_size = 1234,
    }, &version_buf, &url_buf, &asset_name_buf, &asset_url_buf);

    try std.testing.expectEqual(State.update_available, copied.state);
    try std.testing.expectEqualStrings("v0.23.3", copied.latest_version);
    try std.testing.expectEqualStrings("https://github.com/xuzhougeng/phantty/releases/tag/v0.23.3", copied.release_url);
    try std.testing.expectEqualStrings("phantty-windows-portable-v0.23.3.zip", copied.asset_name);
    try std.testing.expectEqualStrings("https://example.test/portable.zip", copied.asset_download_url);
    try std.testing.expectEqual(@as(u64, 1234), copied.asset_size);
}

test "update_check: selects portable asset for runtime flavor" {
    const json =
        \\{
        \\  "tag_name":"v0.28.0",
        \\  "html_url":"https://github.com/xuzhougeng/phantty/releases/tag/v0.28.0",
        \\  "draft":false,
        \\  "prerelease":false,
        \\  "assets":[
        \\    {"name":"phantty-windows-portable-v0.28.0.zip","browser_download_url":"https://example.test/portable.zip","size":11},
        \\    {"name":"phantty-windows-portable-webview2-v0.28.0.zip","browser_download_url":"https://example.test/webview2.zip","size":22},
        \\    {"name":"phantty-windows-portable-no-webview-v0.28.0.zip","browser_download_url":"https://example.test/no-webview.zip","size":33}
        \\  ]
        \\}
    ;
    const release = try parseLatestRelease(std.testing.allocator, json);
    defer release.deinit(std.testing.allocator);

    const normal = selectPortableAsset(release, .portable) orelse return error.ExpectedAsset;
    try std.testing.expectEqualStrings("phantty-windows-portable-v0.28.0.zip", normal.name);
    try std.testing.expectEqualStrings("https://example.test/portable.zip", normal.download_url);
    try std.testing.expectEqual(@as(u64, 11), normal.size);

    const webview2 = selectPortableAsset(release, .portable_webview2) orelse return error.ExpectedAsset;
    try std.testing.expectEqualStrings("phantty-windows-portable-webview2-v0.28.0.zip", webview2.name);

    const no_webview = selectPortableAsset(release, .portable_no_webview) orelse return error.ExpectedAsset;
    try std.testing.expectEqualStrings("phantty-windows-portable-no-webview-v0.28.0.zip", no_webview.name);
}

test "update_check: update result includes selected asset fields" {
    const release = ReleaseInfo{
        .tag_name = "v0.28.0",
        .html_url = "https://github.com/xuzhougeng/phantty/releases/tag/v0.28.0",
        .draft = false,
        .prerelease = false,
        .assets = &.{
            .{
                .name = "phantty-windows-portable-webview2-v0.28.0.zip",
                .download_url = "https://example.test/webview2.zip",
                .size = 1234,
            },
        },
        .owned = false,
    };

    const result = evaluateReleaseForFlavor("0.27.2", release, .portable_webview2);
    try std.testing.expectEqual(State.update_available, result.state);
    try std.testing.expectEqualStrings("v0.28.0", result.latest_version);
    try std.testing.expectEqualStrings("phantty-windows-portable-webview2-v0.28.0.zip", result.asset_name);
    try std.testing.expectEqualStrings("https://example.test/webview2.zip", result.asset_download_url);
    try std.testing.expectEqual(@as(u64, 1234), result.asset_size);
}

test "update_check: missing matching asset fails instead of changing flavor" {
    const release = ReleaseInfo{
        .tag_name = "v0.28.0",
        .html_url = "https://github.com/xuzhougeng/phantty/releases/tag/v0.28.0",
        .draft = false,
        .prerelease = false,
        .assets = &.{
            .{
                .name = "phantty-windows-portable-v0.28.0.zip",
                .download_url = "https://example.test/portable.zip",
                .size = 1234,
            },
        },
        .owned = false,
    };

    const result = evaluateReleaseForFlavor("0.27.2", release, .portable_webview2);
    try std.testing.expectEqual(State.failed, result.state);
}
