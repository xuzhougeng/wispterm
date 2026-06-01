//! OSC 52 clipboard-write payload decoding (pure, testable).
//!
//! The terminal core (ghostty-vt) parses an `OSC 52 ; <kind> ; <payload>`
//! sequence into a `.clipboard_contents` action carrying the selection `kind`
//! and the *raw* payload — still base64 for a write, `"?"` for a read query, or
//! empty to clear. Ghostty's read-only handler discards the action, so WispTerm
//! must decode it here and write the result to the system clipboard.
//!
//! We deliberately only honor *writes*. Read queries (`"?"`) would require
//! handing our clipboard contents back to the program — a privacy leak we refuse
//! — and clears are ignored so a stray sequence can't silently wipe the user's
//! clipboard.

const std = @import("std");

pub const Action = union(enum) {
    /// Decoded clipboard text the caller should write to the system clipboard.
    /// The slice is owned by the caller and must be freed with the same
    /// allocator passed to `decode`.
    write: []u8,
    /// Nothing actionable: a read query, a clear, or an undecodable payload.
    ignore,
};

/// Decode an OSC 52 clipboard payload. `kind` is the selection byte (`'c'`
/// clipboard, `'p'` primary, …) — every selection maps to the single system
/// clipboard on the platforms WispTerm targets, so it does not affect decoding.
pub fn decode(allocator: std.mem.Allocator, kind: u8, data: []const u8) error{OutOfMemory}!Action {
    _ = kind;
    if (data.len == 0) return .ignore; // clear request — ignore
    if (std.mem.eql(u8, data, "?")) return .ignore; // read query — ignore
    const decoded = try decodeBase64(allocator, data) orelse return .ignore;
    if (decoded.len == 0) {
        allocator.free(decoded);
        return .ignore;
    }
    return .{ .write = decoded };
}

/// Base64-decode `data`. OSC 52 specifies standard (padded) base64, but some
/// emitters omit padding, so fall back to the no-pad alphabet. Returns null for
/// a payload that decodes under neither. Only allocation failure propagates.
fn decodeBase64(allocator: std.mem.Allocator, data: []const u8) error{OutOfMemory}!?[]u8 {
    return (try decodeWith(allocator, std.base64.standard.Decoder, data)) orelse
        (try decodeWith(allocator, std.base64.standard_no_pad.Decoder, data));
}

fn decodeWith(
    allocator: std.mem.Allocator,
    decoder: std.base64.Base64Decoder,
    data: []const u8,
) error{OutOfMemory}!?[]u8 {
    const size = decoder.calcSizeForSlice(data) catch return null;
    const buf = try allocator.alloc(u8, size);
    decoder.decode(buf, data) catch {
        allocator.free(buf);
        return null;
    };
    return buf;
}

test "decode returns the decoded text for a standard base64 write" {
    const action = try decode(std.testing.allocator, 'c', "aGVsbG8=");
    switch (action) {
        .write => |text| {
            defer std.testing.allocator.free(text);
            try std.testing.expectEqualStrings("hello", text);
        },
        .ignore => return error.TestExpectedWrite,
    }
}

test "decode ignores a clipboard read query" {
    try std.testing.expectEqual(Action.ignore, try decode(std.testing.allocator, 'c', "?"));
}

test "decode ignores an empty (clear) payload" {
    try std.testing.expectEqual(Action.ignore, try decode(std.testing.allocator, 'c', ""));
}

test "decode ignores an undecodable payload" {
    try std.testing.expectEqual(Action.ignore, try decode(std.testing.allocator, 'c', "@@@@"));
}

test "decode accepts unpadded base64" {
    const action = try decode(std.testing.allocator, 'c', "aGVsbG8");
    switch (action) {
        .write => |text| {
            defer std.testing.allocator.free(text);
            try std.testing.expectEqualStrings("hello", text);
        },
        .ignore => return error.TestExpectedWrite,
    }
}

test "decode round-trips multibyte UTF-8" {
    const action = try decode(std.testing.allocator, 'c', "5L2g5aW9"); // 你好
    switch (action) {
        .write => |text| {
            defer std.testing.allocator.free(text);
            try std.testing.expectEqualStrings("你好", text);
        },
        .ignore => return error.TestExpectedWrite,
    }
}

test "decode honors any selection kind" {
    const action = try decode(std.testing.allocator, 'p', "aGk=");
    switch (action) {
        .write => |text| {
            defer std.testing.allocator.free(text);
            try std.testing.expectEqualStrings("hi", text);
        },
        .ignore => return error.TestExpectedWrite,
    }
}
