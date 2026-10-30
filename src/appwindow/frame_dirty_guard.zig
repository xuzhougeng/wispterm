//! Source guard for the render loop's PTY-output dirty ordering.
//!
//! The IO thread feeds output and then marks `Surface.dirty` (posting one
//! deduped wakeup) under `render_state.mutex`. The frame must consume that flag
//! BEFORE it snapshots terminal state, so a chunk the snapshot misses re-arms
//! the gate with a fresh wakeup. Consuming it after the (vsync-blocking)
//! present loses such a chunk until an unrelated event wakes the loop — the
//! missing prompt after `echo quick` in an unfocused window. `runMainLoop`
//! cannot run under test, so this pins the ordering in its source; the
//! behavioral half lives in AppWindow.zig's render-gate tests.

const std = @import("std");
const scan = @import("../source_guards/scan.zig");

const appwindow_source = @embedFile("../AppWindow.zig");

/// Body of the top-level function starting at `start_marker`, up to its first
/// unindented closing brace. Accepts LF and CRLF: Windows checkouts may embed
/// AppWindow.zig with CRLF line endings.
fn topLevelFnSource(source: []const u8, start_marker: []const u8) ![]const u8 {
    const start = std.mem.indexOf(u8, source, start_marker) orelse return error.StartMarkerMissing;
    const rest = source[start..];
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, rest, from, "\n}")) |pos| {
        const after = pos + "\n}".len;
        if (after == rest.len or rest[after] == '\n' or rest[after] == '\r') return rest[0..pos];
        from = after;
    }
    return error.EndMarkerMissing;
}

fn mainLoopSource() ![]const u8 {
    return topLevelFnSource(appwindow_source, "fn runMainLoop(");
}

test "topLevelFnSource ends at the first unindented brace with LF or CRLF" {
    const lf = "fn a() void {\n    if (x) {\n    }\n}\nfn b() void {}\n";
    try std.testing.expectEqualStrings("fn a() void {\n    if (x) {\n    }", try topLevelFnSource(lf, "fn a("));
    const crlf = "fn a() void {\r\n    if (x) {\r\n    }\r\n}\r\nfn b() void {}\r\n";
    try std.testing.expectEqualStrings("fn a() void {\r\n    if (x) {\r\n    }\r", try topLevelFnSource(crlf, "fn a("));
}

fn indexOrFail(haystack: []const u8, needle: []const u8) !usize {
    return std.mem.indexOf(u8, haystack, needle) orelse {
        std.debug.print("frame_dirty_guard: `{s}` not found in runMainLoop\n", .{needle});
        return error.MarkerMissing;
    };
}

test "main loop consumes surface dirty once, before any terminal snapshot" {
    const loop = try mainLoopSource();
    try std.testing.expectEqual(@as(usize, 1), scan.countOccurrences(loop, "consumeTabSurfaceDirty("));

    const consume = try indexOrFail(loop, "consumeTabSurfaceDirty(active_tab)");
    // After the synchronized-output deferral, which keeps dirty latched so the
    // watchdog is re-polled on the next iteration...
    try std.testing.expect(try indexOrFail(loop, "synchronizedOutputPendingForVisibleSplits(") < consume);
    // ...and before the first branch that copies terminal state into cells.
    try std.testing.expect(consume < try indexOrFail(loop, "cell_renderer.updateTerminalCells"));
}

test "main loop does not clear surface dirty after present" {
    const loop = try mainLoopSource();
    const after_present = loop[try indexOrFail(loop, "presentBackendFrame(win, ")..];
    const forbidden = [_][]const u8{
        "SurfaceDirty(",
        "dirty.swap(false",
        "dirty.store(false",
    };
    for (forbidden) |needle| {
        if (std.mem.indexOf(u8, after_present, needle) != null) {
            std.debug.print("frame_dirty_guard: `{s}` after present in runMainLoop\n", .{needle});
            return error.DirtyClearedAfterPresent;
        }
    }
}
