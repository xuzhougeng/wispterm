//! Thread-safe queue of closures to run on the main (event-pump) thread. The
//! Linux/SDL analog of macOS `wispterm_macos_run_on_main`: worker-thread
//! windows enqueue window-mutation closures here and wake the main pump
//! (`postWakeup`); the main thread drains them inside `pumpAppEvents`.
const std = @import("std");

pub const Task = struct {
    run: *const fn (ctx: *anyopaque) void,
    ctx: *anyopaque,
};

pub const Queue = struct {
    mutex: std.Thread.Mutex = .{},
    items: std.ArrayListUnmanaged(Task) = .{},

    pub fn enqueue(self: *Queue, alloc: std.mem.Allocator, task: Task) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.items.append(alloc, task);
    }

    /// Run every queued task in FIFO order. Tasks are copied out under the lock
    /// so a task may itself enqueue without deadlocking.
    pub fn drain(self: *Queue, alloc: std.mem.Allocator) void {
        self.mutex.lock();
        const batch = self.items.toOwnedSlice(alloc) catch {
            // OOM: fall back to running in place under the lock.
            defer self.mutex.unlock();
            for (self.items.items) |t| t.run(t.ctx);
            self.items.clearRetainingCapacity();
            return;
        };
        self.mutex.unlock();
        defer alloc.free(batch);
        for (batch) |t| t.run(t.ctx);
    }

    pub fn deinit(self: *Queue, alloc: std.mem.Allocator) void {
        self.items.deinit(alloc);
    }
};
