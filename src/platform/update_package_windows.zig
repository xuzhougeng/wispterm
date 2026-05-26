const std = @import("std");
const release_package = @import("../release_package.zig");

const embedded_browser_payload_path = "WebView2Loader.dll";

const AssetNameParts = struct {
    prefix: []const u8,
    suffix: []const u8,
};

pub fn currentPackage(allocator: std.mem.Allocator, webview_enabled: bool) !release_package.Package {
    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);
    const exe_dir = std.fs.path.dirname(exe_path) orelse return release_package.Package.init(.windows, .baseline);
    const payload_path = try std.fs.path.join(allocator, &.{ exe_dir, embeddedBrowserPayloadPath() });
    defer allocator.free(payload_path);
    const has_embedded_browser_payload = blk: {
        var file = std.fs.openFileAbsolute(payload_path, .{}) catch break :blk false;
        file.close();
        break :blk true;
    };
    return release_package.Package.init(.windows, runtimeFlavor(webview_enabled, has_embedded_browser_payload));
}

fn assetNameParts(package: release_package.Package) ?AssetNameParts {
    if (package.platform != .windows) return null;
    return switch (package.flavor) {
        .baseline => .{
            .prefix = "phantty-windows-portable-",
            .suffix = ".zip",
        },
        .with_required_embedded_browser_payload => .{
            .prefix = "phantty-windows-portable-webview2-",
            .suffix = ".zip",
        },
        .without_embedded_browser_payload => .{
            .prefix = "phantty-windows-portable-no-webview-",
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

fn runtimeFlavor(webview_enabled: bool, has_embedded_browser_payload: bool) release_package.Flavor {
    if (!webview_enabled) return .without_embedded_browser_payload;
    if (has_embedded_browser_payload) return .with_required_embedded_browser_payload;
    return .baseline;
}
