//! Shared overlay drawing primitives.

const AppWindow = @import("../../AppWindow.zig");
const gl_init = AppWindow.gpu.gl_init;

/// Render a rounded rectangle with the given color and alpha.
/// Uses multiple quads to approximate rounded corners.
pub fn renderRoundedQuadAlpha(x: f32, y: f32, w: f32, h: f32, radius: f32, color: [3]f32, alpha: f32) void {
    const r = @min(radius, @min(w, h) / 2); // Clamp radius to half of smallest dimension

    // Main body (center rectangle, full height minus corners)
    gl_init.renderQuadAlpha(x + r, y, w - r * 2, h, color, alpha);

    // Left strip (between corners)
    gl_init.renderQuadAlpha(x, y + r, r, h - r * 2, color, alpha);

    // Right strip (between corners)
    gl_init.renderQuadAlpha(x + w - r, y + r, r, h - r * 2, color, alpha);

    // Approximate corners with small quads (simple 2-step approximation)
    // Bottom-left corner
    const r2 = r * 0.7; // Inner radius approximation
    gl_init.renderQuadAlpha(x + r - r2, y + r - r2, r2, r2, color, alpha);
    gl_init.renderQuadAlpha(x, y + r - r2, r - r2, r2, color, alpha);
    gl_init.renderQuadAlpha(x + r - r2, y, r2, r - r2, color, alpha);

    // Bottom-right corner
    gl_init.renderQuadAlpha(x + w - r, y + r - r2, r2, r2, color, alpha);
    gl_init.renderQuadAlpha(x + w - r + r2, y + r - r2, r - r2, r2, color, alpha);
    gl_init.renderQuadAlpha(x + w - r, y, r2, r - r2, color, alpha);

    // Top-left corner
    gl_init.renderQuadAlpha(x + r - r2, y + h - r, r2, r2, color, alpha);
    gl_init.renderQuadAlpha(x, y + h - r, r - r2, r2, color, alpha);
    gl_init.renderQuadAlpha(x + r - r2, y + h - r + r2, r2, r - r2, color, alpha);

    // Top-right corner
    gl_init.renderQuadAlpha(x + w - r, y + h - r, r2, r2, color, alpha);
    gl_init.renderQuadAlpha(x + w - r + r2, y + h - r, r - r2, r2, color, alpha);
    gl_init.renderQuadAlpha(x + w - r, y + h - r + r2, r2, r - r2, color, alpha);
}

pub fn mixColor(from: [3]f32, to: [3]f32, amount: f32) [3]f32 {
    const inv = 1.0 - amount;
    return .{
        from[0] * inv + to[0] * amount,
        from[1] * inv + to[1] * amount,
        from[2] * inv + to[2] * amount,
    };
}
