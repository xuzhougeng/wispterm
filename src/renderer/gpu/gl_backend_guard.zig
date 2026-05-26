//! Compile-time guard: raw OpenGL belongs only to the gpu/opengl backend.
//!
//! Phase A / A6 + D-prep ①c. Comptime source-text scans (mirroring
//! `platform/apprt_win32_guard.zig`), imported by `test_main.zig` so they run
//! under `zig build test`/`test-full`.
//!
//!   1. **glad containment** — no app/renderer/font file outside
//!      `src/renderer/gpu/opengl/` may `@cInclude("glad/gl.h")`. Everyone else
//!      uses `gpu.c`. `AppWindow.zig` included (the host must not pull in glad).
//!   2. **raw-GL lock** — the renderer/presentation layer must not touch the raw
//!      GL function table, neither via `gpu.glTable()` nor by reaching into
//!      `gpu.Context.gl` directly. All GPU work goes through the gpu interface
//!      (`gpu.Pipeline`/`Buffer`/`Texture`/`Framebuffer`/`state`/`vertex`), so a
//!      Metal backend can implement the same calls. This now covers the whole
//!      rendering layer (D-prep ① neutralized `ui_pipeline`/`cell_pipeline`/
//!      `cell_renderer`/`post_process`/`Renderer`/`markdown`/`weixin`/`overlays/*`).
//!
//! Residue (intentionally NOT locked): `AppWindow.zig` still calls `glTable()`
//! for the GL-context-creation seam (`Context.init` via `glGetProcAddress`) and a
//! render-diagnostics snapshot — both host-specific, replaced by the macOS host /
//! generalized by the surface seam in Phase D.

const std = @import("std");

const glad_include = "@cInclude(\"glad/gl.h\")";
const gl_table_call = "glTable(";
const gl_context_bypass = "gpu.Context.gl";

// Single embed per file; the rule lists reference these.
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
const src_cell_pipeline = @embedFile("../cell_pipeline.zig");
const src_ui_pipeline = @embedFile("../ui_pipeline.zig");
const src_weixin = @embedFile("../weixin_qr_renderer.zig");
const src_renderer = @embedFile("../Renderer.zig");
const src_ov_resize = @embedFile("../overlays/resize.zig");
const src_ov_scrollbar = @embedFile("../overlays/scrollbar.zig");
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

/// Rule 2 — the whole rendering/presentation layer: no `gpu.glTable()` and no
/// `gpu.Context.gl` reach-around. (D-prep ① made all of these GL-table-free.)
const raw_gl_free = [_]Entry{
    .{ .name = "renderer/ui_pipeline.zig", .source = src_ui_pipeline },
    .{ .name = "renderer/cell_pipeline.zig", .source = src_cell_pipeline },
    .{ .name = "renderer/cell_renderer.zig", .source = src_cell_renderer },
    .{ .name = "renderer/post_process.zig", .source = src_post_process },
    .{ .name = "renderer/Renderer.zig", .source = src_renderer },
    .{ .name = "renderer/titlebar.zig", .source = src_titlebar },
    .{ .name = "renderer/ai_chat_renderer.zig", .source = src_ai_chat },
    .{ .name = "renderer/file_explorer_renderer.zig", .source = src_file_explorer },
    .{ .name = "renderer/markdown_preview_renderer.zig", .source = src_markdown },
    .{ .name = "renderer/image_renderer.zig", .source = src_image },
    .{ .name = "renderer/background_image.zig", .source = src_background },
    .{ .name = "renderer/fbo.zig", .source = src_fbo },
    .{ .name = "renderer/weixin_qr_renderer.zig", .source = src_weixin },
    .{ .name = "renderer/overlays.zig", .source = src_overlays },
    .{ .name = "renderer/overlays/resize.zig", .source = src_ov_resize },
    .{ .name = "renderer/overlays/scrollbar.zig", .source = src_ov_scrollbar },
    .{ .name = "renderer/overlays/startup_shortcuts.zig", .source = src_ov_startup },
    .{ .name = "font/manager.zig", .source = src_font_manager },
};

/// Returns the offending file name if any entry contains `needle`, else null.
/// Pure helper so the logic is unit-testable independently of the comptime scan.
fn firstMatch(comptime entries: []const Entry, needle: []const u8) ?[]const u8 {
    for (entries) |entry| {
        if (std.mem.indexOf(u8, entry.source, needle) != null) return entry.name;
    }
    return null;
}

comptime {
    @setEvalBranchQuota(40_000_000);
    if (firstMatch(&glad_free, glad_include)) |name| {
        @compileError(name ++ " must not @cInclude(\"glad/gl.h\") — raw GL is backend-only (src/renderer/gpu/opengl/); use gpu.c");
    }
    if (firstMatch(&raw_gl_free, gl_table_call)) |name| {
        @compileError(name ++ " must not call gpu.glTable() — route GPU work through the gpu interface (Pipeline/Buffer/Texture/Framebuffer/state/vertex)");
    }
    if (firstMatch(&raw_gl_free, gl_context_bypass)) |name| {
        @compileError(name ++ " must not reach into gpu.Context.gl — that bypasses the gpu interface; use gpu.state/vertex/Pipeline instead");
    }
}

test "guard data is internally consistent (locked files are clean)" {
    try std.testing.expect(firstMatch(&glad_free, glad_include) == null);
    try std.testing.expect(firstMatch(&raw_gl_free, gl_table_call) == null);
    try std.testing.expect(firstMatch(&raw_gl_free, gl_context_bypass) == null);
}

test "firstMatch detects planted needles" {
    const planted_glad = [_]Entry{.{ .name = "x.zig", .source = "a\n@cInclude(\"glad/gl.h\")\nb" }};
    try std.testing.expectEqualStrings("x.zig", firstMatch(&planted_glad, glad_include).?);
    const planted_table = [_]Entry{.{ .name = "y.zig", .source = "const gl = gpu.glTable();" }};
    try std.testing.expectEqualStrings("y.zig", firstMatch(&planted_table, gl_table_call).?);
    const planted_ctx = [_]Entry{.{ .name = "z.zig", .source = "const gl = gpu.Context.gl;" }};
    try std.testing.expectEqualStrings("z.zig", firstMatch(&planted_ctx, gl_context_bypass).?);
    const clean = [_]Entry{.{ .name = "ok.zig", .source = "gpu.state.clear(0,0,0,1);" }};
    try std.testing.expect(firstMatch(&clean, gl_table_call) == null);
}
