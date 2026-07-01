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
//! for the GL-context-creation seam (`Context.init` via `glGetProcAddress`).
//! Render diagnostics must use backend-neutral `gpu.state` APIs.

const std = @import("std");

const glad_include = "@cInclude(\"glad/gl.h\")";
const gl_table_call = "glTable(";
const gl_context_bypass = "gpu.Context.gl";
const gl_buffer_vocab = [_][]const u8{
    "c.GL_ARRAY_BUFFER",
    "c.GL_STATIC_DRAW",
    "c.GL_STREAM_DRAW",
    "c.GL_DYNAMIC_DRAW",
};
const gl_topology_vocab = [_][]const u8{
    "c.GL_TRIANGLES",
    "c.GL_TRIANGLE_STRIP",
};
const gl_texture_upload_vocab = [_][]const u8{
    ".internal_format",
    ".data_type",
    ".format = c.GL",
    "c.GL_RED",
    "c.GL_RGBA8",
    "c.GL_BGRA",
    "c.GL_RGBA",
};
const gl_texture_handle_vocab = [_][]const u8{
    "c.GLuint",
    "gpu.c.GLuint",
    "drawGlyph(rect: Rect, uv: Uv, tex: c.GLuint",
    "drawColorGlyph(rect: Rect, uv: Uv, tex: c.GLuint",
    "drawTextureQuad(verts: [6][4]f32, tex: c.GLuint",
};
const gl_renderer_handle_vocab = [_][]const u8{
    "Renderer.GLuint",
    "pub const GLuint",
    "texture: GLuint",
    "fbo: GLuint",
    "fbo_texture: GLuint",
};
const appwindow_gl_diag_vocab = [_][]const u8{
    "gpu.c.GL",
};
const gl_c_alias_vocab = [_][]const u8{
    "const c = gpu.c",
    "const c = AppWindow.gpu.c",
};
const gl_init_runtime_vocab = [_][]const u8{
    "gl_init.g_bg_opacity",
    "gl_init.g_draw_call_count",
    "gpu.gl_init.g_bg_opacity",
    "gpu.gl_init.g_draw_call_count",
    "AppWindow.gpu.gl_init.g_draw_call_count",
};
const gl_init_render_vocab = [_][]const u8{
    "gl_init.renderQuad(",
    "gl_init.renderQuadAlpha(",
};
const gl_init_projection_vocab = [_][]const u8{
    "gpu.gl_init.setProjection",
};
const appwindow_gl_init_vocab = [_][]const u8{
    "gpu.gl_init.",
    "AppWindow.gpu.gl_init",
};

// Single embed per file; the rule lists reference these.
const src_app_window = @embedFile("../../AppWindow.zig");
const src_appwindow_split_layout = @embedFile("../../appwindow/split_layout.zig");
const src_font_manager = @embedFile("../../font/manager.zig");
const src_preview_pane = @embedFile("../../preview/pane.zig");
const src_titlebar = @embedFile("../titlebar.zig");
const src_assistant_conversation = @embedFile("../assistant/conversation.zig");
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
const src_feishu_qr = @embedFile("../feishu_qr_renderer.zig");
const src_renderer = @embedFile("../Renderer.zig");
const src_ov_primitives = @embedFile("../overlays/primitives.zig");
const src_ov_resize = @embedFile("../overlays/resize.zig");
const src_ov_scrollbar = @embedFile("../overlays/scrollbar.zig");
const src_ov_startup = @embedFile("../overlays/startup_shortcuts.zig");

const Entry = struct { name: []const u8, source: []const u8 };

/// Rule 1 — must not `@cInclude("glad/gl.h")` (raw GL header is backend-only).
const glad_free = [_]Entry{
    .{ .name = "AppWindow.zig", .source = src_app_window },
    .{ .name = "font/manager.zig", .source = src_font_manager },
    .{ .name = "renderer/titlebar.zig", .source = src_titlebar },
    .{ .name = "renderer/assistant/conversation.zig", .source = src_assistant_conversation },
    .{ .name = "renderer/file_explorer_renderer.zig", .source = src_file_explorer },
    .{ .name = "renderer/markdown_preview_renderer.zig", .source = src_markdown },
    .{ .name = "renderer/overlays.zig", .source = src_overlays },
    .{ .name = "renderer/image_renderer.zig", .source = src_image },
    .{ .name = "renderer/background_image.zig", .source = src_background },
    .{ .name = "renderer/post_process.zig", .source = src_post_process },
    .{ .name = "renderer/fbo.zig", .source = src_fbo },
    .{ .name = "renderer/cell_renderer.zig", .source = src_cell_renderer },
    .{ .name = "renderer/weixin_qr_renderer.zig", .source = src_weixin },
    .{ .name = "renderer/feishu_qr_renderer.zig", .source = src_feishu_qr },
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
    .{ .name = "renderer/assistant/conversation.zig", .source = src_assistant_conversation },
    .{ .name = "renderer/file_explorer_renderer.zig", .source = src_file_explorer },
    .{ .name = "renderer/markdown_preview_renderer.zig", .source = src_markdown },
    .{ .name = "renderer/image_renderer.zig", .source = src_image },
    .{ .name = "renderer/background_image.zig", .source = src_background },
    .{ .name = "renderer/fbo.zig", .source = src_fbo },
    .{ .name = "renderer/weixin_qr_renderer.zig", .source = src_weixin },
    .{ .name = "renderer/feishu_qr_renderer.zig", .source = src_feishu_qr },
    .{ .name = "renderer/overlays.zig", .source = src_overlays },
    .{ .name = "renderer/overlays/resize.zig", .source = src_ov_resize },
    .{ .name = "renderer/overlays/scrollbar.zig", .source = src_ov_scrollbar },
    .{ .name = "renderer/overlays/startup_shortcuts.zig", .source = src_ov_startup },
    .{ .name = "font/manager.zig", .source = src_font_manager },
};

/// Rule 3 — files migrated to backend-neutral draw/buffer vocabulary must not
/// reintroduce GL topology or buffer-usage constants.
const neutral_buffer_vocab = [_]Entry{
    .{ .name = "renderer/ui_pipeline.zig", .source = src_ui_pipeline },
    .{ .name = "renderer/cell_pipeline.zig", .source = src_cell_pipeline },
    .{ .name = "renderer/post_process.zig", .source = src_post_process },
};

const neutral_topology_vocab = [_]Entry{
    .{ .name = "renderer/ui_pipeline.zig", .source = src_ui_pipeline },
    .{ .name = "renderer/cell_renderer.zig", .source = src_cell_renderer },
    .{ .name = "renderer/post_process.zig", .source = src_post_process },
};

const neutral_texture_upload_vocab = [_]Entry{
    .{ .name = "renderer/ui_pipeline.zig", .source = src_ui_pipeline },
    .{ .name = "font/manager.zig", .source = src_font_manager },
};

const neutral_texture_handle_vocab = [_]Entry{
    .{ .name = "font/manager.zig", .source = src_font_manager },
    .{ .name = "preview/pane.zig", .source = src_preview_pane },
    .{ .name = "renderer/background_image.zig", .source = src_background },
    .{ .name = "renderer/ui_pipeline.zig", .source = src_ui_pipeline },
};

const neutral_renderer_handle_vocab = [_]Entry{
    .{ .name = "renderer/Renderer.zig", .source = src_renderer },
    .{ .name = "renderer/image_renderer.zig", .source = src_image },
};

const neutral_appwindow_diag_vocab = [_]Entry{
    .{ .name = "AppWindow.zig", .source = src_app_window },
};

const neutral_c_alias_vocab = [_]Entry{
    .{ .name = "renderer/ui_pipeline.zig", .source = src_ui_pipeline },
    .{ .name = "renderer/post_process.zig", .source = src_post_process },
    .{ .name = "renderer/Renderer.zig", .source = src_renderer },
};

const neutral_runtime_state_vocab = [_]Entry{
    .{ .name = "AppWindow.zig", .source = src_app_window },
    .{ .name = "renderer/background_image.zig", .source = src_background },
    .{ .name = "renderer/cell_renderer.zig", .source = src_cell_renderer },
    .{ .name = "renderer/overlays.zig", .source = src_overlays },
    .{ .name = "renderer/post_process.zig", .source = src_post_process },
    .{ .name = "renderer/ui_pipeline.zig", .source = src_ui_pipeline },
};

const neutral_ui_draw_vocab = [_]Entry{
    .{ .name = "AppWindow.zig", .source = src_app_window },
    .{ .name = "renderer/cell_renderer.zig", .source = src_cell_renderer },
    .{ .name = "renderer/titlebar.zig", .source = src_titlebar },
    .{ .name = "renderer/overlays/primitives.zig", .source = src_ov_primitives },
    .{ .name = "renderer/overlays/scrollbar.zig", .source = src_ov_scrollbar },
    .{ .name = "renderer/overlays/startup_shortcuts.zig", .source = src_ov_startup },
    .{ .name = "renderer/weixin_qr_renderer.zig", .source = src_weixin },
    .{ .name = "renderer/feishu_qr_renderer.zig", .source = src_feishu_qr },
};

const neutral_projection_vocab = [_]Entry{
    .{ .name = "AppWindow.zig", .source = src_app_window },
};

const neutral_appwindow_gl_init_vocab = [_]Entry{
    .{ .name = "AppWindow.zig", .source = src_app_window },
    .{ .name = "appwindow/split_layout.zig", .source = src_appwindow_split_layout },
    .{ .name = "renderer/ui_pipeline.zig", .source = src_ui_pipeline },
};

/// Returns the offending file name if any entry contains `needle`, else null.
/// Pure helper so the logic is unit-testable independently of the comptime scan.
fn firstMatch(comptime entries: []const Entry, needle: []const u8) ?[]const u8 {
    for (entries) |entry| {
        if (std.mem.indexOf(u8, entry.source, needle) != null) return entry.name;
    }
    return null;
}

const EntryNeedleMatch = struct { name: []const u8, needle: []const u8 };

fn firstNeedleMatch(source: []const u8, needles: []const []const u8) ?[]const u8 {
    for (needles) |needle| {
        if (std.mem.indexOf(u8, source, needle) != null) return needle;
    }
    return null;
}

fn firstEntryNeedleMatch(comptime entries: []const Entry, needles: []const []const u8) ?EntryNeedleMatch {
    for (entries) |entry| {
        if (firstNeedleMatch(entry.source, needles)) |needle| return .{ .name = entry.name, .needle = needle };
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
    if (firstEntryNeedleMatch(&neutral_buffer_vocab, &gl_buffer_vocab)) |match| {
        @compileError(match.name ++ " must not use " ++ match.needle ++ " — use WispTerm-owned gpu.BufferUsage / buffer APIs");
    }
    if (firstEntryNeedleMatch(&neutral_topology_vocab, &gl_topology_vocab)) |match| {
        @compileError(match.name ++ " must not use " ++ match.needle ++ " — use WispTerm-owned gpu.PrimitiveTopology");
    }
    if (firstEntryNeedleMatch(&neutral_texture_upload_vocab, &gl_texture_upload_vocab)) |match| {
        @compileError(match.name ++ " must not use " ++ match.needle ++ " — use WispTerm-owned gpu.TextureFormat / gpu.SamplerMode");
    }
    if (firstEntryNeedleMatch(&neutral_texture_handle_vocab, &gl_texture_handle_vocab)) |match| {
        @compileError(match.name ++ " must not use " ++ match.needle ++ " — keep texture handles behind gpu.Texture");
    }
    if (firstEntryNeedleMatch(&neutral_renderer_handle_vocab, &gl_renderer_handle_vocab)) |match| {
        @compileError(match.name ++ " must not use " ++ match.needle ++ " — keep renderer handles behind gpu.Texture/gpu.Framebuffer");
    }
    if (firstEntryNeedleMatch(&neutral_appwindow_diag_vocab, &appwindow_gl_diag_vocab)) |match| {
        @compileError(match.name ++ " must not use " ++ match.needle ++ " — route GPU diagnostics through backend-neutral gpu.state APIs");
    }
    if (firstEntryNeedleMatch(&neutral_c_alias_vocab, &gl_c_alias_vocab)) |match| {
        @compileError(match.name ++ " must not alias gpu.c — keep backend constants/types out of migrated renderer files");
    }
    if (firstEntryNeedleMatch(&neutral_runtime_state_vocab, &gl_init_runtime_vocab)) |match| {
        @compileError(match.name ++ " must not use " ++ match.needle ++ " — use gpu runtime state instead of gl_init");
    }
    if (firstEntryNeedleMatch(&neutral_ui_draw_vocab, &gl_init_render_vocab)) |match| {
        @compileError(match.name ++ " must not use " ++ match.needle ++ " — use ui_pipeline neutral draw helpers");
    }
    if (firstEntryNeedleMatch(&neutral_projection_vocab, &gl_init_projection_vocab)) |match| {
        @compileError(match.name ++ " must not use " ++ match.needle ++ " — use ui_pipeline.setProjection");
    }
    if (firstEntryNeedleMatch(&neutral_appwindow_gl_init_vocab, &appwindow_gl_init_vocab)) |match| {
        @compileError(match.name ++ " must not use " ++ match.needle ++ " — route AppWindow through backend-neutral gpu/ui/cell pipeline APIs");
    }
}

test "guard data is internally consistent (locked files are clean)" {
    try std.testing.expect(firstMatch(&glad_free, glad_include) == null);
    try std.testing.expect(firstMatch(&raw_gl_free, gl_table_call) == null);
    try std.testing.expect(firstMatch(&raw_gl_free, gl_context_bypass) == null);
    try std.testing.expect(firstEntryNeedleMatch(&neutral_buffer_vocab, &gl_buffer_vocab) == null);
    try std.testing.expect(firstEntryNeedleMatch(&neutral_topology_vocab, &gl_topology_vocab) == null);
    try std.testing.expect(firstEntryNeedleMatch(&neutral_texture_upload_vocab, &gl_texture_upload_vocab) == null);
    try std.testing.expect(firstEntryNeedleMatch(&neutral_texture_handle_vocab, &gl_texture_handle_vocab) == null);
    try std.testing.expect(firstEntryNeedleMatch(&neutral_renderer_handle_vocab, &gl_renderer_handle_vocab) == null);
    try std.testing.expect(firstEntryNeedleMatch(&neutral_appwindow_diag_vocab, &appwindow_gl_diag_vocab) == null);
    try std.testing.expect(firstEntryNeedleMatch(&neutral_c_alias_vocab, &gl_c_alias_vocab) == null);
    try std.testing.expect(firstEntryNeedleMatch(&neutral_runtime_state_vocab, &gl_init_runtime_vocab) == null);
    try std.testing.expect(firstEntryNeedleMatch(&neutral_ui_draw_vocab, &gl_init_render_vocab) == null);
    try std.testing.expect(firstEntryNeedleMatch(&neutral_projection_vocab, &gl_init_projection_vocab) == null);
    try std.testing.expect(firstEntryNeedleMatch(&neutral_appwindow_gl_init_vocab, &appwindow_gl_init_vocab) == null);
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
    try std.testing.expectEqualStrings("c.GL_ARRAY_BUFFER", firstNeedleMatch("Buffer.init(c.GL_ARRAY_BUFFER)", &gl_buffer_vocab).?);
    try std.testing.expectEqualStrings("c.GL_TRIANGLE_STRIP", firstNeedleMatch("draw(c.GL_TRIANGLE_STRIP)", &gl_topology_vocab).?);
    try std.testing.expect(firstNeedleMatch("draw(.triangle_strip)", &gl_topology_vocab) == null);
    const planted_buffer = [_]Entry{.{ .name = "cell_pipeline.zig", .source = "Buffer.init(c.GL_ARRAY_BUFFER)" }};
    const planted_topology = [_]Entry{.{ .name = "cell_renderer.zig", .source = "draw(c.GL_TRIANGLE_STRIP)" }};
    try std.testing.expectEqualStrings("cell_pipeline.zig", firstEntryNeedleMatch(&planted_buffer, &gl_buffer_vocab).?.name);
    try std.testing.expectEqualStrings("cell_renderer.zig", firstEntryNeedleMatch(&planted_topology, &gl_topology_vocab).?.name);
    const planted_texture = [_]Entry{.{ .name = "ui_pipeline.zig", .source = ".format = c.GL_RED" }};
    try std.testing.expectEqualStrings("ui_pipeline.zig", firstEntryNeedleMatch(&planted_texture, &gl_texture_upload_vocab).?.name);
    const planted_texture_handle = [_]Entry{.{ .name = "background_image.zig", .source = "threadlocal var g_texture: gpu.c.GLuint = 0" }};
    try std.testing.expectEqualStrings("background_image.zig", firstEntryNeedleMatch(&planted_texture_handle, &gl_texture_handle_vocab).?.name);
    const planted_preview_texture_handle = [_]Entry{.{ .name = "preview/pane.zig", .source = "image_texture: gpu.c.GLuint = 0" }};
    try std.testing.expectEqualStrings("preview/pane.zig", firstEntryNeedleMatch(&planted_preview_texture_handle, &gl_texture_handle_vocab).?.name);
    const planted_font_texture_handle = [_]Entry{.{ .name = "font/manager.zig", .source = "pub threadlocal var g_atlas_texture: c.GLuint = 0" }};
    try std.testing.expectEqualStrings("font/manager.zig", firstEntryNeedleMatch(&planted_font_texture_handle, &gl_texture_handle_vocab).?.name);
    const planted_renderer_handle = [_]Entry{.{ .name = "image_renderer.zig", .source = "var texture_handle: Renderer.GLuint = 0" }};
    try std.testing.expectEqualStrings("image_renderer.zig", firstEntryNeedleMatch(&planted_renderer_handle, &gl_renderer_handle_vocab).?.name);
    const planted_appwindow_diag = [_]Entry{.{ .name = "AppWindow.zig", .source = "glDiagString(gpu.c.GL_VENDOR)" }};
    try std.testing.expectEqualStrings("AppWindow.zig", firstEntryNeedleMatch(&planted_appwindow_diag, &appwindow_gl_diag_vocab).?.name);
    const planted_c_alias = [_]Entry{.{ .name = "Renderer.zig", .source = "const c = AppWindow.gpu.c;" }};
    try std.testing.expectEqualStrings("Renderer.zig", firstEntryNeedleMatch(&planted_c_alias, &gl_c_alias_vocab).?.name);
    const planted_runtime = [_]Entry{.{ .name = "cell_renderer.zig", .source = "gl_init.g_draw_call_count += 1" }};
    try std.testing.expectEqualStrings("cell_renderer.zig", firstEntryNeedleMatch(&planted_runtime, &gl_init_runtime_vocab).?.name);
    const planted_draw = [_]Entry{.{ .name = "primitives.zig", .source = "gl_init.renderQuadAlpha(x, y, w, h, color, alpha)" }};
    try std.testing.expectEqualStrings("primitives.zig", firstEntryNeedleMatch(&planted_draw, &gl_init_render_vocab).?.name);
    const planted_projection = [_]Entry{.{ .name = "AppWindow.zig", .source = "gpu.gl_init.setProjection(800, 600)" }};
    try std.testing.expectEqualStrings("AppWindow.zig", firstEntryNeedleMatch(&planted_projection, &gl_init_projection_vocab).?.name);
    const planted_appwindow_gl_init = [_]Entry{.{ .name = "AppWindow.zig", .source = "gpu.gl_init.initShaders()" }};
    try std.testing.expectEqualStrings("AppWindow.zig", firstEntryNeedleMatch(&planted_appwindow_gl_init, &appwindow_gl_init_vocab).?.name);
    const planted_ui_pipeline_gl_init = [_]Entry{.{ .name = "renderer/ui_pipeline.zig", .source = "AppWindow.gpu.gl_init.setBackendHooks(.{})" }};
    try std.testing.expectEqualStrings("renderer/ui_pipeline.zig", firstEntryNeedleMatch(&planted_ui_pipeline_gl_init, &appwindow_gl_init_vocab).?.name);
    const planted_split_layout_gl_init = [_]Entry{.{ .name = "appwindow/split_layout.zig", .source = "const gl_init = AppWindow.gpu.gl_init;" }};
    try std.testing.expectEqualStrings("appwindow/split_layout.zig", firstEntryNeedleMatch(&planted_split_layout_gl_init, &appwindow_gl_init_vocab).?.name);
}
