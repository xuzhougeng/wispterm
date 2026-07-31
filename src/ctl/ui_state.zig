//! Pure serializer for the wisptermctl `ui-state` command: derives the topmost
//! active overlay and emits the overlay-layer semantic-state JSON. std-only so it
//! unit-tests fast and stays decoupled from the renderer's threadlocal globals —
//! overlays.zig snapshots those into Fields, AppWindow publishes the JSON to the
//! ctl thread. Complements `panes` (tab/split/focus topology) with the overlay
//! layer (which modal is up, selection, filter) that panes does not cover.
const std = @import("std");

pub const Mode = enum { commands, history };
pub const HistorySource = enum { all, sidebar, tab };

pub const Fields = struct {
    command_palette_visible: bool = false,
    command_palette_mode: Mode = .commands,
    command_palette_selected: usize = 0,
    command_palette_visible_count: usize = 0,
    command_palette_filter: []const u8 = "",
    history_selected: usize = 0,
    history_source: HistorySource = .all,
    session_launcher_visible: bool = false,
    session_launcher_selected: usize = 0,
    settings_visible: bool = false,
    ai_form_visible: bool = false,
    ssh_form_visible: bool = false,
    ai_list_visible: bool = false,
    ssh_list_visible: bool = false,
    ai_history_source_visible: bool = false,
    startup_shortcuts_visible: bool = false,
};

/// The single overlay currently capturing input, topmost-first. Session-launcher
/// sub-forms outrank the bare launcher; the command palette is lowest.
pub fn activeOverlay(f: Fields) []const u8 {
    if (f.ai_form_visible) return "ai_form";
    if (f.ssh_form_visible) return "ssh_form";
    if (f.settings_visible) return "settings";
    if (f.ai_list_visible) return "ai_list";
    if (f.ssh_list_visible) return "ssh_list";
    if (f.ai_history_source_visible) return "ai_history_source";
    if (f.session_launcher_visible) return "session_launcher";
    if (f.startup_shortcuts_visible) return "startup_shortcuts";
    if (f.command_palette_visible) return "command_palette";
    return "none";
}

fn modeStr(m: Mode) []const u8 {
    return switch (m) {
        .commands => "commands",
        .history => "history",
    };
}

fn sourceStr(s: HistorySource) []const u8 {
    return switch (s) {
        .all => "all",
        .sidebar => "sidebar",
        .tab => "tab",
    };
}

fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    const enc = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = s }, .{});
    defer allocator.free(enc);
    try out.appendSlice(allocator, enc);
}

fn appendBool(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), b: bool) !void {
    try out.appendSlice(allocator, if (b) "true" else "false");
}

/// Serialize the overlay layer as one JSON object. Caller owns `out`.
pub fn writeJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), f: Fields) !void {
    try out.appendSlice(allocator, "{\"activeOverlay\":");
    try appendJsonString(allocator, out, activeOverlay(f));

    try out.appendSlice(allocator, ",\"commandPalette\":{\"visible\":");
    try appendBool(allocator, out, f.command_palette_visible);
    try out.appendSlice(allocator, ",\"mode\":");
    try appendJsonString(allocator, out, modeStr(f.command_palette_mode));
    try out.print(allocator, ",\"selected\":{d},\"visibleCount\":{d}", .{ f.command_palette_selected, f.command_palette_visible_count });
    try out.appendSlice(allocator, ",\"filter\":");
    try appendJsonString(allocator, out, f.command_palette_filter);
    try out.print(allocator, ",\"historySelected\":{d},\"historySource\":", .{f.history_selected});
    try appendJsonString(allocator, out, sourceStr(f.history_source));
    try out.append(allocator, '}');

    try out.appendSlice(allocator, ",\"sessionLauncher\":{\"visible\":");
    try appendBool(allocator, out, f.session_launcher_visible);
    try out.print(allocator, ",\"selected\":{d}}}", .{f.session_launcher_selected});

    try out.appendSlice(allocator, ",\"settingsVisible\":");
    try appendBool(allocator, out, f.settings_visible);
    try out.appendSlice(allocator, ",\"aiFormVisible\":");
    try appendBool(allocator, out, f.ai_form_visible);
    try out.appendSlice(allocator, ",\"sshFormVisible\":");
    try appendBool(allocator, out, f.ssh_form_visible);
    try out.appendSlice(allocator, ",\"aiListVisible\":");
    try appendBool(allocator, out, f.ai_list_visible);
    try out.appendSlice(allocator, ",\"sshListVisible\":");
    try appendBool(allocator, out, f.ssh_list_visible);
    try out.appendSlice(allocator, ",\"aiHistorySourceVisible\":");
    try appendBool(allocator, out, f.ai_history_source_visible);
    try out.appendSlice(allocator, ",\"startupShortcutsVisible\":");
    try appendBool(allocator, out, f.startup_shortcuts_visible);
    try out.append(allocator, '}');
}

// ---- tests ----
const t = std.testing;

test "activeOverlay picks the topmost overlay, sub-forms above the bare launcher" {
    try t.expectEqualStrings("none", activeOverlay(.{}));
    try t.expectEqualStrings("command_palette", activeOverlay(.{ .command_palette_visible = true }));
    // A session-launcher sub-form (ai_form) outranks both the launcher and palette.
    try t.expectEqualStrings("ai_form", activeOverlay(.{
        .command_palette_visible = true,
        .session_launcher_visible = true,
        .ai_form_visible = true,
    }));
    try t.expectEqualStrings("session_launcher", activeOverlay(.{ .session_launcher_visible = true }));
    try t.expectEqualStrings("settings", activeOverlay(.{ .settings_visible = true }));
}

test "writeJson emits overlay fields with a JSON-escaped filter" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(t.allocator);
    try writeJson(t.allocator, &out, .{
        .command_palette_visible = true,
        .command_palette_mode = .history,
        .command_palette_selected = 2,
        .command_palette_visible_count = 9,
        .command_palette_filter = "de\"p",
        .history_source = .sidebar,
    });
    const s = out.items;
    try t.expect(std.mem.indexOf(u8, s, "\"activeOverlay\":\"command_palette\"") != null);
    try t.expect(std.mem.indexOf(u8, s, "\"mode\":\"history\"") != null);
    try t.expect(std.mem.indexOf(u8, s, "\"selected\":2") != null);
    try t.expect(std.mem.indexOf(u8, s, "\"visibleCount\":9") != null);
    try t.expect(std.mem.indexOf(u8, s, "\"historySource\":\"sidebar\"") != null);
    // The double-quote in the filter must be escaped, not break the JSON.
    try t.expect(std.mem.indexOf(u8, s, "\"filter\":\"de\\\"p\"") != null);
    // Result must be parseable JSON.
    var parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, s, .{});
    defer parsed.deinit();
    try t.expect(parsed.value == .object);
}
