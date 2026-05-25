//! Compile-only entry point for modules that should stay independent from the
//! desktop platform backend.

const build_options = @import("build_options");
const std = @import("std");
const app_metadata = @import("app_metadata.zig");

comptime {
    _ = @import("ai_chat_composer_layout.zig");
    _ = @import("appwindow/thread_message.zig");
    _ = @import("browser_url.zig");
    _ = @import("command_center_state.zig");
    _ = @import("preview_token.zig");
    _ = @import("release_package.zig");
    _ = @import("scrollbar_model.zig");
    _ = @import("selection_unit.zig");
    _ = @import("ssh_prompt.zig");
    _ = @import("system_browser.zig");
    _ = @import("update_check.zig");
    _ = @import("update_install.zig");
    _ = @import("updater_core.zig");
    _ = @import("platform/webview.zig");
}

test "shared compile target has app metadata" {
    try std.testing.expect(build_options.app_version.len > 0);
    try std.testing.expectEqualStrings("Phantty", app_metadata.name);
}
