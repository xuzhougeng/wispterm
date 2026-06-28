//! Overlay-boundary ratchet. The round-1 overlay split carved pure, unit-testable
//! submodules (layout math, input mapping, codecs, view-models) out of the heavy
//! `overlays.zig` graph. Those modules are pure precisely BECAUSE they do not
//! depend on the window object: they never `@import("../../AppWindow.zig")`. This
//! freezes that — each extracted pure module must keep its AppWindow import count
//! at 0, so it stays testable in the fast suite without the GL/Surface graph.
//!
//! NOTE: only the already-extracted PURE modules are listed. `overlays.zig`
//! itself legitimately imports AppWindow and is intentionally excluded.
//! See docs/decoupling-guide.md.

const std = @import("std");
const scan = @import("scan.zig");

const overlays_source = @embedFile("../renderer/overlays.zig");

const PureModule = struct {
    name: []const u8,
    source: []const u8,
};

const pure_overlay_modules = [_]PureModule{
    .{ .name = "command_palette_layout.zig", .source = @embedFile("../renderer/overlays/command_palette_layout.zig") },
    .{ .name = "command_palette_input.zig", .source = @embedFile("../renderer/overlays/command_palette_input.zig") },
    .{ .name = "command_palette_state.zig", .source = @embedFile("../renderer/overlays/command_palette_state.zig") },
    .{ .name = "assistant_profiles.zig", .source = @embedFile("../renderer/overlays/assistant_profiles.zig") },
    .{ .name = "profile_codec.zig", .source = @embedFile("../renderer/overlays/profile_codec.zig") },
    .{ .name = "ssh_profiles.zig", .source = @embedFile("../renderer/overlays/ssh_profiles.zig") },
    .{ .name = "ssh_profiles_layout.zig", .source = @embedFile("../renderer/overlays/ssh_profiles_layout.zig") },
    .{ .name = "transfer_toast_model.zig", .source = @embedFile("../renderer/overlays/transfer_toast_model.zig") },
    .{ .name = "update_prompt_model.zig", .source = @embedFile("../renderer/overlays/update_prompt_model.zig") },
    .{ .name = "whats_new_model.zig", .source = @embedFile("../renderer/overlays/whats_new_model.zig") },
};

/// Pure overlay submodules must not depend on the window object.
const appwindow_import_ceiling: usize = 0;

fn appWindowImportCount(source: []const u8) usize {
    return scan.countOccurrences(source, "@import(\"../../AppWindow.zig\")");
}

fn pureOverlayModuleListed(name: []const u8) bool {
    for (pure_overlay_modules) |module| {
        if (std.mem.eql(u8, module.name, name)) return true;
    }
    return false;
}

fn isConventionallyPureOverlayModule(name: []const u8) bool {
    return std.mem.endsWith(u8, name, "_layout.zig") or
        std.mem.endsWith(u8, name, "_input.zig") or
        std.mem.endsWith(u8, name, "_model.zig") or
        std.mem.endsWith(u8, name, "_state.zig") or
        std.mem.endsWith(u8, name, "_codec.zig");
}

fn staleSessionLauncherTmuxRowCount(source: []const u8) usize {
    return scan.countOccurrences(source, "command_center_state.SESSION_LAUNCHER_ROW_TMUX");
}

test "extracted pure overlay modules do not import AppWindow" {
    for (pure_overlay_modules) |module| {
        const count = appWindowImportCount(module.source);
        if (count > appwindow_import_ceiling) {
            std.debug.print(
                "overlay_boundary_guard: {s} imports AppWindow.zig {d} time(s) " ++
                    "(frozen ceiling {d}). This module is pure; keep AppWindow out so it stays fast-suite testable.\n",
                .{ module.name, count, appwindow_import_ceiling },
            );
            return error.PureOverlayImportedAppWindow;
        }
    }
}

test "pure overlay boundary guard covers conventionally pure overlay files" {
    var dir = try std.fs.cwd().openDir("src/renderer/overlays", .{ .iterate = true });
    defer dir.close();

    var missing = false;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file or !isConventionallyPureOverlayModule(entry.name)) continue;
        if (!pureOverlayModuleListed(entry.name)) {
            std.debug.print(
                "overlay_boundary_guard: src/renderer/overlays/{s} matches the pure-module naming convention but is not in pure_overlay_modules; add it so it cannot bypass the AppWindow import guard.\n",
                .{entry.name},
            );
            missing = true;
        }
    }

    try std.testing.expect(!missing);
}

test "session launcher uses runtime tmux row layout" {
    const count = staleSessionLauncherTmuxRowCount(overlays_source);
    if (count > 0) {
        std.debug.print(
            "overlay_boundary_guard: renderer/overlays.zig uses the compile-time tmux launcher row {d} time(s). " ++
                "Use platform_pty_command.sessionLauncherTmuxRow() so WSL-less Windows shifts rows correctly.\n",
            .{count},
        );
        return error.SessionLauncherUsedStaticTmuxRow;
    }
}
