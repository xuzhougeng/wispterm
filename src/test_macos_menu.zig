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
    const count = menu_macos.wispterm_macos_menu_top_level_count_for_test();
    try std.testing.expect(count > 0);
    var i: i32 = 0;
    while (i < count) : (i += 1) {
        const item_count = menu_macos.wispterm_macos_menu_item_count_for_test(i);
        if (item_count <= 0) continue;
        const j: i32 = 0;
        const title_ptr = menu_macos.wispterm_macos_menu_item_title_for_test(i, j);
        _ = title_ptr;
        // Walk every item until one matches; the menu holder title isn't
        // exposed, so we rely on a known signature item (e.g., "About WispTerm"
        // for the WispTerm submenu, "New Tab" for File, "Open Command Center"
        // for View).
        if (containsItem(i, expected)) return i;
    }
    return error.SubmenuNotFound;
}

fn containsItem(menu_index: i32, expected_title: []const u8) bool {
    const item_count = menu_macos.wispterm_macos_menu_item_count_for_test(menu_index);
    if (item_count <= 0) return false;
    var i: i32 = 0;
    while (i < item_count) : (i += 1) {
        const ptr = menu_macos.wispterm_macos_menu_item_title_for_test(menu_index, i) orelse continue;
        const slice = std.mem.span(ptr);
        if (std.mem.eql(u8, slice, expected_title)) return true;
    }
    return false;
}

fn findItemIndex(menu_index: i32, expected_title: []const u8) !i32 {
    const item_count = menu_macos.wispterm_macos_menu_item_count_for_test(menu_index);
    try std.testing.expect(item_count > 0);
    var i: i32 = 0;
    while (i < item_count) : (i += 1) {
        const ptr = menu_macos.wispterm_macos_menu_item_title_for_test(menu_index, i) orelse continue;
        if (std.mem.eql(u8, std.mem.span(ptr), expected_title)) return i;
    }
    return error.ItemNotFound;
}

const ItemLoc = struct { menu_idx: i32, item_idx: i32 };

/// Locate a menu item by title across every top-level submenu.
fn findItemAcrossMenus(title: []const u8) !ItemLoc {
    const count = menu_macos.wispterm_macos_menu_top_level_count_for_test();
    var i: i32 = 0;
    while (i < count) : (i += 1) {
        if (findItemIndex(i, title)) |item_idx| {
            return .{ .menu_idx = i, .item_idx = item_idx };
        } else |_| {}
    }
    return error.ItemNotFound;
}

/// Translate a keybind modifier set into the menu's modifier bitmask, so a test
/// can compare the live NSMenu against the source-of-truth `keybind.Set`.
fn menuMaskForMods(mods: keybind.Mods) u32 {
    var mask: u32 = 0;
    if (mods.win) mask |= menu_macos.ModCmd;
    if (mods.shift) mask |= menu_macos.ModShift;
    if (mods.alt) mask |= menu_macos.ModOpt;
    if (mods.ctrl) mask |= menu_macos.ModCtrl;
    return mask;
}

test "menu_macos: install publishes the main menu" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    installFreshMenu();
    try std.testing.expect(menu_macos.isInstalled());
    try std.testing.expect(menu_macos.wispterm_macos_menu_top_level_count_for_test() >= 5);
}

test "menu_macos: top-level menus include WispTerm/File/Edit/View/Window" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    installFreshMenu();
    // Each submenu is identified by a signature item.
    _ = try requireSubmenuTitled("About WispTerm");
    _ = try requireSubmenuTitled("New Tab");
    _ = try requireSubmenuTitled("Copy");
    _ = try requireSubmenuTitled("Open Command Center");
    _ = try requireSubmenuTitled("Next Tab");
}

test "menu_macos: View > Open Command Center carries the toggle_command_palette action and ⌘⇧P" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    installFreshMenu();
    const view_idx = try requireSubmenuTitled("Open Command Center");
    const item_idx = try findItemIndex(view_idx, "Open Command Center");
    try std.testing.expectEqual(
        @as(i32, @intCast(@intFromEnum(keybind.Action.toggle_command_palette))),
        menu_macos.wispterm_macos_menu_item_action_for_test(view_idx, item_idx),
    );
    const key_ptr = menu_macos.wispterm_macos_menu_item_key_equivalent_for_test(view_idx, item_idx);
    try std.testing.expect(key_ptr != null);
    try std.testing.expectEqualStrings("p", std.mem.span(key_ptr.?));
    try std.testing.expectEqual(
        menu_macos.ModCmd | menu_macos.ModShift,
        menu_macos.wispterm_macos_menu_item_modifier_for_test(view_idx, item_idx),
    );
}

test "menu_macos: View > Toggle Tab Sidebar carries toggle_sidebar and ⌘⇧B" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    installFreshMenu();
    const view_idx = try requireSubmenuTitled("Open Command Center");
    const item_idx = try findItemIndex(view_idx, "Toggle Tab Sidebar");
    try std.testing.expectEqual(
        @as(i32, @intCast(@intFromEnum(keybind.Action.toggle_sidebar))),
        menu_macos.wispterm_macos_menu_item_action_for_test(view_idx, item_idx),
    );
    const key_ptr = menu_macos.wispterm_macos_menu_item_key_equivalent_for_test(view_idx, item_idx);
    try std.testing.expectEqualStrings("b", std.mem.span(key_ptr.?));
    try std.testing.expectEqual(
        menu_macos.ModCmd | menu_macos.ModShift,
        menu_macos.wispterm_macos_menu_item_modifier_for_test(view_idx, item_idx),
    );
}

test "menu_macos: WispTerm > Settings carries open_config and ⌘," {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    installFreshMenu();
    const wispterm_idx = try requireSubmenuTitled("About WispTerm");
    const item_idx = try findItemIndex(wispterm_idx, "Settings…");
    try std.testing.expectEqual(
        @as(i32, @intCast(@intFromEnum(keybind.Action.open_config))),
        menu_macos.wispterm_macos_menu_item_action_for_test(wispterm_idx, item_idx),
    );
    const key_ptr = menu_macos.wispterm_macos_menu_item_key_equivalent_for_test(wispterm_idx, item_idx);
    try std.testing.expectEqualStrings(",", std.mem.span(key_ptr.?));
    try std.testing.expectEqual(
        menu_macos.ModCmd,
        menu_macos.wispterm_macos_menu_item_modifier_for_test(wispterm_idx, item_idx),
    );
}

test "menu_macos: invoking Open Command Center fires the action callback with the right id" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    installFreshMenu();
    const view_idx = try requireSubmenuTitled("Open Command Center");
    const item_idx = try findItemIndex(view_idx, "Open Command Center");
    g_last_action = -100;
    menu_macos.wispterm_macos_menu_invoke_for_test(view_idx, item_idx);
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
    menu_macos.wispterm_macos_menu_invoke_for_test(view_idx, item_idx);
    try std.testing.expectEqual(
        @as(i32, @intCast(@intFromEnum(keybind.Action.toggle_sidebar))),
        g_last_action,
    );
}

test "menu_macos: system items (About/Quit) are not routed through the action callback" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    installFreshMenu();
    const wispterm_idx = try requireSubmenuTitled("About WispTerm");
    const about_idx = try findItemIndex(wispterm_idx, "About WispTerm");
    g_last_action = -100;
    menu_macos.wispterm_macos_menu_invoke_for_test(wispterm_idx, about_idx);
    // The helper short-circuits on system tags (tag < 0); callback must stay
    // untouched.
    try std.testing.expectEqual(@as(i32, -100), g_last_action);
}

// Drift guard: the menu hardcodes its key equivalents, but the real bindings
// live in keybind.Set.defaults(). When that set migrated macOS Ctrl→Cmd (commit
// 82e7a60) the menu was left behind, so Edit ▸ Paste Image still showed ⌃⇧V
// while the actual shortcut was ⌘⇧V — and AppKit hijacked Ctrl+V from the
// terminal. This test pins every action item's modifiers to the keybind default
// so the two can never silently diverge again. The Tab cases prove the menu
// correctly keeps Ctrl where the keybinds do (Cmd+Tab is the system switcher).
test "menu_macos: action item modifiers track keybind.Set.defaults (Ctrl→Cmd drift guard)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    installFreshMenu();
    const set = keybind.Set.defaults();

    const cases = [_]struct { title: []const u8, action: keybind.Action }{
        .{ .title = "New Tab", .action = .new_session },
        .{ .title = "Close Tab", .action = .close_panel_or_tab },
        .{ .title = "Copy", .action = .copy },
        .{ .title = "Paste", .action = .paste },
        .{ .title = "Paste Image", .action = .paste_image },
        .{ .title = "Open Command Center", .action = .toggle_command_palette },
        .{ .title = "Increase Font Size", .action = .font_size_increase },
        .{ .title = "Equalize Splits", .action = .equalize_splits },
        // Ctrl is intentionally retained for tab switching.
        .{ .title = "Next Tab", .action = .next_tab },
        .{ .title = "Previous Tab", .action = .previous_tab },
    };
    for (cases) |c| {
        const loc = try findItemAcrossMenus(c.title);
        const binding = set.firstForAction(c.action) orelse return error.MissingKeybind;
        try std.testing.expectEqual(
            menuMaskForMods(binding.trigger.mods),
            menu_macos.wispterm_macos_menu_item_modifier_for_test(loc.menu_idx, loc.item_idx),
        );
    }
}
