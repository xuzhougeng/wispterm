//! Pure update-prompt action selection: maps an update CheckResult to the
//! prompt's primary action (download the asset, open the release page, or
//! nothing). Extracted from overlays.zig for fast-suite testing; overlays keeps
//! the prompt's stored URLs and draw state.
const std = @import("std");
const builtin = @import("builtin");
const update_check = @import("../../update_check.zig");

pub const UpdatePromptAction = enum { none, open_release, download_update, install_update };

pub fn updatePromptActionForResult(result: update_check.CheckResult) UpdatePromptAction {
    return if (result.state == .update_available and result.asset_download_url.len > 0)
        .download_update
    else if (result.state == .update_available and result.release_url.len > 0)
        .open_release
    else if (result.state == .failed and result.release_url.len > 0)
        .open_release
    else if (result.state == .download_failed and result.release_url.len > 0)
        .open_release
    else if (result.state == .downloaded and builtin.os.tag == .macos)
        .install_update
    else
        .none;
}

test "overlays: downloaded maps to install_update on macOS only" {
    const expected: UpdatePromptAction = if (builtin.os.tag == .macos) .install_update else .none;
    try std.testing.expectEqual(expected, updatePromptActionForResult(.{ .state = .downloaded, .latest_version = "v1.31.0" }));
}

test "overlays: update prompt action selection prefers downloadable asset" {
    try std.testing.expectEqual(
        UpdatePromptAction.download_update,
        updatePromptActionForResult(.{
            .state = .update_available,
            .release_url = "https://example.test/releases/v0.28.0",
            .asset_download_url = "https://example.test/portable.zip",
        }),
    );
    try std.testing.expectEqual(
        UpdatePromptAction.open_release,
        updatePromptActionForResult(.{
            .state = .download_failed,
            .release_url = "https://example.test/releases/v0.28.0",
        }),
    );
    try std.testing.expectEqual(
        UpdatePromptAction.none,
        updatePromptActionForResult(.{ .state = .up_to_date }),
    );
}
