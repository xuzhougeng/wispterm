const std = @import("std");
const rule_mod = @import("rule.zig");

pub const FormMode = enum { new, edit };

/// Form field indices in focus order. Referenced by the input router
/// (AppWindow.portForwardingFormAdjust) and the form renderer; adding or
/// removing a field means updating all three switch sites plus the count.
pub const FIELD_NAME: usize = 0;
pub const FIELD_PROFILE: usize = 1;
pub const FIELD_DIRECTION: usize = 2;
pub const FIELD_LOCAL_HOST: usize = 3;
pub const FIELD_LOCAL_PORT: usize = 4;
pub const FIELD_REMOTE_HOST: usize = 5;
pub const FIELD_REMOTE_PORT: usize = 6;
pub const FIELD_AUTO_START: usize = 7;
pub const FORM_FIELD_COUNT: usize = 8;

comptime {
    std.debug.assert(FIELD_AUTO_START + 1 == FORM_FIELD_COUNT);
}

pub const FormState = struct {
    mode: FormMode,
    edit_index: ?usize,
    focus: usize = 0,
    rule: rule_mod.Rule,

    pub fn new(profile_name: []const u8) FormState {
        return .{
            .mode = .new,
            .edit_index = null,
            .rule = rule_mod.defaultReverseProxy(profile_name),
        };
    }

    pub fn edit(index: usize, rule: rule_mod.Rule) FormState {
        return .{
            .mode = .edit,
            .edit_index = index,
            .rule = rule,
        };
    }

    pub fn moveFocus(self: *FormState, delta: isize) void {
        self.focus = moveIndexClamped(self.focus, delta, FORM_FIELD_COUNT);
    }

    pub fn insertChar(self: *FormState, ch: u8) void {
        if (!isPrintableAscii(ch)) return;
        switch (self.focus) {
            FIELD_NAME => _ = appendAscii(&self.rule.name_buf, &self.rule.name_len, ch),
            // FIELD_PROFILE is a selector cycled with arrows/space, not typed.
            FIELD_LOCAL_HOST => _ = appendAscii(&self.rule.local_host_buf, &self.rule.local_host_len, ch),
            FIELD_LOCAL_PORT => insertPortDigit(&self.rule.local_port, ch),
            FIELD_REMOTE_HOST => _ = appendAscii(&self.rule.remote_host_buf, &self.rule.remote_host_len, ch),
            FIELD_REMOTE_PORT => insertPortDigit(&self.rule.remote_port, ch),
            else => {},
        }
    }

    pub fn backspace(self: *FormState) void {
        switch (self.focus) {
            FIELD_NAME => truncateText(&self.rule.name_len),
            // FIELD_PROFILE is a selector cycled with arrows/space, not typed.
            FIELD_LOCAL_HOST => truncateText(&self.rule.local_host_len),
            FIELD_LOCAL_PORT => backspacePort(&self.rule.local_port),
            FIELD_REMOTE_HOST => truncateText(&self.rule.remote_host_len),
            FIELD_REMOTE_PORT => backspacePort(&self.rule.remote_port),
            else => {},
        }
    }

    pub fn toggleFocused(self: *FormState) void {
        switch (self.focus) {
            FIELD_DIRECTION => self.rule.direction = switch (self.rule.direction) {
                .local => .reverse,
                .reverse => .local,
            },
            FIELD_AUTO_START => self.rule.auto_start = !self.rule.auto_start,
            else => {},
        }
    }
};

pub const ConfirmState = struct {
    index: usize,
    text: []u8,

    pub fn init(allocator: std.mem.Allocator, index: usize, name: []const u8) !ConfirmState {
        return .{
            .index = index,
            .text = try std.fmt.allocPrint(allocator, "Delete {s}? Enter confirms, Esc cancels.", .{name}),
        };
    }

    pub fn deinit(self: *ConfirmState, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub const Overlay = union(enum) {
    none,
    form: FormState,
    confirm_delete: ConfirmState,

    pub fn deinit(self: *Overlay, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .none => {},
            .form => {},
            .confirm_delete => |*confirm_state| confirm_state.deinit(allocator),
        }
        self.* = .none;
    }
};

pub const PanelModel = struct {
    allocator: std.mem.Allocator,
    sel_row: usize = 0,
    scroll: usize = 0,
    overlay: Overlay = .none,

    pub fn init(allocator: std.mem.Allocator) PanelModel {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PanelModel) void {
        self.overlay.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn move(self: *PanelModel, delta: isize, row_count: usize) void {
        self.sel_row = moveIndexClamped(self.sel_row, delta, row_count);
        self.clamp(row_count);
    }

    pub fn clamp(self: *PanelModel, row_count: usize) void {
        if (row_count == 0) {
            self.sel_row = 0;
            self.scroll = 0;
            return;
        }
        if (self.sel_row >= row_count) self.sel_row = row_count - 1;
        if (self.scroll >= row_count) self.scroll = row_count - 1;
        if (self.scroll > self.sel_row) self.scroll = self.sel_row;
    }

    pub fn setOverlay(self: *PanelModel, overlay: Overlay) void {
        self.overlay.deinit(self.allocator);
        self.overlay = overlay;
    }

    pub fn clearOverlay(self: *PanelModel) void {
        self.overlay.deinit(self.allocator);
    }

    pub fn openNewForm(self: *PanelModel, profile_name: []const u8) !void {
        self.setOverlay(.{ .form = FormState.new(profile_name) });
    }

    pub fn openEditForm(self: *PanelModel, index: usize, rule: rule_mod.Rule) !void {
        self.setOverlay(.{ .form = FormState.edit(index, rule) });
    }

    pub fn openDeleteConfirm(self: *PanelModel, index: usize, name: []const u8) !void {
        const confirm_state = try ConfirmState.init(self.allocator, index, name);
        self.setOverlay(.{ .confirm_delete = confirm_state });
    }

    pub fn form(self: *PanelModel) ?*FormState {
        return switch (self.overlay) {
            .form => |*form_state| form_state,
            else => null,
        };
    }

    pub fn confirm(self: *PanelModel) ?*ConfirmState {
        return switch (self.overlay) {
            .confirm_delete => |*confirm_state| confirm_state,
            else => null,
        };
    }
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    model: PanelModel,

    pub fn create(allocator: std.mem.Allocator) !Session {
        return .{
            .allocator = allocator,
            .model = PanelModel.init(allocator),
        };
    }

    pub fn destroy(self: *Session) void {
        self.mutex.lock();
        self.model.deinit();
        self.mutex.unlock();
        self.* = undefined;
    }
};

fn moveIndexClamped(current: usize, delta: isize, count: usize) usize {
    if (count == 0) return 0;
    const max_index = count - 1;
    const base = @min(current, max_index);
    if (delta >= 0) {
        const amount: usize = @intCast(delta);
        return if (amount > max_index - base) max_index else base + amount;
    }

    const amount: usize = @as(usize, @intCast(-(delta + 1))) + 1;
    return if (amount > base) 0 else base - amount;
}

fn truncateText(len: *usize) void {
    if (len.* > 0) len.* -= 1;
}

fn insertPortDigit(port: *u16, ch: u8) void {
    if (ch < '0' or ch > '9') return;
    const next = @as(u32, port.*) * 10 + (ch - '0');
    if (next > std.math.maxInt(u16)) return;
    port.* = @intCast(next);
}

fn backspacePort(port: *u16) void {
    port.* /= 10;
}

fn appendAscii(buf: anytype, len: *usize, ch: u8) bool {
    if (!isPrintableAscii(ch)) return false;
    const slice = buf[0..];
    if (len.* >= slice.len) return false;
    slice[len.*] = ch;
    len.* += 1;
    return true;
}

fn isPrintableAscii(ch: u8) bool {
    return ch >= 0x20 and ch <= 0x7e;
}

test "port_forwarding: selection clamps to row count" {
    var session = try Session.create(std.testing.allocator);
    defer session.destroy();
    session.model.move(1, 0);
    try std.testing.expectEqual(@as(usize, 0), session.model.sel_row);
    session.model.move(1, 3);
    try std.testing.expectEqual(@as(usize, 1), session.model.sel_row);
    session.model.move(99, 3);
    try std.testing.expectEqual(@as(usize, 2), session.model.sel_row);
    session.model.move(-99, 3);
    try std.testing.expectEqual(@as(usize, 0), session.model.sel_row);
}

test "port_forwarding: new form defaults to reverse proxy" {
    var session = try Session.create(std.testing.allocator);
    defer session.destroy();
    try session.model.openNewForm("devbox");
    const form = session.model.form() orelse return error.ExpectedForm;
    try std.testing.expectEqual(FormMode.new, form.mode);
    try std.testing.expectEqual(rule_mod.Direction.reverse, form.rule.direction);
    try std.testing.expectEqualStrings("devbox", form.rule.profileName());
}

test "port_forwarding: delete confirmation records selected index" {
    var session = try Session.create(std.testing.allocator);
    defer session.destroy();
    try session.model.openDeleteConfirm(2, "Local proxy");
    const confirm = session.model.confirm() orelse return error.ExpectedConfirm;
    try std.testing.expectEqual(@as(usize, 2), confirm.index);
    try std.testing.expectEqualStrings("Delete Local proxy? Enter confirms, Esc cancels.", confirm.text);
}

test "port_forwarding: form focus clamps" {
    var session = try Session.create(std.testing.allocator);
    defer session.destroy();
    try session.model.openNewForm("devbox");
    const form_state = session.model.form() orelse return error.ExpectedForm;

    form_state.moveFocus(99);
    try std.testing.expectEqual(FORM_FIELD_COUNT - 1, form_state.focus);
    form_state.moveFocus(-99);
    try std.testing.expectEqual(@as(usize, 0), form_state.focus);
}

test "port_forwarding: form edits text and port fields" {
    var session = try Session.create(std.testing.allocator);
    defer session.destroy();
    try session.model.openNewForm("devbox");
    const form_state = session.model.form() orelse return error.ExpectedForm;

    form_state.rule.setName("");
    form_state.insertChar('A');
    form_state.insertChar('\n');
    form_state.insertChar(0x7f);
    try std.testing.expectEqualStrings("A", form_state.rule.name());
    form_state.backspace();
    try std.testing.expectEqualStrings("", form_state.rule.name());

    form_state.moveFocus(4);
    form_state.backspace();
    try std.testing.expectEqual(@as(u16, 789), form_state.rule.local_port);
    form_state.insertChar('1');
    form_state.insertChar('x');
    try std.testing.expectEqual(@as(u16, 7891), form_state.rule.local_port);
}

test "port_forwarding: profile field ignores typed input (it is a selector)" {
    var session = try Session.create(std.testing.allocator);
    defer session.destroy();
    try session.model.openNewForm("devbox");
    const form_state = session.model.form() orelse return error.ExpectedForm;

    form_state.moveFocus(1);
    try std.testing.expectEqual(@as(usize, 1), form_state.focus);
    form_state.insertChar('x');
    try std.testing.expectEqualStrings("devbox", form_state.rule.profileName());
    form_state.backspace();
    try std.testing.expectEqualStrings("devbox", form_state.rule.profileName());
}

test "port_forwarding: form toggles direction and auto start" {
    var session = try Session.create(std.testing.allocator);
    defer session.destroy();
    try session.model.openNewForm("devbox");
    const form_state = session.model.form() orelse return error.ExpectedForm;

    form_state.moveFocus(2);
    form_state.toggleFocused();
    try std.testing.expectEqual(rule_mod.Direction.local, form_state.rule.direction);

    form_state.moveFocus(5);
    form_state.toggleFocused();
    try std.testing.expect(!form_state.rule.auto_start);
}

test "port_forwarding: opening form replaces delete confirmation" {
    var session = try Session.create(std.testing.allocator);
    defer session.destroy();
    try session.model.openDeleteConfirm(1, "Local proxy");
    try std.testing.expect(session.model.confirm() != null);

    try session.model.openNewForm("devbox");
    try std.testing.expect(session.model.confirm() == null);
    try std.testing.expect(session.model.form() != null);
}

test "port_forwarding: appendAscii accepts fixed buffers and printable ASCII only" {
    var one: [1]u8 = undefined;
    var one_len: usize = 0;
    try std.testing.expect(appendAscii(&one, &one_len, 'A'));
    try std.testing.expectEqualStrings("A", one[0..one_len]);
    try std.testing.expect(!appendAscii(&one, &one_len, 'B'));

    var host: [rule_mod.HOST_MAX]u8 = undefined;
    var host_len: usize = 0;
    try std.testing.expect(appendAscii(&host, &host_len, 'x'));
    try std.testing.expect(!appendAscii(&host, &host_len, '\n'));
    try std.testing.expect(!appendAscii(&host, &host_len, 0x7f));
    try std.testing.expectEqualStrings("x", host[0..host_len]);
}
