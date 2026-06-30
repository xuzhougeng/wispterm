const std = @import("std");
const settings_page = @import("settings_page.zig");
const toasts = @import("toasts.zig");
const confirm_modals = @import("confirm_modals.zig");
const ssh_profiles = @import("ssh_profiles.zig");
const assistant_profiles = @import("assistant_profiles.zig");
const feishu_config = @import("feishu_config.zig");
const quick_ai_config = @import("quick_ai_config.zig");
const session_launcher = @import("session_launcher.zig");
const command_palette_state = @import("command_palette_state.zig");
const command_registry = @import("../../command/registry.zig");

/// User command snippets loaded from `<config-dir>/snippets/*.md`, re-read each
/// time the command center opens. `items` is heap-owned; `loaded` gates the
/// lazy read inside the palette rebuild.
pub const SnippetState = struct {
    items: []command_registry.CustomCommand = &.{},
    loaded: bool = false,
};

/// Feishu credential-form overlay state: the field buffers plus presentation flags
/// (`visible` short-circuits the launcher render/input branches; `secret_already_set`
/// drives the "leave blank to keep" hint without re-reading the secret each frame).
pub const FeishuFormState = struct {
    config: feishu_config.State = .{},
    visible: bool = false,
    secret_already_set: bool = false,
};

/// Quick AI config-form overlay state: the config fields plus visibility flag.
pub const QuickAiFormState = struct {
    config: quick_ai_config.State = .{},
    visible: bool = false,
};

pub const OverlayState = struct {
    settings: settings_page.State = .{},
    toasts: toasts.State = .{},
    confirms: confirm_modals.State = .{},
    ssh: ssh_profiles.State = .{},
    assistant_profiles: assistant_profiles.State = .{},
    feishu: FeishuFormState = .{},
    quick_ai: QuickAiFormState = .{},
    session: session_launcher.State = .{},
    command_palette: command_palette_state.State = .{},
    snippets: SnippetState = .{},

    pub fn deinit(self: *OverlayState, allocator: std.mem.Allocator) void {
        self.settings.deinit(allocator);
        command_registry.freeCommandList(allocator, self.snippets.items);
        self.snippets = .{};
    }
};

test "overlay state aggregates migrated overlay groups" {
    // OverlayState is multi-MB (SSH/AI profile arrays); heap-allocate.
    const state = try std.testing.allocator.create(OverlayState);
    defer std.testing.allocator.destroy(state);
    state.* = .{};

    state.settings.open();
    state.toasts.copy.show("Copied", 10, 100);
    state.confirms.openRestoreDefaults();
    state.ssh.setFormField(.name, "web");
    state.assistant_profiles.setFormField(.name, "claude");
    state.session.ai_history_source_selected = 2;
    state.command_palette.openWithMode(.commands);

    try std.testing.expect(state.settings.visible);
    try std.testing.expectEqualStrings("Copied", state.toasts.copy.text().?);
    try std.testing.expect(state.confirms.restore_defaults_visible);
    try std.testing.expectEqualStrings("web", state.ssh.formField(.name));
    try std.testing.expectEqualStrings("claude", state.assistant_profiles.formField(.name));
    try std.testing.expectEqual(@as(usize, 2), state.session.ai_history_source_selected);
    try std.testing.expect(state.command_palette.visible);
}

test "overlay state deinit releases settings cache" {
    const state = try std.testing.allocator.create(OverlayState);
    defer std.testing.allocator.destroy(state);
    state.* = .{};

    _ = state.settings.cfg(std.testing.allocator);
    state.deinit(std.testing.allocator);
}

test "quick ai form defaults hidden and idle" {
    const s = QuickAiFormState{};
    try std.testing.expect(!s.visible);
    try std.testing.expectEqual(quick_ai_config.VerifyStatus.idle, s.config.status);
}
