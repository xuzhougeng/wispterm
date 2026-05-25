const std = @import("std");
const builtin = @import("builtin");
const release_package = @import("../release_package.zig");

pub fn currentPackage(allocator: std.mem.Allocator, webview_enabled: bool) !release_package.Package {
    _ = allocator;
    _ = webview_enabled;
    return defaultPackageForOs(builtin.os.tag);
}

fn defaultPackageForOs(os_tag: std.Target.Os.Tag) release_package.Package {
    return switch (os_tag) {
        .macos => .{ .platform = .macos },
        .linux => .{ .platform = .linux },
        else => .{ .platform = .unsupported },
    };
}
