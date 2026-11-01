//! Feature-owned renderer for the Password Store workbench. It reuses the
//! Settings page geometry (left rail + aligned rows + footer band) so the two
//! pages read as one family; the rail lists vault entries instead of
//! categories. Never reaches back into AppWindow or vault I/O.

const std = @import("std");
const i18n = @import("../i18n.zig");
const page = @import("../credential/page.zig");
const store = @import("../credential/store.zig");
const settings_layout = @import("overlays/settings_page_layout.zig");
const ui_patterns = @import("ui_patterns.zig");

pub const DrawContext = struct {
    bg: [3]f32,
    fg: [3]f32,
    accent: [3]f32,
    cell_h: f32,
    fillQuadAlpha: *const fn (f32, f32, f32, f32, [3]f32, f32) void,
    roundedQuadAlpha: *const fn (f32, f32, f32, f32, f32, [3]f32, f32) void,
    renderTextLimited: *const fn ([]const u8, f32, f32, [3]f32, f32) f32,
    glyphAdvance: *const fn (u32) f32,
};

pub const Geometry = struct {
    layout: settings_layout.Layout,
    /// First rail index drawn; the rail follows the selection when it overflows.
    rail_start: usize,
};

pub const Hit = union(enum) {
    none,
    rail: usize,
    row: page.Row,
};

pub fn compute(state: *const page.State, window_height: f32, top_offset: f32, content_x: f32, content_width: f32, cell_h: f32) Geometry {
    var layout = settings_layout.compute(.{
        .window_height = window_height,
        .top_offset = top_offset,
        .content_x = content_x,
        .content_width = content_width,
        .cell_height = cell_h,
        .focus_index = @intFromEnum(state.row),
        .row_count = if (state.current() != null) page.ROWS.len else 0,
        .category_count = 0,
    });
    const footer_h = ui_patterns.workbenchFooterHeight(cell_h);
    const footer_top = ui_patterns.workbenchFooterTop(window_height, top_offset, footer_h);
    const room = @max(layout.nav_item_h, footer_top - layout.nav_item_top_px);
    const capacity: usize = @intFromFloat(@max(1.0, @floor(room / layout.nav_item_h)));
    const total = state.railCount();
    layout.category_count = @min(total, capacity);
    const start = if (state.selected < capacity) 0 else state.selected - capacity + 1;
    return .{ .layout = layout, .rail_start = start };
}

pub fn hitTest(geo: Geometry, x: f32, y: f32) Hit {
    if (geo.layout.categoryAt(x, y)) |i| return .{ .rail = geo.rail_start + i };
    if (geo.layout.rowAt(x, y)) |r| return .{ .row = page.ROWS[r] };
    return .none;
}

pub fn overRail(geo: Geometry, x: f32) bool {
    return x < geo.layout.page_x + geo.layout.nav_w;
}

pub fn render(draw: DrawContext, state: *const page.State, geo: Geometry, window_height: f32) void {
    const layout = geo.layout;
    const page_y = @round(window_height - layout.page_top_px - layout.page_h);
    const border = mixColor(draw.bg, draw.fg, 0.16);
    const muted = mixColor(draw.bg, draw.fg, 0.58);
    const title_color = mixColor(draw.fg, draw.accent, 0.10);

    draw.fillQuadAlpha(layout.page_x, page_y, layout.page_w, layout.page_h, mixColor(draw.bg, draw.fg, 0.012), 1.0);
    draw.fillQuadAlpha(layout.page_x, page_y, layout.nav_w, layout.page_h, mixColor(draw.bg, draw.fg, 0.025), 0.96);
    draw.fillQuadAlpha(layout.page_x + layout.nav_w - 1, page_y, 1, layout.page_h, border, 0.72);

    renderRail(draw, state, geo, window_height, muted, title_color);

    const entry = state.current();
    var subtitle_buf: [160]u8 = undefined;
    const heading: []const u8 = if (entry) |e| e.name else if (state.vault == null) tr("Password store unavailable", "密码库不可用") else tr("New entry", "新建条目");
    const subtitle: []const u8 = if (entry) |e| entrySubtitle(e, &subtitle_buf) else if (state.vault == null)
        tr("The passwords file could not be read; it is left untouched. Fix or move it, then reopen this page.", "无法读取密码库文件，已保持原样未改动。修复或移走该文件后重新打开本页。")
    else if (state.entries().len == 0)
        tr("No passwords yet. Press Enter or click New entry to add the first one; it is encrypted on this machine.", "还没有密码。按 Enter 或点击左侧“新建条目”添加第一个，密码会在本机加密保存。")
    else
        tr("Press Enter to add an entry.", "按 Enter 新建一个条目。");
    _ = draw.renderTextLimited(heading, layout.content_x, textYFromTop(draw, window_height, layout.page_top_px + 28), title_color, layout.content_w);
    _ = draw.renderTextLimited(subtitle, layout.content_x, textYFromTop(draw, window_height, layout.page_top_px + 28 + lineHeight(draw)), muted, layout.content_w);
    draw.fillQuadAlpha(layout.content_x, @round(window_height - layout.row_top_px), layout.content_w, 1, border, 0.52);

    if (entry) |e| {
        for (page.ROWS, 0..) |row, row_index| {
            renderRow(draw, state, e, layout, window_height, row, row_index);
        }
        renderScrollbar(draw, layout, window_height, page.ROWS.len);
    }
    renderFooter(draw, state, layout, window_height, muted, border);
}

fn renderRail(draw: DrawContext, state: *const page.State, geo: Geometry, window_height: f32, muted: [3]f32, title_color: [3]f32) void {
    const layout = geo.layout;
    _ = draw.renderTextLimited(i18n.s().password_store_title, layout.page_x + 24, textYFromTop(draw, window_height, layout.nav_title_top_px), title_color, layout.nav_w - 48);
    var count_buf: [48]u8 = undefined;
    const count = state.entries().len;
    const count_label = (if (i18n.lang() == .zh_CN) std.fmt.bufPrint(&count_buf, "{d} 个条目 · 已加密", .{count}) else std.fmt.bufPrint(&count_buf, "{d} ENTRIES · ENCRYPTED", .{count})) catch "";
    _ = draw.renderTextLimited(count_label, layout.page_x + 24, textYFromTop(draw, window_height, layout.nav_label_top_px), muted, layout.nav_w - 48);

    const entries = state.entries();
    for (0..layout.category_count) |slot| {
        const index = geo.rail_start + slot;
        const item_top = layout.nav_item_top_px + layout.nav_item_h * @as(f32, @floatFromInt(slot));
        const item_y = @round(window_height - item_top - layout.nav_item_h);
        const selected = index == state.selected;
        if (selected) draw.fillQuadAlpha(layout.page_x + 14, item_y + 10, 3, layout.nav_item_h - 20, draw.accent, if (state.focus == .list) 0.84 else 0.38);
        const is_new = index >= entries.len;
        const label = if (is_new) tr("+ New entry", "+ 新建条目") else entries[index].name;
        const color = if (selected) mixColor(draw.fg, draw.accent, 0.16) else if (is_new) mixColor(draw.bg, draw.accent, 0.80) else mixColor(draw.bg, draw.fg, 0.76);
        _ = draw.renderTextLimited(label, layout.page_x + 28, rowTextY(draw, item_y, layout.nav_item_h), color, layout.nav_w - 48);
    }
}

fn entrySubtitle(entry: *const store.Entry, buf: []u8) []const u8 {
    const access = if (entry.agent)
        tr("Agent may request it — you approve each read", "Agent 可申请读取 · 每次都需你批准")
    else
        tr("Hidden from the agent", "Agent 不可读取");
    if (entry.note.len == 0) return access;
    return std.fmt.bufPrint(buf, "{s}  ·  {s}", .{ entry.note, access }) catch access;
}

const ControlKind = enum { text, toggle, action };

fn controlKind(row: page.Row) ControlKind {
    return switch (row) {
        .name, .username, .secret, .note => .text,
        .reveal, .agent => .toggle,
        .copy, .delete => .action,
    };
}

fn renderRow(draw: DrawContext, state: *const page.State, entry: *const store.Entry, layout: settings_layout.Layout, window_height: f32, row: page.Row, row_index: usize) void {
    const visible = layout.visibleRow(window_height, row_index) orelse return;
    const x = layout.content_x;
    const w = layout.content_w;
    const title_x = x + 20;
    const right_edge = x + w - 18;
    const selected = state.focus == .detail and state.row == row;
    const editing = state.editing and state.row == row;

    if (selected) draw.fillQuadAlpha(x + 2, visible.gl_y + 8, 3, layout.row_h - 16, draw.accent, 0.82);
    if (editing) draw.fillQuadAlpha(x + 8, visible.gl_y + 6, w - 16, layout.row_h - 12, mixColor(draw.bg, draw.accent, 0.10), 0.80);

    var value_buf: [512]u8 = undefined;
    const kind = controlKind(row);
    const value = rowValue(state, entry, row, editing, &value_buf);
    const control_h = if (kind == .toggle) 24.0 else @round(@max(32.0, draw.cell_h + 10.0));
    const pill_y = textYFromTop(draw, window_height, visible.top_px + 10) - @round((control_h - draw.cell_h) / 2);
    var title_max_w = w - 40;
    if (kind == .toggle) {
        const on = if (row == .reveal) state.revealed() else entry.agent;
        const value_w: f32 = 46;
        const value_x = @round(right_edge - value_w);
        draw.roundedQuadAlpha(value_x, pill_y, value_w, control_h, control_h / 2, if (on) mixColor(draw.bg, draw.accent, 0.40) else mixColor(draw.bg, draw.fg, 0.18), 0.96);
        const knob_d = control_h - 6;
        const knob_x = if (on) value_x + value_w - knob_d - 3 else value_x + 3;
        draw.roundedQuadAlpha(knob_x, pill_y + 3, knob_d, knob_d, knob_d / 2, if (on) draw.accent else mixColor(draw.bg, draw.fg, 0.42), 0.96);
        title_max_w = @max(1.0, value_x - title_x - 18);
    } else {
        const max_value_w: f32 = if (kind == .text) @max(180.0, w * 0.45) else 220;
        const desired_w = @min(max_value_w, @max(96.0, measure(draw, value) + 24));
        const value_w = ui_patterns.textColumns(right_edge - title_x, measure(draw, rowTitle(row)), desired_w, 18).right_w;
        const value_x = @round(right_edge - value_w);
        const danger = row == .delete and state.confirm_delete;
        const value_color = if (danger) dangerColor() else if (selected or editing) draw.accent else mixColor(draw.bg, draw.fg, 0.82);
        _ = draw.renderTextLimited(value, value_x, rowTextY(draw, pill_y, control_h), value_color, value_w);
        title_max_w = @max(1.0, value_x - title_x - 18);
    }

    if (visible.visible_index > 0) draw.fillQuadAlpha(x + 18, visible.gl_y + layout.row_h - 1, w - 36, 1, mixColor(draw.bg, draw.fg, 0.14), 0.62);
    const title_y = textYFromTop(draw, window_height, visible.top_px + 10);
    const detail_y = textYFromTop(draw, window_height, visible.top_px + 10 + lineHeight(draw));
    _ = draw.renderTextLimited(rowTitle(row), title_x, title_y, if (selected) mixColor(draw.fg, draw.accent, 0.16) else draw.fg, title_max_w);
    _ = draw.renderTextLimited(rowDescription(row), title_x, detail_y, mixColor(draw.bg, draw.fg, 0.56), @max(0, right_edge - title_x));
}

const BULLETS = "••••••••";

/// The text shown in a row's value slot. A password is bullets unless "Show
/// password" is on; a password being typed is bullets of its typed length.
pub fn rowValue(state: *const page.State, entry: *const store.Entry, row: page.Row, editing: bool, buf: []u8) []const u8 {
    if (editing) {
        if (row == .secret) return maskedDraft(state.draftText(), buf);
        return std.fmt.bufPrint(buf, "{s}|", .{state.draftText()}) catch state.draftText();
    }
    return switch (row) {
        .name => entry.name,
        .username => if (entry.username.len > 0) entry.username else tr("Not set", "未设置"),
        .note => if (entry.note.len > 0) entry.note else tr("Not set", "未设置"),
        .secret => if (entry.secret.len == 0) tr("Not set", "未设置") else if (state.revealed()) state.shownSecret() else BULLETS,
        .copy => tr("Copy", "复制"),
        .delete => if (state.confirm_delete) tr("Press Enter again", "再按 Enter 确认") else tr("Delete", "删除"),
        .reveal, .agent => "",
    };
}

fn maskedDraft(draft: []const u8, buf: []u8) []const u8 {
    const dot = "•";
    var len: usize = 0;
    const count = std.unicode.utf8CountCodepoints(draft) catch draft.len;
    for (0..count) |_| {
        if (len + dot.len + 1 > buf.len) break;
        @memcpy(buf[len..][0..dot.len], dot);
        len += dot.len;
    }
    buf[len] = '|';
    return buf[0 .. len + 1];
}

fn rowTitle(row: page.Row) []const u8 {
    return switch (row) {
        .name => tr("Name", "名称"),
        .username => tr("Username", "用户名"),
        .secret => tr("Password", "密码"),
        .reveal => tr("Show password", "显示密码"),
        .note => tr("Note", "备注"),
        .agent => tr("Allow agent", "允许 Agent 使用"),
        .copy => tr("Copy password", "复制密码"),
        .delete => tr("Delete entry", "删除条目"),
    };
}

fn rowDescription(row: page.Row) []const u8 {
    return switch (row) {
        .name => tr("The agent and the Command Center look the entry up by this name", "Agent 和命令面板按这个名称查找条目"),
        .username => tr("Optional, e.g. root or postgres", "可选，例如 root 或 postgres"),
        .secret => tr("Encrypted on disk; type or paste a new one to replace it", "加密保存；输入或粘贴新密码即可替换"),
        .reveal => tr("Show the password in plain text on this page", "在本页以明文显示密码，关闭即隐藏"),
        .note => tr("Tell the agent what it is for, e.g. lab server sudo", "告诉 Agent 用途，例如：实验室服务器 sudo"),
        .agent => tr("When on, password_input may type it into a password prompt after you approve; the agent never sees it", "开启后 Agent 可通过 password_input 在你批准后把它输入到密码提示符，Agent 看不到密码"),
        .copy => tr("Copy to the clipboard, then paste it into the terminal", "复制到剪贴板，再粘贴到终端"),
        .delete => tr("Remove this entry from the store", "从密码库中移除此条目"),
    };
}

fn statusText(status: page.Status) []const u8 {
    return switch (status) {
        .none => "",
        .saved => tr("Saved (encrypted)", "已加密保存"),
        .copied => tr("Password copied to the clipboard", "密码已复制到剪贴板"),
        .deleted => tr("Entry deleted", "条目已删除"),
        .no_secret => tr("This entry has no password yet", "此条目还没有设置密码"),
        .name_empty => tr("Name cannot be empty", "名称不能为空"),
        .name_taken => tr("Another entry already uses this name", "已有同名条目"),
        .save_failed => tr("Could not save the password store", "密码库保存失败"),
        .load_failed => tr("Could not read the password store", "无法读取密码库"),
        .key_failed => tr("Could not use the encryption key (system keychain)", "无法使用加密密钥（系统钥匙串）"),
    };
}

fn statusIsError(status: page.Status) bool {
    return switch (status) {
        .no_secret, .name_empty, .name_taken, .save_failed, .load_failed, .key_failed => true,
        else => false,
    };
}

fn hintText(state: *const page.State) []const u8 {
    if (state.editing) return tr("Type to edit  ·  Enter save  ·  Esc cancel  ·  Paste supported", "输入内容  ·  Enter 保存  ·  Esc 取消  ·  支持粘贴");
    if (state.confirm_delete) return tr("Enter delete  ·  Esc cancel", "Enter 确认删除  ·  Esc 取消");
    if (state.focus == .detail) return tr("↑/↓ field  ·  Enter edit/toggle  ·  ← entries  ·  Copy shortcut copies the password", "↑/↓ 选择字段  ·  Enter 编辑/切换  ·  ← 返回列表  ·  复制快捷键复制密码");
    return tr("↑/↓ entry  ·  Enter/→ open  ·  Delete/⌫ remove  ·  Copy shortcut copies the password", "↑/↓ 选择条目  ·  Enter/→ 打开  ·  Delete/⌫ 删除  ·  复制快捷键复制密码");
}

fn renderFooter(draw: DrawContext, state: *const page.State, layout: settings_layout.Layout, window_height: f32, muted: [3]f32, border: [3]f32) void {
    const footer_h = ui_patterns.workbenchFooterHeight(draw.cell_h);
    const footer_top = ui_patterns.workbenchFooterTop(window_height, layout.page_top_px, footer_h);
    const footer_y = @round(window_height - footer_top - footer_h);
    draw.fillQuadAlpha(layout.page_x, footer_y, layout.page_w, footer_h, mixColor(draw.bg, draw.fg, 0.030), 0.98);
    draw.fillQuadAlpha(layout.page_x, footer_y + footer_h - 1, layout.page_w, 1, border, 0.68);
    const text_y = rowTextY(draw, footer_y, footer_h);
    var x = layout.page_x + 24;
    const right = layout.page_x + layout.page_w - 24;
    const status = statusText(state.status);
    if (status.len > 0) {
        const color = if (statusIsError(state.status)) dangerColor() else draw.accent;
        _ = draw.renderTextLimited(status, x, text_y, color, @max(0, right - x));
        x = @min(right, x + measure(draw, status) + 24);
    }
    _ = draw.renderTextLimited(hintText(state), x, text_y, muted, @max(0.0, right - x));
}

fn renderScrollbar(draw: DrawContext, layout: settings_layout.Layout, window_height: f32, item_count: usize) void {
    if (layout.visible_rows >= item_count) return;
    const total: f32 = @floatFromInt(item_count);
    const vis: f32 = @floatFromInt(layout.visible_rows);
    const track_h = layout.row_h * vis;
    const sb_x = layout.content_x + layout.content_w - 10;
    draw.fillQuadAlpha(sb_x, @round(window_height - layout.row_top_px - track_h), 3, track_h, mixColor(draw.bg, draw.fg, 0.25), 0.30);
    const thumb_h = @max(24.0, @round(track_h * vis / total));
    const max_scroll: f32 = @floatFromInt(item_count - layout.visible_rows);
    const offset = if (max_scroll > 0) @round((track_h - thumb_h) * (@as(f32, @floatFromInt(layout.scroll)) / max_scroll)) else 0;
    draw.fillQuadAlpha(sb_x, @round(window_height - (layout.row_top_px + offset) - thumb_h), 3, thumb_h, draw.accent, 0.55);
}

fn tr(en: []const u8, zh: []const u8) []const u8 {
    return if (i18n.lang() == .zh_CN) zh else en;
}

fn measure(draw: DrawContext, text: []const u8) f32 {
    var w: f32 = 0;
    var view = std.unicode.Utf8View.init(text) catch {
        for (text) |ch| w += draw.glyphAdvance(ch);
        return w;
    };
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| w += draw.glyphAdvance(cp);
    return w;
}

fn dangerColor() [3]f32 {
    return .{ 0.95, 0.38, 0.34 };
}

fn lineHeight(draw: DrawContext) f32 {
    return @round(@max(24.0, draw.cell_h + 8.0));
}

fn textYFromTop(draw: DrawContext, window_height: f32, top: f32) f32 {
    return @round(window_height - top - draw.cell_h);
}

fn rowTextY(draw: DrawContext, y: f32, h: f32) f32 {
    return @round(y + (h - draw.cell_h) / 2);
}

fn mixColor(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    return .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t };
}

const TestDraw = struct {
    var saw_secret: bool = false;
    var saw_bullets: bool = false;
    fn fillQuadAlpha(_: f32, _: f32, _: f32, _: f32, _: [3]f32, _: f32) void {}
    fn roundedQuadAlpha(_: f32, _: f32, _: f32, _: f32, _: f32, _: [3]f32, _: f32) void {}
    fn renderTextLimited(text: []const u8, x: f32, _: f32, _: [3]f32, _: f32) f32 {
        if (std.mem.indexOf(u8, text, "pw") != null) saw_secret = true;
        if (std.mem.eql(u8, text, BULLETS)) saw_bullets = true;
        return x;
    }
    fn glyphAdvance(_: u32) f32 {
        return 8;
    }
    const ctx = DrawContext{
        .bg = .{ 0, 0, 0 },
        .fg = .{ 1, 1, 1 },
        .accent = .{ 0.2, 0.6, 1 },
        .cell_h = 16,
        .fillQuadAlpha = fillQuadAlpha,
        .roundedQuadAlpha = roundedQuadAlpha,
        .renderTextLimited = renderTextLimited,
        .glyphAdvance = glyphAdvance,
    };
};

test "password store page draws bullets, never the secret, by default" {
    var state = page.State{ .allocator = std.testing.allocator, .vault = store.Vault.init(std.testing.allocator) };
    defer state.close();
    try state.vault.?.append(.{ .name = "root", .secret = try state.vault.?.seal("pw") });
    state.focus = .detail;
    TestDraw.saw_secret = false;
    TestDraw.saw_bullets = false;
    const geo = compute(&state, 900, 40, 0, 1200, 16);
    render(TestDraw.ctx, &state, geo, 900);
    try std.testing.expect(TestDraw.saw_bullets);
    try std.testing.expect(!TestDraw.saw_secret);
}

test "password store rail follows the selection and hit-tests rows" {
    var state = page.State{ .allocator = std.testing.allocator, .vault = store.Vault.init(std.testing.allocator) };
    defer state.close();
    for (0..40) |i| {
        var buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "e{d}", .{i});
        try state.vault.?.append(.{ .name = try state.vault.?.dupe(name) });
    }
    state.selected = 39;
    const geo = compute(&state, 600, 40, 0, 1000, 16);
    try std.testing.expect(geo.layout.category_count < state.railCount());
    try std.testing.expectEqual(@as(usize, 39), geo.rail_start + geo.layout.category_count - 1);
    const rail_y = geo.layout.nav_item_top_px + 2;
    try std.testing.expectEqual(Hit{ .rail = geo.rail_start }, hitTest(geo, geo.layout.page_x + 20, rail_y));
    try std.testing.expectEqual(Hit{ .row = .name }, hitTest(geo, geo.layout.content_x + 8, geo.layout.row_top_px + 2));
    try std.testing.expect(overRail(geo, geo.layout.page_x + 5));

    var buf: [64]u8 = undefined;
    state.editing = true;
    state.row = .secret;
    try state.draft.appendSlice(std.testing.allocator, "ab");
    try std.testing.expectEqualStrings("••|", rowValue(&state, state.current().?, .secret, true, &buf));
}
