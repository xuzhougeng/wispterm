const std = @import("std");
const profile_codec = @import("profile_codec.zig");

pub const AI_FIELD_COUNT = profile_codec.AI_FIELD_COUNT;
pub const AI_FIELD_MAX = profile_codec.AI_FIELD_MAX;
pub const AI_PROFILE_MAX: usize = 16;
pub const AI_PROFILE_NONE: usize = std.math.maxInt(usize);
/// Form rows = 12 fields + 3 action rows (save+connect, save, cancel).
pub const AI_FORM_ROW_COUNT = AI_FIELD_COUNT + 3;
pub const AiField = profile_codec.AiField;
pub const AiProfile = profile_codec.AiProfile;

pub const AiListMode = enum {
    manage,
    edit_select,
    delete_select,
    switch_model,
};

pub const State = struct {
    focus: usize = @intFromEnum(AiField.name),
    bufs: [AI_FIELD_COUNT][AI_FIELD_MAX]u8 = undefined,
    lens: [AI_FIELD_COUNT]usize = .{0} ** AI_FIELD_COUNT,
    profiles: [AI_PROFILE_MAX]AiProfile = undefined,
    profile_count: usize = 0,
    profiles_loaded: bool = false,
    list_selected: usize = 0,
    list_mode: AiListMode = .manage,
    edit_index: usize = AI_PROFILE_NONE,

    pub fn formField(self: *const State, field: AiField) []const u8 {
        const idx = @intFromEnum(field);
        return self.bufs[idx][0..self.lens[idx]];
    }

    pub fn setFormField(self: *State, field: AiField, value: []const u8) void {
        const idx = @intFromEnum(field);
        const len = @min(value.len, AI_FIELD_MAX);
        @memcpy(self.bufs[idx][0..len], value[0..len]);
        self.lens[idx] = len;
    }

    pub fn resetForm(self: *State) void {
        self.lens = .{0} ** AI_FIELD_COUNT;
        self.focus = @intFromEnum(AiField.name);
        self.edit_index = AI_PROFILE_NONE;
    }

    pub fn focusNextRow(self: *State) void {
        self.focus = (self.focus + 1) % AI_FORM_ROW_COUNT;
    }

    pub fn focusPrevRow(self: *State) void {
        self.focus = if (self.focus == 0) AI_FORM_ROW_COUNT - 1 else self.focus - 1;
    }
};

test "ai form field set/get round-trips through fixed buffers" {
    const state = try std.testing.allocator.create(State);
    defer std.testing.allocator.destroy(state);
    state.* = .{};

    state.setFormField(.name, "claude");
    state.setFormField(.base_url, "https://api.test");

    try std.testing.expectEqualStrings("claude", state.formField(.name));
    try std.testing.expectEqualStrings("https://api.test", state.formField(.base_url));
    try std.testing.expectEqualStrings("", state.formField(.model));
}

test "ai form focus navigation wraps over field and action rows" {
    const state = try std.testing.allocator.create(State);
    defer std.testing.allocator.destroy(state);
    state.* = .{ .focus = 0 };

    state.focusPrevRow();
    try std.testing.expectEqual(AI_FORM_ROW_COUNT - 1, state.focus);

    state.focusNextRow();
    try std.testing.expectEqual(@as(usize, 0), state.focus);
}

test "ai form reset clears fields and edit index" {
    const state = try std.testing.allocator.create(State);
    defer std.testing.allocator.destroy(state);
    state.* = .{};
    state.setFormField(.name, "x");
    state.focus = 5;
    state.edit_index = 3;

    state.resetForm();

    try std.testing.expectEqualStrings("", state.formField(.name));
    try std.testing.expectEqual(@intFromEnum(AiField.name), state.focus);
    try std.testing.expectEqual(AI_PROFILE_NONE, state.edit_index);
}
