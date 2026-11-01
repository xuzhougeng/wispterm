//! Feature-owned renderer for the Sync workbench. Same family as the Password
//! Store and Settings pages (settings_page_layout: section rail, aligned rows,
//! footer status band). Reads the page model and a snapshot of the sync worker
//! status; never reaches back into AppWindow or does I/O.

const std = @import("std");
const i18n = @import("../i18n.zig");
const page = @import("../sync/page.zig");
const service = @import("../sync/service.zig");
const sync_settings = @import("../sync/settings.zig");
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

/// What the page shows about the worker, captured once per frame.
pub const View = struct {
    status: service.Status = .{},
    passphrase_pending: bool = false,
    now_ms: i64 = 0,
};

pub const Geometry = struct {
    layout: settings_layout.Layout,
};

pub const Hit = union(enum) {
    none,
    section: usize,
    row: usize,
};

pub fn compute(state: *const page.State, window_height: f32, top_offset: f32, content_x: f32, content_width: f32, cell_h: f32) Geometry {
    return .{ .layout = settings_layout.compute(.{
        .window_height = window_height,
        .top_offset = top_offset,
        .content_x = content_x,
        .content_width = content_width,
        .cell_height = cell_h,
        .focus_index = state.row_index,
        .row_count = state.rows().len,
        .category_count = page.SECTIONS.len,
    }) };
}

pub fn hitTest(geo: Geometry, x: f32, y: f32) Hit {
    if (geo.layout.categoryAt(x, y)) |i| return .{ .section = i };
    if (geo.layout.rowAt(x, y)) |r| return .{ .row = r };
    return .none;
}

pub fn overRail(geo: Geometry, x: f32) bool {
    return x < geo.layout.page_x + geo.layout.nav_w;
}

pub fn render(draw: DrawContext, state: *const page.State, view: View, geo: Geometry, window_height: f32) void {
    const layout = geo.layout;
    const page_y = @round(window_height - layout.page_top_px - layout.page_h);
    const border = mixColor(draw.bg, draw.fg, 0.16);
    const muted = mixColor(draw.bg, draw.fg, 0.58);
    const title_color = mixColor(draw.fg, draw.accent, 0.10);

    draw.fillQuadAlpha(layout.page_x, page_y, layout.page_w, layout.page_h, mixColor(draw.bg, draw.fg, 0.012), 1.0);
    draw.fillQuadAlpha(layout.page_x, page_y, layout.nav_w, layout.page_h, mixColor(draw.bg, draw.fg, 0.025), 0.96);
    draw.fillQuadAlpha(layout.page_x + layout.nav_w - 1, page_y, 1, layout.page_h, border, 0.72);

    renderRail(draw, state, view, layout, window_height, muted, title_color);

    var subtitle_buf: [256]u8 = undefined;
    _ = draw.renderTextLimited(sectionTitle(state.section), layout.content_x, textYFromTop(draw, window_height, layout.page_top_px + 28), title_color, layout.content_w);
    _ = draw.renderTextLimited(sectionSubtitle(state, view, &subtitle_buf), layout.content_x, textYFromTop(draw, window_height, layout.page_top_px + 28 + lineHeight(draw)), muted, layout.content_w);
    draw.fillQuadAlpha(layout.content_x, @round(window_height - layout.row_top_px), layout.content_w, 1, border, 0.52);

    for (state.rows(), 0..) |row, row_index| renderRow(draw, state, view, layout, window_height, row, row_index);
    renderScrollbar(draw, layout, window_height, state.rows().len);
    renderFooter(draw, state, view, layout, window_height, muted, border);
}

fn renderRail(draw: DrawContext, state: *const page.State, view: View, layout: settings_layout.Layout, window_height: f32, muted: [3]f32, title_color: [3]f32) void {
    _ = draw.renderTextLimited(i18n.s().sync_title, layout.page_x + 24, textYFromTop(draw, window_height, layout.nav_title_top_px), title_color, layout.nav_w - 48);
    const value = state.settings();
    const label = if (!value.hasLocation())
        tr("NOT SET UP", "未设置")
    else if (view.status.running)
        tr("SYNCING…", "同步中…")
    else if (value.target == .webdav)
        tr("WEBDAV · ENCRYPTED", "WEBDAV · 端到端加密")
    else
        tr("FOLDER · ENCRYPTED", "文件夹 · 端到端加密");
    _ = draw.renderTextLimited(label, layout.page_x + 24, textYFromTop(draw, window_height, layout.nav_label_top_px), muted, layout.nav_w - 48);

    for (page.SECTIONS, 0..) |section, slot| {
        if (slot >= layout.category_count) break;
        const item_top = layout.nav_item_top_px + layout.nav_item_h * @as(f32, @floatFromInt(slot));
        const item_y = @round(window_height - item_top - layout.nav_item_h);
        const selected = section == state.section;
        if (selected) draw.fillQuadAlpha(layout.page_x + 14, item_y + 10, 3, layout.nav_item_h - 20, draw.accent, if (state.focus == .rail) 0.84 else 0.38);
        const color = if (selected) mixColor(draw.fg, draw.accent, 0.16) else mixColor(draw.bg, draw.fg, 0.76);
        _ = draw.renderTextLimited(sectionTitle(section), layout.page_x + 28, rowTextY(draw, item_y, layout.nav_item_h), color, layout.nav_w - 48);
    }
}

fn sectionTitle(section: page.Section) []const u8 {
    return switch (section) {
        .connection => tr("Connection", "连接"),
        .data => tr("What to sync", "同步内容"),
        .status => tr("Status", "状态"),
    };
}

fn sectionSubtitle(state: *const page.State, view: View, buf: []u8) []const u8 {
    return switch (state.section) {
        .connection => tr("Use the same drive and passphrase on every computer. Only encrypted files are stored there.", "在每台电脑上填写同一个网盘和同一个同步口令；网盘里只保存加密后的文件。"),
        .data => tr("Each kind merges item by item; edits and deletions reach your other computers.", "按条目合并：修改和删除都会同步到你的其他电脑。"),
        .status => lastResultText(view, buf),
    };
}

fn renderRow(draw: DrawContext, state: *const page.State, view: View, layout: settings_layout.Layout, window_height: f32, row: page.Row, row_index: usize) void {
    const visible = layout.visibleRow(window_height, row_index) orelse return;
    const x = layout.content_x;
    const w = layout.content_w;
    const title_x = x + 20;
    const right_edge = x + w - 18;
    const selected = state.focus == .detail and state.row_index == row_index;
    const editing = state.editing and selected;

    if (selected) draw.fillQuadAlpha(x + 2, visible.gl_y + 8, 3, layout.row_h - 16, draw.accent, 0.82);
    if (editing) draw.fillQuadAlpha(x + 8, visible.gl_y + 6, w - 16, layout.row_h - 12, mixColor(draw.bg, draw.accent, 0.10), 0.80);

    const kind = page.rowKind(row);
    const control_h = if (kind == .toggle) 24.0 else @round(@max(32.0, draw.cell_h + 10.0));
    const pill_y = textYFromTop(draw, window_height, visible.top_px + 10) - @round((control_h - draw.cell_h) / 2);
    var title_max_w = w - 40;
    if (kind == .toggle) {
        const on = state.settings().kindEnabled(page.toggleKind(row));
        const value_w: f32 = 46;
        const value_x = @round(right_edge - value_w);
        draw.roundedQuadAlpha(value_x, pill_y, value_w, control_h, control_h / 2, if (on) mixColor(draw.bg, draw.accent, 0.40) else mixColor(draw.bg, draw.fg, 0.18), 0.96);
        const knob_d = control_h - 6;
        const knob_x = if (on) value_x + value_w - knob_d - 3 else value_x + 3;
        draw.roundedQuadAlpha(knob_x, pill_y + 3, knob_d, knob_d, knob_d / 2, if (on) draw.accent else mixColor(draw.bg, draw.fg, 0.42), 0.96);
        title_max_w = @max(1.0, value_x - title_x - 18);
    } else {
        var value_buf: [512]u8 = undefined;
        const value = rowValue(state, view, row, editing, &value_buf);
        const max_value_w: f32 = if (kind == .text or kind == .info) @max(180.0, w * 0.50) else 240;
        const desired_w = @min(max_value_w, @max(96.0, measure(draw, value) + 24));
        const value_w = ui_patterns.textColumns(right_edge - title_x, measure(draw, rowTitle(row)), desired_w, 18).right_w;
        const value_x = @round(right_edge - value_w);
        const danger = row == .forget and state.confirm_forget;
        const value_color = if (danger) dangerColor() else if (selected or editing) draw.accent else mixColor(draw.bg, draw.fg, 0.82);
        _ = draw.renderTextLimited(value, value_x, rowTextY(draw, pill_y, control_h), value_color, value_w);
        title_max_w = @max(1.0, value_x - title_x - 18);
    }

    if (visible.visible_index > 0) draw.fillQuadAlpha(x + 18, visible.gl_y + layout.row_h - 1, w - 36, 1, mixColor(draw.bg, draw.fg, 0.14), 0.62);
    _ = draw.renderTextLimited(rowTitle(row), title_x, textYFromTop(draw, window_height, visible.top_px + 10), if (selected) mixColor(draw.fg, draw.accent, 0.16) else draw.fg, title_max_w);
    _ = draw.renderTextLimited(rowDescription(row, state.settings().target), title_x, textYFromTop(draw, window_height, visible.top_px + 10 + lineHeight(draw)), mixColor(draw.bg, draw.fg, 0.56), @max(0, right_edge - title_x));
}

const BULLETS = "••••••••";

/// The text in a row's value slot. Secrets show only whether they are set; a
/// secret being typed shows one bullet per character.
pub fn rowValue(state: *const page.State, view: View, row: page.Row, editing: bool, buf: []u8) []const u8 {
    if (editing) {
        if (page.rowKind(row) == .secret) return maskedDraft(state.draftText(), buf);
        return std.fmt.bufPrint(buf, "{s}|", .{state.draftText()}) catch state.draftText();
    }
    const value = state.settings();
    return switch (row) {
        .target => if (value.target == .webdav) tr("WebDAV", "WebDAV") else tr("Synced folder", "同步文件夹"),
        .url => orNotSet(value.url),
        .username => orNotSet(value.username),
        .password => if (value.password_sealed.len > 0) BULLETS else tr("Not set", "未设置"),
        .remote_folder => if (value.remote_folder.len > 0) value.remote_folder else tr("(share root)", "（网盘根目录）"),
        .folder => orNotSet(value.folder),
        .passphrase => if (view.passphrase_pending) tr("Checking…", "验证中…") else if (value.hasKey()) tr("Set on this computer", "本机已设置") else tr("Not set", "未设置"),
        .passwords, .history, .ssh_hosts, .ai_profiles => "",
        .interval => intervalText(value.interval_minutes, buf),
        .sync_now => if (view.status.running) tr("Syncing…", "同步中…") else tr("Sync now", "立即同步"),
        .last_result => lastResultText(view, buf),
        .forget => if (state.confirm_forget) tr("Press Enter again", "再按 Enter 确认") else tr("Forget", "清除"),
    };
}

fn orNotSet(text: []const u8) []const u8 {
    return if (text.len > 0) text else tr("Not set", "未设置");
}

fn intervalText(minutes: u32, buf: []u8) []const u8 {
    if (minutes == 0) return tr("Off (Sync now only)", "关闭（仅手动同步）");
    return (if (i18n.lang() == .zh_CN) std.fmt.bufPrint(buf, "每 {d} 分钟", .{minutes}) else std.fmt.bufPrint(buf, "Every {d} min", .{minutes})) catch "";
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
        .target => tr("Storage", "存储方式"),
        .url => tr("WebDAV URL", "WebDAV 地址"),
        .username => tr("Username", "用户名"),
        .password => tr("Password", "密码"),
        .remote_folder => tr("Remote folder", "远程文件夹"),
        .folder => tr("Sync folder", "同步文件夹"),
        .passphrase => tr("Sync passphrase", "同步口令"),
        .passwords => tr("Password Store", "密码库"),
        .history => tr("Agent history", "Agent 历史"),
        .ssh_hosts => tr("SSH hosts", "SSH 主机"),
        .ai_profiles => tr("AI profiles", "AI 配置"),
        .interval => tr("Automatic sync", "自动同步"),
        .sync_now => tr("Sync now", "立即同步"),
        .last_result => tr("Last sync", "上次同步"),
        .forget => tr("Forget on this computer", "在本机清除同步设置"),
    };
}

fn rowDescription(row: page.Row, target: sync_settings.Target) []const u8 {
    return switch (row) {
        .target => if (target == .webdav)
            tr("WebDAV: 坚果云 / Nextcloud / Synology / InfiniCloud …", "WebDAV：坚果云 / Nextcloud / 群晖 / InfiniCloud 等")
        else
            tr("A folder your drive client syncs (OneDrive, iCloud Drive, Dropbox)", "由网盘客户端同步的文件夹（OneDrive、iCloud 云盘、Dropbox）"),
        .url => tr("e.g. https://dav.jianguoyun.com/dav/", "例如 https://dav.jianguoyun.com/dav/"),
        .username => tr("Your WebDAV account (坚果云: your login email)", "WebDAV 账号（坚果云：登录邮箱）"),
        .password => tr("Sealed by this computer's keychain; 坚果云 needs an app password", "由本机钥匙串加密保存；坚果云需使用“应用密码”"),
        .remote_folder => tr("Created on the drive on first sync", "首次同步时在网盘中自动创建"),
        .folder => tr("Full path, e.g. ~/Library/Mobile Documents/com~apple~CloudDocs/WispTerm", "完整路径，例如 D:\\OneDrive\\WispTerm"),
        .passphrase => tr("Encrypts everything; same on every computer, at least 8 characters, never stored", "用于加密全部数据；各电脑相同，至少 8 个字符，本机不保存口令本身"),
        .passwords => tr("Entries with their passwords, re-encrypted on each computer", "条目及密码，在每台电脑上重新加密保存"),
        .history => tr("WispTerm Agent / Copilot conversations, one file per session", "WispTerm Agent / 副驾对话，每个会话一个文件"),
        .ssh_hosts => tr("Saved SSH profiles, including stored passwords", "已保存的 SSH 配置，包括其中保存的密码"),
        .ai_profiles => tr("Model provider profiles, including API keys", "模型服务配置，包括 API Key"),
        .interval => tr("Also syncs at launch and shortly after you edit synced data", "启动时以及修改同步数据后不久也会同步"),
        .sync_now => tr("Merge with the drive now", "立即与网盘合并"),
        .last_result => tr("Received ↓ / sent ↑ items in the last run", "上次同步收到 ↓ / 发送 ↑ 的条目数"),
        .forget => tr("Removes the saved login and key here; the drive and your data stay", "删除本机保存的登录信息和密钥；网盘和本地数据保持不变"),
    };
}

/// "Synced 3 min ago · ↓2 ↑1", "Never synced", or the last failure.
pub fn lastResultText(view: View, buf: []u8) []const u8 {
    const st = view.status;
    if (st.running) return tr("Syncing…", "同步中…");
    if (!st.has_run) return tr("Not synced yet in this session", "本次启动后尚未同步");
    if (st.problem != .none) return problemText(st, buf);
    var age_buf: [48]u8 = undefined;
    const age = ageText(view.now_ms - st.finished_at_ms, &age_buf);
    return (if (i18n.lang() == .zh_CN)
        std.fmt.bufPrint(buf, "{s}同步 · 收到 ↓{d} · 发送 ↑{d}", .{ age, st.totals.pulled + st.totals.deleted_local, st.totals.pushed + st.totals.deleted_remote })
    else
        std.fmt.bufPrint(buf, "Synced {s} · ↓{d} received · ↑{d} sent", .{ age, st.totals.pulled + st.totals.deleted_local, st.totals.pushed + st.totals.deleted_remote })) catch "";
}

fn ageText(ms: i64, buf: []u8) []const u8 {
    const minutes = @divTrunc(@max(ms, 0), std.time.ms_per_min);
    const zh = i18n.lang() == .zh_CN;
    if (minutes < 1) return if (zh) "刚刚" else "just now";
    if (minutes < 60) return (if (zh) std.fmt.bufPrint(buf, "{d} 分钟前", .{minutes}) else std.fmt.bufPrint(buf, "{d} min ago", .{minutes})) catch "";
    const hours = @divTrunc(minutes, 60);
    if (hours < 48) return (if (zh) std.fmt.bufPrint(buf, "{d} 小时前", .{hours}) else std.fmt.bufPrint(buf, "{d} h ago", .{hours})) catch "";
    return (if (zh) std.fmt.bufPrint(buf, "{d} 天前", .{@divTrunc(hours, 24)}) else std.fmt.bufPrint(buf, "{d} days ago", .{@divTrunc(hours, 24)})) catch "";
}

pub fn problemText(st: service.Status, buf: []u8) []const u8 {
    const zh = i18n.lang() == .zh_CN;
    return switch (st.problem) {
        .none => "",
        .not_configured => tr("Set the WebDAV URL or sync folder first", "请先填写 WebDAV 地址或同步文件夹"),
        .need_passphrase => tr("Enter the sync passphrase to unlock this drive", "请输入同步口令以解锁该网盘"),
        .wrong_passphrase => tr("The passphrase does not match the one this drive was set up with", "同步口令与该网盘初始化时使用的不一致"),
        .auth_failed => tr("The drive rejected the login (401/403); 坚果云 needs an app password", "网盘拒绝登录（401/403）；坚果云需要使用“应用密码”"),
        .folder_missing => tr("The sync folder was not found and could not be created", "找不到同步文件夹，且无法创建"),
        .drive_full => tr("The drive is full", "网盘空间已满"),
        .server_error => (if (zh) std.fmt.bufPrint(buf, "网盘返回错误（HTTP {d}）", .{st.http_status}) else std.fmt.bufPrint(buf, "The drive returned an error (HTTP {d})", .{st.http_status})) catch "",
        .network => tr("Could not reach the drive (offline, DNS, TLS or proxy)", "无法连接网盘（离线、DNS、TLS 或代理问题）"),
        .unsupported_method => tr("This build cannot create WebDAV folders; create the remote folder on the drive first", "当前版本无法创建 WebDAV 文件夹；请先在网盘中手动创建远程文件夹"),
        .corrupt_remote => tr("A file on the drive could not be decrypted (other passphrase, or damaged)", "网盘上的文件无法解密（口令不同或文件已损坏）"),
        .newer_format => tr("The drive was written by a newer WispTerm; update this computer", "网盘数据来自更新版本的 WispTerm，请先升级本机"),
        .local_busy => tr("A file changed while syncing; it merges on the next sync", "同步期间本地文件有改动，将在下次同步时合并"),
        .history_unavailable => tr("Agent history is not loaded yet", "Agent 历史尚未加载"),
        .keychain => tr("Could not use this computer's keychain to unlock saved secrets", "无法使用本机钥匙串解开已保存的密钥"),
        .other => (if (zh) std.fmt.bufPrint(buf, "同步失败：{s}", .{st.detail()}) else std.fmt.bufPrint(buf, "Sync failed: {s}", .{st.detail()})) catch "",
    };
}

/// Toast text for a finished run (see service.noticeFor).
pub fn noticeText(notice: service.Notice, st: service.Status, buf: []u8) []const u8 {
    const zh = i18n.lang() == .zh_CN;
    const received = st.totals.pulled + st.totals.deleted_local;
    const sent = st.totals.pushed + st.totals.deleted_remote;
    return switch (notice) {
        .none => "",
        .synced => (if (zh) std.fmt.bufPrint(buf, "同步完成：收到 {d}，发送 {d}", .{ received, sent }) else std.fmt.bufPrint(buf, "Sync complete: {d} received, {d} sent", .{ received, sent })) catch "",
        .received => (if (zh) std.fmt.bufPrint(buf, "同步：收到其他电脑的 {d} 项更改", .{received}) else std.fmt.bufPrint(buf, "Sync: {d} changes from your other computers", .{received})) catch "",
        .failed => blk: {
            var problem_buf: [128]u8 = undefined;
            const problem = problemText(st, &problem_buf);
            break :blk (if (zh) std.fmt.bufPrint(buf, "同步失败：{s}", .{problem}) else std.fmt.bufPrint(buf, "Sync failed: {s}", .{problem})) catch "";
        },
    };
}

fn statusText(status: page.PageStatus) []const u8 {
    return switch (status) {
        .none => "",
        .saved => tr("Saved", "已保存"),
        .save_failed => tr("Could not save the sync settings", "同步设置保存失败"),
        .load_failed => tr("Could not read the sync settings", "无法读取同步设置"),
        .url_invalid => tr("The URL must start with https:// or http://", "地址必须以 https:// 或 http:// 开头"),
        .passphrase_short => tr("Use at least 8 characters", "口令至少需要 8 个字符"),
        .passphrase_sent => tr("Unlocking the drive…", "正在解锁网盘…"),
        .need_location => tr("Set the WebDAV URL or sync folder first", "请先填写 WebDAV 地址或同步文件夹"),
        .sync_started => tr("Sync started", "已开始同步"),
        .forgotten => tr("Sync settings removed from this computer", "已从本机清除同步设置"),
        .keychain_failed => tr("Could not use the system keychain", "无法使用系统钥匙串"),
    };
}

fn statusIsError(status: page.PageStatus) bool {
    return switch (status) {
        .save_failed, .load_failed, .url_invalid, .passphrase_short, .need_location, .keychain_failed => true,
        else => false,
    };
}

fn hintText(state: *const page.State) []const u8 {
    if (state.editing) return tr("Type to edit  ·  Enter save  ·  Esc cancel  ·  Paste supported", "输入内容  ·  Enter 保存  ·  Esc 取消  ·  支持粘贴");
    if (state.confirm_forget) return tr("Enter forget  ·  Esc cancel", "Enter 确认清除  ·  Esc 取消");
    if (state.focus == .detail) return tr("↑/↓ field  ·  Enter edit/toggle  ·  ←/→ change  ·  Esc sections", "↑/↓ 选择字段  ·  Enter 编辑/切换  ·  ←/→ 调整  ·  Esc 返回");
    return tr("↑/↓ section  ·  Enter/→ open", "↑/↓ 选择分区  ·  Enter/→ 打开");
}

fn renderFooter(draw: DrawContext, state: *const page.State, view: View, layout: settings_layout.Layout, window_height: f32, muted: [3]f32, border: [3]f32) void {
    const footer_h = ui_patterns.workbenchFooterHeight(draw.cell_h);
    const footer_top = ui_patterns.workbenchFooterTop(window_height, layout.page_top_px, footer_h);
    const footer_y = @round(window_height - footer_top - footer_h);
    draw.fillQuadAlpha(layout.page_x, footer_y, layout.page_w, footer_h, mixColor(draw.bg, draw.fg, 0.030), 0.98);
    draw.fillQuadAlpha(layout.page_x, footer_y + footer_h - 1, layout.page_w, 1, border, 0.68);
    const text_y = rowTextY(draw, footer_y, footer_h);
    var x = layout.page_x + 24;
    const right = layout.page_x + layout.page_w - 24;
    var buf: [256]u8 = undefined;
    // Page-local feedback first; otherwise the worker's last problem.
    const status = statusText(state.status);
    const shown: []const u8, const is_error = if (status.len > 0)
        .{ status, statusIsError(state.status) }
    else if (view.status.problem != .none and !view.status.running)
        .{ problemText(view.status, &buf), true }
    else
        .{ "", false };
    if (shown.len > 0) {
        _ = draw.renderTextLimited(shown, x, text_y, if (is_error) dangerColor() else draw.accent, @max(0, right - x));
        x = @min(right, x + measure(draw, shown) + 24);
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
    var texts: usize = 0;
    fn fillQuadAlpha(_: f32, _: f32, _: f32, _: f32, _: [3]f32, _: f32) void {}
    fn roundedQuadAlpha(_: f32, _: f32, _: f32, _: f32, _: f32, _: [3]f32, _: f32) void {}
    fn renderTextLimited(text: []const u8, x: f32, _: f32, _: [3]f32, _: f32) f32 {
        texts += 1;
        if (std.mem.indexOf(u8, text, "app-pass") != null) saw_secret = true;
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

test "sync page renders every section and masks a typed password" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);
    var state = page.State{};
    state.open(std.testing.allocator, dir);
    defer state.close();
    state.focus = .detail;
    state.row_index = 3;
    try std.testing.expectEqual(page.Row.password, state.currentRow());
    for ("app-pass") |ch| _ = state.insertChar(ch);

    TestDraw.saw_secret = false;
    for (page.SECTIONS) |section| {
        state.section = section;
        if (section != .connection) state.editing = false;
        state.row_index = @min(state.row_index, state.rows().len - 1);
        const geo = compute(&state, 900, 40, 0, 1200, 16);
        TestDraw.texts = 0;
        render(TestDraw.ctx, &state, .{ .now_ms = 1000 }, geo, 900);
        try std.testing.expect(TestDraw.texts > state.rows().len);
    }
    try std.testing.expect(!TestDraw.saw_secret);
}

test "sync page hit-tests sections and rows; status text covers problems" {
    var state = page.State{};
    const geo = compute(&state, 900, 40, 0, 1200, 16);
    try std.testing.expectEqual(Hit{ .section = 1 }, hitTest(geo, geo.layout.page_x + 20, geo.layout.nav_item_top_px + geo.layout.nav_item_h + 2));
    try std.testing.expectEqual(Hit{ .row = 0 }, hitTest(geo, geo.layout.content_x + 8, geo.layout.row_top_px + 2));
    try std.testing.expect(overRail(geo, geo.layout.page_x + 5));

    var buf: [256]u8 = undefined;
    var st = service.Status{ .has_run = true, .problem = .server_error, .http_status = 503 };
    try std.testing.expect(std.mem.indexOf(u8, problemText(st, &buf), "503") != null);
    st.problem = .none;
    st.finished_at_ms = 0;
    st.totals.pulled = 2;
    try std.testing.expect(std.mem.indexOf(u8, lastResultText(.{ .status = st, .now_ms = 5 * std.time.ms_per_min }, &buf), "2") != null);
    try std.testing.expect(noticeText(.synced, st, &buf).len > 0);
}
