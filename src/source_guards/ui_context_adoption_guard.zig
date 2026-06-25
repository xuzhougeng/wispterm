//! UI-context boundary ratchet. `ui/context.zig` is the round-1 seam that lets
//! callers pass UI state explicitly instead of reaching through the window object.
//! It only depends on `std` and must NOT import `AppWindow.zig` — otherwise it would
//! re-introduce the very coupling it exists to break. This freezes its AppWindow
//! import count at 0. See docs/decoupling-guide.md.

const std = @import("std");
const scan = @import("scan.zig");

const ui_context_source = @embedFile("../ui/context.zig");

/// The UI-context seam must stay independent of the window object.
const appwindow_import_ceiling: usize = 0;

fn appWindowImportCount(source: []const u8) usize {
    return scan.countOccurrences(source, "@import(\"../AppWindow.zig\")");
}

test "ui/context.zig does not import AppWindow" {
    const count = appWindowImportCount(ui_context_source);
    if (count > appwindow_import_ceiling) {
        std.debug.print(
            "ui_context_adoption_guard: ui/context.zig imports AppWindow.zig {d} time(s) " ++
                "(frozen ceiling {d}). This seam exists to decouple from the window object; keep AppWindow out.\n",
            .{ count, appwindow_import_ceiling },
        );
        return error.UiContextImportedAppWindow;
    }
}
