const std = @import("std");
const command_center_state = @import("../../command/center_state.zig");
const command_palette_history_view = @import("../../command/palette_history_view.zig");

pub const FILTER_MAX: usize = 64;
pub const Mode = command_center_state.CommandPaletteMode;
pub const SourceFilter = command_palette_history_view.SourceFilter;

pub const State = struct {
    visible: bool = false,
    selected: usize = 0,
    filter: [FILTER_MAX]u8 = undefined,
    filter_len: usize = 0,
    mode: Mode = .commands,
    history_selected: usize = 0,
    history_source: SourceFilter = .all,
    history_item_count: usize = 0,

    pub fn isHistoryMode(self: *const State) bool {
        return self.mode == .agent_history;
    }

    pub fn filterSlice(self: *const State) []const u8 {
        return self.filter[0..self.filter_len];
    }

    pub fn setMode(self: *State, mode: Mode) void {
        self.mode = mode;
        if (mode == .commands) self.history_selected = 0;
    }

    pub fn openWithMode(self: *State, mode: Mode) void {
        self.visible = true;
        self.selected = 0;
        self.filter_len = 0;
        self.setMode(mode);
        self.history_selected = 0;
        self.history_item_count = 0;
    }

    pub fn close(self: *State) void {
        self.visible = false;
        self.filter_len = 0;
        self.selected = 0;
        self.setMode(.commands);
        self.history_selected = 0;
        self.history_item_count = 0;
    }

    pub fn openAgentHistory(self: *State) void {
        self.openWithMode(.agent_history);
        self.history_source = .all;
    }

    pub fn leaveAgentHistory(self: *State) void {
        self.setMode(.commands);
    }

    pub fn moveSelection(self: *State, delta: i32, count: usize) void {
        if (self.isHistoryMode()) return;
        if (count == 0) {
            self.selected = 0;
            return;
        }

        const current: i32 = @intCast(self.selected);
        const count_i: i32 = @intCast(count);
        var next = current + delta;
        while (next < 0) next += count_i;
        next = @mod(next, count_i);
        self.selected = @intCast(next);
    }

    pub fn scrollSelection(self: *State, step: i32, count: usize) void {
        if (count == 0) return;
        if (step < 0) {
            if (self.selected == 0) return;
        } else if (self.selected + 1 >= count) return;
        self.moveSelection(step, count);
    }

    pub fn clampSelection(self: *State, count: usize) void {
        if (count == 0) {
            self.selected = 0;
        } else if (self.selected >= count) {
            self.selected = count - 1;
        }
    }

    pub fn backspaceFilter(self: *State, visible_count: usize) void {
        if (self.filter_len == 0) return;
        var n = self.filter_len - 1;
        while (n > 0 and (self.filter[n] & 0xC0) == 0x80) n -= 1;
        self.filter_len = n;
        if (self.isHistoryMode()) {
            self.history_selected = 0;
        } else {
            self.clampSelection(visible_count);
        }
    }

    pub fn clearFilter(self: *State, visible_count: usize) void {
        if (self.isHistoryMode()) return;
        self.filter_len = 0;
        self.clampSelection(visible_count);
    }

    pub fn insertChar(self: *State, codepoint: u21, visible_count: usize) void {
        if (codepoint < 0x20 or codepoint == 0x7f) return;
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &buf) catch return;
        if (self.filter_len + len > self.filter.len) return;
        @memcpy(self.filter[self.filter_len..][0..len], buf[0..len]);
        self.filter_len += len;
        if (self.isHistoryMode()) {
            self.history_selected = 0;
        } else {
            self.clampSelection(visible_count);
        }
    }

    pub fn cycleHistorySource(self: *State) void {
        self.history_source = switch (self.history_source) {
            .all => .sidebar,
            .sidebar => .tab,
            .tab => .all,
        };
        self.history_selected = 0;
    }

    pub fn moveHistory(self: *State, delta: i32, row_count: usize) void {
        if (!self.isHistoryMode()) return;
        if (row_count == 0) {
            self.history_selected = 0;
            return;
        }

        const current: i32 = @intCast(@min(self.history_selected, row_count - 1));
        const count_i: i32 = @intCast(row_count);
        var next = current + delta;
        while (next < 0) next += count_i;
        next = @mod(next, count_i);
        self.history_selected = @intCast(next);
    }

    pub fn clampHistorySelection(self: *State, row_count: usize) void {
        if (!self.isHistoryMode() or row_count == 0) {
            self.history_selected = 0;
            return;
        }
        self.history_selected = @min(self.history_selected, row_count - 1);
    }

    pub fn selectedHistoryIndex(self: *const State, row_count: usize) ?usize {
        if (!self.isHistoryMode() or row_count == 0) return null;
        return @min(self.history_selected, row_count - 1);
    }

    pub fn activateHistoryRow(self: *State, row_idx: usize, row_count: usize) ?usize {
        if (!self.isHistoryMode() or row_idx >= row_count) return null;
        self.history_selected = row_idx;
        return row_idx;
    }

    pub fn setFilterForTest(self: *State, filter_text: []const u8) void {
        const len = @min(filter_text.len, self.filter.len);
        @memcpy(self.filter[0..len], filter_text[0..len]);
        self.filter_len = len;
        self.selected = 0;
    }
};

test "command palette state edits UTF-8 filter by codepoint" {
    var state: State = .{};
    state.insertChar('a', 10);
    state.insertChar(0x8BBE, 10);
    state.insertChar(0x7F6E, 10);
    try std.testing.expectEqualStrings("a设置", state.filterSlice());
    state.backspaceFilter(10);
    try std.testing.expectEqualStrings("a设", state.filterSlice());
    state.backspaceFilter(10);
    try std.testing.expectEqualStrings("a", state.filterSlice());
}

test "command palette state moves and clamps command selection" {
    var state: State = .{ .selected = 1 };
    state.moveSelection(1, 3);
    try std.testing.expectEqual(@as(usize, 2), state.selected);
    state.moveSelection(1, 3);
    try std.testing.expectEqual(@as(usize, 0), state.selected);
    state.selected = 9;
    state.clampSelection(3);
    try std.testing.expectEqual(@as(usize, 2), state.selected);
}

test "command palette state cycles history source and selection" {
    var state: State = .{};
    state.openAgentHistory();
    state.history_selected = 3;
    state.cycleHistorySource();
    try std.testing.expectEqual(SourceFilter.sidebar, state.history_source);
    try std.testing.expectEqual(@as(usize, 0), state.history_selected);
    state.moveHistory(1, 2);
    try std.testing.expectEqual(@as(?usize, 1), state.selectedHistoryIndex(2));
}
