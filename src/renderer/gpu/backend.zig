//! GPU backend selection. Mirrors Ghostty's `src/renderer/backend.zig`:
//! a `Backend` enum with `default(os_tag)` that returns `.metal` on Darwin,
//! `.opengl` elsewhere. Windows-native D3D11 is opt-in during Phase II.
//! Selection is comptime (see `gpu.zig`).

const std = @import("std");

pub const Backend = enum {
    opengl,
    metal,
    d3d11,

    /// The default backend for a target OS. macOS/iOS are Metal-only
    /// (Apple deprecated OpenGL at 4.1); everything else uses OpenGL while
    /// the D3D11 backend is experimental.
    pub fn default(os_tag: std.Target.Os.Tag) Backend {
        return switch (os_tag) {
            .macos, .ios => .metal,
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

test "Backend.default maps Darwin to metal, others to opengl while d3d11 is opt-in" {
    try std.testing.expectEqual(Backend.metal, Backend.default(.macos));
    try std.testing.expectEqual(Backend.metal, Backend.default(.ios));
    try std.testing.expectEqual(Backend.opengl, Backend.default(.windows));
    try std.testing.expectEqual(Backend.opengl, Backend.default(.linux));
}

test "Backend.resolve honors explicit d3d11 without changing auto defaults" {
    try std.testing.expectEqual(Backend.opengl, Backend.resolve(.windows, "auto"));
    try std.testing.expectEqual(Backend.metal, Backend.resolve(.macos, "auto"));
    try std.testing.expectEqual(Backend.d3d11, Backend.resolve(.windows, "d3d11"));
    try std.testing.expectEqual(Backend.opengl, Backend.resolve(.windows, "opengl"));
    try std.testing.expectEqual(Backend.metal, Backend.resolve(.windows, "metal"));
}
