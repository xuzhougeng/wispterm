const std = @import("std");
const builtin = @import("builtin");
const release_package = @import("../release_package.zig");
const release_asset_backend = @import("update_package_windows.zig");

pub const Backend = enum {
    windows,
    unsupported,
};

pub const PackageScenario = release_package.Flavor;

pub fn backendForOs(os_tag: std.Target.Os.Tag) Backend {
    return switch (os_tag) {
        .windows => .windows,
        else => .unsupported,
    };
}

const impl = switch (backendForOs(builtin.os.tag)) {
    .windows => @import("update_package_windows.zig"),
    .unsupported => @import("update_package_unsupported.zig"),
};

fn runtimeFlavor(webview_enabled: bool, has_embedded_browser_payload: bool) release_package.Flavor {
    if (!webview_enabled) return .without_embedded_browser_payload;
    if (has_embedded_browser_payload) return .with_required_embedded_browser_payload;
    return .baseline;
}

pub fn packageForScenario(scenario: PackageScenario) release_package.Package {
    return release_package.Package.init(.windows, scenario);
}

pub fn assetNameForScenario(
    tag_name: []const u8,
    scenario: PackageScenario,
    buf: []u8,
) ![]const u8 {
    return assetName(tag_name, packageForScenario(scenario), buf);
}

pub fn assetName(tag_name: []const u8, package: release_package.Package, buf: []u8) ![]const u8 {
    return switch (package.platform) {
        .windows => release_asset_backend.assetName(tag_name, package, buf),
        else => error.UnsupportedReleasePackage,
    };
}

pub fn matchesAssetName(name: []const u8, tag_name: []const u8, package: release_package.Package) bool {
    return switch (package.platform) {
        .windows => release_asset_backend.matchesAssetName(name, tag_name, package),
        else => false,
    };
}

pub fn defaultPackageForOs(os_tag: std.Target.Os.Tag) release_package.Package {
    return switch (os_tag) {
        .windows => release_package.Package.init(.windows, .baseline),
        .macos => .{ .platform = .macos },
        .linux => .{ .platform = .linux },
        else => .{ .platform = .unsupported },
    };
}

pub fn defaultPackage() release_package.Package {
    return defaultPackageForOs(builtin.os.tag);
}

pub fn runtimePackageForOs(
    os_tag: std.Target.Os.Tag,
    webview_enabled: bool,
    has_embedded_browser_payload: bool,
) release_package.Package {
    return switch (backendForOs(os_tag)) {
        .windows => release_package.Package.init(.windows, runtimeFlavor(webview_enabled, has_embedded_browser_payload)),
        .unsupported => defaultPackageForOs(os_tag),
    };
}

pub fn runtimePackage(webview_enabled: bool, has_embedded_browser_payload: bool) release_package.Package {
    return runtimePackageForOs(builtin.os.tag, webview_enabled, has_embedded_browser_payload);
}

pub fn currentPackage(allocator: std.mem.Allocator, webview_enabled: bool) !release_package.Package {
    return impl.currentPackage(allocator, webview_enabled);
}

test "platform update package selects backend by target OS" {
    try std.testing.expectEqual(Backend.windows, backendForOs(.windows));
    try std.testing.expectEqual(Backend.unsupported, backendForOs(.linux));
    try std.testing.expectEqual(Backend.unsupported, backendForOs(.macos));
}

test "platform update package maps non-Windows targets to non-Windows packages" {
    try std.testing.expectEqual(release_package.Platform.windows, defaultPackageForOs(.windows).platform);
    try std.testing.expectEqual(release_package.Platform.linux, defaultPackageForOs(.linux).platform);
    try std.testing.expectEqual(release_package.Platform.macos, defaultPackageForOs(.macos).platform);
    try std.testing.expectEqual(release_package.Platform.unsupported, defaultPackageForOs(.freebsd).platform);
}

test "platform update package keeps Windows portable flavor logic in platform layer" {
    try std.testing.expectEqual(release_package.Flavor.without_embedded_browser_payload, runtimeFlavor(false, true));
    try std.testing.expectEqual(release_package.Flavor.with_required_embedded_browser_payload, runtimeFlavor(true, true));
    try std.testing.expectEqual(release_package.Flavor.baseline, runtimeFlavor(true, false));
    try std.testing.expect(release_package.Package.init(.windows, .with_required_embedded_browser_payload).requiresEmbeddedBrowserPayload());
}

test "platform update package builds Windows portable asset names" {
    var buf: [128]u8 = undefined;
    const normal = try assetNameForScenario("v0.28.0", .baseline, &buf);
    try std.testing.expectEqualStrings("phantty-windows-portable-v0.28.0.zip", normal);

    const embedded_browser = try assetNameForScenario("v0.28.0", .with_required_embedded_browser_payload, &buf);
    try std.testing.expectEqualStrings("phantty-windows-portable-webview2-v0.28.0.zip", embedded_browser);

    const no_embedded_browser = try assetNameForScenario("v0.28.0", .without_embedded_browser_payload, &buf);
    try std.testing.expectEqualStrings("phantty-windows-portable-no-webview-v0.28.0.zip", no_embedded_browser);
}

test "platform update package matches exact target asset names only" {
    try std.testing.expect(matchesAssetName(
        "phantty-windows-portable-webview2-v0.28.0.zip",
        "v0.28.0",
        packageForScenario(.with_required_embedded_browser_payload),
    ));
    try std.testing.expect(!matchesAssetName(
        "phantty-windows-portable-v0.28.0.zip",
        "v0.28.0",
        packageForScenario(.with_required_embedded_browser_payload),
    ));
}

test "platform update package rejects unsupported platform asset names" {
    var buf: [128]u8 = undefined;
    try std.testing.expectError(error.UnsupportedReleasePackage, assetName("v0.28.0", .{
        .platform = .macos,
    }, &buf));
    try std.testing.expect(!matchesAssetName("phantty-macos-v0.28.0.zip", "v0.28.0", .{
        .platform = .macos,
    }));
}

test "platform update package exposes platform-neutral package scenarios" {
    var buf: [128]u8 = undefined;

    const baseline = packageForScenario(.baseline);
    const baseline_name = try assetNameForScenario("v0.28.0", .baseline, &buf);
    try std.testing.expectEqual(release_package.Platform.windows, baseline.platform);
    try std.testing.expectEqualStrings("phantty-windows-portable-v0.28.0.zip", baseline_name);
}
