//! GPU backend selection. Mirrors Ghostty's `src/renderer/backend.zig`:
//! a `Backend` enum with `default(os_tag)` that keeps the platform choice thin:
//! Metal on Darwin, D3D11 on Windows, and OpenGL elsewhere.
//! Selection is comptime (see `gpu.zig`).

const std = @import("std");

pub const Backend = enum {
    opengl,
    metal,
    d3d11,

    /// The default backend for a target OS.
    pub fn default(os_tag: std.Target.Os.Tag) Backend {
        return switch (os_tag) {
            .macos, .ios => .metal,
            .windows => .d3d11,
            else => .opengl,
        };
    }

    pub fn parse(name: []const u8) ?Backend {
        inline for (@typeInfo(Backend).@"enum".fields) |field| {
            if (std.mem.eql(u8, name, field.name)) {
                return @enumFromInt(field.value);
            }
        }
        return null;
    }

    pub fn resolve(os_tag: std.Target.Os.Tag, build_option: []const u8) Backend {
        if (std.mem.eql(u8, build_option, "auto")) return default(os_tag);
        return parse(build_option) orelse default(os_tag);
    }
};

test "Backend.default maps each desktop family to its native default" {
    try std.testing.expectEqual(Backend.metal, Backend.default(.macos));
    try std.testing.expectEqual(Backend.metal, Backend.default(.ios));
    try std.testing.expectEqual(Backend.d3d11, Backend.default(.windows));
    try std.testing.expectEqual(Backend.opengl, Backend.default(.linux));
}

test "Backend.resolve honors auto and explicit overrides" {
    try std.testing.expectEqual(Backend.d3d11, Backend.resolve(.windows, "auto"));
    try std.testing.expectEqual(Backend.metal, Backend.resolve(.macos, "auto"));
    try std.testing.expectEqual(Backend.d3d11, Backend.resolve(.windows, "d3d11"));
    try std.testing.expectEqual(Backend.opengl, Backend.resolve(.windows, "opengl"));
    try std.testing.expectEqual(Backend.metal, Backend.resolve(.windows, "metal"));
}
