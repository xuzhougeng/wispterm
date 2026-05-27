//! Application menu facade.
//!
//! Provides a unified API for installing the platform's application menu (e.g.,
//! macOS NSMenu). On platforms without a native app menu, the calls are no-ops.

const std = @import("std");
const builtin = @import("builtin");
const keybind = @import("../keybind.zig");

pub const Backend = enum {
    macos,
    unsupported,
};

pub fn backendForOs(comptime os_tag: std.Target.Os.Tag) Backend {
    return switch (os_tag) {
        .macos => .macos,
        else => .unsupported,
    };
}

const impl = switch (backendForOs(builtin.os.tag)) {
    .macos => @import("menu_macos.zig"),
    .unsupported => @import("menu_unsupported.zig"),
};

/// Invoked when a menu item that maps to a Phantty keybind action is clicked.
pub const ActionHandler = *const fn (action: keybind.Action) void;

/// Build and install the platform application menu. On platforms without a
/// native app menu this returns silently. Idempotent: calling twice rebuilds
/// the menu so the second call wins.
pub fn install(handler: ActionHandler) void {
    impl.install(handler);
}

/// Returns true once `install` has successfully attached a menu to the
/// platform's menu host. Mainly useful in tests.
pub fn isInstalled() bool {
    return impl.isInstalled();
}
