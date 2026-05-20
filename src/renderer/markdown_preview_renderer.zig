//! Renderer for the right-side Markdown/text preview panel.

const std = @import("std");
const AppWindow = @import("../AppWindow.zig");
const panel = @import("../markdown_preview_panel.zig");
const markdown_preview = @import("../markdown_preview.zig");
const ui_perf = @import("../ui_perf.zig");
const titlebar = AppWindow.titlebar;
const font = AppWindow.font;
const gl_init = AppWindow.gl_init;
const c = @cImport({
    @cInclude("glad/gl.h");
});

const FOOTER_HEIGHT: f32 = 44;
const PAD_X: f32 = 16;
const PAD_Y: f32 = 18;
const LINE_GAP: f32 = 6;
const MAX_RENDER_LINES: usize = 512;

fn blend(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    const clamped = @max(0.0, @min(1.0, t));
    return .{
        a[0] + (b[0] - a[0]) * clamped,
        a[1] + (b[1] - a[1]) * clamped,
        a[2] + (b[2] - a[2]) * clamped,
    };
}

pub fn render(window_width: f32, window_height: f32, titlebar_h: f32, right_offset: f32) void {
    if (!panel.g_visible) return;
    const perf = ui_perf.begin("markdown_preview_renderer.render");
    defer perf.end();

    const panel_w = panel.width();
    if (panel_w <= 0) return;

    const side_h = window_height - titlebar_h;
    if (side_h <= 0) return;

    const panel_x = window_width - right_offset - panel_w;

    const gl = AppWindow.gl;
    gl.UseProgram.?(gl_init.shader_program);
    gl.ActiveTexture.?(c.GL_TEXTURE0);
    gl.BindVertexArray.?(gl_init.vao);

    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const panel_bg = blend(bg, fg, 0.03);
    const card_bg = blend(bg, fg, 0.055);
    const code_bg = blend(bg, fg, 0.075);
    const border = blend(bg, .{ 0.0, 0.0, 0.0 }, 0.22);
    const muted = blend(bg, fg, 0.62);
    const normal = blend(bg, fg, 0.88);
    const strong = blend(bg, fg, 0.96);
    const resize_hovered = blk: {
        const win = AppWindow.g_window orelse break :blk false;
        if (win.mouse_x < 0 or win.mouse_y < 0) break :blk false;
        const mx: f32 = @floatFromInt(win.mouse_x);
        const my: f32 = @floatFromInt(win.mouse_y);
        const half_hit = panel.RESIZE_HIT_WIDTH / 2;
        break :blk mx >= panel_x - half_hit and mx <= panel_x + half_hit and my >= titlebar_h and my < window_height;
    };
    const edge_color = if (resize_hovered or AppWindow.input.g_markdown_preview_resize_dragging) blend(bg, accent, 0.38) else border;

    gl_init.renderQuad(panel_x, 0, panel_w, side_h, panel_bg);
    gl_init.renderQuad(panel_x, 0, if (resize_hovered or AppWindow.input.g_markdown_preview_resize_dragging) 2 else 1, side_h, edge_color);

    renderFooter(panel_x, panel_w, card_bg, border, muted, normal, accent);

    renderDocument(panel_x, panel_w, window_height, titlebar_h, normal, muted, strong, accent, code_bg, border);
}

fn renderFooter(
    panel_x: f32,
    panel_w: f32,
    card_bg: [3]f32,
    border: [3]f32,
    muted: [3]f32,
    normal: [3]f32,
    accent: [3]f32,
) void {
    gl_init.renderQuad(panel_x, 0, panel_w, FOOTER_HEIGHT, card_bg);
    gl_init.renderQuad(panel_x, FOOTER_HEIGHT - 1, panel_w, 1, border);

    const badge = switch (panel.g_kind) {
        .markdown => "MD",
        .text => "TXT",
    };
    const text_y = (FOOTER_HEIGHT - font.g_titlebar_cell_height) / 2;
    const badge_end = titlebar.renderTextLimited(badge, panel_x + PAD_X, text_y, accent, 40);
    const content_right = panel_x + panel_w - PAD_X;
    const title_x = badge_end + 10;
    const title_max_w = @max(40, @min(panel_w * 0.34, content_right - title_x));
    const title_end = titlebar.renderTextLimited(panel.title(), title_x, text_y, normal, title_max_w);

    var sep_x = title_end + 10;
    if (sep_x + 12 < content_right) {
        sep_x = titlebar.renderTextLimited("/", sep_x, text_y, muted, 12) + 8;
        _ = titlebar.renderTextLimited(panel.path(), sep_x, text_y, muted, content_right - sep_x);
    }
}

fn renderDocument(
    panel_x: f32,
    panel_w: f32,
    window_height: f32,
    titlebar_h: f32,
    normal: [3]f32,
    muted: [3]f32,
    strong: [3]f32,
    accent: [3]f32,
    code_bg: [3]f32,
    border: [3]f32,
) void {
    const body_top = titlebar_h + PAD_Y;
    const body_bottom = FOOTER_HEIGHT + PAD_Y;
    const body_h = window_height - body_top - body_bottom;
    if (body_h <= 0) return;

    const row_h = @max(22, font.g_titlebar_cell_height + LINE_GAP);
    var y_from_top: f32 = body_top - panel.g_scroll_offset;
    const max_w = panel_w - PAD_X * 2;

    var in_code = false;
    var rendered: usize = 0;
    var lines = std.mem.splitScalar(u8, panel.source(), '\n');
    while (lines.next()) |raw_line| {
        if (rendered >= MAX_RENDER_LINES) break;
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const consumed = renderMarkdownLine(
            panel_x + PAD_X,
            max_w,
            window_height,
            body_top,
            body_h,
            y_from_top,
            row_h,
            line,
            &in_code,
            normal,
            muted,
            strong,
            accent,
            code_bg,
            border,
        );
        y_from_top += consumed;
        rendered += 1;
        if (y_from_top > body_top + body_h + row_h * 4) break;
    }
}

fn renderMarkdownLine(
    x: f32,
    max_w: f32,
    window_height: f32,
    body_top: f32,
    body_h: f32,
    y_from_top: f32,
    row_h: f32,
    raw_line: []const u8,
    in_code: *bool,
    normal: [3]f32,
    muted: [3]f32,
    strong: [3]f32,
    accent: [3]f32,
    code_bg: [3]f32,
    border: [3]f32,
) f32 {
    const trimmed = std.mem.trimLeft(u8, raw_line, " \t");
    if (isFence(trimmed)) {
        in_code.* = !in_code.*;
        const line_y_top = y_from_top + row_h * 0.15;
        if (line_y_top + row_h >= body_top and line_y_top <= body_top + body_h) {
            const gl_y = window_height - line_y_top - row_h * 0.75;
            gl_init.renderQuad(x, gl_y, max_w, 1, border);
            const lang = fenceLanguage(trimmed);
            if (lang.len > 0 and in_code.*) {
                _ = titlebar.renderTextLimited(lang, x + 8, gl_y + 5, muted, max_w - 16);
            }
        }
        return row_h * 0.9;
    }

    if (trimmed.len == 0) return row_h * 0.65;

    var clean_buf: [1024]u8 = undefined;
    var text = cleanInline(&clean_buf, trimmed);
    var color = normal;
    var indent: f32 = 0;
    var line_h = row_h;
    var bg: ?[3]f32 = null;
    var left_rule: ?[3]f32 = null;
    var underline = false;

    if (panel.g_kind == .text) {
        text = cleanPlain(&clean_buf, raw_line);
    } else if (in_code.*) {
        color = accent;
        text = cleanPlain(&clean_buf, raw_line);
        bg = code_bg;
        left_rule = accent;
    } else if (headingBody(trimmed)) |heading| {
        text = cleanInline(&clean_buf, heading.body);
        color = if (heading.level <= 2) strong else normal;
        line_h = switch (heading.level) {
            1 => row_h * 1.85,
            2 => row_h * 1.55,
            3 => row_h * 1.35,
            else => row_h * 1.18,
        };
        if (heading.level <= 2) {
            bg = blend(AppWindow.g_theme.background, accent, 0.08);
            left_rule = accent;
            underline = true;
        }
    } else if (htmlHeadingBody(trimmed)) |heading| {
        text = cleanInline(&clean_buf, heading.body);
        color = if (heading.level <= 2) strong else normal;
        line_h = switch (heading.level) {
            1 => row_h * 1.85,
            2 => row_h * 1.55,
            3 => row_h * 1.35,
            else => row_h * 1.18,
        };
        if (heading.level <= 2) {
            bg = blend(AppWindow.g_theme.background, accent, 0.08);
            left_rule = accent;
            underline = true;
        }
    } else if (std.mem.startsWith(u8, trimmed, ">")) {
        color = muted;
        indent = 18;
        left_rule = accent;
        text = cleanInline(&clean_buf, std.mem.trimLeft(u8, trimmed[1..], " \t"));
    } else if (isHorizontalRule(trimmed)) {
        const line_y_top = y_from_top + row_h * 0.5;
        if (line_y_top >= body_top and line_y_top <= body_top + body_h) {
            const gl_y = window_height - line_y_top - 1;
            gl_init.renderQuad(x, gl_y, max_w, 1, muted);
        }
        return row_h;
    } else if (listBody(trimmed)) |list| {
        color = normal;
        indent = 20;
        const body = cleanInline(&clean_buf, list.body);
        if (body.len + 2 <= clean_buf.len) {
            std.mem.copyBackwards(u8, clean_buf[2 .. body.len + 2], body);
            clean_buf[0] = bulletForList(list);
            clean_buf[1] = ' ';
            text = clean_buf[0 .. body.len + 2];
        } else {
            text = body;
        }
    }

    if (bg) |bg_color| {
        renderTopQuad(x - 8, max_w + 16, window_height, body_top, body_h, y_from_top, line_h, bg_color);
    }
    if (left_rule) |rule_color| {
        renderTopQuad(x - 8, 2, window_height, body_top, body_h, y_from_top + 3, @max(1, line_h - 6), rule_color);
    }
    if (underline) {
        const line_y_top = y_from_top + line_h - 4;
        if (line_y_top >= body_top and line_y_top <= body_top + body_h) {
            const gl_y = window_height - line_y_top - 1;
            gl_init.renderQuad(x, gl_y, max_w, 1, blend(AppWindow.g_theme.background, accent, 0.32));
        }
    }

    return renderWrappedText(
        x + indent,
        max_w - indent,
        window_height,
        body_top,
        body_h,
        y_from_top,
        line_h,
        text,
        color,
    );
}

fn renderWrappedText(
    x: f32,
    max_w: f32,
    window_height: f32,
    body_top: f32,
    body_h: f32,
    y_from_top: f32,
    row_h: f32,
    text: []const u8,
    color: [3]f32,
) f32 {
    if (text.len == 0) return row_h;
    const chars_per_line = @max(@as(usize, 8), @as(usize, @intFromFloat(max_w / @max(font.g_titlebar_cell_width, 1))));
    var offset: usize = 0;
    var consumed: f32 = 0;
    while (offset < text.len) {
        const end = wrapEnd(text, offset, chars_per_line);
        const line_y_top = y_from_top + consumed;
        if (line_y_top + row_h >= body_top and line_y_top <= body_top + body_h) {
            const gl_y = window_height - line_y_top - row_h;
            _ = titlebar.renderTextLimited(text[offset..end], x, gl_y + (row_h - font.g_titlebar_cell_height) / 2, color, max_w);
        }
        consumed += row_h;
        offset = skipSpaces(text, end);
    }
    return consumed;
}

fn renderTopQuad(
    x: f32,
    w: f32,
    window_height: f32,
    body_top: f32,
    body_h: f32,
    y_from_top: f32,
    h: f32,
    color: [3]f32,
) void {
    const top = @max(y_from_top, body_top);
    const bottom = @min(y_from_top + h, body_top + body_h);
    if (bottom <= top) return;
    const gl_y = window_height - bottom;
    gl_init.renderQuad(x, gl_y, w, bottom - top, color);
}

fn wrapEnd(text: []const u8, start: usize, max_chars: usize) usize {
    const end = @min(text.len, start + max_chars);
    if (end >= text.len) return text.len;
    var i = end;
    while (i > start) : (i -= 1) {
        if (text[i - 1] == ' ' or text[i - 1] == '\t') return i - 1;
    }
    return end;
}

fn skipSpaces(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) : (i += 1) {}
    return i;
}

const Heading = struct { level: usize, body: []const u8 };
const List = struct { body: []const u8 };

fn headingBody(line: []const u8) ?Heading {
    var level: usize = 0;
    while (level < line.len and line[level] == '#' and level < 6) : (level += 1) {}
    if (level == 0 or level >= line.len or line[level] != ' ') return null;
    return .{ .level = level, .body = std.mem.trimLeft(u8, line[level + 1 ..], " \t") };
}

fn htmlHeadingBody(line: []const u8) ?Heading {
    if (line.len < 4 or line[0] != '<' or (line[1] != 'h' and line[1] != 'H')) return null;
    const level_ch = line[2];
    if (level_ch < '1' or level_ch > '6') return null;
    const open_end = std.mem.indexOfScalar(u8, line, '>') orelse return null;
    const close_start = std.mem.indexOf(u8, line[open_end + 1 ..], "</") orelse line.len - (open_end + 1);
    const body = line[open_end + 1 .. open_end + 1 + close_start];
    return .{ .level = @intCast(level_ch - '0'), .body = body };
}

fn isFence(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "```") or std.mem.startsWith(u8, line, "~~~");
}

fn fenceLanguage(line: []const u8) []const u8 {
    if (!isFence(line) or line.len <= 3) return "";
    return std.mem.trim(u8, line[3..], " \t");
}

fn isHorizontalRule(line: []const u8) bool {
    var marker: u8 = 0;
    var count: usize = 0;
    for (line) |ch| {
        if (ch == ' ' or ch == '\t') continue;
        if (ch != '-' and ch != '*' and ch != '_') return false;
        if (marker == 0) marker = ch;
        if (ch != marker) return false;
        count += 1;
    }
    return count >= 3;
}

fn listBody(line: []const u8) ?List {
    if (line.len >= 2 and (line[0] == '-' or line[0] == '*' or line[0] == '+') and isSpace(line[1])) {
        return .{ .body = std.mem.trimLeft(u8, line[2..], " \t") };
    }
    var i: usize = 0;
    while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) {}
    if (i > 0 and i + 1 < line.len and (line[i] == '.' or line[i] == ')') and isSpace(line[i + 1])) {
        return .{ .body = std.mem.trimLeft(u8, line[i + 2 ..], " \t") };
    }
    return null;
}

fn bulletForList(_: List) u8 {
    return '-';
}

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t';
}

fn cleanPlain(buf: *[1024]u8, text: []const u8) []const u8 {
    var pos: usize = 0;
    for (text) |ch| {
        if (pos >= buf.len) break;
        if (ch == '\r' or ch == '\n' or ch == 0x1b) continue;
        buf[pos] = ch;
        pos += 1;
    }
    return std.mem.trim(u8, buf[0..pos], " \t");
}

fn cleanInline(buf: *[1024]u8, text: []const u8) []const u8 {
    var pos: usize = 0;
    var i: usize = 0;
    while (i < text.len and pos < buf.len) {
        const ch = text[i];
        if (ch == '<') {
            while (i < text.len and text[i] != '>') : (i += 1) {}
            if (i < text.len) i += 1;
            continue;
        }
        if (ch == '[') {
            if (parseMarkdownLink(text, i)) |link| {
                pos = appendSlice(buf, pos, link.label);
                i = link.end;
                continue;
            }
        }
        if (ch == '!' and i + 1 < text.len and text[i + 1] == '[') {
            if (parseMarkdownLink(text, i + 1)) |link| {
                pos = appendSlice(buf, pos, link.label);
                i = link.end;
                continue;
            }
        }
        if (ch == '*' or ch == '_' or ch == '`' or ch == '\r' or ch == '\n' or ch == 0x1b) {
            i += 1;
            continue;
        }
        buf[pos] = ch;
        pos += 1;
        i += 1;
    }
    return std.mem.trim(u8, buf[0..pos], " \t");
}

const Link = struct { label: []const u8, end: usize };

fn parseMarkdownLink(text: []const u8, bracket: usize) ?Link {
    const close_rel = std.mem.indexOfScalar(u8, text[bracket + 1 ..], ']') orelse return null;
    const close = bracket + 1 + close_rel;
    if (close + 1 >= text.len or text[close + 1] != '(') return null;
    const url_start = close + 2;
    const url_rel = std.mem.indexOfScalar(u8, text[url_start..], ')') orelse return null;
    return .{ .label = text[bracket + 1 .. close], .end = url_start + url_rel + 1 };
}

fn appendSlice(buf: *[1024]u8, pos: usize, text: []const u8) usize {
    const len = @min(text.len, buf.len - pos);
    @memcpy(buf[pos..][0..len], text[0..len]);
    return pos + len;
}
