//! macOS NSMenu implementation behind `platform/menu.zig`.
//!
//! Builds a WispTerm main menu (WispTerm / File / Edit / View / Window) by
//! driving the ObjC bridge with structured calls. Each user-facing menu item
//! carries an action id derived from `keybind.Action`'s integer index so the
//! callback can re-enter the standard action dispatcher and reuse the exact
//! same code path that keyboard shortcuts go through.

const std = @import("std");
const keybind = @import("../keybind.zig");
const menu = @import("menu.zig");

// Modifier bitmask values must mirror the WISPTERM_MAC_MENU_MOD_* constants in
// the ObjC bridge.
pub const ModCmd: u32 = 1 << 0;
pub const ModShift: u32 = 1 << 1;
pub const ModOpt: u32 = 1 << 2;
pub const ModCtrl: u32 = 1 << 3;

pub const SystemAction = enum(i32) {
    about = -2,
    hide = -3,
    hide_others = -4,
    show_all = -5,
    quit = -6,
};

const CCallback = *const fn (action_id: i32) callconv(.c) void;

extern fn wispterm_macos_menu_install(callback: CCallback) void;
extern fn wispterm_macos_menu_begin() void;
extern fn wispterm_macos_menu_begin_submenu(title: [*:0]const u8) void;
extern fn wispterm_macos_menu_add_item(
    title: [*:0]const u8,
    action_id: i32,
    key_equivalent: [*:0]const u8,
    modifier_mask: u32,
) void;
extern fn wispterm_macos_menu_add_separator() void;
extern fn wispterm_macos_menu_end_submenu() void;
extern fn wispterm_macos_menu_finalize() void;
extern fn wispterm_macos_menu_is_installed() bool;

// Test-only inspection functions exposed by the bridge.
pub extern fn wispterm_macos_menu_top_level_count_for_test() i32;
pub extern fn wispterm_macos_menu_item_count_for_test(menu_index: i32) i32;
pub extern fn wispterm_macos_menu_item_action_for_test(menu_index: i32, item_index: i32) i32;
pub extern fn wispterm_macos_menu_item_title_for_test(menu_index: i32, item_index: i32) ?[*:0]const u8;
pub extern fn wispterm_macos_menu_item_modifier_for_test(menu_index: i32, item_index: i32) u32;
pub extern fn wispterm_macos_menu_item_key_equivalent_for_test(menu_index: i32, item_index: i32) ?[*:0]const u8;
pub extern fn wispterm_macos_menu_invoke_for_test(menu_index: i32, item_index: i32) void;

var g_handler: ?menu.ActionHandler = null;

fn onCAction(action_id: i32) callconv(.c) void {
    const action = actionFromId(action_id) orelse return;
    if (g_handler) |handler| handler(action);
}

pub fn install(handler: menu.ActionHandler) void {
    g_handler = handler;
    wispterm_macos_menu_install(onCAction);
    buildDefaultMenu();
}

pub fn isInstalled() bool {
    return wispterm_macos_menu_is_installed();
}

pub fn actionFromId(action_id: i32) ?keybind.Action {
    if (action_id < 0) return null;
    const field_count = std.meta.fields(keybind.Action).len;
    if (@as(usize, @intCast(action_id)) >= field_count) return null;
    return @as(keybind.Action, @enumFromInt(@as(@typeInfo(keybind.Action).@"enum".tag_type, @intCast(action_id))));
}

inline fn id(action: keybind.Action) i32 {
    return @intCast(@intFromEnum(action));
}

fn buildDefaultMenu() void {
    // On macOS the in-app shortcuts use Cmd (⌘) where other platforms use Ctrl:
    // `keybind.Set.defaults()` migrates every non-global, non-Tab Ctrl default to
    // its Cmd equivalent. These menu key equivalents must mirror that migration —
    // not just so the displayed shortcut is right, but because an NSMenu key
    // equivalent is intercepted by AppKit before the terminal sees it. Leaving
    // these on Ctrl made AppKit swallow Ctrl+V / Ctrl+Shift+V (literal-next and
    // friends) as "Paste" / "Paste Image" instead of passing them to the shell.
    // Tab switching (Ctrl+Tab / Ctrl+Shift+Tab) stays on Ctrl to match the
    // keybinds (Cmd+Tab is the system app switcher).
    const AppMod = ModCmd;

    wispterm_macos_menu_begin();

    // WispTerm (application) menu.
    wispterm_macos_menu_begin_submenu("WispTerm");
    wispterm_macos_menu_add_item("About WispTerm", @intFromEnum(SystemAction.about), "", 0);
    wispterm_macos_menu_add_separator();
    wispterm_macos_menu_add_item("Settings…", id(.open_settings), ",", ModCmd);
    wispterm_macos_menu_add_separator();
    wispterm_macos_menu_add_item("Hide WispTerm", @intFromEnum(SystemAction.hide), "h", ModCmd);
    wispterm_macos_menu_add_item("Hide Others", @intFromEnum(SystemAction.hide_others), "h", ModCmd | ModOpt);
    wispterm_macos_menu_add_item("Show All", @intFromEnum(SystemAction.show_all), "", 0);
    wispterm_macos_menu_add_separator();
    wispterm_macos_menu_add_item("Quit WispTerm", @intFromEnum(SystemAction.quit), "q", ModCmd);
    wispterm_macos_menu_end_submenu();

    // File.
    wispterm_macos_menu_begin_submenu("File");
    wispterm_macos_menu_add_item("New Tab", id(.new_session), "t", AppMod | ModShift);
    wispterm_macos_menu_add_item("New Window", id(.new_window), "n", AppMod | ModShift);
    wispterm_macos_menu_add_item("Split Right", id(.split_right), "+", AppMod | ModShift);
    wispterm_macos_menu_add_item("Split Down", id(.split_down), "-", AppMod | ModShift);
    wispterm_macos_menu_add_separator();
    wispterm_macos_menu_add_item("Close Tab", id(.close_panel_or_tab), "w", AppMod);
    wispterm_macos_menu_end_submenu();

    // Edit.
    wispterm_macos_menu_begin_submenu("Edit");
    wispterm_macos_menu_add_item("Copy", id(.copy), "c", AppMod);
    wispterm_macos_menu_add_item("Paste", id(.paste), "v", AppMod);
    wispterm_macos_menu_add_item("Paste Image", id(.paste_image), "v", AppMod | ModShift);
    wispterm_macos_menu_end_submenu();

    // View.
    wispterm_macos_menu_begin_submenu("View");
    wispterm_macos_menu_add_item("Open Command Center", id(.toggle_command_palette), "p", AppMod | ModShift);
    wispterm_macos_menu_add_separator();
    wispterm_macos_menu_add_item("Toggle Tab Sidebar", id(.toggle_sidebar), "b", AppMod | ModShift);
    wispterm_macos_menu_add_item("Toggle Copilot", id(.toggle_ai_copilot), "a", AppMod | ModShift);
    wispterm_macos_menu_add_item("Toggle File Explorer", id(.toggle_file_explorer), "e", AppMod | ModShift | ModOpt);
    wispterm_macos_menu_add_separator();
    wispterm_macos_menu_add_item("Increase Font Size", id(.font_size_increase), "+", AppMod);
    wispterm_macos_menu_add_item("Decrease Font Size", id(.font_size_decrease), "-", AppMod);
    wispterm_macos_menu_end_submenu();

    // Window.
    wispterm_macos_menu_begin_submenu("Window");
    wispterm_macos_menu_add_item("Toggle Maximize", id(.toggle_maximize), "\r", ModOpt);
    wispterm_macos_menu_add_separator();
    // Tab switching keeps Ctrl on macOS (Cmd+Tab is the system app switcher).
    wispterm_macos_menu_add_item("Next Tab", id(.next_tab), "\t", ModCtrl);
    wispterm_macos_menu_add_item("Previous Tab", id(.previous_tab), "\t", ModCtrl | ModShift);
    wispterm_macos_menu_add_separator();
    wispterm_macos_menu_add_item("Equalize Splits", id(.equalize_splits), "z", AppMod | ModShift);
    wispterm_macos_menu_end_submenu();

    wispterm_macos_menu_finalize();
}

test "menu_macos: actionFromId round-trips known WispTerm actions" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const expected = keybind.Action.toggle_command_palette;
    const action_id: i32 = @intCast(@intFromEnum(expected));
    try std.testing.expectEqual(@as(?keybind.Action, expected), actionFromId(action_id));

    // The Copilot menu item round-trips too (View ▸ Toggle Copilot).
    const copilot = keybind.Action.toggle_ai_copilot;
    try std.testing.expectEqual(@as(?keybind.Action, copilot), actionFromId(@intCast(@intFromEnum(copilot))));
}

test "menu_macos: actionFromId rejects system action ids" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    try std.testing.expectEqual(@as(?keybind.Action, null), actionFromId(@intFromEnum(SystemAction.quit)));
    try std.testing.expectEqual(@as(?keybind.Action, null), actionFromId(-1));
}

test "menu_macos: actionFromId rejects out-of-range ids" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const max_id: i32 = @intCast(std.meta.fields(keybind.Action).len);
    try std.testing.expectEqual(@as(?keybind.Action, null), actionFromId(max_id));
    try std.testing.expectEqual(@as(?keybind.Action, null), actionFromId(max_id + 5));
}
