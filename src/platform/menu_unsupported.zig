//! No-op application menu backend for platforms that don't have (or don't yet
//! support) a native app menu. The interface mirrors `platform/menu.zig`.

const keybind = @import("../keybind.zig");
const menu = @import("menu.zig");

pub fn install(handler: menu.ActionHandler) void {
    _ = handler;
}

pub fn isInstalled() bool {
    return false;
}

// Stub for cross-platform callers that go through the facade's actionFromId
// helper. The macOS backend exposes the real implementation.
pub fn actionFromId(action_id: i32) ?keybind.Action {
    _ = action_id;
    return null;
}
