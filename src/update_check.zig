const std = @import("std");

pub const latest_release_api_url = "https://api.github.com/repos/xuzhougeng/phantty/releases/latest";

pub const Order = enum { older, equal, newer, unknown };
pub const State = enum { idle, checking, up_to_date, update_available, failed };

pub const ReleaseInfo = struct {
    tag_name: []const u8,
    html_url: []const u8,
    draft: bool,
    prerelease: bool,
    owned: bool = true,

    pub fn deinit(self: ReleaseInfo, allocator: std.mem.Allocator) void {
        if (!self.owned) return;
        allocator.free(self.tag_name);
        allocator.free(self.html_url);
    }
};

pub const CheckResult = struct {
    state: State,
    latest_version: []const u8 = "",
    release_url: []const u8 = "",
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

    return .{
        .tag_name = tag_name_owned,
        .html_url = html_url_owned,
        .draft = jsonBool(root, "draft"),
        .prerelease = jsonBool(root, "prerelease"),
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

pub fn evaluateRelease(current_version: []const u8, release: ReleaseInfo) CheckResult {
    if (release.draft or release.prerelease) return .{ .state = .up_to_date };

    return switch (compareVersions(current_version, release.tag_name)) {
        .newer => .{
            .state = .update_available,
            .latest_version = release.tag_name,
            .release_url = release.html_url,
        },
        .older, .equal, .unknown => .{ .state = .up_to_date },
    };
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
        .owned = false,
    };
    const result = evaluateRelease("0.23.2", release);
    try std.testing.expectEqual(State.update_available, result.state);
}
