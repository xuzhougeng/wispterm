const std = @import("std");
const builtin = @import("builtin");

pub const MAX_BINDINGS: usize = 64;

pub const Key = struct {
    pub const backspace: u32 = 0x08;
    pub const tab: u32 = 0x09;
    pub const enter: u32 = 0x0D;
    pub const escape: u32 = 0x1B;
    pub const space: u32 = 0x20;
    pub const page_up: u32 = 0x21;
    pub const page_down: u32 = 0x22;
    pub const end: u32 = 0x23;
    pub const home: u32 = 0x24;
    pub const left: u32 = 0x25;
    pub const up: u32 = 0x26;
    pub const right: u32 = 0x27;
    pub const down: u32 = 0x28;
    pub const insert: u32 = 0x2D;
    pub const delete: u32 = 0x2E;
    pub const backquote: u32 = 0xC0;
    pub const comma: u32 = 0xBC;
    pub const plus: u32 = 0xBB;
    pub const minus: u32 = 0xBD;
    pub const bracket_left: u32 = 0xDB;
    pub const bracket_right: u32 = 0xDD;

    pub fn function(n: u8) ?u32 {
        if (n < 1 or n > 24) return null;
        return 0x70 + @as(u32, n) - 1;
    }
};

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
    key_code: u32,

    pub fn eql(a: Trigger, b: Trigger) bool {
        return a.key_code == b.key_code and a.mods.eql(b.mods);
    }
};

pub const Action = enum {
    toggle_quake,
    toggle_command_palette,
    new_window,
    new_session,
    split_right,
    split_down,
    toggle_file_explorer,
    toggle_sidebar,
    toggle_ai_copilot,
    copilot_conversation_picker,
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
    focus_panel_1,
    focus_panel_2,
    focus_panel_3,
    focus_panel_4,
    focus_panel_5,
    focus_panel_6,
    focus_panel_7,
    focus_panel_8,
    focus_panel_9,
    open_settings,
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
        if (builtin.target.os.tag == .macos) {
            // On macOS, application shortcuts use Cmd (the `win`/super modifier)
            // instead of Ctrl: Ctrl is reserved for terminal control sequences
            // (Ctrl+C = SIGINT, Ctrl+V = literal-next) and mac users expect Cmd.
            // Remap every Ctrl-based default to its Cmd equivalent, except two
            // that would collide with the system:
            //   - the global Quake hotkey (Cmd+` is the macOS "cycle windows" key)
            //   - tab switching on Tab (Cmd+Tab / Cmd+Shift+Tab are the system
            //     app switcher)
            // which keep Ctrl. Alt/Option-based defaults are already mac-native
            // and untouched.
            for (set.items[0..set.len]) |*b| {
                if (b.global) continue;
                if (b.trigger.key_code == Key.tab) continue;
                if (b.trigger.mods.ctrl) {
                    b.trigger.mods.ctrl = false;
                    b.trigger.mods.win = true;
                }
            }
            // Copy is just Cmd+C on macOS. Windows/Linux keep Ctrl+Shift+C
            // because Ctrl+C is the terminal's SIGINT and can't double as copy;
            // Cmd+C has no such conflict, so the migrated Cmd+Shift+C is replaced
            // by the single conventional shortcut rather than kept alongside it.
            set.replaceTrigger(.copy, .{ .mods = .{ .win = true }, .key_code = 'C' });
            // Closing uses the native macOS Cmd+W convention. Windows/Linux keep
            // Ctrl+Shift+W so Ctrl+W remains available to shells and TUIs.
            set.replaceTrigger(.close_panel_or_tab, .{ .mods = .{ .win = true }, .key_code = 'W' });
        }
        return set;
    }

    fn replaceTrigger(self: *Set, action: Action, new_trigger: Trigger) void {
        for (self.items[0..self.len]) |*b| {
            if (b.action == action) {
                b.trigger = new_trigger;
                return;
            }
        }
        self.appendIfRoom(.{ .trigger = new_trigger, .action = action });
    }

    fn appendIfRoom(self: *Set, binding: Binding) void {
        if (self.len >= self.items.len) return;
        self.items[self.len] = binding;
        self.len += 1;
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
    var key_code: ?u32 = null;

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
            if (key_code != null) return error.InvalidTrigger;
            key_code = parseKey(part) orelse return error.UnknownKey;
        }

        start = if (end < value.len and value[end] == '+') end + 1 else end;
    }

    return .{ .mods = mods, .key_code = key_code orelse return error.InvalidTrigger };
}

pub fn formatTrigger(trigger: Trigger, buf: []u8) ![]const u8 {
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    if (trigger.mods.ctrl) try writer.writeAll("Ctrl+");
    if (trigger.mods.shift) try writer.writeAll("Shift+");
    if (trigger.mods.alt) try writer.writeAll(if (builtin.target.os.tag == .macos) "Option+" else "Alt+");
    if (trigger.mods.win) try writer.writeAll(if (builtin.target.os.tag == .macos) "Cmd+" else "Win+");
    try writeKeyLabel(writer, trigger.key_code);

    return stream.getWritten();
}

pub fn formatActionShortcut(set: *const Set, action: Action, buf: []u8) ?[]const u8 {
    const binding = set.firstForAction(action) orelse return null;
    return formatTrigger(binding.trigger, buf) catch null;
}

fn parseKey(value: []const u8) ?u32 {
    if (value.len == 1) {
        const ch = value[0];
        if (ch >= 'a' and ch <= 'z') return ch - 'a' + 'A';
        if (ch >= 'A' and ch <= 'Z') return ch;
        if (ch >= '0' and ch <= '9') return ch;
        return switch (ch) {
            '`' => Key.backquote,
            ',' => Key.comma,
            '+' => Key.plus,
            '=' => Key.plus,
            '-' => Key.minus,
            '[' => Key.bracket_left,
            ']' => Key.bracket_right,
            else => null,
        };
    }

    if ((value[0] == 'f' or value[0] == 'F') and value.len <= 3) {
        const n = std.fmt.parseInt(u8, value[1..], 10) catch return null;
        if (Key.function(n)) |code| return code;
        return null;
    }

    if (nameEql(value, "backquote") or nameEql(value, "grave")) return Key.backquote;
    if (nameEql(value, "comma")) return Key.comma;
    if (nameEql(value, "plus") or nameEql(value, "equal")) return Key.plus;
    if (nameEql(value, "minus") or nameEql(value, "dash")) return Key.minus;
    if (nameEql(value, "bracket_left") or nameEql(value, "left_bracket")) return Key.bracket_left;
    if (nameEql(value, "bracket_right") or nameEql(value, "right_bracket")) return Key.bracket_right;
    if (nameEql(value, "enter") or nameEql(value, "return")) return Key.enter;
    if (nameEql(value, "tab")) return Key.tab;
    if (nameEql(value, "escape") or nameEql(value, "esc")) return Key.escape;
    if (nameEql(value, "backspace") or nameEql(value, "back")) return Key.backspace;
    if (nameEql(value, "delete") or nameEql(value, "del")) return Key.delete;
    if (nameEql(value, "insert") or nameEql(value, "ins")) return Key.insert;
    if (nameEql(value, "home")) return Key.home;
    if (nameEql(value, "end")) return Key.end;
    if (nameEql(value, "page_up") or nameEql(value, "pageup")) return Key.page_up;
    if (nameEql(value, "page_down") or nameEql(value, "pagedown")) return Key.page_down;
    if (nameEql(value, "left")) return Key.left;
    if (nameEql(value, "right")) return Key.right;
    if (nameEql(value, "up")) return Key.up;
    if (nameEql(value, "down")) return Key.down;
    if (nameEql(value, "space")) return Key.space;

    return null;
}

fn writeKeyLabel(writer: anytype, key_code: u32) !void {
    if (key_code >= 'A' and key_code <= 'Z') {
        try writer.writeByte(@intCast(key_code));
        return;
    }
    if (key_code >= '0' and key_code <= '9') {
        try writer.writeByte(@intCast(key_code));
        return;
    }
    if (key_code >= 0x70 and key_code <= 0x87) {
        try writer.print("F{}", .{key_code - 0x70 + 1});
        return;
    }

    switch (key_code) {
        Key.backquote => try writer.writeAll("Backquote"),
        Key.comma => try writer.writeAll(","),
        Key.plus => try writer.writeAll("+"),
        Key.minus => try writer.writeAll("-"),
        Key.bracket_left => try writer.writeAll("["),
        Key.bracket_right => try writer.writeAll("]"),
        Key.enter => try writer.writeAll("Enter"),
        Key.tab => try writer.writeAll("Tab"),
        Key.escape => try writer.writeAll("Escape"),
        Key.backspace => try writer.writeAll("Backspace"),
        Key.delete => try writer.writeAll("Delete"),
        Key.insert => try writer.writeAll("Insert"),
        Key.home => try writer.writeAll("Home"),
        Key.end => try writer.writeAll("End"),
        Key.page_up => try writer.writeAll("PageUp"),
        Key.page_down => try writer.writeAll("PageDown"),
        Key.left => try writer.writeAll("Left"),
        Key.right => try writer.writeAll("Right"),
        Key.up => try writer.writeAll("Up"),
        Key.down => try writer.writeAll("Down"),
        Key.space => try writer.writeAll("Space"),
        else => try writer.print("KeyCode 0x{X}", .{key_code}),
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
    .{ .trigger = .{ .mods = .{ .ctrl = true }, .key_code = Key.backquote }, .action = .toggle_quake, .global = true },
    .{ .trigger = .{ .mods = .{ .ctrl = true, .shift = true }, .key_code = 'P' }, .action = .toggle_command_palette },
    .{ .trigger = .{ .mods = .{ .ctrl = true, .shift = true }, .key_code = 'T' }, .action = .new_session },
    .{ .trigger = .{ .mods = .{ .ctrl = true, .shift = true }, .key_code = 'N' }, .action = .new_window },
    .{ .trigger = .{ .mods = .{ .ctrl = true, .shift = true }, .key_code = 'B' }, .action = .toggle_sidebar },
    .{ .trigger = .{ .mods = .{ .ctrl = true, .shift = true }, .key_code = 'A' }, .action = .toggle_ai_copilot },
    .{ .trigger = .{ .mods = .{ .ctrl = true, .shift = true }, .key_code = 'R' }, .action = .copilot_conversation_picker },
    // Windows-Terminal-style split chords: Ctrl+Shift++ splits vertically (a pane
    // to the right), Ctrl+Shift+- splits horizontally (a pane below). These take
    // the shifted "+" chord that font-size-increase used to share, so font size
    // keeps only the unshifted Ctrl+= / Ctrl+- chords below.
    .{ .trigger = .{ .mods = .{ .ctrl = true, .shift = true }, .key_code = Key.plus }, .action = .split_right },
    .{ .trigger = .{ .mods = .{ .ctrl = true, .shift = true }, .key_code = Key.minus }, .action = .split_down },
    .{ .trigger = .{ .mods = .{ .ctrl = true, .shift = true, .alt = true }, .key_code = 'E' }, .action = .toggle_file_explorer },
    .{ .trigger = .{ .mods = .{ .ctrl = true, .shift = true }, .key_code = 'W' }, .action = .close_panel_or_tab },
    .{ .trigger = .{ .mods = .{ .alt = true }, .key_code = Key.enter }, .action = .toggle_maximize },
    // Font size lives on the unshifted chord (press Ctrl and the "=/+" key
    // without Shift). The shifted Ctrl+Shift++ chord is now split_right above.
    .{ .trigger = .{ .mods = .{ .ctrl = true }, .key_code = Key.plus }, .action = .font_size_increase },
    .{ .trigger = .{ .mods = .{ .ctrl = true }, .key_code = Key.minus }, .action = .font_size_decrease },
    .{ .trigger = .{ .mods = .{ .ctrl = true, .shift = true }, .key_code = 'C' }, .action = .copy },
    .{ .trigger = .{ .mods = .{ .ctrl = true }, .key_code = 'V' }, .action = .paste },
    .{ .trigger = .{ .mods = .{ .ctrl = true, .shift = true }, .key_code = 'V' }, .action = .paste_image },
    .{ .trigger = .{ .mods = .{ .alt = true }, .key_code = Key.left }, .action = .focus_left },
    .{ .trigger = .{ .mods = .{ .alt = true }, .key_code = Key.right }, .action = .focus_right },
    .{ .trigger = .{ .mods = .{ .alt = true }, .key_code = Key.up }, .action = .focus_up },
    .{ .trigger = .{ .mods = .{ .alt = true }, .key_code = Key.down }, .action = .focus_down },
    .{ .trigger = .{ .mods = .{ .ctrl = true, .shift = true }, .key_code = Key.bracket_left }, .action = .focus_previous },
    .{ .trigger = .{ .mods = .{ .ctrl = true, .shift = true }, .key_code = Key.bracket_right }, .action = .focus_next },
    .{ .trigger = .{ .mods = .{ .ctrl = true, .shift = true }, .key_code = 'Z' }, .action = .equalize_splits },
    .{ .trigger = .{ .mods = .{ .ctrl = true }, .key_code = Key.tab }, .action = .next_tab },
    .{ .trigger = .{ .mods = .{ .ctrl = true, .shift = true }, .key_code = Key.tab }, .action = .previous_tab },
    .{ .trigger = .{ .mods = .{ .alt = true }, .key_code = '1' }, .action = .switch_tab_1 },
    .{ .trigger = .{ .mods = .{ .alt = true }, .key_code = '2' }, .action = .switch_tab_2 },
    .{ .trigger = .{ .mods = .{ .alt = true }, .key_code = '3' }, .action = .switch_tab_3 },
    .{ .trigger = .{ .mods = .{ .alt = true }, .key_code = '4' }, .action = .switch_tab_4 },
    .{ .trigger = .{ .mods = .{ .alt = true }, .key_code = '5' }, .action = .switch_tab_5 },
    .{ .trigger = .{ .mods = .{ .alt = true }, .key_code = '6' }, .action = .switch_tab_6 },
    .{ .trigger = .{ .mods = .{ .alt = true }, .key_code = '7' }, .action = .switch_tab_7 },
    .{ .trigger = .{ .mods = .{ .alt = true }, .key_code = '8' }, .action = .switch_tab_8 },
    .{ .trigger = .{ .mods = .{ .alt = true }, .key_code = '9' }, .action = .switch_tab_9 },
    .{ .trigger = .{ .mods = .{ .ctrl = true }, .key_code = '1' }, .action = .focus_panel_1 },
    .{ .trigger = .{ .mods = .{ .ctrl = true }, .key_code = '2' }, .action = .focus_panel_2 },
    .{ .trigger = .{ .mods = .{ .ctrl = true }, .key_code = '3' }, .action = .focus_panel_3 },
    .{ .trigger = .{ .mods = .{ .ctrl = true }, .key_code = '4' }, .action = .focus_panel_4 },
    .{ .trigger = .{ .mods = .{ .ctrl = true }, .key_code = '5' }, .action = .focus_panel_5 },
    .{ .trigger = .{ .mods = .{ .ctrl = true }, .key_code = '6' }, .action = .focus_panel_6 },
    .{ .trigger = .{ .mods = .{ .ctrl = true }, .key_code = '7' }, .action = .focus_panel_7 },
    .{ .trigger = .{ .mods = .{ .ctrl = true }, .key_code = '8' }, .action = .focus_panel_8 },
    .{ .trigger = .{ .mods = .{ .ctrl = true }, .key_code = '9' }, .action = .focus_panel_9 },
    .{ .trigger = .{ .mods = .{ .ctrl = true }, .key_code = Key.comma }, .action = .open_settings },
};

test "keybind parses ghostty-style global trigger and action" {
    const binding = try parseBinding("global:ctrl+backquote=toggle_quake");

    try std.testing.expect(binding.global);
    try std.testing.expectEqual(Action.toggle_quake, binding.action);
    try std.testing.expect(binding.trigger.eql(.{
        .mods = .{ .ctrl = true },
        .key_code = Key.backquote,
    }));
}

test "keybind defaults include global quake and command palette" {
    const set = Set.defaults();
    const is_macos = builtin.target.os.tag == .macos;

    // Quake stays Ctrl+` on every platform (global; Cmd+` is the macOS window cycler).
    try std.testing.expectEqual(Action.toggle_quake, set.lookupGlobal(.{
        .mods = .{ .ctrl = true },
        .key_code = Key.backquote,
    }).?);
    // Command palette migrates Ctrl→Cmd (win) on macOS; Ctrl elsewhere.
    try std.testing.expectEqual(Action.toggle_command_palette, set.lookupApp(.{
        .mods = if (is_macos) .{ .win = true, .shift = true } else .{ .ctrl = true, .shift = true },
        .key_code = 'P',
    }).?);
}

test "keybind defaults open the visual settings page with ctrl comma" {
    const set = Set.defaults();
    const is_macos = builtin.target.os.tag == .macos;
    const action = set.lookupApp(.{
        .mods = if (is_macos) .{ .win = true } else .{ .ctrl = true },
        .key_code = Key.comma,
    });
    try std.testing.expectEqual(Action.open_settings, action.?);
}

test "copy default: macOS binds Cmd+C only, other platforms keep Ctrl+Shift+C" {
    const set = Set.defaults();
    if (builtin.target.os.tag == .macos) {
        // macOS copy is the single conventional Cmd+C.
        try std.testing.expectEqual(@as(?Action, .copy), set.lookupApp(.{
            .mods = .{ .win = true },
            .key_code = 'C',
        }));
        // The migrated Cmd+Shift+C is intentionally dropped (not bound).
        try std.testing.expectEqual(@as(?Action, null), set.lookupApp(.{
            .mods = .{ .win = true, .shift = true },
            .key_code = 'C',
        }));
    } else {
        // Elsewhere copy stays Ctrl+Shift+C — Ctrl+C is the terminal's SIGINT.
        try std.testing.expectEqual(@as(?Action, .copy), set.lookupApp(.{
            .mods = .{ .ctrl = true, .shift = true },
            .key_code = 'C',
        }));
    }
}

test "paste image default keeps Ctrl or Cmd Shift V" {
    const set = Set.defaults();
    const mods: Mods = if (builtin.target.os.tag == .macos)
        .{ .win = true, .shift = true }
    else
        .{ .ctrl = true, .shift = true };
    try std.testing.expectEqual(@as(?Action, .paste_image), set.lookupApp(.{ .mods = mods, .key_code = 'V' }));
}

test "keybind overriding an action removes its old default trigger" {
    var set = Set.defaults();
    const is_macos = builtin.target.os.tag == .macos;

    try set.apply("alt+f10=toggle_command_palette");

    // The original default trigger (Cmd+Shift+P on macOS, Ctrl+Shift+P elsewhere)
    // must be gone after the override.
    try std.testing.expect(set.lookupApp(.{
        .mods = if (is_macos) .{ .win = true, .shift = true } else .{ .ctrl = true, .shift = true },
        .key_code = 'P',
    }) == null);
    try std.testing.expectEqual(Action.toggle_command_palette, set.lookupApp(.{
        .mods = .{ .alt = true },
        .key_code = 0x79,
    }).?);
}

test "keybind overriding a trigger removes the old action binding" {
    var set = Set.defaults();
    const is_macos = builtin.target.os.tag == .macos;

    try set.apply("ctrl+shift+p=new_session");

    // The explicit user binding uses Ctrl on every platform.
    try std.testing.expectEqual(Action.new_session, set.lookupApp(.{
        .mods = .{ .ctrl = true, .shift = true },
        .key_code = 'P',
    }).?);
    // new_session's original default (Cmd+Shift+T on macOS, Ctrl+Shift+T else)
    // must be gone now that new_session was rebound.
    try std.testing.expect(set.lookupApp(.{
        .mods = if (is_macos) .{ .win = true, .shift = true } else .{ .ctrl = true, .shift = true },
        .key_code = 'T',
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
    const is_macos = builtin.target.os.tag == .macos;

    try std.testing.expectEqualStrings(
        "Ctrl+Backquote",
        try formatTrigger(.{ .mods = .{ .ctrl = true }, .key_code = Key.backquote }, &buf),
    );
    try std.testing.expectEqualStrings(
        "Ctrl++",
        try formatTrigger(.{ .mods = .{ .ctrl = true }, .key_code = Key.plus }, &buf),
    );
    // Alt renders as Option on macOS, Alt elsewhere.
    try std.testing.expectEqualStrings(
        if (is_macos) "Option+KeyCode 0xAB" else "Alt+KeyCode 0xAB",
        try formatTrigger(.{ .mods = .{ .alt = true }, .key_code = 0xAB }, &buf),
    );
    // The win/super modifier renders as Cmd on macOS, Win elsewhere.
    try std.testing.expectEqualStrings(
        if (is_macos) "Cmd+P" else "Win+P",
        try formatTrigger(.{ .mods = .{ .win = true }, .key_code = 'P' }, &buf),
    );
}

test "split right/down use Windows-Terminal-style Ctrl+Shift +/- bindings" {
    const set = Set.defaults();
    const is_macos = builtin.target.os.tag == .macos;
    // Ctrl→Cmd on macOS for non-global app shortcuts.
    const split_mods: Mods = if (is_macos) .{ .win = true, .shift = true } else .{ .ctrl = true, .shift = true };
    // "+" (vertical) opens a pane to the right; "-" (horizontal) opens one below.
    try std.testing.expectEqual(Action.split_right, set.lookupApp(.{ .mods = split_mods, .key_code = Key.plus }).?);
    try std.testing.expectEqual(Action.split_down, set.lookupApp(.{ .mods = split_mods, .key_code = Key.minus }).?);
    // The shifted-plus chord is no longer font increase; font size keeps the
    // unshifted Ctrl/Cmd +/- chords.
    const font_mods: Mods = if (is_macos) .{ .win = true } else .{ .ctrl = true };
    try std.testing.expectEqual(Action.font_size_increase, set.lookupApp(.{ .mods = font_mods, .key_code = Key.plus }).?);
    try std.testing.expectEqual(Action.font_size_decrease, set.lookupApp(.{ .mods = font_mods, .key_code = Key.minus }).?);
}

test "keybind parses displayed plus shortcut spelling" {
    const binding = try parseBinding("ctrl++=font_size_increase");

    try std.testing.expectEqual(Action.font_size_increase, binding.action);
    try std.testing.expect(binding.trigger.eql(.{
        .mods = .{ .ctrl = true },
        .key_code = Key.plus,
    }));
}

test "focus_panel actions parse and have default Ctrl+number bindings" {
    try std.testing.expectEqual(Action.focus_panel_1, Action.parse("focus_panel_1").?);
    try std.testing.expectEqual(Action.focus_panel_9, Action.parse("focus_panel_9").?);
    // Each focus_panel_N has a default Ctrl+digit binding (→ Cmd+digit on macOS
    // via the Ctrl→Cmd remap in the Set builder).
    var found: usize = 0;
    for (default_bindings) |b| {
        switch (b.action) {
            .focus_panel_1, .focus_panel_2, .focus_panel_3, .focus_panel_4, .focus_panel_5, .focus_panel_6, .focus_panel_7, .focus_panel_8, .focus_panel_9 => {
                try std.testing.expect(b.trigger.mods.ctrl);
                found += 1;
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 9), found);
}
