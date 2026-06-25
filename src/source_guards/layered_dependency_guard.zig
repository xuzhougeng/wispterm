//! Layered-dependency ratchet. `termio/**` is the PTY I/O layer; it must sit
//! BELOW the renderer in the dependency graph and never reach up into it. After
//! the round-1 termio extraction it depends on `core/geometry.zig` for the few
//! shapes it needs instead of importing `renderer/**`, so the `@import("..renderer..")`
//! count across the termio sources is 0. This freezes that: termio may not grow a
//! renderer dependency. New termio code must import `core/*` (or a narrower
//! module), not reach up into the renderer. See docs/decoupling-guide.md.

const std = @import("std");
const scan = @import("scan.zig");

const termio_sources = [_][]const u8{
    @embedFile("../termio/Thread.zig"),
    @embedFile("../termio/ReadThread.zig"),
    @embedFile("../termio/Mailbox.zig"),
    @embedFile("../termio/message.zig"),
    @embedFile("../termio/read_coalesce.zig"),
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
    for (termio_sources) |source| {
        total += rendererImportCount(source);
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
