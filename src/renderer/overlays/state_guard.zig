const std = @import("std");

test "overlays: migrated P2.1 state globals stay out of overlays facade" {
    const source = @embedFile("../overlays.zig");
    const forbidden = [_][]const u8{
        "g_settings_visible",
        "g_settings_focus",
        "g_settings_cfg_dirty",
        "g_settings_cfg_cache",
        "g_copy_toast_until_ms",
        "g_copy_toast_buf",
        "g_copy_toast_len",
        "g_transfer_toast_until_ms",
        "g_transfer_toast_sticky",
        "g_transfer_toast_status",
        "g_transfer_toast_clickable",
        "g_transfer_toast_buf",
        "g_transfer_toast_len",
        "g_update_prompt_until_ms",
        "g_update_prompt_buf",
        "g_update_prompt_len",
        "g_update_prompt_url_buf",
        "g_update_prompt_url_len",
        "g_update_prompt_clickable",
        "g_update_prompt_action",
        "g_transfer_cancel_confirm_visible",
        "g_window_close_confirm_visible",
        "g_close_confirm_pending",
        "g_close_confirm_variant",
        "g_restore_defaults_confirm_visible",
    };

    for (forbidden) |name| {
        try std.testing.expect(std.mem.indexOf(u8, source, name) == null);
    }
}
