//! Native renderer for AI Chat sessions.

const std = @import("std");
const AppWindow = @import("../AppWindow.zig");
const ai_chat = @import("../ai_chat.zig");
const font = AppWindow.font;
const gl_init = AppWindow.gl_init;
const titlebar = AppWindow.titlebar;

const c = @cImport({
    @cInclude("glad/gl.h");
});

pub const LINE_PAD_X: f32 = 18;
const HEADER_H: f32 = 54;
pub const INPUT_H: f32 = 92;
const PERMISSION_CHIP_W: f32 = 112;
const PERMISSION_CHIP_H: f32 = 24;
const STATUS_SLOT_W: f32 = 92;
const BUBBLE_PAD_X: f32 = 14;
const BUBBLE_PAD_Y: f32 = 10;
const BUBBLE_GAP: f32 = 12;
const APPROVAL_H: f32 = 128;
const APPROVAL_GAP: f32 = 12;
const REASONING_PAD_Y: f32 = 6;
const REASONING_LEFT: f32 = 22;
const REASONING_RIGHT: f32 = 12;
const REASONING_LINE_SCALE: f32 = 0.95;

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
    const bottom: f32 = 0;
    const h = @round(@max(1.0, window_height - top));
    if (w <= 1 or h <= 1) return;

    gl_init.renderQuad(x, bottom, w, h, bg);

    session.mutex.lock();
    defer session.mutex.unlock();

    const header_y = window_height - top - HEADER_H;
    gl_init.renderQuadAlpha(x, header_y, w, HEADER_H, panel, 0.95);
    gl_init.renderQuadAlpha(x, header_y, w, 1, line, 0.8);
    _ = titlebar.renderTextLimited(session.title(), x + LINE_PAD_X, header_y + 10, mixColor(fg, accent, 0.12), w * 0.45);

    var meta_buf: [256]u8 = undefined;
    const mode = if (session.agent_enabled) "Agent" else "Chat";
    const meta = std.fmt.bufPrint(&meta_buf, "{s}  {s}", .{ session.model(), mode }) catch session.model();
    const meta_w = measureText(meta);
    const permission = ai_chat.agentPermission();
    const chip_x = permissionChipX(x, w);
    const meta_right = chip_x - 10;
    const meta_limit = @max(80.0, meta_right - (x + LINE_PAD_X + w * 0.28));
    _ = titlebar.renderTextLimited(meta, meta_right - @min(meta_w, meta_limit), header_y + 10, muted, meta_limit);

    var perm_buf: [48]u8 = undefined;
    const perm_text = std.fmt.bufPrint(&perm_buf, "perm: {s}", .{permission.name()}) catch permission.name();
    const perm_color = if (permission == .full) mixColor(fg, accent, 0.25) else mixColor(bg, fg, 0.66);
    _ = titlebar.renderTextLimited(perm_text, chip_x, header_y + 10, perm_color, PERMISSION_CHIP_W);
    gl_init.renderQuadAlpha(chip_x, header_y + 8, PERMISSION_CHIP_W - 10, 1, accent, if (permission == .full) 0.38 else 0.16);

    const status_w = measureText(session.status());
    const status_limit = STATUS_SLOT_W;
    _ = titlebar.renderTextLimited(session.status(), x + w - LINE_PAD_X - @min(status_w, status_limit), header_y + 10, muted, status_limit);

    const input_y: f32 = 0;
    gl_init.renderQuadAlpha(x, input_y, w, INPUT_H, panel, 0.98);
    gl_init.renderQuadAlpha(x, input_y + INPUT_H - 1, w, 1, line, 0.8);

    const field_x = x + LINE_PAD_X;
    const field_y = input_y + 16;
    const field_w = w - LINE_PAD_X * 2;
    const field_h = INPUT_H - 32;
    const field_bg = mixColor(bg, fg, 0.075);
    gl_init.renderQuadAlpha(field_x, field_y, field_w, field_h, field_bg, 0.95);
    gl_init.renderQuadAlpha(field_x, field_y, field_w, 1, mixColor(bg, accent, 0.38), 0.6);

    const input_text = session.input();
    if (input_text.len == 0) {
        const placeholder = if (session.agent_enabled) "Ask Agent" else "Ask AI Chat";
        _ = titlebar.renderTextLimited(placeholder, field_x + 12, field_y + (field_h - font.g_titlebar_cell_height) / 2, mixColor(bg, fg, 0.42), field_w - 24);
    } else {
        _ = renderWrappedText(input_text, field_x + 12, window_height - field_y - field_h + 10, field_w - 24, lineHeight(), fg, window_height, window_height);
    }
    if (!session.request_inflight and AppWindow.g_cursor_blink_visible) {
        const cursor_x = inputCursorX(input_text, field_x + 12, field_w - 24);
        gl_init.renderQuad(cursor_x, field_y + 14, 1, field_h - 28, accent);
    }

    const approval = session.approvalView();
    const approval_h: f32 = if (approval != null) APPROVAL_H + APPROVAL_GAP else 0;

    const transcript_top = top + HEADER_H + 18;
    const transcript_bottom = INPUT_H + approval_h + 18;
    const transcript_h = @max(1.0, window_height - transcript_top - transcript_bottom);
    const content_w = w - LINE_PAD_X * 2;
    const content_x = x + LINE_PAD_X;

    var content_h: f32 = 0;
    for (session.messages.items) |msg| {
        content_h += messageHeight(msg.content, content_w);
        if (msg.reasoning) |reasoning| content_h += reasoningHeight(reasoning, content_w);
        content_h += BUBBLE_GAP;
    }
    const max_scroll = @max(0.0, content_h - transcript_h);
    session.scroll_px = @min(session.scroll_px, max_scroll);

    const scissor_y: c.GLint = @intFromFloat(@round(transcript_bottom));
    const scissor_h: c.GLsizei = @intFromFloat(@round(transcript_h));
    gl.Enable.?(c.GL_SCISSOR_TEST);
    gl.Scissor.?(
        @intFromFloat(@round(x)),
        scissor_y,
        @intFromFloat(@round(w)),
        scissor_h,
    );

    const gravity_offset = @max(0.0, transcript_h - content_h);
    var cursor_top = transcript_top + gravity_offset - session.scroll_px;
    for (session.messages.items) |msg| {
        const bubble_h = messageHeight(msg.content, content_w);
        const visible = cursor_top + bubble_h >= transcript_top and cursor_top <= window_height - transcript_bottom;
        if (visible) {
            renderMessageBubble(
                msg.role,
                msg.content,
                content_x,
                cursor_top,
                content_w,
                bubble_h,
                window_height,
            );
        }
        cursor_top += bubble_h;
        if (msg.reasoning) |reasoning| {
            const r_h = reasoningHeight(reasoning, content_w);
            const reasoning_visible = cursor_top + r_h >= transcript_top and cursor_top <= window_height - transcript_bottom;
            if (reasoning_visible and reasoning.len > 0) {
                renderReasoning(reasoning, content_x, cursor_top, content_w, r_h, window_height);
            }
            cursor_top += r_h;
        }
        cursor_top += BUBBLE_GAP;
    }

    gl.Disable.?(c.GL_SCISSOR_TEST);

    if (approval) |view| {
        renderApprovalCard(view, x + LINE_PAD_X, INPUT_H + APPROVAL_GAP, w - LINE_PAD_X * 2, APPROVAL_H);
    }
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
    const chip_top = titlebar_offset + 12;
    const px: f32 = @floatCast(xpos);
    const py: f32 = @floatCast(ypos);
    return px >= chip_x and px <= chip_x + PERMISSION_CHIP_W and
        py >= chip_top and py <= chip_top + PERMISSION_CHIP_H;
}

fn permissionChipX(x: f32, w: f32) f32 {
    return x + w - LINE_PAD_X - STATUS_SLOT_W - PERMISSION_CHIP_W;
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

fn renderMessageBubble(role: ai_chat.Role, text: []const u8, x: f32, top_px: f32, w: f32, h: f32, window_height: f32) void {
    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const is_user = role == .user;
    const bubble_w = @min(w, if (is_user) w * 0.82 else w);
    const bubble_x = if (is_user) x + w - bubble_w else x;
    const bubble_y = window_height - top_px - h;
    const bubble_bg = if (is_user) mixColor(bg, accent, 0.20) else mixColor(bg, fg, 0.07);
    gl_init.renderQuadAlpha(bubble_x, bubble_y, bubble_w, h, bubble_bg, 0.92);
    gl_init.renderQuadAlpha(bubble_x, bubble_y + h - 1, bubble_w, 1, if (is_user) accent else mixColor(bg, fg, 0.18), 0.55);

    const label_color = if (is_user) mixColor(fg, accent, 0.18) else mixColor(fg, accent, 0.05);
    _ = titlebar.renderTextLimited(role.label(), bubble_x + BUBBLE_PAD_X, bubble_y + h - BUBBLE_PAD_Y - font.g_titlebar_cell_height, label_color, bubble_w - BUBBLE_PAD_X * 2);
    _ = renderWrappedText(
        text,
        bubble_x + BUBBLE_PAD_X,
        top_px + BUBBLE_PAD_Y + lineHeight(),
        bubble_w - BUBBLE_PAD_X * 2,
        lineHeight(),
        fg,
        window_height,
        window_height,
    );
}

fn renderReasoning(text: []const u8, x: f32, top_px: f32, w: f32, h: f32, window_height: f32) void {
    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const y = window_height - top_px - h;
    gl_init.renderQuadAlpha(x, y, w, h, mixColor(bg, fg, 0.04), 0.85);
    gl_init.renderQuadAlpha(x + 8, y, 3, h, accent, 0.32);
    _ = renderWrappedText(text, x + REASONING_LEFT, top_px + REASONING_PAD_Y, w - REASONING_LEFT - REASONING_RIGHT, lineHeight() * REASONING_LINE_SCALE, mixColor(bg, fg, 0.58), window_height, window_height);
}

fn messageHeight(text: []const u8, max_w: f32) f32 {
    const wrapped = countWrappedLines(text, max_w - BUBBLE_PAD_X * 2);
    return BUBBLE_PAD_Y * 2 + lineHeight() + @as(f32, @floatFromInt(@max(1, wrapped))) * lineHeight();
}

fn reasoningHeight(text: []const u8, max_w: f32) f32 {
    const text_w = max_w - REASONING_LEFT - REASONING_RIGHT;
    const lines = countWrappedLines(text, text_w);
    const lh = lineHeight() * REASONING_LINE_SCALE;
    return REASONING_PAD_Y * 2 + @as(f32, @floatFromInt(@max(1, lines))) * lh;
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

pub fn inputCursorX(text: []const u8, x: f32, max_w: f32) f32 {
    var width: f32 = 0;
    var i: usize = 0;
    while (i < text.len) {
        const item = nextCodepoint(text, i);
        if (width + item.advance > max_w) break;
        width += item.advance;
        i += item.len;
    }
    return x + width + 2;
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
