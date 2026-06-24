const std = @import("std");
const input_key = @import("../../input/key.zig");
const Config = @import("../../config.zig");

pub const SETTINGS_THEME_ROW: usize = 1;
pub const SETTINGS_CONTROL_ROW_START: usize = 2;
pub const SETTINGS_ROW_COUNT: usize = SETTINGS_CONTROL_ROW_START + 12;

pub const Action = enum {
    font_size_minus,
    font_size_plus,
    cycle_theme,
    cycle_theme_prev,
    cycle_cursor_style,
    toggle_cursor_blink,
    toggle_focus_follows_mouse,
    cycle_shell,
    cycle_default_ai_profile,
    cycle_default_ai_profile_prev,
    toggle_weixin_direct,
    cycle_language,
    toggle_restore_tabs,
    toggle_distill_suggest,
    open_raw_config,
    restore_defaults,
    close,
};

pub const State = struct {
    visible: bool = false,
    focus: usize = SETTINGS_THEME_ROW,
    cfg_dirty: bool = true,
    cfg_cache: Config = .{},

    pub fn open(self: *State) void {
        self.visible = true;
        self.focus = SETTINGS_THEME_ROW;
        self.cfg_dirty = true;
    }

    pub fn close(self: *State, allocator: ?std.mem.Allocator) void {
        self.visible = false;
        if (!self.cfg_dirty) {
            if (allocator) |alloc| self.cfg_cache.deinit(alloc);
            self.cfg_cache = .{};
            self.cfg_dirty = true;
        }
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (!self.cfg_dirty) self.cfg_cache.deinit(allocator);
        self.cfg_cache = .{};
        self.cfg_dirty = true;
        self.visible = false;
    }

    pub fn reloadConfig(self: *State) void {
        self.cfg_dirty = true;
    }

    pub fn cfg(self: *State, allocator: std.mem.Allocator) *Config {
        if (self.cfg_dirty) {
            self.cfg_cache.deinit(allocator);
            self.cfg_cache = Config.load(allocator) catch Config{};
            self.cfg_dirty = false;
        }
        return &self.cfg_cache;
    }

    pub fn handleKey(self: *State, ev: input_key.KeyEvent) ?Action {
        switch (ev.key) {
            .escape => return .close,
            .arrow_down, .tab => {
                self.focus = (self.focus + 1) % SETTINGS_ROW_COUNT;
                return null;
            },
            .arrow_up => {
                self.focus = if (self.focus == 0) SETTINGS_ROW_COUNT - 1 else self.focus - 1;
                return null;
            },
            .arrow_left => return self.focusLeftAction(),
            .arrow_right => return self.focusRightAction(),
            .enter => return self.focusPrimaryAction(),
            else => return null,
        }
    }

    pub fn handleScroll(self: *State, delta_y: f64) void {
        if (!self.visible) return;
        if (delta_y > 0) {
            if (self.focus > 0) self.focus -= 1;
        } else if (delta_y < 0) {
            if (self.focus + 1 < SETTINGS_ROW_COUNT) self.focus += 1;
        }
    }

    pub fn firstVisibleRow(self: *const State, visible_rows: usize) usize {
        if (visible_rows == 0 or SETTINGS_ROW_COUNT <= visible_rows) return 0;
        const focus = @min(self.focus, SETTINGS_ROW_COUNT - 1);
        if (focus < visible_rows) return 0;
        return @min(focus - visible_rows + 1, SETTINGS_ROW_COUNT - visible_rows);
    }

    pub fn focusPrimaryAction(self: *const State) ?Action {
        return switch (self.focus) {
            0 => .font_size_plus,
            SETTINGS_THEME_ROW => .cycle_theme,
            SETTINGS_CONTROL_ROW_START + 0 => .cycle_cursor_style,
            SETTINGS_CONTROL_ROW_START + 1 => .toggle_cursor_blink,
            SETTINGS_CONTROL_ROW_START + 2 => .toggle_focus_follows_mouse,
            SETTINGS_CONTROL_ROW_START + 3 => .cycle_shell,
            SETTINGS_CONTROL_ROW_START + 4 => .cycle_default_ai_profile,
            SETTINGS_CONTROL_ROW_START + 5 => .toggle_weixin_direct,
            SETTINGS_CONTROL_ROW_START + 6 => .cycle_language,
            SETTINGS_CONTROL_ROW_START + 7 => .toggle_restore_tabs,
            SETTINGS_CONTROL_ROW_START + 8 => .toggle_distill_suggest,
            SETTINGS_CONTROL_ROW_START + 9 => .open_raw_config,
            SETTINGS_CONTROL_ROW_START + 10 => .restore_defaults,
            SETTINGS_CONTROL_ROW_START + 11 => .close,
            else => null,
        };
    }

    pub fn focusLeftAction(self: *const State) ?Action {
        return switch (self.focus) {
            0 => .font_size_minus,
            SETTINGS_THEME_ROW => .cycle_theme_prev,
            SETTINGS_CONTROL_ROW_START + 4 => .cycle_default_ai_profile_prev,
            else => null,
        };
    }

    pub fn focusRightAction(self: *const State) ?Action {
        return switch (self.focus) {
            0 => .font_size_plus,
            SETTINGS_THEME_ROW => .cycle_theme,
            else => self.focusPrimaryAction(),
        };
    }
};

test "settings page state open resets focus and marks config dirty" {
    var state = State{ .visible = false, .focus = 4, .cfg_dirty = false };

    state.open();

    try std.testing.expect(state.visible);
    try std.testing.expectEqual(SETTINGS_THEME_ROW, state.focus);
    try std.testing.expect(state.cfg_dirty);
}

test "settings page key navigation wraps and returns side-effect actions" {
    var state = State{ .visible = true, .focus = 0 };

    try std.testing.expectEqual(@as(?Action, null), state.handleKey(.{ .key = .arrow_up }));
    try std.testing.expectEqual(SETTINGS_ROW_COUNT - 1, state.focus);

    try std.testing.expectEqual(@as(?Action, null), state.handleKey(.{ .key = .arrow_down }));
    try std.testing.expectEqual(@as(usize, 0), state.focus);

    try std.testing.expectEqual(Action.font_size_plus, state.handleKey(.{ .key = .enter }).?);
    try std.testing.expectEqual(Action.font_size_minus, state.handleKey(.{ .key = .arrow_left }).?);
    try std.testing.expectEqual(Action.close, state.handleKey(.{ .key = .escape }).?);
}

test "settings page first visible row keeps focus in short view" {
    var state = State{ .visible = true, .focus = SETTINGS_ROW_COUNT - 1 };

    const scroll = state.firstVisibleRow(3);

    try std.testing.expect(scroll <= state.focus);
    try std.testing.expect(state.focus < scroll + 3);
}
