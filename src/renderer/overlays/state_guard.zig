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
        // P2.2: session launcher / SSH form-list / AI form-list / launcher transient.
        "g_ssh_focus",
        "g_ssh_bufs",
        "g_ssh_lens",
        "g_ssh_profiles",
        "g_ssh_profile_count",
        "g_ssh_profiles_loaded",
        "g_ssh_list_selected",
        "g_ssh_list_mode",
        "g_ssh_list_filter_buf",
        "g_ssh_list_filter_len",
        "g_ssh_delete_selected",
        "g_ssh_edit_index",
        "g_ai_focus",
        "g_ai_bufs",
        "g_ai_lens",
        "g_ai_profiles",
        "g_ai_profile_count",
        "g_ai_profiles_loaded",
        "g_ai_list_selected",
        "g_ai_list_mode",
        "g_ai_edit_index",
        "g_ai_history_source_selected",
        "g_switch_model_target",
    };

    for (forbidden) |name| {
        try std.testing.expect(std.mem.indexOf(u8, source, name) == null);
    }
}
