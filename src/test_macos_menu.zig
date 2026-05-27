//! Native macOS NSMenu smoke tests.
//!
//! Verifies that the bridge constructs the full menu tree, that user-facing
//! menu items carry the expected keybind.Action ids, that key equivalents and
//! modifier masks line up with the default key bindings, and that invoking a
//! menu item drives the registered C callback.

const std = @import("std");
const builtin = @import("builtin");
const platform_menu = @import("platform/menu.zig");
const menu_macos = @import("platform/menu_macos.zig");
const keybind = @import("keybind.zig");

threadlocal var g_last_action: i32 = -100;

fn testActionHandler(action: keybind.Action) void {
    g_last_action = @intCast(@intFromEnum(action));
}

fn installFreshMenu() void {
    g_last_action = -100;
    platform_menu.install(testActionHandler);
}

fn requireSubmenuTitled(expected: []const u8) !i32 {
    const count = menu_macos.phantty_macos_menu_top_level_count_for_test();
    try std.testing.expect(count > 0);
    var i: i32 = 0;
    while (i < count) : (i += 1) {
        const item_count = menu_macos.phantty_macos_menu_item_count_for_test(i);
        if (item_count <= 0) continue;
        const j: i32 = 0;
        const title_ptr = menu_macos.phantty_macos_menu_item_title_for_test(i, j);
        _ = title_ptr;
        // Walk every item until one matches; the menu holder title isn't
        // exposed, so we rely on a known signature item (e.g., "About Phantty"
        // for the Phantty submenu, "New Tab" for File, "Open Command Center"
        // for View).
        if (containsItem(i, expected)) return i;
    }
    return error.SubmenuNotFound;
}

fn containsItem(menu_index: i32, expected_title: []const u8) bool {
    const item_count = menu_macos.phantty_macos_menu_item_count_for_test(menu_index);
    if (item_count <= 0) return false;
    var i: i32 = 0;
    while (i < item_count) : (i += 1) {
        const ptr = menu_macos.phantty_macos_menu_item_title_for_test(menu_index, i) orelse continue;
        const slice = std.mem.span(ptr);
        if (std.mem.eql(u8, slice, expected_title)) return true;
    }
    return false;
}

fn findItemIndex(menu_index: i32, expected_title: []const u8) !i32 {
    const item_count = menu_macos.phantty_macos_menu_item_count_for_test(menu_index);
    try std.testing.expect(item_count > 0);
    var i: i32 = 0;
    while (i < item_count) : (i += 1) {
        const ptr = menu_macos.phantty_macos_menu_item_title_for_test(menu_index, i) orelse continue;
        if (std.mem.eql(u8, std.mem.span(ptr), expected_title)) return i;
    }
    return error.ItemNotFound;
}

test "menu_macos: install publishes the main menu" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    installFreshMenu();
    try std.testing.expect(menu_macos.isInstalled());
    try std.testing.expect(menu_macos.phantty_macos_menu_top_level_count_for_test() >= 5);
}

test "menu_macos: top-level menus include Phantty/File/Edit/View/Window" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    installFreshMenu();
    // Each submenu is identified by a signature item.
    _ = try requireSubmenuTitled("About Phantty");
    _ = try requireSubmenuTitled("New Tab");
    _ = try requireSubmenuTitled("Copy");
    _ = try requireSubmenuTitled("Open Command Center");
    _ = try requireSubmenuTitled("Next Tab");
}

test "menu_macos: View > Open Command Center carries the toggle_command_palette action and ⌃⇧P" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    installFreshMenu();
    const view_idx = try requireSubmenuTitled("Open Command Center");
    const item_idx = try findItemIndex(view_idx, "Open Command Center");
    try std.testing.expectEqual(
        @as(i32, @intCast(@intFromEnum(keybind.Action.toggle_command_palette))),
        menu_macos.phantty_macos_menu_item_action_for_test(view_idx, item_idx),
    );
    const key_ptr = menu_macos.phantty_macos_menu_item_key_equivalent_for_test(view_idx, item_idx);
    try std.testing.expect(key_ptr != null);
    try std.testing.expectEqualStrings("p", std.mem.span(key_ptr.?));
    try std.testing.expectEqual(
        menu_macos.ModCtrl | menu_macos.ModShift,
        menu_macos.phantty_macos_menu_item_modifier_for_test(view_idx, item_idx),
    );
}

test "menu_macos: View > Toggle Tab Sidebar carries toggle_sidebar and ⌃⇧B" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    installFreshMenu();
    const view_idx = try requireSubmenuTitled("Open Command Center");
    const item_idx = try findItemIndex(view_idx, "Toggle Tab Sidebar");
    try std.testing.expectEqual(
        @as(i32, @intCast(@intFromEnum(keybind.Action.toggle_sidebar))),
        menu_macos.phantty_macos_menu_item_action_for_test(view_idx, item_idx),
    );
    const key_ptr = menu_macos.phantty_macos_menu_item_key_equivalent_for_test(view_idx, item_idx);
    try std.testing.expectEqualStrings("b", std.mem.span(key_ptr.?));
    try std.testing.expectEqual(
        menu_macos.ModCtrl | menu_macos.ModShift,
        menu_macos.phantty_macos_menu_item_modifier_for_test(view_idx, item_idx),
    );
}

test "menu_macos: Phantty > Settings carries open_config and ⌘," {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    installFreshMenu();
    const phantty_idx = try requireSubmenuTitled("About Phantty");
    const item_idx = try findItemIndex(phantty_idx, "Settings…");
    try std.testing.expectEqual(
        @as(i32, @intCast(@intFromEnum(keybind.Action.open_config))),
        menu_macos.phantty_macos_menu_item_action_for_test(phantty_idx, item_idx),
    );
    const key_ptr = menu_macos.phantty_macos_menu_item_key_equivalent_for_test(phantty_idx, item_idx);
    try std.testing.expectEqualStrings(",", std.mem.span(key_ptr.?));
    try std.testing.expectEqual(
        menu_macos.ModCmd,
        menu_macos.phantty_macos_menu_item_modifier_for_test(phantty_idx, item_idx),
    );
}

test "menu_macos: invoking Open Command Center fires the action callback with the right id" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    installFreshMenu();
    const view_idx = try requireSubmenuTitled("Open Command Center");
    const item_idx = try findItemIndex(view_idx, "Open Command Center");
    g_last_action = -100;
    menu_macos.phantty_macos_menu_invoke_for_test(view_idx, item_idx);
    try std.testing.expectEqual(
        @as(i32, @intCast(@intFromEnum(keybind.Action.toggle_command_palette))),
        g_last_action,
    );
}

test "menu_macos: invoking Toggle Tab Sidebar fires the action callback" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    installFreshMenu();
    const view_idx = try requireSubmenuTitled("Open Command Center");
    const item_idx = try findItemIndex(view_idx, "Toggle Tab Sidebar");
    g_last_action = -100;
    menu_macos.phantty_macos_menu_invoke_for_test(view_idx, item_idx);
    try std.testing.expectEqual(
        @as(i32, @intCast(@intFromEnum(keybind.Action.toggle_sidebar))),
        g_last_action,
    );
}

test "menu_macos: system items (About/Quit) are not routed through the action callback" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    installFreshMenu();
    const phantty_idx = try requireSubmenuTitled("About Phantty");
    const about_idx = try findItemIndex(phantty_idx, "About Phantty");
    g_last_action = -100;
    menu_macos.phantty_macos_menu_invoke_for_test(phantty_idx, about_idx);
    // The helper short-circuits on system tags (tag < 0); callback must stay
    // untouched.
    try std.testing.expectEqual(@as(i32, -100), g_last_action);
}
