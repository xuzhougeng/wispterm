//! GPU backend selection. Mirrors Ghostty's `src/renderer/backend.zig`:
//! a `Backend` enum with `default(os_tag)` that returns `.metal` on Darwin,
//! `.opengl` elsewhere. Selection is comptime (see `gpu.zig`).

const std = @import("std");

pub const Backend = enum {
    opengl,
    metal,

    /// The default backend for a target OS. macOS/iOS are Metal-only
    /// (Apple deprecated OpenGL at 4.1); everything else uses OpenGL.
    pub fn default(os_tag: std.Target.Os.Tag) Backend {
        return switch (os_tag) {
            .macos, .ios => .metal,
            else => .opengl,
        };
    }
};

test "Backend.default maps Darwin to metal, others to opengl" {
    try std.testing.expectEqual(Backend.metal, Backend.default(.macos));
    try std.testing.expectEqual(Backend.metal, Backend.default(.ios));
    try std.testing.expectEqual(Backend.opengl, Backend.default(.windows));
    try std.testing.expectEqual(Backend.opengl, Backend.default(.linux));
}
