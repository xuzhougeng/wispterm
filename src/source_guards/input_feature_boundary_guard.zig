//! Input/feature-boundary ratchet. `input.zig` historically reaches directly into
//! `file_explorer`'s mutable global state (`file_explorer.g_*`) instead of asking
//! the file_explorer module a query. Round-1 task 04 added query accessors so this
//! coupling can shrink; this guard freezes the raw `file_explorer.g_` reach-in count
//! so it may only ratchet DOWN. Future slices should replace each `file_explorer.g_*`
//! poke with a query call and lower the ceiling — never raise it.
//!
//! A second test guards the extracted `input/mouse_dispatch.zig` submodule: it was
//! split out as a pure dispatch helper and must not depend on the window object, so
//! its AppWindow import count is frozen at 0. See docs/decoupling-guide.md.

const std = @import("std");
const scan = @import("scan.zig");

const input_source = @embedFile("../input.zig");
const mouse_dispatch_source = @embedFile("../input/mouse_dispatch.zig");

/// Frozen at the current baseline; the ratchet may only ratchet DOWN.
/// This counts raw `file_explorer.g_` occurrences (not lines): one line can
/// hold two pokes, so the actual is 73 today even though 72 lines match.
const file_explorer_global_ceiling: usize = 55;

/// The extracted mouse-dispatch helper must not depend on the window object.
const appwindow_import_ceiling: usize = 0;

fn fileExplorerGlobalReachIns(source: []const u8) usize {
    return scan.countOccurrences(source, "file_explorer.g_");
}

fn appWindowImportCount(source: []const u8) usize {
    return scan.countOccurrences(source, "@import(\"../AppWindow.zig\")");
}

test "input.zig reaching into file_explorer globals only shrinks" {
    const count = fileExplorerGlobalReachIns(input_source);
    if (count > file_explorer_global_ceiling) {
        std.debug.print(
            "input_feature_boundary_guard: input.zig touches file_explorer.g_* {d} time(s) " ++
                "(frozen ceiling {d}). Ask file_explorer a query instead; do not raise the ceiling.\n",
            .{ count, file_explorer_global_ceiling },
        );
        return error.InputReachedFileExplorerGlobals;
    }
}

test "input/mouse_dispatch.zig does not import AppWindow" {
    const count = appWindowImportCount(mouse_dispatch_source);
    if (count > appwindow_import_ceiling) {
        std.debug.print(
            "input_feature_boundary_guard: input/mouse_dispatch.zig imports AppWindow.zig {d} time(s) " ++
                "(frozen ceiling {d}). Keep this dispatch helper free of the window object.\n",
            .{ count, appwindow_import_ceiling },
        );
        return error.MouseDispatchImportedAppWindow;
    }
}
