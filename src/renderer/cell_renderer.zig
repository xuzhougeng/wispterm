//! Cell rendering pipeline for AppWindow.
//!
//! Owns the snapshot→rebuild→draw pipeline: reads terminal state under lock,
//! builds GPU cell buffers, and draws them. Also provides renderChar for
//! immediate-mode text rendering (UI overlays, placeholder text).
//! Uses shared rendering primitives owned by the active GPU backend.

const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const Surface = @import("../Surface.zig");
const Renderer = @import("Renderer.zig");
const AppWindow = @import("../AppWindow.zig");
const font = AppWindow.font;
const tab = AppWindow.tab;
const gpu = AppWindow.gpu;
const ui_pipeline = @import("ui_pipeline.zig");
const cell_pipeline = @import("cell_pipeline.zig");
const underline_span = @import("../input/underline_span.zig");
const image_renderer = @import("image_renderer.zig");
const cell_geometry = @import("cell_geometry.zig");

const Character = font.Character;
const Selection = Surface.Selection;

// ============================================================================
// State
// ============================================================================

/// Current surface being rendered (for per-surface selection)
pub threadlocal var g_current_render_surface: ?*Surface = null;

// ============================================================================
// Public API
// ============================================================================

/// Render a single character at the given position using the text shader.
/// Used for UI text (placeholder messages, overlays), not terminal cells.
pub fn renderChar(codepoint: u32, x: f32, y: f32, color: [3]f32) void {
    // Skip control characters
    if (codepoint < 32) return;

    // Get character from cache (load on-demand if needed)
    const ch: Character = font.loadGlyph(codepoint) orelse return;
    if (ch.region.width == 0 or ch.region.height == 0) return;

    // Position glyph relative to baseline (like Ghostty)
    const x0 = x + @as(f32, @floatFromInt(ch.bearing_x));
    const y0 = y + font.cell_baseline - @as(f32, @floatFromInt(ch.size_y - ch.bearing_y));
    const w = @as(f32, @floatFromInt(ch.size_x));
    const h = @as(f32, @floatFromInt(ch.size_y));

    // Compute atlas UVs from region
    const atlas_size = if (font.g_atlas) |a| @as(f32, @floatFromInt(a.size)) else 512.0;
    const uv = font.glyphUV(ch.region, atlas_size);

    ui_pipeline.drawGlyph(
        .{ .x = x0, .y = y0, .w = w, .h = h },
        .{ .u0 = uv.u0, .v0 = uv.v0, .u1 = uv.u1, .v1 = uv.v1 },
        font.g_atlas_texture,
        color,
    );
}

/// Update terminal cells for a specific surface in a split tree.
/// is_focused controls cursor appearance (unfocused shows block_hollow).
/// A focus transition forces a rebuild: the cursor cell's background color is
/// baked into the bg buffer and depends on the effective style (block/hollow).
pub fn updateTerminalCellsForSurface(rend: *Renderer, terminal: *ghostty_vt.Terminal, is_focused: bool) bool {
    if (rend.is_focused != is_focused) rend.force_rebuild = true;
    rend.is_focused = is_focused;
    return updateTerminalCells(rend, terminal);
}

/// Get the selection for the current surface being rendered.
/// Returns the focused surface's selection if no surface is set.
pub fn currentRenderSelection() *Selection {
    if (g_current_render_surface) |surface| {
        return &surface.selection;
    }
    return tab.activeSelection();
}

/// Read terminal state under the lock: dirty check, snapshot cells, cache cursor.
/// Returns true if cells need rebuilding (caller should call rebuildCells()
/// after releasing the lock). Modeled after Ghostty's split:
///   lock → RenderState.update() (snapshot) → unlock → rebuildCells()
pub fn updateTerminalCells(rend: *Renderer, terminal: *ghostty_vt.Terminal) bool {
    // If the application has enabled synchronized output (Mode 2026),
    // skip rendering entirely until the batch ends. This prevents
    // mid-update artifacts (e.g. fzf drawing its UI). Matches Ghostty's
    // renderer/generic.zig which returns early when synchronized_output is set.
    if (terminal.modes.get(.synchronized_output)) return false;

    const screen = terminal.screens.active;
    const viewport_active = screen.pages.viewport == .active;
    const selection_active = currentRenderSelection().active;
    const viewport_pin = screen.pages.getTopLeft(.viewport);
    rend.cached_viewport_offset = AppWindow.input.viewportOffsetForSurfaceLocked(rend.surface);
    const terminal_cursor_visible = terminal.modes.get(.cursor_visible);
    const terminal_cursor_blinking = terminal.modes.get(.cursor_blinking);
    const terminal_cursor_style: Renderer.CursorStyle = switch (screen.cursor.cursor_style) {
        .bar => .bar,
        .block => .block,
        .underline => .underline,
        .block_hollow => .block_hollow,
    };
    // Atlas sizes glyph UVs will be normalized against this pass (mirrors the
    // `else 512.0` fallback rebuildCells uses when an atlas is not yet created).
    const cur_atlas_size: u32 = if (font.g_atlas) |a| a.size else 512;
    const cur_color_atlas_size: u32 = if (font.g_color_atlas) |a| a.size else 512;

    const needs_rebuild = blk: {
        if (rend.force_rebuild) {
            rend.force_rebuild = false;
            break :blk true;
        }
        if (!rend.cells_valid) break :blk true;
        // A shared font atlas can grow mid-frame (during this or another
        // surface's glyph loads), resizing the GPU texture. Cell UVs were baked
        // against the old atlas size, so without a rebuild every glyph samples
        // the wrong place and the whole pane garbles until unrelated activity
        // happens to trigger a rebuild. Tie rebuild to atlas size directly.
        if (cell_geometry.needsRebuildAfterAtlasResize(
            rend.last_atlas_size,
            rend.last_color_atlas_size,
            cur_atlas_size,
            cur_color_atlas_size,
        )) break :blk true;
        if (rend.cursor_blink_visible != rend.last_cursor_blink_visible) break :blk true;
        if (viewport_active != rend.last_viewport_active) break :blk true;
        if (terminal.rows != rend.last_rows or terminal.cols != rend.last_cols) break :blk true;
        if (selection_active != rend.last_selection_active) break :blk true;
        if (screen.kitty_images.dirty != rend.last_kitty_dirty) break :blk true;
        if (AppWindow.input.g_selecting) break :blk true;
        // Cursor position changed — need to rebuild so cursor bg is at the right cell
        if (screen.cursor.x != rend.last_cursor_x or
            screen.cursor.y != rend.last_cursor_y or
            @as(?*anyopaque, screen.cursor.page_pin.node) != rend.last_cursor_node or
            screen.cursor.page_pin.y != rend.last_cursor_pin_y) break :blk true;
        if (terminal_cursor_visible != rend.last_cursor_visible) break :blk true;
        if (terminal_cursor_blinking != rend.last_cursor_blinking) break :blk true;
        if (terminal_cursor_style != rend.last_cursor_style) break :blk true;
        // Viewport pin changed — scroll happened (matches Ghostty's RenderState viewport_pin comparison)
        if (@as(?*anyopaque, viewport_pin.node) != rend.last_viewport_node or
            viewport_pin.y != rend.last_viewport_y) break :blk true;
        // Terminal-level dirty flags (eraseDisplay, fullReset, palette change, etc.)
        {
            const DirtyInt = @typeInfo(@TypeOf(terminal.flags.dirty)).@"struct".backing_integer.?;
            if (@as(DirtyInt, @bitCast(terminal.flags.dirty)) > 0) break :blk true;
        }
        // Screen-level dirty flags (selection, hyperlink hover)
        {
            const ScreenDirtyInt = @typeInfo(@TypeOf(screen.dirty)).@"struct".backing_integer.?;
            if (@as(ScreenDirtyInt, @bitCast(screen.dirty)) > 0) break :blk true;
        }
        // Per-row/page dirty flags (set by VT parser on cell changes)
        var dirty_it = screen.pages.rowIterator(.right_down, .{ .viewport = .{} }, null);
        while (dirty_it.next()) |row_pin| {
            const rac = row_pin.rowAndCell();
            if (rac.row.dirty or row_pin.node.data.dirty) break :blk true;
        }
        break :blk false;
    };

    // Always cache cursor state for drawing outside the lock.
    rend.cached_cursor_x = screen.cursor.x;
    rend.cached_cursor_y = screen.cursor.y;
    rend.cached_cursor_in_viewport = false;

    // Match Ghostty: locate the cursor by page pin within the visible viewport.
    var cursor_row_it = screen.pages.rowIterator(.right_down, .{ .viewport = .{} }, null);
    var cursor_row_idx: usize = 0;
    while (cursor_row_it.next()) |row_pin| : (cursor_row_idx += 1) {
        if (@as(?*anyopaque, row_pin.node) == @as(?*anyopaque, screen.cursor.page_pin.node) and
            row_pin.y == screen.cursor.page_pin.y)
        {
            rend.cached_cursor_y = cursor_row_idx;
            rend.cached_cursor_in_viewport = true;
            break;
        }
    }

    rend.cached_cursor_visible = terminal_cursor_visible;
    rend.cached_cursor_effective = cursorEffectiveStyleForRenderer(rend, terminal_cursor_style, terminal_cursor_blinking);
    if (rend.cached_cursor_effective) |eff| {
        rend.cached_cursor_style = eff;
    }

    if (needs_rebuild) {
        // Snapshot cell data under the lock — fast memcpy of resolved colors
        // and codepoints. Like Ghostty's RenderState.update() fastmem.copy.
        snapshotCells(rend, terminal);
        image_renderer.snapshot(rend, terminal);

        // Debug: check for cursor/content mismatch
        if (rend.cached_cursor_in_viewport and rend.cached_cursor_y >= rend.snap_rows and rend.snap_rows > 0) {
            std.log.warn("CURSOR MISMATCH: cursor_y={} snap_rows={} terminal.rows={} viewport={s}", .{
                rend.cached_cursor_y,
                rend.snap_rows,
                terminal.rows,
                if (screen.pages.viewport == .active) "active" else "pin",
            });
        }

        rend.cells_valid = true;
        rend.last_cursor_blink_visible = rend.cursor_blink_visible;
        rend.last_viewport_active = viewport_active;
        rend.last_viewport_node = viewport_pin.node;
        rend.last_viewport_y = viewport_pin.y;
        rend.last_cursor_node = screen.cursor.page_pin.node;
        rend.last_cursor_pin_y = screen.cursor.page_pin.y;
        rend.last_cursor_x = screen.cursor.x;
        rend.last_cursor_y = screen.cursor.y;
        rend.last_cursor_visible = terminal_cursor_visible;
        rend.last_cursor_blinking = terminal_cursor_blinking;
        rend.last_cursor_style = terminal_cursor_style;
        rend.last_rows = terminal.rows;
        rend.last_cols = terminal.cols;
        rend.last_selection_active = selection_active;
        rend.last_kitty_dirty = screen.kitty_images.dirty;
        // Record the atlas sizes the upcoming rebuildCells will normalize UVs
        // against. If an atlas grows during that rebuild (loadGlyph), the next
        // updateTerminalCells sees cur != last and rebuilds at the new size.
        rend.last_atlas_size = cur_atlas_size;
        rend.last_color_atlas_size = cur_color_atlas_size;

        // Clear dirty flags after snapshot
        terminal.flags.dirty = .{};
        screen.dirty = .{};
        var clear_it = screen.pages.rowIterator(.right_down, .{ .viewport = .{} }, null);
        while (clear_it.next()) |row_pin| {
            row_pin.rowAndCell().row.dirty = false;
        }
    }

    return needs_rebuild;
}

/// Build GPU cell buffers from the snapshot. Does NOT require the terminal
/// mutex — reads from rend.snap which was filled by snapshotCells.
pub fn rebuildCells(rend: *Renderer) void {
    rend.rebuild_generation +%= 1;
    const render_rows = rend.snap_rows;
    const render_cols = rend.snap_cols;
    const atlas_size = if (font.g_atlas) |a| @as(f32, @floatFromInt(a.size)) else 512.0;
    const color_atlas_size = if (font.g_color_atlas) |a| @as(f32, @floatFromInt(a.size)) else 512.0;
    const g_theme = AppWindow.g_theme;

    rend.bg_cell_count = 0;
    rend.fg_cell_count = 0;
    rend.color_fg_cell_count = 0;
    image_renderer.uploadPending(rend);
    const normal_bg_alpha: f32 = if (AppWindow.background_image.g_enabled) gpu.background_opacity else 1.0;

    for (0..render_rows) |row_idx| {
        const row_f: f32 = @floatFromInt(row_idx);
        const row_base = row_idx * render_cols;

        var skip_next_ri = false;
        for (0..render_cols) |col_idx| {
            const snap_idx = row_base + col_idx;
            if (snap_idx >= rend.snap.items.len) break;
            const sc = rend.snap.items[snap_idx];

            const is_cursor = rend.cached_cursor_in_viewport and (col_idx == rend.cached_cursor_x and row_idx == rend.cached_cursor_y);
            const is_selected = isCellSelected(rend, col_idx, row_idx);
            const col_f: f32 = @floatFromInt(col_idx);

            const cursor_is_block = if (rend.cached_cursor_effective) |s| s == .block else false;
            const decision = cell_geometry.backgroundFor(
                sc.bg,
                is_cursor,
                rend.cached_cursor_visible,
                cursor_is_block,
                is_selected,
                .{
                    .background = g_theme.background,
                    .cursor_text = g_theme.cursor_text,
                    .selection_background = g_theme.selection_background,
                    .selection_foreground = g_theme.selection_foreground,
                    .foreground = g_theme.foreground,
                },
                col_f,
                row_f,
                normal_bg_alpha,
                sc.fg,
            );
            if (decision.bg) |bg_inst| {
                if (rend.bg_cell_count < rend.bg_cells.items.len) {
                    rend.bg_cells.items[rend.bg_cell_count] = bg_inst;
                    rend.bg_cell_count += 1;
                }
            }
            const fg_color = decision.fg;

            // Skip spacer cells — the wide character's head cell handles rendering
            // across both cells (like Ghostty).
            if (sc.wide == .spacer_tail or sc.wide == .spacer_head) continue;

            // Skip the second regional indicator in a composed pair
            if (skip_next_ri) {
                skip_next_ri = false;
                continue;
            }

            const char = sc.codepoint;
            if (char == ghostty_vt.kitty.graphics.unicode.placeholder) continue;
            if (char != 0 and char != ' ') {
                // Track if we composed a regional indicator pair (for 2-cell width)
                var composed_ri_pair = false;

                // Use HarfBuzz shaping for grapheme clusters (multi-codepoint emoji),
                // fall back to single-codepoint lookup for regular characters.
                const maybe_ch: ?Character = if (sc.grapheme_len > 0)
                    font.loadGraphemeGlyph(char, sc.grapheme[0..sc.grapheme_len])
                else if (font.isRegionalIndicator(char)) ri: {
                    // Regional indicator without grapheme data — check if a following cell
                    // is also an RI and compose them into a flag pair for shaping.
                    // This handles the case where grapheme_cluster mode isn't active.
                    // Check +1 (narrow RI) and +2 (wide RI with spacer_tail at +1).
                    const offsets = [_]usize{ 1, 2 };
                    for (offsets) |off| {
                        const next_snap_idx = row_base + col_idx + off;
                        if (next_snap_idx < rend.snap.items.len and col_idx + off < render_cols) {
                            const next_sc = rend.snap.items[next_snap_idx];
                            if (font.isRegionalIndicator(next_sc.codepoint)) {
                                const extras = [1]u21{next_sc.codepoint};
                                const result = font.loadGraphemeGlyph(char, &extras);
                                if (result != null) {
                                    composed_ri_pair = true;
                                    skip_next_ri = true;
                                }
                                break :ri result;
                            }
                        }
                    }
                    break :ri font.loadGlyph(char);
                } else font.loadGlyph(char);
                if (maybe_ch) |ch| {
                    if (ch.region.width > 0 and ch.region.height > 0) {
                        // Wide characters (emoji) span 2 cells; narrow = 1 cell.
                        // Composed RI pairs also span 2 cells.
                        const grid_width: f32 = if (sc.wide == .wide or composed_ri_pair) 2.0 else 1.0;
                        if (ch.is_color) {
                            // Color emoji — route to separate color cell buffer.
                            // Scale the emoji bitmap to fit within grid_width cells, preserving aspect ratio.
                            const rect = cell_geometry.colorEmojiRect(ch.size_x, ch.size_y, grid_width, font.cell_width, font.cell_height);
                            const gx = rect.gx;
                            const gy = rect.gy;
                            const gw = rect.gw;
                            const gh = rect.gh;
                            const uv_val = font.glyphUV(ch.region, color_atlas_size);
                            if (rend.color_fg_cell_count < rend.color_fg_cells.items.len) {
                                rend.color_fg_cells.items[rend.color_fg_cell_count] = .{
                                    .grid_col = col_f,
                                    .grid_row = row_f,
                                    .glyph_x = gx,
                                    .glyph_y = gy,
                                    .glyph_w = gw,
                                    .glyph_h = gh,
                                    .uv_left = uv_val.u0,
                                    .uv_top = uv_val.v0,
                                    .uv_right = uv_val.u1,
                                    .uv_bottom = uv_val.v1,
                                    .r = fg_color[0],
                                    .g = fg_color[1],
                                    .b = fg_color[2],
                                };
                                rend.color_fg_cell_count += 1;
                            }
                        } else {
                            // Grayscale text glyph
                            const uv_val = font.glyphUV(ch.region, atlas_size);
                            const rect = cell_geometry.grayscaleGlyphRect(ch.bearing_x, ch.bearing_y, ch.size_x, ch.size_y, font.cell_baseline);
                            const gx = rect.gx;
                            const gy = rect.gy;
                            const gw = rect.gw;
                            const gh = rect.gh;
                            if (rend.fg_cell_count < rend.fg_cells.items.len) {
                                rend.fg_cells.items[rend.fg_cell_count] = .{
                                    .grid_col = col_f,
                                    .grid_row = row_f,
                                    .glyph_x = gx,
                                    .glyph_y = gy,
                                    .glyph_w = gw,
                                    .glyph_h = gh,
                                    .uv_left = uv_val.u0,
                                    .uv_top = uv_val.v0,
                                    .uv_right = uv_val.u1,
                                    .uv_bottom = uv_val.v1,
                                    .r = fg_color[0],
                                    .g = fg_color[1],
                                    .b = fg_color[2],
                                };
                                rend.fg_cell_count += 1;
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Draw terminal grid from CPU cell buffers. Does NOT require the terminal
/// mutex — all terminal state was already read by updateTerminalCells().
pub fn drawCells(rend: *const Renderer, window_height: f32, offset_x: f32, offset_y: f32) void {
    const g_theme = AppWindow.g_theme;

    // The shared instance buffers already hold this renderer's current cells
    // unless it rebuilt since, or another renderer drew in between.
    const need_upload = cell_geometry.needsBufferUpload(
        cell_pipeline.g_last_uploader,
        cell_pipeline.g_uploaded_generation,
        rend,
        rend.rebuild_generation,
    );

    image_renderer.draw(rend, window_height, offset_x, offset_y, .below_bg);

    // --- Draw BG cells ---
    if (rend.bg_cell_count > 0 and cell_pipeline.bg.program != 0) {
        const p = cell_pipeline.bg;
        p.use();
        p.setVec2("cellSize", font.cell_width, font.cell_height);
        p.setVec2("gridOffset", offset_x, offset_y);
        p.setFloat("windowHeight", window_height);
        p.setProjection();
        p.bindVao();
        if (need_upload) cell_pipeline.bg_instances.upload(std.mem.sliceAsBytes(rend.bg_cells.items[0..rend.bg_cell_count]));
        p.drawArraysInstanced(.triangle_strip, 0, 4, @intCast(rend.bg_cell_count));
        gpu.draw_call_count += 1;
    }

    image_renderer.draw(rend, window_height, offset_x, offset_y, .below_text);

    // --- Draw FG cells ---
    if (rend.fg_cell_count > 0 and cell_pipeline.fg.program != 0) {
        const p = cell_pipeline.fg;
        p.use();
        p.setVec2("cellSize", font.cell_width, font.cell_height);
        p.setVec2("gridOffset", offset_x, offset_y);
        p.setFloat("windowHeight", window_height);
        p.setProjection();
        font.g_atlas_texture.bind(0);
        p.setInt("atlas", 0);
        p.bindVao();
        if (need_upload) cell_pipeline.fg_instances.upload(std.mem.sliceAsBytes(rend.fg_cells.items[0..rend.fg_cell_count]));
        p.drawArraysInstanced(.triangle_strip, 0, 4, @intCast(rend.fg_cell_count));
        gpu.draw_call_count += 1;
    }

    // --- Draw color emoji cells (premultiplied alpha blend) ---
    if (rend.color_fg_cell_count > 0 and cell_pipeline.color_fg.program != 0) {
        // Color emoji bitmaps are premultiplied-alpha, so use (ONE, 1-SRC_ALPHA).
        gpu.state.setBlendMode(.premultiplied);
        const p = cell_pipeline.color_fg;
        p.use();
        p.setVec2("cellSize", font.cell_width, font.cell_height);
        p.setVec2("gridOffset", offset_x, offset_y);
        p.setFloat("windowHeight", window_height);
        p.setProjection();
        font.g_color_atlas_texture.bind(0);
        p.setInt("atlas", 0);
        p.bindVao();
        if (need_upload) cell_pipeline.color_fg_instances.upload(std.mem.sliceAsBytes(rend.color_fg_cells.items[0..rend.color_fg_cell_count]));
        p.drawArraysInstanced(.triangle_strip, 0, 4, @intCast(rend.color_fg_cell_count));
        gpu.draw_call_count += 1;
        // Restore standard blend for the cursor/titlebar draws that follow.
        gpu.state.setBlendMode(.alpha);
    }

    cell_pipeline.g_last_uploader = rend;
    cell_pipeline.g_uploaded_generation = rend.rebuild_generation;

    image_renderer.draw(rend, window_height, offset_x, offset_y, .above_text);
    drawUrlUnderline(rend, window_height, offset_x, offset_y);

    // --- Cursor overlay from cached state ---
    if (rend.cached_cursor_in_viewport and rend.cached_cursor_visible) {
        // Use the pre-computed effective cursor style which already factors in
        // window focus, tab rename, split focus, and blink state.
        if (rend.cached_cursor_effective) |style| {
            const px = offset_x + @as(f32, @floatFromInt(rend.cached_cursor_x)) * font.cell_width;
            const py = window_height - offset_y - ((@as(f32, @floatFromInt(rend.cached_cursor_y)) + 1) * font.cell_height);

            const cursor_color = g_theme.cursor_color;
            const cursor_thickness: f32 = @max(2.0, @as(f32, @floatFromInt(font.box_thickness)));

            switch (style) {
                .bar => ui_pipeline.fillQuad(px, py, cursor_thickness, font.cell_height, cursor_color),
                .underline => ui_pipeline.fillQuad(px, py, font.cell_width, cursor_thickness, cursor_color),
                .block_hollow => {
                    ui_pipeline.fillQuad(px, py, font.cell_width, font.cell_height, cursor_color);
                    ui_pipeline.fillQuad(
                        px + cursor_thickness,
                        py + cursor_thickness,
                        font.cell_width - cursor_thickness * 2,
                        font.cell_height - cursor_thickness * 2,
                        g_theme.background,
                    );
                },
                .block => ui_pipeline.fillQuad(px, py, font.cell_width, font.cell_height, cursor_color),
            }
        }
    }
}

fn drawUrlUnderline(rend: *const Renderer, window_height: f32, offset_x: f32, offset_y: f32) void {
    // One range fetch per frame; per-row spans are pure O(1) math against the
    // snapshot-cached viewport offset (no per-cell surface locking).
    const range = AppWindow.input.urlUnderlineRangeForSurface(rend.surface) orelse return;
    const thickness: f32 = @max(1.0, @as(f32, @floatFromInt(font.box_thickness)));
    const underline_y_offset: f32 = @max(2.0, thickness);
    const color = AppWindow.g_theme.cursor_color;

    for (0..rend.snap_rows) |row| {
        const span = underline_span.colSpanForRow(range, rend.cached_viewport_offset + row, rend.snap_cols) orelse continue;
        const x = offset_x + @as(f32, @floatFromInt(span.start_col)) * font.cell_width;
        const y = window_height - offset_y - ((@as(f32, @floatFromInt(row)) + 1) * font.cell_height) + underline_y_offset;
        const width = @as(f32, @floatFromInt(span.end_col - span.start_col + 1)) * font.cell_width;
        ui_pipeline.fillQuad(x, y, width, thickness, color);
    }
}

/// Check if a cell is within the current selection.
/// `col` and `row` are screen-relative (viewport) coordinates.
/// Selection rows are stored as absolute scrollback positions.
pub fn isCellSelected(rend: *const Renderer, col: usize, row: usize) bool {
    const selection = currentRenderSelection();
    if (!selection.active) return false;

    const abs_row = rend.cached_viewport_offset + row;

    var start_row = selection.start_row;
    var start_col = selection.start_col;
    var end_row = selection.end_row;
    var end_col = selection.end_col;

    // Normalize
    if (start_row > end_row or (start_row == end_row and start_col > end_col)) {
        std.mem.swap(usize, &start_row, &end_row);
        std.mem.swap(usize, &start_col, &end_col);
    }

    if (abs_row < start_row or abs_row > end_row) return false;
    if (abs_row == start_row and abs_row == end_row) {
        return col >= start_col and col <= end_col;
    }
    if (abs_row == start_row) return col >= start_col;
    if (abs_row == end_row) return col <= end_col;
    return true;
}

// ============================================================================
// Internal helpers
// ============================================================================

/// Determine effective cursor style (factoring in blink, focus, and split focus).
/// Returns null during blink-off phase (cursor hidden).
/// This version uses per-surface renderer state.
fn cursorEffectiveStyleForRenderer(rend: *const Renderer, terminal_style: Renderer.CursorStyle, terminal_blink: bool) ?Renderer.CursorStyle {
    // Hide cursor during active resize to avoid flicker artifacts
    if (AppWindow.overlays.resize.g_resize_active) return null;
    // Unfocused window or tab rename: show hollow block
    if (!AppWindow.window_focused or tab.g_tab_rename_active) return .block_hollow;
    // Unfocused split: show hollow block (no blinking)
    if (!rend.is_focused) return .block_hollow;
    const should_blink = terminal_blink and AppWindow.g_cursor_blink;
    if (should_blink and !rend.cursor_blink_visible) return null;
    return terminal_style;
}

/// Snapshot terminal cell data under the lock. Resolves colors and codepoints
/// into a flat buffer so rebuildCells can run outside the lock.
/// Modeled after Ghostty's RenderState.update() which copies row data via
/// fastmem.copy under the lock, then releases it for the renderer.
fn snapshotCells(rend: *Renderer, terminal: *ghostty_vt.Terminal) void {
    const g_theme = AppWindow.g_theme;
    const screen = terminal.screens.active;
    const render_cols = terminal.cols;
    const requested_cells = @as(usize, terminal.cols) * @as(usize, terminal.rows);
    rend.ensureCellCapacity(requested_cells) catch {
        rend.snap_cols = 0;
        rend.snap_rows = 0;
        rend.cells_valid = false;
        return;
    };

    rend.snap_cols = render_cols;

    var row_it = screen.pages.rowIterator(
        .right_down,
        .{ .viewport = .{} },
        null,
    );
    var row_idx: usize = 0;
    while (row_it.next()) |row_pin| {
        const p = &row_pin.node.data;
        const rac = row_pin.rowAndCell();
        const page_cells = p.getCells(rac.row);
        const num_cols = @min(page_cells.len, render_cols);
        const row_base = row_idx * render_cols;

        for (0..num_cols) |col_idx| {
            const cell = &page_cells[col_idx];
            var fg_color: [3]f32 = g_theme.foreground;
            var bg_color: ?[3]f32 = null;

            switch (cell.content_tag) {
                .bg_color_palette => bg_color = font.indexToRgb(cell.content.color_palette),
                .bg_color_rgb => {
                    const rgb = cell.content.color_rgb;
                    bg_color = .{
                        @as(f32, @floatFromInt(rgb.r)) / 255.0,
                        @as(f32, @floatFromInt(rgb.g)) / 255.0,
                        @as(f32, @floatFromInt(rgb.b)) / 255.0,
                    };
                },
                else => {},
            }

            var inverse = false;
            if (cell.hasStyling()) {
                const style = p.styles.get(p.memory, cell.style_id);
                inverse = style.flags.inverse;
                switch (style.fg_color) {
                    .none => {},
                    .palette => |idx| fg_color = font.indexToRgb(idx),
                    .rgb => |rgb| fg_color = .{
                        @as(f32, @floatFromInt(rgb.r)) / 255.0,
                        @as(f32, @floatFromInt(rgb.g)) / 255.0,
                        @as(f32, @floatFromInt(rgb.b)) / 255.0,
                    },
                }
                switch (style.bg_color) {
                    .none => {},
                    .palette => |idx| bg_color = font.indexToRgb(idx),
                    .rgb => |rgb| bg_color = .{
                        @as(f32, @floatFromInt(rgb.r)) / 255.0,
                        @as(f32, @floatFromInt(rgb.g)) / 255.0,
                        @as(f32, @floatFromInt(rgb.b)) / 255.0,
                    },
                }
            }

            // SGR inverse (reverse video) swaps foreground/background. TUI apps
            // such as Claude Code often use an inverse space as their input caret.
            if (inverse) {
                const normal_fg = fg_color;
                const normal_bg = bg_color orelse g_theme.background;
                fg_color = normal_bg;
                bg_color = normal_fg;
            }

            if (row_base + col_idx < rend.snap.items.len) {
                var snap: Renderer.SnapCell = .{
                    .codepoint = cell.codepoint(),
                    .fg = fg_color,
                    .bg = bg_color,
                    .wide = @enumFromInt(@intFromEnum(cell.wide)),
                };

                // Store grapheme cluster data for multi-codepoint sequences
                // (emoji with skin tones, flags, ZWJ sequences, VS16, etc.)
                if (cell.hasGrapheme()) {
                    if (p.lookupGrapheme(cell)) |extra_cps| {
                        const len = @min(extra_cps.len, 8); // MAX_GRAPHEME
                        for (0..len) |gi| {
                            snap.grapheme[gi] = extra_cps[gi];
                        }
                        snap.grapheme_len = @intCast(len);
                    }
                }

                rend.snap.items[row_base + col_idx] = snap;
            }
        }
        row_idx += 1;
    }
    rend.snap_rows = row_idx;
}
