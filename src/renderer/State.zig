/// Shared render state, protected by a mutex.
/// The IO thread writes terminal data under the lock,
/// and the main/render thread reads it briefly under the lock.
const std = @import("std");
const ghostty_vt = @import("ghostty-vt");

const State = @This();

mutex: std.Thread.Mutex = .{},
terminal: *ghostty_vt.Terminal,

pub fn init(terminal: *ghostty_vt.Terminal) State {
    return .{ .terminal = terminal };
}
