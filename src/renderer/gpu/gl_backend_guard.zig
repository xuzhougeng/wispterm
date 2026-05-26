//! Compile-time guard: raw OpenGL belongs only to the gpu/opengl backend.
//!
//! Phase A / A6. Two invariants, enforced as comptime source-text scans
//! (mirroring `platform/apprt_win32_guard.zig`) so they run on every build of
//! the test graph without compiling anything backend-specific. `test_main.zig`
//! imports this module so the checks execute under `zig build test`/`test-full`.
//!
//!   1. **glad containment** — no app/renderer/font file outside
//!      `src/renderer/gpu/opengl/` may `@cInclude("glad/gl.h")`. The raw GPU API
//!      header is included only by the backend; everyone else uses `gpu.c`.
//!      `AppWindow.zig` is included here — the host must not pull in glad either.
//!   2. **raw-GL regression-lock** — the renderer feature files decoupled in
//!      A3/A4 must not re-acquire a raw GL function table via `gpu.glTable()`.
//!
//! Known residue (intentionally NOT in `gl_table_free`): the GL presentation
//! layer (`ui_pipeline`, `cell_pipeline`), render coordination (`Renderer`,
//! `cell_renderer`, `post_process`), and the not-yet-extracted plumbing in
//! `markdown_preview_renderer`, `weixin_qr_renderer`, and
//! `overlays/{resize,scrollbar,startup_shortcuts}` still call `gpu.glTable()`.
//! They hold the table from the gpu module (no glad include); the gpu primitive
//! set grows to absorb them. None of them is permitted a glad `@cInclude`.

const std = @import("std");

const glad_include = "@cInclude(\"glad/gl.h\")";
const gl_table_call = "glTable(";

// Single embed per file; the two rule lists reference these.
const src_app_window = @embedFile("../../AppWindow.zig");
const src_font_manager = @embedFile("../../font/manager.zig");
const src_titlebar = @embedFile("../titlebar.zig");
const src_ai_chat = @embedFile("../ai_chat_renderer.zig");
const src_file_explorer = @embedFile("../file_explorer_renderer.zig");
const src_markdown = @embedFile("../markdown_preview_renderer.zig");
const src_overlays = @embedFile("../overlays.zig");
const src_image = @embedFile("../image_renderer.zig");
const src_background = @embedFile("../background_image.zig");
const src_post_process = @embedFile("../post_process.zig");
const src_fbo = @embedFile("../fbo.zig");
const src_cell_renderer = @embedFile("../cell_renderer.zig");
const src_weixin = @embedFile("../weixin_qr_renderer.zig");
const src_renderer = @embedFile("../Renderer.zig");
const src_ov_resize = @embedFile("../overlays/resize.zig");
const src_ov_startup = @embedFile("../overlays/startup_shortcuts.zig");

const Entry = struct { name: []const u8, source: []const u8 };

/// Rule 1 — must not `@cInclude("glad/gl.h")` (raw GL header is backend-only).
const glad_free = [_]Entry{
    .{ .name = "AppWindow.zig", .source = src_app_window },
    .{ .name = "font/manager.zig", .source = src_font_manager },
    .{ .name = "renderer/titlebar.zig", .source = src_titlebar },
    .{ .name = "renderer/ai_chat_renderer.zig", .source = src_ai_chat },
    .{ .name = "renderer/file_explorer_renderer.zig", .source = src_file_explorer },
    .{ .name = "renderer/markdown_preview_renderer.zig", .source = src_markdown },
    .{ .name = "renderer/overlays.zig", .source = src_overlays },
    .{ .name = "renderer/image_renderer.zig", .source = src_image },
    .{ .name = "renderer/background_image.zig", .source = src_background },
    .{ .name = "renderer/post_process.zig", .source = src_post_process },
    .{ .name = "renderer/fbo.zig", .source = src_fbo },
    .{ .name = "renderer/cell_renderer.zig", .source = src_cell_renderer },
    .{ .name = "renderer/weixin_qr_renderer.zig", .source = src_weixin },
    .{ .name = "renderer/Renderer.zig", .source = src_renderer },
    .{ .name = "renderer/overlays/resize.zig", .source = src_ov_resize },
    .{ .name = "renderer/overlays/startup_shortcuts.zig", .source = src_ov_startup },
};

/// Rule 2 — feature files decoupled in A3/A4: locked against re-acquiring a raw
/// GL table. (A subset of `glad_free` that must hold ZERO `gpu.glTable()` calls.)
const gl_table_free = [_]Entry{
    .{ .name = "renderer/titlebar.zig", .source = src_titlebar },
    .{ .name = "renderer/ai_chat_renderer.zig", .source = src_ai_chat },
    .{ .name = "renderer/file_explorer_renderer.zig", .source = src_file_explorer },
    .{ .name = "renderer/image_renderer.zig", .source = src_image },
    .{ .name = "renderer/background_image.zig", .source = src_background },
    .{ .name = "renderer/fbo.zig", .source = src_fbo },
    .{ .name = "renderer/overlays.zig", .source = src_overlays },
    .{ .name = "font/manager.zig", .source = src_font_manager },
};

/// Returns the offending file name if `source` violates the named rule, else null.
/// Pure helper so the logic is unit-testable independently of the comptime scan.
fn firstMatch(comptime entries: []const Entry, needle: []const u8) ?[]const u8 {
    for (entries) |entry| {
        if (std.mem.indexOf(u8, entry.source, needle) != null) return entry.name;
    }
    return null;
}

comptime {
    @setEvalBranchQuota(20_000_000);
    if (firstMatch(&glad_free, glad_include)) |name| {
        @compileError(name ++ " must not @cInclude(\"glad/gl.h\") — raw GL is backend-only (src/renderer/gpu/opengl/); use gpu.c");
    }
    if (firstMatch(&gl_table_free, gl_table_call)) |name| {
        @compileError(name ++ " must not call gpu.glTable() — it was decoupled in A3/A4; route draws through ui_pipeline / gpu primitives");
    }
}

test "guard data is internally consistent (no glad include / glTable in locked files)" {
    // The comptime block above already enforces this at build time; this test
    // makes the failure legible if it ever regresses and documents the contract.
    try std.testing.expect(firstMatch(&glad_free, glad_include) == null);
    try std.testing.expect(firstMatch(&gl_table_free, gl_table_call) == null);
}

test "firstMatch detects a planted needle" {
    const planted = [_]Entry{.{ .name = "x.zig", .source = "a\n@cInclude(\"glad/gl.h\")\nb" }};
    try std.testing.expectEqualStrings("x.zig", firstMatch(&planted, glad_include).?);
    const clean = [_]Entry{.{ .name = "y.zig", .source = "const c = gpu.c;" }};
    try std.testing.expect(firstMatch(&clean, glad_include) == null);
}
