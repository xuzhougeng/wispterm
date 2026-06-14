//! Pure, std-only cell geometry: the GPU instance data types plus the
//! presentation-agnostic transforms used to build them (the BG/cursor/selection
//! decision and the glyph-rect math). No GL, no font, no AppWindow — runs in the
//! fast test suite. The impure glyph lookup (font.loadGlyph / font.glyphUV)
//! stays in cell_renderer.
const std = @import("std");

pub const MAX_GRAPHEME: usize = 8;

/// Background cell instance data for the GPU.
pub const CellBg = extern struct {
    grid_col: f32,
    grid_row: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

/// Foreground (glyph) cell instance data for the GPU.
pub const CellFg = extern struct {
    grid_col: f32,
    grid_row: f32,
    glyph_x: f32,
    glyph_y: f32,
    glyph_w: f32,
    glyph_h: f32,
    uv_left: f32,
    uv_top: f32,
    uv_right: f32,
    uv_bottom: f32,
    r: f32,
    g: f32,
    b: f32,
};

/// Snapshot of a single cell's state (copied from the terminal under lock).
pub const SnapCell = struct {
    codepoint: u21,
    fg: [3]f32,
    bg: ?[3]f32,
    wide: enum(u2) { narrow = 0, wide = 1, spacer_tail = 2, spacer_head = 3 } = .narrow,
    grapheme: [MAX_GRAPHEME]u21 = .{0} ** MAX_GRAPHEME,
    grapheme_len: u4 = 0,
};

pub const Rgb = [3]f32;

pub const ThemeColors = struct {
    background: Rgb,
    cursor_text: ?Rgb,
    selection_background: Rgb,
    selection_foreground: ?Rgb,
    foreground: Rgb,
};

/// The BG/cursor/selection decision extracted from cell_renderer.rebuildCells
/// (its cursor / selection / cell-bg branch). Returns the optional background
/// instance to emit and the resolved foreground.
///
/// `cursor_is_block` must already fold in both the cursor's presence and its
/// effective style — pass `(effective != null and effective.? == .block)`, so
/// it is false when the cursor is inactive or blinked-off. It only gates the fg
/// override; the background is emitted from `cell_bg` regardless of it.
pub fn backgroundFor(
    cell_bg: ?Rgb,
    is_cursor: bool,
    cursor_visible: bool,
    cursor_is_block: bool,
    is_selected: bool,
    theme: ThemeColors,
    grid_col: f32,
    grid_row: f32,
    normal_bg_alpha: f32,
    base_fg: Rgb,
) struct { bg: ?CellBg, fg: Rgb } {
    var fg = base_fg;
    var bg: ?CellBg = null;
    if (is_cursor and cursor_visible) {
        if (cursor_is_block) fg = theme.cursor_text orelse theme.background;
        if (cell_bg) |b| bg = .{ .grid_col = grid_col, .grid_row = grid_row, .r = b[0], .g = b[1], .b = b[2], .a = normal_bg_alpha };
    } else if (is_selected) {
        // Selected cells stay fully opaque (alpha 1.0) even when normal cell
        // backgrounds reveal a wallpaper underneath — matches Ghostty.
        bg = .{ .grid_col = grid_col, .grid_row = grid_row, .r = theme.selection_background[0], .g = theme.selection_background[1], .b = theme.selection_background[2], .a = 1.0 };
        fg = theme.selection_foreground orelse theme.foreground;
    } else if (cell_bg) |b| {
        bg = .{ .grid_col = grid_col, .grid_row = grid_row, .r = b[0], .g = b[1], .b = b[2], .a = normal_bg_alpha };
    }
    return .{ .bg = bg, .fg = fg };
}

pub const GlyphRect = struct { gx: f32, gy: f32, gw: f32, gh: f32 };

/// Grayscale glyph rect math, extracted from cell_renderer.rebuildCells.
pub fn grayscaleGlyphRect(bearing_x: i32, bearing_y: i32, size_x: i32, size_y: i32, cell_baseline: f32) GlyphRect {
    return .{
        .gx = @floatFromInt(bearing_x),
        .gy = cell_baseline - @as(f32, @floatFromInt(size_y - bearing_y)),
        .gw = @floatFromInt(size_x),
        .gh = @floatFromInt(size_y),
    };
}

/// Color-emoji aspect-fit + centering, extracted from cell_renderer.rebuildCells.
pub fn colorEmojiRect(size_x: i32, size_y: i32, grid_width: f32, cell_w: f32, cell_h: f32) GlyphRect {
    const emoji_w: f32 = @floatFromInt(size_x);
    const emoji_h: f32 = @floatFromInt(size_y);
    const target_w = cell_w * grid_width;
    const scale = @min(target_w / emoji_w, cell_h / emoji_h);
    const gw = emoji_w * scale;
    const gh = emoji_h * scale;
    return .{ .gx = (target_w - gw) / 2.0, .gy = (cell_h - gh) / 2.0, .gw = gw, .gh = gh };
}

test "backgroundFor: plain cell emits bg at grid coords, fg unchanged" {
    const theme = ThemeColors{ .background = .{ 0, 0, 0 }, .cursor_text = null, .selection_background = .{ 0.2, 0.2, 0.2 }, .selection_foreground = null, .foreground = .{ 1, 1, 1 } };
    const r = backgroundFor(.{ 0.1, 0.2, 0.3 }, false, false, false, false, theme, 3, 4, 0.5, .{ 0.9, 0.8, 0.7 });
    try std.testing.expect(r.bg != null);
    try std.testing.expectEqual(@as(f32, 3), r.bg.?.grid_col);
    try std.testing.expectEqual(@as(f32, 4), r.bg.?.grid_row);
    try std.testing.expectEqual(@as(f32, 0.5), r.bg.?.a);
    try std.testing.expectEqual(@as(f32, 0.1), r.bg.?.r);
    try std.testing.expectEqual([3]f32{ 0.9, 0.8, 0.7 }, r.fg);
}

test "backgroundFor: no bg color and not cursor/selected emits nothing" {
    const theme = ThemeColors{ .background = .{ 0, 0, 0 }, .cursor_text = null, .selection_background = .{ 0.2, 0.2, 0.2 }, .selection_foreground = null, .foreground = .{ 1, 1, 1 } };
    const r = backgroundFor(null, false, false, false, false, theme, 0, 0, 1.0, .{ 1, 1, 1 });
    try std.testing.expect(r.bg == null);
    try std.testing.expectEqual([3]f32{ 1, 1, 1 }, r.fg);
}

test "backgroundFor: selected cell uses opaque selection bg and selection fg" {
    const theme = ThemeColors{ .background = .{ 0, 0, 0 }, .cursor_text = null, .selection_background = .{ 0.2, 0.3, 0.4 }, .selection_foreground = .{ 0.5, 0.6, 0.7 }, .foreground = .{ 1, 1, 1 } };
    const r = backgroundFor(.{ 0.1, 0.1, 0.1 }, false, false, false, true, theme, 1, 2, 0.3, .{ 0.9, 0.9, 0.9 });
    try std.testing.expect(r.bg != null);
    try std.testing.expectEqual(@as(f32, 1.0), r.bg.?.a);
    try std.testing.expectEqual(@as(f32, 0.2), r.bg.?.r);
    try std.testing.expectEqual([3]f32{ 0.5, 0.6, 0.7 }, r.fg);
}

test "backgroundFor: block cursor overrides fg to cursor_text" {
    const theme = ThemeColors{ .background = .{ 0, 0, 0 }, .cursor_text = .{ 0.1, 0.1, 0.1 }, .selection_background = .{ 0.2, 0.2, 0.2 }, .selection_foreground = null, .foreground = .{ 1, 1, 1 } };
    const r = backgroundFor(.{ 0.4, 0.4, 0.4 }, true, true, true, false, theme, 0, 0, 1.0, .{ 0.9, 0.9, 0.9 });
    try std.testing.expectEqual([3]f32{ 0.1, 0.1, 0.1 }, r.fg);
    try std.testing.expect(r.bg != null);
    try std.testing.expectEqual(@as(f32, 0.4), r.bg.?.r);
}

test "grayscaleGlyphRect: baseline/bearing math" {
    const r = grayscaleGlyphRect(2, 10, 6, 12, 16.0);
    try std.testing.expectEqual(@as(f32, 2), r.gx);
    try std.testing.expectEqual(@as(f32, 14.0), r.gy);
    try std.testing.expectEqual(@as(f32, 6), r.gw);
    try std.testing.expectEqual(@as(f32, 12), r.gh);
}

test "colorEmojiRect: aspect-fit and centering for a narrow cell" {
    const r = colorEmojiRect(20, 10, 1.0, 10.0, 16.0);
    try std.testing.expectEqual(@as(f32, 10), r.gw);
    try std.testing.expectEqual(@as(f32, 5), r.gh);
    try std.testing.expectEqual(@as(f32, 0), r.gx);
    try std.testing.expectEqual(@as(f32, 5.5), r.gy);
}

test "backgroundFor: bar cursor (non-block) leaves fg unchanged, still emits cell bg" {
    const theme = ThemeColors{ .background = .{ 0, 0, 0 }, .cursor_text = .{ 0.1, 0.1, 0.1 }, .selection_background = .{ 0.2, 0.2, 0.2 }, .selection_foreground = null, .foreground = .{ 1, 1, 1 } };
    const r = backgroundFor(.{ 0.3, 0.3, 0.3 }, true, true, false, false, theme, 0, 0, 0.8, .{ 0.9, 0.9, 0.9 });
    try std.testing.expectEqual([3]f32{ 0.9, 0.9, 0.9 }, r.fg); // not block → fg unchanged
    try std.testing.expect(r.bg != null);
    try std.testing.expectEqual(@as(f32, 0.3), r.bg.?.r);
    try std.testing.expectEqual(@as(f32, 0.8), r.bg.?.a);
}

test "backgroundFor: block cursor with null cursor_text falls back to background" {
    const theme = ThemeColors{ .background = .{ 0.05, 0.05, 0.05 }, .cursor_text = null, .selection_background = .{ 0.2, 0.2, 0.2 }, .selection_foreground = null, .foreground = .{ 1, 1, 1 } };
    const r = backgroundFor(null, true, true, true, false, theme, 0, 0, 1.0, .{ 0.9, 0.9, 0.9 });
    try std.testing.expectEqual([3]f32{ 0.05, 0.05, 0.05 }, r.fg); // cursor_text orelse background
    try std.testing.expect(r.bg == null); // no cell bg present
}

test "backgroundFor: selected cell with null selection_foreground falls back to foreground" {
    const theme = ThemeColors{ .background = .{ 0, 0, 0 }, .cursor_text = null, .selection_background = .{ 0.2, 0.3, 0.4 }, .selection_foreground = null, .foreground = .{ 0.8, 0.8, 0.8 } };
    const r = backgroundFor(.{ 0.1, 0.1, 0.1 }, false, false, false, true, theme, 0, 0, 1.0, .{ 0.9, 0.9, 0.9 });
    try std.testing.expectEqual([3]f32{ 0.8, 0.8, 0.8 }, r.fg); // selection_foreground orelse foreground
    try std.testing.expect(r.bg != null);
}

// ============================================================================
// GPU instance-buffer upload gating
// ============================================================================

/// Whether drawCells must re-upload its CPU cell buffers to the shared GPU
/// instance buffers. The buffers are global (one set for all surfaces), so a
/// renderer's upload survives only until another renderer draws; a renderer
/// also re-uploads after each rebuild (its CPU buffers changed). `uploader` /
/// `current` are opaque renderer identities (pointer compare only).
pub fn needsBufferUpload(
    last_uploader: ?*const anyopaque,
    uploaded_generation: u64,
    current: *const anyopaque,
    current_generation: u64,
) bool {
    if (last_uploader != current) return true;
    return uploaded_generation != current_generation;
}

/// Whether a renderer's cached cell buffers must be rebuilt because a font
/// atlas was resized since the last rebuild. Glyph UVs are normalized against
/// the atlas size at build time (cell_renderer.rebuildCells), so when the
/// shared atlas grows — possibly triggered by ANOTHER surface's glyph loads —
/// every cached UV points into the wrong place in the resized texture, garbling
/// the whole pane until the cells are rebuilt at the new size. updateTerminalCells
/// calls this so a grow forces a rebuild even when the terminal content is static.
/// `last_*` are the sizes the cells were last built against (0 before any build).
pub fn needsRebuildAfterAtlasResize(
    last_atlas_size: u32,
    last_color_atlas_size: u32,
    cur_atlas_size: u32,
    cur_color_atlas_size: u32,
) bool {
    return last_atlas_size != cur_atlas_size or
        last_color_atlas_size != cur_color_atlas_size;
}

test "needsBufferUpload: 同 renderer 同代可跳过，重建或换 renderer 必须重传" {
    var a: u8 = 0;
    var b: u8 = 0;
    // 同 renderer、同一次 rebuild 的产物仍在 GPU 缓冲里 → 跳过
    try std.testing.expect(!needsBufferUpload(&a, 7, &a, 7));
    // rebuild 之后（代数变了）→ 重传
    try std.testing.expect(needsBufferUpload(&a, 7, &a, 8));
    // 共享缓冲被另一个 renderer 覆盖过 → 重传
    try std.testing.expect(needsBufferUpload(&b, 7, &a, 7));
    // 首帧（从未上传过）→ 重传
    try std.testing.expect(needsBufferUpload(null, 0, &a, 0));
}

test "needsRebuildAfterAtlasResize: atlas 扩容会让缓存的 cell UV 失效，必须重建" {
    // 字形 UV 在 rebuildCells 里按当时的 atlas 尺寸归一化烘焙进 cell 缓冲。
    // 共享 atlas 一旦扩容（可能由另一个 surface 的字形加载触发），纹理被放大，
    // 而本 surface 缓存的 UV 仍按旧尺寸归一化 → 整屏字形错位花屏，直到重建。

    // 尺寸都没变 → 缓存的 UV 仍然有效，可以跳过重建。
    try std.testing.expect(!needsRebuildAfterAtlasResize(512, 512, 512, 512));

    // 灰度 atlas 扩容 512→1024 → 旧 UV 失效，必须重建。
    try std.testing.expect(needsRebuildAfterAtlasResize(512, 512, 1024, 512));

    // 彩色 emoji atlas 扩容 → 同样必须重建。
    try std.testing.expect(needsRebuildAfterAtlasResize(512, 512, 512, 1024));

    // 两个 atlas 同时扩容 → 必须重建。
    try std.testing.expect(needsRebuildAfterAtlasResize(512, 512, 1024, 1024));

    // 首次 rebuild（renderer 还没记录过任何尺寸，last=0）→ 必须构建。
    try std.testing.expect(needsRebuildAfterAtlasResize(0, 0, 512, 512));
}
