const std = @import("std");

pub const FEISHU_FIELD_COUNT: usize = 2; // text fields: app_id, app_secret (buffer count)
pub const FEISHU_FIELD_MAX: usize = 256;

// Form rows: 0 = enabled toggle, 1 = app_id, 2 = app_secret, 3 = Save.
pub const FEISHU_ROW_COUNT: usize = 4;
pub const ENABLED_ROW: usize = 0;
pub const SAVE_ROW: usize = FEISHU_ROW_COUNT - 1;

pub const FeishuField = enum(usize) {
    app_id = 0,
    app_secret = 1,
};

/// 凭证表单的固定缓冲区状态(镜像 assistant_profiles.State 的最小子集)。
/// focus: 0 = 启用开关行;1 = app_id;2 = app_secret;3 = Save 行。
pub const State = struct {
    enabled: bool = false,
    bufs: [FEISHU_FIELD_COUNT][FEISHU_FIELD_MAX]u8 = undefined,
    lens: [FEISHU_FIELD_COUNT]usize = .{0} ** FEISHU_FIELD_COUNT,
    focus: usize = 0,

    pub fn reset(self: *State) void {
        self.lens = .{0} ** FEISHU_FIELD_COUNT;
        self.focus = 0;
        self.enabled = false;
    }

    pub fn value(self: *const State, field: FeishuField) []const u8 {
        const i = @intFromEnum(field);
        return self.bufs[i][0..self.lens[i]];
    }

    pub fn setValue(self: *State, field: FeishuField, text: []const u8) void {
        const i = @intFromEnum(field);
        const n = @min(text.len, FEISHU_FIELD_MAX);
        @memcpy(self.bufs[i][0..n], text[0..n]);
        self.lens[i] = n;
    }

    pub fn append(self: *State, field: FeishuField, bytes: []const u8) void {
        const i = @intFromEnum(field);
        for (bytes) |b| {
            if (self.lens[i] >= FEISHU_FIELD_MAX) return; // 截断,不溢出
            self.bufs[i][self.lens[i]] = b;
            self.lens[i] += 1;
        }
    }

    pub fn backspace(self: *State, field: FeishuField) void {
        const i = @intFromEnum(field);
        if (self.lens[i] == 0) return;
        var n = self.lens[i] - 1;
        while (n > 0 and (self.bufs[i][n] & 0xC0) == 0x80) : (n -= 1) {} // 退一个 UTF-8 码点
        self.lens[i] = n;
    }

    /// 焦点所在行对应的文本字段(仅 row 1/2),启用行/Save 行返回 null。
    pub fn focusedField(self: *const State) ?FeishuField {
        return switch (self.focus) {
            1 => .app_id,
            2 => .app_secret,
            else => null,
        };
    }

    pub fn toggleEnabled(self: *State) void {
        self.enabled = !self.enabled;
    }

    pub fn focusNextRow(self: *State) void {
        if (self.focus < FEISHU_ROW_COUNT - 1) self.focus += 1; // 上限 = Save 行
    }

    pub fn focusPrevRow(self: *State) void {
        if (self.focus > 0) self.focus -= 1;
    }
};

test "append then value round-trips" {
    var s = State{};
    s.append(.app_id, "cli_abc123");
    try std.testing.expectEqualStrings("cli_abc123", s.value(.app_id));
    try std.testing.expectEqualStrings("", s.value(.app_secret));
}

test "append truncates at FEISHU_FIELD_MAX without overflow" {
    var s = State{};
    const big = "x" ** (FEISHU_FIELD_MAX + 50);
    s.append(.app_secret, big);
    try std.testing.expectEqual(FEISHU_FIELD_MAX, s.value(.app_secret).len);
}

test "backspace drops one byte and is a no-op when empty" {
    var s = State{};
    s.append(.app_id, "ab");
    s.backspace(.app_id);
    try std.testing.expectEqualStrings("a", s.value(.app_id));
    s.backspace(.app_id);
    s.backspace(.app_id); // empty -> no-op, no underflow
    try std.testing.expectEqualStrings("", s.value(.app_id));
}

test "backspace drops a whole multibyte codepoint" {
    var s = State{};
    s.append(.app_id, "a\u{4f60}"); // "a你"
    s.backspace(.app_id);
    try std.testing.expectEqualStrings("a", s.value(.app_id));
}

test "setValue replaces and truncates" {
    var s = State{};
    s.append(.app_id, "old");
    s.setValue(.app_id, "new-id");
    try std.testing.expectEqualStrings("new-id", s.value(.app_id));
    const big = "y" ** (FEISHU_FIELD_MAX + 10);
    s.setValue(.app_secret, big);
    try std.testing.expectEqual(FEISHU_FIELD_MAX, s.value(.app_secret).len);
}

test "focus navigation clamps over enabled, fields, and Save row" {
    var s = State{};
    try std.testing.expectEqual(@as(usize, 0), s.focus);
    s.focusPrevRow(); // clamp at enabled row
    try std.testing.expectEqual(ENABLED_ROW, s.focus);
    s.focusNextRow(); // app_id
    s.focusNextRow(); // app_secret
    s.focusNextRow(); // Save row
    try std.testing.expectEqual(SAVE_ROW, s.focus);
    s.focusNextRow(); // clamp at Save row
    try std.testing.expectEqual(SAVE_ROW, s.focus);
}

test "focusedField maps only text rows to fields" {
    var s = State{};
    s.focus = ENABLED_ROW;
    try std.testing.expect(s.focusedField() == null);
    s.focus = 1;
    try std.testing.expect(s.focusedField() == .app_id);
    s.focus = 2;
    try std.testing.expect(s.focusedField() == .app_secret);
    s.focus = SAVE_ROW;
    try std.testing.expect(s.focusedField() == null);
}

test "toggleEnabled flips the enabled flag" {
    var s = State{};
    try std.testing.expect(!s.enabled);
    s.toggleEnabled();
    try std.testing.expect(s.enabled);
    s.toggleEnabled();
    try std.testing.expect(!s.enabled);
}

test "reset clears lengths, focus, and enabled" {
    var s = State{};
    s.append(.app_id, "x");
    s.focus = SAVE_ROW;
    s.enabled = true;
    s.reset();
    try std.testing.expectEqual(@as(usize, 0), s.value(.app_id).len);
    try std.testing.expectEqual(@as(usize, 0), s.focus);
    try std.testing.expect(!s.enabled);
}
