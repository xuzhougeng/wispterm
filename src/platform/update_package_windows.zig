const std = @import("std");
const release_package = @import("../release_package.zig");

const embedded_browser_payload_path = "WebView2Loader.dll";
const bundled_console_host_payload_path = "conpty.dll";

const AssetNameParts = struct {
    prefix: []const u8,
    suffix: []const u8,
};

pub fn currentPackage(allocator: std.mem.Allocator, webview_enabled: bool) !release_package.Package {
    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);
    const exe_dir = std.fs.path.dirname(exe_path) orelse return release_package.Package.init(.windows, .baseline);
    // Either payload marks a compat install: webview2-flavor installs from
    // before the compat package existed carry only the embedded-browser
    // loader, and their next auto-update migrates them onto the compat asset
    // (a superset that adds the bundled console host).
    const has_compat_payload = payloadExists(allocator, exe_dir, embeddedBrowserPayloadPath()) or
        payloadExists(allocator, exe_dir, bundled_console_host_payload_path);
    return release_package.Package.init(.windows, runtimeFlavor(webview_enabled, has_compat_payload));
}

fn payloadExists(allocator: std.mem.Allocator, exe_dir: []const u8, name: []const u8) bool {
    const path = std.fs.path.join(allocator, &.{ exe_dir, name }) catch return false;
    defer allocator.free(path);
    var file = std.fs.openFileAbsolute(path, .{}) catch return false;
    file.close();
    return true;
}

fn assetNameParts(package: release_package.Package) ?AssetNameParts {
    if (package.platform != .windows) return null;
    return switch (package.flavor) {
        .baseline => .{
            .prefix = "wispterm-windows-portable-",
            .suffix = ".zip",
        },
        .compat => .{
            .prefix = "wispterm-windows-portable-compat-",
            .suffix = ".zip",
        },
    };
}

pub fn assetName(tag_name: []const u8, package: release_package.Package, buf: []u8) ![]const u8 {
    const parts = assetNameParts(package) orelse return error.UnsupportedReleasePackage;
    return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ parts.prefix, tag_name, parts.suffix });
}

pub fn matchesAssetName(name: []const u8, tag_name: []const u8, package: release_package.Package) bool {
    const parts = assetNameParts(package) orelse return false;
    return name.len == parts.prefix.len + tag_name.len + parts.suffix.len and
        std.mem.startsWith(u8, name, parts.prefix) and
        std.mem.endsWith(u8, name, parts.suffix) and
        std.mem.eql(u8, name[parts.prefix.len .. parts.prefix.len + tag_name.len], tag_name);
}

pub fn embeddedBrowserPayloadPath() []const u8 {
    return embedded_browser_payload_path;
}

fn runtimeFlavor(webview_enabled: bool, has_compat_payload: bool) release_package.Flavor {
    _ = webview_enabled;
    if (has_compat_payload) return .compat;
    return .baseline;
}
