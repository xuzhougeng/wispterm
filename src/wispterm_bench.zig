//! wispterm-bench — standalone CPU-side benchmark CLI.
//!
//! Build with `zig build -Demit-bench -Doptimize=ReleaseFast` (mirrors Ghostty's
//! `zig build -Demit-bench`). Deliberately a separate artifact, not part of the
//! default install or app packaging: it links ghostty-vt for the TerminalStream
//! case and is intended for branch-to-branch performance comparisons.
const std = @import("std");
const cli = @import("benchmark/cli.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    try cli.run(allocator, args[1..]);
}
