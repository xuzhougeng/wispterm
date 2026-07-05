const std = @import("std");

pub const Platform = enum {
    windows,
    macos,
    linux,
    unsupported,
};

pub const Flavor = enum {
    baseline,
    /// Full-featured package for older Windows machines: ships the embedded
    /// browser loader plus a modern bundled console host.
    compat,
};

pub const Package = struct {
    platform: Platform,
    flavor: Flavor = .baseline,

    pub fn init(platform: Platform, flavor: Flavor) Package {
        return .{
            .platform = platform,
            .flavor = flavor,
        };
    }

    pub fn requiresEmbeddedBrowserPayload(self: Package) bool {
        return self.flavor == .compat;
    }
};

test "release package exposes embedded browser payload requirement" {
    try std.testing.expect(Package.init(.windows, .compat).requiresEmbeddedBrowserPayload());
    try std.testing.expect(!Package.init(.windows, .baseline).requiresEmbeddedBrowserPayload());
    try std.testing.expect(!(Package{ .platform = .linux }).requiresEmbeddedBrowserPayload());
}
