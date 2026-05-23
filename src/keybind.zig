const std = @import("std");
const win32_backend = @import("apprt/win32.zig");

pub const MAX_BINDINGS: usize = 64;

pub const Mods = struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    win: bool = false,

    pub fn eql(a: Mods, b: Mods) bool {
        return a.ctrl == b.ctrl and
            a.shift == b.shift and
            a.alt == b.alt and
            a.win == b.win;
    }
};

pub const Trigger = struct {
    mods: Mods = .{},
    vk: u32,

    pub fn eql(a: Trigger, b: Trigger) bool {
        return a.vk == b.vk and a.mods.eql(b.mods);
    }
};

pub const Action = enum {
    toggle_quake,
    toggle_command_palette,
    new_window,
    new_session,
    split_right,
    toggle_file_explorer,
    toggle_sidebar,
    close_panel_or_tab,
    toggle_maximize,
    font_size_increase,
    font_size_decrease,
    copy,
    paste,
    paste_image,
    focus_left,
    focus_right,
    focus_up,
    focus_down,
    focus_previous,
    focus_next,
    equalize_splits,
    next_tab,
    previous_tab,
    switch_tab_1,
    switch_tab_2,
    switch_tab_3,
    switch_tab_4,
    switch_tab_5,
    switch_tab_6,
    switch_tab_7,
    switch_tab_8,
    switch_tab_9,
    open_config,

    pub fn parse(value: []const u8) ?Action {
        inline for (std.meta.fields(Action)) |field| {
            if (nameEql(value, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }

    pub fn name(self: Action) []const u8 {
        return @tagName(self);
    }
};

pub const Binding = struct {
    trigger: Trigger,
    action: Action,
    global: bool = false,
};

pub const Set = struct {
    items: [MAX_BINDINGS]Binding = undefined,
    len: usize = 0,

    pub fn defaults() Set {
        var set = Set{};
        for (default_bindings) |binding| {
            set.items[set.len] = binding;
            set.len += 1;
        }
        return set;
    }

    pub fn apply(self: *Set, value: []const u8) !void {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (nameEql(trimmed, "clear")) {
            self.len = 0;
            return;
        }
        try self.put(try parseBinding(trimmed));
    }

    pub fn put(self: *Set, binding: Binding) !void {
        var i: usize = 0;
        while (i < self.len) {
            const existing = self.items[i];
            if (existing.action == binding.action or existing.trigger.eql(binding.trigger)) {
                var j = i + 1;
                while (j < self.len) : (j += 1) {
                    self.items[j - 1] = self.items[j];
                }
                self.len -= 1;
                continue;
            }
            i += 1;
        }
        if (self.len >= self.items.len) return error.TooManyKeybinds;
        self.items[self.len] = binding;
        self.len += 1;
    }

    pub fn lookupApp(self: *const Set, trigger: Trigger) ?Action {
        for (self.items[0..self.len]) |binding| {
            if (!binding.global and binding.trigger.eql(trigger)) return binding.action;
        }
        return null;
    }

    pub fn lookupGlobal(self: *const Set, trigger: Trigger) ?Action {
        for (self.items[0..self.len]) |binding| {
            if (binding.global and binding.trigger.eql(trigger)) return binding.action;
        }
        return null;
    }

    pub fn firstForAction(self: *const Set, action: Action) ?Binding {
        for (self.items[0..self.len]) |binding| {
            if (binding.action == action) return binding;
        }
        return null;
    }
};

pub fn triggerFromKeyEvent(ev: win32_backend.KeyEvent) Trigger {
    return .{
        .mods = .{ .ctrl = ev.ctrl, .shift = ev.shift, .alt = ev.alt },
        .vk = @intCast(ev.vk),
    };
}

pub fn parseBinding(value: []const u8) !Binding {
    var rest = std.mem.trim(u8, value, " \t\r\n");
    var global = false;

    while (true) {
        if (prefixEql(rest, "global:")) {
            global = true;
            rest = std.mem.trim(u8, rest["global:".len..], " \t\r\n");
            continue;
        }
        break;
    }

    const eq = std.mem.indexOfScalar(u8, rest, '=') orelse return error.InvalidKeybind;
    const trigger_text = std.mem.trim(u8, rest[0..eq], " \t");
    const action_text = std.mem.trim(u8, rest[eq + 1 ..], " \t");
    if (trigger_text.len == 0 or action_text.len == 0) return error.InvalidKeybind;

    const action = Action.parse(action_text) orelse return error.UnknownAction;
    return .{
        .trigger = try parseTrigger(trigger_text),
        .action = action,
        .global = global,
    };
}

pub fn parseTrigger(value: []const u8) !Trigger {
    var mods = Mods{};
    var vk: ?u32 = null;

    var start: usize = 0;
    while (start < value.len) {
        const end = if (value[start] == '+') start + 1 else blk: {
            var i = start;
            while (i < value.len and value[i] != '+') : (i += 1) {}
            break :blk i;
        };
        const part = std.mem.trim(u8, value[start..end], " \t\r\n");
        if (part.len == 0) return error.InvalidTrigger;

        if (nameEql(part, "ctrl") or nameEql(part, "control")) {
            mods.ctrl = true;
        } else if (nameEql(part, "shift")) {
            mods.shift = true;
        } else if (nameEql(part, "alt") or nameEql(part, "option")) {
            mods.alt = true;
        } else if (nameEql(part, "win") or nameEql(part, "super") or nameEql(part, "cmd")) {
            mods.win = true;
        } else {
            if (vk != null) return error.InvalidTrigger;
            vk = parseKey(part) orelse return error.UnknownKey;
        }

        start = if (end < value.len and value[end] == '+') end + 1 else end;
    }

    return .{ .mods = mods, .vk = vk orelse return error.InvalidTrigger };
}

pub fn formatTrigger(trigger: Trigger, buf: []u8) ![]const u8 {
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    if (trigger.mods.ctrl) try writer.writeAll("Ctrl+");
    if (trigger.mods.shift) try writer.writeAll("Shift+");
    if (trigger.mods.alt) try writer.writeAll("Alt+");
    if (trigger.mods.win) try writer.writeAll("Win+");
    try writeKeyLabel(writer, trigger.vk);

    return stream.getWritten();
}

pub fn formatActionShortcut(set: *const Set, action: Action, buf: []u8) ?[]const u8 {
    const binding = set.firstForAction(action) orelse return null;
    return formatTrigger(binding.trigger, buf) catch null;
}

pub fn hotkeyModifiers(trigger: Trigger) win32_backend.UINT {
    return (if (trigger.mods.ctrl) win32_backend.MOD_CONTROL else 0) |
        (if (trigger.mods.shift) win32_backend.MOD_SHIFT else 0) |
        (if (trigger.mods.alt) win32_backend.MOD_ALT else 0) |
        (if (trigger.mods.win) win32_backend.MOD_WIN else 0) |
        win32_backend.MOD_NOREPEAT;
}

fn parseKey(value: []const u8) ?u32 {
    if (value.len == 1) {
        const ch = value[0];
        if (ch >= 'a' and ch <= 'z') return ch - 'a' + 'A';
        if (ch >= 'A' and ch <= 'Z') return ch;
        if (ch >= '0' and ch <= '9') return ch;
        return switch (ch) {
            '`' => win32_backend.VK_OEM_3,
            ',' => win32_backend.VK_OEM_COMMA,
            '+' => win32_backend.VK_OEM_PLUS,
            '=' => win32_backend.VK_OEM_PLUS,
            '-' => win32_backend.VK_OEM_MINUS,
            '[' => win32_backend.VK_OEM_4,
            ']' => win32_backend.VK_OEM_6,
            else => null,
        };
    }

    if ((value[0] == 'f' or value[0] == 'F') and value.len <= 3) {
        const n = std.fmt.parseInt(u8, value[1..], 10) catch return null;
        if (n >= 1 and n <= 24) return 0x70 + @as(u32, n) - 1;
    }

    if (nameEql(value, "backquote") or nameEql(value, "grave")) return win32_backend.VK_OEM_3;
    if (nameEql(value, "comma")) return win32_backend.VK_OEM_COMMA;
    if (nameEql(value, "plus") or nameEql(value, "equal")) return win32_backend.VK_OEM_PLUS;
    if (nameEql(value, "minus") or nameEql(value, "dash")) return win32_backend.VK_OEM_MINUS;
    if (nameEql(value, "bracket_left") or nameEql(value, "left_bracket")) return win32_backend.VK_OEM_4;
    if (nameEql(value, "bracket_right") or nameEql(value, "right_bracket")) return win32_backend.VK_OEM_6;
    if (nameEql(value, "enter") or nameEql(value, "return")) return win32_backend.VK_RETURN;
    if (nameEql(value, "tab")) return win32_backend.VK_TAB;
    if (nameEql(value, "escape") or nameEql(value, "esc")) return win32_backend.VK_ESCAPE;
    if (nameEql(value, "backspace") or nameEql(value, "back")) return win32_backend.VK_BACK;
    if (nameEql(value, "delete") or nameEql(value, "del")) return win32_backend.VK_DELETE;
    if (nameEql(value, "insert") or nameEql(value, "ins")) return win32_backend.VK_INSERT;
    if (nameEql(value, "home")) return win32_backend.VK_HOME;
    if (nameEql(value, "end")) return win32_backend.VK_END;
    if (nameEql(value, "page_up") or nameEql(value, "pageup")) return win32_backend.VK_PRIOR;
    if (nameEql(value, "page_down") or nameEql(value, "pagedown")) return win32_backend.VK_NEXT;
    if (nameEql(value, "left")) return win32_backend.VK_LEFT;
    if (nameEql(value, "right")) return win32_backend.VK_RIGHT;
    if (nameEql(value, "up")) return win32_backend.VK_UP;
    if (nameEql(value, "down")) return win32_backend.VK_DOWN;
    if (nameEql(value, "space")) return 0x20;

    return null;
}

fn writeKeyLabel(writer: anytype, vk: u32) !void {
    if (vk >= 'A' and vk <= 'Z') {
        try writer.writeByte(@intCast(vk));
        return;
    }
    if (vk >= '0' and vk <= '9') {
        try writer.writeByte(@intCast(vk));
        return;
    }
    if (vk >= 0x70 and vk <= 0x87) {
        try writer.print("F{}", .{vk - 0x70 + 1});
        return;
    }

    switch (vk) {
        win32_backend.VK_OEM_3 => try writer.writeAll("Backquote"),
        win32_backend.VK_OEM_COMMA => try writer.writeAll(","),
        win32_backend.VK_OEM_PLUS => try writer.writeAll("+"),
        win32_backend.VK_OEM_MINUS => try writer.writeAll("-"),
        win32_backend.VK_OEM_4 => try writer.writeAll("["),
        win32_backend.VK_OEM_6 => try writer.writeAll("]"),
        win32_backend.VK_RETURN => try writer.writeAll("Enter"),
        win32_backend.VK_TAB => try writer.writeAll("Tab"),
        win32_backend.VK_ESCAPE => try writer.writeAll("Escape"),
        win32_backend.VK_BACK => try writer.writeAll("Backspace"),
        win32_backend.VK_DELETE => try writer.writeAll("Delete"),
        win32_backend.VK_INSERT => try writer.writeAll("Insert"),
        win32_backend.VK_HOME => try writer.writeAll("Home"),
        win32_backend.VK_END => try writer.writeAll("End"),
        win32_backend.VK_PRIOR => try writer.writeAll("PageUp"),
        win32_backend.VK_NEXT => try writer.writeAll("PageDown"),
        win32_backend.VK_LEFT => try writer.writeAll("Left"),
        win32_backend.VK_RIGHT => try writer.writeAll("Right"),
        win32_backend.VK_UP => try writer.writeAll("Up"),
        win32_backend.VK_DOWN => try writer.writeAll("Down"),
        0x20 => try writer.writeAll("Space"),
        else => try writer.print("VK_{X}", .{vk}),
    }
}

fn prefixEql(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and nameEql(value[0..prefix.len], prefix);
}

fn nameEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |a_ch, b_ch| {
        if (normalizedNameChar(a_ch) != normalizedNameChar(b_ch)) return false;
    }
    return true;
}

fn normalizedNameChar(ch: u8) u8 {
    return switch (ch) {
        'A'...'Z' => ch + 32,
        '-' => '_',
        else => ch,
    };
}

pub const default_bindings = [_]Binding{
    .{ .trigger = .{ .mods = .{ .ctrl = true }, .vk = win32_backend.VK_OEM_3 }, .action = .toggle_quake, .global = true },
    .{ .trigger = .{ .mods = .{ .ctrl = true, .shift = true }, .vk = 'P' }, .action = .toggle_command_palette },
    .{ .trigger = .{ .mods = .{ .ctrl = true, .shift = true }, .vk = 'T' }, .action = .new_session },
    .{ .trigger = .{ .mods = .{ .ctrl = true, .shift = true }, .vk = 'N' }, .action = .new_window },
    .{ .trigger = .{ .mods = .{ .ctrl = true, .shift = true }, .vk = 'B' }, .action = .toggle_sidebar },
    .{ .trigger = .{ .mods = .{ .ctrl = true, .shift = true }, .vk = 'O' }, .action = .split_right },
    .{ .trigger = .{ .mods = .{ .ctrl = true, .shift = true, .alt = true }, .vk = 'E' }, .action = .toggle_file_explorer },
    .{ .trigger = .{ .mods = .{ .ctrl = true, .shift = true }, .vk = 'W' }, .action = .close_panel_or_tab },
    .{ .trigger = .{ .mods = .{ .alt = true }, .vk = win32_backend.VK_RETURN }, .action = .toggle_maximize },
    .{ .trigger = .{ .mods = .{ .ctrl = true }, .vk = win32_backend.VK_OEM_PLUS }, .action = .font_size_increase },
    .{ .trigger = .{ .mods = .{ .ctrl = true }, .vk = win32_backend.VK_OEM_MINUS }, .action = .font_size_decrease },
    .{ .trigger = .{ .mods = .{ .ctrl = true, .shift = true }, .vk = 'C' }, .action = .copy },
    .{ .trigger = .{ .mods = .{ .ctrl = true }, .vk = 'V' }, .action = .paste },
    .{ .trigger = .{ .mods = .{ .ctrl = true, .shift = true }, .vk = 'V' }, .action = .paste_image },
    .{ .trigger = .{ .mods = .{ .alt = true }, .vk = win32_backend.VK_LEFT }, .action = .focus_left },
    .{ .trigger = .{ .mods = .{ .alt = true }, .vk = win32_backend.VK_RIGHT }, .action = .focus_right },
    .{ .trigger = .{ .mods = .{ .alt = true }, .vk = win32_backend.VK_UP }, .action = .focus_up },
    .{ .trigger = .{ .mods = .{ .alt = true }, .vk = win32_backend.VK_DOWN }, .action = .focus_down },
    .{ .trigger = .{ .mods = .{ .ctrl = true, .shift = true }, .vk = win32_backend.VK_OEM_4 }, .action = .focus_previous },
    .{ .trigger = .{ .mods = .{ .ctrl = true, .shift = true }, .vk = win32_backend.VK_OEM_6 }, .action = .focus_next },
    .{ .trigger = .{ .mods = .{ .ctrl = true, .shift = true }, .vk = 'Z' }, .action = .equalize_splits },
    .{ .trigger = .{ .mods = .{ .ctrl = true }, .vk = win32_backend.VK_TAB }, .action = .next_tab },
    .{ .trigger = .{ .mods = .{ .ctrl = true, .shift = true }, .vk = win32_backend.VK_TAB }, .action = .previous_tab },
    .{ .trigger = .{ .mods = .{ .alt = true }, .vk = '1' }, .action = .switch_tab_1 },
    .{ .trigger = .{ .mods = .{ .alt = true }, .vk = '2' }, .action = .switch_tab_2 },
    .{ .trigger = .{ .mods = .{ .alt = true }, .vk = '3' }, .action = .switch_tab_3 },
    .{ .trigger = .{ .mods = .{ .alt = true }, .vk = '4' }, .action = .switch_tab_4 },
    .{ .trigger = .{ .mods = .{ .alt = true }, .vk = '5' }, .action = .switch_tab_5 },
    .{ .trigger = .{ .mods = .{ .alt = true }, .vk = '6' }, .action = .switch_tab_6 },
    .{ .trigger = .{ .mods = .{ .alt = true }, .vk = '7' }, .action = .switch_tab_7 },
    .{ .trigger = .{ .mods = .{ .alt = true }, .vk = '8' }, .action = .switch_tab_8 },
    .{ .trigger = .{ .mods = .{ .alt = true }, .vk = '9' }, .action = .switch_tab_9 },
    .{ .trigger = .{ .mods = .{ .ctrl = true }, .vk = win32_backend.VK_OEM_COMMA }, .action = .open_config },
};

test "keybind parses ghostty-style global trigger and action" {
    const binding = try parseBinding("global:ctrl+backquote=toggle_quake");

    try std.testing.expect(binding.global);
    try std.testing.expectEqual(Action.toggle_quake, binding.action);
    try std.testing.expect(binding.trigger.eql(.{
        .mods = .{ .ctrl = true },
        .vk = win32_backend.VK_OEM_3,
    }));
}

test "keybind defaults include global quake and command palette" {
    const set = Set.defaults();

    try std.testing.expectEqual(Action.toggle_quake, set.lookupGlobal(.{
        .mods = .{ .ctrl = true },
        .vk = win32_backend.VK_OEM_3,
    }).?);
    try std.testing.expectEqual(Action.toggle_command_palette, set.lookupApp(.{
        .mods = .{ .ctrl = true, .shift = true },
        .vk = 'P',
    }).?);
}

test "keybind overriding an action removes its old default trigger" {
    var set = Set.defaults();

    try set.apply("alt+f10=toggle_command_palette");

    try std.testing.expect(set.lookupApp(.{
        .mods = .{ .ctrl = true, .shift = true },
        .vk = 'P',
    }) == null);
    try std.testing.expectEqual(Action.toggle_command_palette, set.lookupApp(.{
        .mods = .{ .alt = true },
        .vk = 0x79,
    }).?);
}

test "keybind overriding a trigger removes the old action binding" {
    var set = Set.defaults();

    try set.apply("ctrl+shift+p=new_session");

    try std.testing.expectEqual(Action.new_session, set.lookupApp(.{
        .mods = .{ .ctrl = true, .shift = true },
        .vk = 'P',
    }).?);
    try std.testing.expect(set.lookupApp(.{
        .mods = .{ .ctrl = true, .shift = true },
        .vk = 'T',
    }) == null);
}

test "keybind clear removes defaults before adding custom bindings" {
    var set = Set.defaults();

    try set.apply("clear");
    try std.testing.expectEqual(@as(usize, 0), set.len);
    try set.apply("ctrl+shift+p=toggle_command_palette");

    try std.testing.expectEqual(@as(usize, 1), set.len);
}

test "keybind formats display labels" {
    var buf: [64]u8 = undefined;

    try std.testing.expectEqualStrings(
        "Ctrl+Backquote",
        try formatTrigger(.{ .mods = .{ .ctrl = true }, .vk = win32_backend.VK_OEM_3 }, &buf),
    );
    try std.testing.expectEqualStrings(
        "Ctrl++",
        try formatTrigger(.{ .mods = .{ .ctrl = true }, .vk = win32_backend.VK_OEM_PLUS }, &buf),
    );
}

test "keybind parses displayed plus shortcut spelling" {
    const binding = try parseBinding("ctrl++=font_size_increase");

    try std.testing.expectEqual(Action.font_size_increase, binding.action);
    try std.testing.expect(binding.trigger.eql(.{
        .mods = .{ .ctrl = true },
        .vk = win32_backend.VK_OEM_PLUS,
    }));
}
