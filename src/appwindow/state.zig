const std = @import("std");
const window_state = @import("window_state.zig");
const remote_state = @import("remote_state.zig");
const notification_state = @import("notification_state.zig");

pub const WindowState = window_state.State;
pub const RemoteState = remote_state.State;
pub const RemoteAiInputSink = remote_state.AiInputSink;
pub const NotificationState = notification_state.State;

pub const State = struct {
    window: WindowState = .{},
    remote: RemoteState = .{},
    notifications: NotificationState = .{},
};

test "appwindow state aggregates window and remote state" {
    var state = State{};

    state.window.queueResize(120, 32, 100);
    _ = state.remote.recordAiSink(1, 0x5678);
    try std.testing.expect(state.notifications.acceptMemoryDigestProgress(1));

    try std.testing.expect(state.window.pending_resize.pending);
    try std.testing.expectEqual(@as(usize, 0x5678), state.remote.aiSink(1).?.native_handle_bits);
}
