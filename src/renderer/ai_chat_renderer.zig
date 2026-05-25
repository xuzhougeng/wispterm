//! Native renderer for AI Chat sessions.

const std = @import("std");
const AppWindow = @import("../AppWindow.zig");
const ai_chat = @import("../ai_chat.zig");
const composer_layout = @import("../ai_chat_composer_layout.zig");
const md = @import("../markdown_text.zig");

const TABLE_MAX_COLS = md.TABLE_MAX_COLS;
const nextSourceLine = md.nextSourceLine;
const cleanInline = md.cleanInline;
const isTableSeparatorLine = md.isTableSeparatorLine;
const parseTableRowCells = md.parseTableRowCells;
const isMarkdownTableStart = md.isMarkdownTableStart;
const tableBlockEnd = md.tableBlockEnd;

const font = AppWindow.font;
const gl_init = AppWindow.gl_init;
const titlebar = AppWindow.titlebar;

const c = @cImport({
    @cInclude("glad/gl.h");
});

pub const LINE_PAD_X: f32 = 18;
const HEADER_H: f32 = 54;
pub const INPUT_H: f32 = composer_layout.input_min_h;
pub const INPUT_MAX_H: f32 = composer_layout.input_max_h;
pub const INPUT_FIELD_PAD_TOP: f32 = composer_layout.Field.pad_top;
const PERMISSION_CHIP_W: f32 = 104;
const PERMISSION_CHIP_H: f32 = 24;
const STATUS_SLOT_W: f32 = 280;
const STOP_BUTTON_W: f32 = 104;
const STOP_BUTTON_H: f32 = 28;
const MODE_SLOT_W: f32 = 112;
const INPUT_SCROLLBAR_GUTTER: f32 = 10;
const INPUT_SCROLLBAR_W: f32 = 4;
const INPUT_SCROLLBAR_PAD: f32 = 7;
const INPUT_SCROLLBAR_HIT_PAD: f32 = 5;
const BUBBLE_PAD_X: f32 = 14;
const BUBBLE_PAD_Y: f32 = 10;
const BUBBLE_GAP: f32 = 12;
const USAGE_FOOTER_PAD_TOP: f32 = 4;
const APPROVAL_H: f32 = 128;
const APPROVAL_GAP: f32 = 12;
const COPY_BUTTON_SIZE: f32 = 24;
const COPY_BUTTON_PAD: f32 = 8;
const DETAIL_PAD_X: f32 = 14;
const DETAIL_PAD_Y: f32 = 10;
const DETAIL_ARROW_W: f32 = 12;
const DETAIL_RULE_W: f32 = 3;
const TABLE_CELL_PAD_X: f32 = 10;
const TABLE_MIN_COL_W: f32 = 56;
const SUGGESTION_ROW_H: f32 = 28;
const SUGGESTION_PAD_Y: f32 = 6;
const SUGGESTION_GAP: f32 = 6;
const SUGGESTION_MAX_W: f32 = 560;
const SUGGESTION_COMMAND_W: f32 = 148;

pub const HitTarget = union(enum) {
    copy_message: usize,
    toggle_tool: usize,
    toggle_reasoning: usize,
};

pub const TranscriptTextHit = struct {
    message_index: usize,
    byte_offset: usize,
};

pub const InputCursorRect = struct {
    x: f32,
    row: usize,
};

pub const InputLayout = struct {
    input_h: f32,
    field_x: f32,
    field_y: f32,
    field_w: f32,
    field_h: f32,
    text_x: f32,
    text_w: f32,
};

pub const InputFieldMetrics = struct {
    max_cols: usize,
    visible_rows: usize,
};

pub const InputScrollbarHit = struct {
    drag_offset_px: f32,
};

pub const InputScrollbarDrag = struct {
    row: usize,
    max_cols: usize,
    visible_rows: usize,
};

const InputScrollbarGeometry = struct {
    track_x: f32,
    track_top_px: f32,
    track_h: f32,
    thumb_top_px: f32,
    thumb_h: f32,
    max_scroll_row: usize,
};

pub fn render(
    session: *ai_chat.Session,
    window_width: f32,
    window_height: f32,
    titlebar_offset: f32,
    left_panels_w: f32,
    right_panels_w: f32,
) void {
    const gl = &AppWindow.gl;
    gl.Enable.?(c.GL_BLEND);
    gl.BlendFunc.?(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
    gl.UseProgram.?(gl_init.shader_program);
    gl.ActiveTexture.?(c.GL_TEXTURE0);
    gl.BindVertexArray.?(gl_init.vao);

    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const muted = mixColor(bg, fg, 0.62);
    const panel = mixColor(bg, fg, 0.045);
    const line = mixColor(bg, fg, 0.18);

    const x = @round(left_panels_w);
    const w = @round(@max(1.0, window_width - left_panels_w - right_panels_w));
    const top = @round(titlebar_offset);
    const h = @round(@max(1.0, window_height - top));
    if (w <= 1 or h <= 1) return;

    gl_init.renderQuad(x, 0, w, h, bg);

    session.mutex.lock();
    defer session.mutex.unlock();

    const header_y = window_height - top - HEADER_H;
    gl_init.renderQuadAlpha(x, header_y, w, HEADER_H, panel, 0.95);
    gl_init.renderQuadAlpha(x, header_y, w, 1, line, 0.8);
    _ = titlebar.renderTextLimited(session.model(), x + LINE_PAD_X, header_y + 10, mixColor(fg, accent, 0.12), w * 0.48);

    const permission = ai_chat.agentPermission();
    const chip_x = permissionChipX(x, w);
    const mode_text = if (session.agent_enabled) "Agent" else "Chat";
    const mode_x = chip_x - MODE_SLOT_W - 8;
    _ = titlebar.renderTextLimited(mode_text, mode_x, header_y + 10, mixColor(fg, accent, 0.18), MODE_SLOT_W);

    const perm_text = permissionDisplayName(permission);
    const perm_color = if (permission == .full) mixColor(fg, accent, 0.25) else mixColor(bg, fg, 0.66);
    _ = titlebar.renderTextLimited(perm_text, chip_x, header_y + 10, perm_color, PERMISSION_CHIP_W);
    gl_init.renderQuadAlpha(chip_x, header_y + 8, PERMISSION_CHIP_W - 8, 1, accent, if (permission == .full) 0.38 else 0.16);

    if (session.request_inflight) {
        renderStopButton(stopButtonRect(x, w, top), window_height, session.request_stopping);
    } else {
        const status_w = measureText(session.status());
        _ = titlebar.renderTextLimited(session.status(), x + w - LINE_PAD_X - @min(status_w, STATUS_SLOT_W), header_y + 10, muted, STATUS_SLOT_W);
    }

    const input_text = session.input();
    const layout = inputLayout(x, w, input_text);
    const input_h = layout.input_h;
    const input_y: f32 = 0;
    gl_init.renderQuadAlpha(x, input_y, w, input_h, panel, 0.98);
    gl_init.renderQuadAlpha(x, input_y + input_h - 1, w, 1, line, 0.72);

    const field_bg = mixColor(bg, fg, 0.075);
    gl_init.renderQuadAlpha(layout.field_x, layout.field_y, layout.field_w, layout.field_h, field_bg, 0.95);
    gl_init.renderQuadAlpha(layout.field_x, layout.field_y, layout.field_w, 1, mixColor(bg, accent, 0.38), 0.6);

    gl.Enable.?(c.GL_SCISSOR_TEST);
    gl.Scissor.?(
        @intFromFloat(@round(layout.field_x)),
        @intFromFloat(@round(layout.field_y)),
        @intFromFloat(@round(layout.field_w)),
        @intFromFloat(@round(layout.field_h)),
    );

    if (input_text.len == 0) {
        session.input_scroll_row = 0;
        const placeholder = if (session.agent_enabled) "Ask Agent" else "Ask AI Chat";
        _ = titlebar.renderTextLimited(
            placeholder,
            layout.text_x,
            layout.field_y + (layout.field_h - font.g_titlebar_cell_height) / 2,
            mixColor(bg, fg, 0.42),
            layout.text_w,
        );
    } else {
        if (session.input_select_all) {
            gl_init.renderQuadAlpha(
                layout.field_x + 8,
                layout.field_y + 8,
                @max(1.0, layout.field_w - 16),
                @max(1.0, layout.field_h - 16),
                accent,
                0.22,
            );
        }
        const cursor = inputCursorRect(input_text, session.input_cursor, layout.text_x, layout.text_w);
        const visible_rows = inputVisibleRowsForField(layout.field_h);
        const total_rows = countWrappedLines(input_text, layout.text_w);
        const max_first_row = if (total_rows > visible_rows) total_rows - visible_rows else 0;
        var first_row = @min(session.input_scroll_row, max_first_row);
        if (session.input_scroll_follow_cursor) {
            if (cursor.row < first_row) {
                first_row = cursor.row;
            } else if (cursor.row >= first_row + visible_rows) {
                first_row = cursor.row - visible_rows + 1;
            }
        }
        first_row = @min(first_row, max_first_row);
        session.input_scroll_row = first_row;
        const text_start = wrappedByteOffsetForLine(input_text, layout.text_w, first_row);
        _ = renderWrappedText(
            input_text[text_start..],
            layout.text_x,
            window_height - layout.field_y - layout.field_h + composer_layout.Field.pad_top,
            layout.text_w,
            lineHeight(),
            fg,
            window_height,
            window_height - layout.field_y,
        );
        renderInputScrollbar(layout, total_rows, visible_rows, first_row);
    }
    if (!session.request_inflight and AppWindow.g_cursor_blink_visible) {
        const cursor = inputCursorRect(input_text, session.input_cursor, layout.text_x, layout.text_w);
        const visible_rows = inputVisibleRowsForField(layout.field_h);
        const total_rows = countWrappedLines(input_text, layout.text_w);
        const max_first_row = if (total_rows > visible_rows) total_rows - visible_rows else 0;
        const first_row = @min(session.input_scroll_row, max_first_row);
        if (cursor.row >= first_row) {
            const row = cursor.row - first_row;
            if (row < visible_rows) {
                const field_top_px = window_height - layout.field_y - layout.field_h;
                const cursor_top_px = field_top_px + composer_layout.Field.pad_top + @as(f32, @floatFromInt(row)) * lineHeight();
                const cursor_y = window_height - cursor_top_px - font.g_titlebar_cell_height;
                gl_init.renderQuad(cursor.x, cursor_y, 1, font.g_titlebar_cell_height, accent);
            }
        }
    }
    gl.Disable.?(c.GL_SCISSOR_TEST);

    const approval = session.approvalView();
    const approval_h: f32 = if (approval != null) APPROVAL_H + APPROVAL_GAP else 0;

    const transcript_top = top + HEADER_H + 18;
    const transcript_bottom = input_h + approval_h + 18;
    const transcript_h = @max(1.0, window_height - transcript_top - transcript_bottom);
    const content_w = w - LINE_PAD_X * 2;
    const content_x = x + LINE_PAD_X;
    const viewport_bottom_top_px = window_height - transcript_bottom;

    var content_h: f32 = 0;
    for (session.messages.items) |msg| {
        content_h += messageBlockHeight(msg, content_w);
        if (msg.reasoning) |reasoning| {
            if (reasoning.len > 0) content_h += reasoningCardHeight(msg, content_w);
        }
        if (msg.usage_footer) |footer| {
            if (footer.len > 0) content_h += usageFooterHeight(footer, content_w);
        }
        content_h += BUBBLE_GAP;
    }
    const max_scroll = @max(0.0, content_h - transcript_h);
    session.scroll_px = @min(session.scroll_px, max_scroll);

    gl.Enable.?(c.GL_SCISSOR_TEST);
    gl.Scissor.?(
        @intFromFloat(@round(x)),
        @intFromFloat(@round(transcript_bottom)),
        @intFromFloat(@round(w)),
        @intFromFloat(@round(transcript_h)),
    );

    const gravity_offset = @max(0.0, transcript_h - content_h);
    const palette = markdownPalette(bg, fg, accent);
    const transcript_selected = session.transcript_select_all;
    var cursor_top = transcript_top + gravity_offset - session.scroll_px;

    for (session.messages.items, 0..) |msg, message_index| {
        const block_h = messageBlockHeight(msg, content_w);
        if (msg.role == .tool) {
            if (sectionVisible(cursor_top, block_h, transcript_top, viewport_bottom_top_px)) {
                renderToolCard(msg, content_x, cursor_top, content_w, block_h, window_height, transcript_selected);
            }
        } else if (sectionVisible(cursor_top, block_h, transcript_top, viewport_bottom_top_px)) {
            const selection_range = if (session.transcript_selection) |selection|
                selection.rangeForMessage(message_index)
            else
                null;
            renderMessageBubble(msg.role, msg.content, content_x, cursor_top, content_w, block_h, window_height, transcript_selected, selection_range, palette);
        }
        cursor_top += block_h;

        if (msg.reasoning) |reasoning| {
            if (reasoning.len > 0) {
                const r_h = reasoningCardHeight(msg, content_w);
                if (sectionVisible(cursor_top, r_h, transcript_top, viewport_bottom_top_px)) {
                    renderReasoningCard(reasoning, msg.reasoning_collapsed, content_x, cursor_top, content_w, r_h, window_height, transcript_selected);
                }
                cursor_top += r_h;
            }
        }

        if (msg.usage_footer) |footer| {
            if (footer.len > 0) {
                const footer_h = usageFooterHeight(footer, content_w);
                if (sectionVisible(cursor_top, footer_h, transcript_top, viewport_bottom_top_px)) {
                    renderUsageFooter(footer, content_x, cursor_top, content_w, footer_h, window_height);
                }
                cursor_top += footer_h;
            }
        }

        cursor_top += BUBBLE_GAP;
    }

    gl.Disable.?(c.GL_SCISSOR_TEST);

    if (approval) |view| {
        renderApprovalCard(view, x + LINE_PAD_X, input_h + APPROVAL_GAP, w - LINE_PAD_X * 2, APPROVAL_H);
    }
    renderComposerSuggestions(session, layout);
}

pub fn interactionHitTest(
    session: *ai_chat.Session,
    xpos: f64,
    ypos: f64,
    window_width: f32,
    window_height: f32,
    titlebar_offset: f32,
    left_panels_w: f32,
    right_panels_w: f32,
) ?HitTarget {
    const x = @round(left_panels_w);
    const w = @round(@max(1.0, window_width - left_panels_w - right_panels_w));
    if (w <= 1) return null;

    session.mutex.lock();
    defer session.mutex.unlock();

    const approval = session.approvalView();
    const approval_h: f32 = if (approval != null) APPROVAL_H + APPROVAL_GAP else 0;
    const input_h = inputLayout(x, w, session.input()).input_h;
    const transcript_top = titlebar_offset + HEADER_H + 18;
    const transcript_bottom = input_h + approval_h + 18;
    const transcript_h = @max(1.0, window_height - transcript_top - transcript_bottom);
    const viewport_bottom_top_px = window_height - transcript_bottom;
    const content_w = w - LINE_PAD_X * 2;
    const content_x = x + LINE_PAD_X;

    var content_h: f32 = 0;
    for (session.messages.items) |msg| {
        content_h += messageBlockHeight(msg, content_w);
        if (msg.reasoning) |reasoning| {
            if (reasoning.len > 0) content_h += reasoningCardHeight(msg, content_w);
        }
        if (msg.usage_footer) |footer| {
            if (footer.len > 0) content_h += usageFooterHeight(footer, content_w);
        }
        content_h += BUBBLE_GAP;
    }

    const scroll_px = @min(session.scroll_px, @max(0.0, content_h - transcript_h));
    const gravity_offset = @max(0.0, transcript_h - content_h);
    const px: f32 = @floatCast(xpos);
    const py: f32 = @floatCast(ypos);
    var cursor_top = transcript_top + gravity_offset - scroll_px;

    for (session.messages.items, 0..) |msg, message_index| {
        const block_h = messageBlockHeight(msg, content_w);
        if (msg.role == .tool) {
            if (sectionVisible(cursor_top, block_h, transcript_top, viewport_bottom_top_px)) {
                const copy_rect = detailCopyButtonRect(content_x, cursor_top, content_w);
                if (pointInRect(px, py, copy_rect)) return .{ .copy_message = message_index };
                const header_rect = detailHeaderRect(content_x, cursor_top, content_w);
                if (pointInRect(px, py, header_rect)) return .{ .toggle_tool = message_index };
            }
        } else if (sectionVisible(cursor_top, block_h, transcript_top, viewport_bottom_top_px)) {
            const rect = copyButtonRect(msg.role, content_x, cursor_top, content_w);
            if (pointInRect(px, py, rect)) return .{ .copy_message = message_index };
        }
        cursor_top += block_h;

        if (msg.reasoning) |reasoning| {
            if (reasoning.len > 0) {
                const r_h = reasoningCardHeight(msg, content_w);
                if (sectionVisible(cursor_top, r_h, transcript_top, viewport_bottom_top_px)) {
                    const header_rect = detailHeaderRect(content_x, cursor_top, content_w);
                    if (pointInRect(px, py, header_rect)) return .{ .toggle_reasoning = message_index };
                }
                cursor_top += r_h;
            }
        }
        if (msg.usage_footer) |footer| {
            if (footer.len > 0) cursor_top += usageFooterHeight(footer, content_w);
        }
        cursor_top += BUBBLE_GAP;
    }

    return null;
}

pub fn transcriptTextHitTest(
    session: *ai_chat.Session,
    xpos: f64,
    ypos: f64,
    window_width: f32,
    window_height: f32,
    titlebar_offset: f32,
    left_panels_w: f32,
    right_panels_w: f32,
) ?TranscriptTextHit {
    const x = @round(left_panels_w);
    const w = @round(@max(1.0, window_width - left_panels_w - right_panels_w));
    if (w <= 1) return null;

    session.mutex.lock();
    defer session.mutex.unlock();

    const approval = session.approvalView();
    const approval_h: f32 = if (approval != null) APPROVAL_H + APPROVAL_GAP else 0;
    const input_h = inputLayout(x, w, session.input()).input_h;
    const transcript_top = titlebar_offset + HEADER_H + 18;
    const transcript_bottom = input_h + approval_h + 18;
    const transcript_h = @max(1.0, window_height - transcript_top - transcript_bottom);
    const viewport_bottom_top_px = window_height - transcript_bottom;
    const content_w = w - LINE_PAD_X * 2;
    const content_x = x + LINE_PAD_X;

    var content_h: f32 = 0;
    for (session.messages.items) |msg| {
        content_h += messageBlockHeight(msg, content_w);
        if (msg.reasoning) |reasoning| {
            if (reasoning.len > 0) content_h += reasoningCardHeight(msg, content_w);
        }
        if (msg.usage_footer) |footer| {
            if (footer.len > 0) content_h += usageFooterHeight(footer, content_w);
        }
        content_h += BUBBLE_GAP;
    }

    const scroll_px = @min(session.scroll_px, @max(0.0, content_h - transcript_h));
    const gravity_offset = @max(0.0, transcript_h - content_h);
    const px: f32 = @floatCast(xpos);
    const py: f32 = @floatCast(ypos);
    var cursor_top = transcript_top + gravity_offset - scroll_px;

    for (session.messages.items, 0..) |msg, message_index| {
        const block_h = messageBlockHeight(msg, content_w);
        if (msg.role == .assistant and sectionVisible(cursor_top, block_h, transcript_top, viewport_bottom_top_px)) {
            const bubble = bubbleGeometry(msg.role, content_x, content_w);
            const body_x = bubble.x + BUBBLE_PAD_X;
            const body_top = cursor_top + BUBBLE_PAD_Y + lineHeight();
            const body_w = @max(1.0, bubble.w - BUBBLE_PAD_X * 2);
            const body_h = @max(1.0, block_h - BUBBLE_PAD_Y * 2 - lineHeight());
            const hit_slop: f32 = 6;
            if (px >= body_x - hit_slop and px <= body_x + body_w + hit_slop and py >= body_top and py <= body_top + body_h) {
                return .{
                    .message_index = message_index,
                    .byte_offset = byteOffsetForMarkdownPoint(msg.content, body_x, body_top, body_w, px, py),
                };
            }
        }
        cursor_top += block_h;

        if (msg.reasoning) |reasoning| {
            if (reasoning.len > 0) cursor_top += reasoningCardHeight(msg, content_w);
        }
        if (msg.usage_footer) |footer| {
            if (footer.len > 0) cursor_top += usageFooterHeight(footer, content_w);
        }
        cursor_top += BUBBLE_GAP;
    }

    return null;
}

pub fn stopButtonHitTest(
    session: *ai_chat.Session,
    xpos: f64,
    ypos: f64,
    window_width: f32,
    titlebar_offset: f32,
    left_panels_w: f32,
    right_panels_w: f32,
) bool {
    session.mutex.lock();
    const visible = session.request_inflight;
    session.mutex.unlock();
    if (!visible) return false;

    const x = @round(left_panels_w);
    const w = @round(@max(1.0, window_width - left_panels_w - right_panels_w));
    const rect = stopButtonRect(x, w, titlebar_offset);
    return pointInRect(@floatCast(xpos), @floatCast(ypos), rect);
}

pub fn permissionChipHitTest(
    xpos: f64,
    ypos: f64,
    window_width: f32,
    titlebar_offset: f32,
    left_panels_w: f32,
    right_panels_w: f32,
) bool {
    const x = @round(left_panels_w);
    const w = @round(@max(1.0, window_width - left_panels_w - right_panels_w));
    const chip_x = permissionChipX(x, w);
    return pointInRect(@floatCast(xpos), @floatCast(ypos), .{
        .x = chip_x,
        .top_px = titlebar_offset + 12,
        .w = PERMISSION_CHIP_W,
        .h = PERMISSION_CHIP_H,
    });
}

pub fn inputFieldMetricsAt(
    session: *ai_chat.Session,
    xpos: f64,
    ypos: f64,
    window_width: f32,
    window_height: f32,
    left_panels_w: f32,
    right_panels_w: f32,
) ?InputFieldMetrics {
    const x = @round(left_panels_w);
    const w = @round(@max(1.0, window_width - left_panels_w - right_panels_w));
    if (w <= 1) return null;

    session.mutex.lock();
    const layout = inputLayout(x, w, session.input());
    session.mutex.unlock();

    const px: f32 = @floatCast(xpos);
    const py: f32 = @floatCast(ypos);
    const field_top_px = window_height - layout.field_y - layout.field_h;
    if (px < layout.field_x or px > layout.field_x + layout.field_w) return null;
    if (py < field_top_px or py > field_top_px + layout.field_h) return null;

    return .{
        .max_cols = inputWrapColumns(w),
        .visible_rows = inputVisibleRowsForField(layout.field_h),
    };
}

pub fn inputScrollbarHitTest(
    session: *ai_chat.Session,
    xpos: f64,
    ypos: f64,
    window_width: f32,
    window_height: f32,
    left_panels_w: f32,
    right_panels_w: f32,
) ?InputScrollbarHit {
    const x = @round(left_panels_w);
    const w = @round(@max(1.0, window_width - left_panels_w - right_panels_w));
    if (w <= 1) return null;

    session.mutex.lock();
    const layout = inputLayout(x, w, session.input());
    const total_rows = countWrappedLines(session.input(), layout.text_w);
    const visible_rows = inputVisibleRowsForField(layout.field_h);
    const first_row = session.input_scroll_row;
    session.mutex.unlock();

    const geo = inputScrollbarGeometry(layout, window_height, total_rows, visible_rows, first_row) orelse return null;
    const px: f32 = @floatCast(xpos);
    const py: f32 = @floatCast(ypos);
    if (px < geo.track_x - INPUT_SCROLLBAR_HIT_PAD or px > geo.track_x + INPUT_SCROLLBAR_W + INPUT_SCROLLBAR_HIT_PAD) return null;
    if (py < geo.track_top_px or py > geo.track_top_px + geo.track_h) return null;

    const drag_offset = if (py >= geo.thumb_top_px and py <= geo.thumb_top_px + geo.thumb_h)
        py - geo.thumb_top_px
    else
        geo.thumb_h / 2.0;

    return .{
        .drag_offset_px = drag_offset,
    };
}

pub fn inputScrollbarDragRowAt(
    session: *ai_chat.Session,
    ypos: f64,
    window_width: f32,
    window_height: f32,
    left_panels_w: f32,
    right_panels_w: f32,
    drag_offset_px: f32,
) ?InputScrollbarDrag {
    const x = @round(left_panels_w);
    const w = @round(@max(1.0, window_width - left_panels_w - right_panels_w));
    if (w <= 1) return null;

    session.mutex.lock();
    const layout = inputLayout(x, w, session.input());
    const total_rows = countWrappedLines(session.input(), layout.text_w);
    const visible_rows = inputVisibleRowsForField(layout.field_h);
    const first_row = session.input_scroll_row;
    session.mutex.unlock();

    const geo = inputScrollbarGeometry(layout, window_height, total_rows, visible_rows, first_row) orelse return null;
    const usable_h = @max(1.0, geo.track_h - geo.thumb_h);
    const py: f32 = @floatCast(ypos);
    const ratio = std.math.clamp((py - geo.track_top_px - drag_offset_px) / usable_h, 0.0, 1.0);
    const row_f = ratio * @as(f32, @floatFromInt(geo.max_scroll_row));

    return .{
        .row = @intFromFloat(@round(row_f)),
        .max_cols = inputWrapColumns(w),
        .visible_rows = visible_rows,
    };
}

fn messageBlockHeight(msg: ai_chat.Message, max_w: f32) f32 {
    return switch (msg.role) {
        .tool => toolCardHeight(msg, max_w),
        else => bubbleHeight(msg.role, msg.content, max_w),
    };
}

fn bubbleHeight(role: ai_chat.Role, text: []const u8, max_w: f32) f32 {
    const bubble = bubbleGeometry(role, 0, max_w);
    const inner_w = @max(1.0, bubble.w - BUBBLE_PAD_X * 2);
    const body_h = if (role == .assistant)
        markdownContentHeight(text, inner_w)
    else
        plainContentHeight(text, inner_w, lineHeight());
    return BUBBLE_PAD_Y * 2 + lineHeight() + body_h;
}

fn toolCardHeight(msg: ai_chat.Message, max_w: f32) f32 {
    const body_h = if (msg.content_collapsed)
        0
    else
        plainContentHeight(msg.content, @max(1.0, max_w - DETAIL_PAD_X * 2), lineHeight()) + DETAIL_PAD_Y * 2;
    return detailHeaderHeight() + body_h;
}

fn reasoningCardHeight(msg: ai_chat.Message, max_w: f32) f32 {
    const reasoning = msg.reasoning orelse return 0;
    const body_h = if (msg.reasoning_collapsed)
        0
    else
        plainContentHeight(reasoning, @max(1.0, max_w - DETAIL_PAD_X * 2), reasoningLineHeight()) + DETAIL_PAD_Y * 2;
    return detailHeaderHeight() + body_h;
}

fn usageFooterHeight(text: []const u8, max_w: f32) f32 {
    return USAGE_FOOTER_PAD_TOP + plainContentHeight(text, @max(1.0, max_w - BUBBLE_PAD_X * 2), reasoningLineHeight());
}

fn plainContentHeight(text: []const u8, max_w: f32, line_h: f32) f32 {
    return @as(f32, @floatFromInt(@max(@as(usize, 1), countWrappedLines(text, max_w)))) * line_h;
}

fn markdownContentHeight(text: []const u8, max_w: f32) f32 {
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return lineHeight();

    const palette = markdownPalette(AppWindow.g_theme.background, AppWindow.g_theme.foreground, AppWindow.g_theme.cursor_color);
    var cursor: usize = 0;
    var total: f32 = 0;
    var in_code = false;

    while (cursor < text.len) {
        if (!in_code and isMarkdownTableStart(text, cursor)) {
            const end = tableBlockEnd(text, cursor);
            total += tableBlockHeight(text, cursor, end);
            cursor = end;
            continue;
        }

        const info = nextSourceLine(text, cursor);
        cursor = info.next;

        var clean_buf: [1024]u8 = undefined;
        const prepared = prepareMarkdownLine(&clean_buf, info.line, in_code, palette);
        switch (prepared.kind) {
            .blank => total += prepared.line_h,
            .fence => {
                total += prepared.line_h;
                in_code = !in_code;
            },
            .rule => total += prepared.line_h,
            .text => total += plainContentHeight(prepared.text, @max(1.0, max_w - prepared.indent), prepared.line_h),
        }
    }

    return @max(lineHeight(), total);
}

fn renderMessageBubble(
    role: ai_chat.Role,
    text: []const u8,
    x: f32,
    top_px: f32,
    w: f32,
    h: f32,
    window_height: f32,
    selected: bool,
    selection_range: ?ai_chat.TextSelectionRange,
    palette: MarkdownPalette,
) void {
    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const bubble = bubbleGeometry(role, x, w);
    const bubble_y = window_height - top_px - h;
    const is_user = role == .user;
    const bubble_bg = if (selected)
        mixColor(bg, accent, 0.30)
    else if (is_user)
        mixColor(bg, accent, 0.20)
    else
        mixColor(bg, fg, 0.07);

    gl_init.renderQuadAlpha(bubble.x, bubble_y, bubble.w, h, bubble_bg, 0.92);
    gl_init.renderQuadAlpha(bubble.x, bubble_y + h - 1, bubble.w, 1, if (is_user) accent else mixColor(bg, fg, 0.18), 0.55);
    if (selected) gl_init.renderQuadAlpha(bubble.x, bubble_y, 3, h, accent, 0.72);

    const label_color = if (is_user) mixColor(fg, accent, 0.18) else mixColor(fg, accent, 0.05);
    _ = titlebar.renderTextLimited(role.label(), bubble.x + BUBBLE_PAD_X, bubble_y + h - BUBBLE_PAD_Y - font.g_titlebar_cell_height, label_color, bubble.w - BUBBLE_PAD_X * 2);
    renderCopyButton(copyButtonRectForBubble(bubble.x, top_px, bubble.w), window_height, selected);

    const body_x = bubble.x + BUBBLE_PAD_X;
    const body_top = top_px + BUBBLE_PAD_Y + lineHeight();
    const body_w = @max(1.0, bubble.w - BUBBLE_PAD_X * 2);
    if (role == .assistant) {
        _ = renderMarkdownContent(text, body_x, body_top, body_w, window_height, window_height, palette, selection_range);
    } else {
        renderWrappedSelection(text, 0, body_x, body_top, body_w, lineHeight(), selection_range, window_height, window_height);
        _ = renderWrappedText(text, body_x, body_top, body_w, lineHeight(), fg, window_height, window_height);
    }
}

fn renderToolCard(msg: ai_chat.Message, x: f32, top_px: f32, w: f32, h: f32, window_height: f32, selected: bool) void {
    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const y = window_height - top_px - h;
    const header_h = detailHeaderHeight();
    const meta = toolSectionMeta(msg.content);
    const card_bg = if (selected) mixColor(bg, accent, 0.22) else mixColor(bg, fg, 0.055);
    const header_bg = if (selected) mixColor(bg, accent, 0.28) else mixColor(bg, fg, 0.08);
    const header_y = y + h - header_h;

    gl_init.renderQuadAlpha(x, y, w, h, card_bg, 0.94);
    gl_init.renderQuadAlpha(x, y + h - 1, w, 1, mixColor(bg, fg, 0.20), 0.65);
    gl_init.renderQuadAlpha(x, y + h - header_h, w, header_h, header_bg, 0.98);
    gl_init.renderQuadAlpha(x, y, DETAIL_RULE_W, h, accent, if (selected) 0.78 else 0.52);
    if (selected) gl_init.renderQuadAlpha(x, y, 1, h, accent, 0.90);

    const arrow_x = x + DETAIL_PAD_X;
    const arrow_y = header_y + @round((header_h - font.g_titlebar_cell_height) / 2);
    _ = titlebar.renderTextLimited(if (msg.content_collapsed) ">" else "v", arrow_x, arrow_y, mixColor(fg, accent, 0.16), DETAIL_ARROW_W);

    var text_x = arrow_x + DETAIL_ARROW_W + 6;
    const text_y = header_y + @round((header_h - font.g_titlebar_cell_height) / 2);
    const copy_rect = detailCopyButtonRect(x, top_px, w);
    renderCopyButton(copy_rect, window_height, selected);
    const header_text_limit = @max(40.0, copy_rect.x - text_x - 12);
    const title_end = titlebar.renderTextLimited(meta.title, text_x, text_y, mixColor(fg, accent, 0.18), header_text_limit);
    text_x = title_end + 8;
    if (meta.name.len > 0 and text_x + 10 < copy_rect.x) {
        text_x = titlebar.renderTextLimited(meta.name, text_x, text_y, mixColor(fg, accent, 0.32), @max(24.0, copy_rect.x - text_x - 12)) + 10;
    }
    if (msg.content_collapsed and meta.preview.len > 0 and text_x + 12 < copy_rect.x) {
        _ = titlebar.renderTextLimited(meta.preview, text_x, text_y, mixColor(bg, fg, 0.58), @max(24.0, copy_rect.x - text_x - 12));
    }

    if (!msg.content_collapsed) {
        _ = renderWrappedText(
            msg.content,
            x + DETAIL_PAD_X,
            top_px + header_h + DETAIL_PAD_Y,
            @max(1.0, w - DETAIL_PAD_X * 2),
            lineHeight(),
            mixColor(bg, fg, 0.84),
            window_height,
            window_height,
        );
    }
}

fn renderReasoningCard(text: []const u8, collapsed: bool, x: f32, top_px: f32, w: f32, h: f32, window_height: f32, selected: bool) void {
    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const y = window_height - top_px - h;
    const header_h = detailHeaderHeight();
    const card_bg = if (selected) mixColor(bg, accent, 0.18) else mixColor(bg, fg, 0.04);
    const header_bg = if (selected) mixColor(bg, accent, 0.22) else mixColor(bg, fg, 0.06);
    const header_y = y + h - header_h;

    gl_init.renderQuadAlpha(x, y, w, h, card_bg, 0.88);
    gl_init.renderQuadAlpha(x, header_y, w, header_h, header_bg, 0.96);
    gl_init.renderQuadAlpha(x, y, DETAIL_RULE_W, h, accent, if (selected) 0.76 else 0.34);

    const arrow_x = x + DETAIL_PAD_X;
    const arrow_y = header_y + @round((header_h - font.g_titlebar_cell_height) / 2);
    _ = titlebar.renderTextLimited(if (collapsed) ">" else "v", arrow_x, arrow_y, mixColor(fg, accent, 0.14), DETAIL_ARROW_W);

    const title_x = arrow_x + DETAIL_ARROW_W + 6;
    const title_y = header_y + @round((header_h - font.g_titlebar_cell_height) / 2);
    const preview = previewLine(text);
    const title_end = titlebar.renderTextLimited("Thinking", title_x, title_y, mixColor(fg, accent, 0.14), w * 0.3);
    if (collapsed and preview.len > 0) {
        _ = titlebar.renderTextLimited(preview, title_end + 10, title_y, mixColor(bg, fg, 0.56), @max(24.0, w - (title_end - x) - DETAIL_PAD_X - 16));
    }

    if (!collapsed) {
        _ = renderWrappedText(
            text,
            x + DETAIL_PAD_X,
            top_px + header_h + DETAIL_PAD_Y,
            @max(1.0, w - DETAIL_PAD_X * 2),
            reasoningLineHeight(),
            mixColor(bg, fg, 0.58),
            window_height,
            window_height,
        );
    }
}

fn renderUsageFooter(text: []const u8, x: f32, top_px: f32, w: f32, h: f32, window_height: f32) void {
    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const body_x = x + BUBBLE_PAD_X;
    const body_w = @max(1.0, w - BUBBLE_PAD_X * 2);
    const top = top_px + USAGE_FOOTER_PAD_TOP;
    _ = renderWrappedText(
        text,
        body_x,
        top,
        body_w,
        reasoningLineHeight(),
        mixColor(bg, fg, 0.58),
        window_height,
        window_height,
    );
    const y = window_height - top_px - h;
    gl_init.renderQuadAlpha(body_x, y + h - 1, @max(1.0, @min(body_w, measureText(text))), 1, mixColor(bg, accent, 0.28), 0.34);
}

fn renderInputScrollbar(layout: InputLayout, total_rows: usize, visible_rows_raw: usize, first_row: usize) void {
    const geo = inputScrollbarGeometry(layout, 0, total_rows, visible_rows_raw, first_row) orelse return;

    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const track_y = @round(layout.field_y + INPUT_SCROLLBAR_PAD);
    const thumb_y = track_y + (geo.track_h - geo.thumb_h) * (1.0 - @as(f32, @floatFromInt(@min(first_row, geo.max_scroll_row))) / @as(f32, @floatFromInt(geo.max_scroll_row)));

    gl_init.renderQuadAlpha(geo.track_x, track_y, INPUT_SCROLLBAR_W, geo.track_h, mixColor(bg, fg, 0.24), 0.35);
    gl_init.renderQuadAlpha(geo.track_x, @round(thumb_y), INPUT_SCROLLBAR_W, geo.thumb_h, mixColor(fg, accent, 0.18), 0.72);
}

fn inputScrollbarGeometry(layout: InputLayout, window_height: f32, total_rows: usize, visible_rows_raw: usize, first_row_raw: usize) ?InputScrollbarGeometry {
    const visible_rows = @max(@as(usize, 1), visible_rows_raw);
    if (total_rows <= visible_rows) return null;

    const track_x = @round(layout.field_x + layout.field_w - INPUT_SCROLLBAR_PAD - INPUT_SCROLLBAR_W);
    const track_y = @round(layout.field_y + INPUT_SCROLLBAR_PAD);
    const track_h = @round(@max(1.0, layout.field_h - INPUT_SCROLLBAR_PAD * 2));
    const max_scroll = total_rows - visible_rows;
    const first_row = @min(first_row_raw, max_scroll);
    const ratio = @as(f32, @floatFromInt(first_row)) / @as(f32, @floatFromInt(max_scroll));
    const visible_ratio = @as(f32, @floatFromInt(visible_rows)) / @as(f32, @floatFromInt(total_rows));
    const thumb_h = @round(@min(track_h, @max(18.0, track_h * visible_ratio)));
    const thumb_y = @round(track_y + (track_h - thumb_h) * (1.0 - ratio));
    const track_top_px = if (window_height > 0) window_height - track_y - track_h else 0;
    const thumb_top_px = if (window_height > 0) window_height - thumb_y - thumb_h else 0;

    return .{
        .track_x = track_x,
        .track_top_px = track_top_px,
        .track_h = track_h,
        .thumb_top_px = thumb_top_px,
        .thumb_h = thumb_h,
        .max_scroll_row = max_scroll,
    };
}

fn sectionVisible(top_px: f32, h: f32, viewport_top: f32, viewport_bottom_top_px: f32) bool {
    return top_px + h >= viewport_top and top_px <= viewport_bottom_top_px;
}

fn bubbleGeometry(role: ai_chat.Role, x: f32, w: f32) BubbleGeometry {
    const is_user = role == .user;
    const bubble_w = @min(w, if (is_user) w * 0.82 else w);
    return .{
        .x = if (is_user) x + w - bubble_w else x,
        .w = bubble_w,
    };
}

const BubbleGeometry = struct {
    x: f32,
    w: f32,
};

const Rect = struct {
    x: f32,
    top_px: f32,
    w: f32,
    h: f32,
};

const CopyButtonRect = Rect;

const HeaderButtonRect = Rect;

fn pointInRect(px: f32, py: f32, rect: Rect) bool {
    return px >= rect.x and px <= rect.x + rect.w and py >= rect.top_px and py <= rect.top_px + rect.h;
}

fn detailHeaderRect(x: f32, top_px: f32, w: f32) Rect {
    return .{
        .x = x,
        .top_px = top_px,
        .w = w,
        .h = detailHeaderHeight(),
    };
}

fn detailCopyButtonRect(x: f32, top_px: f32, w: f32) CopyButtonRect {
    const header_h = detailHeaderHeight();
    return .{
        .x = x + w - DETAIL_PAD_X - COPY_BUTTON_SIZE,
        .top_px = top_px + @round((header_h - COPY_BUTTON_SIZE) / 2),
        .w = COPY_BUTTON_SIZE,
        .h = COPY_BUTTON_SIZE,
    };
}

fn copyButtonRect(role: ai_chat.Role, x: f32, top_px: f32, w: f32) CopyButtonRect {
    const bubble = bubbleGeometry(role, x, w);
    return copyButtonRectForBubble(bubble.x, top_px, bubble.w);
}

fn copyButtonRectForBubble(bubble_x: f32, top_px: f32, bubble_w: f32) CopyButtonRect {
    return .{
        .x = bubble_x + bubble_w - BUBBLE_PAD_X - COPY_BUTTON_SIZE,
        .top_px = top_px + COPY_BUTTON_PAD,
        .w = COPY_BUTTON_SIZE,
        .h = COPY_BUTTON_SIZE,
    };
}

fn permissionChipX(x: f32, w: f32) f32 {
    return x + w - LINE_PAD_X - STATUS_SLOT_W - 12 - PERMISSION_CHIP_W;
}

fn stopButtonRect(x: f32, w: f32, titlebar_offset: f32) HeaderButtonRect {
    return .{
        .x = x + w - LINE_PAD_X - STOP_BUTTON_W,
        .top_px = titlebar_offset + @round((HEADER_H - STOP_BUTTON_H) / 2),
        .w = STOP_BUTTON_W,
        .h = STOP_BUTTON_H,
    };
}

fn renderStopButton(rect: HeaderButtonRect, window_height: f32, stopping: bool) void {
    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const y = window_height - rect.top_px - rect.h;
    const fill = if (stopping) mixColor(bg, fg, 0.12) else mixColor(bg, accent, 0.20);
    const stroke = if (stopping) mixColor(bg, fg, 0.42) else accent;
    gl_init.renderQuadAlpha(rect.x, y, rect.w, rect.h, fill, 0.92);
    gl_init.renderQuadAlpha(rect.x, y + rect.h - 1, rect.w, 1, stroke, 0.70);
    gl_init.renderQuadAlpha(rect.x, y, rect.w, 1, mixColor(bg, fg, 0.20), 0.70);

    const icon_size: f32 = 8;
    const icon_x = rect.x + 12;
    const icon_y = y + @round((rect.h - icon_size) / 2);
    gl_init.renderQuad(icon_x, icon_y, icon_size, icon_size, if (stopping) mixColor(bg, fg, 0.62) else mixColor(fg, accent, 0.10));

    const label = if (stopping) "Stopping" else "Esc Stop";
    _ = titlebar.renderTextLimited(label, rect.x + 28, y + @round((rect.h - font.g_titlebar_cell_height) / 2), if (stopping) mixColor(bg, fg, 0.72) else fg, rect.w - 34);
}

fn permissionDisplayName(permission: ai_chat.AgentPermission) []const u8 {
    return switch (permission) {
        .confirm => "Ask",
        .full => "Full",
    };
}

fn renderComposerSuggestions(session: *ai_chat.Session, layout: InputLayout) void {
    const input_text = session.input();
    const count = ai_chat.composerSuggestionCountForInput(input_text, session.input_cursor, session.skill_suggestions);
    if (count == 0) return;

    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const popup_w = @min(layout.field_w, SUGGESTION_MAX_W);
    const popup_x = layout.field_x;
    const popup_y = layout.field_y + layout.field_h + SUGGESTION_GAP;
    const popup_h = SUGGESTION_PAD_Y * 2 + SUGGESTION_ROW_H * @as(f32, @floatFromInt(count));
    const popup_bg = mixColor(bg, fg, 0.085);
    const border = mixColor(bg, accent, 0.36);
    const selected = @min(session.suggestion_selected, count - 1);

    gl_init.renderQuadAlpha(popup_x, popup_y, popup_w, popup_h, popup_bg, 0.98);
    gl_init.renderQuadAlpha(popup_x, popup_y + popup_h - 1, popup_w, 1, border, 0.78);
    gl_init.renderQuadAlpha(popup_x, popup_y, popup_w, 1, mixColor(bg, fg, 0.20), 0.82);
    gl_init.renderQuadAlpha(popup_x, popup_y, 1, popup_h, mixColor(bg, fg, 0.16), 0.72);
    gl_init.renderQuadAlpha(popup_x + popup_w - 1, popup_y, 1, popup_h, mixColor(bg, fg, 0.16), 0.72);

    const top = popup_y + popup_h - SUGGESTION_PAD_Y;
    for (0..count) |i| {
        const row_y = top - @as(f32, @floatFromInt(i + 1)) * SUGGESTION_ROW_H;
        if (i == selected) {
            gl_init.renderQuadAlpha(popup_x + 4, row_y + 2, popup_w - 8, SUGGESTION_ROW_H - 4, mixColor(bg, accent, 0.18), 0.90);
            gl_init.renderQuadAlpha(popup_x + 4, row_y + 2, 3, SUGGESTION_ROW_H - 4, accent, 0.82);
        }
        const suggestion = ai_chat.composerSuggestionAtForInput(input_text, session.input_cursor, session.skill_suggestions, i) orelse continue;
        const text_y = row_y + @round((SUGGESTION_ROW_H - font.g_titlebar_cell_height) / 2);
        var label_buf: [160]u8 = undefined;
        const label = suggestionLabel(&label_buf, suggestion);
        _ = titlebar.renderTextLimited(
            label,
            popup_x + 14,
            text_y,
            if (i == selected) mixColor(fg, accent, 0.14) else fg,
            @min(SUGGESTION_COMMAND_W, popup_w - 28),
        );
        if (popup_w > SUGGESTION_COMMAND_W + 44) {
            _ = titlebar.renderTextLimited(
                suggestion.description,
                popup_x + 14 + SUGGESTION_COMMAND_W,
                text_y,
                mixColor(bg, fg, 0.62),
                popup_w - SUGGESTION_COMMAND_W - 28,
            );
        }
    }
}

fn suggestionLabel(buf: []u8, suggestion: ai_chat.ComposerSuggestion) []const u8 {
    return switch (suggestion.kind) {
        .slash_command => suggestion.text,
        .skill => std.fmt.bufPrint(buf, "${s}", .{suggestion.text}) catch suggestion.text,
    };
}

fn renderApprovalCard(view: ai_chat.ApprovalView, x: f32, y: f32, w: f32, h: f32) void {
    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const card_bg = mixColor(bg, accent, 0.08);
    gl_init.renderQuadAlpha(x, y, w, h, card_bg, 0.98);
    gl_init.renderQuadAlpha(x, y + h - 1, w, 1, accent, 0.65);
    gl_init.renderQuadAlpha(x, y, w, 1, mixColor(bg, fg, 0.18), 0.8);
    gl_init.renderQuadAlpha(x, y, 4, h, accent, 0.85);

    var title_buf: [256]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "Approve {s}?", .{view.tool}) catch "Approve tool?";
    _ = titlebar.renderTextLimited(title, x + 16, y + h - 26, mixColor(fg, accent, 0.20), w - 32);
    _ = titlebar.renderTextLimited("Enter/Y to run, Esc/N to deny", x + 16, y + h - 50, mixColor(bg, fg, 0.62), w - 32);
    if (view.reason.len > 0) {
        _ = titlebar.renderTextLimited(view.reason, x + 16, y + h - 74, mixColor(bg, fg, 0.70), w - 32);
    }
    const command_bg = mixColor(bg, fg, 0.065);
    gl_init.renderQuadAlpha(x + 12, y + 10, w - 24, 34, command_bg, 0.95);
    _ = titlebar.renderTextLimited(view.command, x + 20, y + 18, fg, w - 40);
}

fn renderCopyButton(rect: CopyButtonRect, window_height: f32, selected: bool) void {
    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const button_bg = if (selected) mixColor(bg, accent, 0.24) else mixColor(bg, fg, 0.10);
    const icon = if (selected) mixColor(fg, accent, 0.14) else mixColor(bg, fg, 0.72);
    const y = window_height - rect.top_px - rect.h;
    gl_init.renderQuadAlpha(rect.x, y, rect.w, rect.h, button_bg, 0.72);

    const t: f32 = 1.3;
    const back_x = rect.x + 7;
    const back_y = y + 7;
    const front_x = rect.x + 5;
    const front_y = y + 5;
    const box_w: f32 = 9;
    const box_h: f32 = 10;
    drawOutlineRect(back_x, back_y, box_w, box_h, t, mixColor(icon, bg, 0.22));
    drawOutlineRect(front_x, front_y + 3, box_w, box_h, t, icon);
}

fn drawOutlineRect(x: f32, y: f32, w: f32, h: f32, t: f32, color: [3]f32) void {
    gl_init.renderQuad(x, y + h - t, w, t, color);
    gl_init.renderQuad(x, y, w, t, color);
    gl_init.renderQuad(x, y, t, h, color);
    gl_init.renderQuad(x + w - t, y, t, h, color);
}

const ToolSectionMeta = struct {
    title: []const u8,
    name: []const u8 = "",
    preview: []const u8 = "",
};

fn toolSectionMeta(text: []const u8) ToolSectionMeta {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "running ")) {
        const rest = std.mem.trimLeft(u8, trimmed["running ".len..], " \t");
        var end: usize = 0;
        while (end < rest.len and rest[end] != ' ' and rest[end] != '\t' and rest[end] != '\r' and rest[end] != '\n') : (end += 1) {}
        return .{
            .title = "Tool call",
            .name = if (end > 0) rest[0..end] else "",
            .preview = if (end < rest.len) previewLine(rest[end..]) else "",
        };
    }
    if (std.mem.startsWith(u8, trimmed, "exit_code=") or
        std.mem.startsWith(u8, trimmed, "timed_out=") or
        std.mem.startsWith(u8, trimmed, "stdout:") or
        std.mem.startsWith(u8, trimmed, "stderr:") or
        std.mem.startsWith(u8, trimmed, "DENIED"))
    {
        return .{ .title = "Tool result", .preview = previewLine(trimmed) };
    }
    return .{ .title = "Tool update", .preview = previewLine(trimmed) };
}

fn previewLine(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return "";
    const end = std.mem.indexOfAny(u8, trimmed, "\r\n") orelse trimmed.len;
    return std.mem.trim(u8, trimmed[0..end], " \t");
}

const MarkdownPalette = struct {
    normal: [3]f32,
    muted: [3]f32,
    strong: [3]f32,
    accent: [3]f32,
    code_bg: [3]f32,
    heading_bg: [3]f32,
    quote_bg: [3]f32,
    table_bg: [3]f32,
    table_alt: [3]f32,
    table_border: [3]f32,
};

fn markdownPalette(bg: [3]f32, fg: [3]f32, accent: [3]f32) MarkdownPalette {
    return .{
        .normal = fg,
        .muted = mixColor(bg, fg, 0.60),
        .strong = mixColor(bg, fg, 0.96),
        .accent = mixColor(fg, accent, 0.10),
        .code_bg = mixColor(bg, fg, 0.075),
        .heading_bg = mixColor(bg, accent, 0.08),
        .quote_bg = mixColor(bg, fg, 0.05),
        .table_bg = mixColor(bg, fg, 0.055),
        .table_alt = mixColor(bg, fg, 0.08),
        .table_border = mixColor(bg, fg, 0.20),
    };
}

const MarkdownBlockKind = enum {
    blank,
    fence,
    rule,
    text,
};

const MarkdownPreparedLine = struct {
    kind: MarkdownBlockKind,
    text: []const u8 = "",
    color: [3]f32 = .{ 0.0, 0.0, 0.0 },
    indent: f32 = 0,
    line_h: f32 = 0,
    background: ?[3]f32 = null,
    left_rule: ?[3]f32 = null,
    underline: bool = false,
    fence_label: []const u8 = "",
};

fn prepareMarkdownLine(buf: *[1024]u8, raw_line: []const u8, in_code: bool, palette: MarkdownPalette) MarkdownPreparedLine {
    const base_h = lineHeight();
    const cl = md.cleanedLine(buf, raw_line, in_code);
    return switch (cl.style) {
        .blank => .{ .kind = .blank, .line_h = blankLineHeight(), .color = palette.muted },
        .fence => .{ .kind = .fence, .line_h = fenceLineHeight(), .color = palette.muted, .fence_label = cl.fence_label },
        .rule => .{ .kind = .rule, .line_h = @round(base_h * 0.78), .color = palette.muted },
        .code => .{
            .kind = .text,
            .text = cl.text,
            .color = palette.accent,
            .line_h = base_h,
            .background = palette.code_bg,
            .left_rule = palette.accent,
        },
        .heading => .{
            .kind = .text,
            .text = cl.text,
            .color = if (cl.heading_level <= 2) palette.strong else palette.normal,
            .line_h = switch (cl.heading_level) {
                1 => @round(base_h * 1.72),
                2 => @round(base_h * 1.45),
                3 => @round(base_h * 1.24),
                else => @round(base_h * 1.10),
            },
            .background = if (cl.heading_level <= 2) palette.heading_bg else null,
            .left_rule = if (cl.heading_level <= 2) palette.accent else null,
            .underline = cl.heading_level <= 2,
        },
        .quote => .{
            .kind = .text,
            .text = cl.text,
            .color = palette.muted,
            .indent = 16,
            .line_h = base_h,
            .background = palette.quote_bg,
            .left_rule = palette.accent,
        },
        .list => .{ .kind = .text, .text = cl.text, .color = palette.normal, .indent = 12, .line_h = base_h },
        .normal => .{ .kind = .text, .text = cl.text, .color = palette.normal, .line_h = base_h },
    };
}

fn renderMarkdownContent(
    text: []const u8,
    x: f32,
    top_px: f32,
    max_w: f32,
    window_height: f32,
    clip_bottom_top_px: f32,
    palette: MarkdownPalette,
    selection_range: ?ai_chat.TextSelectionRange,
) f32 {
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
        return renderWrappedText("", x, top_px, max_w, lineHeight(), palette.normal, window_height, clip_bottom_top_px);
    }

    var cursor: usize = 0;
    var current_top = top_px;
    var in_code = false;

    while (cursor < text.len) {
        if (!in_code and isMarkdownTableStart(text, cursor)) {
            const end = tableBlockEnd(text, cursor);
            current_top += renderTableBlock(text, cursor, end, x, current_top, max_w, window_height, palette);
            cursor = end;
            continue;
        }

        const line_start = cursor;
        const info = nextSourceLine(text, cursor);
        cursor = info.next;

        var clean_buf: [1024]u8 = undefined;
        const prepared = prepareMarkdownLine(&clean_buf, info.line, in_code, palette);
        switch (prepared.kind) {
            .blank => current_top += prepared.line_h,
            .fence => {
                renderMarkdownFence(prepared.fence_label, x, current_top, max_w, window_height, palette);
                current_top += prepared.line_h;
                in_code = !in_code;
            },
            .rule => {
                renderTopQuad(x, max_w, window_height, current_top + prepared.line_h * 0.42, 1, prepared.color);
                current_top += prepared.line_h;
            },
            .text => {
                const body_h = plainContentHeight(prepared.text, @max(1.0, max_w - prepared.indent), prepared.line_h);
                if (prepared.background) |bg_color| {
                    renderTopQuad(x - 8, max_w + 16, window_height, current_top, body_h, bg_color);
                }
                if (prepared.left_rule) |rule_color| {
                    renderTopQuad(x - 8, DETAIL_RULE_W, window_height, current_top, body_h, rule_color);
                }
                if (prepared.underline) {
                    renderTopQuad(x, max_w, window_height, current_top + body_h - 3, 1, mixColor(AppWindow.g_theme.background, AppWindow.g_theme.cursor_color, 0.32));
                }
                renderWrappedSelection(
                    info.line,
                    line_start,
                    x + prepared.indent,
                    current_top,
                    @max(1.0, max_w - prepared.indent),
                    prepared.line_h,
                    selection_range,
                    window_height,
                    clip_bottom_top_px,
                );
                current_top = renderWrappedText(
                    prepared.text,
                    x + prepared.indent,
                    current_top,
                    @max(1.0, max_w - prepared.indent),
                    prepared.line_h,
                    prepared.color,
                    window_height,
                    clip_bottom_top_px,
                );
            },
        }
    }

    return current_top - top_px;
}

fn byteOffsetForMarkdownPoint(
    text: []const u8,
    x: f32,
    top_px: f32,
    max_w: f32,
    px: f32,
    py: f32,
) usize {
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return 0;
    if (py <= top_px) return 0;

    const palette = markdownPalette(AppWindow.g_theme.background, AppWindow.g_theme.foreground, AppWindow.g_theme.cursor_color);
    var cursor: usize = 0;
    var display_cursor: usize = 0;
    var current_top = top_px;
    var in_code = false;

    while (cursor < text.len) {
        if (!in_code and isMarkdownTableStart(text, cursor)) {
            const start = cursor;
            const end = tableBlockEnd(text, cursor);
            const block_h = tableBlockHeight(text, cursor, end);
            if (py < current_top + block_h) {
                const row_h = tableRowHeight();
                const row_index: usize = @intFromFloat(@max(0.0, @floor((py - current_top) / row_h)));
                return display_cursor + md.tableRowDisplayOffsetWithin(text, start, end, row_index);
            }
            current_top += block_h;
            display_cursor += md.tableBlockDisplayLen(text, start, end);
            cursor = end;
            continue;
        }

        const info = nextSourceLine(text, cursor);
        cursor = info.next;

        var clean_buf: [1024]u8 = undefined;
        const prepared = prepareMarkdownLine(&clean_buf, info.line, in_code, palette);
        switch (prepared.kind) {
            .blank => {
                if (py < current_top + prepared.line_h) return display_cursor;
                current_top += prepared.line_h;
            },
            .fence => {
                if (py < current_top + prepared.line_h) return display_cursor;
                current_top += prepared.line_h;
                in_code = !in_code;
            },
            .rule => {
                if (py < current_top + prepared.line_h) return display_cursor;
                current_top += prepared.line_h;
            },
            .text => {
                const line_w = @max(1.0, max_w - prepared.indent);
                const body_h = plainContentHeight(prepared.text, line_w, prepared.line_h);
                if (py < current_top + body_h) {
                    return byteOffsetForWrappedPoint(
                        prepared.text,
                        display_cursor,
                        x + prepared.indent,
                        current_top,
                        line_w,
                        prepared.line_h,
                        px,
                        py,
                    );
                }
                current_top += body_h;
            },
        }
        display_cursor += prepared.text.len + 1;
    }

    return display_cursor;
}


fn byteOffsetForWrappedPoint(
    text: []const u8,
    base_offset: usize,
    x: f32,
    top_px: f32,
    max_w: f32,
    line_h: f32,
    px: f32,
    py: f32,
) usize {
    if (py <= top_px) return base_offset;
    var line_start: usize = 0;
    var line_width: f32 = 0;
    var i: usize = 0;
    var current_top = top_px;
    while (i < text.len) {
        if (text[i] == '\n') {
            if (py < current_top + line_h) return byteOffsetForLineX(text[line_start..i], base_offset + line_start, x, px);
            current_top += line_h;
            i += 1;
            line_start = i;
            line_width = 0;
            continue;
        }
        const item = nextCodepoint(text, i);
        if (line_width > 0 and line_width + item.advance > max_w) {
            if (py < current_top + line_h) return byteOffsetForLineX(text[line_start..i], base_offset + line_start, x, px);
            current_top += line_h;
            line_start = i;
            line_width = 0;
            continue;
        }
        line_width += item.advance;
        i += item.len;
    }
    if (py < current_top + line_h) return byteOffsetForLineX(text[line_start..i], base_offset + line_start, x, px);
    return base_offset + text.len;
}

fn byteOffsetForLineX(text: []const u8, base_offset: usize, x: f32, px: f32) usize {
    if (px <= x) return base_offset;
    var width: f32 = 0;
    var i: usize = 0;
    while (i < text.len) {
        const item = nextCodepoint(text, i);
        if (px < x + width + item.advance * 0.5) return base_offset + i;
        width += item.advance;
        i += item.len;
    }
    return base_offset + text.len;
}

fn renderMarkdownFence(label: []const u8, x: f32, top_px: f32, max_w: f32, window_height: f32, palette: MarkdownPalette) void {
    const mid_top = top_px + fenceLineHeight() * 0.55;
    renderTopQuad(x, max_w, window_height, mid_top, 1, palette.table_border);
    if (label.len > 0) {
        renderTextLine(label, x + 8, top_px, max_w - 16, palette.muted, window_height, window_height);
    }
}

fn tableBlockHeight(text: []const u8, start: usize, end: usize) f32 {
    var row_count: usize = 0;
    var cursor = start;
    while (cursor < end) {
        const info = nextSourceLine(text, cursor);
        cursor = info.next;
        if (isTableSeparatorLine(info.line)) continue;
        row_count += 1;
    }
    if (row_count == 0) return tableRowHeight();
    return @as(f32, @floatFromInt(row_count)) * tableRowHeight() + 1;
}

fn renderTableBlock(
    text: []const u8,
    start: usize,
    end: usize,
    x: f32,
    top_px: f32,
    max_w: f32,
    window_height: f32,
    palette: MarkdownPalette,
) f32 {
    var widths: [TABLE_MAX_COLS]f32 = .{0} ** TABLE_MAX_COLS;
    const col_count = measureTableColumns(text, start, end, max_w, &widths);
    if (col_count == 0) return 0;

    const table_w = tableUsedWidth(widths[0..col_count]);
    const row_h = tableRowHeight();
    const total_h = tableBlockHeight(text, start, end);
    const table_y = window_height - top_px - total_h;

    gl_init.renderQuadAlpha(x, table_y, table_w, total_h, palette.table_bg, 0.94);
    gl_init.renderQuadAlpha(x, table_y, DETAIL_RULE_W, total_h, palette.table_border, 0.85);
    gl_init.renderQuadAlpha(x, table_y, table_w, 1, palette.table_border, 0.85);
    gl_init.renderQuadAlpha(x, table_y + total_h - 1, table_w, 1, palette.table_border, 0.85);
    gl_init.renderQuadAlpha(x + table_w - 1, table_y, 1, total_h, palette.table_border, 0.85);

    var cursor = start;
    var row_index: usize = 0;
    while (cursor < end) {
        const info = nextSourceLine(text, cursor);
        cursor = info.next;
        if (isTableSeparatorLine(info.line)) continue;

        var cells: [TABLE_MAX_COLS][]const u8 = .{""} ** TABLE_MAX_COLS;
        const cell_count = parseTableRowCells(info.line, &cells);
        const row_top = top_px + @as(f32, @floatFromInt(row_index)) * row_h;
        const row_y = window_height - row_top - row_h;
        const row_bg = if (row_index == 0)
            mixColor(palette.table_bg, AppWindow.g_theme.cursor_color, 0.10)
        else if (row_index % 2 == 0)
            palette.table_bg
        else
            palette.table_alt;
        gl_init.renderQuadAlpha(x, row_y, table_w, row_h, row_bg, if (row_index == 0) 0.98 else 0.92);
        gl_init.renderQuadAlpha(x, row_y, table_w, 1, palette.table_border, 0.85);

        var cell_x = x + 1;
        for (0..col_count) |col| {
            if (col > 0) gl_init.renderQuadAlpha(cell_x - 1, row_y, 1, row_h, palette.table_border, 0.85);
            const text_w = widths[col];
            const cell_w = text_w + TABLE_CELL_PAD_X * 2 + 1;
            var clean_buf: [256]u8 = undefined;
            const cell_text = if (col < cell_count) cleanInline(&clean_buf, cells[col]) else "";
            _ = titlebar.renderTextLimited(
                cell_text,
                cell_x + TABLE_CELL_PAD_X,
                row_y + @round((row_h - font.g_titlebar_cell_height) / 2),
                if (row_index == 0) palette.strong else palette.normal,
                text_w,
            );
            cell_x += cell_w;
        }

        row_index += 1;
    }

    return total_h;
}

fn measureTableColumns(text: []const u8, start: usize, end: usize, max_w: f32, widths: *[TABLE_MAX_COLS]f32) usize {
    @memset(widths, 0);
    var col_count: usize = 0;
    var cursor = start;
    while (cursor < end) {
        const info = nextSourceLine(text, cursor);
        cursor = info.next;
        if (isTableSeparatorLine(info.line)) continue;

        var cells: [TABLE_MAX_COLS][]const u8 = .{""} ** TABLE_MAX_COLS;
        const count = parseTableRowCells(info.line, &cells);
        col_count = @max(col_count, count);
        for (0..count) |i| {
            var clean_buf: [256]u8 = undefined;
            const cell_text = cleanInline(&clean_buf, cells[i]);
            widths[i] = @max(widths[i], measureText(cell_text));
        }
    }
    if (col_count == 0) return 0;

    var natural_content_w: f32 = 0;
    for (0..col_count) |i| {
        widths[i] = @max(widths[i], TABLE_MIN_COL_W);
        natural_content_w += widths[i];
    }

    const chrome = @as(f32, @floatFromInt(col_count)) * (TABLE_CELL_PAD_X * 2 + 1) + 1;
    if (natural_content_w + chrome > max_w) {
        const available = @max(24.0, (max_w - chrome) / @as(f32, @floatFromInt(col_count)));
        for (0..col_count) |i| widths[i] = available;
    }

    return col_count;
}

fn tableUsedWidth(widths: []const f32) f32 {
    var total: f32 = 1;
    for (widths) |w| total += w + TABLE_CELL_PAD_X * 2 + 1;
    return total;
}

fn renderWrappedSelection(
    text: []const u8,
    base_offset: usize,
    x: f32,
    top_px: f32,
    max_w: f32,
    line_h: f32,
    selection_range: ?ai_chat.TextSelectionRange,
    window_height: f32,
    clip_bottom_top_px: f32,
) void {
    const range = selection_range orelse return;
    if (range.start >= range.end) return;

    var line_start: usize = 0;
    var line_width: f32 = 0;
    var i: usize = 0;
    var current_top = top_px;
    while (i < text.len) {
        if (text[i] == '\n') {
            renderTextLineSelection(text[line_start..i], base_offset + line_start, x, current_top, line_h, range, window_height, clip_bottom_top_px);
            current_top += line_h;
            i += 1;
            line_start = i;
            line_width = 0;
            continue;
        }
        const item = nextCodepoint(text, i);
        if (line_width > 0 and line_width + item.advance > max_w) {
            renderTextLineSelection(text[line_start..i], base_offset + line_start, x, current_top, line_h, range, window_height, clip_bottom_top_px);
            current_top += line_h;
            line_start = i;
            line_width = 0;
            continue;
        }
        line_width += item.advance;
        i += item.len;
    }
    renderTextLineSelection(text[line_start..i], base_offset + line_start, x, current_top, line_h, range, window_height, clip_bottom_top_px);
}

fn renderTextLineSelection(
    text: []const u8,
    base_offset: usize,
    x: f32,
    top_px: f32,
    line_h: f32,
    range: ai_chat.TextSelectionRange,
    window_height: f32,
    clip_bottom_top_px: f32,
) void {
    if (top_px + line_h < 0 or top_px > clip_bottom_top_px) return;
    const line_end = base_offset + text.len;
    const start = @max(range.start, base_offset);
    const end = @min(range.end, line_end);
    if (start >= end) return;
    const local_start = start - base_offset;
    const local_end = end - base_offset;
    const prefix_w = measureText(text[0..local_start]);
    const selected_w = @max(1.0, measureText(text[local_start..local_end]));
    const selection_color = mixColor(AppWindow.g_theme.background, AppWindow.g_theme.cursor_color, 0.44);
    renderTopQuad(x + prefix_w, selected_w, window_height, top_px + @max(0.0, (line_h - font.g_titlebar_cell_height) * 0.5) - 1, @max(1.0, font.g_titlebar_cell_height + 3), selection_color);
}

fn renderWrappedText(
    text: []const u8,
    x: f32,
    top_px: f32,
    max_w: f32,
    line_h: f32,
    color: [3]f32,
    window_height: f32,
    clip_bottom_top_px: f32,
) f32 {
    var line_start: usize = 0;
    var line_width: f32 = 0;
    var i: usize = 0;
    var current_top = top_px;
    while (i < text.len) {
        if (text[i] == '\n') {
            renderTextLine(text[line_start..i], x, current_top, max_w, color, window_height, clip_bottom_top_px);
            current_top += line_h;
            i += 1;
            line_start = i;
            line_width = 0;
            continue;
        }
        const item = nextCodepoint(text, i);
        if (line_width > 0 and line_width + item.advance > max_w) {
            renderTextLine(text[line_start..i], x, current_top, max_w, color, window_height, clip_bottom_top_px);
            current_top += line_h;
            line_start = i;
            line_width = 0;
            continue;
        }
        line_width += item.advance;
        i += item.len;
    }
    renderTextLine(text[line_start..i], x, current_top, max_w, color, window_height, clip_bottom_top_px);
    return current_top + line_h;
}

fn renderTextLine(text: []const u8, x: f32, top_px: f32, max_w: f32, color: [3]f32, window_height: f32, clip_bottom_top_px: f32) void {
    if (top_px + lineHeight() < 0 or top_px > clip_bottom_top_px) return;
    const y = window_height - top_px - font.g_titlebar_cell_height;
    _ = titlebar.renderTextLimited(text, x, y, color, max_w);
}

fn renderTopQuad(x: f32, w: f32, window_height: f32, top_px: f32, h: f32, color: [3]f32) void {
    const y = window_height - top_px - h;
    gl_init.renderQuadAlpha(x, y, w, h, color, 0.96);
}

const CodepointItem = struct {
    len: usize,
    advance: f32,
};

fn nextCodepoint(text: []const u8, i: usize) CodepointItem {
    const first = text[i];
    const len = std.unicode.utf8ByteSequenceLength(first) catch 1;
    if (i + len > text.len) return .{ .len = 1, .advance = titlebar.titlebarGlyphAdvance('?') };
    const cp = std.unicode.utf8Decode(text[i .. i + len]) catch @as(u21, '?');
    return .{ .len = len, .advance = titlebar.titlebarGlyphAdvance(@intCast(cp)) };
}

fn countWrappedLines(text: []const u8, max_w: f32) usize {
    if (text.len == 0) return 1;
    var lines: usize = 1;
    var width: f32 = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\n') {
            lines += 1;
            width = 0;
            i += 1;
            continue;
        }
        const item = nextCodepoint(text, i);
        if (width > 0 and width + item.advance > max_w) {
            lines += 1;
            width = 0;
        }
        width += item.advance;
        i += item.len;
    }
    return lines;
}

pub fn inputLayout(panel_x: f32, panel_w: f32, text: []const u8) InputLayout {
    const field_w = composer_layout.fieldWidth(panel_w);
    const field_x = composer_layout.fieldX(panel_x, panel_w);
    const text_w = @max(1.0, composer_layout.textWidth(field_w) - INPUT_SCROLLBAR_GUTTER);
    const field_h = inputHeightForText(text, text_w) - composer_layout.Panel.pad_y * 2;
    return .{
        .input_h = field_h + composer_layout.Panel.pad_y * 2,
        .field_x = field_x,
        .field_y = composer_layout.Panel.pad_y,
        .field_w = field_w,
        .field_h = field_h,
        .text_x = field_x + composer_layout.Field.pad_x,
        .text_w = text_w,
    };
}

pub fn inputHeightForText(text: []const u8, max_w: f32) f32 {
    const rows = countWrappedLines(text, @max(1.0, max_w));
    return composer_layout.inputHeightForRows(rows, lineHeight());
}

pub fn inputVisibleRowsForField(field_h: f32) usize {
    return composer_layout.visibleRows(field_h, lineHeight());
}

pub fn inputWrapColumns(panel_w: f32) usize {
    const field_w = composer_layout.fieldWidth(panel_w);
    const text_w = composer_layout.textWidth(field_w);
    const cell_w = @max(@as(f32, 1.0), font.g_titlebar_cell_width);
    return @max(@as(usize, 1), @as(usize, @intFromFloat(@max(1.0, @floor(text_w / cell_w)))));
}

pub fn inputCursorRect(text: []const u8, cursor_raw: usize, x: f32, max_w_raw: f32) InputCursorRect {
    const max_w = @max(1.0, max_w_raw);
    const cursor = @min(cursor_raw, text.len);
    var width: f32 = 0;
    var row: usize = 0;
    var i: usize = 0;
    while (i < cursor) {
        if (text[i] == '\n') {
            row += 1;
            width = 0;
            i += 1;
            continue;
        }
        const item = nextCodepoint(text, i);
        if (width > 0 and width + item.advance > max_w) {
            row += 1;
            width = 0;
        }
        width += item.advance;
        i += item.len;
    }
    return .{ .x = x + width + 2, .row = row };
}

pub fn inputCursorX(text: []const u8, x: f32, max_w: f32) f32 {
    return inputCursorRect(text, text.len, x, max_w).x;
}

fn wrappedByteOffsetForLine(text: []const u8, max_w_raw: f32, target_row: usize) usize {
    if (target_row == 0) return 0;
    const max_w = @max(1.0, max_w_raw);
    var width: f32 = 0;
    var row: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\n') {
            row += 1;
            i += 1;
            width = 0;
            if (row == target_row) return i;
            continue;
        }
        const item = nextCodepoint(text, i);
        if (width > 0 and width + item.advance > max_w) {
            row += 1;
            width = 0;
            if (row == target_row) return i;
        }
        width += item.advance;
        i += item.len;
    }
    return text.len;
}

fn measureText(text: []const u8) f32 {
    var width: f32 = 0;
    var i: usize = 0;
    while (i < text.len) {
        const item = nextCodepoint(text, i);
        width += item.advance;
        i += item.len;
    }
    return width;
}

fn detailHeaderHeight() f32 {
    return @round(@max(34.0, font.g_titlebar_cell_height + 12.0));
}

fn reasoningLineHeight() f32 {
    return @round(@max(21.0, font.g_titlebar_cell_height + 6.0));
}

fn tableRowHeight() f32 {
    return @round(@max(28.0, font.g_titlebar_cell_height + 10.0));
}

fn blankLineHeight() f32 {
    return @round(@max(12.0, lineHeight() * 0.56));
}

fn fenceLineHeight() f32 {
    return @round(@max(16.0, lineHeight() * 0.72));
}

fn lineHeight() f32 {
    return @round(@max(23.0, font.g_titlebar_cell_height + 8.0));
}

fn mixColor(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    const clamped = @max(0.0, @min(1.0, t));
    return .{
        a[0] + (b[0] - a[0]) * clamped,
        a[1] + (b[1] - a[1]) * clamped,
        a[2] + (b[2] - a[2]) * clamped,
    };
}

