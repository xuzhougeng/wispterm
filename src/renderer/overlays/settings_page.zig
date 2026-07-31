const std = @import("std");
const input_key = @import("../../input/key.zig");
const Config = @import("../../config.zig");
const shell_integration = @import("../../platform/shell_integration.zig");
const settings_picker = @import("settings_picker.zig");
const settings_page_layout = @import("settings_page_layout.zig");

pub const SETTINGS_FONT_FAMILY_ROW: usize = 0;
pub const SETTINGS_FONT_SIZE_ROW: usize = 1;
pub const SETTINGS_THEME_ROW: usize = 2;
pub const SETTINGS_CONTROL_ROW_START: usize = 3;
pub const SHELL_INTEGRATION_ROWS: usize = if (shell_integration.supported) 2 else 0;
pub const SETTINGS_RAW_CONFIG_ROW: usize = SETTINGS_CONTROL_ROW_START + 9 + SHELL_INTEGRATION_ROWS;
pub const SETTINGS_RESTORE_DEFAULTS_ROW: usize = SETTINGS_CONTROL_ROW_START + 10 + SHELL_INTEGRATION_ROWS;

pub const Category = enum {
    general,
    appearance,
    ai,
    system,
};

const GENERAL_ROWS = [_]usize{
    SETTINGS_CONTROL_ROW_START + 3, // shell
    SETTINGS_CONTROL_ROW_START + 6, // language
    SETTINGS_CONTROL_ROW_START + 7, // restore tabs
    SETTINGS_RAW_CONFIG_ROW,
    SETTINGS_RESTORE_DEFAULTS_ROW,
};
const APPEARANCE_ROWS = [_]usize{
    SETTINGS_FONT_FAMILY_ROW,
    SETTINGS_FONT_SIZE_ROW,
    SETTINGS_THEME_ROW,
    SETTINGS_CONTROL_ROW_START + 0, // cursor style
    SETTINGS_CONTROL_ROW_START + 1, // cursor blink
    SETTINGS_CONTROL_ROW_START + 2, // focus follows mouse
};
const AI_ROWS = [_]usize{
    SETTINGS_CONTROL_ROW_START + 4, // default AI
    SETTINGS_CONTROL_ROW_START + 5, // WeChat direct
    SETTINGS_CONTROL_ROW_START + 8, // distill suggestions
};
const SYSTEM_ROWS = [_]usize{
    SETTINGS_CONTROL_ROW_START + 9, // Start menu
    SETTINGS_CONTROL_ROW_START + 10, // startup
};

pub fn categoryCount() usize {
    return if (shell_integration.supported) 4 else 3;
}

pub fn categoryAt(index: usize) ?Category {
    return switch (index) {
        0 => .general,
        1 => .appearance,
        2 => .ai,
        3 => if (shell_integration.supported) .system else null,
        else => null,
    };
}

pub fn categoryRows(category: Category) []const usize {
    return switch (category) {
        .general => GENERAL_ROWS[0..],
        .appearance => APPEARANCE_ROWS[0..],
        .ai => AI_ROWS[0..],
        .system => if (shell_integration.supported) SYSTEM_ROWS[0..] else &.{},
    };
}

pub const Action = enum {
    open_font_picker,
    font_size_minus,
    font_size_plus,
    cycle_theme,
    cycle_theme_prev,
    cycle_cursor_style,
    toggle_cursor_blink,
    toggle_focus_follows_mouse,
    open_shell_picker,
    choose_picker_value,
    close_picker,
    cycle_default_ai_profile,
    cycle_default_ai_profile_prev,
    toggle_weixin_direct,
    cycle_language,
    toggle_restore_tabs,
    toggle_distill_suggest,
    toggle_start_menu,
    toggle_startup,
    open_raw_config,
    restore_defaults,
    select_general,
    select_appearance,
    select_ai,
    select_system,
};

pub const State = struct {
    visible: bool = false,
    category: Category = .general,
    focus: usize = GENERAL_ROWS[0],
    cfg_dirty: bool = true,
    cfg_loaded: bool = false,
    cfg_cache: Config = .{},
    picker: settings_picker.State = .{},
    picker_choices: []const []const u8 = &.{},
    picker_choices_owned: bool = false,
    picker_allocator: ?std.mem.Allocator = null,

    pub fn open(self: *State) void {
        self.closePicker(null);
        self.visible = true;
        self.selectCategory(.general);
        self.cfg_dirty = true;
    }

    pub fn selectCategory(self: *State, category: Category) void {
        const rows = categoryRows(category);
        if (rows.len == 0) return;
        self.category = category;
        self.focus = rows[0];
    }

    pub fn focusIndex(self: *const State) usize {
        const rows = categoryRows(self.category);
        for (rows, 0..) |row, idx| {
            if (row == self.focus) return idx;
        }
        return 0;
    }

    fn moveFocus(self: *State, delta: isize) void {
        const rows = categoryRows(self.category);
        if (rows.len == 0) return;
        const current: isize = @intCast(self.focusIndex());
        const count: isize = @intCast(rows.len);
        self.focus = rows[@intCast(@mod(current + delta, count))];
    }

    pub fn close(self: *State, allocator: ?std.mem.Allocator) void {
        self.visible = false;
        self.closePicker(null);
        if (self.cfg_loaded) {
            const alloc = allocator orelse return;
            self.cfg_cache.deinit(alloc);
            self.cfg_loaded = false;
        }
        self.cfg_cache = .{};
        self.cfg_dirty = true;
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.closePicker(allocator);
        if (self.cfg_loaded) self.cfg_cache.deinit(allocator);
        self.cfg_cache = .{};
        self.cfg_loaded = false;
        self.cfg_dirty = true;
        self.visible = false;
    }

    pub fn reloadConfig(self: *State) void {
        self.cfg_dirty = true;
    }

    pub fn cfg(self: *State, allocator: std.mem.Allocator) *Config {
        if (self.cfg_dirty) {
            if (self.cfg_loaded) {
                self.cfg_cache.deinit(allocator);
                self.cfg_loaded = false;
            }
            self.cfg_cache = .{};
            self.cfg_cache = Config.load(allocator) catch {
                self.cfg_dirty = false;
                return &self.cfg_cache;
            };
            self.cfg_loaded = true;
            self.cfg_dirty = false;
        }
        return &self.cfg_cache;
    }

    pub fn openPicker(self: *State, kind: settings_picker.Kind, choices: []const []const u8, current: []const u8, owned: bool, allocator: ?std.mem.Allocator) void {
        std.debug.assert(!owned or allocator != null);
        self.closePicker(null);
        self.picker_choices = choices;
        self.picker_choices_owned = owned;
        self.picker_allocator = if (owned) allocator else null;
        self.picker.open(kind, choices, current);
    }

    pub fn closePicker(self: *State, allocator: ?std.mem.Allocator) void {
        if (self.picker_choices_owned) {
            if (self.picker_allocator orelse allocator) |alloc| {
                for (self.picker_choices) |choice| alloc.free(choice);
                alloc.free(self.picker_choices);
            } else return;
        }
        self.picker.close();
        self.picker_choices = &.{};
        self.picker_choices_owned = false;
        self.picker_allocator = null;
    }

    pub fn pickerOpen(self: *const State) bool {
        return self.picker.kind != null;
    }

    pub fn pickerKind(self: *const State) ?settings_picker.Kind {
        return self.picker.kind;
    }

    pub fn pickerCount(self: *const State) usize {
        return if (self.pickerOpen()) self.picker_choices.len else 0;
    }

    pub fn pickerValue(self: *const State) ?[]const u8 {
        return self.picker.selectedValue(self.picker_choices);
    }

    pub fn pickerValueAt(self: *const State, index: usize) ?[]const u8 {
        if (!self.pickerOpen() or index >= self.picker_choices.len) return null;
        return self.picker_choices[index];
    }

    pub fn selectPickerIndex(self: *State, index: usize) bool {
        if (!self.pickerOpen() or index >= self.picker_choices.len) return false;
        self.picker.selected = index;
        return true;
    }

    pub fn handleKey(self: *State, ev: input_key.KeyEvent) ?Action {
        if (self.pickerOpen()) {
            return switch (ev.key) {
                .escape, .arrow_left => .close_picker,
                .arrow_down, .tab => blk: {
                    self.picker.move(1, self.picker_choices.len);
                    break :blk null;
                },
                .arrow_up => blk: {
                    self.picker.move(-1, self.picker_choices.len);
                    break :blk null;
                },
                .enter, .arrow_right => .choose_picker_value,
                else => null,
            };
        }
        switch (ev.key) {
            .escape => return null,
            .arrow_down, .tab => {
                self.moveFocus(1);
                return null;
            },
            .arrow_up => {
                self.moveFocus(-1);
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
        if (self.pickerOpen()) {
            if (delta_y > 0) self.picker.move(-1, self.picker_choices.len) else if (delta_y < 0) self.picker.move(1, self.picker_choices.len);
            return;
        }
        if (delta_y > 0) {
            self.moveFocus(-1);
        } else if (delta_y < 0) {
            self.moveFocus(1);
        }
    }

    pub fn hitTest(self: *State, layout: settings_page_layout.Layout, x: f32, y: f32) ?Action {
        if (layout.categoryAt(x, y)) |index| {
            return switch (categoryAt(index) orelse return null) {
                .general => .select_general,
                .appearance => .select_appearance,
                .ai => .select_ai,
                .system => .select_system,
            };
        }

        const row_index = layout.rowAt(x, y) orelse return null;
        if (self.pickerOpen()) {
            if (!self.selectPickerIndex(row_index)) return null;
            return .choose_picker_value;
        }
        const rows = categoryRows(self.category);
        if (row_index >= rows.len) return null;
        const row = rows[row_index];
        self.focus = row;

        if (row == SETTINGS_FONT_SIZE_ROW) {
            return switch (layout.fontControlAt(x) orelse return null) {
                .minus => .font_size_minus,
                .plus => .font_size_plus,
            };
        }
        if (row == SETTINGS_THEME_ROW) return .cycle_theme;
        if (row == SETTINGS_FONT_FAMILY_ROW) return .open_font_picker;

        const control_row = row - SETTINGS_CONTROL_ROW_START;
        if (shell_integration.supported) {
            if (control_row == 9) return .toggle_start_menu;
            if (control_row == 10) return .toggle_startup;
        }
        return switch (control_row) {
            0 => .cycle_cursor_style,
            1 => .toggle_cursor_blink,
            2 => .toggle_focus_follows_mouse,
            3 => .open_shell_picker,
            4 => .cycle_default_ai_profile,
            5 => .toggle_weixin_direct,
            6 => .cycle_language,
            7 => .toggle_restore_tabs,
            8 => .toggle_distill_suggest,
            9 + SHELL_INTEGRATION_ROWS => .open_raw_config,
            10 + SHELL_INTEGRATION_ROWS => .restore_defaults,
            else => null,
        };
    }

    pub fn firstVisibleRow(self: *const State, visible_rows: usize) usize {
        const row_count = categoryRows(self.category).len;
        if (visible_rows == 0 or row_count <= visible_rows) return 0;
        const focus = @min(self.focusIndex(), row_count - 1);
        if (focus < visible_rows) return 0;
        return @min(focus - visible_rows + 1, row_count - visible_rows);
    }

    pub fn focusPrimaryAction(self: *const State) ?Action {
        if (shell_integration.supported) {
            if (self.focus == SETTINGS_CONTROL_ROW_START + 9) return .toggle_start_menu;
            if (self.focus == SETTINGS_CONTROL_ROW_START + 10) return .toggle_startup;
        }
        return switch (self.focus) {
            SETTINGS_FONT_FAMILY_ROW => .open_font_picker,
            SETTINGS_FONT_SIZE_ROW => .font_size_plus,
            SETTINGS_THEME_ROW => .cycle_theme,
            SETTINGS_CONTROL_ROW_START + 0 => .cycle_cursor_style,
            SETTINGS_CONTROL_ROW_START + 1 => .toggle_cursor_blink,
            SETTINGS_CONTROL_ROW_START + 2 => .toggle_focus_follows_mouse,
            SETTINGS_CONTROL_ROW_START + 3 => .open_shell_picker,
            SETTINGS_CONTROL_ROW_START + 4 => .cycle_default_ai_profile,
            SETTINGS_CONTROL_ROW_START + 5 => .toggle_weixin_direct,
            SETTINGS_CONTROL_ROW_START + 6 => .cycle_language,
            SETTINGS_CONTROL_ROW_START + 7 => .toggle_restore_tabs,
            SETTINGS_CONTROL_ROW_START + 8 => .toggle_distill_suggest,
            SETTINGS_CONTROL_ROW_START + 9 + SHELL_INTEGRATION_ROWS => .open_raw_config,
            SETTINGS_CONTROL_ROW_START + 10 + SHELL_INTEGRATION_ROWS => .restore_defaults,
            else => null,
        };
    }

    pub fn focusLeftAction(self: *const State) ?Action {
        return switch (self.focus) {
            SETTINGS_FONT_SIZE_ROW => .font_size_minus,
            SETTINGS_THEME_ROW => .cycle_theme_prev,
            SETTINGS_CONTROL_ROW_START + 4 => .cycle_default_ai_profile_prev,
            else => null,
        };
    }

    pub fn focusRightAction(self: *const State) ?Action {
        return switch (self.focus) {
            SETTINGS_FONT_SIZE_ROW => .font_size_plus,
            SETTINGS_THEME_ROW => .cycle_theme,
            else => self.focusPrimaryAction(),
        };
    }
};

test "settings page state open resets to General and marks config dirty" {
    var state = State{ .visible = false, .focus = 4, .cfg_dirty = false };

    state.open();

    try std.testing.expect(state.visible);
    try std.testing.expectEqual(Category.general, state.category);
    try std.testing.expectEqual(GENERAL_ROWS[0], state.focus);
    try std.testing.expect(state.cfg_dirty);
}

test "settings page key navigation wraps within the selected category" {
    var state = State{ .visible = true, .category = .appearance, .focus = APPEARANCE_ROWS[0] };

    try std.testing.expectEqual(@as(?Action, null), state.handleKey(.{ .key = .arrow_up }));
    try std.testing.expectEqual(APPEARANCE_ROWS[APPEARANCE_ROWS.len - 1], state.focus);

    try std.testing.expectEqual(@as(?Action, null), state.handleKey(.{ .key = .arrow_down }));
    try std.testing.expectEqual(APPEARANCE_ROWS[0], state.focus);

    try std.testing.expectEqual(Action.open_font_picker, state.handleKey(.{ .key = .enter }).?);
    try std.testing.expectEqual(@as(?Action, null), state.handleKey(.{ .key = .arrow_down }));
    try std.testing.expectEqual(Action.font_size_plus, state.handleKey(.{ .key = .enter }).?);
    try std.testing.expectEqual(Action.font_size_minus, state.handleKey(.{ .key = .arrow_left }).?);
    try std.testing.expectEqual(@as(?Action, null), state.handleKey(.{ .key = .escape }));
}

test "settings page exposes shell integration rows only on Windows" {
    try std.testing.expectEqual(if (shell_integration.supported) @as(usize, 2) else 0, SHELL_INTEGRATION_ROWS);
    if (shell_integration.supported) {
        var state = State{ .visible = true, .focus = SETTINGS_CONTROL_ROW_START + 9 };
        try std.testing.expectEqual(Action.toggle_start_menu, state.focusPrimaryAction().?);
        state.focus += 1;
        try std.testing.expectEqual(Action.toggle_startup, state.focusPrimaryAction().?);
    }
}

test "settings page category selection scopes visible rows" {
    var state = State{ .visible = true };
    state.selectCategory(.ai);
    state.focus = AI_ROWS[AI_ROWS.len - 1];

    const scroll = state.firstVisibleRow(2);

    try std.testing.expectEqual(Category.ai, state.category);
    try std.testing.expectEqual(@as(usize, 1), scroll);
}

test "appearance exposes font family before font size" {
    const rows = categoryRows(.appearance);
    try std.testing.expectEqual(SETTINGS_FONT_FAMILY_ROW, rows[0]);
    try std.testing.expectEqual(SETTINGS_FONT_SIZE_ROW, rows[1]);
}

test "settings page choice picker handles navigation selection and cancel" {
    const choices = [_][]const u8{ "bash", "zsh", "fish" };
    var state = State{ .visible = true };
    state.openPicker(.shell, &choices, "zsh", false, null);

    try std.testing.expectEqual(@as(?Action, null), state.handleKey(.{ .key = .arrow_down }));
    try std.testing.expectEqualStrings("fish", state.pickerValue().?);
    try std.testing.expectEqual(Action.choose_picker_value, state.handleKey(.{ .key = .enter }).?);
    try std.testing.expectEqual(Action.close_picker, state.handleKey(.{ .key = .escape }).?);
}

test "settings page hit test selects a picker row without AppWindow" {
    const choices = [_][]const u8{ "bash", "zsh" };
    var state = State{ .visible = true };
    state.openPicker(.shell, &choices, "bash", false, null);
    const layout = settings_page_layout.compute(.{
        .window_height = 700,
        .top_offset = 40,
        .content_x = 0,
        .content_width = 900,
        .cell_height = 20,
        .focus_index = 0,
        .row_count = choices.len,
        .category_count = categoryCount(),
    });

    const action = state.hitTest(layout, layout.content_x + 10, layout.row_top_px + layout.row_h + 1);

    try std.testing.expectEqual(Action.choose_picker_value, action.?);
    try std.testing.expectEqualStrings("zsh", state.pickerValue().?);
}

test "settings page reopen releases owned picker choices and resets picker" {
    var state = State{ .visible = true };
    const choices = try std.testing.allocator.alloc([]const u8, 2);
    choices[0] = try std.testing.allocator.dupe(u8, "Fira Code");
    choices[1] = try std.testing.allocator.dupe(u8, "JetBrains Mono");
    state.openPicker(.font_family, choices, "Fira Code", true, std.testing.allocator);

    state.open();

    try std.testing.expect(state.visible);
    try std.testing.expect(!state.pickerOpen());
    try std.testing.expectEqual(@as(usize, 0), state.pickerCount());
}

test "settings page deinit frees loaded cache after reload invalidation" {
    var state = State{};

    _ = state.cfg(std.testing.allocator);
    state.reloadConfig();
    state.deinit(std.testing.allocator);
}

test "settings page close frees loaded cache after reload invalidation" {
    var state = State{ .visible = true };

    _ = state.cfg(std.testing.allocator);
    state.reloadConfig();
    state.close(std.testing.allocator);
}

test "settings page null close leaves loaded cache for later deinit" {
    var state = State{ .visible = true };

    _ = state.cfg(std.testing.allocator);
    state.close(null);
    state.deinit(std.testing.allocator);
}
