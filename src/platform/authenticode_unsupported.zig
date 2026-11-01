//! Authenticode is Windows-only; elsewhere nothing is ever signed.
const authenticode = @import("authenticode.zig");

pub fn signerSubject(path: []const u8, buf: *[authenticode.subject_buffer_len]u8) ?[]const u8 {
    _ = path;
    _ = buf;
    return null;
}
