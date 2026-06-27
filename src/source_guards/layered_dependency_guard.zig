//! Layered-dependency ratchet. `termio/**` is the PTY I/O layer; it must sit
//! BELOW the renderer in the dependency graph and never reach up into it. After
//! the round-1 termio extraction it depends on `core/geometry.zig` for the few
//! shapes it needs instead of importing `renderer/**`, so the `@import("..renderer..")`
//! count across the termio sources is 0. This freezes that: termio may not grow a
//! renderer dependency. New termio code must import `core/*` (or a narrower
//! module), not reach up into the renderer. See docs/decoupling-guide.md.

const std = @import("std");
const scan = @import("scan.zig");

const GuardedSource = struct {
    name: []const u8,
    source: []const u8,
};

const termio_sources = [_]GuardedSource{
    .{ .name = "Thread.zig", .source = @embedFile("../termio/Thread.zig") },
    .{ .name = "ReadThread.zig", .source = @embedFile("../termio/ReadThread.zig") },
    .{ .name = "Mailbox.zig", .source = @embedFile("../termio/Mailbox.zig") },
    .{ .name = "message.zig", .source = @embedFile("../termio/message.zig") },
    .{ .name = "read_coalesce.zig", .source = @embedFile("../termio/read_coalesce.zig") },
};

/// termio is a lower layer than the renderer: it may not import it at all.
const renderer_import_ceiling: usize = 0;

fn rendererImportCount(source: []const u8) usize {
    // Matches any relative import path that crosses into the renderer tree,
    // e.g. `@import("../renderer/...")` or `@import("renderer/...")`.
    return scan.countOccurrences(source, "renderer/");
}

test "termio does not import the renderer layer" {
    var total: usize = 0;
    for (termio_sources) |source_file| {
        total += rendererImportCount(source_file.source);
    }
    if (total > renderer_import_ceiling) {
        std.debug.print(
            "layered_dependency_guard: termio/** references the renderer layer {d} time(s) " ++
                "(frozen ceiling {d}). termio is below the renderer; import core/* instead of reaching up.\n",
            .{ total, renderer_import_ceiling },
        );
        return error.TermioReachedRenderer;
    }
}

fn termioSourceListed(name: []const u8) bool {
    for (termio_sources) |source_file| {
        if (std.mem.eql(u8, source_file.name, name)) return true;
    }
    return false;
}

test "termio layered-dependency guard covers new Zig files" {
    var dir = try std.fs.cwd().openDir("src/termio", .{ .iterate = true });
    defer dir.close();

    var missing = false;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        if (!termioSourceListed(entry.name)) {
            std.debug.print(
                "layered_dependency_guard: src/termio/{s} is not in termio_sources; add it so new termio files cannot bypass the renderer dependency check.\n",
                .{entry.name},
            );
            missing = true;
        }
    }

    try std.testing.expect(!missing);
}
