const std = @import("std");
const profile_codec = @import("profile_codec.zig");

pub const SSH_FIELD_COUNT = profile_codec.SSH_FIELD_COUNT;
pub const SSH_FIELD_MAX = profile_codec.SSH_FIELD_MAX;
pub const SSH_PROFILE_MAX: usize = 128;
pub const SSH_PROFILE_NONE: usize = std.math.maxInt(usize);
/// Form rows = 8 fields + 3 action rows (save+connect, save, cancel).
pub const SSH_FORM_ROW_COUNT = SSH_FIELD_COUNT + 3;
pub const SshField = profile_codec.SshField;
pub const SshProfile = profile_codec.SshProfile;

pub const SshListMode = enum {
    manage,
    edit_select,
    delete_select,
    ai_history_select,
    tmux_connect,
};

pub const State = struct {
    focus: usize = @intFromEnum(SshField.name),
    bufs: [SSH_FIELD_COUNT][SSH_FIELD_MAX]u8 = undefined,
    lens: [SSH_FIELD_COUNT]usize = .{0} ** SSH_FIELD_COUNT,
    profiles: [SSH_PROFILE_MAX]SshProfile = undefined,
    profile_count: usize = 0,
    profiles_loaded: bool = false,
    list_selected: usize = 0,
    list_mode: SshListMode = .manage,
    list_filter_buf: [SSH_FIELD_MAX]u8 = undefined,
    list_filter_len: usize = 0,
    delete_selected: [SSH_PROFILE_MAX]bool = .{false} ** SSH_PROFILE_MAX,
    edit_index: usize = SSH_PROFILE_NONE,

    pub fn formField(self: *const State, field: SshField) []const u8 {
        const idx = @intFromEnum(field);
        return self.bufs[idx][0..self.lens[idx]];
    }

    pub fn setFormField(self: *State, field: SshField, value: []const u8) void {
        const idx = @intFromEnum(field);
        const len = @min(value.len, SSH_FIELD_MAX);
        @memcpy(self.bufs[idx][0..len], value[0..len]);
        self.lens[idx] = len;
    }

    pub fn resetForm(self: *State) void {
        self.lens = .{0} ** SSH_FIELD_COUNT;
        self.focus = @intFromEnum(SshField.name);
        self.edit_index = SSH_PROFILE_NONE;
    }

    pub fn focusNextRow(self: *State) void {
        self.focus = (self.focus + 1) % SSH_FORM_ROW_COUNT;
    }

    pub fn focusPrevRow(self: *State) void {
        self.focus = if (self.focus == 0) SSH_FORM_ROW_COUNT - 1 else self.focus - 1;
    }

    pub fn listFilter(self: *const State) []const u8 {
        return self.list_filter_buf[0..self.list_filter_len];
    }

    pub fn clearListFilter(self: *State) void {
        self.list_filter_len = 0;
    }
};

test "ssh form field set/get round-trips through fixed buffers" {
    const state = try std.testing.allocator.create(State);
    defer std.testing.allocator.destroy(state);
    state.* = .{};

    state.setFormField(.name, "web-01");
    state.setFormField(.ip, "10.0.0.5");

    try std.testing.expectEqualStrings("web-01", state.formField(.name));
    try std.testing.expectEqualStrings("10.0.0.5", state.formField(.ip));
    try std.testing.expectEqualStrings("", state.formField(.user));
}

test "ssh form focus navigation wraps over field and action rows" {
    const state = try std.testing.allocator.create(State);
    defer std.testing.allocator.destroy(state);
    state.* = .{ .focus = 0 };

    state.focusPrevRow();
    try std.testing.expectEqual(SSH_FORM_ROW_COUNT - 1, state.focus);

    state.focusNextRow();
    try std.testing.expectEqual(@as(usize, 0), state.focus);
}

test "ssh form reset clears fields and edit index" {
    const state = try std.testing.allocator.create(State);
    defer std.testing.allocator.destroy(state);
    state.* = .{};
    state.setFormField(.name, "x");
    state.focus = 4;
    state.edit_index = 7;

    state.resetForm();

    try std.testing.expectEqualStrings("", state.formField(.name));
    try std.testing.expectEqual(@intFromEnum(SshField.name), state.focus);
    try std.testing.expectEqual(SSH_PROFILE_NONE, state.edit_index);
}

test "ssh list filter accessor and clear" {
    const state = try std.testing.allocator.create(State);
    defer std.testing.allocator.destroy(state);
    state.* = .{};
    @memcpy(state.list_filter_buf[0..3], "web");
    state.list_filter_len = 3;

    try std.testing.expectEqualStrings("web", state.listFilter());
    state.clearListFilter();
    try std.testing.expectEqualStrings("", state.listFilter());
}
