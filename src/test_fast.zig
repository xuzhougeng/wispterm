//! Fast native unit-test aggregator.
//!
//! `zig build test` builds and runs THIS file against the native host target.
//! It pulls in only platform-independent logic modules that have real unit
//! tests and compile without the heavy app graph (no `App.zig`/`AppWindow.zig`,
//! `ghostty-vt`, `xev`, or GL/win32 bindings). The goal is a sub-second inner
//! loop: editing a logic module reruns its tests in ~1s instead of forcing the
//! full `test_main` binary (99 modules + deps) to recompile.
//!
//! The complete suite — including the GUI binary and cross-compile checks —
//! lives behind `zig build test-full`.
//!
//! Only add modules here that (a) have unit tests worth running and (b) pass
//! natively. Platform-coupled modules whose tests assert Windows behavior
//! (e.g. `platform/window_backend`, `platform/pty_command_windows`) belong in
//! `test-full`, not here.

const build_options = @import("build_options");
const std = @import("std");
const app_metadata = @import("app_metadata.zig");

test {
    _ = @import("command_palette_model.zig");
    _ = @import("command_center_state.zig");
    _ = @import("config.zig");
    _ = @import("markdown_text.zig");
    _ = @import("ai_chat_composer_layout.zig");
    _ = @import("browser_url.zig");
    _ = @import("ssh_prompt.zig");
    _ = @import("selection_unit.zig");
    _ = @import("scrollbar_model.zig");
    _ = @import("preview_token.zig");
    _ = @import("agent_history.zig");
    _ = @import("renderer/gpu/backend.zig");
}
