const std = @import("std");
const platform_input = @import("input_events.zig");
const platform_window = @import("window.zig");

pub const FileDropHandler = *const fn (path: []const u8, x: i32, y: i32) bool;
const MessageCallback = *const fn (
    message: platform_window.MessageId,
    wparam: platform_window.WordParam,
    lparam: platform_window.LongParam,
) ?platform_window.MessageResult;
const ResizeCallback = *const fn (width: i32, height: i32) void;

const NativeHandle = platform_window.NativeHandle;

const Error = error{
    AppKitWindowInitFailed,
};

fn RingBuffer(comptime T: type, comptime N: usize) type {
    return struct {
        items: [N]T = undefined,
        head: usize = 0,
        count: usize = 0,

        pub fn push(self: *@This(), item: T) void {
            const idx = (self.head + self.count) % N;
            self.items[idx] = item;
            if (self.count < N) {
                self.count += 1;
            } else {
                self.head = (self.head + 1) % N;
            }
        }

        pub fn pop(self: *@This()) ?T {
            if (self.count == 0) return null;
            const item = self.items[self.head];
            self.head = (self.head + 1) % N;
            self.count -= 1;
            return item;
        }

        pub fn clear(self: *@This()) void {
            self.head = 0;
            self.count = 0;
        }
    };
}

const RawKeyEvent = extern struct {
    key_code: usize,
    ctrl: bool,
    shift: bool,
    alt: bool,
    super: bool,
};

const RawCharEvent = extern struct {
    codepoint: u32,
    ctrl: bool,
    shift: bool,
    alt: bool,
    super: bool,
};

const RawMouseButtonEvent = extern struct {
    button: u8,
    action: u8,
    x: i32,
    y: i32,
    ctrl: bool,
    shift: bool,
    alt: bool,
};

const RawMouseMoveEvent = extern struct {
    x: i32,
    y: i32,
    ctrl: bool,
    shift: bool,
    alt: bool,
};

const RawMouseWheelEvent = extern struct {
    delta: i16,
    xpos: i32,
    ypos: i32,
    ctrl: bool,
    shift: bool,
    alt: bool,
};

const RawMessageEvent = extern struct {
    message: platform_window.MessageId,
    wparam: platform_window.WordParam,
    lparam: platform_window.LongParam,
};

const RawFileDropEvent = extern struct {
    path: [4096]u8,
    path_len: usize,
    x: i32,
    y: i32,
};

extern fn phantty_macos_window_create(
    width: i32,
    height: i32,
    title: [*:0]const u16,
    x: i32,
    y: i32,
    has_position: bool,
    maximize: bool,
) ?NativeHandle;
extern fn phantty_macos_window_destroy(handle: NativeHandle) void;
extern fn phantty_macos_window_poll(handle: NativeHandle) void;
extern fn phantty_macos_window_close_requested(handle: NativeHandle) bool;
extern fn phantty_macos_window_get_framebuffer_size(handle: NativeHandle, width: *i32, height: *i32, dpi: *u32) void;
extern fn phantty_macos_window_set_content_size(handle: NativeHandle, width: i32, height: i32) void;
extern fn phantty_macos_window_metal_layer(handle: NativeHandle) ?*anyopaque;
extern fn phantty_macos_window_pop_key_event(handle: NativeHandle, out: *RawKeyEvent) bool;
extern fn phantty_macos_window_pop_char_event(handle: NativeHandle, out: *RawCharEvent) bool;
extern fn phantty_macos_window_pop_mouse_button_event(handle: NativeHandle, out: *RawMouseButtonEvent) bool;
extern fn phantty_macos_window_pop_mouse_move_event(handle: NativeHandle, out: *RawMouseMoveEvent) bool;
extern fn phantty_macos_window_pop_mouse_wheel_event(handle: NativeHandle, out: *RawMouseWheelEvent) bool;
extern fn phantty_macos_window_pop_message_event(handle: NativeHandle, out: *RawMessageEvent) bool;
extern fn phantty_macos_window_pop_file_drop_event(handle: NativeHandle, out: *RawFileDropEvent) bool;
extern fn phantty_macos_window_copy_ime_preedit(handle: NativeHandle, out: [*]u8, out_len: usize) usize;
extern fn phantty_macos_window_set_ime_caret(handle: NativeHandle, x: i32, y: i32, height: i32) void;
extern fn phantty_macos_window_test_push_key(handle: NativeHandle, key_code: usize, ctrl: bool, shift: bool, alt: bool) void;
extern fn phantty_macos_window_test_map_key_code(native_key_code: u16, characters_utf8: ?[*:0]const u8) usize;
extern fn phantty_macos_window_test_push_char(handle: NativeHandle, codepoint: u32, ctrl: bool, shift: bool, alt: bool) void;
extern fn phantty_macos_window_test_push_mouse_button(handle: NativeHandle, button: u8, action: u8, x: i32, y: i32, ctrl: bool, shift: bool, alt: bool) void;
extern fn phantty_macos_window_test_push_mouse_move(handle: NativeHandle, x: i32, y: i32, ctrl: bool, shift: bool, alt: bool) void;
extern fn phantty_macos_window_test_push_mouse_wheel(handle: NativeHandle, delta: i16, xpos: i32, ypos: i32, ctrl: bool, shift: bool, alt: bool) void;
extern fn phantty_macos_window_test_set_ime_preedit(handle: NativeHandle, text: [*:0]const u8) void;
extern fn phantty_macos_window_test_push_file_drop(handle: NativeHandle, path: [*:0]const u8, x: i32, y: i32) void;

var global_window: ?*Window = null;
var test_message_seen: bool = false;
var test_message_value: platform_window.WordParam = 0;
var test_drop_seen: bool = false;
var test_drop_x: i32 = 0;
var test_drop_y: i32 = 0;

pub const Window = struct {
    pub const FramebufferSize = struct {
        width: i32,
        height: i32,
    };

    hwnd: NativeHandle,
    width: i32 = 0,
    height: i32 = 0,
    dpi: u32 = 96,
    titlebar_height: i32 = platform_window.titlebar_height,
    sidebar_width: i32 = 0,
    tab_count: usize = 0,
    mouse_x: i32 = 0,
    mouse_y: i32 = 0,
    hovered_button: platform_window.CaptionButton = .none,
    close_btn_x_start: [256]i32 = [_]i32{0} ** 256,
    close_btn_x_end: [256]i32 = [_]i32{0} ** 256,
    plus_btn_x_start: i32 = 0,
    plus_btn_x_end: i32 = 0,
    ime_caret_x: i32 = 12,
    ime_caret_y: i32 = 10,
    ime_caret_height: i32 = 20,
    ime_composing: bool = false,
    focused: bool = true,
    is_minimized: bool = false,
    is_fullscreen: bool = false,
    close_requested: bool = false,
    dpi_changed: bool = false,
    size_changed: bool = true,
    on_resize: ?ResizeCallback = null,
    on_message: ?MessageCallback = null,
    on_file_drop: ?FileDropHandler = null,
    ime_preedit_buf: [1024]u8 = undefined,
    ime_preedit_len: usize = 0,
    key_events: RingBuffer(platform_input.KeyEvent, 64) = .{},
    char_events: RingBuffer(platform_input.CharEvent, 64) = .{},
    mouse_button_events: RingBuffer(platform_input.MouseButtonEvent, 32) = .{},
    mouse_move_events: RingBuffer(platform_input.MouseMoveEvent, 64) = .{},
    mouse_wheel_events: RingBuffer(platform_input.MouseWheelEvent, 16) = .{},

    pub fn init(width: i32, height: i32, title: [*:0]const u16, x: ?i32, y: ?i32, maximize: bool) !Window {
        const has_position = x != null and y != null;
        const handle = phantty_macos_window_create(
            width,
            height,
            title,
            x orelse 0,
            y orelse 0,
            has_position,
            maximize,
        ) orelse return Error.AppKitWindowInitFailed;

        var window = Window{ .hwnd = handle };
        window.refreshGeometry();
        return window;
    }

    pub fn deinit(self: *Window) void {
        if (global_window == self) global_window = null;
        phantty_macos_window_destroy(self.hwnd);
    }

    pub fn pollEvents(self: *Window) bool {
        phantty_macos_window_poll(self.hwnd);
        self.drainMessageEvents();
        self.drainFileDropEvents();
        self.drainInputEvents();
        self.refreshGeometry();
        self.close_requested = self.close_requested or phantty_macos_window_close_requested(self.hwnd);
        return !self.close_requested;
    }

    pub fn swapBuffers(self: *Window) void {
        _ = self;
    }

    pub fn getFramebufferSize(self: *Window) FramebufferSize {
        self.refreshGeometry();
        return .{ .width = self.width, .height = self.height };
    }

    pub fn setSize(self: *Window, width: i32, height: i32) void {
        phantty_macos_window_set_content_size(self.hwnd, width, height);
        self.refreshGeometry();
    }

    pub fn setImeCaret(self: *Window, x: i32, y: i32, height: i32) void {
        self.ime_caret_x = @max(0, x);
        self.ime_caret_y = @max(0, y);
        self.ime_caret_height = @max(1, height);
        phantty_macos_window_set_ime_caret(self.hwnd, x, y, height);
    }

    pub fn imePreeditText(self: *const Window) []const u8 {
        return self.ime_preedit_buf[0..self.ime_preedit_len];
    }

    pub fn clearTransientInputQueues(self: *Window) void {
        self.mouse_button_events.clear();
        self.mouse_move_events.clear();
        self.mouse_wheel_events.clear();
        self.hovered_button = .none;
        self.mouse_x = -1;
        self.mouse_y = -1;
    }

    fn refreshGeometry(self: *Window) void {
        var width: i32 = self.width;
        var height: i32 = self.height;
        var dpi_value: u32 = self.dpi;
        phantty_macos_window_get_framebuffer_size(self.hwnd, &width, &height, &dpi_value);

        const size_changed = width != self.width or height != self.height;
        const dpi_changed = dpi_value != self.dpi;
        self.width = width;
        self.height = height;
        self.dpi = dpi_value;
        self.size_changed = self.size_changed or size_changed;
        self.dpi_changed = self.dpi_changed or dpi_changed;
        if (size_changed) {
            if (self.on_resize) |callback| callback(width, height);
        }
    }

    fn drainInputEvents(self: *Window) void {
        var key: RawKeyEvent = undefined;
        while (phantty_macos_window_pop_key_event(self.hwnd, &key)) {
            self.key_events.push(.{
                .key_code = key.key_code,
                .ctrl = key.ctrl,
                .shift = key.shift,
                .alt = key.alt,
                .super = key.super,
            });
        }

        var char: RawCharEvent = undefined;
        while (phantty_macos_window_pop_char_event(self.hwnd, &char)) {
            if (char.codepoint <= 0x10FFFF) {
                self.char_events.push(.{
                    .codepoint = @intCast(char.codepoint),
                    .ctrl = char.ctrl,
                    .shift = char.shift,
                    .alt = char.alt,
                    .super = char.super,
                });
            }
        }

        var button: RawMouseButtonEvent = undefined;
        while (phantty_macos_window_pop_mouse_button_event(self.hwnd, &button)) {
            self.mouse_x = button.x;
            self.mouse_y = button.y;
            self.mouse_button_events.push(.{
                .button = @enumFromInt(button.button),
                .action = @enumFromInt(button.action),
                .x = button.x,
                .y = button.y,
                .ctrl = button.ctrl,
                .shift = button.shift,
                .alt = button.alt,
            });
        }

        var move: RawMouseMoveEvent = undefined;
        while (phantty_macos_window_pop_mouse_move_event(self.hwnd, &move)) {
            self.mouse_x = move.x;
            self.mouse_y = move.y;
            self.mouse_move_events.push(.{
                .x = move.x,
                .y = move.y,
                .ctrl = move.ctrl,
                .shift = move.shift,
                .alt = move.alt,
            });
        }

        var wheel: RawMouseWheelEvent = undefined;
        while (phantty_macos_window_pop_mouse_wheel_event(self.hwnd, &wheel)) {
            self.mouse_wheel_events.push(.{
                .delta = wheel.delta,
                .xpos = wheel.xpos,
                .ypos = wheel.ypos,
                .ctrl = wheel.ctrl,
                .shift = wheel.shift,
                .alt = wheel.alt,
            });
        }

        self.ime_preedit_len = @min(
            phantty_macos_window_copy_ime_preedit(self.hwnd, self.ime_preedit_buf[0..].ptr, self.ime_preedit_buf.len),
            self.ime_preedit_buf.len,
        );
        self.ime_composing = self.ime_preedit_len > 0;
    }

    fn drainMessageEvents(self: *Window) void {
        var msg: RawMessageEvent = undefined;
        while (phantty_macos_window_pop_message_event(self.hwnd, &msg)) {
            if (self.on_message) |callback| {
                _ = callback(msg.message, msg.wparam, msg.lparam);
            }
        }
    }

    fn drainFileDropEvents(self: *Window) void {
        var drop: RawFileDropEvent = undefined;
        while (phantty_macos_window_pop_file_drop_event(self.hwnd, &drop)) {
            if (self.on_file_drop) |callback| {
                const len = @min(drop.path_len, drop.path.len);
                _ = callback(drop.path[0..len], drop.x, drop.y);
            }
        }
    }
};

pub fn setGlobalWindow(window: *Window) void {
    global_window = window;
}

pub fn glGetProcAddress(name: [*:0]const u8) callconv(.c) ?*const anyopaque {
    _ = name;
    return null;
}

pub fn metalLayer(window: *Window) ?*anyopaque {
    return phantty_macos_window_metal_layer(window.hwnd);
}

test "macOS backend drains translated key events" {
    const title = std.unicode.utf8ToUtf16LeStringLiteral("Phantty Input Smoke");
    var window = try Window.init(320, 180, title, null, null, false);
    defer window.deinit();

    phantty_macos_window_test_push_key(window.hwnd, platform_input.key_enter, true, false, true);
    _ = window.pollEvents();

    const ev = window.key_events.pop() orelse return error.ExpectedKeyEvent;
    try std.testing.expectEqual(platform_input.key_enter, ev.key_code);
    try std.testing.expect(ev.ctrl);
    try std.testing.expect(!ev.shift);
    try std.testing.expect(ev.alt);
}

test "macOS backend normalizes control-modified shortcut key codes" {
    const ctrl_p = [_:0]u8{0x10};
    try std.testing.expectEqual(@as(usize, 'P'), phantty_macos_window_test_map_key_code(35, &ctrl_p));
    try std.testing.expectEqual(@as(usize, 'P'), phantty_macos_window_test_map_key_code(35, "P"));
    try std.testing.expectEqual(@as(usize, 'P'), phantty_macos_window_test_map_key_code(35, "p"));
    try std.testing.expectEqual(@as(usize, 0xC0), phantty_macos_window_test_map_key_code(50, null));

    // Punctuation keys must map to their Windows virtual-key codes (not the
    // raw character) so Cmd shortcuts on them match: "="/"+" -> 0xBB,
    // "-"/"_" -> 0xBD, "," -> 0xBC, "[" -> 0xDB, "]" -> 0xDD.
    try std.testing.expectEqual(@as(usize, 0xBB), phantty_macos_window_test_map_key_code(24, "="));
    try std.testing.expectEqual(@as(usize, 0xBB), phantty_macos_window_test_map_key_code(24, "+"));
    try std.testing.expectEqual(@as(usize, 0xBD), phantty_macos_window_test_map_key_code(27, "-"));
    try std.testing.expectEqual(@as(usize, 0xBD), phantty_macos_window_test_map_key_code(27, "_"));
    try std.testing.expectEqual(@as(usize, 0xBC), phantty_macos_window_test_map_key_code(43, ","));
    try std.testing.expectEqual(@as(usize, 0xDB), phantty_macos_window_test_map_key_code(33, "["));
    try std.testing.expectEqual(@as(usize, 0xDD), phantty_macos_window_test_map_key_code(30, "]"));
}

test "macOS backend drains text, mouse, wheel, and IME preedit events" {
    const title = std.unicode.utf8ToUtf16LeStringLiteral("Phantty Input Smoke");
    var window = try Window.init(320, 180, title, null, null, false);
    defer window.deinit();

    phantty_macos_window_test_push_char(window.hwnd, 'A', false, true, false);
    phantty_macos_window_test_push_mouse_button(window.hwnd, 0, 2, 10, 20, false, false, true);
    phantty_macos_window_test_push_mouse_move(window.hwnd, 30, 40, true, false, false);
    phantty_macos_window_test_push_mouse_wheel(window.hwnd, 120, 30, 40, false, true, false);
    _ = window.pollEvents();
    phantty_macos_window_test_set_ime_preedit(window.hwnd, "zhong");
    window.ime_preedit_len = @min(
        phantty_macos_window_copy_ime_preedit(window.hwnd, window.ime_preedit_buf[0..].ptr, window.ime_preedit_buf.len),
        window.ime_preedit_buf.len,
    );
    window.ime_composing = window.ime_preedit_len > 0;

    const char = window.char_events.pop() orelse return error.ExpectedCharEvent;
    try std.testing.expectEqual(@as(u21, 'A'), char.codepoint);
    try std.testing.expect(char.shift);

    const button = window.mouse_button_events.pop() orelse return error.ExpectedMouseButtonEvent;
    try std.testing.expectEqual(platform_input.MouseButton.left, button.button);
    try std.testing.expectEqual(platform_input.MouseButtonAction.double_click, button.action);
    try std.testing.expectEqual(@as(i32, 10), button.x);
    try std.testing.expect(button.alt);

    const move = window.mouse_move_events.pop() orelse return error.ExpectedMouseMoveEvent;
    try std.testing.expectEqual(@as(i32, 30), move.x);
    try std.testing.expect(move.ctrl);

    const wheel = window.mouse_wheel_events.pop() orelse return error.ExpectedMouseWheelEvent;
    try std.testing.expectEqual(@as(i16, 120), wheel.delta);
    try std.testing.expect(wheel.shift);

    try std.testing.expectEqualStrings("zhong", window.imePreeditText());
}

fn testMessageCallback(
    message: platform_window.MessageId,
    wparam: platform_window.WordParam,
    lparam: platform_window.LongParam,
) ?platform_window.MessageResult {
    _ = message;
    _ = lparam;
    test_message_seen = true;
    test_message_value = wparam;
    return 1;
}

test "macOS backend drains posted platform messages" {
    const title = std.unicode.utf8ToUtf16LeStringLiteral("Phantty Message Smoke");
    var window = try Window.init(320, 180, title, null, null, false);
    defer window.deinit();

    test_message_seen = false;
    test_message_value = 0;
    window.on_message = testMessageCallback;

    try std.testing.expect(platform_window.postMessage(window.hwnd, platform_window.hotkey_message, 42, 0));
    _ = window.pollEvents();

    try std.testing.expect(test_message_seen);
    try std.testing.expectEqual(@as(platform_window.WordParam, 42), test_message_value);
}

fn testFileDropCallback(path: []const u8, x: i32, y: i32) bool {
    test_drop_seen = std.mem.eql(u8, path, "/tmp/phantty-drop.txt");
    test_drop_x = x;
    test_drop_y = y;
    return true;
}

test "macOS backend drains file drop events" {
    const title = std.unicode.utf8ToUtf16LeStringLiteral("Phantty Drop Smoke");
    var window = try Window.init(320, 180, title, null, null, false);
    defer window.deinit();

    test_drop_seen = false;
    test_drop_x = 0;
    test_drop_y = 0;
    window.on_file_drop = testFileDropCallback;

    phantty_macos_window_test_push_file_drop(window.hwnd, "/tmp/phantty-drop.txt", 11, 22);
    _ = window.pollEvents();

    try std.testing.expect(test_drop_seen);
    try std.testing.expectEqual(@as(i32, 11), test_drop_x);
    try std.testing.expectEqual(@as(i32, 22), test_drop_y);
}
