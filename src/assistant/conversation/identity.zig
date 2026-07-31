//! Runtime-only identities for live Assistant/Copilot instances.
//!
//! History session IDs may be restored into a new live session, so terminal
//! ownership needs a separate process-local identity.
const std = @import("std");

var g_next_id = std.atomic.Value(u64).init(1);

pub fn next() u64 {
    return g_next_id.fetchAdd(1, .monotonic);
}

test "runtime agent identities are distinct" {
    const first = next();
    const second = next();
    try std.testing.expect(first != 0);
    try std.testing.expect(second > first);
}
