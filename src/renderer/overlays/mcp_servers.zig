//! In-app "MCP Servers" config panel: overlay state that loads configured
//! servers from disk into a fixed-size, heap-free struct. Mirrors
//! ssh_profiles.zig conventions (fixed arrays, fixed char buffers with a
//! `_len`, no heap allocation stored on the struct — this lives inside the
//! multi-MB OverlayState).
const std = @import("std");
const mcp_registry = @import("../../tools/mcp_registry.zig");
const mcp_probe = @import("../../assistant/mcp_probe.zig");

pub const MCP_SERVER_MAX = 32;
pub const FIELD_MAX = 512;

/// One server row as displayed in the panel. `args` is the arg list joined
/// by single spaces (display-only — mcp_registry.ServerConfig owns the real
/// `[][]u8`).
pub const Server = struct {
    name: [FIELD_MAX]u8 = undefined,
    name_len: usize = 0,
    command: [FIELD_MAX]u8 = undefined,
    command_len: usize = 0,
    args: [FIELD_MAX]u8 = undefined,
    args_len: usize = 0,
    enabled: bool = true,
};

pub const View = enum { list, form };

/// Form field identifiers, indexed into `State.form_bufs`/`form_lens`.
pub const Field = enum { name, command, args };
const FORM_FIELD_COUNT = @typeInfo(Field).@"enum".fields.len;

/// Rows in the add/edit form: the three text fields, then the action rows.
/// `delete` is only present when editing an existing server. (`test` is a Zig
/// keyword, hence `test_conn`.) Tab/↓ walk this order via `formFocusNext`.
pub const FormRow = enum {
    name,
    command,
    args,
    save,
    test_conn,
    delete,
    cancel,

    /// The text field this row edits, or null for action rows.
    pub fn field(self: FormRow) ?Field {
        return switch (self) {
            .name => .name,
            .command => .command,
            .args => .args,
            else => null,
        };
    }
};

/// Navigation order of the form rows. `delete` only appears when editing.
const FORM_ROWS_ADD = [_]FormRow{ .name, .command, .args, .save, .test_conn, .cancel };
const FORM_ROWS_EDIT = [_]FormRow{ .name, .command, .args, .save, .test_conn, .delete, .cancel };

/// What a `list` view row represents: one configured server, or one of the
/// three trailing action rows (mirrors ssh_profiles' manage-mode action rows).
pub const ListAction = enum { server, new_server, edit_json, close };

pub const FormError = error{ EmptyName, DuplicateName, EmptyCommand, Full };

/// Sentinel for `editing_index`: no server is being edited (an add, not
/// an edit).
pub const EDIT_INDEX_NONE: usize = std.math.maxInt(usize);

pub const ProbeStatus = enum { idle, running, ok, failed };

/// Holds the outcome of the "Test" probe against `servers[target_index]`.
/// Mirrors `mcp_probe.Result`'s fixed buffers (message/tools are plain
/// values, not owned pointers) so `applyProbeResult` can copy one in without
/// touching the heap. The probe thread itself (Task 10) lives in the input
/// handler; this struct only holds + applies the result it hands back.
pub const ProbeState = struct {
    status: ProbeStatus = .idle,
    target_index: usize = 0,
    message: [256]u8 = undefined,
    message_len: usize = 0,
    tools: [24][64]u8 = undefined,
    tool_count: usize = 0,
};

pub const State = struct {
    visible: bool = false,
    view: View = .list,
    servers: [MCP_SERVER_MAX]Server = undefined,
    count: usize = 0,
    list_selected: usize = 0,
    form_bufs: [FORM_FIELD_COUNT][FIELD_MAX]u8 = undefined,
    form_lens: [FORM_FIELD_COUNT]usize = .{0} ** FORM_FIELD_COUNT,
    editing_index: usize = EDIT_INDEX_NONE,
    /// Which form row currently has keyboard focus; Tab/↑↓ cycle it across the
    /// text fields and the action rows.
    form_focus: FormRow = .name,
    /// Set when `commitForm` fails, so the input handler can keep the form
    /// open instead of returning to the list. Cleared by `beginAdd`,
    /// `beginEdit`, and a successful commit.
    form_error: ?FormError = null,
    /// Result of the last "Test" probe, applied via `applyProbeResult`.
    probe: ProbeState = .{},
    /// Live filter for the list view: typing narrows the visible servers
    /// (mirrors the SSH picker's search box). Empty = show all.
    list_filter_buf: [FIELD_MAX]u8 = undefined,
    list_filter_len: usize = 0,

    /// Reset to defaults and load `<config-dir>/mcp.json` into `servers`.
    /// A missing/unreadable config file yields zero servers (not an error).
    pub fn open(self: *State, allocator: std.mem.Allocator) void {
        self.* = .{ .visible = true };
        const loaded = mcp_registry.loadConfigFile(allocator) catch return;
        defer mcp_registry.freeServersConfig(allocator, loaded);
        for (loaded) |cfg| {
            if (self.count >= MCP_SERVER_MAX) break;
            var s = Server{ .enabled = cfg.enabled };
            setBuf(&s.name, &s.name_len, cfg.name);
            setBuf(&s.command, &s.command_len, cfg.command);
            var joined: [FIELD_MAX]u8 = undefined;
            var n: usize = 0;
            for (cfg.args, 0..) |arg, i| {
                if (i != 0 and n < FIELD_MAX) {
                    joined[n] = ' ';
                    n += 1;
                }
                const take = @min(arg.len, FIELD_MAX - n);
                @memcpy(joined[n..][0..take], arg[0..take]);
                n += take;
            }
            setBuf(&s.args, &s.args_len, joined[0..n]);
            self.servers[self.count] = s;
            self.count += 1;
        }
    }

    /// Move the list selection by `delta`, wrapping across the full row set
    /// (visible servers + action rows), mirroring the SSH picker. `listRowCount`
    /// is always >= 3 (the trailing action rows), so this never divides by zero.
    pub fn moveSelection(self: *State, delta: i32) void {
        const n: i64 = @intCast(self.listRowCount());
        const cur: i64 = @intCast(self.list_selected);
        var next = @mod(cur + delta, n);
        if (next < 0) next += n;
        self.list_selected = @intCast(next);
    }

    pub fn serverName(self: *const State, i: usize) []const u8 {
        return self.servers[i].name[0..self.servers[i].name_len];
    }

    pub fn serverArgs(self: *const State, i: usize) []const u8 {
        return self.servers[i].args[0..self.servers[i].args_len];
    }

    // ---- List filter (search box) -----------------------------------------

    pub fn listFilter(self: *const State) []const u8 {
        return self.list_filter_buf[0..self.list_filter_len];
    }

    pub fn clearListFilter(self: *State) void {
        self.list_filter_len = 0;
        self.list_selected = 0;
    }

    /// Replace the whole filter (used by paste and tests) and reset selection.
    pub fn setFilter(self: *State, value: []const u8) void {
        setBuf(&self.list_filter_buf, &self.list_filter_len, value);
        self.list_selected = 0;
    }

    /// Append one printable-ASCII byte to the filter and reset the selection to
    /// the top so it always points at a valid (possibly newly-filtered) row.
    pub fn appendListFilter(self: *State, ch: u8) void {
        if (self.list_filter_len >= FIELD_MAX) return;
        self.list_filter_buf[self.list_filter_len] = ch;
        self.list_filter_len += 1;
        self.list_selected = 0;
    }

    pub fn backspaceListFilter(self: *State) void {
        if (self.list_filter_len == 0) return;
        self.list_filter_len -= 1;
        self.list_selected = 0;
    }

    /// Case-insensitive substring match on name/command/args. An empty filter
    /// matches every server.
    pub fn serverMatchesFilter(self: *const State, i: usize) bool {
        const filter = self.listFilter();
        if (filter.len == 0) return true;
        return containsIgnoreCase(self.serverName(i), filter) or
            containsIgnoreCase(self.servers[i].command[0..self.servers[i].command_len], filter) or
            containsIgnoreCase(self.serverArgs(i), filter);
    }

    pub fn visibleCount(self: *const State) usize {
        var n: usize = 0;
        for (0..self.count) |i| {
            if (self.serverMatchesFilter(i)) n += 1;
        }
        return n;
    }

    /// Actual `servers` index of the `visible_row`-th server matching the
    /// current filter, or null if `visible_row` is past the filtered set.
    pub fn visibleServerIndex(self: *const State, visible_row: usize) ?usize {
        var seen: usize = 0;
        for (0..self.count) |i| {
            if (!self.serverMatchesFilter(i)) continue;
            if (seen == visible_row) return i;
            seen += 1;
        }
        return null;
    }

    // ---- List rows (visible servers + trailing action rows) ---------------

    /// Total selectable rows: visible servers + 3 action rows (new server,
    /// edit mcp.json, close).
    pub fn listRowCount(self: *const State) usize {
        return self.visibleCount() + 3;
    }

    pub fn listActionForRow(self: *const State, row: usize) ListAction {
        const vc = self.visibleCount();
        if (row < vc) return .server;
        return switch (row - vc) {
            0 => .new_server,
            1 => .edit_json,
            else => .close,
        };
    }

    /// The `servers` index the list selection points at, or null when the
    /// selection is on one of the action rows.
    pub fn selectedServerIndex(self: *const State) ?usize {
        if (self.list_selected >= self.visibleCount()) return null;
        return self.visibleServerIndex(self.list_selected);
    }

    // ---- Form row navigation ----------------------------------------------

    fn formRowOrder(self: *const State) []const FormRow {
        return if (self.editing_index != EDIT_INDEX_NONE) &FORM_ROWS_EDIT else &FORM_ROWS_ADD;
    }

    pub fn formFocusNext(self: *State) void {
        const rows = self.formRowOrder();
        const cur = indexOfFormRow(rows, self.form_focus);
        self.form_focus = rows[(cur + 1) % rows.len];
    }

    pub fn formFocusPrev(self: *State) void {
        const rows = self.formRowOrder();
        const cur = indexOfFormRow(rows, self.form_focus);
        self.form_focus = rows[(cur + rows.len - 1) % rows.len];
    }

    pub fn formField(self: *const State, field: Field) []const u8 {
        const idx = @intFromEnum(field);
        return self.form_bufs[idx][0..self.form_lens[idx]];
    }

    pub fn setFormField(self: *State, field: Field, value: []const u8) void {
        const idx = @intFromEnum(field);
        setBuf(&self.form_bufs[idx], &self.form_lens[idx], value);
    }

    /// Clear the form and switch to it, ready to add a new server.
    pub fn beginAdd(self: *State) void {
        self.form_lens = .{0} ** FORM_FIELD_COUNT;
        self.editing_index = EDIT_INDEX_NONE;
        self.form_focus = .name;
        self.form_error = null;
        self.probe.status = .idle;
        self.view = .form;
    }

    /// Populate the form from `servers[index]` and switch to it.
    pub fn beginEdit(self: *State, index: usize) void {
        self.setFormField(.name, self.serverName(index));
        self.setFormField(.command, self.servers[index].command[0..self.servers[index].command_len]);
        self.setFormField(.args, self.serverArgs(index));
        self.editing_index = index;
        self.form_focus = .name;
        self.form_error = null;
        self.probe.status = .idle;
        self.view = .form;
    }

    /// Validate the form (non-empty unique name, non-empty command) and
    /// write it into `servers`: appends when adding, overwrites in place
    /// when `editing_index` was set by `beginEdit`. The duplicate-name
    /// check skips `editing_index` so editing a server keeps its own name.
    /// `enabled` is not a form field: editing a server preserves its
    /// existing `enabled` value, and adding one defaults it to `true`.
    /// Adding past `MCP_SERVER_MAX` returns `error.Full` instead of
    /// overflowing `servers`.
    pub fn commitForm(self: *State) FormError!void {
        const name = std.mem.trim(u8, self.formField(.name), " \t");
        if (name.len == 0) return error.EmptyName;
        const command = self.formField(.command);
        if (command.len == 0) return error.EmptyCommand;
        for (0..self.count) |i| {
            if (i == self.editing_index) continue;
            if (std.mem.eql(u8, self.serverName(i), name)) return error.DuplicateName;
        }

        const target: *Server = if (self.editing_index != EDIT_INDEX_NONE)
            &self.servers[self.editing_index]
        else blk: {
            if (self.count >= MCP_SERVER_MAX) return error.Full;
            self.count += 1;
            self.servers[self.count - 1] = .{};
            break :blk &self.servers[self.count - 1];
        };
        setBuf(&target.name, &target.name_len, name);
        setBuf(&target.command, &target.command_len, command);
        setBuf(&target.args, &target.args_len, self.formField(.args));
    }

    /// Remove `servers[index]`, shifting later entries down. Clears `probe`
    /// because a shift invalidates `probe.target_index`: without this, the
    /// render (gated on `probe.target_index == selected`) could show a stale
    /// probe result misattributed to the server that shifted into `index`.
    /// Selection is re-clamped into the new (servers + action) row range.
    pub fn removeAt(self: *State, index: usize) void {
        if (index >= self.count) return;
        for (index..self.count - 1) |i| {
            self.servers[i] = self.servers[i + 1];
        }
        self.count -= 1;
        self.probe.status = .idle;
        self.probe.target_index = 0;
        const rc = self.listRowCount();
        if (self.list_selected >= rc) self.list_selected = rc - 1;
    }

    /// Flip `enabled` on `servers[index]`.
    pub fn toggleAt(self: *State, index: usize) void {
        if (index >= self.count) return;
        self.servers[index].enabled = !self.servers[index].enabled;
    }

    /// Copy a completed `mcp_probe.probeBlocking`/`start` result into
    /// `self.probe`, tagging it with the `servers[index]` it belongs to.
    /// `r` is a plain value (no owned heap memory), so this is a straight
    /// field copy — heap-free like the rest of `State`.
    pub fn applyProbeResult(self: *State, index: usize, r: mcp_probe.Result) void {
        self.probe.target_index = index;
        self.probe.message = r.message;
        self.probe.message_len = r.message_len;
        self.probe.tools = r.tools;
        self.probe.tool_count = r.tool_count;
        self.probe.status = if (r.ok) .ok else .failed;
    }

    /// Build an owned `[]mcp_registry.ServerConfig` from `servers[0..count]`.
    /// Each server's `args` display string is split on whitespace runs.
    /// Caller frees with `mcp_registry.freeServersConfig`.
    pub fn toServerConfigs(self: *const State, allocator: std.mem.Allocator) ![]mcp_registry.ServerConfig {
        var list: std.ArrayListUnmanaged(mcp_registry.ServerConfig) = .empty;
        errdefer {
            for (list.items) |cfg| {
                allocator.free(cfg.name);
                allocator.free(cfg.command);
                for (cfg.args) |arg| allocator.free(arg);
                allocator.free(cfg.args);
            }
            list.deinit(allocator);
        }

        for (0..self.count) |i| {
            const name = try allocator.dupe(u8, self.serverName(i));
            errdefer allocator.free(name);
            const command = try allocator.dupe(u8, self.servers[i].command[0..self.servers[i].command_len]);
            errdefer allocator.free(command);

            var args: std.ArrayListUnmanaged([]u8) = .empty;
            errdefer {
                for (args.items) |arg| allocator.free(arg);
                args.deinit(allocator);
            }
            var it = std.mem.tokenizeAny(u8, self.serverArgs(i), " \t");
            while (it.next()) |tok| {
                try args.append(allocator, try allocator.dupe(u8, tok));
            }
            const args_owned = try args.toOwnedSlice(allocator);
            errdefer allocator.free(args_owned);

            try list.append(allocator, .{
                .name = name,
                .command = command,
                .args = args_owned,
                .enabled = self.servers[i].enabled,
            });
        }
        return list.toOwnedSlice(allocator);
    }

    /// Read-only JSON preview of what `save` would write.
    /// Write `servers[0..count]` to `<config-dir>/mcp.json`.
    /// The caller is responsible for triggering an MCP tools reload.
    pub fn save(self: *State, allocator: std.mem.Allocator) !void {
        const cfgs = try self.toServerConfigs(allocator);
        defer mcp_registry.freeServersConfig(allocator, cfgs);
        try mcp_registry.saveConfigFile(allocator, cfgs);
    }
};

/// Truncate-copy `src` into `buf`, recording the copied length in `len_ptr`.
fn setBuf(buf: []u8, len_ptr: *usize, src: []const u8) void {
    const len = @min(src.len, buf.len);
    @memcpy(buf[0..len], src[0..len]);
    len_ptr.* = len;
}

/// Case-insensitive substring test (ASCII). Empty needle always matches.
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn indexOfFormRow(rows: []const FormRow, target: FormRow) usize {
    for (rows, 0..) |r, i| {
        if (r == target) return i;
    }
    return 0;
}

test "FormRow.field maps text rows to fields and action rows to null" {
    try std.testing.expectEqual(Field.name, FormRow.name.field().?);
    try std.testing.expectEqual(Field.command, FormRow.command.field().?);
    try std.testing.expectEqual(Field.args, FormRow.args.field().?);
    try std.testing.expect(FormRow.save.field() == null);
    try std.testing.expect(FormRow.test_conn.field() == null);
    try std.testing.expect(FormRow.delete.field() == null);
    try std.testing.expect(FormRow.cancel.field() == null);
}

test "form focus cycles fields then action rows; delete only when editing" {
    var s: State = .{};
    // Add mode: no delete row.
    s.beginAdd();
    const add_order = [_]FormRow{ .name, .command, .args, .save, .test_conn, .cancel, .name };
    for (add_order) |expected| {
        try std.testing.expectEqual(expected, s.form_focus);
        s.formFocusNext();
    }
    // Edit mode: delete appears between test and cancel.
    s.beginAdd();
    s.setFormField(.name, "a");
    s.setFormField(.command, "x");
    try s.commitForm();
    s.beginEdit(0);
    const edit_order = [_]FormRow{ .name, .command, .args, .save, .test_conn, .delete, .cancel, .name };
    for (edit_order) |expected| {
        try std.testing.expectEqual(expected, s.form_focus);
        s.formFocusNext();
    }
    // prev walks back one step.
    s.form_focus = .name;
    s.formFocusPrev();
    try std.testing.expectEqual(FormRow.cancel, s.form_focus);
}

test "list filter narrows visible servers case-insensitively" {
    var s: State = .{};
    for ([_][]const u8{ "context7", "filesystem", "jina" }) |name| {
        s.beginAdd();
        s.setFormField(.name, name);
        s.setFormField(.command, "x");
        try s.commitForm();
    }
    try std.testing.expectEqual(@as(usize, 3), s.visibleCount());

    s.setFilter("e"); // context7 and filesystem contain 'e'; jina does not
    try std.testing.expectEqual(@as(usize, 2), s.visibleCount());
    try std.testing.expectEqualStrings("context7", s.serverName(s.visibleServerIndex(0).?));
    try std.testing.expectEqualStrings("filesystem", s.serverName(s.visibleServerIndex(1).?));
    try std.testing.expect(s.visibleServerIndex(2) == null);

    s.setFilter("JIN"); // case-insensitive, matches jina only
    try std.testing.expectEqual(@as(usize, 1), s.visibleCount());
    try std.testing.expectEqualStrings("jina", s.serverName(s.visibleServerIndex(0).?));

    s.clearListFilter();
    try std.testing.expectEqual(@as(usize, 3), s.visibleCount());
}

test "list rows = visible servers + 3 action rows; action mapping" {
    var s: State = .{};
    for ([_][]const u8{ "a", "b" }) |name| {
        s.beginAdd();
        s.setFormField(.name, name);
        s.setFormField(.command, "x");
        try s.commitForm();
    }
    try std.testing.expectEqual(@as(usize, 5), s.listRowCount());
    try std.testing.expectEqual(ListAction.server, s.listActionForRow(0));
    try std.testing.expectEqual(ListAction.server, s.listActionForRow(1));
    try std.testing.expectEqual(ListAction.new_server, s.listActionForRow(2));
    try std.testing.expectEqual(ListAction.edit_json, s.listActionForRow(3));
    try std.testing.expectEqual(ListAction.close, s.listActionForRow(4));

    // selectedServerIndex resolves server rows, null on action rows.
    s.list_selected = 1;
    try std.testing.expectEqual(@as(usize, 1), s.selectedServerIndex().?);
    s.list_selected = 3; // an action row
    try std.testing.expect(s.selectedServerIndex() == null);
}

test "moveSelection wraps across servers and action rows" {
    var s: State = .{};
    s.beginAdd();
    s.setFormField(.name, "only");
    s.setFormField(.command, "x");
    try s.commitForm(); // 1 server + 3 actions = 4 rows

    s.list_selected = 0;
    s.moveSelection(-1); // wrap to last row
    try std.testing.expectEqual(s.listRowCount() - 1, s.list_selected);
    s.moveSelection(1); // wrap back to top
    try std.testing.expectEqual(@as(usize, 0), s.list_selected);
}

test "add a server through the form" {
    var s: State = .{};
    s.beginAdd();
    s.setFormField(.name, "gh");
    s.setFormField(.command, "github-mcp");
    s.setFormField(.args, "stdio --verbose");
    try s.commitForm();
    try std.testing.expectEqual(@as(usize, 1), s.count);
    try std.testing.expectEqualStrings("gh", s.serverName(0));
    try std.testing.expectEqualStrings("stdio --verbose", s.serverArgs(0));
    try std.testing.expect(s.servers[0].enabled);
}

test "form rejects empty name, empty command, and duplicate name" {
    var s: State = .{};
    s.beginAdd();
    s.setFormField(.command, "x");
    try std.testing.expectError(error.EmptyName, s.commitForm());
    s.setFormField(.name, "a");
    s.setFormField(.command, "");
    try std.testing.expectError(error.EmptyCommand, s.commitForm());
    s.setFormField(.command, "x");
    try s.commitForm(); // "a" added
    s.beginAdd();
    s.setFormField(.name, "a");
    s.setFormField(.command, "y");
    try std.testing.expectError(error.DuplicateName, s.commitForm());
}

test "commitForm rejects a whitespace-only name and trims a padded one" {
    var s: State = .{};
    s.beginAdd();
    s.setFormField(.name, "   ");
    s.setFormField(.command, "x");
    try std.testing.expectError(error.EmptyName, s.commitForm());
    try std.testing.expectEqual(@as(usize, 0), s.count);

    s.setFormField(.name, "  gh  ");
    try s.commitForm();
    try std.testing.expectEqualStrings("gh", s.serverName(0));
}

test "toggle and remove the selected server" {
    var s: State = .{};
    s.beginAdd();
    s.setFormField(.name, "a");
    s.setFormField(.command, "x");
    try s.commitForm();
    s.list_selected = 0;
    s.toggleAt(0);
    try std.testing.expect(!s.servers[0].enabled);
    s.removeAt(0);
    try std.testing.expectEqual(@as(usize, 0), s.count);
}

test "removeAt clears a stale probe result so it isn't misattributed" {
    var s: State = .{};
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        s.beginAdd();
        var name_buf: [8]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "s{d}", .{i}) catch unreachable;
        s.setFormField(.name, name);
        s.setFormField(.command, "x");
        try s.commitForm();
    }
    try std.testing.expectEqual(@as(usize, 3), s.count);

    // Simulate a completed probe against index 1.
    const r = mcp_probe.Result{ .ok = true, .message = undefined, .message_len = 0, .tools = undefined, .tool_count = 0 };
    s.applyProbeResult(1, r);
    try std.testing.expect(s.probe.status == .ok);

    // Delete index 0; index 1's server shifts down to index 0, but the
    // stale probe result must not follow it.
    s.list_selected = 0;
    s.removeAt(0);
    try std.testing.expectEqual(@as(usize, 2), s.count);
    try std.testing.expect(s.probe.status == .idle);
}

test "open loads servers from the config dir and clamps selection" {
    const mcp_registry_dirs = @import("../../platform/dirs.zig");
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    mcp_registry_dirs.setTestConfigDirOverride(dir_path);
    defer mcp_registry_dirs.setTestConfigDirOverride(null);
    const servers = [_]mcp_registry.ServerConfig{
        .{ .name = @constCast("a"), .command = @constCast("x"), .args = &.{}, .enabled = true },
        .{ .name = @constCast("b"), .command = @constCast("y"), .args = &.{}, .enabled = false },
    };
    try mcp_registry.saveConfigFile(a, servers[0..]);

    var state: State = .{};
    state.open(a);
    try std.testing.expect(state.visible);
    try std.testing.expectEqual(@as(usize, 2), state.count);
    try std.testing.expectEqualStrings("a", state.serverName(0));
    try std.testing.expect(!state.servers[1].enabled);

    // 2 servers + 3 action rows = 5 rows; selection wraps.
    state.list_selected = 0;
    state.moveSelection(-1); // wraps to the last (close) row
    try std.testing.expectEqual(state.listRowCount() - 1, state.list_selected);
    state.moveSelection(1); // wraps back to the first server
    try std.testing.expectEqual(@as(usize, 0), state.list_selected);
}

test "edit preserves enabled state of a disabled server" {
    var s: State = .{};
    s.beginAdd();
    s.setFormField(.name, "a");
    s.setFormField(.command, "x");
    try s.commitForm();
    s.list_selected = 0;
    s.toggleAt(0);
    try std.testing.expect(!s.servers[0].enabled);

    s.beginEdit(0);
    s.setFormField(.command, "y");
    try s.commitForm();
    try std.testing.expect(!s.servers[0].enabled);
}

test "toggleAt then save persists the disabled flag to disk" {
    const mcp_registry_dirs = @import("../../platform/dirs.zig");
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    mcp_registry_dirs.setTestConfigDirOverride(dir_path);
    defer mcp_registry_dirs.setTestConfigDirOverride(null);

    var s: State = .{};
    s.beginAdd();
    s.setFormField(.name, "jina");
    s.setFormField(.command, "npx");
    try s.commitForm();
    try std.testing.expect(s.servers[0].enabled);

    s.toggleAt(0);
    try std.testing.expect(!s.servers[0].enabled);
    try s.save(a); // this is exactly what persistMcp() calls

    const loaded = try mcp_registry.loadConfigFile(a);
    defer mcp_registry.freeServersConfig(a, loaded);
    try std.testing.expectEqual(@as(usize, 1), loaded.len);
    try std.testing.expect(!loaded[0].enabled); // disabled flag round-tripped
}

test "toServerConfigs splits args and serializes to mcp.json" {
    const a = std.testing.allocator;
    var s: State = .{};
    s.beginAdd();
    s.setFormField(.name, "c");
    s.setFormField(.command, "npx");
    s.setFormField(.args, "-y  pkg");
    try s.commitForm(); // double space → 2 args

    const cfgs = try s.toServerConfigs(a);
    defer mcp_registry.freeServersConfig(a, cfgs);
    try std.testing.expectEqual(@as(usize, 1), cfgs.len);
    try std.testing.expectEqual(@as(usize, 2), cfgs[0].args.len);
    try std.testing.expectEqualStrings("pkg", cfgs[0].args[1]);

    const json = try mcp_registry.writeServersConfig(a, cfgs);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"c\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"npx\"") != null);
}

test "applyProbeResult stores tool names and status on the state" {
    var s: State = .{};
    s.beginAdd();
    s.setFormField(.name, "x");
    s.setFormField(.command, "/bin/sh");
    try s.commitForm();
    var r = mcp_probe.Result{ .ok = true, .message = undefined, .message_len = 0, .tools = undefined, .tool_count = 1 };
    @memcpy(r.tools[0][0..4], "echo");
    s.applyProbeResult(0, r);
    try std.testing.expect(s.probe.status == .ok);
    try std.testing.expectEqual(@as(usize, 1), s.probe.tool_count);
}

test "commitForm rejects a 33rd server" {
    var s: State = .{};
    var i: usize = 0;
    while (i < MCP_SERVER_MAX) : (i += 1) {
        s.beginAdd();
        var name_buf: [8]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "s{d}", .{i}) catch unreachable;
        s.setFormField(.name, name);
        s.setFormField(.command, "x");
        try s.commitForm();
    }
    try std.testing.expectEqual(@as(usize, MCP_SERVER_MAX), s.count);

    s.beginAdd();
    s.setFormField(.name, "overflow");
    s.setFormField(.command, "x");
    try std.testing.expectError(error.Full, s.commitForm());
    try std.testing.expectEqual(@as(usize, MCP_SERVER_MAX), s.count);
}
