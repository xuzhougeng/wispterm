/// Blocking PTY reader thread (matches Ghostty's threadMainWindows).
///
/// Runs a tight blocking ReadFile loop on the PTY output pipe, processing
/// VT data under the render lock. The output pipe is created via CreatePipe
/// (anonymous, synchronous), so blocking ReadFile properly registers a
/// kernel IRP on the pipe.
///
/// This is critical for resize: ResizePseudoConsole (called on the writer
/// thread) makes ConPTY send a full screen redraw through the pipe. The
/// pending ReadFile on this thread absorbs that output, preventing the
/// pipe from filling up and deadlocking ResizePseudoConsole.
///
/// Shutdown via CancelIoEx from Surface.deinit().
const std = @import("std");
const windows = std.os.windows;
const Surface = @import("../Surface.zig");
const win32 = @import("../apprt/win32.zig");

const READ_BUF_SIZE = 4096;

pub fn threadMain(surface: *Surface) void {
    var buf: [READ_BUF_SIZE]u8 = undefined;
    var resize_pending: std.ArrayListUnmanaged(u8) = .empty;
    defer resize_pending.deinit(surface.allocator);

    while (!surface.exited.load(.acquire)) {
        var bytes_read: windows.DWORD = 0;
        if (windows.kernel32.ReadFile(
            surface.pty.out_pipe,
            &buf,
            READ_BUF_SIZE,
            &bytes_read,
            null, // synchronous — properly registers kernel IRP
        ) == 0) {
            const err = windows.kernel32.GetLastError();
            switch (err) {
                // CancelIoEx from deinit, or ConPTY internally cancelling
                // I/O during resize. Retry unless we're shutting down.
                .OPERATION_ABORTED => continue,

                // Pipe closed — child process exited
                .BROKEN_PIPE => {
                    surface.exited.store(true, .release);
                    return;
                },

                // Any other error — exit
                else => {
                    std.debug.print("ReadThread: ReadFile error: {}\n", .{err});
                    surface.exited.store(true, .release);
                    return;
                },
            }
        }
        if (bytes_read == 0) {
            surface.exited.store(true, .release);
            return;
        }

        const data = buf[0..@intCast(bytes_read)];
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
        var available: windows.DWORD = 0;
        if (win32.PeekNamedPipe(
            surface.pty.out_pipe,
            null,
            0,
            null,
            &available,
            null,
        ) == 0) return;

        if (available == 0) {
            std.Thread.sleep(std.time.ns_per_ms);
            continue;
        }

        const to_read: windows.DWORD = @intCast(@min(@as(usize, @intCast(available)), scratch.len));
        var bytes_read: windows.DWORD = 0;
        if (windows.kernel32.ReadFile(
            surface.pty.out_pipe,
            scratch,
            to_read,
            &bytes_read,
            null,
        ) == 0) {
            if (windows.kernel32.GetLastError() == .OPERATION_ABORTED) continue;
            return;
        }

        if (bytes_read == 0) return;

        const data = scratch[0..@intCast(bytes_read)];
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
    surface.vt_stream.nextSlice(data);
    surface.scanForOscTitle(data);
    surface.noteAgentOutput(data);
    surface.dirty.store(true, .release);
}
