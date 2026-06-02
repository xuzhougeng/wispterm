const std = @import("std");
const input_key = @import("../input/key.zig");

pub const TransferCancelConfirmAction = enum { none, keep, interrupt };

pub fn transferCancelConfirmAction(ev: input_key.KeyEvent) TransferCancelConfirmAction {
    return switch (ev.key) {
        .escape => .keep,
        .enter => .interrupt,
        else => .none,
    };
}

test "overlay transfer cancellation maps platform-neutral keys to actions" {
    try std.testing.expectEqual(TransferCancelConfirmAction.keep, transferCancelConfirmAction(.{ .key = .escape }));
    try std.testing.expectEqual(TransferCancelConfirmAction.interrupt, transferCancelConfirmAction(.{ .key = .enter }));
    try std.testing.expectEqual(TransferCancelConfirmAction.none, transferCancelConfirmAction(.{ .key = .tab }));
}
