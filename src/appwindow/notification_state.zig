const std = @import("std");

pub const State = struct {
    last_memory_digest_progress_seq: u64 = 0,

    pub fn acceptMemoryDigestProgress(self: *State, seq: u64) bool {
        if (seq == 0 or seq == self.last_memory_digest_progress_seq) return false;
        self.last_memory_digest_progress_seq = seq;
        return true;
    }
};

test "notification state dedupes memory digest progress by sequence" {
    var state = State{};

    try std.testing.expect(!state.acceptMemoryDigestProgress(0));
    try std.testing.expect(state.acceptMemoryDigestProgress(10));
    try std.testing.expect(!state.acceptMemoryDigestProgress(10));
    try std.testing.expect(state.acceptMemoryDigestProgress(11));
}
