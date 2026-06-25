//! Import-hub ratchet. `AppWindow.zig` re-exports whole modules via
//! `pub const X = @import(...)`, which lets unrelated code reach them as
//! `AppWindow.X` and quietly turns the window object into the import hub for the
//! whole app (123 imports today). This freezes the re-export count: it may only
//! shrink. New code must import the real module directly
//! (`@import("appwindow/tab.zig")`), not add another forward through
//! `AppWindow`. See docs/decoupling-guide.md.

const std = @import("std");
const scan = @import("scan.zig");

const app_window = @embedFile("../AppWindow.zig");

/// Frozen at the current count; the ratchet may only ratchet DOWN.
const reexport_ceiling: usize = 29;

fn reexportCount(source: []const u8) usize {
    return scan.countTopLevelLinesContaining(source, "pub const ", "= @import(");
}

test "AppWindow module re-exports only shrink" {
    const count = reexportCount(app_window);
    if (count > reexport_ceiling) {
        std.debug.print(
            "import_hub_guard: AppWindow.zig re-exports {d} modules via `pub const X = @import(...)` " ++
                "(frozen ceiling {d}). Import the real module directly; do not add another AppWindow forward.\n",
            .{ count, reexport_ceiling },
        );
        return error.ImportHubGrew;
    }
}
