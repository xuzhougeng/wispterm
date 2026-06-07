/// Blocking PTY reader thread.
///
/// Runs a tight blocking read loop on the PTY output stream, processing VT
/// data under the render lock.
///
/// This is critical for resize: some PTY backends emit a redraw when the grid
/// size changes. The pending read on this thread keeps output draining while
/// the writer thread applies the resize.
///
/// Shutdown is delegated to the platform PTY backend.
const std = @import("std");
const Surface = @import("../Surface.zig");
const window_backend = @import("../platform/window_backend.zig");

const READ_BUF_SIZE = 4096;

pub fn threadMain(surface: *Surface) void {
    var buf: [READ_BUF_SIZE]u8 = undefined;
    var resize_pending: std.ArrayListUnmanaged(u8) = .empty;
    defer resize_pending.deinit(surface.allocator);

    while (!surface.exited.load(.acquire)) {
        const bytes_read = surface.pty.readOutput(&buf) catch |err| {
            switch (err) {
                // Backend interrupted the blocking read. Retry unless we're shutting down.
                error.ReadInterrupted => continue,

                // Pipe closed — child process exited
                error.BrokenPipe => {
                    surface.exited.store(true, .release);
                    return;
                },

                // Any other error — exit
                else => {
                    std.debug.print("ReadThread: read error: {}\n", .{err});
                    surface.exited.store(true, .release);
                    return;
                },
            }
        };
        if (bytes_read == 0) {
            surface.exited.store(true, .release);
            return;
        }

        const data = buf[0..bytes_read];
        if (surface.remote_client) |client| {
            client.sendOutput(surface.remote_id[0..], data);
        }

        if (surface.resize_in_progress.load(.acquire)) {
            resize_pending.appendSlice(surface.allocator, data) catch {
                resize_pending.clearRetainingCapacity();
            };
            drainResizeOutput(surface, &resize_pending, &buf);
            if (resize_pending.items.len == 0) continue;
            processOutput(surface, resize_pending.items);
            resize_pending.clearRetainingCapacity();
            continue;
        }

        if (resize_pending.items.len > 0) {
            resize_pending.appendSlice(surface.allocator, data) catch {
                processOutput(surface, resize_pending.items);
                resize_pending.clearRetainingCapacity();
                processOutput(surface, data);
                continue;
            };
            processOutput(surface, resize_pending.items);
            resize_pending.clearRetainingCapacity();
        } else {
            processOutput(surface, data);
        }
    }
}

fn drainResizeOutput(
    surface: *Surface,
    pending: *std.ArrayListUnmanaged(u8),
    scratch: *[READ_BUF_SIZE]u8,
) void {
    while (surface.resize_in_progress.load(.acquire) and !surface.exited.load(.acquire)) {
        const available = surface.pty.outputAvailable() orelse return;

        if (available == 0) {
            std.Thread.sleep(std.time.ns_per_ms);
            continue;
        }

        const to_read = @min(available, scratch.len);
        const bytes_read = surface.pty.readOutput(scratch[0..to_read]) catch |err| switch (err) {
            error.ReadInterrupted => continue,
            else => return,
        };

        if (bytes_read == 0) return;

        const data = scratch[0..bytes_read];
        if (surface.remote_client) |client| {
            client.sendOutput(surface.remote_id[0..], data);
        }
        pending.appendSlice(surface.allocator, data) catch {
            pending.clearRetainingCapacity();
            return;
        };
    }
}

fn processOutput(surface: *Surface, data: []const u8) void {
    if (data.len == 0) return;

    surface.render_state.mutex.lock();
    defer surface.render_state.mutex.unlock();

    surface.resetOscBatch();
    surface.feedVtWithWispTermImageFallback(data);
    surface.scanForOscTitle(data);
    surface.noteAgentOutput(data);
    surface.dirty.store(true, .release);
    window_backend.postWakeup();
}
