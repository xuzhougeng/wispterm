//! File-size backstop. A single Zig source file crossing `max_lines` fails the
//! test gate. This is a coarse "runaway" tripwire, NOT a health metric: a file
//! well under the limit can still be tangled. Cohesion/coupling — reviewed via
//! the other `source_guards/` ratchets and the architecture docs — is the real
//! criterion. See AGENTS.md and docs/decoupling-guide.md.

const std = @import("std");
const scan = @import("scan.zig");

/// Hard ceiling. Crossing it fails the gate. Chosen as the line `AppWindow.zig`
/// was pulled back under (10,469 → 7,091) during the ui-state-debt refactor;
/// the whole tree currently sits below it, so there is no exemption list.
pub const max_lines: usize = 10_000;

/// Count source lines as `wc -l` does: the number of newline bytes.
pub fn lineCount(source: []const u8) usize {
    return scan.countOccurrences(source, "\n");
}

pub fn exceedsLimit(line_count: usize) bool {
    return line_count > max_lines;
}

test "exceedsLimit triggers strictly above the limit" {
    try std.testing.expect(!exceedsLimit(max_lines));
    try std.testing.expect(exceedsLimit(max_lines + 1));
    try std.testing.expect(!exceedsLimit(0));
}

test "lineCount counts newlines" {
    try std.testing.expectEqual(@as(usize, 3), lineCount("a\nb\nc\n"));
    try std.testing.expectEqual(@as(usize, 0), lineCount(""));
}

// The live backstop: every `.zig` under `src/` must stay under `max_lines`.
// Covers future files too (it iterates the tree, not a fixed list). Skips
// silently when `src/` is not reachable from the CWD so it never produces a
// false failure when the test binary is run from an unexpected directory; it
// only ever FAILS on a genuinely oversized file found on disk.
test "no src/*.zig file exceeds the line backstop" {
    const gpa = std.testing.allocator;
    var dir = std.fs.cwd().openDir("src", .{ .iterate = true }) catch return;
    defer dir.close();

    var offenders = std.ArrayList(u8).empty;
    defer offenders.deinit(gpa);

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const source = try dir.readFileAlloc(gpa, entry.path, 16 * 1024 * 1024);
        defer gpa.free(source);
        const lines = lineCount(source);
        if (exceedsLimit(lines)) {
            try offenders.writer(gpa).print("  src/{s}: {d} lines (> {d})\n", .{ entry.path, lines, max_lines });
        }
    }

    if (offenders.items.len != 0) {
        std.debug.print(
            "\nfile_size_guard: source file(s) crossed the {d}-line backstop:\n{s}" ++
                "Split by responsibility (see docs/decoupling-guide.md), do not raise the limit.\n",
            .{ max_lines, offenders.items },
        );
        return error.FileExceedsLineBackstop;
    }
}
