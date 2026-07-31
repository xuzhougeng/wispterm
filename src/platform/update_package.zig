const std = @import("std");
const builtin = @import("builtin");
const release_package = @import("../release_package.zig");
const linux_release_asset_backend = @import("update_package_linux.zig");
const macos_release_asset_backend = @import("update_package_macos.zig");
const windows_release_asset_backend = @import("update_package_windows.zig");

pub const Backend = enum {
    windows,
    linux,
    macos,
    unsupported,
};

pub const PackageScenario = release_package.Flavor;

pub fn backendForOs(os_tag: std.Target.Os.Tag) Backend {
    return switch (os_tag) {
        .windows => .windows,
        .linux => .linux,
        .macos => .macos,
        else => .unsupported,
    };
}

const impl = switch (backendForOs(builtin.os.tag)) {
    .windows => @import("update_package_windows.zig"),
    .linux => @import("update_package_linux.zig"),
    .macos => @import("update_package_macos.zig"),
    .unsupported => @import("update_package_unsupported.zig"),
};

fn runtimeFlavor(
    gpu_backend: []const u8,
    webview_enabled: bool,
    has_compat_payload: bool,
) release_package.Flavor {
    _ = webview_enabled;
    if (std.mem.eql(u8, gpu_backend, "opengl")) return .opengl;
    if (has_compat_payload) return .compat;
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
        .windows => windows_release_asset_backend.assetName(tag_name, package, buf),
        .linux => linux_release_asset_backend.assetName(tag_name, package, buf),
        .macos => macos_release_asset_backend.assetName(tag_name, package, buf),
        else => error.UnsupportedReleasePackage,
    };
}

pub fn matchesAssetName(name: []const u8, tag_name: []const u8, package: release_package.Package) bool {
    return switch (package.platform) {
        .windows => windows_release_asset_backend.matchesAssetName(name, tag_name, package),
        .linux => linux_release_asset_backend.matchesAssetName(name, tag_name, package),
        .macos => macos_release_asset_backend.matchesAssetName(name, tag_name, package),
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
    gpu_backend: []const u8,
    webview_enabled: bool,
    has_compat_payload: bool,
) release_package.Package {
    return switch (backendForOs(os_tag)) {
        .windows => release_package.Package.init(.windows, runtimeFlavor(gpu_backend, webview_enabled, has_compat_payload)),
        .linux => defaultPackageForOs(os_tag),
        .macos => defaultPackageForOs(os_tag),
        .unsupported => defaultPackageForOs(os_tag),
    };
}

pub fn runtimePackage(
    gpu_backend: []const u8,
    webview_enabled: bool,
    has_compat_payload: bool,
) release_package.Package {
    return runtimePackageForOs(builtin.os.tag, gpu_backend, webview_enabled, has_compat_payload);
}

pub fn currentPackage(
    allocator: std.mem.Allocator,
    webview_enabled: bool,
    gpu_backend: []const u8,
) !release_package.Package {
    return impl.currentPackage(allocator, webview_enabled, gpu_backend);
}

test "platform update package selects backend by target OS" {
    try std.testing.expectEqual(Backend.windows, backendForOs(.windows));
    try std.testing.expectEqual(Backend.linux, backendForOs(.linux));
    try std.testing.expectEqual(Backend.macos, backendForOs(.macos));
}

test "platform update package maps non-Windows targets to non-Windows packages" {
    try std.testing.expectEqual(release_package.Platform.windows, defaultPackageForOs(.windows).platform);
    try std.testing.expectEqual(release_package.Platform.linux, defaultPackageForOs(.linux).platform);
    try std.testing.expectEqual(release_package.Platform.macos, defaultPackageForOs(.macos).platform);
    try std.testing.expectEqual(release_package.Platform.unsupported, defaultPackageForOs(.freebsd).platform);
}

test "platform update package maps Windows runtime payloads after no-WebView retirement" {
    try std.testing.expectEqual(release_package.Flavor.baseline, runtimeFlavor("d3d11", false, false));
    try std.testing.expectEqual(release_package.Flavor.compat, runtimeFlavor("d3d11", false, true));
    try std.testing.expectEqual(release_package.Flavor.compat, runtimeFlavor("d3d11", true, true));
    try std.testing.expectEqual(release_package.Flavor.baseline, runtimeFlavor("d3d11", true, false));
    try std.testing.expectEqual(release_package.Flavor.opengl, runtimeFlavor("opengl", true, false));
    try std.testing.expectEqual(release_package.Flavor.opengl, runtimeFlavor("opengl", true, true));
    try std.testing.expect(release_package.Package.init(.windows, .compat).requiresEmbeddedBrowserPayload());
}

test "platform update package builds Windows portable asset names" {
    var buf: [128]u8 = undefined;
    const normal = try assetNameForScenario("v0.28.0", .baseline, &buf);
    try std.testing.expectEqualStrings("wispterm-windows-portable-v0.28.0.zip", normal);

    const compat = try assetNameForScenario("v0.28.0", .compat, &buf);
    try std.testing.expectEqualStrings("wispterm-windows-portable-compat-v0.28.0.zip", compat);

    const opengl = try assetNameForScenario("v0.28.0", .opengl, &buf);
    try std.testing.expectEqualStrings("wispterm-windows-portable-opengl-v0.28.0.zip", opengl);
}

test "platform update package matches exact target asset names only" {
    try std.testing.expect(matchesAssetName(
        "wispterm-windows-portable-compat-v0.28.0.zip",
        "v0.28.0",
        packageForScenario(.compat),
    ));
    try std.testing.expect(!matchesAssetName(
        "wispterm-windows-portable-v0.28.0.zip",
        "v0.28.0",
        packageForScenario(.compat),
    ));
    try std.testing.expect(matchesAssetName(
        "wispterm-windows-portable-opengl-v0.28.0.zip",
        "v0.28.0",
        packageForScenario(.opengl),
    ));
    try std.testing.expect(!matchesAssetName(
        "wispterm-windows-portable-v0.28.0.zip",
        "v0.28.0",
        packageForScenario(.opengl),
    ));
}

test "platform update package builds macOS DMG asset names" {
    var buf: [128]u8 = undefined;
    const name = try assetName("v1.28.0", .{ .platform = .macos }, &buf);
    const expected = switch (builtin.cpu.arch) {
        .aarch64 => "wispterm-macos-aarch64-v1.28.0.dmg",
        .x86_64 => "wispterm-macos-x86_64-v1.28.0.dmg",
        else => return error.SkipZigTest,
    };
    try std.testing.expectEqualStrings(expected, name);
    try std.testing.expect(matchesAssetName(expected, "v1.28.0", .{ .platform = .macos }));
    try std.testing.expect(!matchesAssetName("wispterm-macos-v1.28.0.dmg", "v1.28.0", .{ .platform = .macos }));
    try std.testing.expect(!matchesAssetName("wispterm-macos-v1.28.0.zip", "v1.28.0", .{ .platform = .macos }));
}

test "platform update package builds Linux AppImage asset names" {
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;

    var buf: [128]u8 = undefined;
    const package = release_package.Package{ .platform = .linux };
    const name = try assetName("v1.33.1", package, &buf);
    try std.testing.expectEqualStrings("WispTerm-1.33.1-x86_64.AppImage", name);
    try std.testing.expect(matchesAssetName("WispTerm-1.33.1-x86_64.AppImage", "v1.33.1", package));
    try std.testing.expect(!matchesAssetName("WispTerm-v1.33.1-x86_64.AppImage", "v1.33.1", package));
}

test "platform update package rejects unsupported platform asset names" {
    var buf: [128]u8 = undefined;
    try std.testing.expectError(error.UnsupportedReleasePackage, assetName("v0.28.0", .{
        .platform = .unsupported,
    }, &buf));
    try std.testing.expect(!matchesAssetName("wispterm-freebsd-v0.28.0.tar.gz", "v0.28.0", .{
        .platform = .unsupported,
    }));
}

test "platform update package exposes platform-neutral package scenarios" {
    var buf: [128]u8 = undefined;

    const baseline = packageForScenario(.baseline);
    const baseline_name = try assetNameForScenario("v0.28.0", .baseline, &buf);
    try std.testing.expectEqual(release_package.Platform.windows, baseline.platform);
    try std.testing.expectEqualStrings("wispterm-windows-portable-v0.28.0.zip", baseline_name);
}
