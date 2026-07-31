//! Backend policy for Ghostty/Shadertoy-style custom post-processing shaders.
//!
//! The current custom shader path is GLSL/OpenGL-oriented. Until non-OpenGL
//! backends grow real translation or native shader loading, they should fail
//! closed with a clear fallback message instead of trying to compile GLSL as a
//! backend-native shader language.

const std = @import("std");
const Backend = @import("gpu/backend.zig").Backend;

pub const DisableReason = enum {
    d3d11_experimental,
    metal_translation_missing,

    pub fn message(self: DisableReason) []const u8 {
        return switch (self) {
            .d3d11_experimental => "D3D11 custom post-processing shaders are disabled while the backend is experimental; the frame renders without the custom shader",
            .metal_translation_missing => "Metal custom post-processing shaders need GLSL-to-MSL translation; the frame renders without the custom shader",
        };
    }
};

pub const Decision = union(enum) {
    load,
    disabled: DisableReason,
};

pub fn decide(backend: Backend) Decision {
    return switch (backend) {
        .opengl => .load,
        .d3d11 => .{ .disabled = .d3d11_experimental },
        .metal => .{ .disabled = .metal_translation_missing },
    };
}

test "post_process_policy: OpenGL loads custom shaders" {
    try std.testing.expect(decide(.opengl) == .load);
}

test "post_process_policy: D3D11 disables custom shaders with explicit fallback" {
    const decision = decide(.d3d11);
    try std.testing.expect(decision == .disabled);
    try std.testing.expectEqual(DisableReason.d3d11_experimental, decision.disabled);
    try std.testing.expect(std.mem.indexOf(u8, decision.disabled.message(), "disabled") != null);
    try std.testing.expect(std.mem.indexOf(u8, decision.disabled.message(), "without the custom shader") != null);
}

test "post_process_policy: Metal disables custom shaders until translation exists" {
    const decision = decide(.metal);
    try std.testing.expect(decision == .disabled);
    try std.testing.expectEqual(DisableReason.metal_translation_missing, decision.disabled);
    try std.testing.expect(std.mem.indexOf(u8, decision.disabled.message(), "GLSL-to-MSL") != null);
}
