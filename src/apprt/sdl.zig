//! SDL3 window + OpenGL 3.3 core-profile context for the Linux port.
//!
//! Provides the same `Window` struct shape as `window_backend_unsupported.zig`
//! but backed by a real SDL3 window and GL context.  The 5 input event queues
//! are mutex-guarded so the event pump can push while the render thread pops.
//! Task C3: SDL input events are now routed into the neutral input queues so
//! the terminal is interactive (keyboard, mouse, wheel, file-drop).
const std = @import("std");
const builtin = @import("builtin");
const platform_input = @import("../platform/input_events.zig");
const platform_window = @import("../platform/window_linux.zig");
const window_drag_region = @import("window_drag_region.zig");
const window_registry = @import("window_registry.zig");
const GlContext = @import("../renderer/gpu/opengl/Context.zig");
const keymap = @import("../input/sdl_keymap.zig");

pub const c = @import("sdl").c;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub const FileDropHandler = *const fn (path: []const u8, x: i32, y: i32) bool;
pub const NativeHandle = platform_window.NativeHandle;

const MessageCallback = *const fn (
    message: u32,
    wparam: usize,
    lparam: isize,
) ?isize;
const ResizeCallback = *const fn (width: i32, height: i32) void;

// ---------------------------------------------------------------------------
// Mutex-guarded ring-buffer event queue
// ---------------------------------------------------------------------------

fn EventQueue(comptime T: type) type {
    return struct {
        const CAPACITY = 256;
        mutex: std.Thread.Mutex = .{},
        buf: [CAPACITY]T = undefined,
        read: usize = 0,
        write: usize = 0,

        /// Push an event; drops the event silently when the queue is full.
        pub fn push(self: *@This(), event: T) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            const next = (self.write + 1) % CAPACITY;
            if (next == self.read) return; // full — drop
            self.buf[self.write] = event;
            self.write = next;
        }

        /// Pop the oldest event, or null when empty.
        pub fn pop(self: *@This()) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.read == self.write) return null;
            const event = self.buf[self.read];
            self.read = (self.read + 1) % CAPACITY;
            return event;
        }

        /// Drain all pending events (called from clearTransientInputQueues).
        pub fn clear(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.read = self.write;
        }
    };
}

// ---------------------------------------------------------------------------
// Module-level state
// ---------------------------------------------------------------------------

var g_sdl_initialized: bool = false;
var g_quit: bool = false;
var g_wakeup_event_type: u32 = 0;
var g_registry: window_registry.Registry = .{};
var g_global_window: ?*Window = null;

// ---------------------------------------------------------------------------
// Window
// ---------------------------------------------------------------------------

pub const Window = struct {
    pub const FramebufferSize = struct {
        width: i32,
        height: i32,
    };

    // SDL handles
    sdl_window: *c.SDL_Window,
    gl_context: c.SDL_GLContext,

    // NativeHandle stores the SDL_Window* as an opaque pointer so that
    // window_backend.nativeHandleBits can call @intFromPtr on it.
    hwnd: NativeHandle,

    // Logical geometry (CSS / pt units — what the renderer works in)
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

    // IME state (set by setImeCaret; C3 will fill these from SDL text events)
    ime_composing: bool = false,
    ime_caret_x: i32 = 12,
    ime_caret_y: i32 = platform_window.titlebar_height + 10,
    ime_caret_height: i32 = 20,
    ime_preedit_buf: [512]u8 = undefined,
    ime_preedit_len: usize = 0,

    // Input event queues (mutex-guarded; C3 will push into them)
    key_events: EventQueue(platform_input.KeyEvent) = .{},
    char_events: EventQueue(platform_input.CharEvent) = .{},
    mouse_button_events: EventQueue(platform_input.MouseButtonEvent) = .{},
    mouse_move_events: EventQueue(platform_input.MouseMoveEvent) = .{},
    mouse_wheel_events: EventQueue(platform_input.MouseWheelEvent) = .{},

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    pub fn init(
        width: i32,
        height: i32,
        title: [*:0]const u16,
        x: ?i32,
        y: ?i32,
        maximize: bool,
    ) !Window {
        _ = maximize;

        // One-time SDL init
        if (!g_sdl_initialized) {
            if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
                std.debug.print("SDL_Init failed: {s}\n", .{c.SDL_GetError()});
                return error.SDLInitFailed;
            }
            // Register a user-event type for postWakeup()
            g_wakeup_event_type = c.SDL_RegisterEvents(1);
            g_sdl_initialized = true;
        }

        // Request OpenGL 3.3 core profile
        _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MAJOR_VERSION, 3);
        _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MINOR_VERSION, 3);
        _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_PROFILE_MASK, c.SDL_GL_CONTEXT_PROFILE_CORE);
        _ = c.SDL_GL_SetAttribute(c.SDL_GL_DOUBLEBUFFER, 1);

        // Convert UTF-16 title to UTF-8 for SDL
        const title_utf8 = try std.unicode.utf16LeToUtf8Alloc(
            std.heap.c_allocator,
            std.mem.span(title),
        );
        defer std.heap.c_allocator.free(title_utf8);
        // Null-terminate
        const title_z = try std.heap.c_allocator.dupeZ(u8, title_utf8);
        defer std.heap.c_allocator.free(title_z);

        const flags: c.SDL_WindowFlags =
            c.SDL_WINDOW_OPENGL |
            c.SDL_WINDOW_RESIZABLE |
            c.SDL_WINDOW_BORDERLESS |
            c.SDL_WINDOW_HIGH_PIXEL_DENSITY;

        const sdl_win = c.SDL_CreateWindow(title_z.ptr, width, height, flags) orelse {
            std.debug.print("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
            return error.SDLCreateWindowFailed;
        };

        // Apply initial position if requested
        if (x != null or y != null) {
            _ = c.SDL_SetWindowPosition(
                sdl_win,
                x orelse c.SDL_WINDOWPOS_CENTERED,
                y orelse c.SDL_WINDOWPOS_CENTERED,
            );
        }

        const gl_ctx = c.SDL_GL_CreateContext(sdl_win) orelse {
            std.debug.print("SDL_GL_CreateContext failed: {s}\n", .{c.SDL_GetError()});
            c.SDL_DestroyWindow(sdl_win);
            return error.SDLGLContextFailed;
        };
        if (!c.SDL_GL_MakeCurrent(sdl_win, gl_ctx)) {
            std.debug.print("SDL_GL_MakeCurrent failed: {s}\n", .{c.SDL_GetError()});
            _ = c.SDL_GL_DestroyContext(gl_ctx);
            c.SDL_DestroyWindow(sdl_win);
            return error.SDLGLMakeCurrentFailed;
        }

        // Build the Window struct early so we can register it and pass a pointer
        // for the hit-test callback.
        var win = Window{
            .sdl_window = sdl_win,
            .gl_context = gl_ctx,
            .hwnd = @ptrCast(sdl_win),
            .width = width,
            .height = height,
        };

        // NOTE: do NOT register &win or install the hit-test here. `init` returns
        // the Window BY VALUE, so &win points at this stack temporary, not the
        // caller's final storage — a registry entry made here would dangle and
        // event routing would push input into a dead Window. Registration and
        // the hit-test are installed in setGlobalWindow(), which receives the
        // permanent, stable window pointer.

        // Query actual framebuffer size (HiDPI factor may differ from logical size)
        var pw: c_int = 0;
        var ph: c_int = 0;
        _ = c.SDL_GetWindowSizeInPixels(sdl_win, &pw, &ph);
        win.width = @intCast(pw);
        win.height = @intCast(ph);

        // Load GLAD function table now that the GL context is current
        GlContext.init(@ptrCast(&glGetProcAddress)) catch |err| {
            std.debug.print("GLAD init failed: {}\n", .{err});
            _ = c.SDL_GL_DestroyContext(gl_ctx);
            c.SDL_DestroyWindow(sdl_win);
            return err;
        };

        // Compute initial DPI from SDL display scale
        const scale = c.SDL_GetWindowDisplayScale(sdl_win);
        win.dpi = @intFromFloat(@round(scale * 96.0));

        // Enable text-input mode so SDL_EVENT_TEXT_INPUT fires for printable keys.
        _ = c.SDL_StartTextInput(sdl_win);

        std.debug.print("SDL window created: {}x{} DPI={}\n", .{ win.width, win.height, win.dpi });
        return win;
    }

    pub fn deinit(self: *Window) void {
        const win_id = c.SDL_GetWindowID(self.sdl_window);
        g_registry.remove(win_id);
        _ = c.SDL_GL_DestroyContext(self.gl_context);
        c.SDL_DestroyWindow(self.sdl_window);
    }

    // -----------------------------------------------------------------------
    // Frame operations
    // -----------------------------------------------------------------------

    pub fn pollEvents(self: *Window) bool {
        return !self.close_requested;
    }

    pub fn isVisible(self: *Window) bool {
        const flags = c.SDL_GetWindowFlags(self.sdl_window);
        return (flags & c.SDL_WINDOW_HIDDEN) == 0;
    }

    pub fn swapBuffers(self: *Window) void {
        _ = c.SDL_GL_SwapWindow(self.sdl_window);
    }

    pub fn getFramebufferSize(self: *Window) FramebufferSize {
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.SDL_GetWindowSizeInPixels(self.sdl_window, &w, &h);
        return .{ .width = @intCast(w), .height = @intCast(h) };
    }

    pub fn setSize(self: *Window, width: i32, height: i32) void {
        _ = c.SDL_SetWindowSize(self.sdl_window, @intCast(width), @intCast(height));
        self.size_changed = true;
    }

    pub fn setImeCaret(self: *Window, x: i32, y: i32, height: i32) void {
        self.ime_caret_x = @max(0, x);
        self.ime_caret_y = @max(0, y);
        self.ime_caret_height = @max(1, height);
        const rect = c.SDL_Rect{ .x = self.ime_caret_x, .y = self.ime_caret_y, .w = 1, .h = self.ime_caret_height };
        _ = c.SDL_SetTextInputArea(self.sdl_window, &rect, 0);
    }

    pub fn imePreeditText(self: *const Window) []const u8 {
        return self.ime_preedit_buf[0..self.ime_preedit_len];
    }

    pub fn clearTransientInputQueues(self: *Window) void {
        self.key_events.clear();
        self.char_events.clear();
        self.mouse_button_events.clear();
        self.mouse_move_events.clear();
        self.mouse_wheel_events.clear();
    }
};

// ---------------------------------------------------------------------------
// Hit-test callback (borderless drag / resize zones)
// ---------------------------------------------------------------------------

fn hitTest(
    win: ?*c.SDL_Window,
    area: [*c]const c.SDL_Point,
    data: ?*anyopaque,
) callconv(.c) c.SDL_HitTestResult {
    _ = win;
    const self: *Window = @alignCast(@ptrCast(data orelse return c.SDL_HITTEST_NORMAL));
    const hit = window_drag_region.classify(
        self.width,
        self.height,
        area.*.x,
        area.*.y,
        .{ .titlebar_height = self.titlebar_height, .border = 4, .exclusions = &.{} },
    );
    return switch (hit) {
        .normal => c.SDL_HITTEST_NORMAL,
        .draggable => c.SDL_HITTEST_DRAGGABLE,
        .resize_top => c.SDL_HITTEST_RESIZE_TOP,
        .resize_bottom => c.SDL_HITTEST_RESIZE_BOTTOM,
        .resize_left => c.SDL_HITTEST_RESIZE_LEFT,
        .resize_right => c.SDL_HITTEST_RESIZE_RIGHT,
        .resize_top_left => c.SDL_HITTEST_RESIZE_TOPLEFT,
        .resize_top_right => c.SDL_HITTEST_RESIZE_TOPRIGHT,
        .resize_bottom_left => c.SDL_HITTEST_RESIZE_BOTTOMLEFT,
        .resize_bottom_right => c.SDL_HITTEST_RESIZE_BOTTOMRIGHT,
    };
}

// ---------------------------------------------------------------------------
// Module-level functions
// ---------------------------------------------------------------------------

/// GL proc-address loader for GLAD.  SDL_GL_GetProcAddress returns a
/// SDL_FunctionPointer (void(*)(void)) but GLAD expects GLADapiproc which
/// is the same ABI — safe to cast.
pub fn glGetProcAddress(name: [*:0]const u8) callconv(.c) ?*const anyopaque {
    return @ptrCast(c.SDL_GL_GetProcAddress(name));
}

pub fn setGlobalWindow(window: *Window) void {
    g_global_window = window;
    // This is the first time apprt/sdl sees the window's permanent address
    // (Window.init returns by value). Register it for event routing and point
    // the hit-test callback at it, so processEvent pushes input into the same
    // Window the main loop drains.
    const win_id = c.SDL_GetWindowID(window.sdl_window);
    g_registry.set(win_id, @ptrCast(window));
    _ = c.SDL_SetWindowHitTest(window.sdl_window, hitTest, @ptrCast(window));
}

/// Pump SDL events, blocking up to `timeout_seconds`.  Sets the module-level
/// quit flag and individual window close_requested flags as appropriate.
pub fn pumpAppEvents(timeout_seconds: f64) void {
    // WaitEventTimeout expects milliseconds as Sint32.
    const timeout_ms: i32 = @intFromFloat(@min(timeout_seconds * 1000.0, @as(f64, @floatFromInt(std.math.maxInt(i32)))));

    var event: c.SDL_Event = undefined;
    // Block until an event arrives or timeout expires.
    _ = c.SDL_WaitEventTimeout(&event, timeout_ms);

    // Drain any remaining queued events.
    processEvent(event);
    while (c.SDL_PollEvent(&event)) {
        processEvent(event);
    }
}

fn processEvent(event: c.SDL_Event) void {
    switch (event.type) {
        c.SDL_EVENT_QUIT => {
            g_quit = true;
            // Signal all registered windows
            if (g_global_window) |w| w.close_requested = true;
        },
        c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => {
            const win_id = event.window.windowID;
            if (g_registry.find(win_id)) |ptr| {
                const w: *Window = @alignCast(@ptrCast(ptr));
                w.close_requested = true;
            }
        },
        c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED => {
            const win_id = event.window.windowID;
            if (g_registry.find(win_id)) |ptr| {
                const w: *Window = @alignCast(@ptrCast(ptr));
                w.width = event.window.data1;
                w.height = event.window.data2;
                w.size_changed = true;
                const scale = c.SDL_GetWindowDisplayScale(w.sdl_window);
                const new_dpi: u32 = @intFromFloat(@round(scale * 96.0));
                if (new_dpi != w.dpi) {
                    w.dpi = new_dpi;
                    w.dpi_changed = true;
                }
                if (w.on_resize) |cb| cb(w.width, w.height);
            }
        },
        c.SDL_EVENT_WINDOW_FOCUS_GAINED => {
            const win_id = event.window.windowID;
            if (g_registry.find(win_id)) |ptr| {
                const w: *Window = @alignCast(@ptrCast(ptr));
                w.focused = true;
            }
        },
        c.SDL_EVENT_WINDOW_FOCUS_LOST => {
            const win_id = event.window.windowID;
            if (g_registry.find(win_id)) |ptr| {
                const w: *Window = @alignCast(@ptrCast(ptr));
                w.focused = false;
            }
        },
        c.SDL_EVENT_WINDOW_MINIMIZED => {
            const win_id = event.window.windowID;
            if (g_registry.find(win_id)) |ptr| {
                const w: *Window = @alignCast(@ptrCast(ptr));
                w.is_minimized = true;
            }
        },
        c.SDL_EVENT_WINDOW_RESTORED => {
            const win_id = event.window.windowID;
            if (g_registry.find(win_id)) |ptr| {
                const w: *Window = @alignCast(@ptrCast(ptr));
                w.is_minimized = false;
                w.size_changed = true;
            }
        },

        // ---------------------------------------------------------------
        // Keyboard: key-down → KeyEvent (key-up discarded; no press/release
        //           in neutral layer), text-input → CharEvent.
        // ---------------------------------------------------------------
        c.SDL_EVENT_KEY_DOWN => {
            const win_id = event.key.windowID;
            if (g_registry.find(win_id)) |ptr| {
                const w: *Window = @alignCast(@ptrCast(ptr));
                const sc: u32 = @intCast(event.key.scancode);
                if (keymap.keyCodeFromScancode(sc)) |code| {
                    const m = keymap.modifiers(@intCast(event.key.mod));
                    w.key_events.push(.{
                        .key_code = code,
                        .ctrl = m.ctrl,
                        .shift = m.shift,
                        .alt = m.alt,
                        .super = m.super,
                    });
                }
            }
        },
        // KEY_UP: intentionally ignored (neutral KeyEvent has no action field).

        c.SDL_EVENT_TEXT_EDITING => {
            const win_id = event.edit.windowID;
            if (g_registry.find(win_id)) |ptr| {
                const w: *Window = @alignCast(@ptrCast(ptr));
                // event.edit.text is [*c]const u8 — a C pointer that may be null.
                const txt: []const u8 = if (event.edit.text != null)
                    std.mem.span(@as([*:0]const u8, @ptrCast(event.edit.text)))
                else
                    "";
                const n = @min(txt.len, w.ime_preedit_buf.len);
                if (n > 0) @memcpy(w.ime_preedit_buf[0..n], txt[0..n]);
                w.ime_preedit_len = n;
                w.ime_composing = n > 0;
            }
        },

        c.SDL_EVENT_TEXT_INPUT => {
            const win_id = event.text.windowID;
            if (g_registry.find(win_id)) |ptr| {
                const w: *Window = @alignCast(@ptrCast(ptr));
                // event.text.text is a null-terminated UTF-8 C string (*const u8).
                const raw: [*:0]const u8 = event.text.text;
                const slice = std.mem.span(raw);
                const m = keymap.modifiers(@intCast(c.SDL_GetModState()));
                var view = std.unicode.Utf8View.initUnchecked(slice);
                var it = view.iterator();
                while (it.nextCodepoint()) |cp| {
                    w.char_events.push(.{
                        .codepoint = @intCast(cp),
                        .ctrl = m.ctrl,
                        .shift = m.shift,
                        .alt = m.alt,
                        .super = m.super,
                    });
                }
                // Composition is finished once text commits — clear preedit.
                w.ime_preedit_len = 0;
                w.ime_composing = false;
            }
        },

        // ---------------------------------------------------------------
        // Mouse buttons
        // ---------------------------------------------------------------
        c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP => {
            const win_id = event.button.windowID;
            if (g_registry.find(win_id)) |ptr| {
                const w: *Window = @alignCast(@ptrCast(ptr));
                const btn: platform_input.MouseButton = switch (event.button.button) {
                    c.SDL_BUTTON_LEFT => .left,
                    c.SDL_BUTTON_MIDDLE => .middle,
                    c.SDL_BUTTON_RIGHT => .right,
                    else => return, // unknown button — ignore
                };
                const action: platform_input.MouseButtonAction = if (event.type == c.SDL_EVENT_MOUSE_BUTTON_UP)
                    .release
                else if (event.button.clicks == 2)
                    .double_click
                else
                    .press;
                const mx: i32 = @intFromFloat(event.button.x);
                const my: i32 = @intFromFloat(event.button.y);
                const m = keymap.modifiers(@intCast(c.SDL_GetModState()));
                w.mouse_x = mx;
                w.mouse_y = my;
                w.mouse_button_events.push(.{
                    .button = btn,
                    .action = action,
                    .x = mx,
                    .y = my,
                    .ctrl = m.ctrl,
                    .shift = m.shift,
                    .alt = m.alt,
                    .super = m.super,
                });
            }
        },

        // ---------------------------------------------------------------
        // Mouse motion
        // ---------------------------------------------------------------
        c.SDL_EVENT_MOUSE_MOTION => {
            const win_id = event.motion.windowID;
            if (g_registry.find(win_id)) |ptr| {
                const w: *Window = @alignCast(@ptrCast(ptr));
                const mx: i32 = @intFromFloat(event.motion.x);
                const my: i32 = @intFromFloat(event.motion.y);
                const m = keymap.modifiers(@intCast(c.SDL_GetModState()));
                w.mouse_x = mx;
                w.mouse_y = my;
                w.mouse_move_events.push(.{
                    .x = mx,
                    .y = my,
                    .ctrl = m.ctrl,
                    .shift = m.shift,
                    .alt = m.alt,
                    .super = m.super,
                });
            }
        },

        // ---------------------------------------------------------------
        // Mouse wheel — convert SDL float ticks to Win32-style ±120 deltas.
        // ---------------------------------------------------------------
        c.SDL_EVENT_MOUSE_WHEEL => {
            const win_id = event.wheel.windowID;
            if (g_registry.find(win_id)) |ptr| {
                const w: *Window = @alignCast(@ptrCast(ptr));
                const dy: f32 = event.wheel.y;
                // Clamp to i16 range before converting.
                const raw_delta: f32 = dy * 120.0;
                const clamped: i16 = if (raw_delta > @as(f32, std.math.maxInt(i16)))
                    std.math.maxInt(i16)
                else if (raw_delta < @as(f32, std.math.minInt(i16)))
                    std.math.minInt(i16)
                else
                    @intFromFloat(raw_delta);
                const m = keymap.modifiers(@intCast(c.SDL_GetModState()));
                w.mouse_wheel_events.push(.{
                    .delta = clamped,
                    .xpos = w.mouse_x,
                    .ypos = w.mouse_y,
                    .ctrl = m.ctrl,
                    .shift = m.shift,
                    .alt = m.alt,
                });
            }
        },

        // ---------------------------------------------------------------
        // File drop
        // ---------------------------------------------------------------
        c.SDL_EVENT_DROP_FILE => {
            const win_id = event.drop.windowID;
            if (g_registry.find(win_id)) |ptr| {
                const w: *Window = @alignCast(@ptrCast(ptr));
                if (w.on_file_drop) |cb| {
                    if (event.drop.data) |data_ptr| {
                        const path: [*:0]const u8 = data_ptr;
                        const drop_x: i32 = @intFromFloat(event.drop.x);
                        const drop_y: i32 = @intFromFloat(event.drop.y);
                        _ = cb(std.mem.span(path), drop_x, drop_y);
                    }
                }
            }
        },

        else => {
            // Wakeup user event — no action needed beyond unblocking the pump.
            if (event.type == g_wakeup_event_type) {}
        },
    }
}

/// Push a wakeup event to unblock a blocked pumpAppEvents call.
pub fn postWakeup() void {
    if (g_wakeup_event_type == 0) return;
    var event: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
    event.type = g_wakeup_event_type;
    _ = c.SDL_PushEvent(&event);
}

pub fn consumeQuitRequest() bool {
    const q = g_quit;
    g_quit = false;
    return q;
}

/// Return DPI for a NativeHandle (stored as usize = @intFromPtr(SDL_Window*)).
pub fn dpiForNativeHandle(handle: usize) u32 {
    if (handle == 0) return 96;
    const sdl_win: *c.SDL_Window = @ptrFromInt(handle);
    const scale = c.SDL_GetWindowDisplayScale(sdl_win);
    return @intFromFloat(@round(scale * 96.0));
}
