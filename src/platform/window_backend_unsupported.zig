const platform_input = @import("input_events.zig");
const platform_window = @import("window.zig");

pub const FileDropHandler = *const fn (path: []const u8, x: i32, y: i32) bool;
const MessageCallback = *const fn (
    message: u32,
    wparam: usize,
    lparam: isize,
) ?isize;
const ResizeCallback = *const fn (width: i32, height: i32) void;

fn EmptyQueue(comptime T: type) type {
    return struct {
        pub fn pop(self: *@This()) ?T {
            _ = self;
            return null;
        }
    };
}

pub const Window = struct {
    pub const FramebufferSize = struct {
        width: i32,
        height: i32,
    };

    hwnd: *anyopaque = @ptrFromInt(1),
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
    focused: bool = false,
    is_minimized: bool = false,
    is_fullscreen: bool = false,
    close_requested: bool = false,
    dpi_changed: bool = false,
    size_changed: bool = true,
    on_resize: ?ResizeCallback = null,
    on_message: ?MessageCallback = null,
    on_file_drop: ?FileDropHandler = null,
    key_events: EmptyQueue(platform_input.KeyEvent) = .{},
    char_events: EmptyQueue(platform_input.CharEvent) = .{},
    mouse_button_events: EmptyQueue(platform_input.MouseButtonEvent) = .{},
    mouse_move_events: EmptyQueue(platform_input.MouseMoveEvent) = .{},
    mouse_wheel_events: EmptyQueue(platform_input.MouseWheelEvent) = .{},

    pub fn init(width: i32, height: i32, title: [*:0]const u16, x: ?i32, y: ?i32, maximize: bool) !Window {
        _ = title;
        _ = x;
        _ = y;
        _ = maximize;
        return .{
            .width = width,
            .height = height,
        };
    }

    pub fn deinit(self: *Window) void {
        _ = self;
    }

    pub fn pollEvents(self: *Window) bool {
        return !self.close_requested;
    }

    pub fn swapBuffers(self: *Window) void {
        _ = self;
    }

    pub fn getFramebufferSize(self: *Window) FramebufferSize {
        return .{ .width = self.width, .height = self.height };
    }

    pub fn setSize(self: *Window, width: i32, height: i32) void {
        self.width = width;
        self.height = height;
        self.size_changed = true;
    }

    pub fn playBell(self: *Window) void {
        _ = self;
    }

    pub fn flashTaskbar(self: *Window) void {
        _ = self;
    }

    pub fn setImeCaret(self: *Window, x: i32, y: i32, height: i32) void {
        _ = self;
        _ = x;
        _ = y;
        _ = height;
    }

    pub fn imePreeditText(self: *const Window) []const u8 {
        _ = self;
        return "";
    }

    pub fn clearTransientInputQueues(self: *Window) void {
        _ = self;
    }
};

pub fn setGlobalWindow(window: *Window) void {
    _ = window;
}

pub fn glGetProcAddress(name: [*:0]const u8) callconv(.c) ?*const anyopaque {
    _ = name;
    return null;
}
