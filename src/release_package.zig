const std = @import("std");

pub const Platform = enum {
    windows,
    macos,
    linux,
    unsupported,
};

pub const Flavor = enum {
    baseline,
    with_required_embedded_browser_payload,
    without_embedded_browser_payload,
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
        return self.flavor == .with_required_embedded_browser_payload;
    }
};

test "release package exposes embedded browser payload requirement" {
    try std.testing.expect(Package.init(.windows, .with_required_embedded_browser_payload).requiresEmbeddedBrowserPayload());
    try std.testing.expect(!Package.init(.windows, .baseline).requiresEmbeddedBrowserPayload());
    try std.testing.expect(!(Package{ .platform = .linux }).requiresEmbeddedBrowserPayload());
}
