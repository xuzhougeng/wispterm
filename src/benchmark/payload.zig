//! Synthetic VT payload generators for benchmarks (pure std, fast-suite tested).
//!
//! Kept free of ghostty-vt / Surface / build_options so both the CPU CLI
//! (`TerminalStream.zig`) and the in-app GPU benchmark (`scenarios.zig`) share
//! one canonical generator — reports from the two runners stay comparable and
//! this module unit-tests in the lean fast suite.

const std = @import("std");

/// Scroll-flood payload: printable ASCII lines of width `cols` + CRLF, with one
/// SGR color sequence per line so the escape-sequence parser path is exercised.
/// This is the exact content the CPU `terminal-stream` case feeds, so an in-app
/// scroll-flood number lines up with the CLI throughput number.
pub fn generateScrollFlood(allocator: std.mem.Allocator, cols: usize, payload_bytes: usize) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    var written: usize = 0;
    var color: u8 = 0;
    while (written < payload_bytes) {
        const sgr = try std.fmt.allocPrint(allocator, "\x1b[3{d}m", .{color});
        defer allocator.free(sgr);
        try buf.appendSlice(allocator, sgr);
        color = (color + 1) % 8;

        const line_len = @min(cols, payload_bytes - written);
        var i: usize = 0;
        while (i < line_len) : (i += 1) {
            // Cycle printable ASCII 0x21..0x7e.
            const ch: u8 = 0x21 + @as(u8, @intCast((written + i) % 94));
            try buf.append(allocator, ch);
        }
        try buf.appendSlice(allocator, "\r\n");
        written += line_len + 2;
    }

    return try buf.toOwnedSlice(allocator);
}

/// Unicode-heavy payload: CJK (双宽, 3 UTF-8 bytes) + emoji (4 bytes) + ASCII,
/// one SGR color per line. Stresses the wide-cell layout path and the color
/// glyph atlas, which scroll-flood (pure ASCII) never touches — the two
/// scenarios isolate different render costs. `cols` is a display-column budget.
pub fn generateUnicode(allocator: std.mem.Allocator, cols: usize, payload_bytes: usize) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const cjk = "中";
    const ascii_run = "A1";
    const emoji = "😀";

    var written: usize = 0;
    var color: u8 = 0;
    while (written < payload_bytes) {
        const sgr = try std.fmt.allocPrint(allocator, "\x1b[3{d}m", .{color});
        defer allocator.free(sgr);
        try buf.appendSlice(allocator, sgr);
        color = (color + 1) % 8;

        var col_budget: usize = cols;
        // Every run is 2 display columns; stop when fewer than 2 remain so an
        // odd `cols` (e.g. a 79-col terminal) doesn't underflow `col_budget`.
        while (col_budget >= 2 and written < payload_bytes) {
            const pick = (written + col_budget) % 4;
            if (pick == 0) {
                try buf.appendSlice(allocator, cjk);
                col_budget -= 2;
                written += 3;
            } else if (pick == 1) {
                try buf.appendSlice(allocator, emoji);
                col_budget -= 2;
                written += 4;
            } else {
                try buf.appendSlice(allocator, ascii_run);
                col_budget -= 2;
                written += 2;
            }
        }
        try buf.appendSlice(allocator, "\r\n");
        written += 2;
    }

    return try buf.toOwnedSlice(allocator);
}

test "payload: scroll-flood shape — CRLF + SGR, ~payload_bytes" {
    const allocator = std.testing.allocator;
    const payload = try generateScrollFlood(allocator, 10, 256);
    defer allocator.free(payload);
    try std.testing.expect(payload.len >= 128 and payload.len <= 512);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\x1b[3") != null);
}

test "payload: unicode-heavy contains CJK and emoji" {
    const allocator = std.testing.allocator;
    const payload = try generateUnicode(allocator, 40, 1024);
    defer allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "中") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "😀") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\x1b[3") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\r\n") != null);
}

test "payload: scroll-flood is deterministic for the same inputs" {
    const allocator = std.testing.allocator;
    const a = try generateScrollFlood(allocator, 20, 512);
    defer allocator.free(a);
    const b = try generateScrollFlood(allocator, 20, 512);
    defer allocator.free(b);
    try std.testing.expectEqualSlices(u8, a, b);
}

test "payload: unicode-heavy does not underflow on odd column budgets" {
    const allocator = std.testing.allocator;
    // An odd col budget (e.g. a 79-col terminal) must not underflow the
    // 2-column-wide run loop; the line just ends one column short.
    const data = try generateUnicode(allocator, 79, 1024);
    defer allocator.free(data);
    try std.testing.expect(data.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, data, "\r\n") != null);
}

test "payload: unicode-heavy handles a 1-column budget without underflow" {
    const allocator = std.testing.allocator;
    const data = try generateUnicode(allocator, 1, 256);
    defer allocator.free(data);
    // No 2-col run fits a 1-col line, so the payload is just CRLFs.
    try std.testing.expect(data.len > 0);
}
