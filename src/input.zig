//! Input handling for AppWindow.
//!
//! Processes platform input events (keyboard, mouse, resize) and dispatches
//! to appropriate handlers. Manages clipboard, selection, scrollbar dragging,
//! split divider dragging, and fullscreen toggle.

const std = @import("std");
const builtin = @import("builtin");
const AppWindow = @import("AppWindow.zig");
const tab = AppWindow.tab;
const active_tab_state = @import("appwindow/active_tab.zig");
const titlebar = AppWindow.titlebar;
const font = AppWindow.font;
const overlays = AppWindow.overlays;
const split_layout = AppWindow.split_layout;
const file_explorer = AppWindow.file_explorer;
const file_backend = @import("file_backend.zig");
const markdown_preview = @import("preview/markdown.zig");
const preview_gallery = @import("preview/gallery.zig");
const preview_token = @import("preview/token.zig");
const browser_panel = AppWindow.browser_panel;
const html_server = @import("html/server.zig");
const html_server_model = @import("html/server_model.zig");
const ai_sidebar = @import("assistant/sidebar/panel.zig");
const copilot_hint_gate = @import("assistant/sidebar/hint_gate.zig");
const ui_perf = AppWindow.ui_perf;
const render_diagnostics = @import("render_diagnostics.zig");
const link_open = @import("link_open.zig");
const platform_dirs = @import("platform/dirs.zig");
const platform_local_path = @import("platform/local_path.zig");
const platform_remote_file = @import("platform/remote_file.zig");
const platform_open_url = @import("platform/open_url.zig");
const platform_file_dialog = @import("platform/file_dialog.zig");
const input_shortcuts = @import("input_shortcuts.zig");
const keybind = @import("keybind.zig");
const platform_cursor = @import("platform/cursor.zig");
const platform_input = @import("platform/input_events.zig");
const platform_pty_command = @import("platform/pty_command.zig");
const platform_wsl = @import("platform/wsl.zig");
const window_backend = @import("platform/window_backend.zig");
const window_metrics = @import("ui/window_metrics.zig");
const WindowMetrics = window_metrics.WindowMetrics;
const input_key = @import("input/key.zig");
const assistant_conversation = @import("input/assistant_conversation.zig");
const command_dispatch = @import("input/command_dispatch.zig");
const file_explorer_keymap = @import("input/file_explorer_keymap.zig");
const input_effects = @import("input/effects.zig");
const ui_effect = @import("appwindow/ui_effect.zig");
const command_palette_input = @import("renderer/overlays/command_palette_input.zig");
const Config = @import("config.zig");
const Surface = @import("Surface.zig");
const SplitTree = @import("split_tree.zig");
const PreviewPane = @import("preview/pane.zig");
const PreviewImageDrag = @import("input/preview_image_drag.zig");
const selection_unit = @import("selection_unit.zig");
const Selection = Surface.Selection;
const CellPos = struct { col: usize, row: usize };

const clipboard = @import("input/clipboard.zig");
const click_tracker = @import("input/click_tracker.zig");
const hit_test = @import("input/hit_test.zig");
const preview_source = @import("input/preview_source.zig");
const preview_diagnostics = @import("preview/diagnostics.zig");
const ls_path_context = @import("input/ls_path_context.zig");
const terminal_link_action = @import("input/terminal_link_action.zig");
const underline_span = @import("input/underline_span.zig");
const mouse_report = @import("input/mouse_report.zig");
const mouse_dispatch = @import("input/mouse_dispatch.zig");
const mouse_wheel_scroll = @import("input/mouse_wheel_scroll.zig");
const close_confirm = @import("close_confirm.zig");
const close_confirm_state = @import("ui/close_shortcut_confirm.zig");
const jupyter_picker = @import("jupyter/picker.zig");
const copilot_picker = @import("assistant/sidebar/picker.zig");
const jupyter_detect = @import("jupyter/detect.zig");
const scp = @import("scp.zig");
const writeToPty = clipboard.writeToPty;
pub const copyTextToClipboard = clipboard.copyTextToClipboard;
const activeTerminalSelectionExists = clipboard.activeTerminalSelectionExists;
const handleConfiguredRightClick = clipboard.handleConfiguredRightClick;
const copyAiChatToClipboard = clipboard.copyAiChatToClipboard;
const copyAiChatCutToClipboard = clipboard.copyAiChatCutToClipboard;
const copyAiChatMessageToClipboard = clipboard.copyAiChatMessageToClipboard;
pub const handleFileDrop = clipboard.handleFileDrop;
pub const copySelectionToClipboard = clipboard.copySelectionToClipboard;
pub const pasteFromClipboard = clipboard.pasteFromClipboard;
const pasteClipboardIntoBrowserUrlBar = clipboard.pasteClipboardIntoBrowserUrlBar;
const pasteClipboardIntoSessionLauncher = clipboard.pasteClipboardIntoSessionLauncher;
const pasteFromClipboardIntoAiChat = clipboard.pasteFromClipboardIntoAiChat;
const pasteImageIntoAiChat = clipboard.pasteImageIntoAiChat;
pub const pasteImageFromClipboard = clipboard.pasteImageFromClipboard;
pub const writeTextToActivePty = clipboard.writeTextToActivePty;
pub const writeTextToSurfacePty = clipboard.writeTextToSurfacePty;
const looksLikePreviewPath = preview_source.looksLikePreviewPath;
const resolveTerminalPreviewPath = preview_source.resolveTerminalPreviewPath;
const basenameForPreview = preview_source.basenameForPreview;
const buildPreviewCommand = preview_source.buildPreviewCommand;

const LayoutResizeUrgency = terminal_link_action.LayoutResizeUrgency;
const TerminalPathClickAction = terminal_link_action.TerminalPathClickAction;
const InteractiveUnderlineTokenKind = terminal_link_action.InteractiveUnderlineTokenKind;

const panelToggleResizeUrgency = terminal_link_action.panelToggleResizeUrgency;

fn clientSize(win: anytype) window_backend.Size {
    return window_backend.clientSize(win);
}

fn syncGridFromWindow(win: anytype) void {
    const size = clientSize(win);
    syncGridFromWindowSize(size.width, size.height);
}

fn syncPanelGridFromWindow(win: anytype) void {
    const size = clientSize(win);
    syncPanelGridFromWindowSize(size.width, size.height);
}

fn syncSidebarWidthToBackend(win: anytype) void {
    window_backend.setSidebarWidth(win, @intFromFloat(titlebar.sidebarWidth()));
}

const primaryOpenMod = terminal_link_action.primaryOpenMod;
const terminalPathClickAction = terminal_link_action.terminalPathClickAction;

const interactiveUnderlineTokenKind = terminal_link_action.interactiveUnderlineTokenKind;
const looksLikeDownloadPath = terminal_link_action.looksLikeDownloadPath;

test "input: WeChat QR panel consumes text input while visible" {
    AppWindow.weixin_qr_panel.g_visible = true;
    defer AppWindow.weixin_qr_panel.g_visible = false;

    try std.testing.expect(weixinQrPanelConsumesChar());
}

test "input: command palette shortcut toggles command center" {
    const previous_keybinds = AppWindow.g_keybinds;
    defer AppWindow.g_keybinds = previous_keybinds;
    defer overlays.commandPaletteClose();

    AppWindow.g_keybinds = keybind.Set.defaults();
    overlays.commandPaletteClose();

    // macOS migrates app shortcuts to Cmd (the super modifier); other platforms
    // keep Ctrl. So the command palette is Cmd+Shift+P on macOS, Ctrl+Shift+P else.
    const is_macos = builtin.os.tag == .macos;
    const palette_key = platform_input.KeyEvent{
        .key_code = 'P',
        .ctrl = !is_macos,
        .shift = true,
        .alt = false,
        .super = is_macos,
    };

    handleKey(palette_key);
    try std.testing.expect(overlays.commandPaletteVisible());

    handleKey(palette_key);
    try std.testing.expect(!overlays.commandPaletteVisible());
}

test "input: browser toolbar has a refresh action entrypoint" {
    const info = @typeInfo(@TypeOf(refreshBrowserPanel)).@"fn";
    try std.testing.expectEqual(@as(usize, 0), info.params.len);
}

test "input: preview gallery neighbor opens next raster sibling" {
    const gpa = std.testing.allocator;
    const prev_allocator = AppWindow.g_allocator;
    defer AppWindow.g_allocator = prev_allocator;
    AppWindow.g_allocator = gpa;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a.png", .data = "a" });
    try tmp.dir.writeFile(.{ .sub_path = "b.pdf", .data = "b" });
    try tmp.dir.writeFile(.{ .sub_path = "c.jpg", .data = "c" });

    const root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(root);
    const current_path = try std.fs.path.join(gpa, &.{ root, "b.pdf" });
    defer gpa.free(current_path);
    const next_path = try std.fs.path.join(gpa, &.{ root, "c.jpg" });
    defer gpa.free(next_path);

    var pane = try PreviewPane.create(gpa);
    defer pane.unref(gpa);
    pane.open(.pdf, "b.pdf", current_path, "current");

    AppWindow.g_force_rebuild = false;
    AppWindow.g_cells_valid = true;
    try std.testing.expect(openPreviewGalleryNeighbor(pane, true));
    try std.testing.expectEqualStrings("c.jpg", pane.title());
    try std.testing.expectEqualStrings(next_path, pane.path());
    try std.testing.expect(AppWindow.g_force_rebuild);
    try std.testing.expect(!AppWindow.g_cells_valid);
}

test "input: focused preview ignores shift-modified navigation keys" {
    const gpa = std.testing.allocator;
    const prev_allocator = AppWindow.g_allocator;
    const previous_tabs = tab.g_tabs;
    const previous_count = tab.g_tab_count;
    const previous_active = active_tab_state.g_active_tab;
    const previous_force_rebuild = AppWindow.g_force_rebuild;
    const previous_cells_valid = AppWindow.g_cells_valid;

    var pane = try PreviewPane.create(gpa);
    defer pane.unref(gpa);
    pane.open(.image, "a.png", "a.png", "current");

    var tab_state = tab.TabState{
        .tree = try SplitTree.initPane(gpa, .{ .preview = pane }),
    };
    defer tab_state.tree.deinit();

    AppWindow.g_allocator = gpa;
    tab.g_tabs = .{null} ** tab.MAX_TABS;
    tab.g_tabs[0] = &tab_state;
    tab.g_tab_count = 1;
    active_tab_state.g_active_tab = 0;
    defer {
        AppWindow.g_allocator = prev_allocator;
        tab.g_tabs = previous_tabs;
        tab.g_tab_count = previous_count;
        active_tab_state.g_active_tab = previous_active;
        AppWindow.g_force_rebuild = previous_force_rebuild;
        AppWindow.g_cells_valid = previous_cells_valid;
    }

    AppWindow.g_force_rebuild = false;
    AppWindow.g_cells_valid = true;
    handleKey(.{
        .key_code = platform_input.key_right,
        .ctrl = false,
        .shift = true,
        .alt = false,
        .super = false,
    });

    try std.testing.expect(!AppWindow.g_force_rebuild);
    try std.testing.expect(AppWindow.g_cells_valid);
}

// Regression: the event-driven render loop (PR #168) only paints a frame when
// something marks the UI dirty. Command-center family overlays consume their own
// key/char events and never reach the terminal, so each navigation/typing keystroke
// MUST request a rebuild — otherwise the new selection only appears on the next
// incidental wake (cursor blink ~530ms / mouse move), which felt like lag ("不跟手").
const arrow_down_event = platform_input.KeyEvent{
    .key_code = platform_input.key_down,
    .ctrl = false,
    .shift = false,
    .alt = false,
    .super = false,
};

const arrow_left_event = platform_input.KeyEvent{
    .key_code = platform_input.key_left,
    .ctrl = false,
    .shift = false,
    .alt = false,
    .super = false,
};

const arrow_right_event = platform_input.KeyEvent{
    .key_code = platform_input.key_right,
    .ctrl = false,
    .shift = false,
    .alt = false,
    .super = false,
};

const enter_event = platform_input.KeyEvent{
    .key_code = platform_input.key_enter,
    .ctrl = false,
    .shift = false,
    .alt = false,
    .super = false,
};

const escape_event = platform_input.KeyEvent{
    .key_code = platform_input.key_escape,
    .ctrl = false,
    .shift = false,
    .alt = false,
    .super = false,
};

test "input: command palette arrow navigation requests a repaint" {
    const previous_keybinds = AppWindow.g_keybinds;
    defer AppWindow.g_keybinds = previous_keybinds;
    defer overlays.commandPaletteClose();

    AppWindow.g_keybinds = keybind.Set.defaults();
    overlays.commandPaletteOpen();
    try std.testing.expect(overlays.commandPaletteVisible());

    AppWindow.g_force_rebuild = false;
    AppWindow.g_cells_valid = true;
    handleKey(arrow_down_event);

    try std.testing.expect(AppWindow.g_force_rebuild);
    try std.testing.expect(!AppWindow.g_cells_valid);
}

test "input: command palette dispatchKey returns repaint effect" {
    const previous_keybinds = AppWindow.g_keybinds;
    defer AppWindow.g_keybinds = previous_keybinds;
    defer overlays.commandPaletteClose();

    AppWindow.g_keybinds = keybind.Set.defaults();
    overlays.commandPaletteOpen();

    const effect = dispatchKey(arrow_down_event);

    try std.testing.expect(effect.consumed);
    try std.testing.expect(effect.needs_rebuild);
    try std.testing.expect(effect.cells_invalid);
}

test "input: command palette dispatchKey preserves repaint for unmapped palette keys" {
    const previous_keybinds = AppWindow.g_keybinds;
    defer AppWindow.g_keybinds = previous_keybinds;
    defer overlays.commandPaletteClose();

    AppWindow.g_keybinds = keybind.Set.defaults();
    overlays.commandPaletteOpen();

    const effect = dispatchKey(.{
        .key_code = 0x5A,
        .ctrl = false,
        .shift = false,
        .alt = false,
        .super = false,
    });

    try std.testing.expect(effect.consumed);
    try std.testing.expect(effect.needs_rebuild);
    try std.testing.expect(effect.cells_invalid);
}

test "input: window close confirm dispatchKey returns repaint effect" {
    defer overlays.windowCloseConfirmClose();
    overlays.closeConfirmOpen(.window, .window_generic);

    const effect = dispatchKey(.{
        .key_code = platform_input.key_escape,
        .ctrl = false,
        .shift = false,
        .alt = false,
        .super = false,
    });

    try std.testing.expect(effect.consumed);
    try std.testing.expect(effect.needs_rebuild);
    try std.testing.expect(effect.cells_invalid);
}

test "input: command palette text filtering requests a repaint" {
    defer overlays.commandPaletteClose();
    overlays.commandPaletteOpen();
    try std.testing.expect(overlays.commandPaletteVisible());

    AppWindow.g_force_rebuild = false;
    AppWindow.g_cells_valid = true;
    handleChar(.{ .codepoint = 'a' });

    try std.testing.expect(AppWindow.g_force_rebuild);
    try std.testing.expect(!AppWindow.g_cells_valid);
}

test "input: command palette dispatchChar returns repaint effect for text filtering" {
    defer overlays.commandPaletteClose();
    overlays.commandPaletteOpen();

    const effect = dispatchChar(.{ .codepoint = 'a' });

    try std.testing.expect(effect.consumed);
    try std.testing.expect(effect.needs_rebuild);
    try std.testing.expect(effect.cells_invalid);
}

test "input: command palette dispatchChar consumes ctrl text without repaint" {
    defer overlays.commandPaletteClose();
    overlays.commandPaletteOpen();

    const effect = dispatchChar(.{ .codepoint = 'a', .ctrl = true, .alt = false });

    try std.testing.expect(effect.consumed);
    try std.testing.expect(!effect.needs_rebuild);
    try std.testing.expect(!effect.cells_invalid);
}

test "input: session launcher arrow navigation requests a repaint" {
    const previous_keybinds = AppWindow.g_keybinds;
    defer AppWindow.g_keybinds = previous_keybinds;
    defer overlays.sessionLauncherClose();

    AppWindow.g_keybinds = keybind.Set.defaults();
    overlays.sessionLauncherOpen();
    try std.testing.expect(overlays.sessionLauncherVisible());

    AppWindow.g_force_rebuild = false;
    AppWindow.g_cells_valid = true;
    handleKey(arrow_down_event);

    try std.testing.expect(AppWindow.g_force_rebuild);
    try std.testing.expect(!AppWindow.g_cells_valid);
}

test "input: session launcher dispatchKey returns repaint effect" {
    const previous_keybinds = AppWindow.g_keybinds;
    defer AppWindow.g_keybinds = previous_keybinds;
    defer overlays.sessionLauncherClose();

    AppWindow.g_keybinds = keybind.Set.defaults();
    overlays.sessionLauncherOpen();

    const effect = dispatchKey(arrow_down_event);

    try std.testing.expect(effect.consumed);
    try std.testing.expect(effect.needs_rebuild);
    try std.testing.expect(effect.cells_invalid);
}

test "input: command center child escape returns to command center" {
    const previous_keybinds = AppWindow.g_keybinds;
    defer AppWindow.g_keybinds = previous_keybinds;
    defer overlays.commandPaletteClose();
    defer overlays.sessionLauncherClose();

    AppWindow.g_keybinds = keybind.Set.defaults();
    overlays.commandPaletteClose();
    overlays.sessionLauncherClose();

    overlays.commandPaletteOpen();
    try std.testing.expect(overlays.commandPaletteVisible());

    handleKey(enter_event);
    try std.testing.expect(!overlays.commandPaletteVisible());
    try std.testing.expect(overlays.sessionLauncherVisible());

    handleKey(escape_event);
    try std.testing.expect(overlays.commandPaletteVisible());
    try std.testing.expect(!overlays.sessionLauncherVisible());
}

test "input: settings page arrow navigation requests a repaint" {
    const previous_keybinds = AppWindow.g_keybinds;
    defer AppWindow.g_keybinds = previous_keybinds;
    defer overlays.settingsPageClose();

    AppWindow.g_keybinds = keybind.Set.defaults();
    overlays.settingsPageOpen();
    try std.testing.expect(overlays.settingsPageVisible());

    AppWindow.g_force_rebuild = false;
    AppWindow.g_cells_valid = true;
    handleKey(arrow_down_event);

    try std.testing.expect(AppWindow.g_force_rebuild);
    try std.testing.expect(!AppWindow.g_cells_valid);
}

test "input: settings page dispatchKey returns repaint effect" {
    const previous_keybinds = AppWindow.g_keybinds;
    defer AppWindow.g_keybinds = previous_keybinds;
    defer overlays.settingsPageClose();

    AppWindow.g_keybinds = keybind.Set.defaults();
    overlays.settingsPageOpen();

    const effect = dispatchKey(arrow_down_event);

    try std.testing.expect(effect.consumed);
    try std.testing.expect(effect.needs_rebuild);
    try std.testing.expect(effect.cells_invalid);
}

test "input: port forwarding arrow navigation requests a repaint" {
    const allocator = std.testing.allocator;
    const previous_count = tab.g_tab_count;
    const previous_active = active_tab_state.g_active_tab;
    if (!tab.spawnPortForwardingTab(allocator)) return error.SkipZigTest;
    defer {
        while (tab.g_tab_count > previous_count) {
            const idx = tab.g_tab_count - 1;
            if (tab.g_tabs[idx]) |t| {
                t.deinit(allocator);
                allocator.destroy(t);
                tab.g_tabs[idx] = null;
            }
            tab.g_tab_count -= 1;
        }
        active_tab_state.g_active_tab = previous_active;
    }

    AppWindow.g_force_rebuild = false;
    AppWindow.g_cells_valid = true;
    handleKey(arrow_down_event);

    try std.testing.expect(AppWindow.g_force_rebuild);
    try std.testing.expect(!AppWindow.g_cells_valid);
}

test "input: skill center tool toggle requests a repaint" {
    const allocator = std.testing.allocator;
    const previous_allocator = AppWindow.g_allocator;
    const previous_tabs = tab.g_tabs;
    const previous_count = tab.g_tab_count;
    const previous_active = active_tab_state.g_active_tab;
    const previous_force_rebuild = AppWindow.g_force_rebuild;
    const previous_cells_valid = AppWindow.g_cells_valid;
    defer {
        AppWindow.g_allocator = previous_allocator;
        tab.g_tabs = previous_tabs;
        tab.g_tab_count = previous_count;
        active_tab_state.g_active_tab = previous_active;
        AppWindow.g_force_rebuild = previous_force_rebuild;
        AppWindow.g_cells_valid = previous_cells_valid;
        platform_dirs.clearTestConfigDirForCurrentThread();
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("tools/fake_tool/bin");
    try tmp.dir.writeFile(.{ .sub_path = "tools/fake_tool/SKILL.md", .data = "---\nname: fake_tool\n---\n" });
    try tmp.dir.writeFile(.{ .sub_path = "tools/fake_tool/bin/fake_tool", .data = "" });
    const manifest =
        \\{
        \\  "kind": "binary_tool",
        \\  "id": "fake_tool",
        \\  "function_name": "fake_tool",
        \\  "enabled": false,
        \\  "executable": "bin/fake_tool",
        \\  "source_path": "/tmp/fake_tool",
        \\  "sha256": "abc123",
        \\  "imported_at_ms": 1,
        \\  "description": "fake"
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "tools/fake_tool/manifest.json", .data = manifest });
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    platform_dirs.setTestConfigDirForCurrentThread(root);

    AppWindow.g_allocator = allocator;
    tab.g_tabs = .{null} ** tab.MAX_TABS;
    tab.g_tab_count = 0;
    active_tab_state.g_active_tab = 0;
    if (!tab.spawnSkillCenterTab(allocator)) return error.SkipZigTest;
    defer {
        while (tab.g_tab_count > 0) {
            const idx = tab.g_tab_count - 1;
            if (tab.g_tabs[idx]) |t| {
                t.deinit(allocator);
                allocator.destroy(t);
                tab.g_tabs[idx] = null;
            }
            tab.g_tab_count -= 1;
        }
    }

    const session = AppWindow.activeSkillCenter() orelse return error.ExpectedSkillCenterTab;
    const executable_path = try std.fs.path.join(allocator, &.{ root, "tools", "fake_tool", "bin", "fake_tool" });
    var executable_path_owned = true;
    errdefer if (executable_path_owned) allocator.free(executable_path);
    const skill_path = try std.fs.path.join(allocator, &.{ root, "tools", "fake_tool", "SKILL.md" });
    var skill_path_owned = true;
    errdefer if (skill_path_owned) allocator.free(skill_path);
    const name = try allocator.dupe(u8, "fake_tool");
    var name_owned = true;
    errdefer if (name_owned) allocator.free(name);
    const entries = try allocator.alloc(AppWindow.skill_center.LibraryEntry, 1);
    var entries_owned = true;
    errdefer if (entries_owned) allocator.free(entries);
    entries[0] = .{ .tool = .{
        .name = name,
        .executable_path = executable_path,
        .skill_path = skill_path,
        .enabled = false,
    } };
    session.mutex.lock();
    session.model.setEntries(entries);
    entries_owned = false;
    name_owned = false;
    executable_path_owned = false;
    skill_path_owned = false;
    session.mutex.unlock();

    AppWindow.g_force_rebuild = false;
    AppWindow.g_cells_valid = true;
    handleKey(.{ .key_code = 0x45, .ctrl = false, .shift = false, .alt = false, .super = false });

    try std.testing.expect(AppWindow.g_force_rebuild);
    try std.testing.expect(!AppWindow.g_cells_valid);

    const persisted_manifest = try tmp.dir.readFileAlloc(allocator, "tools/fake_tool/manifest.json", 4096);
    defer allocator.free(persisted_manifest);
    try std.testing.expect(std.mem.indexOf(u8, persisted_manifest, "\"enabled\": true") != null);

    _ = AppWindow.skillCenterToggleToolEnabled();
}

test "input: skill center first-party tool toggle writes state and requests a repaint" {
    const allocator = std.testing.allocator;
    const previous_allocator = AppWindow.g_allocator;
    const previous_tabs = tab.g_tabs;
    const previous_count = tab.g_tab_count;
    const previous_active = active_tab_state.g_active_tab;
    const previous_force_rebuild = AppWindow.g_force_rebuild;
    const previous_cells_valid = AppWindow.g_cells_valid;
    defer {
        AppWindow.g_allocator = previous_allocator;
        tab.g_tabs = previous_tabs;
        tab.g_tab_count = previous_count;
        active_tab_state.g_active_tab = previous_active;
        AppWindow.g_force_rebuild = previous_force_rebuild;
        AppWindow.g_cells_valid = previous_cells_valid;
        platform_dirs.clearTestConfigDirForCurrentThread();
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    platform_dirs.setTestConfigDirForCurrentThread(root);

    AppWindow.g_allocator = allocator;
    tab.g_tabs = .{null} ** tab.MAX_TABS;
    tab.g_tab_count = 0;
    active_tab_state.g_active_tab = 0;
    if (!tab.spawnSkillCenterTab(allocator)) return error.SkipZigTest;
    defer {
        while (tab.g_tab_count > 0) {
            const idx = tab.g_tab_count - 1;
            if (tab.g_tabs[idx]) |t| {
                t.deinit(allocator);
                allocator.destroy(t);
                tab.g_tabs[idx] = null;
            }
            tab.g_tab_count -= 1;
        }
    }

    const session = AppWindow.activeSkillCenter() orelse return error.ExpectedSkillCenterTab;
    const name = try allocator.dupe(u8, "webread");
    var name_owned = true;
    errdefer if (name_owned) allocator.free(name);
    const description = try allocator.dupe(u8, "Read web pages.");
    var description_owned = true;
    errdefer if (description_owned) allocator.free(description);
    const entries = try allocator.alloc(AppWindow.skill_center.LibraryEntry, 1);
    var entries_owned = true;
    errdefer if (entries_owned) allocator.free(entries);
    entries[0] = .{ .first_party_tool = .{
        .name = name,
        .description = description,
        .enabled = true,
        .disableable = true,
    } };
    session.mutex.lock();
    session.model.setEntries(entries);
    entries_owned = false;
    name_owned = false;
    description_owned = false;
    session.mutex.unlock();

    AppWindow.g_force_rebuild = false;
    AppWindow.g_cells_valid = true;
    handleKey(.{ .key_code = 0x45, .ctrl = false, .shift = false, .alt = false, .super = false });

    try std.testing.expect(AppWindow.g_force_rebuild);
    try std.testing.expect(!AppWindow.g_cells_valid);

    const state = try tmp.dir.readFileAlloc(allocator, "agent_tools.json", 4096);
    defer allocator.free(state);
    try std.testing.expect(std.mem.indexOf(u8, state, "\"webread\"") != null);

    {
        session.mutex.lock();
        defer session.mutex.unlock();
        const entry = session.model.selectedEntry() orelse return error.ExpectedFirstPartyTool;
        switch (entry) {
            .first_party_tool => |tool| try std.testing.expect(!tool.enabled),
            else => return error.ExpectedFirstPartyTool,
        }
    }

    const settings = AppWindow.ai_chat.currentAgentSettings();
    try std.testing.expectEqual(@as(usize, 1), settings.disabled_first_party_tools.len);
    try std.testing.expectEqualStrings("webread", settings.disabled_first_party_tools[0]);

    try std.testing.expect(AppWindow.skillCenterToggleToolEnabled());
}

test "input: skill center tool toggle is blocked while selection overlay is active" {
    const allocator = std.testing.allocator;
    const previous_allocator = AppWindow.g_allocator;
    const previous_tabs = tab.g_tabs;
    const previous_count = tab.g_tab_count;
    const previous_active = active_tab_state.g_active_tab;
    const previous_force_rebuild = AppWindow.g_force_rebuild;
    const previous_cells_valid = AppWindow.g_cells_valid;
    defer {
        AppWindow.g_allocator = previous_allocator;
        tab.g_tabs = previous_tabs;
        tab.g_tab_count = previous_count;
        active_tab_state.g_active_tab = previous_active;
        AppWindow.g_force_rebuild = previous_force_rebuild;
        AppWindow.g_cells_valid = previous_cells_valid;
        platform_dirs.clearTestConfigDirForCurrentThread();
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("tools/fake_tool/bin");
    try tmp.dir.writeFile(.{ .sub_path = "tools/fake_tool/SKILL.md", .data = "---\nname: fake_tool\n---\n" });
    try tmp.dir.writeFile(.{ .sub_path = "tools/fake_tool/bin/fake_tool", .data = "" });
    const manifest =
        \\{
        \\  "kind": "binary_tool",
        \\  "id": "fake_tool",
        \\  "function_name": "fake_tool",
        \\  "enabled": true,
        \\  "executable": "bin/fake_tool",
        \\  "source_path": "/tmp/fake_tool",
        \\  "sha256": "abc123",
        \\  "imported_at_ms": 1,
        \\  "description": "fake"
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "tools/fake_tool/manifest.json", .data = manifest });
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    platform_dirs.setTestConfigDirForCurrentThread(root);

    AppWindow.g_allocator = allocator;
    tab.g_tabs = .{null} ** tab.MAX_TABS;
    tab.g_tab_count = 0;
    active_tab_state.g_active_tab = 0;
    if (!tab.spawnSkillCenterTab(allocator)) return error.SkipZigTest;
    defer {
        while (tab.g_tab_count > 0) {
            const idx = tab.g_tab_count - 1;
            if (tab.g_tabs[idx]) |t| {
                t.deinit(allocator);
                allocator.destroy(t);
                tab.g_tabs[idx] = null;
            }
            tab.g_tab_count -= 1;
        }
    }

    const session = AppWindow.activeSkillCenter() orelse return error.ExpectedSkillCenterTab;
    const executable_path = try std.fs.path.join(allocator, &.{ root, "tools", "fake_tool", "bin", "fake_tool" });
    var executable_path_owned = true;
    errdefer if (executable_path_owned) allocator.free(executable_path);
    const skill_path = try std.fs.path.join(allocator, &.{ root, "tools", "fake_tool", "SKILL.md" });
    var skill_path_owned = true;
    errdefer if (skill_path_owned) allocator.free(skill_path);
    const name = try allocator.dupe(u8, "fake_tool");
    var name_owned = true;
    errdefer if (name_owned) allocator.free(name);
    const entries = try allocator.alloc(AppWindow.skill_center.LibraryEntry, 1);
    var entries_owned = true;
    errdefer if (entries_owned) allocator.free(entries);
    entries[0] = .{ .tool = .{
        .name = name,
        .executable_path = executable_path,
        .skill_path = skill_path,
        .enabled = true,
    } };

    const picker_labels = try allocator.alloc([]u8, 1);
    var picker_labels_owned = true;
    errdefer if (picker_labels_owned) allocator.free(picker_labels);
    picker_labels[0] = try allocator.dupe(u8, "Local · Claude Code");
    var picker_label_0_owned = true;
    errdefer if (picker_label_0_owned) allocator.free(picker_labels[0]);
    const picker_targets = try allocator.alloc(AppWindow.skill_center.Target, 1);
    var picker_targets_owned = true;
    errdefer if (picker_targets_owned) allocator.free(picker_targets);
    picker_targets[0] = try AppWindow.skill_center.Target.dupe(allocator, "local", "Local", .claude, true);
    var picker_target_0_owned = true;
    errdefer if (picker_target_0_owned) picker_targets[0].deinit(allocator);
    const picker_skill_name = try allocator.dupe(u8, "prompt_skill");
    var picker_skill_name_owned = true;
    errdefer if (picker_skill_name_owned) allocator.free(picker_skill_name);

    session.mutex.lock();
    session.model.setEntries(entries);
    entries_owned = false;
    name_owned = false;
    executable_path_owned = false;
    skill_path_owned = false;
    session.model.setOverlay(.{ .picker = .{
        .purpose = .deploy,
        .skill_name = picker_skill_name,
        .labels = picker_labels,
        .targets = picker_targets,
        .sel = 0,
    } });
    picker_skill_name_owned = false;
    picker_labels_owned = false;
    picker_label_0_owned = false;
    picker_targets_owned = false;
    picker_target_0_owned = false;
    session.mutex.unlock();

    AppWindow.g_force_rebuild = false;
    AppWindow.g_cells_valid = true;
    handleKey(.{ .key_code = 0x45, .ctrl = false, .shift = false, .alt = false, .super = false });

    const persisted_manifest = try tmp.dir.readFileAlloc(allocator, "tools/fake_tool/manifest.json", 4096);
    defer allocator.free(persisted_manifest);
    try std.testing.expect(std.mem.indexOf(u8, persisted_manifest, "\"enabled\": true") != null);

    session.mutex.lock();
    defer session.mutex.unlock();
    const entry = session.model.selectedEntry() orelse return error.ExpectedSkillCenterTool;
    switch (entry) {
        .tool => |tool| try std.testing.expect(tool.enabled),
        else => return error.ExpectedSkillCenterTool,
    }
}

test "input: empty skill center library import shortcut opens picker" {
    const allocator = std.testing.allocator;
    const previous_allocator = AppWindow.g_allocator;
    const previous_tabs = tab.g_tabs;
    const previous_count = tab.g_tab_count;
    const previous_active = active_tab_state.g_active_tab;
    const previous_force_rebuild = AppWindow.g_force_rebuild;
    const previous_cells_valid = AppWindow.g_cells_valid;
    defer {
        AppWindow.g_allocator = previous_allocator;
        tab.g_tabs = previous_tabs;
        tab.g_tab_count = previous_count;
        active_tab_state.g_active_tab = previous_active;
        AppWindow.g_force_rebuild = previous_force_rebuild;
        AppWindow.g_cells_valid = previous_cells_valid;
    }

    AppWindow.g_allocator = allocator;
    tab.g_tabs = .{null} ** tab.MAX_TABS;
    tab.g_tab_count = 0;
    active_tab_state.g_active_tab = 0;
    if (!tab.spawnSkillCenterTab(allocator)) return error.SkipZigTest;
    defer {
        while (tab.g_tab_count > 0) {
            const idx = tab.g_tab_count - 1;
            if (tab.g_tabs[idx]) |t| {
                t.deinit(allocator);
                allocator.destroy(t);
                tab.g_tabs[idx] = null;
            }
            tab.g_tab_count -= 1;
        }
    }

    const session = AppWindow.activeSkillCenter() orelse return error.ExpectedSkillCenterTab;

    AppWindow.g_force_rebuild = false;
    AppWindow.g_cells_valid = true;
    handleKey(.{ .key_code = 0x49, .ctrl = false, .shift = false, .alt = false, .super = false });

    try std.testing.expect(AppWindow.g_force_rebuild);
    try std.testing.expect(!AppWindow.g_cells_valid);
    session.mutex.lock();
    defer session.mutex.unlock();
    switch (session.model.overlay) {
        .picker => |picker| {
            try std.testing.expectEqual(AppWindow.skill_center.Purpose.import_, picker.purpose);
            try std.testing.expectEqualStrings("", picker.skill_name);
        },
        else => return error.ExpectedSkillCenterPicker,
    }
}

test "input: skill center deploy and import keys ignore selected tool rows" {
    const allocator = std.testing.allocator;
    const previous_allocator = AppWindow.g_allocator;
    const previous_tabs = tab.g_tabs;
    const previous_count = tab.g_tab_count;
    const previous_active = active_tab_state.g_active_tab;
    const previous_force_rebuild = AppWindow.g_force_rebuild;
    const previous_cells_valid = AppWindow.g_cells_valid;
    defer {
        AppWindow.g_allocator = previous_allocator;
        tab.g_tabs = previous_tabs;
        tab.g_tab_count = previous_count;
        active_tab_state.g_active_tab = previous_active;
        AppWindow.g_force_rebuild = previous_force_rebuild;
        AppWindow.g_cells_valid = previous_cells_valid;
    }

    AppWindow.g_allocator = allocator;
    tab.g_tabs = .{null} ** tab.MAX_TABS;
    tab.g_tab_count = 0;
    active_tab_state.g_active_tab = 0;
    if (!tab.spawnSkillCenterTab(allocator)) return error.SkipZigTest;
    defer {
        while (tab.g_tab_count > 0) {
            const idx = tab.g_tab_count - 1;
            if (tab.g_tabs[idx]) |t| {
                t.deinit(allocator);
                allocator.destroy(t);
                tab.g_tabs[idx] = null;
            }
            tab.g_tab_count -= 1;
        }
    }

    const session = AppWindow.activeSkillCenter() orelse return error.ExpectedSkillCenterTab;
    const name = try allocator.dupe(u8, "fake_tool");
    var name_owned = true;
    errdefer if (name_owned) allocator.free(name);
    const executable_path = try allocator.dupe(u8, "/tmp/tools/fake_tool/bin/fake_tool");
    var executable_path_owned = true;
    errdefer if (executable_path_owned) allocator.free(executable_path);
    const skill_path = try allocator.dupe(u8, "/tmp/tools/fake_tool/SKILL.md");
    var skill_path_owned = true;
    errdefer if (skill_path_owned) allocator.free(skill_path);
    const entries = try allocator.alloc(AppWindow.skill_center.LibraryEntry, 1);
    var entries_owned = true;
    errdefer if (entries_owned) allocator.free(entries);
    entries[0] = .{ .tool = .{
        .name = name,
        .executable_path = executable_path,
        .skill_path = skill_path,
        .enabled = false,
    } };

    session.mutex.lock();
    session.model.setEntries(entries);
    entries_owned = false;
    name_owned = false;
    executable_path_owned = false;
    skill_path_owned = false;
    session.mutex.unlock();

    AppWindow.g_force_rebuild = false;
    AppWindow.g_cells_valid = true;
    handleKey(.{ .key_code = 0x44, .ctrl = false, .shift = false, .alt = false, .super = false });
    try std.testing.expect(!AppWindow.g_force_rebuild);
    try std.testing.expect(AppWindow.g_cells_valid);
    try std.testing.expect(!AppWindow.skillCenterOverlayActive());

    AppWindow.g_force_rebuild = false;
    AppWindow.g_cells_valid = true;
    handleKey(.{ .key_code = 0x49, .ctrl = false, .shift = false, .alt = false, .super = false });
    try std.testing.expect(!AppWindow.g_force_rebuild);
    try std.testing.expect(AppWindow.g_cells_valid);
    try std.testing.expect(!AppWindow.skillCenterOverlayActive());

    AppWindow.g_force_rebuild = false;
    AppWindow.g_cells_valid = true;
    handleKey(.{ .key_code = platform_input.key_enter, .ctrl = false, .shift = false, .alt = false, .super = false });
    try std.testing.expect(!AppWindow.g_force_rebuild);
    try std.testing.expect(AppWindow.g_cells_valid);
    try std.testing.expect(!AppWindow.skillCenterOverlayActive());
}

test "input: skill center tool import shortcut is a no-op when no file is selected" {
    const allocator = std.testing.allocator;
    const previous_allocator = AppWindow.g_allocator;
    const previous_open_file = AppWindow.g_skill_center_open_file_override;
    const previous_tabs = tab.g_tabs;
    const previous_count = tab.g_tab_count;
    const previous_active = active_tab_state.g_active_tab;
    const previous_force_rebuild = AppWindow.g_force_rebuild;
    const previous_cells_valid = AppWindow.g_cells_valid;
    defer {
        AppWindow.g_allocator = previous_allocator;
        AppWindow.g_skill_center_open_file_override = previous_open_file;
        tab.g_tabs = previous_tabs;
        tab.g_tab_count = previous_count;
        active_tab_state.g_active_tab = previous_active;
        AppWindow.g_force_rebuild = previous_force_rebuild;
        AppWindow.g_cells_valid = previous_cells_valid;
    }

    AppWindow.g_allocator = allocator;
    tab.g_tabs = .{null} ** tab.MAX_TABS;
    tab.g_tab_count = 0;
    active_tab_state.g_active_tab = 0;
    if (!tab.spawnSkillCenterTab(allocator)) return error.SkipZigTest;
    defer {
        while (tab.g_tab_count > 0) {
            const idx = tab.g_tab_count - 1;
            if (tab.g_tabs[idx]) |t| {
                t.deinit(allocator);
                allocator.destroy(t);
                tab.g_tabs[idx] = null;
            }
            tab.g_tab_count -= 1;
        }
    }

    const session = AppWindow.activeSkillCenter() orelse return error.ExpectedSkillCenterTab;
    AppWindow.g_skill_center_open_file_override = struct {
        fn open(_: std.mem.Allocator, _: platform_file_dialog.OpenRequest) ?[]u8 {
            return null;
        }
    }.open;

    AppWindow.g_force_rebuild = false;
    AppWindow.g_cells_valid = true;
    handleKey(.{ .key_code = 0x54, .ctrl = false, .shift = false, .alt = false, .super = false });

    try std.testing.expect(!AppWindow.g_force_rebuild);
    try std.testing.expect(AppWindow.g_cells_valid);
    session.mutex.lock();
    defer session.mutex.unlock();
    try std.testing.expectEqualStrings("", session.status);
}

test "input: skill center tool import preview keys import-scroll-cancel while text preview still closes on Enter" {
    const allocator = std.testing.allocator;
    const previous_allocator = AppWindow.g_allocator;
    const previous_tabs = tab.g_tabs;
    const previous_count = tab.g_tab_count;
    const previous_active = active_tab_state.g_active_tab;
    const previous_force_rebuild = AppWindow.g_force_rebuild;
    const previous_cells_valid = AppWindow.g_cells_valid;
    defer {
        AppWindow.g_allocator = previous_allocator;
        tab.g_tabs = previous_tabs;
        tab.g_tab_count = previous_count;
        active_tab_state.g_active_tab = previous_active;
        AppWindow.g_force_rebuild = previous_force_rebuild;
        AppWindow.g_cells_valid = previous_cells_valid;
        platform_dirs.clearTestConfigDirForCurrentThread();
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("tools/docx");
    try tmp.dir.makePath("tools/.import-stage-docx/bin");
    try tmp.dir.makePath("source");
    try tmp.dir.writeFile(.{ .sub_path = "tools/.import-stage-docx/bin/docx", .data = "staged bytes" });
    try tmp.dir.writeFile(.{ .sub_path = "source/docx", .data = "original bytes" });
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    platform_dirs.setTestConfigDirForCurrentThread(root);
    const staged_path = try tmp.dir.realpathAlloc(allocator, "tools/.import-stage-docx/bin/docx");
    defer allocator.free(staged_path);
    const stage_root = try tmp.dir.realpathAlloc(allocator, "tools/.import-stage-docx");
    defer allocator.free(stage_root);
    const source_path = try tmp.dir.realpathAlloc(allocator, "source/docx");
    defer allocator.free(source_path);

    AppWindow.g_allocator = allocator;
    tab.g_tabs = .{null} ** tab.MAX_TABS;
    tab.g_tab_count = 0;
    active_tab_state.g_active_tab = 0;
    if (!tab.spawnSkillCenterTab(allocator)) return error.SkipZigTest;
    defer {
        while (tab.g_tab_count > 0) {
            const idx = tab.g_tab_count - 1;
            if (tab.g_tabs[idx]) |t| {
                t.deinit(allocator);
                allocator.destroy(t);
                tab.g_tabs[idx] = null;
            }
            tab.g_tab_count -= 1;
        }
    }

    const session = AppWindow.activeSkillCenter() orelse return error.ExpectedSkillCenterTab;
    session.mutex.lock();
    try session.model.openToolImportPreview(.{
        .tool_id = "docx",
        .function_name = "docx",
        .source_path = source_path,
        .staged_binary_path = staged_path,
        .skill_md = "---\nname: docx\n---\nUse docs.\n",
        .doc_source = .skill_flag,
        .ai_review_required = false,
    });
    session.mutex.unlock();

    AppWindow.g_force_rebuild = false;
    AppWindow.g_cells_valid = true;
    handleKey(.{ .key_code = platform_input.key_down, .ctrl = false, .shift = false, .alt = false, .super = false });
    try std.testing.expect(AppWindow.g_force_rebuild);
    try std.testing.expect(!AppWindow.g_cells_valid);
    session.mutex.lock();
    try std.testing.expectEqual(@as(usize, 1), session.model.overlay.tool_import_preview.scroll);
    session.mutex.unlock();

    AppWindow.g_force_rebuild = false;
    AppWindow.g_cells_valid = true;
    handleKey(.{ .key_code = platform_input.key_enter, .ctrl = false, .shift = false, .alt = false, .super = false });
    try std.testing.expect(AppWindow.g_force_rebuild);
    try std.testing.expect(!AppWindow.g_cells_valid);
    session.mutex.lock();
    try std.testing.expect(session.model.overlay == .tool_import_preview);
    try std.testing.expect(std.mem.indexOf(u8, session.status, "Tool import failed:") != null);
    session.mutex.unlock();
    try std.fs.accessAbsolute(stage_root, .{});

    AppWindow.g_force_rebuild = false;
    AppWindow.g_cells_valid = true;
    handleKey(.{ .key_code = platform_input.key_escape, .ctrl = false, .shift = false, .alt = false, .super = false });
    try std.testing.expect(AppWindow.g_force_rebuild);
    try std.testing.expect(!AppWindow.g_cells_valid);
    session.mutex.lock();
    try std.testing.expect(session.model.overlay == .none);
    session.mutex.unlock();
    try std.testing.expectError(error.FileNotFound, std.fs.accessAbsolute(stage_root, .{}));

    session.mutex.lock();
    try session.model.openTextPreview("docx / SKILL.md", "preview");
    session.mutex.unlock();
    AppWindow.g_force_rebuild = false;
    AppWindow.g_cells_valid = true;
    handleKey(.{ .key_code = platform_input.key_enter, .ctrl = false, .shift = false, .alt = false, .super = false });
    try std.testing.expect(AppWindow.g_force_rebuild);
    try std.testing.expect(!AppWindow.g_cells_valid);
    session.mutex.lock();
    defer session.mutex.unlock();
    try std.testing.expect(session.model.overlay == .none);
}

test "input: skill center deploy and import keys are blocked while picker overlay is active" {
    const allocator = std.testing.allocator;
    const previous_allocator = AppWindow.g_allocator;
    const previous_tabs = tab.g_tabs;
    const previous_count = tab.g_tab_count;
    const previous_active = active_tab_state.g_active_tab;
    const previous_force_rebuild = AppWindow.g_force_rebuild;
    const previous_cells_valid = AppWindow.g_cells_valid;
    defer {
        AppWindow.g_allocator = previous_allocator;
        tab.g_tabs = previous_tabs;
        tab.g_tab_count = previous_count;
        active_tab_state.g_active_tab = previous_active;
        AppWindow.g_force_rebuild = previous_force_rebuild;
        AppWindow.g_cells_valid = previous_cells_valid;
    }

    AppWindow.g_allocator = allocator;
    tab.g_tabs = .{null} ** tab.MAX_TABS;
    tab.g_tab_count = 0;
    active_tab_state.g_active_tab = 0;
    if (!tab.spawnSkillCenterTab(allocator)) return error.SkipZigTest;
    defer {
        while (tab.g_tab_count > 0) {
            const idx = tab.g_tab_count - 1;
            if (tab.g_tabs[idx]) |t| {
                t.deinit(allocator);
                allocator.destroy(t);
                tab.g_tabs[idx] = null;
            }
            tab.g_tab_count -= 1;
        }
    }

    const session = AppWindow.activeSkillCenter() orelse return error.ExpectedSkillCenterTab;
    const name = try allocator.dupe(u8, "main_prompt");
    var name_owned = true;
    errdefer if (name_owned) allocator.free(name);
    const rel_path = try allocator.dupe(u8, "main_prompt/SKILL.md");
    var rel_path_owned = true;
    errdefer if (rel_path_owned) allocator.free(rel_path);
    const entries = try allocator.alloc(AppWindow.skill_center.LibraryEntry, 1);
    var entries_owned = true;
    errdefer if (entries_owned) allocator.free(entries);
    entries[0] = .{ .prompt = .{
        .name = name,
        .rel_path = rel_path,
        .agg_hash = null,
    } };

    const picker_labels = try allocator.alloc([]u8, 1);
    var picker_labels_owned = true;
    errdefer if (picker_labels_owned) allocator.free(picker_labels);
    picker_labels[0] = try allocator.dupe(u8, "Local · Claude Code");
    var picker_label_0_owned = true;
    errdefer if (picker_label_0_owned) allocator.free(picker_labels[0]);
    const picker_targets = try allocator.alloc(AppWindow.skill_center.Target, 1);
    var picker_targets_owned = true;
    errdefer if (picker_targets_owned) allocator.free(picker_targets);
    picker_targets[0] = try AppWindow.skill_center.Target.dupe(allocator, "local", "Local", .claude, true);
    var picker_target_0_owned = true;
    errdefer if (picker_target_0_owned) picker_targets[0].deinit(allocator);
    const overlay_skill_name = try allocator.dupe(u8, "overlay_prompt");
    var overlay_skill_name_owned = true;
    errdefer if (overlay_skill_name_owned) allocator.free(overlay_skill_name);

    session.mutex.lock();
    session.model.setEntries(entries);
    entries_owned = false;
    name_owned = false;
    rel_path_owned = false;
    session.model.setOverlay(.{ .picker = .{
        .purpose = .deploy,
        .skill_name = overlay_skill_name,
        .labels = picker_labels,
        .targets = picker_targets,
        .sel = 0,
    } });
    overlay_skill_name_owned = false;
    picker_labels_owned = false;
    picker_label_0_owned = false;
    picker_targets_owned = false;
    picker_target_0_owned = false;
    session.mutex.unlock();

    AppWindow.g_force_rebuild = false;
    AppWindow.g_cells_valid = true;
    handleKey(.{ .key_code = 0x44, .ctrl = false, .shift = false, .alt = false, .super = false });
    try std.testing.expect(!AppWindow.g_force_rebuild);
    try std.testing.expect(AppWindow.g_cells_valid);
    {
        session.mutex.lock();
        defer session.mutex.unlock();
        switch (session.model.overlay) {
            .picker => |picker| try std.testing.expectEqualStrings("overlay_prompt", picker.skill_name),
            else => return error.ExpectedSkillCenterPicker,
        }
    }

    AppWindow.g_force_rebuild = false;
    AppWindow.g_cells_valid = true;
    handleKey(.{ .key_code = 0x49, .ctrl = false, .shift = false, .alt = false, .super = false });
    try std.testing.expect(!AppWindow.g_force_rebuild);
    try std.testing.expect(AppWindow.g_cells_valid);
    {
        session.mutex.lock();
        defer session.mutex.unlock();
        switch (session.model.overlay) {
            .picker => |picker| try std.testing.expectEqualStrings("overlay_prompt", picker.skill_name),
            else => return error.ExpectedSkillCenterPicker,
        }
    }
}

test "input: skill center main actions are blocked while import list overlay is active" {
    const allocator = std.testing.allocator;
    const previous_allocator = AppWindow.g_allocator;
    const previous_tabs = tab.g_tabs;
    const previous_count = tab.g_tab_count;
    const previous_active = active_tab_state.g_active_tab;
    const previous_force_rebuild = AppWindow.g_force_rebuild;
    const previous_cells_valid = AppWindow.g_cells_valid;
    defer {
        AppWindow.g_allocator = previous_allocator;
        tab.g_tabs = previous_tabs;
        tab.g_tab_count = previous_count;
        active_tab_state.g_active_tab = previous_active;
        AppWindow.g_force_rebuild = previous_force_rebuild;
        AppWindow.g_cells_valid = previous_cells_valid;
        platform_dirs.clearTestConfigDirForCurrentThread();
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("tools/fake_tool/bin");
    try tmp.dir.writeFile(.{ .sub_path = "tools/fake_tool/SKILL.md", .data = "---\nname: fake_tool\n---\n" });
    try tmp.dir.writeFile(.{ .sub_path = "tools/fake_tool/bin/fake_tool", .data = "" });
    const manifest =
        \\{
        \\  "kind": "binary_tool",
        \\  "id": "fake_tool",
        \\  "function_name": "fake_tool",
        \\  "enabled": true,
        \\  "executable": "bin/fake_tool",
        \\  "source_path": "/tmp/fake_tool",
        \\  "sha256": "abc123",
        \\  "imported_at_ms": 1,
        \\  "description": "fake"
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "tools/fake_tool/manifest.json", .data = manifest });
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    platform_dirs.setTestConfigDirForCurrentThread(root);

    AppWindow.g_allocator = allocator;
    tab.g_tabs = .{null} ** tab.MAX_TABS;
    tab.g_tab_count = 0;
    active_tab_state.g_active_tab = 0;
    if (!tab.spawnSkillCenterTab(allocator)) return error.SkipZigTest;
    defer {
        while (tab.g_tab_count > 0) {
            const idx = tab.g_tab_count - 1;
            if (tab.g_tabs[idx]) |t| {
                t.deinit(allocator);
                allocator.destroy(t);
                tab.g_tabs[idx] = null;
            }
            tab.g_tab_count -= 1;
        }
    }

    const session = AppWindow.activeSkillCenter() orelse return error.ExpectedSkillCenterTab;
    const prompt_name = try allocator.dupe(u8, "main_prompt");
    var prompt_name_owned = true;
    errdefer if (prompt_name_owned) allocator.free(prompt_name);
    const prompt_rel_path = try allocator.dupe(u8, "main_prompt/SKILL.md");
    var prompt_rel_path_owned = true;
    errdefer if (prompt_rel_path_owned) allocator.free(prompt_rel_path);
    const executable_path = try std.fs.path.join(allocator, &.{ root, "tools", "fake_tool", "bin", "fake_tool" });
    var executable_path_owned = true;
    errdefer if (executable_path_owned) allocator.free(executable_path);
    const skill_path = try std.fs.path.join(allocator, &.{ root, "tools", "fake_tool", "SKILL.md" });
    var skill_path_owned = true;
    errdefer if (skill_path_owned) allocator.free(skill_path);
    const name = try allocator.dupe(u8, "fake_tool");
    var name_owned = true;
    errdefer if (name_owned) allocator.free(name);
    const entries = try allocator.alloc(AppWindow.skill_center.LibraryEntry, 2);
    var entries_owned = true;
    errdefer if (entries_owned) allocator.free(entries);
    entries[0] = .{ .prompt = .{
        .name = prompt_name,
        .rel_path = prompt_rel_path,
        .agg_hash = null,
    } };
    entries[1] = .{ .tool = .{
        .name = name,
        .executable_path = executable_path,
        .skill_path = skill_path,
        .enabled = true,
    } };

    var import_target = try AppWindow.skill_center.Target.dupe(allocator, "local", "Local", .claude, true);
    var import_target_owned = true;
    errdefer if (import_target_owned) import_target.deinit(allocator);
    const import_names = try allocator.alloc([]u8, 1);
    var import_names_owned = true;
    errdefer if (import_names_owned) allocator.free(import_names);
    import_names[0] = try allocator.dupe(u8, "remote_prompt");
    var import_name_0_owned = true;
    errdefer if (import_name_0_owned) allocator.free(import_names[0]);
    const import_markers = try allocator.alloc(AppWindow.skill_center.Marker, 1);
    var import_markers_owned = true;
    errdefer if (import_markers_owned) allocator.free(import_markers);
    import_markers[0] = .new_;

    session.mutex.lock();
    session.model.setEntries(entries);
    entries_owned = false;
    prompt_name_owned = false;
    prompt_rel_path_owned = false;
    name_owned = false;
    executable_path_owned = false;
    skill_path_owned = false;
    session.model.setOverlay(.{ .import_list = .{
        .target = import_target,
        .names = import_names,
        .markers = import_markers,
        .sel = 0,
    } });
    import_target_owned = false;
    import_names_owned = false;
    import_name_0_owned = false;
    import_markers_owned = false;
    session.mutex.unlock();

    AppWindow.g_force_rebuild = false;
    AppWindow.g_cells_valid = true;
    handleKey(.{ .key_code = 0x44, .ctrl = false, .shift = false, .alt = false, .super = false });
    try std.testing.expect(!AppWindow.g_force_rebuild);
    try std.testing.expect(AppWindow.g_cells_valid);
    {
        session.mutex.lock();
        defer session.mutex.unlock();
        switch (session.model.overlay) {
            .import_list => |import_list| try std.testing.expectEqualStrings("remote_prompt", import_list.names[0]),
            else => return error.ExpectedSkillCenterImportList,
        }
    }

    AppWindow.g_force_rebuild = false;
    AppWindow.g_cells_valid = true;
    handleKey(.{ .key_code = 0x49, .ctrl = false, .shift = false, .alt = false, .super = false });
    try std.testing.expect(!AppWindow.g_force_rebuild);
    try std.testing.expect(AppWindow.g_cells_valid);
    {
        session.mutex.lock();
        defer session.mutex.unlock();
        switch (session.model.overlay) {
            .import_list => |import_list| try std.testing.expectEqualStrings("remote_prompt", import_list.names[0]),
            else => return error.ExpectedSkillCenterImportList,
        }
        session.model.sel_row = 1;
    }

    AppWindow.g_force_rebuild = false;
    AppWindow.g_cells_valid = true;
    handleKey(.{ .key_code = 0x54, .ctrl = false, .shift = false, .alt = false, .super = false });
    try std.testing.expect(!AppWindow.g_force_rebuild);
    try std.testing.expect(AppWindow.g_cells_valid);
    {
        session.mutex.lock();
        defer session.mutex.unlock();
        try std.testing.expectEqualStrings("", session.status);
        switch (session.model.overlay) {
            .import_list => |import_list| {
                try std.testing.expectEqual(@as(usize, 1), import_list.names.len);
                try std.testing.expectEqualStrings("remote_prompt", import_list.names[0]);
            },
            else => return error.ExpectedSkillCenterImportList,
        }
    }

    AppWindow.g_force_rebuild = false;
    AppWindow.g_cells_valid = true;
    handleKey(.{ .key_code = 0x45, .ctrl = false, .shift = false, .alt = false, .super = false });
    try std.testing.expect(!AppWindow.g_force_rebuild);
    try std.testing.expect(AppWindow.g_cells_valid);
    const persisted_manifest = try tmp.dir.readFileAlloc(allocator, "tools/fake_tool/manifest.json", 4096);
    defer allocator.free(persisted_manifest);
    try std.testing.expect(std.mem.indexOf(u8, persisted_manifest, "\"enabled\": true") != null);
    {
        session.mutex.lock();
        defer session.mutex.unlock();
        switch (session.model.overlay) {
            .import_list => |import_list| try std.testing.expectEqualStrings("remote_prompt", import_list.names[0]),
            else => return error.ExpectedSkillCenterImportList,
        }
    }
}

test "input: terminal viewport mouse wheel scroll requests a repaint" {
    const allocator = std.testing.allocator;
    const ghostty_vt = @import("ghostty-vt");
    const renderer = @import("renderer.zig");

    const previous_tabs = tab.g_tabs;
    const previous_count = tab.g_tab_count;
    const previous_active = active_tab_state.g_active_tab;
    const previous_sidebar = tab.g_sidebar_visible;
    const previous_split_rect_count = split_layout.g_split_rect_count;
    const previous_file_visible = file_explorer.g_visible;
    const previous_file_owner = file_explorer.g_owner_tab;
    const previous_browser_visible = browser_panel.g_visible;
    const previous_browser_owner = browser_panel.g_owner_tab;
    const previous_selecting = g_selecting;
    const previous_whats_new_visible = overlays.whatsNewVisible();
    defer {
        tab.g_tabs = previous_tabs;
        tab.g_tab_count = previous_count;
        active_tab_state.g_active_tab = previous_active;
        tab.g_sidebar_visible = previous_sidebar;
        split_layout.g_split_rect_count = previous_split_rect_count;
        file_explorer.g_visible = previous_file_visible;
        file_explorer.g_owner_tab = previous_file_owner;
        browser_panel.g_visible = previous_browser_visible;
        browser_panel.g_owner_tab = previous_browser_owner;
        g_selecting = previous_selecting;
        if (previous_whats_new_visible) overlays.showWhatsNew() else overlays.hideWhatsNew();
    }

    var surface: Surface = undefined;
    surface.terminal = try ghostty_vt.Terminal.init(allocator, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback = 1024,
        .default_modes = .{ .grapheme_cluster = true },
    });
    defer surface.terminal.deinit(allocator);
    surface.render_state = renderer.State.init(&surface.terminal);
    surface.selection = .{};
    surface.ref_count = 1;
    surface.scrollbar_opacity = 0;
    surface.scrollbar_show_time = 0;

    var tab_state = tab.TabState{
        .kind = .terminal,
        .tree = try SplitTree.init(allocator, &surface),
        .focused = .root,
        .ai_chat_session = null,
        .ai_history_session = null,
        .skill_center_session = null,
        .port_forwarding_session = null,
        .copilot_session = null,
        .copilot_visible = false,
    };
    defer tab_state.tree.deinit();

    tab.g_tabs = .{null} ** tab.MAX_TABS;
    tab.g_tabs[0] = &tab_state;
    tab.g_tab_count = 1;
    active_tab_state.g_active_tab = 0;
    tab.g_sidebar_visible = false;
    split_layout.g_split_rect_count = 0;
    file_explorer.g_visible = false;
    browser_panel.g_visible = false;
    g_selecting = false;
    overlays.hideWhatsNew();

    AppWindow.g_force_rebuild = false;
    AppWindow.g_cells_valid = true;

    handleMouseWheel(.{ .delta = 120, .xpos = 20, .ypos = 40 });

    try std.testing.expect(AppWindow.g_force_rebuild);
    try std.testing.expect(!AppWindow.g_cells_valid);
}

test "input: file explorer mouse wheel scroll requests a repaint" {
    // Regression: scrolling the file explorer sidebar (Ctrl+Shift+Alt+E) only
    // mutated the scroll offset without requesting a frame, so the panel did not
    // redraw until the next cursor-blink tick (~600ms) — visibly stuttery scroll.
    // The wheel handler must set g_force_rebuild so the new position is drawn now.
    const previous_visible = file_explorer.g_visible;
    const previous_owner = file_explorer.g_owner_tab;
    const previous_mode = file_explorer.g_panel_mode;
    const previous_entry_count = file_explorer.g_entry_count;
    const previous_visible_height = file_explorer.g_visible_height;
    const previous_scroll = file_explorer.g_scroll_offset;
    const previous_row_height = file_explorer.g_row_height;
    const previous_panel_width = file_explorer.g_width;
    const previous_sidebar = tab.g_sidebar_visible;
    const previous_browser_visible = browser_panel.g_visible;
    const previous_whats_new_visible = overlays.whatsNewVisible();
    defer {
        file_explorer.g_visible = previous_visible;
        file_explorer.g_owner_tab = previous_owner;
        file_explorer.g_panel_mode = previous_mode;
        file_explorer.g_entry_count = previous_entry_count;
        file_explorer.g_visible_height = previous_visible_height;
        file_explorer.g_scroll_offset = previous_scroll;
        file_explorer.g_row_height = previous_row_height;
        file_explorer.g_width = previous_panel_width;
        tab.g_sidebar_visible = previous_sidebar;
        browser_panel.g_visible = previous_browser_visible;
        if (previous_whats_new_visible) overlays.showWhatsNew() else overlays.hideWhatsNew();
    }

    tab.g_sidebar_visible = false;
    browser_panel.g_visible = false;
    overlays.hideWhatsNew();

    // Make the explorer visible for the active tab with a scrollable list.
    file_explorer.g_visible = true;
    file_explorer.g_owner_tab = active_tab_state.g_active_tab;
    file_explorer.g_panel_mode = .files;
    file_explorer.g_width = 240;
    file_explorer.g_row_height = 20;
    file_explorer.g_visible_height = 100;
    file_explorer.g_entry_count = 100; // total 2000px >> visible 100px → scrollable
    file_explorer.g_scroll_offset = 0;

    AppWindow.g_force_rebuild = false;
    AppWindow.g_cells_valid = true;

    // Wheel "down" inside the panel (negative delta scrolls toward the bottom).
    handleMouseWheel(.{ .delta = -120, .xpos = 20, .ypos = 200 });

    // The fix: a frame is requested for the new scroll position.
    try std.testing.expect(AppWindow.g_force_rebuild);
    // The offset actually advanced, proving we took the explorer branch (the
    // terminal fallback would also set g_force_rebuild, so assert the side effect
    // unique to this branch).
    try std.testing.expect(file_explorer.g_scroll_offset > 0);
    // The explorer draws above the terminal cell grid, so scrolling it must not
    // invalidate the cells — that would force an unnecessary grid rebuild.
    try std.testing.expect(AppWindow.g_cells_valid);
}

test "input: file explorer keyboard navigation requests a repaint" {
    // Same regression as the wheel path: arrow-key navigation in the focused
    // explorer moved the selection without requesting a frame, so the highlight
    // did not update until the next cursor-blink tick (~600ms).
    const previous_visible = file_explorer.g_visible;
    const previous_owner = file_explorer.g_owner_tab;
    const previous_focused = file_explorer.g_focused;
    const previous_mode = file_explorer.g_panel_mode;
    const previous_op_mode = file_explorer.g_op_mode;
    const previous_entry_count = file_explorer.g_entry_count;
    const previous_selected = file_explorer.g_selected;
    const previous_whats_new_visible = overlays.whatsNewVisible();
    defer {
        file_explorer.g_visible = previous_visible;
        file_explorer.g_owner_tab = previous_owner;
        file_explorer.g_focused = previous_focused;
        file_explorer.g_panel_mode = previous_mode;
        file_explorer.g_op_mode = previous_op_mode;
        file_explorer.g_entry_count = previous_entry_count;
        file_explorer.g_selected = previous_selected;
        if (previous_whats_new_visible) overlays.showWhatsNew() else overlays.hideWhatsNew();
    }

    overlays.hideWhatsNew();
    file_explorer.g_visible = true;
    file_explorer.g_owner_tab = active_tab_state.g_active_tab;
    file_explorer.g_focused = true;
    file_explorer.g_panel_mode = .files;
    file_explorer.g_op_mode = .none;
    file_explorer.g_entry_count = 10;
    file_explorer.g_selected = 0;

    AppWindow.g_force_rebuild = false;

    // Bare Down arrow advances the selection (no modifier → not a keybind).
    handleKey(.{ .key_code = platform_input.key_down, .ctrl = false, .shift = false, .alt = false, .super = false });

    // The fix: a frame is requested so the moved highlight is drawn now.
    try std.testing.expect(AppWindow.g_force_rebuild);
    // Selection advanced, proving the explorer key branch consumed the event.
    try std.testing.expectEqual(@as(?usize, 1), file_explorer.g_selected);
}

test "input: port forwarding form left/right arrows toggle Direction and request a repaint" {
    const allocator = std.testing.allocator;
    AppWindow.setSshHostsContentForTest("");
    defer AppWindow.setSshHostsContentForTest(null);
    const previous_count = tab.g_tab_count;
    const previous_active = active_tab_state.g_active_tab;
    if (!tab.spawnPortForwardingTab(allocator)) return error.SkipZigTest;
    defer {
        while (tab.g_tab_count > previous_count) {
            const idx = tab.g_tab_count - 1;
            if (tab.g_tabs[idx]) |t| {
                t.deinit(allocator);
                allocator.destroy(t);
                tab.g_tabs[idx] = null;
            }
            tab.g_tab_count -= 1;
        }
        active_tab_state.g_active_tab = previous_active;
    }

    try std.testing.expect(AppWindow.portForwardingOpenNew());
    handleKey(arrow_down_event); // Name -> Profile
    handleKey(arrow_down_event); // Profile -> Direction

    AppWindow.g_force_rebuild = false;
    AppWindow.g_cells_valid = true;
    handleKey(arrow_right_event);

    try std.testing.expect(AppWindow.g_force_rebuild);
    try std.testing.expect(!AppWindow.g_cells_valid);
    {
        const session = AppWindow.activePortForwarding() orelse return error.ExpectedPortForwardingTab;
        session.mutex.lock();
        defer session.mutex.unlock();
        const form = session.model.form() orelse return error.ExpectedPortForwardingForm;
        try std.testing.expect(form.rule.direction == .local);
    }

    AppWindow.g_force_rebuild = false;
    AppWindow.g_cells_valid = true;
    handleKey(arrow_left_event);

    try std.testing.expect(AppWindow.g_force_rebuild);
    try std.testing.expect(!AppWindow.g_cells_valid);
    const session = AppWindow.activePortForwarding() orelse return error.ExpectedPortForwardingTab;
    session.mutex.lock();
    defer session.mutex.unlock();
    const form = session.model.form() orelse return error.ExpectedPortForwardingForm;
    try std.testing.expect(form.rule.direction == .reverse);
}

test "input: port forwarding form letter keys remain text input" {
    const allocator = std.testing.allocator;
    AppWindow.setSshHostsContentForTest("");
    defer AppWindow.setSshHostsContentForTest(null);
    const previous_count = tab.g_tab_count;
    const previous_active = active_tab_state.g_active_tab;
    if (!tab.spawnPortForwardingTab(allocator)) return error.SkipZigTest;
    defer {
        while (tab.g_tab_count > previous_count) {
            const idx = tab.g_tab_count - 1;
            if (tab.g_tabs[idx]) |t| {
                t.deinit(allocator);
                allocator.destroy(t);
                tab.g_tabs[idx] = null;
            }
            tab.g_tab_count -= 1;
        }
        active_tab_state.g_active_tab = previous_active;
    }

    try std.testing.expect(AppWindow.portForwardingOpenNew());
    handleChar(.{ .codepoint = 'P' });
    handleKey(.{ .key_code = 0x4E, .ctrl = false, .shift = false, .alt = false });
    handleChar(.{ .codepoint = 'n' });

    const session = AppWindow.activePortForwarding() orelse return error.ExpectedPortForwardingTab;
    session.mutex.lock();
    defer session.mutex.unlock();
    const form = session.model.form() orelse return error.ExpectedPortForwardingForm;
    try std.testing.expectEqualStrings("Local proxyPn", form.rule.name());
}

test "input: port forwarding new command suppresses its follow-up char event" {
    const allocator = std.testing.allocator;
    AppWindow.setSshHostsContentForTest("");
    defer AppWindow.setSshHostsContentForTest(null);
    const previous_count = tab.g_tab_count;
    const previous_active = active_tab_state.g_active_tab;
    if (!tab.spawnPortForwardingTab(allocator)) return error.SkipZigTest;
    defer {
        while (tab.g_tab_count > previous_count) {
            const idx = tab.g_tab_count - 1;
            if (tab.g_tabs[idx]) |t| {
                t.deinit(allocator);
                allocator.destroy(t);
                tab.g_tabs[idx] = null;
            }
            tab.g_tab_count -= 1;
        }
        active_tab_state.g_active_tab = previous_active;
    }

    handleKey(.{ .key_code = 0x4E, .ctrl = false, .shift = false, .alt = false });
    handleChar(.{ .codepoint = 'n' });

    const session = AppWindow.activePortForwarding() orelse return error.ExpectedPortForwardingTab;
    session.mutex.lock();
    defer session.mutex.unlock();
    const form = session.model.form() orelse return error.ExpectedPortForwardingForm;
    try std.testing.expectEqualStrings("Local proxy", form.rule.name());
}

// Ties the fix end-to-end: a consumed overlay key must make the next render-gate
// evaluation decide to render (the exact signal the main loop builds), instead of
// blocking until an incidental wake — that decision IS the anti-lag invariant.
test "input: overlay navigation drives the render gate to repaint" {
    const render_gate = @import("appwindow/render_gate.zig");
    defer overlays.commandPaletteClose();
    overlays.commandPaletteOpen();

    AppWindow.g_force_rebuild = false;
    AppWindow.g_cells_valid = true;
    handleKey(arrow_down_event);

    const signals = render_gate.RenderSignals{
        .force_rebuild = AppWindow.g_force_rebuild or !AppWindow.g_cells_valid,
        .any_surface_dirty = false,
        .cursor_blink_due = false,
        .ai_streaming = false,
        .overlay_active = false,
        .atlas_sync_pending = false,
    };
    try std.testing.expect(render_gate.frameNeedsRender(signals));
}

test "macOS UI smoke: Cmd+Shift+B toggles the tab sidebar" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const previous_keybinds = AppWindow.g_keybinds;
    const previous_sidebar = tab.g_sidebar_visible;
    defer AppWindow.g_keybinds = previous_keybinds;
    defer tab.g_sidebar_visible = previous_sidebar;

    AppWindow.g_keybinds = keybind.Set.defaults();
    tab.g_sidebar_visible = false;

    // macOS uses Cmd (super) for the sidebar toggle, not Ctrl.
    const sidebar_key = platform_input.KeyEvent{
        .key_code = 'B',
        .ctrl = false,
        .shift = true,
        .alt = false,
        .super = true,
    };

    handleKey(sidebar_key);
    try std.testing.expect(tab.g_sidebar_visible);

    handleKey(sidebar_key);
    try std.testing.expect(!tab.g_sidebar_visible);
}

fn weixinQrPanelConsumesChar() bool {
    return AppWindow.weixin_qr_panel.visible();
}

// Selection + divider drag state (moved from AppWindow.zig)
pub threadlocal var g_selecting: bool = false; // True while mouse button is held
pub threadlocal var g_click_x: f64 = 0; // X position of initial click (for threshold calculation)
pub threadlocal var g_click_y: f64 = 0; // Y position of initial click
var g_selection_changed_for_copy: bool = false;

// Terminal mouse reporting drag state. When a press is delivered to the PTY
// (the focused program enabled mouse tracking and Shift wasn't held), the
// matching drag-motion and release are routed to the PTY too — until the
// button lifts — instead of driving local text selection. See
// input/mouse_report.zig for the protocol encoder.
// The reported-drag state machine (begin/finish/motion-dedupe) lives in
// input/mouse_dispatch.zig as a pure, std-only helper; input.zig owns the one
// instance and supplies the I/O (report target, PTY write, focus).
threadlocal var g_mouse_report: mouse_dispatch.TerminalMouseReportState(*Surface) = .{};
threadlocal var g_left_click_tracker: click_tracker.ClickTracker = .{};
const MULTI_CLICK_INTERVAL_MS: i64 = 500;
const MAX_SELECTION_COLS: usize = 4096;

const UrlUnderline = struct {
    surface: ?*Surface = null,
    start_row_abs: usize = 0,
    end_row_abs: usize = 0,
    start_col: usize = 0,
    end_col: usize = 0,

    fn active(self: UrlUnderline) bool {
        return self.surface != null;
    }
};

threadlocal var g_url_underline: UrlUnderline = .{};

const TokenAtCell = struct {
    text: []u8,
    start_row: usize,
    end_row: usize,
    start_col: usize,
    end_col: usize,

    fn deinit(self: TokenAtCell, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

pub const SPLIT_DIVIDER_HIT_WIDTH: f32 = 8; // Larger hit area for easier grabbing

pub threadlocal var g_divider_hover: bool = false; // Mouse is over a divider
// Handle of the preview pane whose close (×) button the mouse is currently
// hovering, or null. The renderer brightens that pane's button; updated on
// mouse-move. Just a hover hint — clicks are hit-tested independently.
pub threadlocal var g_preview_close_hover: ?SplitTree.Node.Handle = null;
pub threadlocal var g_divider_dragging: bool = false; // Currently dragging a divider
pub threadlocal var g_divider_drag_handle: ?SplitTree.Node.Handle = null; // Handle of the split node being resized
pub threadlocal var g_divider_drag_layout: ?SplitTree.Split.Layout = null; // horizontal or vertical

// Alt + left-drag panel swap. `source` is the grabbed panel (recorded on press),
// `target` is the panel under the cursor while dragging (drives the highlight),
// `active` flips true once the drag passes PANEL_SWAP_DRAG_THRESHOLD_PX. The
// renderer reads `g_panel_swap_active`/`source`/`target` to dim the source and
// highlight the drop target.
const PANEL_SWAP_DRAG_THRESHOLD_PX: f64 = 6.0;
pub threadlocal var g_panel_swap_active: bool = false;
pub threadlocal var g_panel_swap_source: ?SplitTree.Node.Handle = null;
pub threadlocal var g_panel_swap_target: ?SplitTree.Node.Handle = null;
threadlocal var g_panel_swap_start_x: f64 = 0;
threadlocal var g_panel_swap_start_y: f64 = 0;

// Left-drag pan of a ready image preview pane (the pane-world successor of the
// old right-dock image drag). All state and the drag-lifetime pane ref live in
// the tested state machine; input.zig only routes press/move/release into it.
threadlocal var g_preview_image_drag: PreviewImageDrag = .{};
threadlocal var g_scrollbar_drag_surface: ?*Surface = null;
threadlocal var g_scrollbar_drag_view_y: f32 = 0;
threadlocal var g_scrollbar_drag_view_h: f32 = 0;
threadlocal var g_scrollbar_drag_top_pad: f32 = 0;
threadlocal var g_ai_input_scroll_dragging: bool = false;
threadlocal var g_ai_input_scroll_chat: ?*AppWindow.ai_chat.Session = null;
threadlocal var g_ai_input_scroll_drag_offset: f32 = 0;
const AiTranscriptPanel = enum {
    active_chat,
    copilot_sidebar,
};
const AiTranscriptPanelGeometry = ai_sidebar.PanelGeometry;
threadlocal var g_ai_transcript_scroll_dragging: bool = false;
threadlocal var g_ai_transcript_scroll_chat: ?*AppWindow.ai_chat.Session = null;
threadlocal var g_ai_transcript_scroll_drag_offset: f32 = 0;
threadlocal var g_ai_transcript_scroll_panel: AiTranscriptPanel = .active_chat;
threadlocal var g_ai_transcript_selecting: bool = false;
threadlocal var g_ai_transcript_select_chat: ?*AppWindow.ai_chat.Session = null;
threadlocal var g_ai_transcript_select_auto_copy: bool = false;
threadlocal var g_ai_transcript_select_panel: AiTranscriptPanel = .active_chat;
threadlocal var g_port_forwarding_suppress_command_char: ?u21 = null;
threadlocal var g_skill_center_suppress_command_char: ?u21 = null;
pub threadlocal var g_sidebar_resize_hover: bool = false; // Mouse is over the sidebar resize edge
pub threadlocal var g_sidebar_resize_dragging: bool = false; // Currently dragging the sidebar edge
pub threadlocal var g_explorer_resize_hover: bool = false; // Mouse is over the file explorer resize edge
pub threadlocal var g_explorer_resize_dragging: bool = false; // Currently dragging the file explorer edge
pub threadlocal var g_browser_resize_hover: bool = false; // Mouse is over the embedded browser edge
pub threadlocal var g_browser_resize_dragging: bool = false; // Currently dragging the browser edge
pub threadlocal var g_ai_copilot_resize_hover: bool = false; // Mouse is over the AI copilot left edge
pub threadlocal var g_ai_copilot_resize_dragging: bool = false; // Currently dragging the AI copilot edge
pub threadlocal var g_url_open_mode: link_open.Mode = .embedded;

/// Whether the AI copilot sidebar currently owns keyboard/mouse focus. Set by
/// AppWindow.toggleAiCopilot; full key/mouse routing lands in a later task.
threadlocal var g_ai_copilot_focused: bool = false;

pub fn focusAiCopilot() void {
    g_ai_copilot_focused = true;
}

pub fn blurAiCopilot() void {
    g_ai_copilot_focused = false;
}

pub fn aiCopilotFocused() bool {
    return g_ai_copilot_focused;
}
const SIDEBAR_TAB_DRAG_THRESHOLD_PX: f64 = 6.0;
threadlocal var g_sidebar_tab_drag_pressed: ?usize = null;
threadlocal var g_sidebar_tab_drag_current: ?usize = null;
threadlocal var g_sidebar_tab_drag_start_x: f64 = 0;
threadlocal var g_sidebar_tab_drag_start_y: f64 = 0;
threadlocal var g_sidebar_tab_drag_active: bool = false;

// Internal input state.
threadlocal var plus_btn_pressed: bool = false;
threadlocal var fullscreen_restore_state: window_backend.FullscreenRestoreState = .{};
const CLOSE_SHORTCUT_CONFIRM_MS: i64 = 5000;

fn titlebarHeight() f64 {
    return @floatCast(AppWindow.currentTitlebarHeight());
}

/// Snapshot the window geometry that hit-testing reads repeatedly
/// (framebuffer size + titlebar height + sidebar width) in one place, so panel
/// hit-tests consume a single computed struct instead of recomputing each value
/// inline. Reads the exact same sources as the inline call sites it replaces.
fn windowMetrics(win: *window_backend.Window) WindowMetrics {
    const fb = window_backend.framebufferSize(win);
    return WindowMetrics.init(
        fb.width,
        fb.height,
        titlebarHeight(),
        @floatCast(titlebar.sidebarWidth()),
    );
}

fn syncGridFromWindowSize(width: i32, height: i32) void {
    if (width <= 0 or height <= 0) return;
    const render_padding: f32 = 10;
    const tb_offset: f32 = @floatCast(titlebarHeight());
    const left_panels_w = AppWindow.leftPanelsWidth();
    const right_panels_w = AppWindow.rightPanelsWidthForWindow(width);
    const explicit_left: f32 = @floatFromInt(split_layout.DEFAULT_PADDING);
    const explicit_right: f32 = @as(f32, @floatFromInt(split_layout.DEFAULT_PADDING)) + overlays.SCROLLBAR_WIDTH;
    const explicit_top: f32 = @floatFromInt(split_layout.DEFAULT_PADDING);
    const explicit_bottom: f32 = @floatFromInt(split_layout.DEFAULT_PADDING);

    const total_width_padding = left_panels_w + right_panels_w + explicit_left + explicit_right;
    const total_height_padding = render_padding * 2 + tb_offset + explicit_top + explicit_bottom;

    const avail_width = @as(f32, @floatFromInt(width)) - total_width_padding;
    const avail_height = @as(f32, @floatFromInt(height)) - total_height_padding;

    const new_cols: u16 = @intFromFloat(@max(1, avail_width / font.cell_width));
    const new_rows: u16 = @intFromFloat(@max(1, avail_height / font.cell_height));

    if (new_cols != AppWindow.term_cols or new_rows != AppWindow.term_rows) {
        render_diagnostics.log(
            "input-grid-sync source={}x{} avail={d:.1}x{d:.1} panels_l={d:.1} panels_r={d:.1} titlebar={d:.1} cell={d:.2}x{d:.2} pending={}x{} old={}x{}",
            .{
                width,
                height,
                avail_width,
                avail_height,
                left_panels_w,
                right_panels_w,
                tb_offset,
                font.cell_width,
                font.cell_height,
                new_cols,
                new_rows,
                AppWindow.term_cols,
                AppWindow.term_rows,
            },
        );
        AppWindow.requestGridResize(
            new_cols,
            new_rows,
            std.time.milliTimestamp(),
        );
    }
}

fn syncGridFromWindowSizeImmediate(width: i32, height: i32) void {
    AppWindow.requestImmediateLayoutResize();
    syncGridFromWindowSize(width, height);
}

fn syncGridFromWindowSizeWithUrgency(width: i32, height: i32, urgency: LayoutResizeUrgency) void {
    const perf = ui_perf.begin(switch (urgency) {
        .coalesced => "input.grid_sync.coalesced",
        .immediate => "input.grid_sync.immediate",
    });
    defer perf.end();

    switch (urgency) {
        .coalesced => syncGridFromWindowSize(width, height),
        .immediate => syncGridFromWindowSizeImmediate(width, height),
    }
}

fn syncPanelGridFromWindowSize(width: i32, height: i32) void {
    syncGridFromWindowSizeWithUrgency(width, height, panelToggleResizeUrgency());
}

fn applyInputEffect(effect: ui_effect.UiEffect) void {
    AppWindow.applyUiEffect(effect);
}

fn requestInputRepaint() void {
    applyInputEffect(input_effects.repaint());
}

fn requestInputRebuild() void {
    applyInputEffect(input_effects.rebuildOnly());
}

fn requestInputDirtyFlags(force_rebuild: bool, cells_valid: bool) void {
    applyInputEffect(input_effects.fromDirtyFlags(force_rebuild, cells_valid));
}

fn markBrowserUrlBarDirty() void {
    requestInputRepaint();
}

fn markSkillCenterInputDirty() void {
    requestInputRepaint();
}

fn blurBrowserUrlBarIfFocused() void {
    if (!browser_panel.urlBarFocused()) return;
    browser_panel.blurUrlBar();
    markBrowserUrlBarDirty();
}

pub fn cancelTransientMouseState(win: anytype) void {
    g_divider_hover = false;
    g_divider_dragging = false;
    g_divider_drag_handle = null;
    g_divider_drag_layout = null;
    g_sidebar_resize_hover = false;
    g_sidebar_resize_dragging = false;
    g_explorer_resize_hover = false;
    g_explorer_resize_dragging = false;
    g_browser_resize_hover = false;
    g_browser_resize_dragging = false;
    g_ai_copilot_resize_hover = false;
    g_ai_copilot_resize_dragging = false;
    g_selecting = false;
    plus_btn_pressed = false;
    tab.g_tab_close_pressed = null;
    releasePreviewImageDrag();
    resetPanelSwapState();
    resetSidebarTabDragState();
    overlays.scrollbar.g_scrollbar_dragging = false;
    g_scrollbar_drag_surface = null;
    g_ai_input_scroll_dragging = false;
    g_ai_input_scroll_chat = null;
    g_ai_transcript_scroll_dragging = false;
    g_ai_transcript_scroll_chat = null;
    AppWindow.assistant_conversation_renderer.g_transcript_scrollbar_dragging = false;
    AppWindow.assistant_conversation_renderer.g_transcript_scrollbar_hover = false;
    g_ai_transcript_scroll_panel = .active_chat;
    g_ai_transcript_selecting = false;
    g_ai_transcript_select_chat = null;
    g_ai_transcript_select_auto_copy = false;
    g_ai_transcript_select_panel = .active_chat;
    window_backend.clearTransientInput(win);
}

pub fn toggleSidebar() void {
    const perf = ui_perf.begin("input.toggle_sidebar");
    defer perf.end();

    tab.g_sidebar_visible = !tab.g_sidebar_visible;
    if (AppWindow.g_window) |win| {
        syncPanelGridFromWindow(win);
        syncSidebarWidthToBackend(win);
    }
    requestInputRepaint();
}

pub fn toggleFileExplorer() void {
    const perf = ui_perf.begin("input.toggle_file_explorer");
    defer perf.end();

    file_explorer.toggle();
    if (file_explorer.isVisibleForActiveTab()) {
        AppWindow.syncVisibleFileExplorerForActiveTab(true);
    }
    if (AppWindow.g_window) |win| {
        syncPanelGridFromWindow(win);
    }
    requestInputRepaint();
}

fn closeFileExplorerPanel() void {
    file_explorer.close();
    blurBrowserUrlBarIfFocused();
    if (AppWindow.g_window) |win| {
        syncPanelGridFromWindow(win);
    }
    requestInputRepaint();
}

pub fn toggleBrowserPanel() void {
    const perf = ui_perf.begin("input.toggle_browser_panel");
    defer perf.end();

    const allocator = AppWindow.g_allocator orelse return;
    const parent = AppWindow.currentNativeHandle();
    const surface = AppWindow.activeSurface();
    if (g_url_open_mode == .system_browser and !browser_panel.isVisibleForActiveTab()) {
        const target = browser_panel.externalUrlForSurface(allocator, browser_panel.DEFAULT_URL, surface) orelse return;
        defer allocator.free(target);
        _ = platform_open_url.open(allocator, .{ .url = target });
        return;
    }
    if (!browser_panel.isVisibleForActiveTab()) AppWindow.hideAiCopilot();
    if (!browser_panel.toggleForSurface(allocator, parent, surface)) return;
    if (AppWindow.g_window) |win| {
        syncPanelGridFromWindow(win);
    }
    requestInputRepaint();
}

pub fn openJupyterPanel() void {
    const perf = ui_perf.begin("input.open_jupyter_panel");
    defer perf.end();

    const allocator = AppWindow.g_allocator orelse return;
    const parent = AppWindow.currentNativeHandle();
    const surface = AppWindow.activeSurface();
    if (!browser_panel.isVisibleForActiveTab()) AppWindow.hideAiCopilot();

    // Open Jupyter takes over the full content area.
    browser_panel.setDisplayMode(.full);

    // Auto-detect a running Jupyter URL from the focused terminal.
    if (AppWindow.activeSurfaceSnapshot(allocator)) |snap| {
        defer allocator.free(snap);
        if (jupyter_detect.findJupyterUrls(allocator, snap) catch null) |result| {
            defer result.deinit(allocator);
            if (result.urls.len == 1) {
                if (!browser_panel.openForSurface(allocator, parent, result.urls[0], surface)) return;
                finishOpenJupyter();
                return;
            } else if (result.urls.len >= 2) {
                jupyter_picker.show(@ptrCast(result.urls));
                requestInputRepaint();
                return;
            }
        }
    }

    // 0 matches → open full + focus empty URL bar for manual paste.
    if (!browser_panel.openJupyterForSurface(allocator, parent, surface)) return;
    finishOpenJupyter();
}

fn finishOpenJupyter() void {
    if (AppWindow.g_window) |win| {
        syncPanelGridFromWindow(win);
    }
    requestInputRepaint();
}

fn closeBrowserPanel() void {
    close_confirm_state.clear();
    browser_panel.close();
    if (AppWindow.g_window) |win| {
        syncPanelGridFromWindow(win);
    }
    requestInputRepaint();
}

pub fn refreshBrowserPanel() void {
    browser_panel.refresh();
    requestInputRepaint();
}

fn closeAiCopilotPanel() void {
    AppWindow.hideAiCopilot();
    if (AppWindow.g_window) |win| {
        syncPanelGridFromWindow(win);
    }
    requestInputRepaint();
}

pub fn closePanelOrTab() void {
    // Close the FOCUSED pane. A preview pane closes on one press; a terminal pane is
    // guarded by a confirm so a stray Ctrl+Shift+W can't drop the terminal you are
    // typing in (focus stays on the terminal after a preview opens). The browser
    // panel still closes first: it is an unfocusable side dock, so this shortcut is
    // its only keyboard close. Priority order lives in close_confirm.decideClose.
    switch (close_confirm.decideClose(.{
        .browser_visible = browser_panel.isVisibleForActiveTab(),
        .confirm_running_enabled = AppWindow.g_confirm_close_running_program,
        .has_running_program = AppWindow.activeSurfaceHasRunningProgram(),
        .would_close_window = AppWindow.closeFocusedSplitWouldCloseWindow(),
        .focused_is_terminal = AppWindow.focusedPaneIsTerminal(),
    })) {
        .close_browser => closeBrowserPanel(),
        .confirm_running_program => {
            close_confirm_state.clear();
            overlays.closeConfirmOpen(.focused_split, .running_program);
            requestInputRepaint();
        },
        .window_press_again => {
            const now = std.time.milliTimestamp();
            if (close_confirm_state.isActive(now)) {
                close_confirm_state.clear();
                AppWindow.closeFocusedSplit();
                return;
            }
            close_confirm_state.show(now, CLOSE_SHORTCUT_CONFIRM_MS);
            overlays.showCloseShortcutConfirm(CLOSE_SHORTCUT_CONFIRM_MS);
            requestInputRepaint();
        },
        .confirm_terminal => {
            close_confirm_state.clear();
            overlays.closeConfirmOpen(.focused_split, .terminal_split);
            requestInputRepaint();
        },
        .close_now => {
            close_confirm_state.clear();
            AppWindow.closeFocusedSplit();
        },
    }
}

/// Close a specific preview pane by handle (the preview's × button). Focuses
/// the pane, then reuses the standard close-split path, which removes it and
/// refocuses the surviving terminal. Defensive: a no-op unless `handle` is still
/// a live preview leaf (the tree may reshape between the cached rect and the
/// click). Closing a preview never closes the window or hits a running program,
/// so the close-shortcut/running-program confirmations are intentionally skipped.
fn closePreviewPaneByHandle(handle: SplitTree.Node.Handle) void {
    const tb = AppWindow.activeTab() orelse return;
    if (tb.kind != .terminal) return;
    if (handle.idx() >= tb.tree.nodes.len) return;
    switch (tb.tree.nodes[handle.idx()]) {
        .leaf => |pane| switch (pane) {
            .preview => {},
            else => return,
        },
        .split => return,
    }
    g_preview_close_hover = null;
    tb.focused = handle;
    AppWindow.closeFocusedSplit();
    requestInputRepaint();
}

/// Close a tab via a pointer gesture (middle-click or the × button), honoring
/// the running-program confirmation. `tab_idx` is the tab to close.
fn requestCloseTabGesture(tab_idx: usize) void {
    const closes_window = tab.g_tab_count <= 1;
    if (close_confirm.shouldConfirm(AppWindow.g_confirm_close_running_program, AppWindow.tabHasRunningProgram(tab_idx))) {
        const action: close_confirm.PendingClose = if (closes_window) .window else .{ .tab = tab_idx };
        overlays.closeConfirmOpen(action, .running_program);
        requestInputRepaint();
        return;
    }
    if (closes_window) {
        AppWindow.g_should_close = true;
    } else {
        AppWindow.closeTab(tab_idx);
    }
}

pub fn adjustFontSize(delta: i32) void {
    const allocator = AppWindow.g_allocator orelse return;
    var cfg = Config.load(allocator) catch Config{};
    defer cfg.deinit(allocator);

    const current: i32 = @intCast(cfg.@"font-size");
    var next = current + delta;
    if (next < 6) next = 6;
    if (next > 72) next = 72;
    if (next == current) return;

    var buf: [16]u8 = undefined;
    const value = std.fmt.bufPrint(&buf, "{d}", .{next}) catch return;
    Config.setConfigValue(allocator, "font-size", value) catch {};
}

pub fn copyRemoteSessionKeyToClipboard() bool {
    const app = AppWindow.g_app orelse return false;
    const client = app.remote_client orelse return false;
    const key = client.sessionKey();
    if (!copyTextToClipboard(key)) return false;
    overlays.remoteKeyCopiedFlash();
    overlays.remoteKeyOverlayDismiss(key);
    requestInputRepaint();
    std.debug.print("Remote session key copied to clipboard\n", .{});
    return true;
}

// ============================================================================
// Shared helpers (used by input + cell_renderer)
// ============================================================================

pub const ScrollbarState = struct {
    total: usize,
    offset: usize,
    len: usize,
};

/// Convert mouse position to terminal cell coordinates.
pub fn mouseToCell(xpos: f64, ypos: f64) CellPos {
    const padding_d: f64 = 10;
    const tb_d = titlebarHeight();
    const sidebar_d: f64 = @floatCast(titlebar.sidebarWidth());
    const col_f = (xpos - sidebar_d - padding_d) / @as(f64, font.cell_width);
    const row_f = (ypos - padding_d - tb_d) / @as(f64, font.cell_height);

    const col = if (col_f < 0) 0 else if (col_f >= @as(f64, @floatFromInt(AppWindow.term_cols))) AppWindow.term_cols - 1 else @as(usize, @intFromFloat(col_f));
    const row = if (row_f < 0) 0 else if (row_f >= @as(f64, @floatFromInt(AppWindow.term_rows))) AppWindow.term_rows - 1 else @as(usize, @intFromFloat(row_f));

    return .{ .col = col, .row = row };
}

fn splitRectForSurface(surface: *Surface) ?split_layout.SplitRect {
    for (0..split_layout.g_split_rect_count) |i| {
        const rect = split_layout.g_split_rects[i];
        if (!split_layout.cachedRectIsLive(rect)) continue;
        const s = rect.surface() orelse continue;
        if (s == surface) return rect;
    }
    return null;
}

const ScrollbarTarget = struct {
    surface: *Surface,
    view_x: f32,
    view_y: f32,
    view_w: f32,
    view_h: f32,
    top_pad: f32,
};

fn scrollbarTargetAt(xpos: f64, ypos: f64, window_w: f32, window_h: f32, top_pad: f32) ?ScrollbarTarget {
    if (split_layout.g_split_rect_count > 1) {
        for (0..split_layout.g_split_rect_count) |i| {
            const rect = split_layout.g_split_rects[i];
            if (!split_layout.cachedRectIsLive(rect)) continue;
            const s = rect.surface() orelse continue;
            const pad = s.getPadding();
            const view_x: f32 = @floatFromInt(rect.x);
            const view_y: f32 = @floatFromInt(rect.y);
            const view_w: f32 = @floatFromInt(rect.width);
            const view_h: f32 = @floatFromInt(rect.height);
            const local_top_pad: f32 = @floatFromInt(pad.top);
            if (overlays.scrollbarHitTestForSurface(s, xpos, ypos, view_x, view_y, view_w, view_h, local_top_pad)) {
                return .{
                    .surface = s,
                    .view_x = view_x,
                    .view_y = view_y,
                    .view_w = view_w,
                    .view_h = view_h,
                    .top_pad = local_top_pad,
                };
            }
        }
        return null;
    }

    const surface = AppWindow.activeSurface() orelse return null;
    if (!overlays.scrollbarHitTestForSurface(surface, xpos, ypos, 0, 0, window_w, window_h, top_pad)) return null;
    return .{
        .surface = surface,
        .view_x = 0,
        .view_y = 0,
        .view_w = window_w,
        .view_h = window_h,
        .top_pad = top_pad,
    };
}

pub fn viewportOffsetForSurface(surface: *Surface) usize {
    return scrollbarForSurface(surface).offset;
}

pub fn scrollbarForSurface(surface: *Surface) ScrollbarState {
    surface.render_state.mutex.lock();
    defer surface.render_state.mutex.unlock();
    return scrollbarForSurfaceLocked(surface);
}

pub fn viewportOffsetForSurfaceLocked(surface: *Surface) usize {
    return scrollbarForSurfaceLocked(surface).offset;
}

pub fn scrollbarForSurfaceLocked(surface: *Surface) ScrollbarState {
    var pages = &surface.terminal.screens.active.pages;
    const rows: usize = @intCast(pages.rows);
    if (pages.total_rows <= rows) {
        return .{
            .total = rows,
            .offset = 0,
            .len = rows,
        };
    }

    const sb = pages.scrollbar();
    return .{
        .total = sb.total,
        .offset = sb.offset,
        .len = sb.len,
    };
}

/// Convert a window mouse position to a cell in the clicked split surface.
fn mouseToSurfaceCell(surface: *Surface, xpos: f64, ypos: f64) CellPos {
    const rect = splitRectForSurface(surface) orelse return mouseToCell(xpos, ypos);
    const pad = surface.getPadding();
    const col_f = (xpos - @as(f64, @floatFromInt(rect.x)) - @as(f64, @floatFromInt(pad.left))) / @as(f64, @floatCast(font.cell_width));
    const row_f = (ypos - @as(f64, @floatFromInt(rect.y)) - @as(f64, @floatFromInt(pad.top))) / @as(f64, @floatCast(font.cell_height));
    const cols = @max(@as(usize, 1), @as(usize, @intCast(surface.size.grid.cols)));
    const rows = @max(@as(usize, 1), @as(usize, @intCast(surface.size.grid.rows)));

    const col = if (col_f < 0) 0 else if (col_f >= @as(f64, @floatFromInt(cols))) cols - 1 else @as(usize, @intFromFloat(col_f));
    const row = if (row_f < 0) 0 else if (row_f >= @as(f64, @floatFromInt(rows))) rows - 1 else @as(usize, @intFromFloat(row_f));

    return .{ .col = col, .row = row };
}

fn mouseToSurfacePixel(surface: *Surface, xpos: i32, ypos: i32) struct { x: i32, y: i32 } {
    if (splitRectForSurface(surface)) |rect| {
        const pad = surface.getPadding();
        return .{
            .x = xpos - rect.x - @as(i32, @intCast(pad.left)),
            .y = ypos - rect.y - @as(i32, @intCast(pad.top)),
        };
    }
    return .{
        .x = xpos - @as(i32, @intFromFloat(titlebar.sidebarWidth())) - 10,
        .y = ypos - @as(i32, @intFromFloat(titlebarHeight())) - 10,
    };
}

/// Update split focus based on mouse position (focus follows mouse).
pub fn updateFocusFromMouse(mouse_x: i32, mouse_y: i32) void {
    const t = tab.activeTab() orelse return;
    for (0..split_layout.g_split_rect_count) |i| {
        const rect = split_layout.g_split_rects[i];
        if (!split_layout.cachedRectIsLive(rect)) continue;
        if (mouse_x >= rect.x and mouse_x < rect.x + rect.width and
            mouse_y >= rect.y and mouse_y < rect.y + rect.height)
        {
            if (rect.handle != t.focused) {
                t.focused = rect.handle;
                AppWindow.handleActiveSurfaceChangeWithinTab();
            }
            return;
        }
    }
}

/// Return the split-tree handle of the panel containing the given window point,
/// or null if the point is not inside any (live) panel rect — e.g. it is over a
/// divider gap or outside the content area.
fn panelHandleAtPoint(x: i32, y: i32) ?SplitTree.Node.Handle {
    for (0..split_layout.g_split_rect_count) |i| {
        const rect = split_layout.g_split_rects[i];
        if (!split_layout.cachedRectIsLive(rect)) continue;
        if (x >= rect.x and x < rect.x + rect.width and
            y >= rect.y and y < rect.y + rect.height)
        {
            return rect.handle;
        }
    }
    return null;
}

fn resetPanelSwapState() void {
    g_panel_swap_active = false;
    g_panel_swap_source = null;
    g_panel_swap_target = null;
    g_panel_swap_start_x = 0;
    g_panel_swap_start_y = 0;
}

/// End an image-preview pan drag, dropping the drag's pane reference.
fn releasePreviewImageDrag() void {
    const gpa = AppWindow.g_allocator orelse return; // drag only starts when set
    g_preview_image_drag.release(gpa);
}

/// Begin a potential Alt-drag panel swap if the active terminal tab is split and
/// the press landed inside a panel. Returns true if the gesture was engaged (the
/// caller should consume the event). Single-panel tabs are left alone so default
/// click/selection behavior is unchanged.
fn beginPanelSwapIfSplit(x: i32, y: i32) bool {
    const t = tab.activeTab() orelse return false;
    if (t.kind != .terminal or !t.tree.isSplit()) return false;
    const source = panelHandleAtPoint(x, y) orelse return false;
    g_panel_swap_source = source;
    g_panel_swap_target = null;
    g_panel_swap_active = false;
    g_panel_swap_start_x = @floatFromInt(x);
    g_panel_swap_start_y = @floatFromInt(y);
    platform_cursor.set(.size_all);
    return true;
}

/// Drive an in-progress panel swap from a mouse-move. Returns true while the
/// gesture owns the move (caller should return early). Engages `active` once the
/// drag passes the threshold, then tracks the hovered drop target for highlight.
fn updatePanelSwapDrag(x: i32, y: i32) bool {
    const source = g_panel_swap_source orelse return false;

    if (!g_panel_swap_active) {
        const dx = @as(f64, @floatFromInt(x)) - g_panel_swap_start_x;
        const dy = @as(f64, @floatFromInt(y)) - g_panel_swap_start_y;
        if (@sqrt(dx * dx + dy * dy) < PANEL_SWAP_DRAG_THRESHOLD_PX) return true;
        g_panel_swap_active = true;
        g_selecting = false;
    }

    // The drop target is the hovered panel, but never the source itself.
    const hovered = panelHandleAtPoint(x, y);
    const target: ?SplitTree.Node.Handle = if (hovered) |h| (if (h == source) null else h) else null;
    if (target != g_panel_swap_target) {
        g_panel_swap_target = target;
        requestInputRepaint();
    }
    platform_cursor.set(.size_all);
    return true;
}

/// Finish a panel swap on mouse-up. Returns true if a swap gesture was in
/// progress (caller should consume the event). Performs the swap only when the
/// drag was active and dropped on a valid, different panel.
fn finishPanelSwapDrag() bool {
    const source = g_panel_swap_source orelse return false;
    const did_swap = g_panel_swap_active;
    const target = g_panel_swap_target;
    resetPanelSwapState();
    if (did_swap) {
        if (target) |t| _ = AppWindow.swapPanels(source, t);
    }
    // The press set the size_all cursor; restore it whether or not a swap
    // happened (a bare Alt-click never crossed the drag threshold).
    platform_cursor.set(.arrow);
    return true;
}

/// 时序 instrumentation：最近一次处理 key/char 输入的微秒时间戳，尚未与一帧 present 配对。
/// 主循环 present 后读它算「输入 → 呈现」延迟（见 AppWindow.recordFrameLatencyIfInputDriven），
/// 0 表示无待配对输入。仅在开启 render diagnostics 时被读取，平时只是个无害的时间戳写入。
pub threadlocal var g_pending_input_us: i64 = 0;
/// Main-loop iteration in which the above input was processed. Paired with
/// AppWindow.g_loop_iter at present time: equal ⇒ the input painted in its own
/// iteration (true latency); different ⇒ the loop idled in between and an
/// unrelated wake (cursor blink, etc.) presented — a stall, not real latency.
pub threadlocal var g_pending_input_iter: u64 = 0;

/// Process all queued platform input events. Called once per frame from the main loop.
pub fn processEvents(win: anytype) void {
    if (window_backend.isMinimized(win)) {
        cancelTransientMouseState(win);
        _ = window_backend.consumeSizeChanged(win);
        return;
    }
    processKeyAndCharEvents(win);
    processMouseButtonEvents(win);
    processMouseMoveEvents(win);
    processMouseWheelEvents(win);
    processSizeChange(win);
}

// Interleave key and text events so they fire in the order the platform
// backend generated them. Key events can arrive before their matching text
// events, so popping one event from each queue per iteration replays the
// original temporal order. Draining keys fully before text meant a
// focus-shifting key (Enter, Tab, Down) typed right after a character changed
// focus before the queued character was inserted, dropping the last password
// byte into the Port field and silently breaking SSH connect via the form.
fn processKeyAndCharEvents(win: anytype) void {
    while (true) {
        var did_anything = false;
        if (window_backend.popKeyEvent(win)) |ev| {
            handleKey(ev);
            did_anything = true;
        }
        if (window_backend.popCharEvent(win)) |ev| {
            handleChar(ev);
            did_anything = true;
        }
        if (!did_anything) break;
        // Stamp the input→present latency clock on every handled key/char so the
        // main loop can measure how long the resulting frame took to reach present,
        // and tag the iteration so a later, unrelated paint isn't mis-attributed.
        g_pending_input_us = std.time.microTimestamp();
        g_pending_input_iter = AppWindow.g_loop_iter;
    }
}

fn processMouseButtonEvents(win: anytype) void {
    while (window_backend.popMouseButtonEvent(win)) |ev| {
        handleMouseButton(ev);
    }
}

fn processMouseMoveEvents(win: anytype) void {
    // Only process the latest move event (coalesce)
    var latest: ?platform_input.MouseMoveEvent = null;
    while (window_backend.popMouseMoveEvent(win)) |ev| {
        latest = ev;
    }
    if (latest) |ev| {
        handleMouseMove(ev);
    }
}

fn processMouseWheelEvents(win: anytype) void {
    while (window_backend.popMouseWheelEvent(win)) |ev| {
        handleMouseWheel(ev);
    }
}

fn processSizeChange(win: anytype) void {
    if (!window_backend.consumeSizeChanged(win)) return;
    const size = window_backend.clientSize(win);
    if (window_backend.isMinimized(win) or size.width <= 0 or size.height <= 0) return;
    render_diagnostics.log(
        "input-size-change client={}x{} dpi={} font_dpi={} cell={d:.2}x{d:.2} term={}x{}",
        .{ size.width, size.height, window_backend.effectiveDpi(win), font.g_dpi, font.cell_width, font.cell_height, AppWindow.term_cols, AppWindow.term_rows },
    );
    if (titlebar.setSidebarWidth(titlebar.g_sidebar_width, @floatFromInt(size.width))) {
        syncSidebarWidthToBackend(win);
        requestInputRepaint();
    }

    syncGridFromWindowSize(size.width, size.height);
}

fn handleChar(ev: platform_input.CharEvent) void {
    applyInputEffect(dispatchChar(ev));
}

fn dispatchChar(ev: platform_input.CharEvent) ui_effect.UiEffect {
    overlays.startupShortcutsDismiss();
    if (overlays.sessionLauncherVisible()) {
        if (!ev.ctrl and !ev.alt) {
            overlays.sessionLauncherInsertChar(ev.codepoint);
            return input_effects.repaint();
        }
        return .none;
    }
    if (overlays.commandPaletteVisible()) {
        const effect = command_palette_input.charEffect(ev);
        if (effect.needs_rebuild) overlays.commandPaletteInsertChar(ev.codepoint);
        return effect;
    }
    if (weixinQrPanelConsumesChar()) return .none;
    if (browser_panel.urlBarFocused()) {
        if (!ev.ctrl and !ev.alt) {
            browser_panel.insertUrlBarChar(ev.codepoint);
            markBrowserUrlBarDirty();
        }
        return .none;
    }
    // File explorer inline editing
    if (file_explorer.isFocused() and file_explorer.isVisibleForActiveTab() and file_explorer.hasActiveOp() and file_explorer.opMode() != .confirm_delete) {
        if (!ev.ctrl and !ev.alt) file_explorer.inputChar(ev.codepoint);
        return .none;
    }
    // When tab rename is active, route chars to the rename buffer
    if (tab.g_tab_rename_active) {
        AppWindow.g_cursor_blink_visible = true;
        AppWindow.g_last_blink_time = std.time.milliTimestamp();
        tab.handleRenameChar(ev.codepoint);
        return .none;
    }
    if (assistant_conversation.current(aiCopilotFocused())) |target| {
        if (!ev.ctrl and !ev.alt) {
            AppWindow.resetCursorBlink();
            target.session.handleChar(ev.codepoint);
            return input_effects.repaint();
        }
        return .none;
    }
    if (AppWindow.activeAiHistory() != null) {
        // aiHistoryInsertCodepoint only consumes the codepoint while the Search box
        // owns focus, so 'r'/Space type into the query there yet stay free to act as
        // Scan/Preview shortcuts when another panel is focused. A Space on an empty
        // query is declined (see typeIntoSearch) so it previews the transcript too.
        if (!ev.ctrl and !ev.alt and !ev.super) {
            _ = AppWindow.aiHistoryInsertCodepoint(ev.codepoint);
        }
        return .none;
    }
    if (AppWindow.activeSkillCenter() != null) {
        if (g_skill_center_suppress_command_char) |codepoint| {
            const suppress = !ev.ctrl and !ev.alt and !ev.super and ev.codepoint == codepoint;
            g_skill_center_suppress_command_char = null;
            if (suppress) return .none;
        }
        if (!ev.ctrl and !ev.alt and !ev.super) {
            if (AppWindow.skillCenterUrlInsertChar(ev.codepoint)) markSkillCenterInputDirty(); // no-op unless url_input active
        }
        return .none;
    }
    if (AppWindow.activePortForwarding() != null) {
        if (g_port_forwarding_suppress_command_char) |codepoint| {
            const suppress = !ev.ctrl and !ev.alt and !ev.super and ev.codepoint == codepoint;
            g_port_forwarding_suppress_command_char = null;
            if (suppress) return .none;
        }
        if (!ev.ctrl and !ev.alt and !ev.super) {
            _ = AppWindow.portForwardingInsertChar(ev.codepoint);
        }
        return .none;
    }
    // A focused raster (image/PDF) preview consumes +/=/- as zoom in/out. Only
    // raster previews claim these chars (markdown previews ignore them so they
    // reach nothing), and only when such a preview holds focus — terminals are
    // never affected.
    if (AppWindow.focusedPreviewPane()) |p| {
        if (p.kind.isRaster() and !ev.ctrl and !ev.alt) {
            const zoomed = switch (ev.codepoint) {
                '+', '=' => p.zoomImageBySteps(1, true),
                '-', '_' => p.zoomImageBySteps(1, false),
                else => false,
            };
            if (zoomed) return input_effects.repaint();
            switch (ev.codepoint) {
                '+', '=', '-', '_' => return .none,
                else => {},
            }
        }
    }
    if (!AppWindow.isActiveTabTerminal()) return .none;
    // Skip chars when Alt is held without Ctrl — those are part of Alt+key
    // combos (e.g. Shift+Alt+4) and shouldn't produce text input.
    // However, AltGr on international keyboards reports as Ctrl+Alt, so
    // we must allow chars when both Ctrl and Alt are held (AltGr chars).
    // This matches Ghostty's consumed_mods / effectiveMods approach.
    if (ev.alt and !ev.ctrl) return .none;
    // Cmd / Super shortcuts (macOS Cmd+C, Win key on other platforms) are
    // commands, not text input — never inject them into the PTY.
    if (ev.super) return .none;
    const surface = AppWindow.activeSurface() orelse return .none;
    AppWindow.resetCursorBlink();
    {
        surface.render_state.mutex.lock();
        defer surface.render_state.mutex.unlock();
        surface.terminal.scrollViewport(.bottom);
    }
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(ev.codepoint, &buf) catch return .none;
    writeToPty(surface, buf[0..len]);
    return .none;
}

const KeybindPhase = command_dispatch.Phase;

fn triggerFromKeyEvent(ev: platform_input.KeyEvent) keybind.Trigger {
    return .{
        .mods = .{ .ctrl = ev.ctrl, .shift = ev.shift, .alt = ev.alt, .win = ev.super },
        .key_code = @intCast(ev.key_code),
    };
}

fn configuredAction(ev: platform_input.KeyEvent) ?keybind.Action {
    return AppWindow.g_keybinds.lookupApp(triggerFromKeyEvent(ev));
}

fn logicalKeyEvent(ev: platform_input.KeyEvent) input_key.KeyEvent {
    return .{
        .key = logicalKeyFromCode(ev.key_code),
        .ctrl = ev.ctrl,
        .shift = ev.shift,
        .alt = ev.alt,
    };
}

fn logicalKeyFromCode(key_code: platform_input.KeyCode) input_key.Key {
    return switch (key_code) {
        platform_input.key_backspace => .backspace,
        platform_input.key_tab => .tab,
        platform_input.key_enter => .enter,
        platform_input.key_escape => .escape,
        platform_input.key_space => .space,
        platform_input.key_delete => .delete,
        platform_input.key_home => .home,
        platform_input.key_end => .end,
        platform_input.key_page_up => .page_up,
        platform_input.key_page_down => .page_down,
        platform_input.key_insert => .insert,
        platform_input.key_up => .arrow_up,
        platform_input.key_down => .arrow_down,
        platform_input.key_left => .arrow_left,
        platform_input.key_right => .arrow_right,
        0x41 => .key_a,
        0x43 => .key_c,
        0x45 => .key_e,
        0x48 => .key_h,
        0x4B => .key_k,
        0x4C => .key_l,
        0x4E => .key_n,
        0x50 => .key_p,
        0x53 => .key_s,
        0x55 => .key_u,
        0x56 => .key_v,
        0x57 => .key_w,
        0x59 => .key_y,
        else => .unidentified,
    };
}

fn aiTranscriptPanelGeometryForBounds(window_width: i32, window_height: i32, bounds: ai_sidebar.Bounds) AiTranscriptPanelGeometry {
    return ai_sidebar.panelGeometryForBounds(window_width, window_height, bounds);
}

fn aiTranscriptPanelGeometry(panel: AiTranscriptPanel) ?AiTranscriptPanelGeometry {
    const win = AppWindow.g_window orelse return null;
    const metrics = windowMetrics(win);
    return switch (panel) {
        .active_chat => .{
            .window_width = @floatFromInt(metrics.framebuffer_width),
            .window_height = @floatFromInt(metrics.framebuffer_height),
            .chat_x = AppWindow.leftPanelsWidth(),
            .chat_w = @as(f32, @floatFromInt(metrics.framebuffer_width)) - AppWindow.leftPanelsWidth() - AppWindow.rightPanelsWidthForWindow(metrics.framebuffer_width),
        },
        .copilot_sidebar => blk: {
            if (!AppWindow.aiCopilotVisible()) return null;
            const bounds = ai_sidebar.boundsForWindow(
                @intCast(metrics.framebuffer_width),
                @intCast(metrics.framebuffer_height),
                @floatCast(metrics.titlebar_h),
                AppWindow.leftPanelsWidth(),
                0,
            );
            break :blk aiTranscriptPanelGeometryForBounds(@intCast(metrics.framebuffer_width), @intCast(metrics.framebuffer_height), bounds);
        },
    };
}

test "input: logical key mapping includes session launcher H mnemonic" {
    try std.testing.expectEqual(input_key.Key.key_h, logicalKeyFromCode(0x48));
}

test "input: copilot transcript panel geometry uses sidebar bounds" {
    const bounds = ai_sidebar.Bounds{
        .left = 1120,
        .top = 30,
        .right = 1600,
        .bottom = 900,
    };
    const geometry = aiTranscriptPanelGeometryForBounds(1600, 900, bounds);

    try std.testing.expectApproxEqAbs(@as(f32, 1600), geometry.window_width, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 900), geometry.window_height, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1120), geometry.chat_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 480), geometry.chat_w, 0.001);
}

fn actionIs(action: ?keybind.Action, expected: keybind.Action) bool {
    return if (action) |actual| actual == expected else false;
}

fn commitTabRenameIfActive() void {
    if (tab.g_tab_rename_active) tab.commitTabRename();
}

fn currentClientWidthOr(default: f64) ?f64 {
    const win = AppWindow.g_window orelse return null;
    const rect = window_backend.clientRect(win) orelse return default;
    return @floatFromInt(rect.right);
}

fn requestNewWindowFromActiveCwd() void {
    const app = AppWindow.g_app orelse return;
    const handle = AppWindow.currentNativeHandle();

    var cwd_buf: platform_pty_command.CwdBuffer = undefined;
    var cwd: ?platform_pty_command.CwdSlice = null;
    if (AppWindow.activeSurface()) |surface| {
        if (surface.getCwd()) |guest_path| {
            std.debug.print("CWD from OSC 7: {s}\n", .{guest_path});
            if (platform_wsl.nativeCwdForLaunchKind(surface.launch_kind, guest_path, &cwd_buf)) |native_cwd| {
                cwd = native_cwd;
                var path_u8: [260]u8 = undefined;
                var display_buf: platform_pty_command.CwdBuffer = undefined;
                if (platform_wsl.guestPathToLocalPathUtf8(guest_path, &display_buf, &path_u8)) |local_path| {
                    std.debug.print("Converted to local path: {s}\n", .{local_path});
                }
            } else {
                std.debug.print("Failed to convert WSL guest path to local path\n", .{});
            }
        } else {
            std.debug.print("No CWD from active surface (OSC 7 not received)\n", .{});
        }
    }
    app.requestNewWindow(handle, cwd);
}

fn handleConfiguredKeybindAction(action: keybind.Action, phase: KeybindPhase) bool {
    const cmd = command_dispatch.resolve(action, phase) orelse return false;
    if (phase == .early) commitTabRenameIfActive();
    return executeCommand(cmd);
}

/// Dispatch a keybind action through both early and late phases. Used by UI
/// entrypoints (NSMenu items, future buttons) so a click takes the same path
/// as a keyboard shortcut without reproducing the early/late split logic.
pub fn invokeKeybindAction(action: keybind.Action) bool {
    if (handleConfiguredKeybindAction(action, .early)) return true;
    return handleConfiguredKeybindAction(action, .late);
}

fn executeCommand(cmd: command_dispatch.Command) bool {
    switch (cmd) {
        // Early
        .toggle_quake => AppWindow.toggleQuakeVisibility(),
        .toggle_command_palette => overlays.commandPaletteToggle(),
        .new_window => requestNewWindowFromActiveCwd(),
        .new_session => overlays.sessionLauncherOpen(),
        .split_right => AppWindow.splitFocused(.right),
        .split_down => AppWindow.splitFocused(.down),
        .toggle_file_explorer => toggleFileExplorer(),
        .toggle_sidebar => toggleSidebar(),
        .toggle_ai_copilot => AppWindow.toggleAiCopilot(),
        .copilot_conversation_picker => AppWindow.openCopilotConversationPicker(),
        .close_panel_or_tab => closePanelOrTab(),
        .toggle_maximize => toggleMaximize(),
        .font_size => |delta| adjustFontSize(delta),
        // Late
        .copy => copySelectionToClipboard(),
        .paste => {
            if (assistant_conversation.current(aiCopilotFocused())) |target| {
                pasteFromClipboardIntoAiChat(target.session);
            } else {
                pasteFromClipboard();
            }
        },
        .paste_image => {
            if (assistant_conversation.current(aiCopilotFocused())) |target| {
                pasteImageIntoAiChat(target.session);
            } else {
                pasteImageFromClipboard();
            }
        },
        // Panel-focus shortcuts are "performable": if there is no pane in
        // the requested direction, don't consume the key so it falls
        // through to the terminal (e.g. Alt+Up reaches a TUI like Claude
        // Code as \x1b[1;3A when running in a single pane).
        .focus_split => |target| return switch (target) {
            .left => AppWindow.gotoSplit(.{ .spatial = .left }),
            .right => AppWindow.gotoSplit(.{ .spatial = .right }),
            .up => AppWindow.gotoSplit(.{ .spatial = .up }),
            .down => AppWindow.gotoSplit(.{ .spatial = .down }),
            .previous => AppWindow.gotoSplit(.previous_wrapped),
            .next => AppWindow.gotoSplit(.next_wrapped),
        },
        // Numeric panel focus: like focus_split, "performable" — if there is no
        // panel at that index (single-panel tab, or index past the panel count),
        // don't consume the key so it falls through to the terminal.
        .focus_panel => |n| return AppWindow.focusPanel(n),
        .equalize_splits => AppWindow.equalizeSplits(),
        .next_tab => AppWindow.switchTab((active_tab_state.g_active_tab + 1) % tab.g_tab_count),
        .previous_tab => {
            if (active_tab_state.g_active_tab > 0) AppWindow.switchTab(active_tab_state.g_active_tab - 1) else AppWindow.switchTab(tab.g_tab_count - 1);
        },
        .open_config => {
            std.debug.print("[keybind] open_config pressed\n", .{});
            if (AppWindow.g_allocator) |alloc| Config.openConfigInEditor(alloc);
        },
        .switch_tab => |idx| {
            if (idx < tab.g_tab_count) AppWindow.switchTab(idx);
        },
    }
    return true;
}

fn applyCommandPaletteAction(action: command_palette_input.Action, history_visible: bool) void {
    switch (action) {
        .noop => {},
        .close => overlays.commandPaletteClose(),
        .leave_history => overlays.commandPaletteLeaveAgentHistory(),
        .move_up => if (history_visible) overlays.commandPaletteMoveAgentHistory(-1) else overlays.commandPaletteMove(-1),
        .move_down => if (history_visible) overlays.commandPaletteMoveAgentHistory(1) else overlays.commandPaletteMove(1),
        .execute => overlays.commandPaletteExecuteSelected(),
        .backspace => overlays.commandPaletteBackspace(),
        .clear_filter => overlays.commandPaletteClearFilter(),
        .delete_history => _ = overlays.commandPaletteDeleteSelectedAgentHistory(),
        .cycle_history_source => overlays.commandPaletteCycleHistorySource(),
    }
}

/// Encode a special terminal key (Enter/Backspace/Tab) honoring the Kitty
/// keyboard protocol when the foreground app enabled it, otherwise returning
/// the supplied legacy bytes. This is what lets Shift+Enter reach Claude
/// Code/Codex as a distinct "insert newline" sequence (issue #302).
fn terminalSpecialKeySeq(
    surface: *Surface,
    ev: platform_input.KeyEvent,
    key: anytype,
    buf: []u8,
    legacy: []const u8,
) []const u8 {
    const ghostty_vt = @import("ghostty-vt");
    const opts = ghostty_vt.input.KeyEncodeOptions.fromTerminal(&surface.terminal);
    const mods: ghostty_vt.input.KeyMods = .{
        .shift = ev.shift,
        .ctrl = ev.ctrl,
        .alt = ev.alt,
        .super = ev.super,
    };
    return input_shortcuts.kittyKeyEncode(opts, key, mods, buf) orelse legacy;
}

fn handleKey(ev: platform_input.KeyEvent) void {
    applyInputEffect(dispatchKey(ev));
}

fn dispatchKey(ev: platform_input.KeyEvent) ui_effect.UiEffect {
    overlays.startupShortcutsDismiss();
    const key_event = logicalKeyEvent(ev);
    if (overlays.whatsNewVisible()) {
        overlays.whatsNewHandleKey(key_event);
        return input_effects.repaint();
    }
    if (overlays.integrationPromptVisible()) {
        overlays.integrationPromptHandleKey(key_event);
        return input_effects.repaint();
    }
    if (overlays.windowCloseConfirmVisible()) {
        return overlays.windowCloseConfirmHandleKey(key_event);
    }
    if (overlays.transferCancelConfirmVisible()) {
        const result = overlays.transferCancelConfirmHandleKeyEffect(key_event);
        switch (result.action) {
            .interrupt => _ = file_explorer.cancelActiveTransfer(),
            .keep, .none => {},
        }
        return result.effect;
    }
    const action = configuredAction(ev);
    const is_close_shortcut = actionIs(action, .close_panel_or_tab);
    if (!is_close_shortcut and !isModifierKey(ev.key_code)) close_confirm_state.clear();
    if (overlays.sessionLauncherVisible()) {
        if (actionIs(action, .paste)) {
            return if (pasteClipboardIntoSessionLauncher()) .repaint else .none;
        }
        return overlays.sessionLauncherHandleKey(key_event);
    }
    if (action) |app_action| {
        if (handleConfiguredKeybindAction(app_action, .early)) return .none;
    }
    if (overlays.commandPaletteVisible()) {
        const history_visible = overlays.commandPaletteAgentHistoryVisible();
        const palette_action = command_palette_input.keyAction(ev, history_visible);
        applyCommandPaletteAction(palette_action, history_visible);
        return command_palette_input.effectForAction(palette_action);
    }
    if (copilot_picker.isVisible()) {
        switch (ev.key_code) {
            platform_input.key_escape => copilot_picker.hide(),
            platform_input.key_up => copilot_picker.move(-1),
            platform_input.key_down => copilot_picker.move(1),
            platform_input.key_delete => {
                if (!copilot_picker.isNewRowSelected()) {
                    AppWindow.deleteCopilotConversationById(copilot_picker.selectedId());
                    AppWindow.refreshCopilotPickerRows();
                }
            },
            platform_input.key_enter => {
                if (copilot_picker.isNewRowSelected()) {
                    AppWindow.newCopilotConversation();
                } else {
                    AppWindow.loadCopilotConversationById(copilot_picker.selectedId());
                }
                copilot_picker.hide();
            },
            else => {},
        }
        return input_effects.repaint();
    }
    if (jupyter_picker.isVisible()) {
        switch (ev.key_code) {
            platform_input.key_escape => jupyter_picker.hide(),
            platform_input.key_up => jupyter_picker.move(-1),
            platform_input.key_down => jupyter_picker.move(1),
            platform_input.key_enter => {
                const url = jupyter_picker.selectedUrl();
                if (AppWindow.g_allocator) |allocator| {
                    const parent = AppWindow.currentNativeHandle();
                    const surface = AppWindow.activeSurface();
                    browser_panel.setDisplayMode(.full);
                    _ = browser_panel.openForSurface(allocator, parent, url, surface);
                    if (AppWindow.g_window) |win| syncPanelGridFromWindow(win);
                }
                jupyter_picker.hide();
            },
            else => {},
        }
        return input_effects.repaint();
    }
    if (overlays.restoreDefaultsConfirmVisible()) {
        return overlays.restoreDefaultsConfirmHandleKey(key_event);
    }
    if (overlays.settingsPageVisible()) {
        return overlays.settingsPageHandleKey(key_event);
    }
    if (AppWindow.weixin_qr_panel.visible()) {
        switch (ev.key_code) {
            platform_input.key_escape => overlays.weixinQrPanelHandleAction(.close),
            platform_input.key_enter => if (AppWindow.weixin_qr_panel.status() == .expired) overlays.weixinQrPanelHandleAction(.retry),
            else => {},
        }
        return .none;
    }
    // File explorer key handling (when focused and in operation mode)
    if (file_explorer.isFocused() and file_explorer.isVisibleForActiveTab()) {
        if (handleFileExplorerKey(ev)) {
            // Navigation/edits change what the panel draws; request a frame so it
            // updates immediately (same rationale as the wheel-scroll path).
            return input_effects.rebuildOnly();
        }
    }
    // When tab rename is active, handle special keys
    if (tab.g_tab_rename_active) {
        AppWindow.g_cursor_blink_visible = true;
        AppWindow.g_last_blink_time = std.time.milliTimestamp();
        tab.handleRenameKey(key_event);
        return .none;
    }
    if (browser_panel.urlBarFocused()) {
        handleBrowserUrlBarKey(ev);
        return .none;
    }
    if (browser_panel.isVisibleForActiveTab() and !browser_panel.urlBarFocused() and !jupyter_picker.isVisible() and !copilot_picker.isVisible()) {
        if (ev.key_code == platform_input.key_escape) {
            closeBrowserPanel();
            return input_effects.repaint();
        }
    }
    if (assistant_conversation.current(aiCopilotFocused())) |target| {
        // Accept Cmd (super, macOS) or Ctrl (Windows) for chat editing keys.
        const mod = ev.ctrl or ev.super;
        if (mod and !ev.alt and ev.key_code == 0x41) { // select all
            target.session.selectAll();
            return input_effects.repaint();
        }
        if (mod and !ev.alt and ev.key_code == 0x43) { // copy
            copyAiChatToClipboard(target.session);
            return .none;
        }
        if (mod and !ev.alt and ev.key_code == 0x58) { // cut input
            copyAiChatCutToClipboard(target.session);
            return .none;
        }
    }
    if (action) |app_action| {
        if (handleConfiguredKeybindAction(app_action, .late)) return .none;
    }

    if (assistant_conversation.current(aiCopilotFocused())) |target| {
        if (target.isSidebar() and ev.key_code == platform_input.key_escape) {
            if (target.session.requestState().inflight) {
                target.session.stopRequest();
            } else if (target.session.hasSelection()) {
                target.session.clearSelection();
            } else {
                AppWindow.hideAiCopilot();
            }
            return input_effects.repaint();
        }
        if (isAiChatKey(ev)) {
            AppWindow.resetCursorBlink();
            const wrap_cols = if (target.isSidebar()) aiCopilotInputWrapCols() else aiChatInputWrapCols();
            target.session.handleKeyWithWrapCols(key_event, wrap_cols);
            return input_effects.repaint();
        }
    }

    if (AppWindow.activeAiHistory() != null) {
        const plain = !ev.ctrl and !ev.alt and !ev.super;
        // The Search box owns plain typing while focused, so Backspace edits the
        // query there and the single-key Scan/Preview shortcuts stand down — letting
        // their characters fall through to the filter instead.
        const search_focused = AppWindow.aiHistorySearchFocused();
        switch (ev.key_code) {
            platform_input.key_backspace => {
                if (search_focused) _ = AppWindow.aiHistoryBackspaceFilter();
                return .none;
            },
            platform_input.key_up => {
                _ = AppWindow.aiHistoryNav(-1);
                return .none;
            },
            platform_input.key_down => {
                _ = AppWindow.aiHistoryNav(1);
                return .none;
            },
            platform_input.key_left => {
                _ = AppWindow.aiHistoryFocusMove(-1);
                return .none;
            },
            platform_input.key_right => {
                _ = AppWindow.aiHistoryFocusMove(1);
                return .none;
            },
            platform_input.key_enter => {
                _ = AppWindow.aiHistoryLoadSelectedTranscript();
                return .none;
            },
            platform_input.key_page_up => {
                _ = AppWindow.aiHistoryScrollTranscript(-8);
                return .none;
            },
            platform_input.key_page_down => {
                _ = AppWindow.aiHistoryScrollTranscript(8);
                return .none;
            },
            platform_input.key_home => {
                _ = AppWindow.aiHistoryScrollTranscript(-(1 << 30));
                return .none;
            },
            platform_input.key_end => {
                _ = AppWindow.aiHistoryScrollTranscript(1 << 30);
                return .none;
            },
            0x20 => if (plain and AppWindow.aiHistorySpacePreviews()) {
                _ = AppWindow.aiHistoryPreviewSelectedTranscript();
                return .none;
            },
            0x52 => if (plain and !ev.shift and !search_focused) {
                _ = AppWindow.aiHistoryScanLocalNow();
                return .none;
            },
            else => {},
        }
        return .none;
    }

    if (AppWindow.activePortForwarding() != null) {
        const plain = !ev.ctrl and !ev.alt and !ev.super;
        const overlay_kind = AppWindow.portForwardingOverlayKind() orelse .none;
        const form_active = overlay_kind == .form;
        const overlay_active = overlay_kind != .none;
        switch (ev.key_code) {
            platform_input.key_up => {
                if (form_active) {
                    _ = AppWindow.portForwardingFormMove(-1);
                } else if (!overlay_active) {
                    _ = AppWindow.portForwardingMove(-1);
                }
                return .none;
            },
            platform_input.key_down => {
                if (form_active) {
                    _ = AppWindow.portForwardingFormMove(1);
                } else if (!overlay_active) {
                    _ = AppWindow.portForwardingMove(1);
                }
                return .none;
            },
            platform_input.key_left => {
                if (form_active) _ = AppWindow.portForwardingFormAdjust(-1);
                return .none;
            },
            platform_input.key_right => {
                if (form_active) _ = AppWindow.portForwardingFormAdjust(1);
                return .none;
            },
            platform_input.key_tab => {
                if (form_active) _ = AppWindow.portForwardingFormMove(1);
                return .none;
            },
            platform_input.key_enter => {
                if (overlay_active) _ = AppWindow.portForwardingConfirmOrApply();
                return .none;
            },
            platform_input.key_escape => {
                _ = AppWindow.portForwardingCancelOrClose();
                return .none;
            },
            platform_input.key_backspace => {
                if (form_active) _ = AppWindow.portForwardingBackspace();
                return .none;
            },
            platform_input.key_space => if (plain and !ev.shift) {
                if (form_active) {
                    _ = AppWindow.portForwardingFormAdjust(1);
                } else if (!overlay_active) {
                    _ = AppWindow.portForwardingToggleSelected();
                }
                return .none;
            },
            0x4E => if (plain and !ev.shift) {
                if (!overlay_active and AppWindow.portForwardingOpenNew()) {
                    g_port_forwarding_suppress_command_char = 'n';
                }
                return .none;
            },
            0x45 => if (plain and !ev.shift) {
                if (!overlay_active and AppWindow.portForwardingOpenEdit()) {
                    g_port_forwarding_suppress_command_char = 'e';
                }
                return .none;
            },
            0x44 => if (plain and !ev.shift) {
                if (!overlay_active) _ = AppWindow.portForwardingOpenDeleteConfirm();
                return .none;
            },
            0x52 => if (plain and !ev.shift) {
                if (!overlay_active) _ = AppWindow.portForwardingRestartSelected();
                return .none;
            },
            0x41 => if (plain and !ev.shift) {
                if (!overlay_active) _ = AppWindow.portForwardingToggleAutoStart();
                return .none;
            },
            else => {},
        }
        return .none;
    }

    // Skill Center: ↑/↓ move, space preview/toggle, ⏎ confirm, esc cancel,
    // d deploy, i import, t import tool, e toggle, g get-from-GitHub, r rescan.
    // The URL-input overlay captures text; the checklist captures space + 'a'.
    if (AppWindow.activeSkillCenter() != null) {
        switch (AppWindow.skillCenterPreviewKind()) {
            .text => {
                switch (ev.key_code) {
                    platform_input.key_escape, platform_input.key_space, platform_input.key_enter => if (AppWindow.skillCenterPreviewClose()) markSkillCenterInputDirty(),
                    platform_input.key_up => if (AppWindow.skillCenterPreviewScroll(-1)) markSkillCenterInputDirty(),
                    platform_input.key_down => if (AppWindow.skillCenterPreviewScroll(1)) markSkillCenterInputDirty(),
                    platform_input.key_page_up => if (AppWindow.skillCenterPreviewScroll(-12)) markSkillCenterInputDirty(),
                    platform_input.key_page_down => if (AppWindow.skillCenterPreviewScroll(12)) markSkillCenterInputDirty(),
                    platform_input.key_home => if (AppWindow.skillCenterPreviewScroll(-1_000_000)) markSkillCenterInputDirty(),
                    platform_input.key_end => if (AppWindow.skillCenterPreviewScroll(1_000_000)) markSkillCenterInputDirty(),
                    else => {},
                }
                return .none;
            },
            .tool_import_confirm => {
                switch (ev.key_code) {
                    platform_input.key_enter => if (AppWindow.skillCenterOverlaySelect()) markSkillCenterInputDirty(),
                    platform_input.key_escape => if (AppWindow.skillCenterOverlayCancel()) markSkillCenterInputDirty(),
                    platform_input.key_up => if (AppWindow.skillCenterPreviewScroll(-1)) markSkillCenterInputDirty(),
                    platform_input.key_down => if (AppWindow.skillCenterPreviewScroll(1)) markSkillCenterInputDirty(),
                    platform_input.key_page_up => if (AppWindow.skillCenterPreviewScroll(-12)) markSkillCenterInputDirty(),
                    platform_input.key_page_down => if (AppWindow.skillCenterPreviewScroll(12)) markSkillCenterInputDirty(),
                    platform_input.key_home => if (AppWindow.skillCenterPreviewScroll(-1_000_000)) markSkillCenterInputDirty(),
                    platform_input.key_end => if (AppWindow.skillCenterPreviewScroll(1_000_000)) markSkillCenterInputDirty(),
                    else => {},
                }
                return .none;
            },
            .tool_import => {
                switch (ev.key_code) {
                    platform_input.key_enter => if (AppWindow.skillCenterOverlaySelect()) markSkillCenterInputDirty(),
                    platform_input.key_escape => if (AppWindow.skillCenterOverlayCancel()) markSkillCenterInputDirty(),
                    platform_input.key_up => if (AppWindow.skillCenterPreviewScroll(-1)) markSkillCenterInputDirty(),
                    platform_input.key_down => if (AppWindow.skillCenterPreviewScroll(1)) markSkillCenterInputDirty(),
                    platform_input.key_page_up => if (AppWindow.skillCenterPreviewScroll(-12)) markSkillCenterInputDirty(),
                    platform_input.key_page_down => if (AppWindow.skillCenterPreviewScroll(12)) markSkillCenterInputDirty(),
                    platform_input.key_home => if (AppWindow.skillCenterPreviewScroll(-1_000_000)) markSkillCenterInputDirty(),
                    platform_input.key_end => if (AppWindow.skillCenterPreviewScroll(1_000_000)) markSkillCenterInputDirty(),
                    else => {},
                }
                return .none;
            },
            .none => {},
        }
        const plain = !ev.ctrl and !ev.alt and !ev.super;
        const text_capture = AppWindow.skillCenterUrlInputActive();
        const picking = AppWindow.skillCenterPickActive();
        const overlay_active = AppWindow.skillCenterOverlayActive();
        // Ctrl/Cmd+V paste into the URL field.
        if (text_capture and (ev.ctrl or ev.super) and ev.key_code == 0x56) { // 'V'
            if (AppWindow.skillCenterUrlPaste()) markSkillCenterInputDirty();
            return .none;
        }
        switch (ev.key_code) {
            platform_input.key_up => {
                if (AppWindow.skillCenterMove(-1)) markSkillCenterInputDirty();
                return .none;
            },
            platform_input.key_down => {
                if (AppWindow.skillCenterMove(1)) markSkillCenterInputDirty();
                return .none;
            },
            platform_input.key_enter => {
                if (overlay_active) {
                    if (AppWindow.skillCenterOverlaySelect()) markSkillCenterInputDirty();
                } else {
                    if (AppWindow.skillCenterDeploy()) markSkillCenterInputDirty();
                }
                return .none;
            },
            platform_input.key_escape => {
                if (AppWindow.skillCenterOverlayCancel()) markSkillCenterInputDirty();
                return .none;
            },
            platform_input.key_backspace => {
                if (text_capture) {
                    if (AppWindow.skillCenterUrlBackspace()) markSkillCenterInputDirty();
                    return .none;
                }
            },
            0x52 => if (plain and !ev.shift and !text_capture) { // 'R'
                if (AppWindow.skillCenterRescan()) markSkillCenterInputDirty();
                return .none;
            },
            0x44 => if (plain and !ev.shift and !text_capture and !picking and !overlay_active) { // 'D'
                if (AppWindow.skillCenterDeploy()) markSkillCenterInputDirty();
                return .none;
            },
            0x49 => if (plain and !ev.shift and !text_capture and !picking and !overlay_active) { // 'I'
                if (AppWindow.skillCenterImport()) markSkillCenterInputDirty();
                return .none;
            },
            0x54 => if (plain and !ev.shift and !text_capture and !picking and !overlay_active) { // 'T'
                if (AppWindow.skillCenterImportTool()) markSkillCenterInputDirty();
                return .none;
            },
            0x45 => if (plain and !ev.shift and !text_capture and !picking and !overlay_active) { // 'E'
                if (AppWindow.skillCenterToggleToolEnabled()) markSkillCenterInputDirty();
                return .none;
            },
            0x47 => if (plain and !ev.shift and !text_capture and !picking) { // 'G'
                if (AppWindow.skillCenterOpenUrlInput()) markSkillCenterInputDirty();
                // SDL text-input mode also fires a 'g' CHAR event after this
                // key-down; suppress it so it doesn't land in the now-active
                // URL field. (Only 'G' opens a text field, so only it suppresses.)
                g_skill_center_suppress_command_char = 'g';
                return .none;
            },
            0x41 => if (plain and !ev.shift and picking) { // 'A' select-all
                if (AppWindow.skillCenterPickSelectAll()) markSkillCenterInputDirty();
                return .none;
            },
            platform_input.key_space => if (plain and !ev.shift and !text_capture) {
                if (AppWindow.skillCenterSpacePreview()) markSkillCenterInputDirty(); // toggles when picking
                return .none;
            },
            else => {},
        }
        return .none;
    }

    // A focused preview leaf consumes plain navigation keys for scroll/pan.
    // Only engaged when a preview actually holds focus; otherwise this block is
    // skipped entirely and terminal/copilot key handling is unchanged. Modified
    // keys (ctrl/shift/alt/super) are left for keybinds and the terminal.
    if (AppWindow.focusedPreviewPane()) |p| {
        if (!ev.ctrl and !ev.shift and !ev.alt and !ev.super) {
            var consumed = true;
            switch (ev.key_code) {
                platform_input.key_page_up => if (p.kind == .pdf) {
                    _ = p.flipPdfPage(false);
                } else p.scrollBy(-360),
                platform_input.key_page_down => if (p.kind == .pdf) {
                    _ = p.flipPdfPage(true);
                } else p.scrollBy(360),
                platform_input.key_up => if (p.kind.isRaster()) {
                    _ = p.panImageBy(0, 40);
                } else p.scrollBy(-60),
                platform_input.key_down => if (p.kind.isRaster()) {
                    _ = p.panImageBy(0, -40);
                } else p.scrollBy(60),
                platform_input.key_left => if (p.kind.isRaster()) {
                    _ = openPreviewGalleryNeighbor(p, false);
                } else {
                    consumed = false;
                },
                platform_input.key_right => if (p.kind.isRaster()) {
                    _ = openPreviewGalleryNeighbor(p, true);
                } else {
                    consumed = false;
                },
                platform_input.key_home => p.scrollBy(-1_000_000),
                platform_input.key_end => p.scrollBy(1_000_000),
                else => consumed = false,
            }
            if (consumed) {
                return input_effects.repaint();
            }
        }
    }

    // Don't send input to PTY if active tab isn't the terminal
    if (!AppWindow.isActiveTabTerminal()) return .none;

    const surface = AppWindow.activeSurface() orelse return .none;

    // Track whether this keypress actually sends data to the PTY.
    // Like Ghostty, we only scroll-to-bottom when input is actually generated,
    // not for modifier-only keys or key combos that don't produce PTY output.
    var wrote_to_pty = false;

    // Scratch buffer for Kitty keyboard protocol key encoding. Only used by the
    // Enter/Backspace/Tab arms below; harmless otherwise.
    var kitty_buf: [128]u8 = undefined;

    const seq: ?[]const u8 = switch (ev.key_code) {
        platform_input.key_enter => terminalSpecialKeySeq(surface, ev, .enter, &kitty_buf, "\r"),
        platform_input.key_backspace => terminalSpecialKeySeq(surface, ev, .backspace, &kitty_buf, "\x7f"),
        platform_input.key_tab => terminalSpecialKeySeq(surface, ev, .tab, &kitty_buf, if (ev.shift) "\x1b[Z" else "\t"),
        platform_input.key_escape => "\x1b",
        platform_input.key_up, platform_input.key_down, platform_input.key_right, platform_input.key_left => input_shortcuts.terminalArrowSequence(key_event, surface.terminal.modes.get(.cursor_keys)),
        platform_input.key_home => "\x1b[H",
        platform_input.key_end => "\x1b[F",
        platform_input.key_page_up => blk: { // Page Up
            if (ev.shift) {
                surface.render_state.mutex.lock();
                surface.terminal.scrollViewport(.{ .delta = -@as(isize, AppWindow.term_rows / 2) });
                surface.render_state.mutex.unlock();
                overlays.scrollbarShow();
                break :blk null;
            }
            break :blk "\x1b[5~";
        },
        platform_input.key_page_down => blk: { // Page Down
            if (ev.shift) {
                surface.render_state.mutex.lock();
                surface.terminal.scrollViewport(.{ .delta = @as(isize, AppWindow.term_rows / 2) });
                surface.render_state.mutex.unlock();
                overlays.scrollbarShow();
                break :blk null;
            }
            break :blk "\x1b[6~";
        },
        platform_input.key_insert => "\x1b[2~",
        platform_input.key_delete => "\x1b[3~",
        else => blk: {
            // Ctrl+A through Ctrl+Z
            if (ev.ctrl and ev.key_code >= 0x41 and ev.key_code <= 0x5A) {
                // Shifted Ctrl+letter chords are application shortcuts above.
                if (!ev.shift) {
                    const ctrl_char: u8 = @intCast(ev.key_code - 0x41 + 1);
                    writeToPty(surface, &[_]u8{ctrl_char});
                    wrote_to_pty = true;
                }
            }
            break :blk null;
        },
    };

    if (seq) |s| {
        writeToPty(surface, s);
        wrote_to_pty = true;
    }

    // Only scroll to bottom and reset cursor blink when we actually sent
    // data to the PTY. This matches Ghostty's behavior: modifier-only keys,
    // unbound key combos (like Shift+Alt+4), and scroll keys don't snap
    // the viewport to the bottom.
    if (wrote_to_pty) {
        AppWindow.resetCursorBlink();
        surface.render_state.mutex.lock();
        surface.terminal.scrollViewport(.bottom);
        surface.render_state.mutex.unlock();
    }
    return .none;
}

fn isModifierKey(key_code: platform_input.KeyCode) bool {
    return key_code == platform_input.key_shift or
        key_code == platform_input.key_control or
        key_code == platform_input.key_alt or
        key_code == platform_input.key_left_shift or
        key_code == platform_input.key_right_shift or
        key_code == platform_input.key_left_control or
        key_code == platform_input.key_right_control or
        key_code == platform_input.key_left_alt or
        key_code == platform_input.key_right_alt;
}

fn isAiChatKey(ev: platform_input.KeyEvent) bool {
    if (ev.key_code == platform_input.key_enter or
        ev.key_code == platform_input.key_backspace or
        ev.key_code == platform_input.key_delete or
        ev.key_code == platform_input.key_left or
        ev.key_code == platform_input.key_right or
        ev.key_code == platform_input.key_up or
        ev.key_code == platform_input.key_down or
        ev.key_code == platform_input.key_home or
        ev.key_code == platform_input.key_end or
        ev.key_code == platform_input.key_tab or
        ev.key_code == platform_input.key_escape) return true;
    if (ev.ctrl and !ev.alt and (ev.key_code == 0x41 or ev.key_code == 0x55 or ev.key_code == 0x4C)) return true; // Ctrl+A / Ctrl+U / Ctrl+L
    return false;
}

fn aiChatInputWrapCols() usize {
    const win = AppWindow.g_window orelse return std.math.maxInt(usize);
    const size = clientSize(win);
    const ww: f32 = @floatFromInt(size.width);
    const panel_w = @max(1.0, ww - AppWindow.leftPanelsWidth() - AppWindow.rightPanelsWidth());
    return AppWindow.assistant_conversation_renderer.inputWrapColumns(panel_w);
}

/// Wrap columns for the AI copilot sidebar's composer. Mirrors
/// `aiChatInputWrapCols` but uses the sidebar/copilot panel width rather than
/// the full-tab chat width.
fn aiCopilotInputWrapCols() usize {
    const win = AppWindow.g_window orelse return std.math.maxInt(usize);
    const size = clientSize(win);
    const panel_w = AppWindow.aiCopilotWidth(size.width);
    return AppWindow.assistant_conversation_renderer.inputWrapColumns(panel_w);
}

fn handleBrowserUrlBarKey(ev: platform_input.KeyEvent) void {
    // Accept Cmd (super, macOS) or Ctrl (Windows) for text-field editing keys.
    const mod = ev.ctrl or ev.super;
    if (mod and !ev.shift and !ev.alt and ev.key_code == 0x41) { // Ctrl/Cmd+A
        browser_panel.selectAllUrlBar();
        markBrowserUrlBarDirty();
        return;
    }
    if (mod and !ev.shift and !ev.alt and ev.key_code == 0x56) { // Ctrl/Cmd+V
        if (pasteClipboardIntoBrowserUrlBar()) markBrowserUrlBarDirty();
        return;
    }

    switch (ev.key_code) {
        platform_input.key_escape => {
            browser_panel.blurUrlBar();
            markBrowserUrlBarDirty();
        },
        platform_input.key_enter => {
            const allocator = AppWindow.g_allocator orelse return;
            const parent = AppWindow.currentNativeHandle();
            _ = browser_panel.submitUrlBar(allocator, parent, AppWindow.activeSurface());
            markBrowserUrlBarDirty();
        },
        platform_input.key_backspace => {
            browser_panel.backspaceUrlBar();
            markBrowserUrlBarDirty();
        },
        platform_input.key_delete => {
            browser_panel.clearUrlBar();
            markBrowserUrlBarDirty();
        },
        else => {},
    }
}

fn sidebarLayout() hit_test.SidebarLayout {
    return .{
        .visible = tab.g_sidebar_visible,
        .titlebar_h = titlebarHeight(),
        .width = @floatCast(titlebar.sidebarWidth()),
        .header_h = @floatCast(titlebar.sidebarHeaderHeight()),
        .row_h = @floatCast(titlebar.sidebarRowHeight()),
        .tab_count = tab.g_tab_count,
        .resize_hit_width = @floatCast(titlebar.SIDEBAR_RESIZE_HIT_WIDTH),
        .close_btn_w = @floatCast(tab.TAB_CLOSE_BTN_W),
    };
}

fn hitTestSidebarTab(xpos: f64, ypos: f64) ?usize {
    return hit_test.sidebarTabAt(sidebarLayout(), xpos, ypos);
}

fn resetSidebarTabDragState() void {
    g_sidebar_tab_drag_pressed = null;
    g_sidebar_tab_drag_current = null;
    g_sidebar_tab_drag_start_x = 0;
    g_sidebar_tab_drag_start_y = 0;
    g_sidebar_tab_drag_active = false;
}

fn beginSidebarTabPotentialDrag(tab_idx: usize, xpos: f64, ypos: f64) void {
    if (tab.g_tab_count <= 1) return;
    g_sidebar_tab_drag_pressed = tab_idx;
    g_sidebar_tab_drag_current = tab_idx;
    g_sidebar_tab_drag_start_x = xpos;
    g_sidebar_tab_drag_start_y = ypos;
    g_sidebar_tab_drag_active = false;
}

fn sidebarTabIndexForDragY(ypos: f64) ?usize {
    return hit_test.sidebarTabIndexForDragY(sidebarLayout(), ypos);
}

fn updateSidebarTabDrag(xpos: f64, ypos: f64) bool {
    const current = g_sidebar_tab_drag_current orelse return false;
    if (!tab.g_sidebar_visible or tab.g_tab_count <= 1 or current >= tab.g_tab_count) {
        resetSidebarTabDragState();
        return false;
    }

    if (!g_sidebar_tab_drag_active) {
        const dx = xpos - g_sidebar_tab_drag_start_x;
        const dy = ypos - g_sidebar_tab_drag_start_y;
        const distance = @sqrt(dx * dx + dy * dy);
        if (distance < SIDEBAR_TAB_DRAG_THRESHOLD_PX) return true;
        g_sidebar_tab_drag_active = true;
        g_selecting = false;
    }

    const target = sidebarTabIndexForDragY(ypos) orelse return true;
    if (target != current and AppWindow.reorderTab(current, target)) {
        g_sidebar_tab_drag_current = target;
    }

    return true;
}

fn finishSidebarTabDrag() bool {
    const consumed = g_sidebar_tab_drag_pressed != null or g_sidebar_tab_drag_active;
    resetSidebarTabDragState();
    return consumed;
}

fn hitTestSidebarPlusButton(xpos: f64, ypos: f64) bool {
    return hit_test.sidebarPlusButton(sidebarLayout(), xpos, ypos);
}

fn hitTestSidebarTabCloseButton(xpos: f64, ypos: f64, tab_idx: usize) bool {
    return hit_test.sidebarTabCloseButton(sidebarLayout(), xpos, ypos, tab_idx);
}

fn shouldStartSidebarTabRename(xpos: f64, ypos: f64, tab_idx: usize) bool {
    if (tab_idx >= tab.g_tab_count) return false;
    const layout = sidebarLayout();
    if (hit_test.sidebarPlusButton(layout, xpos, ypos)) return false;
    if (hit_test.sidebarResizeHandle(layout, xpos, ypos)) return false;
    if (hit_test.sidebarTabCloseButton(layout, xpos, ypos, tab_idx)) return false;
    return true;
}

fn hitTestSidebarResizeHandle(xpos: f64, ypos: f64) bool {
    return hit_test.sidebarResizeHandle(sidebarLayout(), xpos, ypos);
}

fn applySidebarWidthFromMouse(xpos: f64) void {
    const win = AppWindow.g_window orelse return;
    const size = clientSize(win);
    if (!titlebar.setSidebarWidth(@floatCast(xpos), @floatFromInt(size.width))) return;
    syncGridFromWindow(win);
    syncSidebarWidthToBackend(win);
    requestInputRepaint();
}

fn hitTestFileExplorer(xpos: f64, ypos: f64) bool {
    if (!file_explorer.isVisibleForActiveTab()) return false;
    if (ypos < titlebarHeight()) return false;
    const panel_x: f64 = @floatCast(titlebar.sidebarWidth());
    const panel_right = panel_x + @as(f64, @floatCast(file_explorer.width()));
    return xpos >= panel_x and xpos < panel_right;
}

fn fileExplorerHeaderLayout() ?hit_test.PanelHeaderLayout {
    if (!file_explorer.isVisibleForActiveTab()) return null;
    const panel_x: f64 = @floatCast(titlebar.sidebarWidth());
    const panel_right = panel_x + @as(f64, @floatCast(file_explorer.width()));
    return .{
        .visible = true,
        .left = panel_x,
        .right = panel_right,
        .top = titlebarHeight(),
        .height = @floatCast(file_explorer.headerHeight()),
    };
}

fn hitTestFileExplorerCloseButton(xpos: f64, ypos: f64) bool {
    return hit_test.panelHeaderCloseButton(fileExplorerHeaderLayout() orelse return false, xpos, ypos);
}

fn hitTestFileExplorerRefreshButton(xpos: f64, ypos: f64) bool {
    return hit_test.panelHeaderSecondButton(fileExplorerHeaderLayout() orelse return false, xpos, ypos);
}

fn browserPanelBounds() ?browser_panel.Bounds {
    if (!browser_panel.isVisibleForActiveTab()) return null;
    const win = AppWindow.g_window orelse return null;
    const size = clientSize(win);
    return browser_panel.boundsForWindow(
        size.width,
        size.height,
        @floatCast(titlebarHeight()),
        AppWindow.leftPanelsWidth(),
        AppWindow.browserPanelRightOffset(),
    );
}

fn hitTestBrowserPanel(xpos: f64, ypos: f64) bool {
    const bounds = browserPanelBounds() orelse return false;
    return xpos >= @as(f64, @floatFromInt(bounds.left)) and
        xpos < @as(f64, @floatFromInt(bounds.right)) and
        ypos >= @as(f64, @floatFromInt(bounds.top)) and
        ypos < @as(f64, @floatFromInt(bounds.bottom));
}

fn hitTestBrowserUrlBar(xpos: f64, ypos: f64) bool {
    const bounds = browserPanelBounds() orelse return false;
    const url_bar = browser_panel.urlBarBounds(bounds) orelse return false;
    return xpos >= @as(f64, @floatFromInt(url_bar.left)) and
        xpos < @as(f64, @floatFromInt(url_bar.right)) and
        ypos >= @as(f64, @floatFromInt(url_bar.top)) and
        ypos < @as(f64, @floatFromInt(url_bar.bottom));
}

fn browserHeaderLayout() ?hit_test.PanelHeaderLayout {
    const bounds = browserPanelBounds() orelse return null;
    const url_bar = browser_panel.urlBarBounds(bounds) orelse return null;
    return .{
        .visible = true,
        .left = @floatFromInt(url_bar.left),
        .right = @floatFromInt(url_bar.right),
        .top = @floatFromInt(url_bar.top),
        .height = @floatFromInt(url_bar.bottom - url_bar.top),
    };
}

fn hitTestBrowserCloseButton(xpos: f64, ypos: f64) bool {
    return hit_test.panelHeaderCloseButton(browserHeaderLayout() orelse return false, xpos, ypos);
}

fn hitTestBrowserToggleButton(xpos: f64, ypos: f64) bool {
    return hit_test.panelHeaderSecondButton(browserHeaderLayout() orelse return false, xpos, ypos);
}

fn hitTestBrowserRefreshButton(xpos: f64, ypos: f64) bool {
    return hit_test.panelHeaderButton(browserHeaderLayout() orelse return false, 2, xpos, ypos);
}

fn toggleBrowserDisplayMode() void {
    browser_panel.setDisplayMode(if (browser_panel.displayMode() == .full) .side else .full);
    if (AppWindow.g_window) |win| {
        syncPanelGridFromWindow(win);
    }
    requestInputRepaint();
}

fn aiCopilotHeaderLayout() ?hit_test.PanelHeaderLayout {
    if (!AppWindow.aiCopilotVisible()) return null;
    const win = AppWindow.g_window orelse return null;
    const metrics = windowMetrics(win);
    const bounds = ai_sidebar.boundsForWindow(
        @intCast(metrics.framebuffer_width),
        @intCast(metrics.framebuffer_height),
        @floatCast(metrics.titlebar_h),
        AppWindow.leftPanelsWidth(),
        0,
    );
    return .{
        .visible = true,
        .left = @floatFromInt(bounds.left),
        .right = @floatFromInt(bounds.right),
        .top = @floatFromInt(bounds.top),
        .height = @floatCast(AppWindow.assistant_conversation_renderer.HEADER_H),
    };
}

fn hitTestAiCopilotCloseButton(xpos: f64, ypos: f64) bool {
    return hit_test.panelHeaderCloseButton(aiCopilotHeaderLayout() orelse return false, xpos, ypos);
}

fn hitTestBrowserResizeHandle(xpos: f64, ypos: f64) bool {
    if (!browser_panel.isVisibleForActiveTab()) return false;
    if (ypos < titlebarHeight()) return false;
    const bounds = browserPanelBounds() orelse return false;
    const panel_x: f64 = @floatFromInt(bounds.left);
    const half_hit: f64 = @as(f64, @floatCast(browser_panel.RESIZE_HIT_WIDTH)) / 2;
    return xpos >= panel_x - half_hit and xpos <= panel_x + half_hit;
}

fn applyBrowserWidthFromMouse(xpos: f64) void {
    const win = AppWindow.g_window orelse return;
    const size = clientSize(win);
    const right_edge = @as(f64, @floatFromInt(size.width)) - @as(f64, @floatCast(AppWindow.browserPanelRightOffset()));
    const new_width = right_edge - xpos;
    const available_width: f32 = @as(f32, @floatFromInt(size.width)) - AppWindow.leftPanelsWidth() - AppWindow.browserPanelRightOffset();
    if (!browser_panel.setWidth(@floatCast(new_width), available_width)) return;
    syncGridFromWindow(win);
    requestInputRepaint();
}

// AI copilot panel resize grip. The copilot is right-docked (right_offset 0)
// and its bounds are computed against framebufferSize everywhere (renderer +
// click handling), so the hit-test/apply mirror the browser resize structure
// but read the framebuffer size to track the panel's actual left edge.
fn hitTestAiCopilotResizeHandle(xpos: f64, ypos: f64) bool {
    if (!AppWindow.aiCopilotVisible()) return false;
    if (ypos < titlebarHeight()) return false;
    const win = AppWindow.g_window orelse return false;
    const metrics = windowMetrics(win);
    const bounds = ai_sidebar.boundsForWindow(
        @intCast(metrics.framebuffer_width),
        @intCast(metrics.framebuffer_height),
        @floatCast(metrics.titlebar_h),
        AppWindow.leftPanelsWidth(),
        0,
    );
    const panel_x: f64 = @floatFromInt(bounds.left);
    const half_hit: f64 = @as(f64, @floatCast(ai_sidebar.RESIZE_HIT_WIDTH)) / 2;
    return xpos >= panel_x - half_hit and xpos <= panel_x + half_hit;
}

/// Hit-test the closed-state Copilot summon handle (valid only when Copilot is
/// closed). Widens the click zone for comfort without a heavier visual.
fn hitTestCopilotEdgeHandle(xpos: f64, ypos: f64) bool {
    // Must match the render + mouse-move eligibility exactly, or this becomes an
    // invisible click-band that steals clicks (e.g. from the scrollbar when the
    // feature is disabled, or from a browser/Jupyter panel sharing the slot).
    if (!copilot_hint_gate.handleEligible(
        AppWindow.g_copilot_hint,
        AppWindow.aiCopilotVisible(),
        AppWindow.isActiveTabTerminal(),
        AppWindow.anyRightDockPanelVisible(),
    )) return false;
    if (ypos < titlebarHeight()) return false;
    const win = AppWindow.g_window orelse return false;
    const metrics = windowMetrics(win);
    const rect = ai_sidebar.closedHandleRect(
        @floatFromInt(metrics.framebuffer_width),
        @floatFromInt(metrics.framebuffer_height),
        @floatCast(metrics.titlebar_h),
        AppWindow.leftPanelsWidth(),
    );
    if (!rect.eligible) return false;
    const hit_w: f64 = @max(@as(f64, @floatCast(rect.w)), 12);
    const right: f64 = @floatFromInt(metrics.framebuffer_width);
    const top: f64 = @floatCast(rect.y);
    const bottom: f64 = @floatCast(rect.y + rect.h);
    return xpos >= right - hit_w and ypos >= top and ypos <= bottom;
}

fn applyAiCopilotWidthFromMouse(xpos: f64) void {
    const win = AppWindow.g_window orelse return;
    const metrics = windowMetrics(win);
    // Right-docked at the far right edge (right_offset 0): width grows as the
    // mouse moves left, same as the browser's right-edge math.
    const right_edge = @as(f64, @floatFromInt(metrics.framebuffer_width));
    const new_width = right_edge - xpos;
    const available_width: f32 = @as(f32, @floatFromInt(metrics.framebuffer_width)) - AppWindow.leftPanelsWidth();
    if (!ai_sidebar.setWidth(@floatCast(new_width), available_width)) return;
    syncGridFromWindow(win);
    requestInputRepaint();
}

fn hitTestFileExplorerResizeHandle(xpos: f64, ypos: f64) bool {
    if (!file_explorer.isVisibleForActiveTab()) return false;
    if (ypos < titlebarHeight()) return false;
    const panel_x: f64 = @floatCast(titlebar.sidebarWidth());
    const panel_right = panel_x + @as(f64, @floatCast(file_explorer.width()));
    const half_hit: f64 = @as(f64, @floatCast(file_explorer.RESIZE_HIT_WIDTH)) / 2;
    return xpos >= panel_right - half_hit and xpos <= panel_right + half_hit;
}

fn applyExplorerWidthFromMouse(xpos: f64) void {
    const win = AppWindow.g_window orelse return;
    const size = clientSize(win);
    const panel_x: f64 = @floatCast(titlebar.sidebarWidth());
    const new_width = xpos - panel_x;
    if (!file_explorer.setWidth(@floatCast(new_width), @floatFromInt(size.width))) return;
    syncGridFromWindow(win);
    requestInputRepaint();
}

fn handleFileExplorerKey(ev: platform_input.KeyEvent) bool {
    if (file_explorer.isAgentHistoryPanel()) {
        return handleAgentHistoryKey(ev);
    }

    const key_escape = platform_input.key_escape;
    const key_enter = platform_input.key_enter;
    const key_backspace = platform_input.key_backspace;
    const key_up = platform_input.key_up;
    const key_down = platform_input.key_down;

    // In input mode (rename/new file/new dir)
    if (file_explorer.hasActiveOp()) {
        switch (ev.key_code) {
            key_escape => {
                file_explorer.cancelOp();
                return true;
            },
            key_enter => {
                file_explorer.commitOp();
                return true;
            },
            key_backspace => {
                file_explorer.inputBackspace();
                return true;
            },
            else => return false,
        }
    }

    // Normal navigation mode
    switch (ev.key_code) {
        key_escape => {
            file_explorer.blur();
            return true;
        },
        key_up, key_down, key_enter => {
            // Navigation keys route through a domain-owned action so this branch
            // asks file_explorer to perform the intent instead of calling its
            // internals directly. fromNavigationKey owns exactly these keys.
            if (file_explorer_keymap.fromNavigationKey(ev.key_code)) |action| {
                file_explorer.handleAction(action);
            }
            return true;
        },
        0x53 => { // 'S' key: Ctrl/Cmd+S = download selected file
            if ((ev.ctrl or ev.super) and !ev.alt and !ev.shift) {
                if (file_explorer.isRemoteMode()) {
                    // Download to user's Downloads folder
                    var dl_buf: [260]u8 = undefined;
                    const dl_path = getDownloadsFolder(&dl_buf);
                    if (dl_path.len > 0) {
                        file_explorer.downloadSelected(dl_path);
                    }
                    return true;
                }
            }
            return false;
        },
        0x55 => { // 'U' = upload file; Shift+U = upload folder
            if (file_explorer.isRemoteMode() and !ev.ctrl and !ev.alt and !ev.super) {
                if (ev.shift) {
                    openFolderDialogAndUpload();
                } else {
                    openFileDialogAndUpload();
                }
                return true;
            }
            return false;
        },
        else => {
            if (file_explorer_keymap.fromOperationKey(ev)) |action| {
                file_explorer.handleAction(action);
                return true;
            }
            return false;
        },
    }
}

fn handleAgentHistoryKey(ev: platform_input.KeyEvent) bool {
    switch (ev.key_code) {
        platform_input.key_escape => {
            file_explorer.blur();
            return true;
        },
        platform_input.key_up => {
            file_explorer.moveHistorySelection(-1);
            return true;
        },
        platform_input.key_down => {
            file_explorer.moveHistorySelection(1);
            return true;
        },
        platform_input.key_enter => {
            activateSelectedAgentHistoryRow();
            return true;
        },
        platform_input.key_delete => {
            deleteSelectedAgentHistoryRow();
            return true;
        },
        0x44 => { // 'D' key = delete history row
            if (!ev.ctrl and !ev.alt and !ev.shift and !ev.super) {
                deleteSelectedAgentHistoryRow();
                return true;
            }
            return false;
        },
        else => return false,
    }
}

fn getDownloadsFolder(buf: *[260]u8) []const u8 {
    const downloads = platform_dirs.downloadsDir(std.heap.page_allocator) catch return "";
    defer std.heap.page_allocator.free(downloads);
    if (downloads.len > buf.len) return "";
    @memcpy(buf[0..downloads.len], downloads);
    return buf[0..downloads.len];
}

fn openFileDialogAndUpload() void {
    const allocator = AppWindow.g_allocator orelse return;
    const filters = [_]platform_file_dialog.Filter{.{ .name = "All Files", .pattern = "*.*" }};
    const owner: platform_file_dialog.Owner = if (AppWindow.currentNativeHandleBits()) |handle_bits|
        platform_file_dialog.windowOwner(handle_bits)
    else
        .{};
    const path = platform_file_dialog.openFile(allocator, .{
        .owner = owner,
        .title = "Upload file to remote",
        .filters = &filters,
    }) orelse return;
    defer allocator.free(path);

    file_explorer.uploadFile(path);
}

fn openFolderDialogAndUpload() void {
    const allocator = AppWindow.g_allocator orelse return;
    const filters = [_]platform_file_dialog.Filter{.{ .name = "All Files", .pattern = "*.*" }};
    const owner: platform_file_dialog.Owner = if (AppWindow.currentNativeHandleBits()) |handle_bits|
        platform_file_dialog.windowOwner(handle_bits)
    else
        .{};
    const path = platform_file_dialog.pickFolder(allocator, .{
        .owner = owner,
        .title = "Upload folder to remote",
        .filters = &filters,
    }) orelse return;
    defer allocator.free(path);

    file_explorer.uploadFolder(path);
}

fn handleFileExplorerPress(xpos: f64, ypos: f64, ctrl: bool, shift: bool, alt: bool, super: bool) void {
    file_explorer.focus();

    // Check resize handle first
    if (hitTestFileExplorerResizeHandle(xpos, ypos)) {
        g_explorer_resize_dragging = true;
        g_explorer_resize_hover = true;
        platform_cursor.set(.size_we);
        return;
    }

    if (file_explorer.isAgentHistoryPanel()) {
        handleAgentHistoryPress(xpos, ypos);
        return;
    }

    // Cancel any active op on click elsewhere in the panel
    if (file_explorer.hasActiveOp()) {
        file_explorer.cancelOp();
    }

    // Click on a file entry
    const panel_x: f64 = @floatCast(titlebar.sidebarWidth());
    const panel_right = panel_x + @as(f64, @floatCast(file_explorer.width()));
    if (xpos < panel_x or xpos >= panel_right) return;

    const titlebar_h = titlebarHeight();
    const header_h: f64 = @floatCast(file_explorer.headerHeight());
    const list_top = titlebar_h + header_h;
    if (ypos < list_top) return;

    if (file_explorer.rowIndexAtListY(ypos - list_top)) |row_idx| {
        const click_count = nextLeftClickCount(xpos, ypos);
        const entry = file_explorer.selectEntry(row_idx) orelse return;
        if (!entry.is_dir and ((primaryOpenMod(ctrl, super) and !shift and !alt) or click_count == 2)) {
            if (openFileExplorerPreview(entry)) {
                requestInputRebuild();
                return;
            }
        }
        _ = file_explorer.toggleDirectoryAt(row_idx);
        requestInputRebuild();
    }
}

fn handleAgentHistoryPress(xpos: f64, ypos: f64) void {
    const panel_x: f64 = @floatCast(titlebar.sidebarWidth());
    const panel_right = panel_x + @as(f64, @floatCast(file_explorer.width()));
    if (xpos < panel_x or xpos >= panel_right) return;

    const titlebar_h = titlebarHeight();
    const header_h: f64 = @floatCast(file_explorer.headerHeight());
    const list_top = titlebar_h + header_h;
    if (ypos < list_top) return;

    const row_h: f64 = @floatCast(file_explorer.rowHeight());
    const scroll: f64 = @floatCast(file_explorer.g_history_scroll_offset);
    const row_idx: usize = @intFromFloat((ypos - list_top + scroll) / row_h);
    if (row_idx >= file_explorer.g_history_row_count) return;

    const click_count = nextLeftClickCount(xpos, ypos);
    file_explorer.g_history_selected = row_idx;
    if (click_count == 2) {
        activateSelectedAgentHistoryRow();
        return;
    }
    requestInputRebuild();
}

fn activateSelectedAgentHistoryRow() void {
    const session_id = file_explorer.selectedHistorySessionId() orelse return;
    file_explorer.blur();
    if (!AppWindow.reopenAiChatTabFromHistorySessionId(session_id)) return;
    file_explorer.blur();
}

fn deleteSelectedAgentHistoryRow() void {
    const session_id = file_explorer.selectedHistorySessionId() orelse return;
    if (!AppWindow.deleteAiChatHistorySessionId(session_id)) return;
    AppWindow.syncFileExplorerAgentHistoryRows();
    requestInputRepaint();
}

fn hitTestConfigButton(xpos: f64, ypos: f64) bool {
    const titlebar_h = titlebarHeight();
    if (ypos < 0 or ypos >= titlebar_h) return false;

    const win = AppWindow.g_window orelse return false;
    const size = clientSize(win);
    const window_width: f64 = @floatFromInt(size.width);
    const caption_w: f64 = 46 * 3;
    const config_w: f64 = @floatCast(titlebar.TITLEBAR_CONFIG_W);
    const config_x = window_width - caption_w - config_w;
    return xpos >= config_x and xpos < config_x + config_w;
}

fn hitTestHelpButton(xpos: f64, ypos: f64) bool {
    const titlebar_h = titlebarHeight();
    if (ypos < 0 or ypos >= titlebar_h) return false;

    const win = AppWindow.g_window orelse return false;
    const size = clientSize(win);
    const window_width: f64 = @floatFromInt(size.width);
    const caption_w: f64 = 46 * 3;
    const config_w: f64 = @floatCast(titlebar.TITLEBAR_CONFIG_W);
    const help_w: f64 = @floatCast(titlebar.TITLEBAR_HELP_W);
    const help_x = window_width - caption_w - config_w - help_w;
    return xpos >= help_x and xpos < help_x + help_w;
}

fn hitTestCopilotButton(xpos: f64, ypos: f64) bool {
    const titlebar_h = titlebarHeight();
    if (ypos < 0 or ypos >= titlebar_h) return false;
    if (titlebar.TITLEBAR_COPILOT_W <= 0) return false;
    const win = AppWindow.g_window orelse return false;
    const size = clientSize(win);
    const window_width: f64 = @floatFromInt(size.width);
    const caption_w: f64 = 46 * 3;
    const config_w: f64 = @floatCast(titlebar.TITLEBAR_CONFIG_W);
    const help_w: f64 = @floatCast(titlebar.TITLEBAR_HELP_W);
    const copilot_w: f64 = @floatCast(titlebar.TITLEBAR_COPILOT_W);
    const copilot_x = window_width - caption_w - config_w - help_w - copilot_w;
    return xpos >= copilot_x and xpos < copilot_x + copilot_w;
}

fn handleTopbarPress(xpos: f64) void {
    const toggle_x: f64 = @floatCast(titlebar.titlebarLeftReserved());
    const toggle_end: f64 = toggle_x + @as(f64, titlebar.TITLEBAR_TOGGLE_W);
    if (xpos >= toggle_x and xpos < toggle_end) {
        toggleSidebar();
        return;
    }

    if (hitTestCopilotButton(xpos, titlebarHeight() / 2)) {
        AppWindow.toggleAiCopilot();
        return;
    }

    if (hitTestHelpButton(xpos, titlebarHeight() / 2)) {
        overlays.startupShortcutsToggle();
        return;
    }

    if (hitTestConfigButton(xpos, titlebarHeight() / 2)) {
        overlays.settingsPageOpen();
    }
}

fn handleSidebarPress(xpos: f64, ypos: f64) void {
    if (tab.g_tab_rename_active) tab.commitTabRename();

    if (hitTestSidebarPlusButton(xpos, ypos)) {
        overlays.sessionLauncherOpen();
        return;
    }

    if (hitTestSidebarTab(xpos, ypos)) |tab_idx| {
        if (tab.g_tab_count > 1 and tab.g_tab_close_opacity[tab_idx] > 0.1 and hitTestSidebarTabCloseButton(xpos, ypos, tab_idx)) {
            resetSidebarTabDragState();
            tab.g_tab_close_pressed = tab_idx;
            return;
        }
        beginSidebarTabPotentialDrag(tab_idx, xpos, ypos);
        AppWindow.switchTab(tab_idx);
    }
}

fn viewportCellCodepoint(surface: *Surface, col: usize, row: usize) u21 {
    const cell_data = surface.terminal.screens.active.pages.getCell(.{ .viewport = .{
        .x = @intCast(col),
        .y = @intCast(row),
    } }) orelse return 0;
    return @intCast(cell_data.cell.codepoint());
}

fn viewportRowFlags(surface: *Surface, row: usize) struct { wraps_next: bool, continues_from_prev: bool } {
    const row_pin = surface.terminal.screens.active.pages.pin(.{ .viewport = .{
        .x = 0,
        .y = @intCast(row),
    } }) orelse return .{ .wraps_next = false, .continues_from_prev = false };
    const rac = row_pin.rowAndCell();
    return .{
        .wraps_next = rac.row.wrap,
        .continues_from_prev = rac.row.wrap_continuation,
    };
}

const TerminalTokenGrid = struct {
    surface: *Surface,
    rows: usize,
    cols: usize,

    pub fn rowCount(self: TerminalTokenGrid) usize {
        return self.rows;
    }

    pub fn colCount(self: TerminalTokenGrid, row: usize) usize {
        _ = row;
        return self.cols;
    }

    pub fn codepoint(self: TerminalTokenGrid, row: usize, col: usize) u21 {
        return viewportCellCodepoint(self.surface, col, row);
    }

    pub fn wrapsNext(self: TerminalTokenGrid, row: usize) bool {
        return viewportRowFlags(self.surface, row).wraps_next;
    }

    pub fn continuesFromPrev(self: TerminalTokenGrid, row: usize) bool {
        return viewportRowFlags(self.surface, row).continues_from_prev;
    }
};

fn markSelectionChanged() void {
    g_selection_changed_for_copy = true;
    requestInputRepaint();
}

fn nextLeftClickCount(xpos: f64, ypos: f64) u8 {
    const now = std.time.milliTimestamp();
    const max_distance: f64 = @floatCast(@max(font.cell_width, font.cell_height));
    return g_left_click_tracker.register(xpos, ypos, now, max_distance, MULTI_CLICK_INTERVAL_MS);
}

fn resetLeftClickCount() void {
    g_left_click_tracker.reset();
}

fn readViewportRowLocked(surface: *Surface, row: usize, buf: *[MAX_SELECTION_COLS]u21) []const u21 {
    const cols = @min(@as(usize, @intCast(surface.size.grid.cols)), buf.len);
    if (row >= @as(usize, @intCast(surface.size.grid.rows))) return buf[0..0];
    for (0..cols) |col| {
        buf[col] = viewportCellCodepoint(surface, col, row);
    }
    return buf[0..cols];
}

fn viewportRowIsBlankLocked(surface: *Surface, row: usize, buf: *[MAX_SELECTION_COLS]u21) bool {
    return selection_unit.rowIsBlank(readViewportRowLocked(surface, row, buf));
}

fn activateSelection(surface: *Surface, start_col: usize, start_row: usize, end_col: usize, end_row: usize) void {
    surface.selection.has_anchor = true;
    surface.selection.start_col = start_col;
    surface.selection.start_row = start_row;
    surface.selection.end_col = end_col;
    surface.selection.end_row = end_row;
    surface.selection.active = true;
    markSelectionChanged();
}

fn clearSelectionAtCell(surface: *Surface, cell_pos: CellPos) void {
    const abs_row = viewportOffsetForSurface(surface) + cell_pos.row;
    surface.selection.has_anchor = true;
    surface.selection.start_col = cell_pos.col;
    surface.selection.start_row = abs_row;
    surface.selection.end_col = cell_pos.col;
    surface.selection.end_row = abs_row;
    surface.selection.active = false;
    markSelectionChanged();
}

fn startSelectionAtCell(surface: *Surface, cell_pos: CellPos, xpos: f64, ypos: f64) void {
    const abs_row = viewportOffsetForSurface(surface) + cell_pos.row;
    surface.selection.has_anchor = true;
    surface.selection.start_col = cell_pos.col;
    surface.selection.start_row = abs_row;
    surface.selection.end_col = cell_pos.col;
    surface.selection.end_row = abs_row;
    surface.selection.active = false;
    g_selecting = true;
    g_click_x = xpos;
    g_click_y = ypos;
    markSelectionChanged();
}

fn extendSelectionAtCell(surface: *Surface, cell_pos: CellPos, xpos: f64, ypos: f64) bool {
    if (!surface.selection.has_anchor) return false;
    const abs_row = viewportOffsetForSurface(surface) + cell_pos.row;
    const same_cell = surface.selection.start_col == cell_pos.col and surface.selection.start_row == abs_row;
    surface.selection.end_col = cell_pos.col;
    surface.selection.end_row = abs_row;
    surface.selection.active = !same_cell;
    g_selecting = true;
    g_click_x = xpos;
    g_click_y = ypos;
    markSelectionChanged();
    return true;
}

fn selectWordAtCell(surface: *Surface, cell_pos: CellPos) bool {
    var row_buf: [MAX_SELECTION_COLS]u21 = undefined;

    surface.render_state.mutex.lock();
    defer surface.render_state.mutex.unlock();

    const row = readViewportRowLocked(surface, cell_pos.row, &row_buf);
    if (cell_pos.col >= row.len) return false;
    const range = selection_unit.wordRange(row, cell_pos.col) orelse return false;
    const abs_row = viewportOffsetForSurfaceLocked(surface) + cell_pos.row;
    activateSelection(surface, range.start, abs_row, range.end, abs_row);
    return true;
}

fn selectLineAtCell(surface: *Surface, cell_pos: CellPos) bool {
    var row_buf: [MAX_SELECTION_COLS]u21 = undefined;

    surface.render_state.mutex.lock();
    defer surface.render_state.mutex.unlock();

    const row = readViewportRowLocked(surface, cell_pos.row, &row_buf);
    const range = selection_unit.lineRange(row) orelse return false;
    const abs_row = viewportOffsetForSurfaceLocked(surface) + cell_pos.row;
    activateSelection(surface, range.start, abs_row, range.end, abs_row);
    return true;
}

fn selectParagraphAtCell(surface: *Surface, cell_pos: CellPos) bool {
    var row_buf: [MAX_SELECTION_COLS]u21 = undefined;

    surface.render_state.mutex.lock();
    defer surface.render_state.mutex.unlock();

    const rows = @as(usize, @intCast(surface.size.grid.rows));
    if (cell_pos.row >= rows or viewportRowIsBlankLocked(surface, cell_pos.row, &row_buf)) return false;

    var start_row = cell_pos.row;
    while (start_row > 0 and !viewportRowIsBlankLocked(surface, start_row - 1, &row_buf)) : (start_row -= 1) {}

    var end_row = cell_pos.row;
    while (end_row + 1 < rows and !viewportRowIsBlankLocked(surface, end_row + 1, &row_buf)) : (end_row += 1) {}

    const start_cols = readViewportRowLocked(surface, start_row, &row_buf);
    const start_col = selection_unit.firstNonBlankCol(start_cols) orelse 0;
    const end_cols = readViewportRowLocked(surface, end_row, &row_buf);
    const end_col = selection_unit.lastNonBlankCol(end_cols) orelse 0;
    const vp_off = viewportOffsetForSurfaceLocked(surface);

    activateSelection(surface, start_col, vp_off + start_row, end_col, vp_off + end_row);
    return true;
}

/// Resolve a left-button click in terminal content into focus + selection.
/// Shared by the normal press path and the macOS double_click fall-through:
/// the click count comes from click_tracker (time+distance based, identical on
/// every platform), so 1=drag-select, 2=word, 3=line, 4=paragraph.
fn handleTerminalSelectionPress(ev: platform_input.MouseButtonEvent, xpos: f64, ypos: f64) void {
    // Find which surface was clicked and focus it
    const clicked_surface = split_layout.surfaceAtPoint(@intFromFloat(xpos), @intFromFloat(ypos)) orelse AppWindow.activeSurface() orelse return;

    // Focus the clicked split if different from current focus
    if (AppWindow.activeTab()) |tb| {
        const previous_focus = tb.focused;
        for (0..split_layout.g_split_rect_count) |i| {
            const rect = split_layout.g_split_rects[i];
            if (!split_layout.cachedRectIsLive(rect)) continue;
            if (rect.surface()) |s| {
                if (s == clicked_surface) {
                    tb.focused = rect.handle;
                    break;
                }
            }
        }
        if (tb.focused != previous_focus) {
            AppWindow.handleActiveSurfaceChangeWithinTab();
        }
    }

    const cell_pos = mouseToSurfaceCell(clicked_surface, xpos, ypos);
    const open_mod = primaryOpenMod(ev.ctrl, ev.super);
    const click_action = terminalPathClickAction(clicked_surface.launch_kind, open_mod, ev.shift, ev.alt);
    // Only instrument the SSH download gesture (Ctrl/Cmd+Shift) so the log is not
    // flooded by every terminal click. This shows whether a download gesture
    // routed to `download_ssh_file` and whether the surface had SSH metadata.
    if (open_mod and ev.shift and !ev.alt) {
        preview_diagnostics.debug("download", &.{
            .{ .key = "stage", .value = "click" },
            .{ .key = "launch", .value = @tagName(clicked_surface.launch_kind) },
            .{ .key = "has_conn", .value = if (clicked_surface.ssh_connection != null) "true" else "false" },
            .{ .key = "action", .value = @tagName(click_action) },
        });
    }
    switch (click_action) {
        .download_ssh_file => {
            if (downloadTerminalFileAtCell(clicked_surface, cell_pos)) return;
        },
        .open_url_or_preview => {
            if (openUrlAtCell(clicked_surface, cell_pos)) return;
            if (openHtmlPanelForCell(clicked_surface, cell_pos)) return;
            if (openPreviewPanelForCell(clicked_surface, cell_pos, ev.shift)) return;
        },
        .pass_through => {},
    }

    clearUrlUnderline();
    const shift_range_select = ev.shift and !ev.ctrl and !ev.alt;
    const click_count: u8 = if (shift_range_select) blk: {
        resetLeftClickCount();
        break :blk 1;
    } else nextLeftClickCount(xpos, ypos);
    switch (click_count) {
        1 => {
            // Shift-click extends from the last click anchor, matching
            // document editor style range selection.
            if (!(shift_range_select and extendSelectionAtCell(clicked_surface, cell_pos, xpos, ypos))) {
                startSelectionAtCell(clicked_surface, cell_pos, xpos, ypos);
            }
        },
        2 => {
            g_selecting = false;
            if (!selectWordAtCell(clicked_surface, cell_pos)) clearSelectionAtCell(clicked_surface, cell_pos);
        },
        3 => {
            g_selecting = false;
            if (!selectLineAtCell(clicked_surface, cell_pos)) clearSelectionAtCell(clicked_surface, cell_pos);
        },
        4 => {
            g_selecting = false;
            if (!selectParagraphAtCell(clicked_surface, cell_pos)) clearSelectionAtCell(clicked_surface, cell_pos);
        },
        else => unreachable,
    }
}

fn extractTokenRangeAtCell(allocator: std.mem.Allocator, surface: *Surface, cell_pos: CellPos) ?TokenAtCell {
    const cols = @as(usize, @intCast(surface.size.grid.cols));
    const rows = @as(usize, @intCast(surface.size.grid.rows));
    if (cols == 0 or rows == 0 or cell_pos.row >= rows) return null;
    const click_col = @min(cell_pos.col, cols - 1);

    surface.render_state.mutex.lock();
    defer surface.render_state.mutex.unlock();

    const grid = TerminalTokenGrid{
        .surface = surface,
        .rows = rows,
        .cols = cols,
    };
    const token = preview_token.extractGridTokenAtCell(allocator, grid, .{
        .row = cell_pos.row,
        .col = click_col,
    }) orelse return null;

    return .{
        .text = token.text,
        .start_row = token.start.row,
        .end_row = token.end.row,
        .start_col = token.start.col,
        .end_col = token.end.col,
    };
}

fn extractTokenAtCell(allocator: std.mem.Allocator, surface: *Surface, cell_pos: CellPos) ?[]u8 {
    const token = extractTokenRangeAtCell(allocator, surface, cell_pos) orelse return null;
    return token.text;
}

const looksLikeUrl = terminal_link_action.looksLikeUrl;

fn extractUrlRangeAtCell(allocator: std.mem.Allocator, surface: *Surface, cell_pos: CellPos) ?TokenAtCell {
    const token = extractTokenRangeAtCell(allocator, surface, cell_pos) orelse return null;
    if (!looksLikeUrl(token.text)) {
        token.deinit(allocator);
        return null;
    }
    return token;
}

fn extractUrlAtCell(allocator: std.mem.Allocator, surface: *Surface, cell_pos: CellPos) ?[]u8 {
    const token = extractUrlRangeAtCell(allocator, surface, cell_pos) orelse return null;
    return token.text;
}

fn markUrlUnderlineDirty(surface: ?*Surface) void {
    const s = surface orelse return;
    s.surface_renderer.markDirty();
    requestInputRebuild();
}

fn setUrlUnderline(surface: *Surface, start_row_abs: usize, end_row_abs: usize, start_col: usize, end_col: usize) void {
    const old_surface = g_url_underline.surface;
    if (g_url_underline.surface == surface and
        g_url_underline.start_row_abs == start_row_abs and
        g_url_underline.end_row_abs == end_row_abs and
        g_url_underline.start_col == start_col and
        g_url_underline.end_col == end_col)
    {
        return;
    }

    g_url_underline = .{
        .surface = surface,
        .start_row_abs = start_row_abs,
        .end_row_abs = end_row_abs,
        .start_col = start_col,
        .end_col = end_col,
    };
    markUrlUnderlineDirty(old_surface);
    markUrlUnderlineDirty(surface);
}

fn clearUrlUnderline() void {
    if (!g_url_underline.active()) return;
    const old_surface = g_url_underline.surface;
    g_url_underline = .{};
    markUrlUnderlineDirty(old_surface);
}

/// The hover-underline range for `surface`, or null when no underline targets
/// it. One call per frame — the renderer computes per-row spans itself (pure
/// underline_span.colSpanForRow) using its snapshot-cached viewport offset,
/// instead of a per-cell predicate that locked the surface each call.
pub fn urlUnderlineRangeForSurface(surface: *Surface) ?underline_span.Range {
    if (g_url_underline.surface != surface) return null;
    return .{
        .start_row_abs = g_url_underline.start_row_abs,
        .end_row_abs = g_url_underline.end_row_abs,
        .start_col = g_url_underline.start_col,
        .end_col = g_url_underline.end_col,
    };
}

fn extractPreviewPathAtCell(allocator: std.mem.Allocator, surface: *Surface, cell_pos: CellPos) ?[]u8 {
    const token = extractPreviewPathRangeAtCell(allocator, surface, cell_pos) orelse return null;
    return token.text;
}

fn extractDownloadPathAtCell(allocator: std.mem.Allocator, surface: *Surface, cell_pos: CellPos) ?[]u8 {
    const token = extractDownloadPathRangeAtCell(allocator, surface, cell_pos) orelse return null;
    return token.text;
}

fn extractPreviewPathRangeAtCell(allocator: std.mem.Allocator, surface: *Surface, cell_pos: CellPos) ?TokenAtCell {
    const token = extractTokenRangeAtCell(allocator, surface, cell_pos) orelse return null;
    if (!looksLikePreviewPath(token.text) and !html_server_model.isHtmlPath(token.text)) {
        token.deinit(allocator);
        return null;
    }
    return token;
}

fn extractDownloadPathRangeAtCell(allocator: std.mem.Allocator, surface: *Surface, cell_pos: CellPos) ?TokenAtCell {
    const token = extractTokenRangeAtCell(allocator, surface, cell_pos) orelse return null;
    if (!looksLikeDownloadPath(token.text)) {
        token.deinit(allocator);
        return null;
    }
    return token;
}

fn extractInteractiveUnderlineRangeAtCell(
    allocator: std.mem.Allocator,
    surface: *Surface,
    cell_pos: CellPos,
    action: TerminalPathClickAction,
) ?TokenAtCell {
    const token = extractTokenRangeAtCell(allocator, surface, cell_pos) orelse return null;
    if (interactiveUnderlineTokenKind(action, token.text) == .none) {
        token.deinit(allocator);
        return null;
    }
    return token;
}

fn openUrl(surface: *Surface, url: []const u8) bool {
    const allocator = AppWindow.g_allocator orelse return false;
    const target = if (std.mem.startsWith(u8, url, "www."))
        std.fmt.allocPrint(allocator, "https://{s}", .{url}) catch return false
    else
        allocator.dupe(u8, url) catch return false;
    defer allocator.free(target);

    const handle = AppWindow.currentNativeHandle();
    const embedded_available = browser_panel.embeddedBrowserAvailable();
    const destination = link_open.destinationForUrlClick(embedded_available, g_url_open_mode);
    preview_diagnostics.debug("url", &.{
        .{ .key = "stage", .value = "open" },
        .{ .key = "launch", .value = @tagName(surface.launch_kind) },
        .{ .key = "mode", .value = @tagName(g_url_open_mode) },
        .{ .key = "embedded_available", .value = if (embedded_available) "true" else "false" },
        .{ .key = "destination", .value = @tagName(destination) },
        .{ .key = "target", .value = target },
    });
    switch (destination) {
        .embedded_browser => {
            if (!browser_panel.openForSurface(allocator, handle, target, surface)) return false;
            if (AppWindow.g_window) |win| {
                syncPanelGridFromWindow(win);
            }
            requestInputRepaint();
            return true;
        },
        .system_browser => {
            const external_target = browser_panel.externalUrlForSurface(allocator, target, surface) orelse return false;
            defer allocator.free(external_target);
            preview_diagnostics.debug("url", &.{
                .{ .key = "stage", .value = "system-browser" },
                .{ .key = "target", .value = target },
                .{ .key = "external", .value = external_target },
            });
            return platform_open_url.open(allocator, .{ .url = external_target });
        },
    }
}

fn openUrlAtCell(surface: *Surface, cell_pos: CellPos) bool {
    const allocator = AppWindow.g_allocator orelse return false;
    const token = extractUrlRangeAtCell(allocator, surface, cell_pos) orelse return false;
    defer token.deinit(allocator);
    const vp_off = viewportOffsetForSurface(surface);
    setUrlUnderline(surface, vp_off + token.start_row, vp_off + token.end_row, token.start_col, token.end_col);
    const opened = openUrl(surface, token.text);
    if (opened) clearUrlUnderline();
    return opened;
}

fn openHtmlPanelForCell(surface: *Surface, cell_pos: CellPos) bool {
    const allocator = AppWindow.g_allocator orelse return false;
    const path = extractPreviewPathAtCell(allocator, surface, cell_pos) orelse return false;
    defer allocator.free(path);
    if (!html_server_model.isHtmlPath(path)) return false;

    var ls_prefix_buf: [256]u8 = undefined;
    const ls_prefix = lsPrefixForCell(surface, cell_pos, &ls_prefix_buf);
    preview_diagnostics.debug("html", &.{
        .{ .key = "stage", .value = "click" },
        .{ .key = "launch", .value = @tagName(surface.launch_kind) },
        .{ .key = "path", .value = path },
        .{ .key = "ls_prefix", .value = ls_prefix orelse "" },
    });

    switch (html_server.openForSurface(allocator, surface, path, ls_prefix)) {
        .url => |url| {
            defer allocator.free(url);
            preview_diagnostics.debug("html", &.{
                .{ .key = "stage", .value = "open-browser" },
                .{ .key = "path", .value = path },
                .{ .key = "url", .value = url },
            });
            const parent = AppWindow.currentNativeHandle();
            browser_panel.open(parent, url);
            if (AppWindow.g_window) |win| syncPanelGridFromWindow(win);
            requestInputRepaint();
            return true;
        },
        .err => |err| {
            preview_diagnostics.debug("html", &.{
                .{ .key = "stage", .value = "failed" },
                .{ .key = "path", .value = path },
                .{ .key = "err", .value = @errorName(err) },
            });
            file_explorer.setTransferStatus(.failed, switch (err) {
                error.CwdUnavailable => "HTML cwd unknown",
                error.ServerUnavailable => "Install Python 3 in this environment",
                error.ServerNotReady => "HTML server not reachable",
                error.TunnelFailed => "HTML SSH tunnel failed",
                else => "HTML preview failed",
            });
            return true;
        },
    }
}

fn updateInteractiveUnderlineAtMouse(xpos: f64, ypos: f64, ctrl: bool, shift: bool, alt: bool, super: bool) void {
    if (g_selecting or overlays.scrollbar.g_scrollbar_dragging or g_divider_dragging) {
        clearUrlUnderline();
        return;
    }
    if (ypos < titlebarHeight() or hitTestFileExplorer(xpos, ypos) or hitTestBrowserPanel(xpos, ypos)) {
        clearUrlUnderline();
        return;
    }
    if (tab.g_sidebar_visible and xpos < @as(f64, @floatCast(titlebar.sidebarWidth()))) {
        clearUrlUnderline();
        return;
    }

    const surface = split_layout.surfaceAtPoint(@intFromFloat(xpos), @intFromFloat(ypos)) orelse {
        clearUrlUnderline();
        return;
    };
    const allocator = AppWindow.g_allocator orelse return;
    const cell_pos = mouseToSurfaceCell(surface, xpos, ypos);

    const action = terminalPathClickAction(surface.launch_kind, primaryOpenMod(ctrl, super), shift, alt);
    const token = extractInteractiveUnderlineRangeAtCell(allocator, surface, cell_pos, action) orelse {
        clearUrlUnderline();
        return;
    };
    defer token.deinit(allocator);

    const vp_off = viewportOffsetForSurface(surface);
    setUrlUnderline(surface, vp_off + token.start_row, vp_off + token.end_row, token.start_col, token.end_col);
}

fn openPreviewAsync(kind: markdown_preview.Kind, title: []const u8, path: []const u8, source_kind: PreviewPane.PreviewSourceKind, move_focus: bool) bool {
    const perf = ui_perf.begin("input.open_preview_async");
    defer perf.end();

    const t = tab.activeTab() orelse return false;
    const gpa = AppWindow.g_allocator orelse return false;
    const pane: *PreviewPane = if (tab.previewForReuse(gpa, t, kind)) |h|
        switch (t.tree.nodes[h.idx()]) {
            .leaf => |pn| switch (pn) {
                .preview => |p| p,
                else => return false,
            },
            .split => return false,
        }
    else
        (tab.splitIntoPreviewStacked(gpa) orelse return false);
    // Only steal focus when the caller asks (file-explorer preview). A Ctrl+click
    // from the terminal keeps focus on the terminal so typing continues there; the
    // preview's PgUp/PgDn/close keys then require clicking it first.
    if (move_focus) _ = tab.focusPreviewPane(pane);
    if (!pane.beginAsyncLoad(kind, title, path, source_kind)) {
        file_explorer.setTransferStatus(.failed, "Preview failed");
        return true;
    }
    requestInputRepaint();
    return true;
}

fn openPreviewGalleryNeighbor(p: *PreviewPane, forward: bool) bool {
    const gpa = AppWindow.g_allocator orelse return false;
    var target = findPreviewGalleryNeighbor(gpa, p, forward) orelse return false;
    defer target.deinit(gpa);

    if (!p.beginAsyncLoad(target.kind, target.title(), target.path, p.currentSourceKind())) {
        file_explorer.setTransferStatus(.failed, "Preview failed");
        return false;
    }

    requestInputRepaint();
    return true;
}

fn findPreviewGalleryNeighbor(allocator: std.mem.Allocator, p: *const PreviewPane, forward: bool) ?preview_gallery.Target {
    return switch (p.currentSourceKind()) {
        .local => preview_gallery.findNeighbor(allocator, @as(file_backend.Backend, .local), p.path(), forward) catch null,
        .wsl => preview_gallery.findNeighbor(allocator, @as(file_backend.Backend, .wsl), p.path(), forward) catch null,
        .remote => |conn| preview_gallery.findNeighbor(allocator, .{ .ssh = &conn }, p.path(), forward) catch null,
    };
}

fn openPreviewNew(kind: markdown_preview.Kind, title: []const u8, path: []const u8, source_kind: PreviewPane.PreviewSourceKind, move_focus: bool) bool {
    const perf = ui_perf.begin("input.open_preview_new");
    defer perf.end();

    const gpa = AppWindow.g_allocator orelse return false;
    const pane = tab.splitIntoPreviewStacked(gpa) orelse return false;
    // Keep focus on the terminal for Ctrl+click opens; see openPreviewAsync.
    if (move_focus) _ = tab.focusPreviewPane(pane);
    if (!pane.beginAsyncLoad(kind, title, path, source_kind)) {
        file_explorer.setTransferStatus(.failed, "Preview failed");
        return true;
    }
    requestInputRepaint();
    return true;
}

fn fileExplorerPreviewSourceKind() ?PreviewPane.PreviewSourceKind {
    return switch (file_explorer.sourceSnapshot() orelse return null) {
        .local => .local,
        .wsl => .wsl,
        .remote => |conn| .{ .remote = conn },
    };
}

fn terminalPreviewSourceKind(surface: *Surface) ?PreviewPane.PreviewSourceKind {
    return switch (surface.launch_kind) {
        .local => .local,
        .wsl => .wsl,
        .ssh => if (surface.ssh_connection) |conn| .{ .remote = conn } else null,
    };
}

fn openFileExplorerPreview(entry: file_explorer.EntryView) bool {
    const perf = ui_perf.begin("input.open_file_explorer_preview");
    defer perf.end();

    if (entry.is_dir) return false;

    const kind = markdown_preview.detectKind(entry.path) orelse return false;
    const source_kind = fileExplorerPreviewSourceKind() orelse {
        file_explorer.setTransferStatus(.failed, "Preview failed");
        return true;
    };

    // File-explorer preview keeps moving focus onto the preview so its scroll /
    // gallery keys work straight away (the user is browsing files, not typing).
    return openPreviewAsync(kind, entry.name, entry.path, source_kind, true);
}

/// Infer the `ls <dir>/` directory prefix for the clicked cell, copied into
/// `out_buf`. The returned slice points into `out_buf`, so the caller's buffer
/// must outlive every use of the result. Returns null when no nearby `ls`
/// command applies. Holds `render_state.mutex` only for the grid scan.
fn lsPrefixForCell(surface: *Surface, cell_pos: CellPos, out_buf: []u8) ?[]const u8 {
    const cols = @as(usize, @intCast(surface.size.grid.cols));
    const rows = @as(usize, @intCast(surface.size.grid.rows));
    if (cols == 0 or rows == 0 or cell_pos.row >= rows) return null;

    surface.render_state.mutex.lock();
    defer surface.render_state.mutex.unlock();

    const grid = TerminalTokenGrid{ .surface = surface, .rows = rows, .cols = cols };
    return ls_path_context.inferPrefixForClick(grid, cell_pos.row, out_buf);
}

fn openPreviewPanelForCell(surface: *Surface, cell_pos: CellPos, shift: bool) bool {
    const allocator = AppWindow.g_allocator orelse return false;
    const path = extractPreviewPathAtCell(allocator, surface, cell_pos) orelse return false;
    defer allocator.free(path);

    var ls_prefix_buf: [256]u8 = undefined;
    const ls_prefix = lsPrefixForCell(surface, cell_pos, &ls_prefix_buf);

    if (markdown_preview.detectKind(path)) |kind| {
        preview_diagnostics.debug("preview", &.{
            .{ .key = "stage", .value = "click" },
            .{ .key = "launch", .value = @tagName(surface.launch_kind) },
            .{ .key = "kind", .value = @tagName(kind) },
            .{ .key = "path", .value = path },
            .{ .key = "ls_prefix", .value = ls_prefix orelse "" },
        });
        const resolved_path = resolveTerminalPreviewPath(allocator, surface, path, ls_prefix) catch |err| {
            preview_diagnostics.debug("preview", &.{
                .{ .key = "stage", .value = "resolve-failed" },
                .{ .key = "kind", .value = @tagName(kind) },
                .{ .key = "path", .value = path },
                .{ .key = "err", .value = @errorName(err) },
            });
            file_explorer.setTransferStatus(.failed, "Preview failed");
            return true;
        };
        defer allocator.free(resolved_path);

        const source_kind = terminalPreviewSourceKind(surface) orelse {
            preview_diagnostics.debug("preview", &.{
                .{ .key = "stage", .value = "source-kind-failed" },
                .{ .key = "kind", .value = @tagName(kind) },
                .{ .key = "path", .value = path },
                .{ .key = "resolved", .value = resolved_path },
            });
            file_explorer.setTransferStatus(.failed, "Preview failed");
            return true;
        };
        preview_diagnostics.debug("preview", &.{
            .{ .key = "stage", .value = "open-pane" },
            .{ .key = "kind", .value = @tagName(kind) },
            .{ .key = "path", .value = path },
            .{ .key = "resolved", .value = resolved_path },
            .{ .key = "source", .value = previewSourceKindName(source_kind) },
            .{ .key = "new_pane", .value = if (shift) "true" else "false" },
        });

        if (shift) {
            return openPreviewNew(kind, basenameForPreview(path), resolved_path, source_kind, false);
        } else {
            return openPreviewAsync(kind, basenameForPreview(path), resolved_path, source_kind, false);
        }
    }

    const command = buildPreviewCommand(allocator, path) orelse return false;
    defer allocator.free(command);

    const preview_surface = AppWindow.splitFocusedReturningSurface(.right) orelse return false;
    writeTextToSurfacePty(preview_surface, command);
    return true;
}

fn previewSourceKindName(kind: PreviewPane.PreviewSourceKind) []const u8 {
    return switch (kind) {
        .local => "local",
        .wsl => "wsl",
        .remote => "ssh",
    };
}

fn buildRemotePathKindCommand(buf: []u8, remote_path: []const u8) ?[]const u8 {
    var path_expr_buf: [1024]u8 = undefined;
    const path_expr = platform_remote_file.shellPathExpr(&path_expr_buf, remote_path) orelse return null;
    return std.fmt.bufPrint(
        buf,
        "if test -d {s}; then printf d; elif test -e {s}; then printf f; else exit 1; fi",
        .{ path_expr, path_expr },
    ) catch null;
}

fn remotePathIsDirectoryForDownload(allocator: std.mem.Allocator, conn: *const @import("ssh_connection.zig").SshConnection, remote_path: []const u8) ?bool {
    var cmd_buf: [2300]u8 = undefined;
    const cmd = buildRemotePathKindCommand(cmd_buf[0..], remote_path) orelse return null;
    // Runs on the UI thread, so bound it: a hung remote `test -d` becomes a
    // bounded delay + null result instead of a permanent freeze (see scp watchdog).
    // Kept under ssh's ServerAlive give-up (~10 s) so the watchdog kill wins over
    // the slower keepalive timeout.
    const PROBE_TIMEOUT_MS = 5_000;
    const output = scp.sshExecCappedOpts(allocator, conn, cmd, 8, .{ .timeout_ms = PROBE_TIMEOUT_MS }) orelse return null;
    defer allocator.free(output);

    const trimmed = std.mem.trim(u8, output, " \t\r\n");
    if (std.mem.eql(u8, trimmed, "d")) return true;
    if (std.mem.eql(u8, trimmed, "f")) return false;
    return null;
}

test "input: remote download path kind command shell-quotes paths" {
    var buf: [2300]u8 = undefined;
    const cmd = buildRemotePathKindCommand(buf[0..], "/tmp/it's here") orelse return error.CommandTooLong;
    try std.testing.expectEqualStrings(
        "if test -d '/tmp/it'\\''s here'; then printf d; elif test -e '/tmp/it'\\''s here'; then printf f; else exit 1; fi",
        cmd,
    );
}

fn downloadTerminalFileAtCell(surface: *Surface, cell_pos: CellPos) bool {
    if (surface.launch_kind != .ssh) {
        preview_diagnostics.debug("download", &.{
            .{ .key = "stage", .value = "abort" },
            .{ .key = "reason", .value = "not-ssh" },
            .{ .key = "launch", .value = @tagName(surface.launch_kind) },
        });
        return false;
    }
    const conn = surface.ssh_connection orelse {
        preview_diagnostics.debug("download", &.{
            .{ .key = "stage", .value = "abort" },
            .{ .key = "reason", .value = "no-conn" },
        });
        file_explorer.setTransferStatusForKind(.download, .failed, "SSH connection unavailable");
        return true;
    };
    const allocator = AppWindow.g_allocator orelse return false;

    const path = extractDownloadPathAtCell(allocator, surface, cell_pos) orelse {
        preview_diagnostics.debug("download", &.{
            .{ .key = "stage", .value = "abort" },
            .{ .key = "reason", .value = "no-path" },
        });
        return false;
    };
    defer allocator.free(path);

    var ls_prefix_buf: [256]u8 = undefined;
    const ls_prefix = lsPrefixForCell(surface, cell_pos, &ls_prefix_buf);
    preview_diagnostics.debug("download", &.{
        .{ .key = "stage", .value = "extract" },
        .{ .key = "host", .value = conn.host() },
        .{ .key = "path", .value = path },
        .{ .key = "ls_prefix", .value = ls_prefix orelse "" },
    });

    const resolved_path = resolveTerminalPreviewPath(allocator, surface, path, ls_prefix) catch |err| {
        preview_diagnostics.debug("download", &.{
            .{ .key = "stage", .value = "resolve-failed" },
            .{ .key = "path", .value = path },
            .{ .key = "err", .value = @errorName(err) },
        });
        if (err == error.CwdUnavailable) {
            file_explorer.setTransferStatusForKind(.download, .failed, "SSH cwd unknown");
            overlays.showSshCwdFallbackPrompt();
        } else {
            file_explorer.setTransferStatusForKind(.download, .failed, "Download failed");
        }
        return true;
    };
    defer allocator.free(resolved_path);

    const name = basenameForPreview(resolved_path);
    if (name.len == 0) {
        preview_diagnostics.debug("download", &.{
            .{ .key = "stage", .value = "abort" },
            .{ .key = "reason", .value = "no-name" },
            .{ .key = "resolved", .value = resolved_path },
        });
        return false;
    }
    const dir_probe = remotePathIsDirectoryForDownload(allocator, &conn, resolved_path);
    const is_dir = dir_probe orelse {
        preview_diagnostics.debug("download", &.{
            .{ .key = "stage", .value = "probe-failed" },
            .{ .key = "resolved", .value = resolved_path },
        });
        file_explorer.setTransferStatusForKind(.download, .failed, "SSH helper unavailable");
        return true;
    };
    preview_diagnostics.debug("download", &.{
        .{ .key = "stage", .value = "probe" },
        .{ .key = "resolved", .value = resolved_path },
        // Distinguishes "probe ran and said file/dir" from "probe ssh helper
        // failed" (null) — the latter points at the SSH metadata channel (#268).
        .{ .key = "probe", .value = if (is_dir) "dir" else "file" },
    });

    var dl_buf: [260]u8 = undefined;
    const dl_path = getDownloadsFolder(&dl_buf);
    if (dl_path.len == 0) {
        preview_diagnostics.debug("download", &.{
            .{ .key = "stage", .value = "abort" },
            .{ .key = "reason", .value = "no-downloads-folder" },
        });
        file_explorer.setTransferStatusForKind(.download, .failed, "Download folder missing");
        return true;
    }

    var dst_buf: [512]u8 = undefined;
    const dst = platform_local_path.joinInto(dst_buf[0..], dl_path, name) orelse {
        preview_diagnostics.debug("download", &.{
            .{ .key = "stage", .value = "abort" },
            .{ .key = "reason", .value = "dst-too-long" },
        });
        file_explorer.setTransferStatusForKind(.download, .failed, "Path too long");
        return true;
    };

    const dispatched = file_explorer.downloadRemotePathToPath(resolved_path, dst, name, &conn, is_dir);
    preview_diagnostics.debug("download", &.{
        .{ .key = "stage", .value = "dispatch" },
        .{ .key = "resolved", .value = resolved_path },
        .{ .key = "dst", .value = dst },
        .{ .key = "dispatched", .value = if (dispatched) "true" else "false" },
    });
    return true;
}

/// Ctrl+right-click (Cmd on macOS) over a local terminal opens the file path
/// under the cursor in the OS default app. Returns true only when it launched
/// an open; false otherwise so the caller falls through to the configured
/// right-click action (copy/paste) for plain right-clicks, remote terminals,
/// empty space, and non-path text.
fn openInEditorAtRightClick(ev: platform_input.MouseButtonEvent) bool {
    const surface = split_layout.surfaceAtPoint(ev.x, ev.y) orelse return false;
    if (!terminal_link_action.rightClickOpensInEditor(
        surface.launch_kind,
        primaryOpenMod(ev.ctrl, ev.super),
        ev.shift,
        ev.alt,
    )) return false;

    const allocator = AppWindow.g_allocator orelse return false;
    const cell_pos = mouseToSurfaceCell(surface, @floatFromInt(ev.x), @floatFromInt(ev.y));

    const path = extractPreviewPathAtCell(allocator, surface, cell_pos) orelse return false;
    defer allocator.free(path);

    var ls_prefix_buf: [256]u8 = undefined;
    const ls_prefix = lsPrefixForCell(surface, cell_pos, &ls_prefix_buf);

    const resolved = resolveTerminalPreviewPath(allocator, surface, path, ls_prefix) catch return false;
    defer allocator.free(resolved);

    return platform_open_url.open(allocator, .{ .url = resolved });
}

fn handleMouseButton(ev: platform_input.MouseButtonEvent) void {
    if (ev.action == .press) close_confirm_state.clear();
    if (overlays.whatsNewVisible()) {
        if (ev.button == .left and ev.action == .press) {
            const win = AppWindow.g_window orelse return;
            const fb = window_backend.framebufferSize(win);
            const xpos: f64 = @floatFromInt(ev.x);
            const ypos: f64 = @floatFromInt(ev.y);
            _ = overlays.whatsNewExecuteAt(xpos, ypos, @floatFromInt(fb.width), @floatFromInt(fb.height));
            requestInputRepaint();
        }
        return;
    }
    if (overlays.integrationPromptVisible()) {
        if (ev.button == .left and ev.action == .press) {
            const win = AppWindow.g_window orelse return;
            const fb = window_backend.framebufferSize(win);
            const xpos: f64 = @floatFromInt(ev.x);
            const ypos: f64 = @floatFromInt(ev.y);
            _ = overlays.integrationPromptExecuteAt(xpos, ypos, @floatFromInt(fb.width), @floatFromInt(fb.height));
            requestInputRepaint();
        }
        return;
    }
    if (overlays.windowCloseConfirmVisible()) {
        if (ev.button == .left and ev.action == .press) {
            const win = AppWindow.g_window orelse return;
            const fb = window_backend.framebufferSize(win);
            const xpos: f64 = @floatFromInt(ev.x);
            const ypos: f64 = @floatFromInt(ev.y);
            _ = overlays.windowCloseConfirmExecuteAt(xpos, ypos, @floatFromInt(fb.width), @floatFromInt(fb.height));
            requestInputRepaint();
        }
        return;
    }
    if (overlays.transferCancelConfirmVisible()) {
        if (ev.button == .left and ev.action == .press) {
            const win = AppWindow.g_window orelse return;
            const fb = window_backend.framebufferSize(win);
            const xpos: f64 = @floatFromInt(ev.x);
            const ypos: f64 = @floatFromInt(ev.y);
            switch (overlays.transferCancelConfirmExecuteAt(xpos, ypos, @floatFromInt(fb.width), @floatFromInt(fb.height))) {
                .interrupt => _ = file_explorer.cancelActiveTransfer(),
                .keep, .none => {},
            }
            requestInputRepaint();
        }
        return;
    }
    if (!hitTestHelpButton(@floatFromInt(ev.x), @floatFromInt(ev.y)))
        overlays.startupShortcutsDismiss();
    if (overlays.sessionLauncherVisible()) {
        if (ev.button == .left and ev.action == .press) {
            const win = AppWindow.g_window orelse return;
            const fb = window_backend.framebufferSize(win);
            const w_f: f32 = @floatFromInt(fb.width);
            const h_f: f32 = @floatFromInt(fb.height);
            const top_offset: f32 = @floatCast(titlebarHeight());
            const xpos: f64 = @floatFromInt(ev.x);
            const ypos: f64 = @floatFromInt(ev.y);
            if (overlays.sessionLauncherExecuteAt(xpos, ypos, w_f, h_f, top_offset)) return;
            if (!overlays.sessionLauncherContainsPoint(xpos, ypos, w_f, h_f, top_offset)) {
                overlays.sessionLauncherClose();
            }
        }
        return;
    }
    if (overlays.restoreDefaultsConfirmVisible()) {
        if (ev.button == .left and ev.action == .press) {
            const win = AppWindow.g_window orelse return;
            const fb = window_backend.framebufferSize(win);
            const xpos: f64 = @floatFromInt(ev.x);
            const ypos: f64 = @floatFromInt(ev.y);
            _ = overlays.restoreDefaultsConfirmExecuteAt(xpos, ypos, @floatFromInt(fb.width), @floatFromInt(fb.height));
            requestInputRepaint();
        }
        return;
    }
    if (overlays.settingsPageVisible()) {
        if (ev.button == .left and ev.action == .press) {
            const win = AppWindow.g_window orelse return;
            const fb = window_backend.framebufferSize(win);
            const w_f: f32 = @floatFromInt(fb.width);
            const h_f: f32 = @floatFromInt(fb.height);
            const top_offset: f32 = @floatCast(titlebarHeight());
            const xpos: f64 = @floatFromInt(ev.x);
            const ypos: f64 = @floatFromInt(ev.y);
            if (overlays.settingsPageExecuteAt(xpos, ypos, w_f, h_f, top_offset)) return;
            if (!overlays.settingsPageContainsPoint(xpos, ypos, w_f, h_f, top_offset)) {
                overlays.settingsPageClose();
            }
        }
        return;
    }
    if (overlays.commandPaletteVisible()) {
        if (ev.button == .left and ev.action == .press) {
            const win = AppWindow.g_window orelse return;
            const fb = window_backend.framebufferSize(win);
            const w_f: f32 = @floatFromInt(fb.width);
            const h_f: f32 = @floatFromInt(fb.height);
            const top_offset: f32 = @floatCast(titlebarHeight());
            const xpos: f64 = @floatFromInt(ev.x);
            const ypos: f64 = @floatFromInt(ev.y);
            if (overlays.commandPaletteExecuteAt(xpos, ypos, w_f, h_f, top_offset)) return;
            if (!overlays.commandPaletteContainsPoint(xpos, ypos, w_f, h_f, top_offset)) {
                overlays.commandPaletteClose();
            }
        }
        return;
    }
    if (AppWindow.weixin_qr_panel.visible()) {
        if (ev.button == .left and ev.action == .press) {
            const win = AppWindow.g_window orelse return;
            const fb = window_backend.framebufferSize(win);
            const w_f: f32 = @floatFromInt(fb.width);
            const h_f: f32 = @floatFromInt(fb.height);
            const top_offset: f32 = @floatCast(titlebarHeight());
            const xpos: f64 = @floatFromInt(ev.x);
            const ypos: f64 = @floatFromInt(ev.y);
            overlays.weixinQrPanelHandleAction(AppWindow.weixin_qr_panel.executeAt(xpos, ypos, w_f, h_f, top_offset));
        }
        return;
    }
    if (ev.button == .left and ev.action == .press) {
        const win = AppWindow.g_window orelse return;
        const fb = window_backend.framebufferSize(win);
        const xpos: f64 = @floatFromInt(ev.x);
        const ypos: f64 = @floatFromInt(ev.y);
        if (overlays.transferToastHitTest(xpos, ypos, @floatFromInt(fb.width), @floatFromInt(fb.height))) {
            overlays.transferCancelConfirmOpen();
            requestInputRepaint();
            return;
        }
        if (overlays.updatePromptHitTest(xpos, ypos, @floatFromInt(fb.height))) {
            overlays.activateUpdatePrompt();
            return;
        }
        if (overlays.remoteKeyCopyHitTest(xpos, ypos, @floatFromInt(fb.height))) {
            _ = copyRemoteSessionKeyToClipboard();
            return;
        }
    }

    // Alt + left-press begins a panel swap when the active terminal tab is
    // split. Intercept here — before terminal mouse-reporting — so the gesture
    // works even when the panel runs a full-screen mouse-tracking program. Only
    // engages when the press lands inside a panel of a split tab; otherwise it
    // falls through to the normal handling below.
    if (ev.button == .left and ev.action == .press and ev.alt) {
        if (beginPanelSwapIfSplit(ev.x, ev.y)) {
            updateFocusFromMouse(ev.x, ev.y);
            return;
        }
    }

    // Terminal mouse reporting (xterm 1000/1002/1003). When the focused
    // program has enabled mouse tracking, deliver button events to the PTY
    // instead of driving local selection / paste / context-menu. A release
    // always finishes an in-progress reported drag — any modifier, anywhere —
    // so state never leaks. A press starts reporting only over terminal
    // content, with Shift up (Shift forces the terminal's own selection) and
    // without the link-open modifier (Ctrl/Cmd keeps opening links/previews
    // through the existing path below).
    if (ev.action == .release) {
        if (finishTerminalMouseReport(ev)) return;
    } else if (mouse_dispatch.pressShouldReport(.{
        .shift = ev.shift,
        .alt = ev.alt,
        .primary_open = primaryOpenMod(ev.ctrl, ev.super),
    })) {
        if (beginTerminalMouseReport(ev)) return;
    }

    // A natively-reported double-click (macOS backend) targets UI chrome:
    // double-click a tab to rename, the bare titlebar to zoom, or a file-
    // explorer entry to open it. If it hits none of those, it is a terminal
    // content double-click and falls through to selection below.
    if (ev.button == .left and ev.action == .double_click) {
        const xpos: f64 = @floatFromInt(ev.x);
        const titlebar_h: f64 = titlebarHeight();
        const ypos: f64 = @floatFromInt(ev.y);
        if (hitTestFileExplorer(xpos, ypos)) {
            handleFileExplorerPress(xpos, ypos, ev.ctrl, ev.shift, ev.alt, ev.super);
            return;
        }
        if (ypos < titlebar_h) {
            if (hitTestConfigButton(xpos, ypos)) {
                overlays.settingsPageOpen();
            } else if (xpos >= @as(f64, titlebar.titlebarLeftReserved() + titlebar.TITLEBAR_TOGGLE_W)) {
                // Double-clicking on bare titlebar (not on the toggle, and not
                // on the macOS traffic-light strip) zooms / unzooms.
                toggleMaximize();
            }
            return;
        }
        if (hitTestSidebarTab(xpos, ypos)) |tab_idx| {
            if (shouldStartSidebarTabRename(xpos, ypos, tab_idx)) {
                tab.startTabRename(tab_idx);
            }
            return;
        }
        // No chrome hit — this is a double-click in terminal content. The macOS
        // backend reports the 2nd/3rd/4th click of a multi-click as
        // double_click (clickCount > 1) rather than press, so they never reach
        // the press-path selection. Route terminal-content double-clicks
        // through the same click_tracker path: the opening press already
        // registered count=1, so this registers 2/3/4 → word/line/paragraph.
        // Windows/Linux never emit double_click, so their behavior is unchanged.
        if (split_layout.surfaceAtPoint(ev.x, ev.y) != null) {
            handleTerminalSelectionPress(ev, xpos, ypos);
        }
        return;
    }

    // Middle-click on tab to close it
    if (ev.button == .middle and ev.action == .release) {
        const xpos: f64 = @floatFromInt(ev.x);
        const ypos: f64 = @floatFromInt(ev.y);
        if (hitTestSidebarTab(xpos, ypos)) |tab_idx| {
            requestCloseTabGesture(tab_idx);
            return;
        }
        if (AppWindow.activeAiChat()) |chat| {
            const win = AppWindow.g_window orelse return;
            const fb = window_backend.framebufferSize(win);
            if (AppWindow.assistant_conversation_renderer.inputFieldMetricsAt(
                chat,
                xpos,
                ypos,
                @floatFromInt(fb.width),
                @floatFromInt(fb.height),
                AppWindow.leftPanelsWidth(),
                @as(f32, @floatFromInt(fb.width)) - AppWindow.leftPanelsWidth() - AppWindow.rightPanelsWidthForWindow(fb.width),
            ) != null) {
                pasteFromClipboardIntoAiChat(chat);
                return;
            }
        }
        return;
    }

    // Ctrl+right-click (Cmd on macOS) over a local terminal opens the file under
    // the cursor in the OS default app; otherwise follow the configured action.
    if (ev.button == .right and ev.action == .release) {
        if (openInEditorAtRightClick(ev)) return;
        handleConfiguredRightClick();
        return;
    }

    if (ev.button == .left) {
        const xpos: f64 = @floatFromInt(ev.x);
        const ypos: f64 = @floatFromInt(ev.y);
        const titlebar_h: f64 = titlebarHeight();

        if (ev.action == .press) {
            g_selection_changed_for_copy = false;

            // Commit rename on any click
            if (tab.g_tab_rename_active) tab.commitTabRename();

            // Check if click is in the titlebar (tab bar area)
            if (ypos < titlebar_h) {
                blurBrowserUrlBarIfFocused();
                handleTopbarPress(xpos);
                return;
            }
            if (hitTestFileExplorerCloseButton(xpos, ypos)) {
                closeFileExplorerPanel();
                return;
            }
            if (file_explorer.isFilesPanel() and hitTestFileExplorerRefreshButton(xpos, ypos)) {
                file_explorer.refresh();
                requestInputRepaint();
                return;
            }
            if (hitTestBrowserRefreshButton(xpos, ypos)) {
                refreshBrowserPanel();
                return;
            }
            if (hitTestBrowserToggleButton(xpos, ypos)) {
                toggleBrowserDisplayMode();
                return;
            }
            if (hitTestBrowserCloseButton(xpos, ypos)) {
                closeBrowserPanel();
                return;
            }
            if (hitTestAiCopilotCloseButton(xpos, ypos)) {
                closeAiCopilotPanel();
                return;
            }
            const over_browser_url_bar = hitTestBrowserUrlBar(xpos, ypos);
            if (!over_browser_url_bar) blurBrowserUrlBarIfFocused();
            if (hitTestSidebarResizeHandle(xpos, ypos)) {
                g_sidebar_resize_dragging = true;
                g_sidebar_resize_hover = true;
                platform_cursor.set(.size_we);
                return;
            }
            if (hitTestFileExplorerResizeHandle(xpos, ypos)) {
                g_explorer_resize_dragging = true;
                g_explorer_resize_hover = true;
                platform_cursor.set(.size_we);
                return;
            }
            if (hitTestBrowserResizeHandle(xpos, ypos)) {
                g_browser_resize_dragging = true;
                g_browser_resize_hover = true;
                platform_cursor.set(.size_we);
                return;
            }
            if (hitTestAiCopilotResizeHandle(xpos, ypos)) {
                g_ai_copilot_resize_dragging = true;
                g_ai_copilot_resize_hover = true;
                platform_cursor.set(.size_we);
                return;
            }
            if (!AppWindow.aiCopilotVisible() and hitTestCopilotEdgeHandle(xpos, ypos)) {
                AppWindow.toggleAiCopilot();
                return;
            }

            if (over_browser_url_bar) {
                file_explorer.blurAndCancelOp();
                browser_panel.focusUrlBar();
                markBrowserUrlBarDirty();
                return;
            }

            if (tab.g_sidebar_visible and xpos < @as(f64, @floatCast(titlebar.sidebarWidth()))) {
                handleSidebarPress(xpos, ypos);
                return;
            }

            if (hitTestBrowserPanel(xpos, ypos)) {
                file_explorer.blurAndCancelOp();
                browser_panel.blurUrlBar();
                markBrowserUrlBarDirty();
                browser_panel.focus();
                return;
            }

            // File explorer left sidebar click
            if (hitTestFileExplorer(xpos, ypos)) {
                handleFileExplorerPress(xpos, ypos, ev.ctrl, ev.shift, ev.alt, ev.super);
                return;
            }

            // Clicking outside file explorer unfocuses it
            file_explorer.blurAndCancelOp();

            if (AppWindow.activeAiHistory() != null) {
                if (AppWindow.aiHistoryHandleMousePress(xpos, ypos)) return;
            }

            // AI copilot sidebar (terminal tabs). When the panel is visible,
            // a click inside its rect focuses the copilot and routes one-shot
            // interactions (stop / missing-api-key / message toggle / copy /
            // permission chip). A click outside the panel blurs the copilot and
            // falls through to normal terminal handling. Transcript selection
            // and scrollbar drags record that they started in the sidebar, so
            // their continue-handlers keep using the narrower panel geometry.
            if (AppWindow.aiCopilotVisible()) {
                if (AppWindow.activeCopilotSessionForInput()) |chat| {
                    const win = AppWindow.g_window orelse return;
                    const fb = window_backend.framebufferSize(win);
                    const bounds = ai_sidebar.boundsForWindow(
                        @intCast(fb.width),
                        @intCast(fb.height),
                        @floatCast(titlebarHeight()),
                        AppWindow.leftPanelsWidth(),
                        0,
                    );
                    const bx_left: f64 = @floatFromInt(bounds.left);
                    const bx_right: f64 = @floatFromInt(bounds.right);
                    const by_top: f64 = @floatFromInt(bounds.top);
                    const by_bottom: f64 = @floatFromInt(bounds.bottom);
                    if (xpos >= bx_left and xpos < bx_right and ypos >= by_top and ypos < by_bottom) {
                        focusAiCopilot();
                        const chat_x: f32 = @floatFromInt(bounds.left);
                        const chat_w: f32 = @floatFromInt(bounds.right - bounds.left);
                        if (AppWindow.assistant_conversation_renderer.stopButtonHitTest(
                            chat,
                            xpos,
                            ypos,
                            @floatFromInt(fb.width),
                            @floatCast(titlebarHeight()),
                            chat_x,
                            chat_w,
                            true, // copilot sidebar: dot hit-box
                        )) {
                            chat.stopRequest();
                            requestInputRepaint();
                            return;
                        }
                        if (AppWindow.assistant_conversation_renderer.missingApiKeyStatusHitTest(
                            chat,
                            xpos,
                            ypos,
                            @floatFromInt(fb.width),
                            @floatCast(titlebarHeight()),
                            chat_x,
                            chat_w,
                            true, // copilot sidebar: error text left of dot
                        )) {
                            overlays.openAiConfigForSession(chat);
                            requestInputRepaint();
                            return;
                        }
                        if (AppWindow.assistant_conversation_renderer.interactionHitTest(
                            chat,
                            xpos,
                            ypos,
                            @floatFromInt(fb.width),
                            @floatFromInt(fb.height),
                            @floatCast(titlebarHeight()),
                            chat_x,
                            chat_w,
                        )) |target| {
                            switch (target) {
                                .copy_message => |message_index| copyAiChatMessageToClipboard(chat, message_index),
                                .toggle_tool => |message_index| {
                                    chat.toggleToolMessageCollapsed(message_index);
                                    requestInputRepaint();
                                },
                                .toggle_reasoning => |message_index| {
                                    chat.toggleReasoningCollapsed(message_index);
                                    requestInputRepaint();
                                },
                                .question_option => |idx| {
                                    _ = chat.resolveQuestionOption(idx);
                                    requestInputRepaint();
                                },
                            }
                            return;
                        }
                        if (AppWindow.assistant_conversation_renderer.modelLabelHitTest(
                            chat,
                            xpos,
                            ypos,
                            @floatFromInt(fb.width),
                            @floatCast(titlebarHeight()),
                            chat_x,
                            chat_w,
                        )) {
                            overlays.openSwitchModelPicker(chat);
                            requestInputRepaint();
                            return;
                        }
                        if (AppWindow.assistant_conversation_renderer.permissionChipHitTest(
                            xpos,
                            ypos,
                            @floatFromInt(fb.width),
                            @floatCast(titlebarHeight()),
                            chat_x,
                            chat_w,
                        )) {
                            toggleAiAgentPermission();
                            return;
                        }
                        if (AppWindow.assistant_conversation_renderer.transcriptScrollbarHitTest(
                            chat,
                            xpos,
                            ypos,
                            @floatFromInt(fb.width),
                            @floatFromInt(fb.height),
                            @floatCast(titlebarHeight()),
                            chat_x,
                            chat_w,
                        )) |drag_offset| {
                            g_ai_transcript_scroll_dragging = true;
                            g_ai_transcript_scroll_chat = chat;
                            g_ai_transcript_scroll_drag_offset = drag_offset;
                            g_ai_transcript_scroll_panel = .copilot_sidebar;
                            AppWindow.assistant_conversation_renderer.g_transcript_scrollbar_dragging = true;
                            applyAiTranscriptScrollbarDrag(chat, ypos);
                            requestInputRepaint();
                            return;
                        }
                        if (!ev.ctrl and !ev.alt) {
                            if (AppWindow.assistant_conversation_renderer.transcriptTextHitTest(
                                chat,
                                xpos,
                                ypos,
                                @floatFromInt(fb.width),
                                @floatFromInt(fb.height),
                                @floatCast(titlebarHeight()),
                                chat_x,
                                chat_w,
                            )) |hit| {
                                chat.beginTranscriptSelection(hit.message_index, hit.byte_offset);
                                g_ai_transcript_selecting = true;
                                g_ai_transcript_select_chat = chat;
                                g_ai_transcript_select_auto_copy = ev.shift;
                                g_ai_transcript_select_panel = .copilot_sidebar;
                                platform_cursor.set(.ibeam);
                                requestInputRepaint();
                                return;
                            }
                        }
                        // Click landed in the panel but not on an interactive
                        // element: keep focus, clear any selection, consume it.
                        chat.clearSelection();
                        requestInputRepaint();
                        return;
                    }
                    // Click outside the sidebar: hand focus back to the terminal.
                    blurAiCopilot();
                }
            }

            if (AppWindow.activeAiChat()) |chat| {
                const win = AppWindow.g_window orelse return;
                const fb = window_backend.framebufferSize(win);
                if (AppWindow.assistant_conversation_renderer.stopButtonHitTest(
                    chat,
                    xpos,
                    ypos,
                    @floatFromInt(fb.width),
                    @floatCast(titlebarHeight()),
                    AppWindow.leftPanelsWidth(),
                    @as(f32, @floatFromInt(fb.width)) - AppWindow.leftPanelsWidth() - AppWindow.rightPanelsWidthForWindow(fb.width),
                    false, // full tab: Esc Stop button hit-box
                )) {
                    chat.stopRequest();
                    requestInputRepaint();
                    return;
                }
                if (AppWindow.assistant_conversation_renderer.missingApiKeyStatusHitTest(
                    chat,
                    xpos,
                    ypos,
                    @floatFromInt(fb.width),
                    @floatCast(titlebarHeight()),
                    AppWindow.leftPanelsWidth(),
                    @as(f32, @floatFromInt(fb.width)) - AppWindow.leftPanelsWidth() - AppWindow.rightPanelsWidthForWindow(fb.width),
                    false, // full tab: status text hit-box
                )) {
                    overlays.openAiConfigForSession(chat);
                    requestInputRepaint();
                    return;
                }
                if (AppWindow.assistant_conversation_renderer.interactionHitTest(
                    chat,
                    xpos,
                    ypos,
                    @floatFromInt(fb.width),
                    @floatFromInt(fb.height),
                    @floatCast(titlebarHeight()),
                    AppWindow.leftPanelsWidth(),
                    @as(f32, @floatFromInt(fb.width)) - AppWindow.leftPanelsWidth() - AppWindow.rightPanelsWidthForWindow(fb.width),
                )) |target| {
                    switch (target) {
                        .copy_message => |message_index| copyAiChatMessageToClipboard(chat, message_index),
                        .toggle_tool => |message_index| {
                            chat.toggleToolMessageCollapsed(message_index);
                            requestInputRepaint();
                        },
                        .toggle_reasoning => |message_index| {
                            chat.toggleReasoningCollapsed(message_index);
                            requestInputRepaint();
                        },
                        .question_option => |idx| {
                            _ = chat.resolveQuestionOption(idx);
                            requestInputRepaint();
                        },
                    }
                    return;
                }
                if (AppWindow.assistant_conversation_renderer.modelLabelHitTest(
                    chat,
                    xpos,
                    ypos,
                    @floatFromInt(fb.width),
                    @floatCast(titlebarHeight()),
                    AppWindow.leftPanelsWidth(),
                    @as(f32, @floatFromInt(fb.width)) - AppWindow.leftPanelsWidth() - AppWindow.rightPanelsWidthForWindow(fb.width),
                )) {
                    overlays.openSwitchModelPicker(chat);
                    requestInputRepaint();
                    return;
                }
                if (AppWindow.assistant_conversation_renderer.permissionChipHitTest(
                    xpos,
                    ypos,
                    @floatFromInt(fb.width),
                    @floatCast(titlebarHeight()),
                    AppWindow.leftPanelsWidth(),
                    @as(f32, @floatFromInt(fb.width)) - AppWindow.leftPanelsWidth() - AppWindow.rightPanelsWidthForWindow(fb.width),
                )) {
                    toggleAiAgentPermission();
                    return;
                }
                if (AppWindow.assistant_conversation_renderer.transcriptScrollbarHitTest(
                    chat,
                    xpos,
                    ypos,
                    @floatFromInt(fb.width),
                    @floatFromInt(fb.height),
                    @floatCast(titlebarHeight()),
                    AppWindow.leftPanelsWidth(),
                    @as(f32, @floatFromInt(fb.width)) - AppWindow.leftPanelsWidth() - AppWindow.rightPanelsWidthForWindow(fb.width),
                )) |drag_offset| {
                    g_ai_transcript_scroll_dragging = true;
                    g_ai_transcript_scroll_chat = chat;
                    g_ai_transcript_scroll_drag_offset = drag_offset;
                    g_ai_transcript_scroll_panel = .active_chat;
                    AppWindow.assistant_conversation_renderer.g_transcript_scrollbar_dragging = true;
                    applyAiTranscriptScrollbarDrag(chat, ypos);
                    requestInputRepaint();
                    return;
                }
                if (!ev.ctrl and !ev.alt) {
                    if (AppWindow.assistant_conversation_renderer.transcriptTextHitTest(
                        chat,
                        xpos,
                        ypos,
                        @floatFromInt(fb.width),
                        @floatFromInt(fb.height),
                        @floatCast(titlebarHeight()),
                        AppWindow.leftPanelsWidth(),
                        @as(f32, @floatFromInt(fb.width)) - AppWindow.leftPanelsWidth() - AppWindow.rightPanelsWidthForWindow(fb.width),
                    )) |hit| {
                        chat.beginTranscriptSelection(hit.message_index, hit.byte_offset);
                        g_ai_transcript_selecting = true;
                        g_ai_transcript_select_chat = chat;
                        g_ai_transcript_select_auto_copy = ev.shift;
                        g_ai_transcript_select_panel = .active_chat;
                        platform_cursor.set(.ibeam);
                        requestInputRepaint();
                        return;
                    }
                }
                if (AppWindow.assistant_conversation_renderer.inputScrollbarHitTest(
                    chat,
                    xpos,
                    ypos,
                    @floatFromInt(fb.width),
                    @floatFromInt(fb.height),
                    AppWindow.leftPanelsWidth(),
                    @as(f32, @floatFromInt(fb.width)) - AppWindow.leftPanelsWidth() - AppWindow.rightPanelsWidthForWindow(fb.width),
                )) |hit| {
                    g_ai_input_scroll_dragging = true;
                    g_ai_input_scroll_chat = chat;
                    g_ai_input_scroll_drag_offset = hit.drag_offset_px;
                    applyAiInputScrollbarDrag(chat, ypos);
                    requestInputRepaint();
                    return;
                }
                chat.clearSelection();
                requestInputRepaint();
                return;
            }

            // Click in terminal content area: update split focus
            updateFocusFromMouse(@intFromFloat(xpos), @intFromFloat(ypos));

            // Check if click is on the scrollbar
            const win = AppWindow.g_window orelse return;
            const fb = window_backend.framebufferSize(win);
            const w_f: f32 = @floatFromInt(fb.width);
            const h_f: f32 = @floatFromInt(fb.height);
            const tb_f: f32 = @floatCast(titlebarHeight());
            const top_pad: f32 = 10 + tb_f;
            if (scrollbarTargetAt(xpos, ypos, w_f, h_f, top_pad)) |target| {
                if (overlays.scrollbarGeometryForSurface(target.surface, target.view_h, target.top_pad)) |geo| {
                    overlays.scrollbar.g_scrollbar_dragging = true;
                    g_scrollbar_drag_surface = target.surface;
                    g_scrollbar_drag_view_y = target.view_y;
                    g_scrollbar_drag_view_h = target.view_h;
                    g_scrollbar_drag_top_pad = target.top_pad;
                    overlays.scrollbarShowForSurface(target.surface);

                    const y_f: f32 = @as(f32, @floatCast(ypos)) - target.view_y;
                    const thumb_top_px = target.view_h - (geo.thumb_y + geo.thumb_h); // convert GL→pixel
                    const thumb_bottom_px = target.view_h - geo.thumb_y;
                    if (y_f >= thumb_top_px and y_f <= thumb_bottom_px) {
                        // Clicked on thumb — offset from top of thumb
                        overlays.scrollbar.g_scrollbar_drag_offset = y_f - thumb_top_px;
                    } else {
                        // Clicked on track — jump thumb center to click position
                        overlays.scrollbar.g_scrollbar_drag_offset = geo.thumb_h / 2;
                        overlays.scrollbarDragForSurface(target.surface, ypos, target.view_y, target.view_h, target.top_pad);
                    }
                    return;
                }
            }

            // Check if click is on a split divider
            if (split_layout.hitTestDivider(ev.x, ev.y)) |hit| {
                g_divider_dragging = true;
                g_divider_drag_handle = hit.handle;
                g_divider_drag_layout = hit.layout;
                // Initialize per-surface resize tracking with current sizes
                // so we only show overlays on surfaces that actually change
                if (AppWindow.activeTab()) |tb| {
                    var it = tb.tree.surfaces();
                    while (it.next()) |entry| {
                        entry.surface.resize_overlay_active = false;
                        entry.surface.resize_overlay_last_cols = entry.surface.size.grid.cols;
                        entry.surface.resize_overlay_last_rows = entry.surface.size.grid.rows;
                    }
                }
                return;
            }

            // A click on a preview's top-right × button closes that preview, so
            // users who don't know the close-split keybind can dismiss it with
            // the mouse. Checked before the focus/drag path below (the button
            // sits inside the pane rect).
            if (split_layout.previewCloseButtonAtPoint(ev.x, ev.y)) |close_handle| {
                closePreviewPaneByHandle(close_handle);
                return;
            }

            // A click on a preview leaf focuses it (so keyboard/wheel scroll-zoom
            // route there) and consumes the event — previews have no terminal
            // grid to select into. Terminal leaves fall through to the surface
            // focus + selection path below, so non-preview clicks are unchanged.
            // A ready image/PDF preview additionally starts a drag-to-pan.
            if (split_layout.paneAtPoint(ev.x, ev.y)) |hit| {
                switch (hit.pane) {
                    .preview => |p| {
                        const tb = AppWindow.activeTab() orelse return;
                        if (tb.focused != hit.handle) {
                            tb.focused = hit.handle;
                            requestInputRepaint();
                        }
                        if (AppWindow.g_allocator) |gpa| {
                            if (g_preview_image_drag.begin(gpa, p, xpos, ypos))
                                platform_cursor.set(.size_all);
                        }
                        return;
                    },
                    .terminal => {},
                }
            }

            handleTerminalSelectionPress(ev, xpos, ypos);
        } else {
            // Mouse up
            if (g_preview_image_drag.active()) {
                releasePreviewImageDrag();
                platform_cursor.set(.arrow);
                return;
            }
            overlays.scrollbar.g_scrollbar_dragging = false;
            g_scrollbar_drag_surface = null;
            g_ai_input_scroll_dragging = false;
            g_ai_input_scroll_chat = null;
            g_ai_transcript_scroll_dragging = false;
            g_ai_transcript_scroll_chat = null;
            g_ai_transcript_scroll_panel = .active_chat;
            AppWindow.assistant_conversation_renderer.g_transcript_scrollbar_dragging = false;
            if (g_ai_transcript_selecting) {
                if (g_ai_transcript_select_chat) |chat| {
                    if (chat.finishTranscriptSelection() and g_ai_transcript_select_auto_copy) copyAiChatToClipboard(chat);
                }
                g_ai_transcript_selecting = false;
                g_ai_transcript_select_chat = null;
                g_ai_transcript_select_auto_copy = false;
                g_ai_transcript_select_panel = .active_chat;
                requestInputRepaint();
                platform_cursor.set(.arrow);
                return;
            }
            if (g_sidebar_resize_dragging) {
                g_sidebar_resize_dragging = false;
                g_sidebar_resize_hover = hitTestSidebarResizeHandle(xpos, ypos);
                platform_cursor.set(if (g_sidebar_resize_hover) .size_we else .arrow);
                return;
            }
            if (g_explorer_resize_dragging) {
                g_explorer_resize_dragging = false;
                g_explorer_resize_hover = hitTestFileExplorerResizeHandle(xpos, ypos);
                platform_cursor.set(if (g_explorer_resize_hover) .size_we else .arrow);
                return;
            }
            if (g_browser_resize_dragging) {
                g_browser_resize_dragging = false;
                g_browser_resize_hover = hitTestBrowserResizeHandle(xpos, ypos);
                platform_cursor.set(if (g_browser_resize_hover) .size_we else .arrow);
                return;
            }
            if (g_ai_copilot_resize_dragging) {
                g_ai_copilot_resize_dragging = false;
                g_ai_copilot_resize_hover = hitTestAiCopilotResizeHandle(xpos, ypos);
                platform_cursor.set(if (g_ai_copilot_resize_hover) .size_we else .arrow);
                return;
            }

            // Handle Alt-drag panel swap release (performs the swap if valid).
            if (finishPanelSwapDrag()) return;

            // Handle divider drag release
            if (g_divider_dragging) {
                g_divider_dragging = false;
                g_divider_drag_handle = null;
                g_divider_drag_layout = null;
                // Reset per-surface resize overlay state
                if (AppWindow.activeTab()) |tb| {
                    var it = tb.tree.surfaces();
                    while (it.next()) |entry| {
                        entry.surface.resize_overlay_active = false;
                    }
                }
                // Cursor will be reset in handleMouseMove
                return;
            }

            if (finishSidebarTabDrag()) {
                return;
            }

            // Handle close button release — close tab if still on the close button
            if (tab.g_tab_close_pressed) |pressed_idx| {
                tab.g_tab_close_pressed = null;
                if (pressed_idx < tab.g_tab_count and hitTestSidebarTabCloseButton(xpos, ypos, pressed_idx)) {
                    requestCloseTabGesture(pressed_idx);
                }
                return;
            }

            if (plus_btn_pressed) {
                plus_btn_pressed = false;
                // Only fire if still in the + button area
                if (hitTestSidebarPlusButton(xpos, ypos)) {
                    overlays.sessionLauncherOpen();
                }
                return;
            }
            if (AppWindow.g_copy_on_select and g_selection_changed_for_copy and activeTerminalSelectionExists()) {
                copySelectionToClipboard();
            }
            g_selection_changed_for_copy = false;
            g_selecting = false;
        }
    }
}

fn handleTabBarPress(xpos: f64) void {
    // Commit any active rename when clicking in the tab bar
    if (tab.g_tab_rename_active) {
        tab.commitTabRename();
    }
    const window_width = currentClientWidthOr(800.0) orelse return;

    const caption_area_w: f64 = 46 * 3;
    const gap_w: f64 = 42;
    const plus_btn_w: f64 = 46;
    const show_plus = tab.g_tab_count > 1;
    const num_tabs = tab.g_tab_count;

    const plus_total: f64 = if (show_plus) plus_btn_w else 0;
    const right_reserved: f64 = caption_area_w + gap_w + plus_total;
    const tab_area_w: f64 = window_width - right_reserved;
    const tab_w: f64 = if (num_tabs > 0) tab_area_w / @as(f64, @floatFromInt(num_tabs)) else tab_area_w;

    // Check which tab was clicked — also check close button
    var cursor: f64 = 0;
    for (0..num_tabs) |tab_idx| {
        if (xpos >= cursor and xpos < cursor + tab_w) {
            // Check if the close button was clicked (centered on shortcut position)
            if (num_tabs > 1 and tab.g_tab_close_opacity[tab_idx] > 0.1) {
                const sc_w: f64 = @floatCast(titlebar.titlebarGlyphAdvance(titlebar.tab_shortcut_modifier_cp) + titlebar.titlebarGlyphAdvance(if (tab_idx == 9) @as(u32, '0') else @as(u32, @intCast('1' + tab_idx))));
                const sc_center = cursor + tab_w - 12 - sc_w / 2;
                const close_btn_x = sc_center - tab.TAB_CLOSE_BTN_W / 2;
                if (xpos >= close_btn_x and xpos < close_btn_x + tab.TAB_CLOSE_BTN_W) {
                    tab.g_tab_close_pressed = tab_idx;
                    return;
                }
            }
            AppWindow.switchTab(tab_idx);
            return;
        }
        cursor += tab_w;
    }

    // Check if + button was pressed
    if (show_plus and xpos >= cursor and xpos < cursor + plus_btn_w) {
        plus_btn_pressed = true;
    }
}

fn hitTestTab(xpos: f64) ?usize {
    const window_width = currentClientWidthOr(800.0) orelse return null;

    const caption_area_w: f64 = 46 * 3;
    const gap_w: f64 = 42;
    const plus_btn_w: f64 = 46;
    const show_plus = tab.g_tab_count > 1;
    const num_tabs = tab.g_tab_count;

    const plus_total: f64 = if (show_plus) plus_btn_w else 0;
    const right_reserved: f64 = caption_area_w + gap_w + plus_total;
    const tab_area_w: f64 = window_width - right_reserved;
    const tab_w: f64 = if (num_tabs > 0) tab_area_w / @as(f64, @floatFromInt(num_tabs)) else tab_area_w;

    var cursor: f64 = 0;
    for (0..num_tabs) |tab_idx| {
        if (xpos >= cursor and xpos < cursor + tab_w) {
            return tab_idx;
        }
        cursor += tab_w;
    }
    return null;
}

fn hitTestTabCloseButton(xpos: f64, tab_idx: usize) bool {
    const window_width = currentClientWidthOr(800.0) orelse 800.0;

    const caption_area_w: f64 = 46 * 3;
    const gap_w: f64 = 42;
    const plus_btn_w: f64 = 46;
    const show_plus = tab.g_tab_count > 1;
    const num_tabs = tab.g_tab_count;

    const plus_total: f64 = if (show_plus) plus_btn_w else 0;
    const right_reserved: f64 = caption_area_w + gap_w + plus_total;
    const tab_area_w: f64 = window_width - right_reserved;
    const tab_w: f64 = if (num_tabs > 0) tab_area_w / @as(f64, @floatFromInt(num_tabs)) else tab_area_w;

    const tab_x = tab_w * @as(f64, @floatFromInt(tab_idx));
    const sc_w: f64 = @floatCast(titlebar.titlebarGlyphAdvance(titlebar.tab_shortcut_modifier_cp) + titlebar.titlebarGlyphAdvance(if (tab_idx == 9) @as(u32, '0') else @as(u32, @intCast('1' + tab_idx))));
    const sc_center = tab_x + tab_w - 12 - sc_w / 2;
    const close_btn_x = sc_center - tab.TAB_CLOSE_BTN_W / 2;
    return xpos >= close_btn_x and xpos < close_btn_x + tab.TAB_CLOSE_BTN_W;
}

fn hitTestPlusButton(xpos: f64) bool {
    const window_width = currentClientWidthOr(800.0) orelse return false;

    const caption_area_w: f64 = 46 * 3;
    const gap_w: f64 = 42;
    const plus_btn_w: f64 = 46;
    if (tab.g_tab_count <= 1) return false;

    const right_reserved: f64 = caption_area_w + gap_w + plus_btn_w;
    const tab_area_w: f64 = window_width - right_reserved;
    const tab_w: f64 = tab_area_w / @as(f64, @floatFromInt(tab.g_tab_count));
    const plus_x = tab_w * @as(f64, @floatFromInt(tab.g_tab_count));

    return xpos >= plus_x and xpos < plus_x + plus_btn_w;
}

fn applyAiInputScrollbarDrag(chat: *AppWindow.ai_chat.Session, ypos: f64) void {
    const win = AppWindow.g_window orelse return;
    const size = clientSize(win);
    if (AppWindow.assistant_conversation_renderer.inputScrollbarDragRowAt(
        chat,
        ypos,
        @floatFromInt(size.width),
        @floatFromInt(size.height),
        AppWindow.leftPanelsWidth(),
        @as(f32, @floatFromInt(size.width)) - AppWindow.leftPanelsWidth() - AppWindow.rightPanelsWidthForWindow(size.width),
        g_ai_input_scroll_drag_offset,
    )) |drag| {
        _ = chat.setInputScrollRow(drag.row, drag.max_cols, drag.visible_rows);
        requestInputRepaint();
    }
}

fn applyAiTranscriptScrollbarDrag(chat: *AppWindow.ai_chat.Session, ypos: f64) void {
    const geometry = aiTranscriptPanelGeometry(g_ai_transcript_scroll_panel) orelse return;
    if (AppWindow.assistant_conversation_renderer.transcriptScrollbarScrollPxAt(
        chat,
        ypos,
        geometry.window_width,
        geometry.window_height,
        @floatCast(titlebarHeight()),
        geometry.chat_x,
        geometry.chat_w,
        g_ai_transcript_scroll_drag_offset,
    )) |px| {
        chat.scrollToPx(px);
        requestInputRepaint();
    }
}

fn updateAiTranscriptSelectionDrag(chat: *AppWindow.ai_chat.Session, xpos: f64, ypos: f64) void {
    const geometry = aiTranscriptPanelGeometry(g_ai_transcript_select_panel) orelse return;
    if (AppWindow.assistant_conversation_renderer.transcriptTextHitTest(
        chat,
        xpos,
        ypos,
        geometry.window_width,
        geometry.window_height,
        @floatCast(titlebarHeight()),
        geometry.chat_x,
        geometry.chat_w,
    )) |hit| {
        chat.updateTranscriptSelection(hit.message_index, hit.byte_offset);
        requestInputRepaint();
    }
}

fn handleMouseMove(ev: platform_input.MouseMoveEvent) void {
    const xpos: f64 = @floatFromInt(ev.x);
    const ypos: f64 = @floatFromInt(ev.y);
    if (g_sidebar_resize_dragging) {
        applySidebarWidthFromMouse(xpos);
        platform_cursor.set(.size_we);
        return;
    }
    if (g_explorer_resize_dragging) {
        applyExplorerWidthFromMouse(xpos);
        platform_cursor.set(.size_we);
        return;
    }
    if (g_browser_resize_dragging) {
        applyBrowserWidthFromMouse(xpos);
        platform_cursor.set(.size_we);
        return;
    }
    if (g_ai_copilot_resize_dragging) {
        applyAiCopilotWidthFromMouse(xpos);
        platform_cursor.set(.size_we);
        return;
    }
    if (g_ai_input_scroll_dragging) {
        if (g_ai_input_scroll_chat) |chat| applyAiInputScrollbarDrag(chat, ypos);
        return;
    }
    if (g_ai_transcript_scroll_dragging) {
        if (g_ai_transcript_scroll_chat) |chat| applyAiTranscriptScrollbarDrag(chat, ypos);
        return;
    }
    if (g_ai_transcript_selecting) {
        if (g_ai_transcript_select_chat) |chat| updateAiTranscriptSelectionDrag(chat, xpos, ypos);
        platform_cursor.set(.ibeam);
        return;
    }
    // Left-drag pans a ready image/PDF preview (the renderer clamps the pan to
    // the raster content's overflow each frame).
    if (g_preview_image_drag.active()) {
        if (g_preview_image_drag.move(xpos, ypos)) requestInputRebuild();
        platform_cursor.set(.size_all);
        return;
    }
    // Alt-drag panel swap: track the drop target / dim the source. Owns the move
    // while a swap source is recorded, so it must precede PTY mouse-report and
    // selection handling below.
    if (updatePanelSwapDrag(ev.x, ev.y)) return;

    // Reported mouse drag: stream motion to the PTY (button/any tracking
    // modes) and suppress local hover/selection while the button is held.
    if (g_mouse_report.active()) |button| {
        if (g_mouse_report.activeSurface()) |surface| reportMouseMotion(surface, button, ev);
        return;
    }

    if (AppWindow.g_window) |hover_win| {
        if (AppWindow.activeAiChat()) |chat| {
            const hover_fb = window_backend.framebufferSize(hover_win);
            const over = AppWindow.assistant_conversation_renderer.transcriptScrollbarHitTest(
                chat,
                xpos,
                ypos,
                @floatFromInt(hover_fb.width),
                @floatFromInt(hover_fb.height),
                @floatCast(titlebarHeight()),
                AppWindow.leftPanelsWidth(),
                @as(f32, @floatFromInt(hover_fb.width)) - AppWindow.leftPanelsWidth() - AppWindow.rightPanelsWidthForWindow(hover_fb.width),
            ) != null;
            if (over != AppWindow.assistant_conversation_renderer.g_transcript_scrollbar_hover) {
                AppWindow.assistant_conversation_renderer.g_transcript_scrollbar_hover = over;
                requestInputRebuild();
            }
        } else if (AppWindow.assistant_conversation_renderer.g_transcript_scrollbar_hover) {
            AppWindow.assistant_conversation_renderer.g_transcript_scrollbar_hover = false;
            requestInputRebuild();
        }
    }
    if (updateSidebarTabDrag(xpos, ypos)) return;

    // Handle divider dragging
    if (g_divider_dragging) {
        if (g_divider_drag_handle) |handle| {
            const active_tab = AppWindow.activeTab() orelse return;
            const allocator = AppWindow.g_allocator orelse return;

            // Get spatial info for this split
            var spatial = active_tab.tree.spatial(allocator) catch return;
            defer spatial.deinit(allocator);

            // Get content area dimensions
            const win = AppWindow.g_window orelse return;
            const fb = window_backend.framebufferSize(win);
            const left_panels_w = AppWindow.leftPanelsWidth();
            const right_panels_w = AppWindow.rightPanelsWidthForWindow(fb.width);
            const content_x: f32 = left_panels_w + @as(f32, @floatFromInt(split_layout.DEFAULT_PADDING));
            const content_y: f32 = @floatCast(titlebarHeight());
            const content_w: f32 = @as(f32, @floatFromInt(fb.width)) - left_panels_w - right_panels_w - @as(f32, @floatFromInt(2 * split_layout.DEFAULT_PADDING));
            const content_h: f32 = @as(f32, @floatFromInt(fb.height)) - content_y - @as(f32, @floatFromInt(split_layout.DEFAULT_PADDING));

            const slot = spatial.slots[handle.idx()];
            const layout = g_divider_drag_layout orelse return;

            // Calculate new ratio based on mouse position
            const new_ratio: f16 = switch (layout) {
                .horizontal => blk: {
                    const slot_x = content_x + @as(f32, @floatCast(slot.x)) * content_w;
                    const slot_w = @as(f32, @floatCast(slot.width)) * content_w;
                    const mouse_x: f32 = @floatCast(xpos);
                    // Clamp ratio to 0.1-0.9 to prevent splits from becoming too small
                    break :blk @floatCast(@max(0.1, @min(0.9, (mouse_x - slot_x) / slot_w)));
                },
                .vertical => blk: {
                    const slot_y = content_y + @as(f32, @floatCast(slot.y)) * content_h;
                    const slot_h = @as(f32, @floatCast(slot.height)) * content_h;
                    const mouse_y: f32 = @floatCast(ypos);
                    break :blk @floatCast(@max(0.1, @min(0.9, (mouse_y - slot_y) / slot_h)));
                },
            };

            // Update the ratio in place
            active_tab.tree.resizeInPlace(handle, new_ratio);

            // Force layout recalculation and redraw
            requestInputRepaint();
        }
        return;
    }
    if (!g_selecting and !overlays.scrollbar.g_scrollbar_dragging) {
        if (hitTestAiCopilotCloseButton(xpos, ypos)) {
            platform_cursor.set(.arrow);
            return;
        }
        const over_sidebar_resize = hitTestSidebarResizeHandle(xpos, ypos);
        if (over_sidebar_resize) {
            platform_cursor.set(.size_we);
            g_sidebar_resize_hover = true;
            return;
        } else if (g_sidebar_resize_hover) {
            platform_cursor.set(.arrow);
            g_sidebar_resize_hover = false;
        }
        const over_explorer_resize = hitTestFileExplorerResizeHandle(xpos, ypos);
        if (over_explorer_resize) {
            platform_cursor.set(.size_we);
            g_explorer_resize_hover = true;
            return;
        } else if (g_explorer_resize_hover) {
            platform_cursor.set(.arrow);
            g_explorer_resize_hover = false;
        }
        const over_browser_resize = hitTestBrowserResizeHandle(xpos, ypos);
        if (over_browser_resize) {
            platform_cursor.set(.size_we);
            g_browser_resize_hover = true;
            return;
        } else if (g_browser_resize_hover) {
            platform_cursor.set(.arrow);
            g_browser_resize_hover = false;
        }
        const over_ai_copilot_resize = hitTestAiCopilotResizeHandle(xpos, ypos);
        if (over_ai_copilot_resize) {
            platform_cursor.set(.size_we);
            g_ai_copilot_resize_hover = true;
            return;
        } else if (g_ai_copilot_resize_hover) {
            platform_cursor.set(.arrow);
            g_ai_copilot_resize_hover = false;
        }
        // Closed-state Copilot summon handle: reveal as the cursor nears the edge.
        if (!AppWindow.aiCopilotVisible()) {
            const handle_eligible = copilot_hint_gate.handleEligible(
                AppWindow.g_copilot_hint,
                AppWindow.aiCopilotVisible(),
                AppWindow.isActiveTabTerminal(),
                AppWindow.anyRightDockPanelVisible(),
            );
            if (handle_eligible) {
                if (AppWindow.g_window) |handle_win| {
                    const handle_fb = window_backend.framebufferSize(handle_win);
                    const tgt = copilot_hint_gate.handleRevealTarget(
                        @floatCast(xpos),
                        @floatCast(ypos),
                        @floatFromInt(handle_fb.width),
                        @floatCast(titlebarHeight()),
                        overlays.copilot_edge_handle.REVEAL_ZONE_W,
                        overlays.copilot_edge_handle.REVEALED_ALPHA,
                    );
                    overlays.copilotEdgeHandleSetTarget(tgt);
                    const handle_hovered = hitTestCopilotEdgeHandle(xpos, ypos);
                    overlays.copilotEdgeHandleSetHovered(handle_hovered);
                    // Only repaint while the handle is actually near/visible — avoids a
                    // full rebuild on every mouse move across the terminal when it is hidden.
                    if (tgt > 0 or handle_hovered) requestInputRebuild();
                    if (handle_hovered) {
                        platform_cursor.set(.arrow);
                        return;
                    }
                }
            } else {
                overlays.copilotEdgeHandleSetTarget(0);
                overlays.copilotEdgeHandleSetHovered(false);
            }
        }
    }

    if (hitTestBrowserPanel(xpos, ypos)) {
        clearUrlUnderline();
        return;
    }

    // Focus follows mouse: check if mouse is over a different split
    if (AppWindow.g_focus_follows_mouse) {
        updateFocusFromMouse(@intFromFloat(xpos), @intFromFloat(ypos));
    }
    updateInteractiveUnderlineAtMouse(xpos, ypos, ev.ctrl, ev.shift, ev.alt, ev.super);

    // Update scrollbar hover state
    const win = AppWindow.g_window orelse return;
    const fb = window_backend.framebufferSize(win);
    const w_f: f32 = @floatFromInt(fb.width);
    const h_f: f32 = @floatFromInt(fb.height);
    const tb_f: f32 = @floatCast(titlebarHeight());
    const top_pad: f32 = 10 + tb_f;

    const was_hover = overlays.scrollbar.g_scrollbar_hover;
    overlays.scrollbar.g_scrollbar_hover = false;
    if (scrollbarTargetAt(xpos, ypos, w_f, h_f, top_pad)) |target| {
        overlays.scrollbar.g_scrollbar_hover = true;
        if (!was_hover) overlays.scrollbarShowForSurface(target.surface);
    }

    // Handle scrollbar drag
    if (overlays.scrollbar.g_scrollbar_dragging) {
        if (g_scrollbar_drag_surface) |surface| {
            overlays.scrollbarDragForSurface(surface, ypos, g_scrollbar_drag_view_y, g_scrollbar_drag_view_h, g_scrollbar_drag_top_pad);
        } else {
            overlays.scrollbarDrag(ypos, h_f, top_pad);
        }
        return;
    }

    // Check for divider hover and update cursor
    if (!overlays.scrollbar.g_scrollbar_hover and !g_selecting) {
        if (split_layout.hitTestDivider(ev.x, ev.y)) |hit| {
            // Set resize cursor based on layout
            const cursor_shape: platform_cursor.Shape = switch (hit.layout) {
                .horizontal => .size_we, // left-right resize
                .vertical => .size_ns, // up-down resize
            };
            platform_cursor.set(cursor_shape);
            g_divider_hover = true;
        } else if (g_divider_hover) {
            // Reset to default cursor when leaving divider
            platform_cursor.set(.arrow);
            g_divider_hover = false;
        }
    }

    // Track which preview's × button (if any) the mouse is over, so the renderer
    // can brighten it. Re-render only when the hovered button changes.
    const new_close_hover = if (!g_selecting) split_layout.previewCloseButtonAtPoint(ev.x, ev.y) else null;
    if (new_close_hover != g_preview_close_hover) {
        g_preview_close_hover = new_close_hover;
        requestInputRepaint();
    }

    // Normal selection handling
    if (!g_selecting) return;

    const surface = AppWindow.activeSurface() orelse return;
    updateDragSelection(surface, xpos, ypos);
}

fn appendBytes(out: *[512]u8, len: *usize, bytes: []const u8) bool {
    if (len.* + bytes.len > out.len) return false;
    @memcpy(out[len.* .. len.* + bytes.len], bytes);
    len.* += bytes.len;
    return true;
}

fn appendByte(out: *[512]u8, len: *usize, byte: u8) bool {
    if (len.* >= out.len) return false;
    out[len.*] = byte;
    len.* += 1;
    return true;
}

fn appendFmt(out: *[512]u8, len: *usize, comptime fmt: []const u8, args: anytype) bool {
    const written = std.fmt.bufPrint(out[len.*..], fmt, args) catch return false;
    len.* += written.len;
    return true;
}

fn mouseWheelUnits(delta: i16) usize {
    const notches = @abs(@as(i32, delta));
    return @max(@as(usize, 1), @as(usize, @intCast((notches * 3 + 119) / 120)));
}

fn appendMouseWheelReport(surface: *Surface, ev: platform_input.MouseWheelEvent, out: *[512]u8, len: *usize) bool {
    if (surface.terminal.flags.mouse_event == .none or surface.terminal.flags.mouse_event == .x10) return false;

    var button_code: u8 = if (ev.delta > 0) 64 else 65; // xterm wheel up/down buttons 4/5
    if (ev.shift) button_code += 4;
    if (ev.alt) button_code += 8;
    if (ev.ctrl) button_code += 16;

    const cell = mouseToSurfaceCell(surface, @floatFromInt(ev.xpos), @floatFromInt(ev.ypos));
    const x = cell.col + 1;
    const y = cell.row + 1;

    switch (surface.terminal.flags.mouse_format) {
        .sgr => return appendFmt(out, len, "\x1b[<{d};{d};{d}M", .{ button_code, x, y }),
        .urxvt => return appendFmt(out, len, "\x1b[{d};{d};{d}M", .{ 32 + @as(u16, button_code), x, y }),
        .sgr_pixels => {
            const pixel = mouseToSurfacePixel(surface, ev.xpos, ev.ypos);
            return appendFmt(out, len, "\x1b[<{d};{d};{d}M", .{ button_code, @max(0, pixel.x), @max(0, pixel.y) });
        },
        .x10, .utf8 => {
            if (cell.col > 222 or cell.row > 222) return false;
            if (!appendBytes(out, len, "\x1b[M")) return false;
            if (!appendByte(out, len, 32 + button_code)) return false;
            if (!appendByte(out, len, 32 + @as(u8, @intCast(cell.col)) + 1)) return false;
            if (!appendByte(out, len, 32 + @as(u8, @intCast(cell.row)) + 1)) return false;
            return true;
        },
    }
}

fn appendAlternateScrollKeys(surface: *Surface, ev: platform_input.MouseWheelEvent, out: *[512]u8, len: *usize) bool {
    if (surface.terminal.screens.active_key != .alternate) return false;
    if (surface.terminal.flags.mouse_event != .none) return false;
    if (!surface.terminal.modes.get(.mouse_alternate_scroll)) return false;

    const seq = if (surface.terminal.modes.get(.cursor_keys))
        if (ev.delta > 0) "\x1bOA" else "\x1bOB"
    else if (ev.delta > 0) "\x1b[A" else "\x1b[B";

    for (0..mouseWheelUnits(ev.delta)) |_| {
        if (!appendBytes(out, len, seq)) return false;
    }
    return true;
}

// --- Terminal mouse button reporting --------------------------------------
// Companion to appendMouseWheelReport: encodes button presses, releases and
// drags so mouse-aware TUIs (nvim, tmux, htop) receive clicks, not just wheel
// scrolls. The pure protocol encoder lives in input/mouse_report.zig; these
// helpers map ghostty-vt's flags onto it and deliver the bytes to the PTY.

// Map ghostty-vt's mouse flags onto the local encoder enums. Typed `anytype`
// because the enums aren't re-exported from the ghostty-vt module root; the
// switch over enum literals coerces to whatever enum the flags field holds
// (the same literals the wheel path compares against in appendMouseWheelReport).
fn mouseReportEvent(mode: anytype) mouse_report.Event {
    return switch (mode) {
        .none => .none,
        .x10 => .x10,
        .normal => .normal,
        .button => .button,
        .any => .any,
    };
}

fn mouseReportFormat(fmt: anytype) mouse_report.Format {
    return switch (fmt) {
        .x10 => .x10,
        .utf8 => .utf8,
        .sgr => .sgr,
        .urxvt => .urxvt,
        .sgr_pixels => .sgr_pixels,
    };
}

fn platformMouseButton(button: platform_input.MouseButton) mouse_report.Button {
    return switch (button) {
        .left => .left,
        .middle => .middle,
        .right => .right,
    };
}

/// Encode and deliver one mouse button/motion event to the surface's PTY.
/// Returns true if bytes were written (false when the active mode does not
/// report this event — e.g. motion in normal mode, or no tracking at all).
fn sendTerminalMouseReport(
    surface: *Surface,
    action: mouse_report.Action,
    button: ?mouse_report.Button,
    x_px: i32,
    y_px: i32,
    mods: mouse_report.Mods,
) bool {
    var buf: [512]u8 = undefined;
    var len: usize = 0;
    surface.render_state.mutex.lock();
    const mode = mouseReportEvent(surface.terminal.flags.mouse_event);
    const fmt = mouseReportFormat(surface.terminal.flags.mouse_format);
    if (mode == .none) {
        surface.render_state.mutex.unlock();
        return false;
    }
    const cell = mouseToSurfaceCell(surface, @floatFromInt(x_px), @floatFromInt(y_px));
    const pixel = mouseToSurfacePixel(surface, x_px, y_px);
    _ = mouse_report.encode(mode, fmt, action, button, mods, cell.col, cell.row, pixel.x, pixel.y, &buf, &len);
    surface.render_state.mutex.unlock();
    if (len == 0) return false;
    writeToPty(surface, buf[0..len]);
    return true;
}

/// True when the AI copilot sidebar is shown and covers (xf, yf).
fn aiCopilotRegionContains(xf: f64, yf: f64) bool {
    if (!AppWindow.aiCopilotVisible()) return false;
    const win = AppWindow.g_window orelse return false;
    const fb = window_backend.framebufferSize(win);
    const bounds = ai_sidebar.boundsForWindow(
        @intCast(fb.width),
        @intCast(fb.height),
        @floatCast(titlebarHeight()),
        AppWindow.leftPanelsWidth(),
        0,
    );
    return xf >= @as(f64, @floatFromInt(bounds.left)) and xf < @as(f64, @floatFromInt(bounds.right)) and
        yf >= @as(f64, @floatFromInt(bounds.top)) and yf < @as(f64, @floatFromInt(bounds.bottom));
}

/// The surface that should receive a mouse report for an event at (x, y), or
/// null when the point is over window chrome / side panels or the focused
/// program has not enabled mouse tracking. Mirrors the chrome exclusions the
/// left-press path walks before it reaches terminal content.
fn terminalMouseReportTarget(x_i: i32, y_i: i32) ?*Surface {
    const xf: f64 = @floatFromInt(x_i);
    const yf: f64 = @floatFromInt(y_i);
    if (yf < titlebarHeight()) return null; // titlebar
    if (AppWindow.activeAiChat() != null) return null; // AI chat tab: no terminal
    if (tab.g_sidebar_visible and xf < @as(f64, @floatCast(titlebar.sidebarWidth()))) return null;
    if (hitTestFileExplorer(xf, yf)) return null;
    if (hitTestBrowserUrlBar(xf, yf)) return null;
    if (hitTestBrowserPanel(xf, yf)) return null;
    if (aiCopilotRegionContains(xf, yf)) return null;
    const surface = split_layout.surfaceAtPoint(x_i, y_i) orelse return null;
    surface.render_state.mutex.lock();
    const mode = surface.terminal.flags.mouse_event;
    surface.render_state.mutex.unlock();
    if (mode == .none) return null;
    return surface;
}

/// Begin a reported press for an event that landed on terminal content.
/// Returns true if the press was consumed (delivered to the PTY).
fn beginTerminalMouseReport(ev: platform_input.MouseButtonEvent) bool {
    const surface = terminalMouseReportTarget(ev.x, ev.y) orelse return false;
    const button = platformMouseButton(ev.button);
    updateFocusFromMouse(ev.x, ev.y);
    _ = sendTerminalMouseReport(surface, .press, button, ev.x, ev.y, .{
        .shift = ev.shift,
        .alt = ev.alt,
        .ctrl = ev.ctrl,
    });
    g_mouse_report.begin(surface, button);
    return true;
}

/// Finish a reported drag on button release (wherever the pointer ends up, and
/// regardless of modifiers) so the app always sees button-up and state never
/// leaks. Returns true if a matching reported press was in progress.
fn finishTerminalMouseReport(ev: platform_input.MouseButtonEvent) bool {
    const result = g_mouse_report.finishRelease(platformMouseButton(ev.button));
    if (!result.matched) return false;
    if (result.surface) |s| {
        _ = sendTerminalMouseReport(s, .release, result.button, ev.x, ev.y, .{
            .shift = ev.shift,
            .alt = ev.alt,
            .ctrl = ev.ctrl,
        });
    }
    return true;
}

/// Stream a drag-motion report while a reported press is held, deduplicated by
/// cell so we don't flood the PTY with one report per pixel.
fn reportMouseMotion(surface: *Surface, button: mouse_report.Button, ev: platform_input.MouseMoveEvent) void {
    const cell = blk: {
        surface.render_state.mutex.lock();
        defer surface.render_state.mutex.unlock();
        break :blk mouseToSurfaceCell(surface, @floatFromInt(ev.x), @floatFromInt(ev.y));
    };
    if (!g_mouse_report.motionShouldReport(.{ .col = cell.col, .row = cell.row })) return;
    _ = sendTerminalMouseReport(surface, .motion, button, ev.x, ev.y, .{
        .shift = ev.shift,
        .alt = ev.alt,
        .ctrl = ev.ctrl,
    });
}

fn handleMouseWheel(ev: platform_input.MouseWheelEvent) void {
    overlays.startupShortcutsDismiss();
    if (overlays.whatsNewVisible()) {
        overlays.whatsNewHandleScroll(@floatFromInt(ev.delta));
        requestInputRebuild();
        return;
    }
    if (overlays.integrationPromptVisible()) {
        overlays.integrationPromptHandleScroll(@floatFromInt(ev.delta));
        requestInputRepaint();
        return;
    }
    if (overlays.settingsPageVisible()) {
        overlays.settingsPageHandleScroll(@floatFromInt(ev.delta));
        requestInputRebuild();
        return;
    }
    if (overlays.commandPaletteVisible()) {
        overlays.commandPaletteHandleScroll(@floatFromInt(ev.delta));
        requestInputRepaint();
        return;
    }
    if (overlays.sessionLauncherVisible()) {
        overlays.sessionLauncherHandleScroll(@floatFromInt(ev.delta));
        requestInputRepaint();
        return;
    }
    if (copilot_picker.isVisible()) {
        copilot_picker.move(if (ev.delta > 0) -1 else 1);
        requestInputRepaint();
        return;
    }
    if (jupyter_picker.isVisible()) {
        jupyter_picker.move(if (ev.delta > 0) -1 else 1);
        requestInputRepaint();
        return;
    }
    if (tab.g_sidebar_visible and ev.xpos >= 0 and ev.xpos < @as(i32, @intFromFloat(titlebar.sidebarWidth()))) return;
    if (hitTestBrowserPanel(@floatFromInt(ev.xpos), @floatFromInt(ev.ypos))) return;
    // Scroll in file explorer
    if (file_explorer.isVisibleForActiveTab()) {
        const panel_x = @as(i32, @intFromFloat(titlebar.sidebarWidth()));
        const panel_right = @as(i32, @intFromFloat(titlebar.sidebarWidth() + file_explorer.width()));
        if (ev.xpos >= panel_x and ev.xpos < panel_right) {
            const delta: f32 = -@as(f32, @floatFromInt(ev.delta)) * file_explorer.rowHeight() * 3 / 120.0;
            file_explorer.scrollBy(delta);
            // Request a frame so the new offset is drawn now; otherwise the panel
            // only redraws on the next cursor-blink tick (~600ms) → stuttery scroll.
            // The explorer draws above the terminal cell grid, so leave
            // g_cells_valid untouched — no need to rebuild the cells underneath.
            requestInputRebuild();
            return;
        }
    }
    // AI History transcript preview: scroll the wrapped transcript when the
    // wheel is over the detail (rightmost) pane.
    if (AppWindow.activeAiHistory() != null) {
        const win = AppWindow.g_window orelse return;
        const size = clientSize(win);
        const left_f = AppWindow.leftPanelsWidth();
        const right_f = @as(f32, @floatFromInt(size.width)) - AppWindow.rightPanelsWidthForWindow(size.width);
        const content_w = @max(0, right_f - left_f);
        const layout = AppWindow.terminal_agent_sessions_renderer.computeLayout(left_f, content_w);
        const x: f32 = @floatFromInt(ev.xpos);
        if (x >= layout.detail_x and x < layout.detail_x + layout.detail_w) {
            const units: i32 = @intCast(mouseWheelUnits(ev.delta));
            const step = units * 3;
            _ = AppWindow.aiHistoryScrollTranscript(if (ev.delta > 0) -step else step);
            return;
        }
        if (x >= layout.left_x and x < layout.left_x + layout.left_w) {
            const units: i32 = @intCast(mouseWheelUnits(ev.delta));
            _ = AppWindow.aiHistoryScrollDateList(if (ev.delta > 0) -units else units);
            return;
        }
        return;
    }
    if (AppWindow.activeAiChat()) |chat| {
        const win = AppWindow.g_window orelse return;
        const size = clientSize(win);
        const left = @as(i32, @intFromFloat(AppWindow.leftPanelsWidth()));
        const right = size.width - @as(i32, @intFromFloat(AppWindow.rightPanelsWidthForWindow(size.width)));
        if (ev.xpos >= left and ev.xpos < right) {
            if (AppWindow.assistant_conversation_renderer.inputFieldMetricsAt(
                chat,
                @floatFromInt(ev.xpos),
                @floatFromInt(ev.ypos),
                @floatFromInt(size.width),
                @floatFromInt(size.height),
                AppWindow.leftPanelsWidth(),
                @as(f32, @floatFromInt(size.width)) - AppWindow.leftPanelsWidth() - AppWindow.rightPanelsWidthForWindow(size.width),
            )) |metrics| {
                const units: i32 = @intCast(mouseWheelUnits(ev.delta));
                const rows = if (ev.delta > 0) -units else units;
                _ = chat.scrollInputRows(rows, metrics.max_cols, metrics.visible_rows);
                requestInputRepaint();
                return;
            }
            const delta: f32 = -@as(f32, @floatFromInt(ev.delta)) * 72.0 / 120.0;
            chat.scrollBy(delta);
            requestInputRebuild();
            return;
        }
    }
    // AI copilot sidebar (terminal tabs): scroll the copilot transcript (or its
    // composer when the cursor is over the input field) when the wheel event
    // falls inside the sidebar rect. Uses the same clientSize source as the
    // ai_chat-tab wheel path above so the rect matches what was hit-tested.
    if (AppWindow.aiCopilotVisible()) {
        if (AppWindow.activeCopilotSessionForInput()) |chat| {
            const win = AppWindow.g_window orelse return;
            const size = clientSize(win);
            const bounds = ai_sidebar.boundsForWindow(
                size.width,
                size.height,
                @floatCast(titlebarHeight()),
                AppWindow.leftPanelsWidth(),
                0,
            );
            if (ev.xpos >= bounds.left and ev.xpos < bounds.right and ev.ypos >= bounds.top and ev.ypos < bounds.bottom) {
                const chat_x: f32 = @floatFromInt(bounds.left);
                const chat_w: f32 = @floatFromInt(bounds.right - bounds.left);
                if (AppWindow.assistant_conversation_renderer.inputFieldMetricsAt(
                    chat,
                    @floatFromInt(ev.xpos),
                    @floatFromInt(ev.ypos),
                    @floatFromInt(size.width),
                    @floatFromInt(size.height),
                    chat_x,
                    chat_w,
                )) |metrics| {
                    const units: i32 = @intCast(mouseWheelUnits(ev.delta));
                    const rows = if (ev.delta > 0) -units else units;
                    _ = chat.scrollInputRows(rows, metrics.max_cols, metrics.visible_rows);
                    requestInputRepaint();
                    return;
                }
                const delta: f32 = -@as(f32, @floatFromInt(ev.delta)) * 72.0 / 120.0;
                chat.scrollBy(delta);
                requestInputRebuild();
                return;
            }
        }
    }
    // Wheel over a preview leaf scrolls/zooms that pane (mirroring the dock
    // preview wheel logic above) and consumes the event. Terminal leaves fall
    // through to the surface-scroll path below, so the default behavior is
    // unchanged when the cursor is not over a preview.
    if (split_layout.paneAtPoint(ev.xpos, ev.ypos)) |hit| {
        if (hit.pane == .preview) {
            const p = hit.pane.preview;
            if (p.kind.isRaster()) {
                // Continuous, per-event-bounded zoom: mouseWheelUnits is tuned
                // for line-scrolling and turns macOS precise/trackpad deltas
                // into a runaway 1.2^N zoom (see zoomImageByWheel).
                _ = p.zoomImageByWheel(ev.delta);
            } else {
                const delta: f32 = -@as(f32, @floatFromInt(ev.delta)) * 72.0 / 120.0;
                p.scrollBy(delta);
            }
            requestInputRebuild();
            return;
        }
    }
    // Scroll the surface under the mouse cursor (like Ghostty), not the focused surface.
    // Fall back to focused surface if mouse is not over any split.
    const surface = split_layout.surfaceAtPoint(ev.xpos, ev.ypos) orelse AppWindow.activeSurface() orelse return;

    var terminal_input_buf: [512]u8 = undefined;
    var terminal_input_len: usize = 0;
    var sent_to_terminal = false;

    surface.render_state.mutex.lock();
    if (surface.terminal.flags.mouse_event != .none) {
        for (0..mouseWheelUnits(ev.delta)) |_| {
            if (!appendMouseWheelReport(surface, ev, &terminal_input_buf, &terminal_input_len)) break;
        }
        sent_to_terminal = terminal_input_len > 0;
    } else if (appendAlternateScrollKeys(surface, ev, &terminal_input_buf, &terminal_input_len)) {
        sent_to_terminal = true;
    } else {
        // WHEEL_DELTA is 120 per notch. Convert to lines (3 lines per notch, like GLFW).
        const notches = @as(f64, @floatFromInt(ev.delta)) / 120.0;
        const delta: isize = @intFromFloat(-notches * 3);
        surface.terminal.scrollViewport(.{ .delta = delta });
        if (mouse_wheel_scroll.repaintFlagsForViewportScroll(delta)) |flags| {
            requestInputDirtyFlags(flags.force_rebuild, flags.cells_valid);
        }

        // Show scrollbar for the scrolled surface
        surface.scrollbar_opacity = 1.0;
        surface.scrollbar_show_time = std.time.milliTimestamp();
    }
    surface.render_state.mutex.unlock();

    if (g_selecting and !sent_to_terminal) {
        updateDragSelection(surface, @floatFromInt(ev.xpos), @floatFromInt(ev.ypos));
    }

    if (sent_to_terminal) {
        writeToPty(surface, terminal_input_buf[0..terminal_input_len]);
    }
}

fn updateDragSelection(surface: *Surface, xpos: f64, ypos: f64) void {
    const selection = &surface.selection;
    const cell_pos = mouseToSurfaceCell(surface, xpos, ypos);
    const abs_row = viewportOffsetForSurface(surface) + cell_pos.row;
    selection.has_anchor = true;
    selection.end_col = cell_pos.col;
    selection.end_row = abs_row;

    const threshold = font.cell_width * 0.6;
    const grid_left = blk: {
        if (splitRectForSurface(surface)) |rect| {
            const pad = surface.getPadding();
            break :blk @as(f64, @floatFromInt(rect.x)) + @as(f64, @floatFromInt(pad.left));
        }
        break :blk @as(f64, @floatCast(titlebar.sidebarWidth())) + 10;
    };
    const click_cell_x = g_click_x - grid_left - @as(f64, @floatFromInt(selection.start_col)) * @as(f64, @floatCast(font.cell_width));
    const drag_cell_x = xpos - grid_left - @as(f64, @floatFromInt(cell_pos.col)) * @as(f64, @floatCast(font.cell_width));

    const same_cell = (selection.start_col == cell_pos.col and selection.start_row == abs_row);
    if (same_cell) {
        const moved_right = drag_cell_x >= threshold and click_cell_x < threshold;
        const moved_left = drag_cell_x < threshold and click_cell_x >= threshold;
        selection.active = moved_right or moved_left;
    } else {
        selection.active = true;
    }

    markSelectionChanged();
}

fn toggleAiAgentPermission() void {
    const allocator = AppWindow.g_allocator orelse return;
    var cfg = Config.load(allocator) catch Config{};
    defer cfg.deinit(allocator);

    const next = switch (cfg.@"ai-agent-permission") {
        .confirm => "auto",
        .auto => "full",
        .full => "ask",
    };
    Config.setConfigValue(allocator, "ai-agent-permission", next) catch return;
    AppWindow.reloadConfigImmediate(allocator);
    requestInputRepaint();
}

// --- Maximize toggle (native window) ---

pub fn toggleMaximize() void {
    const win = AppWindow.g_window orelse return;
    const size = window_backend.clientSize(win);
    render_diagnostics.log(
        "toggle-maximize requested client={}x{} dpi={} full={} max={}",
        .{ size.width, size.height, window_backend.effectiveDpi(win), window_backend.isFullscreen(win), window_backend.isMaximized(win) },
    );

    if (window_backend.isFullscreen(win)) {
        toggleFullscreen();
        return;
    }

    window_backend.toggleMaximized(win);
}

// --- Fullscreen toggle (native window) ---

pub fn toggleFullscreen() void {
    const win = AppWindow.g_window orelse return;
    const size = window_backend.clientSize(win);
    render_diagnostics.log(
        "toggle-fullscreen requested client={}x{} dpi={} full={} max={}",
        .{ size.width, size.height, window_backend.effectiveDpi(win), window_backend.isFullscreen(win), window_backend.isMaximized(win) },
    );

    if (window_backend.isFullscreen(win)) {
        // Restore windowed mode
        window_backend.exitBorderlessFullscreen(win, fullscreen_restore_state);
        std.debug.print("Exited fullscreen\n", .{});
    } else {
        if (!window_backend.enterBorderlessFullscreen(win, &fullscreen_restore_state)) return;
        std.debug.print("Entered fullscreen\n", .{});
    }
}
