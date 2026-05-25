const std = @import("std");
const builtin = @import("builtin");
const release_package = @import("../release_package.zig");
const release_asset_backend = @import("update_package_windows.zig");

pub const PayloadEntry = release_package.PayloadEntry;

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

pub fn payloadManifest(package: release_package.Package) ![]const PayloadEntry {
    return switch (package.platform) {
        .windows => release_asset_backend.payloadManifest(package),
        else => error.UnsupportedReleasePackage,
    };
}

pub fn mainExecutablePath(package: release_package.Package) ![]const u8 {
    return switch (package.platform) {
        .windows => release_asset_backend.mainExecutablePath(package),
        else => error.UnsupportedReleasePackage,
    };
}

pub fn updaterExecutablePath(package: release_package.Package) ![]const u8 {
    return switch (package.platform) {
        .windows => release_asset_backend.updaterExecutablePath(package),
        else => error.UnsupportedReleasePackage,
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

pub const ArchiveEntryNameError = error{UnsafeArchiveEntryName};

fn isDriveQualifiedArchiveName(name: []const u8) bool {
    return name.len >= 3 and
        std.ascii.isAlphabetic(name[0]) and
        name[1] == ':' and
        (name[2] == '/' or name[2] == '\\');
}

fn isReservedArchiveNameChar(c: u8) bool {
    return switch (c) {
        '<', '>', ':', '"', '|', '?', '*' => true,
        else => false,
    };
}

pub fn validateArchiveEntryName(name: []const u8) ArchiveEntryNameError!void {
    if (name.len == 0) return error.UnsafeArchiveEntryName;
    if (name[0] == '/' or name[0] == '\\') return error.UnsafeArchiveEntryName;
    if (isDriveQualifiedArchiveName(name)) return error.UnsafeArchiveEntryName;

    var component_start: usize = 0;
    var saw_component = false;
    for (name, 0..) |c, i| {
        if (isReservedArchiveNameChar(c)) return error.UnsafeArchiveEntryName;
        if (c != '/' and c != '\\') continue;

        if (i == component_start) return error.UnsafeArchiveEntryName;
        const component = name[component_start..i];
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return error.UnsafeArchiveEntryName;
        saw_component = true;
        component_start = i + 1;
    }

    if (component_start == name.len) {
        if (!saw_component) return error.UnsafeArchiveEntryName;
        return;
    }

    const component = name[component_start..];
    if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return error.UnsafeArchiveEntryName;
}

pub fn updaterReplacementPackage() release_package.Package {
    return release_package.Package.init(.windows, .baseline);
}

pub fn updaterReplacementManifest() []const release_package.PayloadEntry {
    return payloadManifest(updaterReplacementPackage()) catch unreachable;
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

    const required_extra = try payloadManifest(packageForScenario(.with_required_embedded_browser_payload));
    try std.testing.expect(!required_extra[required_extra.len - 1].optional);

    const without_extra = try payloadManifest(packageForScenario(.without_embedded_browser_payload));
    try std.testing.expect(without_extra[without_extra.len - 1].optional);
}

test "platform update package exposes updater replacement manifest package" {
    const manifest = updaterReplacementManifest();
    try std.testing.expectEqualStrings(try mainExecutablePath(updaterReplacementPackage()), manifest[0].path);
    try std.testing.expectEqualStrings(try updaterExecutablePath(updaterReplacementPackage()), manifest[1].path);
}

test "platform update package exposes payload metadata through platform boundary" {
    const package = packageForScenario(.baseline);
    const manifest = try payloadManifest(package);
    try std.testing.expect(@TypeOf(manifest[0]) == PayloadEntry);
    try std.testing.expectEqualStrings(try mainExecutablePath(package), manifest[0].path);
    try std.testing.expectEqualStrings(try updaterExecutablePath(package), manifest[1].path);
}

test "platform update package provides Windows portable payload manifest" {
    const portable = try payloadManifest(packageForScenario(.baseline));
    try std.testing.expectEqual(@as(usize, 5), portable.len);
    try std.testing.expectEqualStrings(try mainExecutablePath(packageForScenario(.baseline)), portable[0].path);
    try std.testing.expect(!portable[0].directory);
    try std.testing.expect(!portable[0].optional);
    try std.testing.expectEqualStrings("plugins", portable[3].path);
    try std.testing.expect(portable[3].directory);
    try std.testing.expectEqualStrings(release_asset_backend.embeddedBrowserPayloadPath(), portable[4].path);
    try std.testing.expect(portable[4].optional);

    const embedded_browser = try payloadManifest(packageForScenario(.with_required_embedded_browser_payload));
    try std.testing.expect(!embedded_browser[4].optional);
}

test "platform update package rejects executable payload paths for unsupported packages" {
    try std.testing.expectError(error.UnsupportedReleasePackage, mainExecutablePath(.{ .platform = .linux }));
    try std.testing.expectError(error.UnsupportedReleasePackage, updaterExecutablePath(.{ .platform = .macos }));
}

test "platform update package validates archive entry names for extraction" {
    try validateArchiveEntryName("plugins\\skill\\SKILL.md");
    try validateArchiveEntryName("plugins/");

    const unsafe_names = [_][]const u8{
        "",
        "/phantty.exe",
        "\\phantty.exe",
        "//phantty.exe",
        "\\\\server\\share\\phantty.exe",
        "C:\\Phantty\\phantty.exe",
        "C:/Phantty/phantty.exe",
        "plugins//skill",
        "plugins\\\\skill",
        "plugins/./skill",
        "plugins/../skill",
        "plugins/skill:name",
        "plugins/skill?.md",
    };

    for (unsafe_names) |name| {
        try std.testing.expectError(error.UnsafeArchiveEntryName, validateArchiveEntryName(name));
    }
}
