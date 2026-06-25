const std = @import("std");

pub const MAX_REMOTE_AI_SINKS: usize = 32;

pub const AiInputSink = struct {
    native_handle_bits: usize = 0,
    tab_index: usize = 0,
    registered: bool = false,
};

pub const State = struct {
    layout_last_ms: i64 = 0,
    ai_sinks: [MAX_REMOTE_AI_SINKS]AiInputSink = [_]AiInputSink{.{}} ** MAX_REMOTE_AI_SINKS,
    last_transfer_notification_seq: u64 = 0,

    pub fn shouldSendLayout(self: *State, now_ms: i64, interval_ms: i64) bool {
        if (self.layout_last_ms != 0 and now_ms - self.layout_last_ms < interval_ms) return false;
        self.layout_last_ms = now_ms;
        return true;
    }

    pub fn forceNextLayout(self: *State) void {
        self.layout_last_ms = 0;
    }

    pub fn recordAiSink(self: *State, tab_index: usize, native_handle_bits: usize) ?*AiInputSink {
        if (tab_index >= self.ai_sinks.len) return null;
        self.ai_sinks[tab_index] = .{ .native_handle_bits = native_handle_bits, .tab_index = tab_index, .registered = true };
        return &self.ai_sinks[tab_index];
    }

    pub fn aiSink(self: *State, tab_index: usize) ?*AiInputSink {
        if (tab_index >= self.ai_sinks.len) return null;
        if (!self.ai_sinks[tab_index].registered) return null;
        return &self.ai_sinks[tab_index];
    }

    pub fn acceptTransferNotification(self: *State, seq: u64) bool {
        if (seq == self.last_transfer_notification_seq) return false;
        self.last_transfer_notification_seq = seq;
        return true;
    }
};

test "remote state throttles layout sends and can force the next layout" {
    var state = State{};

    try std.testing.expect(state.shouldSendLayout(1_000, 250));
    try std.testing.expect(!state.shouldSendLayout(1_100, 250));

    state.forceNextLayout();
    try std.testing.expect(state.shouldSendLayout(1_101, 250));
}

test "remote state records ai input sinks by index" {
    var state = State{};

    const sink = state.recordAiSink(2, 0x1234).?;
    try std.testing.expectEqual(@as(usize, 2), sink.tab_index);
    try std.testing.expectEqual(@as(usize, 0x1234), sink.native_handle_bits);
    try std.testing.expect(sink.registered);

    try std.testing.expectEqual(sink, state.aiSink(2).?);
    try std.testing.expectEqual(@as(?*AiInputSink, null), state.recordAiSink(MAX_REMOTE_AI_SINKS, 1));
}

test "remote state dedupes transfer notifications by sequence" {
    var state = State{};

    try std.testing.expect(state.acceptTransferNotification(10));
    try std.testing.expect(!state.acceptTransferNotification(10));
    try std.testing.expect(state.acceptTransferNotification(11));
}
