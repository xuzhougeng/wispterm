//! Password Store workbench page: a Settings-style rail of vault entries on
//! the left and the selected entry's fields on the right. Feature-owned model;
//! renderer/password_store_renderer.zig draws it and the integration layer
//! runs the one side effect that needs the platform clipboard (`Action`).
//!
//! Passwords are hidden by default. A secret is decrypted only while "Show
//! password" is on (wiped when it turns off or the entry changes) or for a
//! one-shot copy; editing a password types a replacement and never shows the
//! old one.
const std = @import("std");
const input_key = @import("../input/key.zig");
const store = @import("store.zig");

pub const Row = enum { name, username, secret, reveal, note, agent, copy, delete };
pub const ROWS = std.enums.values(Row);

pub const Focus = enum { list, detail };

/// Last outcome shown in the footer; the renderer owns the wording.
pub const Status = enum { none, saved, copied, deleted, no_secret, name_empty, name_taken, save_failed, load_failed, key_failed };

/// Side effects the host performs.
pub const Action = enum { copy_secret };

pub const State = struct {
    allocator: ?std.mem.Allocator = null,
    /// null with `status == .load_failed`: the file could not be read, so the
    /// page is read-only and never overwrites it.
    vault: ?store.Vault = null,
    /// Rail index; `entries().len` is the trailing "New entry" item.
    selected: usize = 0,
    focus: Focus = .list,
    row: Row = .name,
    editing: bool = false,
    draft: std.ArrayListUnmanaged(u8) = .empty,
    /// Plaintext of the selected secret while "Show password" is on.
    shown: ?[]u8 = null,
    confirm_delete: bool = false,
    status: Status = .none,
    /// The vault file as this page last read or wrote it.
    disk: store.Fingerprint = @splat(0),

    /// (Re)load the vault from disk, discarding page state.
    pub fn open(self: *State, allocator: std.mem.Allocator) void {
        self.close();
        self.allocator = allocator;
        self.vault = store.load(allocator) catch blk: {
            self.status = .load_failed;
            break :blk null;
        };
        self.disk = store.fileFingerprint(allocator);
    }

    /// Reload when the file changed underneath (sync, another window), so the
    /// next save never writes back a stale copy. The selection and an open
    /// edit follow their entry by name. Called before every mutation.
    pub fn refreshIfChanged(self: *State) void {
        const allocator = self.allocator orelse return;
        if (self.vault == null) return;
        const now = store.fileFingerprint(allocator);
        if (std.mem.eql(u8, &now, &self.disk)) return;
        const fresh = store.load(allocator) catch return;
        var name_buf: [512]u8 = undefined;
        var name_len: ?usize = null;
        if (self.current()) |e| {
            const n = @min(e.name.len, name_buf.len);
            @memcpy(name_buf[0..n], e.name[0..n]);
            name_len = n;
        }
        self.hideSecret();
        self.vault.?.deinit();
        self.vault = fresh;
        self.disk = now;
        const count = self.entries().len;
        self.selected = if (name_len) |n| (self.vault.?.find(name_buf[0..n], null) orelse count) else count;
        if (self.current() == null and self.editing) self.endEdit();
    }

    pub fn close(self: *State) void {
        self.hideSecret();
        self.clearDraft();
        if (self.allocator) |allocator| self.draft.deinit(allocator);
        if (self.vault) |*vault| vault.deinit();
        self.* = .{};
    }

    /// The tab lost focus: hide a shown password and drop any unsaved edit.
    pub fn didDeactivate(self: *State) void {
        self.hideSecret();
        self.endEdit();
        self.confirm_delete = false;
    }

    pub fn entries(self: *const State) []const store.Entry {
        return if (self.vault) |*vault| vault.entries.items else &.{};
    }

    /// Rail items: every entry plus "New entry" (none when the load failed).
    pub fn railCount(self: *const State) usize {
        return if (self.vault != null) self.entries().len + 1 else 0;
    }

    pub fn current(self: *const State) ?*const store.Entry {
        const items = self.entries();
        return if (self.selected < items.len) &items[self.selected] else null;
    }

    fn currentMut(self: *State) ?*store.Entry {
        const vault = if (self.vault) |*v| v else return null;
        const items = vault.entries.items;
        return if (self.selected < items.len) &items[self.selected] else null;
    }

    pub fn revealed(self: *const State) bool {
        return self.shown != null;
    }

    pub fn shownSecret(self: *const State) []const u8 {
        return self.shown orelse "";
    }

    pub fn draftText(self: *const State) []const u8 {
        return self.draft.items;
    }

    pub fn handleKey(self: *State, ev: input_key.KeyEvent) ?Action {
        if (self.editing) {
            switch (ev.key) {
                .escape => self.endEdit(),
                .enter => _ = self.commitEdit(),
                .backspace, .delete => self.popDraft(),
                else => {},
            }
            return null;
        }
        if (self.confirm_delete) {
            if (ev.key == .enter) {
                self.deleteCurrent();
                return null;
            }
            self.confirm_delete = false;
            if (ev.key == .escape) return null;
        }
        // ⌫ is the delete key on a Mac keyboard; in the rail it cannot mean
        // "erase a character", and a second Enter is still required.
        const delete_key = ev.key == .delete or (ev.key == .backspace and self.focus == .list);
        if (delete_key and self.current() != null) {
            self.focus = .detail;
            self.row = .delete;
            self.confirm_delete = true;
            return null;
        }
        switch (self.focus) {
            .list => switch (ev.key) {
                .arrow_up => self.moveRail(-1),
                .arrow_down => self.moveRail(1),
                .enter, .arrow_right, .tab => self.enterDetail(),
                else => {},
            },
            .detail => switch (ev.key) {
                .arrow_up => self.moveRow(-1),
                .arrow_down, .tab => self.moveRow(1),
                .arrow_left, .escape => self.focus = .list,
                .enter => return self.activate(self.row),
                .arrow_right => if (self.row == .reveal or self.row == .agent) return self.activate(self.row),
                else => {},
            },
        }
        return null;
    }

    /// Typed text. On a text field it starts (or continues) editing; Space
    /// flips a toggle row. Returns whether the page consumed it.
    pub fn insertChar(self: *State, cp: u21) bool {
        if (cp < 0x20 or cp == 0x7f) return false;
        if (!self.editing) {
            if (self.focus != .detail or self.current() == null) return false;
            switch (self.row) {
                .name, .username, .secret, .note => self.beginEdit(self.row),
                .reveal, .agent => {
                    if (cp == ' ') _ = self.activate(self.row);
                    return true;
                },
                .copy, .delete => return false,
            }
        }
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch return false;
        self.appendDraft(buf[0..len]);
        return true;
    }

    /// Paste into the field being edited (or the focused text field). Line
    /// breaks are dropped: every field is a single line.
    pub fn paste(self: *State, text: []const u8) bool {
        if (!self.editing) {
            if (self.focus != .detail or self.current() == null) return false;
            switch (self.row) {
                .name, .username, .secret, .note => self.beginEdit(self.row),
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

    /// Click on a rail item. An open edit is committed first; a failed commit
    /// (empty/duplicate name) keeps the edit and ignores the click.
    pub fn clickRail(self: *State, index: usize) void {
        if (self.editing and !self.commitEdit()) return;
        if (index >= self.railCount()) return;
        self.confirm_delete = false;
        if (index != self.selected) self.selectRail(index);
        self.focus = .list;
        if (self.current() == null) self.createEntry();
    }

    pub fn clickRow(self: *State, row: Row) ?Action {
        if (self.editing) {
            if (row == self.row) return null;
            if (!self.commitEdit()) return null;
        }
        if (self.current() == null) return null;
        if (row != self.row) self.confirm_delete = false;
        self.focus = .detail;
        self.row = row;
        return self.activate(row);
    }

    pub fn scroll(self: *State, delta: isize, over_rail: bool) void {
        if (self.editing or delta == 0) return;
        self.confirm_delete = false;
        if (over_rail) self.moveRail(delta) else self.moveRow(delta);
    }

    /// Decrypt the selected secret for a copy. Release with `store.wipe`.
    pub fn revealForCopy(self: *State) ?[]u8 {
        const allocator = self.allocator orelse return null;
        const entry = self.current() orelse return null;
        if (entry.secret.len == 0) {
            self.status = .no_secret;
            return null;
        }
        return store.reveal(allocator, entry) catch {
            self.status = .key_failed;
            return null;
        };
    }

    fn activate(self: *State, row: Row) ?Action {
        self.refreshIfChanged();
        if (self.current() == null) {
            self.createEntry();
            return null;
        }
        switch (row) {
            .name, .username, .secret, .note => self.beginEdit(row),
            .reveal => if (self.shown != null) self.hideSecret() else self.showSecret(),
            .agent => {
                const entry = self.currentMut() orelse return null;
                entry.agent = !entry.agent;
                self.persist();
            },
            .copy => return .copy_secret,
            .delete => if (self.confirm_delete) self.deleteCurrent() else {
                self.confirm_delete = true;
            },
        }
        return null;
    }

    fn enterDetail(self: *State) void {
        if (self.vault == null) return;
        if (self.current() == null) return self.createEntry();
        self.focus = .detail;
    }

    fn selectRail(self: *State, index: usize) void {
        self.hideSecret();
        self.selected = index;
        self.status = .none;
    }

    fn moveRail(self: *State, delta: isize) void {
        const count = self.railCount();
        if (count == 0) return;
        const next = moveClamped(self.selected, delta, count);
        if (next != self.selected) self.selectRail(next);
    }

    fn moveRow(self: *State, delta: isize) void {
        self.row = ROWS[moveClamped(@intFromEnum(self.row), delta, ROWS.len)];
    }

    fn createEntry(self: *State) void {
        self.refreshIfChanged();
        const vault = if (self.vault) |*v| v else return;
        var name_buf: [32]u8 = undefined;
        var n: usize = 1;
        const name = while (true) : (n += 1) {
            const candidate = (if (n == 1) std.fmt.bufPrint(&name_buf, "new-entry", .{}) else std.fmt.bufPrint(&name_buf, "new-entry-{d}", .{n})) catch return;
            if (vault.find(candidate, null) == null) break candidate;
        };
        const owned = vault.dupe(name) catch return;
        vault.append(.{ .name = owned }) catch return;
        self.persist();
        self.selectRail(vault.entries.items.len - 1);
        self.focus = .detail;
        self.row = .name;
        self.beginEdit(.name);
        // Typing the name replaces the placeholder; Esc keeps it.
        self.clearDraft();
    }

    fn deleteCurrent(self: *State) void {
        self.confirm_delete = false;
        self.refreshIfChanged();
        if (self.current() == null) return;
        self.hideSecret();
        _ = self.vault.?.entries.orderedRemove(self.selected);
        self.persist();
        if (self.status == .saved) self.status = .deleted;
        self.focus = .list;
    }

    fn beginEdit(self: *State, row: Row) void {
        const entry = self.current() orelse return;
        self.confirm_delete = false;
        self.row = row;
        self.editing = true;
        self.clearDraft();
        switch (row) {
            .name => self.appendDraft(entry.name),
            .username => self.appendDraft(entry.username),
            .note => self.appendDraft(entry.note),
            // A replacement is typed fresh; the old password is never shown here.
            else => {},
        }
    }

    fn endEdit(self: *State) void {
        self.editing = false;
        self.clearDraft();
    }

    /// Store the draft into the edited field and save. False keeps editing.
    fn commitEdit(self: *State) bool {
        self.refreshIfChanged();
        const vault = if (self.vault) |*v| v else {
            self.endEdit();
            return false;
        };
        const entry = self.currentMut() orelse {
            self.endEdit();
            return false;
        };
        const text = self.draft.items;
        const trimmed = std.mem.trim(u8, text, " \t");
        switch (self.row) {
            .name => {
                if (trimmed.len == 0) {
                    self.status = .name_empty;
                    return false;
                }
                if (vault.find(trimmed, self.selected) != null) {
                    self.status = .name_taken;
                    return false;
                }
                entry.name = vault.dupe(trimmed) catch return false;
            },
            .username => entry.username = vault.dupe(trimmed) catch return false,
            .note => entry.note = vault.dupe(trimmed) catch return false,
            .secret => {
                entry.secret = vault.seal(text) catch {
                    self.status = .key_failed;
                    return false;
                };
                self.hideSecret();
            },
            else => {},
        }
        self.endEdit();
        self.persist();
        return true;
    }

    fn persist(self: *State) void {
        const allocator = self.allocator orelse return;
        store.save(allocator, self.entries()) catch {
            self.status = .save_failed;
            return;
        };
        self.disk = store.fileFingerprint(allocator);
        self.status = .saved;
    }

    fn showSecret(self: *State) void {
        const allocator = self.allocator orelse return;
        const entry = self.current() orelse return;
        if (entry.secret.len == 0) {
            self.status = .no_secret;
            return;
        }
        self.shown = store.reveal(allocator, entry) catch {
            self.status = .key_failed;
            return;
        };
    }

    fn hideSecret(self: *State) void {
        const secret = self.shown orelse return;
        if (self.allocator) |allocator| store.wipe(allocator, secret);
        self.shown = null;
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

    /// Drafts may hold a new password, so they are wiped, not just truncated.
    fn clearDraft(self: *State) void {
        std.crypto.secureZero(u8, self.draft.items);
        self.draft.clearRetainingCapacity();
    }
};

fn moveClamped(current: usize, delta: isize, count: usize) usize {
    const max: isize = @intCast(count - 1);
    const next = std.math.clamp(@as(isize, @intCast(@min(current, count - 1))) + delta, 0, max);
    return @intCast(next);
}

// Feature-owned instance: the page is a singleton tab per window thread (like
// recipe/ui_state.zig), so the integration layer gains no new global.
threadlocal var g_state: State = .{};

pub fn state() *State {
    return &g_state;
}

fn testState(names: []const []const u8) !State {
    var s = State{ .allocator = std.testing.allocator, .vault = store.Vault.init(std.testing.allocator) };
    for (names) |name| try s.vault.?.append(.{ .name = try s.vault.?.dupe(name), .secret = try s.vault.?.seal("pw") });
    return s;
}

fn key(k: input_key.Key) input_key.KeyEvent {
    return .{ .key = k };
}

test "password page keeps the password hidden until shown, then wipes it" {
    var s = try testState(&.{"root"});
    defer s.close();
    try std.testing.expect(!s.revealed());
    _ = s.handleKey(key(.enter)); // list -> detail
    s.row = .reveal;
    _ = s.handleKey(key(.enter));
    try std.testing.expectEqualStrings("pw", s.shownSecret());
    s.moveRail(1); // switching entries hides it again
    try std.testing.expect(!s.revealed());
}

test "password page hides the password and drops edits when the tab is left" {
    var s = try testState(&.{"root"});
    defer s.close();
    s.focus = .detail;
    s.row = .reveal;
    _ = s.handleKey(key(.enter));
    try std.testing.expect(s.revealed());
    s.row = .secret;
    try std.testing.expect(s.insertChar('x'));
    s.didDeactivate();
    try std.testing.expect(!s.revealed());
    try std.testing.expect(!s.editing);
    try std.testing.expectEqual(@as(usize, 0), s.draftText().len);
}

test "password page edits a field through the draft and validates names" {
    var s = try testState(&.{ "root", "mysql" });
    defer s.close();
    s.focus = .detail;
    s.row = .name;
    try std.testing.expect(s.insertChar('x')); // typing starts an edit seeded with the name
    try std.testing.expectEqualStrings("rootx", s.draftText());
    s.popDraft();
    s.popDraft();
    s.popDraft();
    s.popDraft();
    s.popDraft();
    _ = s.paste("MySQL\n");
    try std.testing.expect(!s.commitEdit());
    try std.testing.expectEqual(Status.name_taken, s.status);
    try std.testing.expect(s.editing);
    _ = s.handleKey(key(.escape));
    try std.testing.expect(!s.editing);
    try std.testing.expectEqualStrings("root", s.current().?.name);
}

test "password page secret edit starts empty and seals the replacement" {
    var s = try testState(&.{"root"});
    defer s.close();
    s.focus = .detail;
    s.row = .secret;
    try std.testing.expect(s.insertChar('n'));
    try std.testing.expectEqualStrings("n", s.draftText()); // old secret never seeded
    _ = s.paste("ew");
    try std.testing.expect(s.commitEdit());
    // Random base64 ciphertext may contain "new" by chance. Reject storing
    // plaintext verbatim, and verify authenticated decryption below.
    try std.testing.expect(!std.mem.eql(u8, s.current().?.secret, "new"));
    const plain = s.revealForCopy().?;
    defer store.wipe(std.testing.allocator, plain);
    try std.testing.expectEqualStrings("new", plain);
}

test "password page delete needs a second Enter and Escape cancels it" {
    var s = try testState(&.{ "a", "b" });
    defer s.close();
    _ = s.handleKey(key(.delete));
    try std.testing.expect(s.confirm_delete);
    _ = s.handleKey(key(.escape));
    try std.testing.expect(!s.confirm_delete);
    try std.testing.expectEqual(@as(usize, 2), s.entries().len);
    _ = s.handleKey(key(.delete));
    _ = s.handleKey(key(.enter));
    try std.testing.expectEqual(@as(usize, 1), s.entries().len);
    try std.testing.expectEqualStrings("b", s.entries()[0].name);
}

test "password page rail ends with New entry and copy returns an action" {
    var s = try testState(&.{"root"});
    defer s.close();
    try std.testing.expectEqual(@as(usize, 2), s.railCount());
    s.moveRail(5);
    try std.testing.expectEqual(@as(usize, 1), s.selected);
    try std.testing.expect(s.current() == null);
    s.moveRail(-1);
    try std.testing.expectEqual(Action.copy_secret, s.clickRow(.copy).?);
    try std.testing.expectEqual(Focus.detail, s.focus);
}

test "password page refuses to edit a vault it could not load" {
    var s = State{ .allocator = std.testing.allocator, .status = .load_failed };
    defer s.close();
    try std.testing.expectEqual(@as(usize, 0), s.railCount());
    _ = s.handleKey(key(.enter));
    try std.testing.expect(s.vault == null);
}
