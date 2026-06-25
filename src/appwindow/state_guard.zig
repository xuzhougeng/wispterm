const std = @import("std");

test "appwindow: migrated P2.3 state globals stay out of AppWindow facade" {
    const source = @embedFile("../AppWindow.zig");
    const forbidden = [_][]const u8{
        "g_remote_layout_last_ms",
        "g_remote_ai_sinks",
        "g_last_transfer_notification_seq",
        "g_pending_resize",
        "g_pending_cols",
        "g_pending_rows",
        "g_last_resize_time",
        "g_layout_resize_immediate",
        "g_present_bringup_settled",
    };

    for (forbidden) |name| {
        try std.testing.expect(std.mem.indexOf(u8, source, name) == null);
    }
}
