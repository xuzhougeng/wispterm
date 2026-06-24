const std = @import("std");
const settings_page = @import("settings_page.zig");
const toasts = @import("toasts.zig");
const confirm_modals = @import("confirm_modals.zig");
const ssh_profiles = @import("ssh_profiles.zig");
const ai_profiles = @import("ai_profiles.zig");
const session_launcher = @import("session_launcher.zig");

pub const OverlayState = struct {
    settings: settings_page.State = .{},
    toasts: toasts.State = .{},
    confirms: confirm_modals.State = .{},
    ssh: ssh_profiles.State = .{},
    ai: ai_profiles.State = .{},
    session: session_launcher.State = .{},

    pub fn deinit(self: *OverlayState, allocator: std.mem.Allocator) void {
        self.settings.deinit(allocator);
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
    state.ai.setFormField(.name, "claude");
    state.session.ai_history_source_selected = 2;

    try std.testing.expect(state.settings.visible);
    try std.testing.expectEqualStrings("Copied", state.toasts.copy.text().?);
    try std.testing.expect(state.confirms.restore_defaults_visible);
    try std.testing.expectEqualStrings("web", state.ssh.formField(.name));
    try std.testing.expectEqualStrings("claude", state.ai.formField(.name));
    try std.testing.expectEqual(@as(usize, 2), state.session.ai_history_source_selected);
}

test "overlay state deinit releases settings cache" {
    const state = try std.testing.allocator.create(OverlayState);
    defer std.testing.allocator.destroy(state);
    state.* = .{};

    _ = state.settings.cfg(std.testing.allocator);
    state.deinit(std.testing.allocator);
}
