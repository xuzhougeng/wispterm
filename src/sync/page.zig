//! Sync workbench page: a Settings-style rail of three sections (Connection,
//! What to sync, Status) and the selected section's rows. Feature-owned model;
//! renderer/sync_page_renderer.zig draws it and appwindow/sync_bridge.zig
//! routes input to it.
//!
//! Secrets typed here never stay in clear: the WebDAV password is sealed with
//! this computer's keychain key as soon as it is committed, and the sync
//! passphrase is handed to the worker (which derives the key and wipes it).
//! Neither is ever shown again; editing either types a replacement.
const std = @import("std");
const input_key = @import("../input/key.zig");
const sync_settings = @import("settings.zig");
const service = @import("service.zig");

pub const Section = enum { connection, data, status };
pub const SECTIONS = std.enums.values(Section);

pub const Row = enum {
    target,
    url,
    username,
    password,
    remote_folder,
    folder,
    passphrase,
    passwords,
    history,
    ssh_hosts,
    ai_profiles,
    interval,
    sync_now,
    last_result,
    forget,
};

const WEBDAV_ROWS = [_]Row{ .target, .url, .username, .password, .remote_folder, .passphrase };
const FOLDER_ROWS = [_]Row{ .target, .folder, .passphrase };
const DATA_ROWS = [_]Row{ .passwords, .history, .ssh_hosts, .ai_profiles, .interval };
const STATUS_ROWS = [_]Row{ .sync_now, .last_result, .forget };

pub fn rowsFor(section: Section, target: sync_settings.Target) []const Row {
    return switch (section) {
        .connection => if (target == .webdav) &WEBDAV_ROWS else &FOLDER_ROWS,
        .data => &DATA_ROWS,
        .status => &STATUS_ROWS,
    };
}

pub const MIN_PASSPHRASE_LEN = 8;

pub const Kind = enum { text, secret, toggle, choice, action, info };

pub fn rowKind(row: Row) Kind {
    return switch (row) {
        .url, .username, .remote_folder, .folder => .text,
        .password, .passphrase => .secret,
        .passwords, .history, .ssh_hosts, .ai_profiles => .toggle,
        .target, .interval => .choice,
        .sync_now, .forget => .action,
        .last_result => .info,
    };
}

pub const Focus = enum { rail, detail };

/// Last page-local outcome shown in the footer; the renderer owns the wording.
pub const PageStatus = enum {
    none,
    saved,
    save_failed,
    load_failed,
    url_invalid,
    passphrase_short,
    passphrase_sent,
    need_location,
    sync_started,
    forgotten,
    keychain_failed,
};

pub const State = struct {
    allocator: ?std.mem.Allocator = null,
    /// `<config-dir>/sync`, owned.
    dir: []const u8 = "",
    loaded: ?sync_settings.Loaded = null,
    section: Section = .connection,
    focus: Focus = .rail,
    row_index: usize = 0,
    editing: bool = false,
    draft: std.ArrayListUnmanaged(u8) = .empty,
    confirm_forget: bool = false,
    status: PageStatus = .none,

    pub fn open(self: *State, allocator: std.mem.Allocator, dir: []const u8) void {
        self.close();
        self.allocator = allocator;
        self.dir = allocator.dupe(u8, dir) catch "";
        self.reload();
    }

    pub fn close(self: *State) void {
        self.clearDraft();
        if (self.allocator) |allocator| {
            self.draft.deinit(allocator);
            if (self.dir.len > 0) allocator.free(self.dir);
        }
        if (self.loaded) |*l| l.deinit();
        self.* = .{};
    }

    /// Re-read settings.json (the worker stores the derived key there).
    /// Skipped while a field is being edited.
    pub fn reload(self: *State) void {
        if (self.editing) return;
        const allocator = self.allocator orelse return;
        if (self.loaded) |*l| l.deinit();
        self.loaded = null;
        service.lockSettings();
        defer service.unlockSettings();
        self.loaded = sync_settings.load(allocator, self.dir) catch blk: {
            self.status = .load_failed;
            break :blk null;
        };
        self.clampRow();
    }

    pub fn didDeactivate(self: *State) void {
        self.endEdit();
        self.confirm_forget = false;
    }

    pub fn settings(self: *const State) sync_settings.Settings {
        return if (self.loaded) |l| l.value else .{};
    }

    pub fn rows(self: *const State) []const Row {
        return rowsFor(self.section, self.settings().target);
    }

    pub fn currentRow(self: *const State) Row {
        const r = self.rows();
        return r[@min(self.row_index, r.len - 1)];
    }

    pub fn draftText(self: *const State) []const u8 {
        return self.draft.items;
    }

    pub fn handleKey(self: *State, ev: input_key.KeyEvent) void {
        if (self.editing) {
            switch (ev.key) {
                .escape => self.endEdit(),
                .enter, .tab => _ = self.commitEdit(),
                .backspace, .delete => self.popDraft(),
                else => {},
            }
            return;
        }
        if (self.confirm_forget) {
            if (ev.key == .enter) return self.forgetSetup();
            self.confirm_forget = false;
            if (ev.key == .escape) return;
        }
        switch (self.focus) {
            .rail => switch (ev.key) {
                .arrow_up => self.moveSection(-1),
                .arrow_down => self.moveSection(1),
                .enter, .arrow_right, .tab => self.focus = .detail,
                else => {},
            },
            .detail => switch (ev.key) {
                .arrow_up => self.moveRow(-1),
                .arrow_down, .tab => self.moveRow(1),
                .escape => self.focus = .rail,
                .arrow_left => if (rowKind(self.currentRow()) == .choice) self.cycle(-1) else {
                    self.focus = .rail;
                },
                .arrow_right => switch (rowKind(self.currentRow())) {
                    .choice => self.cycle(1),
                    .toggle => self.activate(),
                    else => {},
                },
                .enter => self.activate(),
                else => {},
            },
        }
    }

    /// Typed text: starts (or continues) editing a text field; Space flips a
    /// toggle. Returns whether the page consumed it.
    pub fn insertChar(self: *State, cp: u21) bool {
        if (cp < 0x20 or cp == 0x7f) return false;
        if (!self.editing) {
            if (self.focus != .detail) return false;
            switch (rowKind(self.currentRow())) {
                .text, .secret => self.beginEdit(),
                .toggle, .choice => {
                    if (cp == ' ') self.activate();
                    return true;
                },
                .action, .info => return false,
            }
        }
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch return false;
        self.appendDraft(buf[0..len]);
        return true;
    }

    pub fn paste(self: *State, text: []const u8) bool {
        if (!self.editing) {
            if (self.focus != .detail) return false;
            switch (rowKind(self.currentRow())) {
                .text, .secret => self.beginEdit(),
                else => return false,
            }
        }
        var start: usize = 0;
        for (text, 0..) |ch, i| {
            if (ch != '\r' and ch != '\n') continue;
            self.appendDraft(text[start..i]);
            start = i + 1;
        }
        self.appendDraft(text[start..]);
        return true;
    }

    pub fn clickSection(self: *State, index: usize) void {
        if (self.editing and !self.commitEdit()) return;
        if (index >= SECTIONS.len) return;
        self.confirm_forget = false;
        if (SECTIONS[index] != self.section) self.selectSection(SECTIONS[index]);
        self.focus = .rail;
    }

    pub fn clickRow(self: *State, index: usize) void {
        if (self.editing) {
            if (index == self.row_index) return;
            if (!self.commitEdit()) return;
        }
        if (index >= self.rows().len) return;
        if (index != self.row_index) self.confirm_forget = false;
        self.focus = .detail;
        self.row_index = index;
        self.activate();
    }

    pub fn scroll(self: *State, delta: isize, over_rail: bool) void {
        if (self.editing or delta == 0) return;
        self.confirm_forget = false;
        if (over_rail) self.moveSection(delta) else self.moveRow(delta);
    }

    fn activate(self: *State) void {
        const row = self.currentRow();
        switch (rowKind(row)) {
            .text, .secret => self.beginEdit(),
            .toggle => {
                var value = self.settings();
                const kind = toggleKind(row);
                value.setKindEnabled(kind, !value.kindEnabled(kind));
                self.persist(value);
            },
            .choice => self.cycle(1),
            .action => switch (row) {
                .sync_now => self.syncNow(),
                .forget => if (self.confirm_forget) self.forgetSetup() else {
                    self.confirm_forget = true;
                },
                else => {},
            },
            .info => {},
        }
    }

    fn cycle(self: *State, delta: isize) void {
        var value = self.settings();
        switch (self.currentRow()) {
            .target => value.target = if (value.target == .webdav) .folder else .webdav,
            .interval => {
                const choices = sync_settings.INTERVAL_CHOICES;
                var i: usize = 0;
                while (i < choices.len and choices[i] != value.interval_minutes) i += 1;
                if (i == choices.len) i = 0;
                const n: isize = @intCast(choices.len);
                value.interval_minutes = choices[@intCast(@mod(@as(isize, @intCast(i)) + delta, n))];
            },
            else => return,
        }
        self.persist(value);
        self.clampRow();
    }

    fn syncNow(self: *State) void {
        const value = self.settings();
        if (!value.hasLocation()) {
            self.status = .need_location;
            return;
        }
        service.requestSync(true);
        self.status = .sync_started;
    }

    fn forgetSetup(self: *State) void {
        self.confirm_forget = false;
        service.forget(self.dir);
        self.reload();
        self.status = .forgotten;
        self.section = .connection;
        self.row_index = 0;
    }

    fn selectSection(self: *State, section: Section) void {
        self.section = section;
        self.row_index = 0;
        self.status = .none;
    }

    fn moveSection(self: *State, delta: isize) void {
        const next = moveClamped(@intFromEnum(self.section), delta, SECTIONS.len);
        if (next != @intFromEnum(self.section)) self.selectSection(SECTIONS[next]);
    }

    fn moveRow(self: *State, delta: isize) void {
        self.row_index = moveClamped(self.row_index, delta, self.rows().len);
    }

    fn clampRow(self: *State) void {
        self.row_index = @min(self.row_index, self.rows().len - 1);
    }

    fn beginEdit(self: *State) void {
        self.confirm_forget = false;
        self.editing = true;
        self.clearDraft();
        const value = self.settings();
        switch (self.currentRow()) {
            .url => self.appendDraft(value.url),
            .username => self.appendDraft(value.username),
            .remote_folder => self.appendDraft(value.remote_folder),
            .folder => self.appendDraft(value.folder),
            // Secrets are typed fresh; the old ones are never shown.
            else => {},
        }
    }

    fn endEdit(self: *State) void {
        self.editing = false;
        self.clearDraft();
    }

    /// Store the draft into the edited field. False keeps editing.
    fn commitEdit(self: *State) bool {
        const allocator = self.allocator orelse {
            self.endEdit();
            return false;
        };
        const loaded = if (self.loaded) |*l| l else {
            self.endEdit();
            return false;
        };
        var value = loaded.value;
        const trimmed = std.mem.trim(u8, self.draft.items, " \t");
        switch (self.currentRow()) {
            .url => {
                if (trimmed.len > 0 and !std.ascii.startsWithIgnoreCase(trimmed, "https://") and !std.ascii.startsWithIgnoreCase(trimmed, "http://")) {
                    self.status = .url_invalid;
                    return false;
                }
                value.url = loaded.dupe(trimmed) catch return false;
            },
            .username => value.username = loaded.dupe(trimmed) catch return false,
            .remote_folder => value.remote_folder = loaded.dupe(std.mem.trim(u8, trimmed, "/\\")) catch return false,
            .folder => value.folder = loaded.dupe(trimmed) catch return false,
            .password => {
                const sealed = sync_settings.sealLocal(allocator, self.draft.items) catch {
                    self.status = .keychain_failed;
                    return false;
                };
                defer allocator.free(sealed);
                value.password_sealed = loaded.dupe(sealed) catch return false;
            },
            .passphrase => {
                if (std.unicode.utf8CountCodepoints(self.draft.items) catch 0 < MIN_PASSPHRASE_LEN) {
                    self.status = .passphrase_short;
                    return false;
                }
                if (!value.hasLocation()) {
                    self.status = .need_location;
                    return false;
                }
                service.submitPassphrase(self.draft.items);
                self.endEdit();
                self.status = .passphrase_sent;
                return true;
            },
            else => {},
        }
        self.endEdit();
        self.persist(value);
        return true;
    }

    fn persist(self: *State, value: sync_settings.Settings) void {
        const allocator = self.allocator orelse return;
        service.saveUserSettings(allocator, self.dir, value) catch {
            self.status = .save_failed;
            return;
        };
        if (self.loaded) |*l| l.value = value;
        self.status = .saved;
        service.reconfigure();
    }

    fn appendDraft(self: *State, text: []const u8) void {
        const allocator = self.allocator orelse return;
        self.draft.appendSlice(allocator, text) catch {};
    }

    fn popDraft(self: *State) void {
        var len = self.draft.items.len;
        while (len > 0) {
            len -= 1;
            if (self.draft.items[len] & 0xC0 != 0x80) break;
        }
        std.crypto.secureZero(u8, self.draft.items[len..]);
        self.draft.shrinkRetainingCapacity(len);
    }

    /// Drafts may hold a password or the passphrase: wipe, don't truncate.
    fn clearDraft(self: *State) void {
        std.crypto.secureZero(u8, self.draft.items);
        self.draft.clearRetainingCapacity();
    }
};

pub fn toggleKind(row: Row) sync_settings.Kind {
    return switch (row) {
        .passwords => .passwords,
        .history => .history,
        .ssh_hosts => .ssh_hosts,
        else => .ai_profiles,
    };
}

fn moveClamped(current: usize, delta: isize, count: usize) usize {
    const max: isize = @intCast(count - 1);
    const next = std.math.clamp(@as(isize, @intCast(@min(current, count - 1))) + delta, 0, max);
    return @intCast(next);
}

// Feature-owned instance: one Sync page per window thread (like
// credential/page.zig), so the integration layer gains no new global.
threadlocal var g_state: State = .{};

pub fn state() *State {
    return &g_state;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn testState(dir: []const u8) State {
    var s = State{};
    s.open(std.testing.allocator, dir);
    return s;
}

fn key(k: input_key.Key) input_key.KeyEvent {
    return .{ .key = k };
}

fn typeText(s: *State, text: []const u8) void {
    var view = std.unicode.Utf8View.initUnchecked(text);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| _ = s.insertChar(cp);
}

test "sync page edits the WebDAV URL and validates it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);
    var s = testState(dir);
    defer s.close();

    s.handleKey(key(.enter)); // rail -> detail
    s.handleKey(key(.arrow_down)); // url
    try std.testing.expectEqual(Row.url, s.currentRow());
    typeText(&s, "dav.example.com");
    s.handleKey(key(.enter));
    try std.testing.expectEqual(PageStatus.url_invalid, s.status);
    try std.testing.expect(s.editing);
    s.handleKey(key(.escape));
    typeText(&s, "https://dav.example.com/dav");
    s.handleKey(key(.enter));
    try std.testing.expect(!s.editing);
    try std.testing.expectEqualStrings("https://dav.example.com/dav", s.settings().url);

    var reopened = testState(dir);
    defer reopened.close();
    try std.testing.expectEqualStrings("https://dav.example.com/dav", reopened.settings().url);
}

test "sync page seals the WebDAV password and never seeds it into the draft" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);
    var s = testState(dir);
    defer s.close();
    s.focus = .detail;
    s.row_index = 3;
    try std.testing.expectEqual(Row.password, s.currentRow());
    typeText(&s, "app-pass");
    s.handleKey(key(.enter));
    try std.testing.expect(s.settings().password_sealed.len > 0);
    const raw = try tmp.dir.readFileAlloc(std.testing.allocator, "settings.json", 1 << 20);
    defer std.testing.allocator.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "app-pass") == null);

    try std.testing.expect(s.insertChar('x'));
    try std.testing.expectEqualStrings("x", s.draftText());
}

test "sync page target switch changes the connection rows; toggles and interval persist" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);
    var s = testState(dir);
    defer s.close();
    try std.testing.expectEqual(@as(usize, WEBDAV_ROWS.len), s.rows().len);
    s.focus = .detail;
    s.handleKey(key(.arrow_right)); // target -> folder
    try std.testing.expectEqual(sync_settings.Target.folder, s.settings().target);
    try std.testing.expectEqual(@as(usize, FOLDER_ROWS.len), s.rows().len);

    s.focus = .rail;
    s.handleKey(key(.arrow_down)); // data section
    try std.testing.expectEqual(Section.data, s.section);
    s.handleKey(key(.enter));
    s.handleKey(key(.enter)); // passwords off
    try std.testing.expect(!s.settings().passwords);
    try std.testing.expect(s.insertChar(' ')); // back on
    try std.testing.expect(s.settings().passwords);
    s.row_index = 4;
    s.handleKey(key(.arrow_right));
    try std.testing.expectEqual(@as(u32, 30), s.settings().interval_minutes);
    s.handleKey(key(.arrow_left));
    s.handleKey(key(.arrow_left));
    try std.testing.expectEqual(@as(u32, 5), s.settings().interval_minutes);
}

test "sync page passphrase needs a location and a minimum length; forget needs two Enters" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);
    var s = testState(dir);
    defer s.close();
    s.focus = .detail;
    s.row_index = 5;
    try std.testing.expectEqual(Row.passphrase, s.currentRow());
    typeText(&s, "short");
    s.handleKey(key(.enter));
    try std.testing.expectEqual(PageStatus.passphrase_short, s.status);
    typeText(&s, " but long now");
    s.handleKey(key(.enter));
    try std.testing.expectEqual(PageStatus.need_location, s.status);
    s.handleKey(key(.escape));

    s.section = .status;
    s.row_index = 2;
    s.handleKey(key(.enter));
    try std.testing.expect(s.confirm_forget);
    s.handleKey(key(.escape));
    try std.testing.expect(!s.confirm_forget);
    s.handleKey(key(.enter));
    s.handleKey(key(.enter));
    try std.testing.expectEqual(PageStatus.forgotten, s.status);
    try std.testing.expectEqual(Section.connection, s.section);
}
