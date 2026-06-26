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
const read_coalesce = @import("read_coalesce.zig");

/// Large reads keep the per-chunk overhead (render-lock acquisition, VT parse
/// setup, OSC/agent scans, UI wakeup) off the hot path during output floods:
/// fewer, bigger chunks instead of thousands of 4KB ones. Both PTY backends
/// accept arbitrary buffer sizes.
const READ_BUF_SIZE = 64 * 1024;

pub fn threadMain(surface: *Surface) void {
    defer surface.markStopped();

    var buf: [READ_BUF_SIZE]u8 = undefined;
    var resize_pending: std.ArrayListUnmanaged(u8) = .empty;
    defer resize_pending.deinit(surface.allocator);
    var output_pending: std.ArrayListUnmanaged(u8) = .empty;
    defer output_pending.deinit(surface.allocator);

    while (!surface.exited.load(.acquire)) {
        const bytes_read = surface.pty.readOutput(&buf) catch |err| {
            switch (handleReadError(surface, err)) {
                .retry => continue,
                .stop => return,
            }
        };
        if (bytes_read == 0) {
            if (!surface.exited.load(.acquire)) {
                surface.markExited(.eof, surface.pollExitStatus());
            }
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
                processOutputCoalesced(surface, data, &output_pending, &buf);
                continue;
            };
            processOutput(surface, resize_pending.items);
            resize_pending.clearRetainingCapacity();
        } else {
            processOutputCoalesced(surface, data, &output_pending, &buf);
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
        const bytes_read = surface.pty.readOutput(scratch[0..to_read]) catch |err| switch (handleReadError(surface, err)) {
            .retry => continue,
            .stop => return,
        };

        if (bytes_read == 0) {
            if (!surface.exited.load(.acquire)) {
                surface.markExited(.eof, surface.pollExitStatus());
            }
            return;
        }

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

fn processOutputCoalesced(
    surface: *Surface,
    first: []const u8,
    pending: *std.ArrayListUnmanaged(u8),
    scratch: *[READ_BUF_SIZE]u8,
) void {
    if (first.len == 0) return;

    pending.clearRetainingCapacity();
    pending.appendSlice(surface.allocator, first) catch {
        processOutput(surface, first);
        return;
    };

    drainAvailableOutput(surface, pending, scratch);
    processOutput(surface, pending.items);
}

fn drainAvailableOutput(
    surface: *Surface,
    pending: *std.ArrayListUnmanaged(u8),
    scratch: *[READ_BUF_SIZE]u8,
) void {
    while (!surface.exited.load(.acquire)) {
        const available = surface.pty.outputAvailable() orelse return;
        const to_read = read_coalesce.nextDrainLen(available, scratch.len, pending.items.len);
        if (to_read == 0) return;

        const bytes_read = surface.pty.readOutput(scratch[0..to_read]) catch |err| switch (handleReadError(surface, err)) {
            .retry => continue,
            .stop => return,
        };
        if (bytes_read == 0) {
            if (!surface.exited.load(.acquire)) {
                surface.markExited(.eof, surface.pollExitStatus());
            }
            return;
        }

        const data = scratch[0..bytes_read];
        if (surface.remote_client) |client| {
            client.sendOutput(surface.remote_id[0..], data);
        }
        pending.appendSlice(surface.allocator, data) catch {
            processOutput(surface, pending.items);
            pending.clearRetainingCapacity();
            processOutput(surface, data);
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
    // One wakeup per UI consume cycle is enough — the render loop drains all
    // pending output on a single frame; per-chunk posts only flood the
    // platform event queue during output bursts.
    if (surface.markOutputDirty()) window_backend.postWakeup();
}

const ReadErrorAction = enum { retry, stop };

fn handleReadError(surface: *Surface, err: anyerror) ReadErrorAction {
    if (err == error.ReadInterrupted) {
        return if (surface.exited.load(.acquire)) .stop else .retry;
    }

    if (surface.exited.load(.acquire)) return .stop;

    if (err == error.BrokenPipe) {
        surface.markExited(.broken_pipe, surface.pollExitStatus());
        return .stop;
    }

    surface.failIo(.pty_read, err);
    return .stop;
}
