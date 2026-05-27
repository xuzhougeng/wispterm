/// IO writer thread — runs an xev event loop for mailbox-driven operations.
///
/// Each Surface spawns one of these (plus a ReadThread for PTY data).
/// The writer thread handles:
///   - Mailbox wakeup: drains queued messages from the main thread
///   - Resize coalescing: 25ms xev.Timer batches rapid resize events
///   - Stop signal: clean shutdown via xev.Async
///
/// Resize is applied directly on this thread. This works because the
/// ReadThread is concurrently blocked on PTY output, which keeps data draining
/// while a backend-specific resize may emit redraw output.
///
/// Flow:
///   Main thread → mailbox.send(.resize) → mailbox.notify()
///   Writer thread → wakeup → drainMailbox → coalesce timer (25ms)
///   Writer thread → coalesceCallback → pty.setSize + terminal.resize
const std = @import("std");
const xev = @import("xev");
const Surface = @import("../Surface.zig");
const renderer = @import("../renderer.zig");

const Thread = @This();

const COALESCE_MS = 25;

loop: xev.Loop,
stop: xev.Async,
coalesce: xev.Timer,

/// Completions — must be stable pointers (not moved while in use).
wakeup_c: xev.Completion = .{},
stop_c: xev.Completion = .{},
coalesce_c: xev.Completion = .{},
coalesce_cancel_c: xev.Completion = .{},

/// Pending coalesced resize (latest wins). Writer-thread-only.
coalesce_data: ?renderer.size.GridSize = null,

/// Whether the coalesce timer is currently active.
coalesce_active: bool = false,

/// Back-pointer to the surface, set during threadMain.
surface: ?*Surface = null,

pub fn init() !Thread {
    return .{
        .loop = try xev.Loop.init(.{}),
        .stop = try xev.Async.init(),
        .coalesce = try xev.Timer.init(),
    };
}

pub fn deinit(self: *Thread) void {
    self.coalesce.deinit();
    self.stop.deinit();
    self.loop.deinit();
}

pub fn threadMain(self: *Thread, surface: *Surface) void {
    self.surface = surface;

    // Register mailbox wakeup callback
    surface.mailbox.wakeup.wait(&self.loop, &self.wakeup_c, Thread, self, wakeupCallback);

    // Register stop callback
    self.stop.wait(&self.loop, &self.stop_c, Thread, self, stopCallback);

    // Run the event loop until stop is signaled
    self.loop.run(.until_done) catch {};
}

fn wakeupCallback(
    self_opt: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch return .disarm;
    const self = self_opt orelse return .disarm;
    self.drainMailbox();
    return .rearm;
}

fn stopCallback(
    _: ?*Thread,
    loop: *xev.Loop,
    _: *xev.Completion,
    _: xev.Async.WaitError!void,
) xev.CallbackAction {
    loop.stop();
    return .disarm;
}

fn drainMailbox(self: *Thread) void {
    const surface = self.surface orelse return;
    while (surface.mailbox.pop()) |msg| {
        defer msg.deinit();

        switch (msg) {
            .resize => |grid| self.handleResize(grid),
            .resize_immediate => |grid| self.handleResizeImmediate(grid),
            .write_small => |payload| writeToPty(surface, payload.data[0..payload.len]),
            .write_alloc => |payload| writeToPty(surface, payload.data),
        }
    }
}

fn writeToPty(surface: *Surface, data: []const u8) void {
    surface.pty.writeInput(data) catch {};
}

fn handleResize(self: *Thread, grid: renderer.size.GridSize) void {
    self.coalesce_data = grid;

    if (self.coalesce_active) return; // timer already running, it will pick up latest data

    // Start 25ms coalesce timer
    self.coalesce_active = true;
    self.coalesce.run(&self.loop, &self.coalesce_c, COALESCE_MS, Thread, self, coalesceCallback);
}

fn handleResizeImmediate(self: *Thread, grid: renderer.size.GridSize) void {
    // Drop any older coalesced resize so a delayed timer cannot undo the
    // immediate layout change.
    self.coalesce_data = null;
    applyResize(self.surface.?, grid);
}

fn coalesceCallback(
    self_opt: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch {
        if (self_opt) |self| self.coalesce_active = false;
        return .disarm;
    };
    const self = self_opt orelse return .disarm;

    self.coalesce_active = false;

    if (self.coalesce_data) |grid| {
        self.coalesce_data = null;
        applyResize(self.surface.?, grid);
    }

    return .disarm;
}

fn applyResize(surface: *Surface, grid: renderer.size.GridSize) void {
    // PTY resize first (like Ghostty), then terminal.
    // The ReadThread is concurrently in a blocking PTY read. This keeps
    // backend output draining while resize side effects are emitted.
    surface.resize_in_progress.store(true, .release);
    defer surface.resize_in_progress.store(false, .release);

    surface.pty.setSize(.{ .ws_col = grid.cols, .ws_row = grid.rows }) catch {};

    surface.render_state.mutex.lock();
    defer surface.render_state.mutex.unlock();

    surface.terminal.resize(surface.allocator, grid.cols, grid.rows) catch {};
    surface.terminal.width_px = @intFromFloat(@as(f32, @floatFromInt(grid.cols)) * surface.size.cell.width);
    surface.terminal.height_px = @intFromFloat(@as(f32, @floatFromInt(grid.rows)) * surface.size.cell.height);

    // Match Ghostty's Termio.resize behavior: a resize is allowed to break
    // synchronized output mode so TUI redraws become visible immediately.
    surface.clearSynchronizedOutputLocked();

    surface.terminal.scrollViewport(.{ .bottom = {} });
    surface.dirty.store(true, .release);
}
