//! Finds the API key for a conversation that is being restored from history.
//!
//! Keys are not written to the history file (`agent/history.zig` serializes
//! every record with an empty `api_key`), so a restored session has to get
//! its key from where keys are meant to live: the saved AI profiles. The app
//! layer registers a resolver that looks the endpoint up there; this module
//! holds the hook and the pure matching rule, and has no UI dependency.
const std = @import("std");

/// Copies the key for `base_url` / `model` into `out` and returns the slice,
/// or null when no saved profile matches.
pub const Resolver = *const fn (base_url: []const u8, model: []const u8, out: []u8) ?[]const u8;

var resolver: ?Resolver = null;

pub fn set(cb: ?Resolver) void {
    resolver = cb;
}

pub fn resolve(base_url: []const u8, model: []const u8, out: []u8) ?[]const u8 {
    const cb = resolver orelse return null;
    return cb(base_url, model, out);
}

pub const Candidate = struct {
    base_url: []const u8,
    model: []const u8,
    api_key: []const u8,
};

/// The key of the profile that best matches an endpoint: the same base URL
/// and model if there is one, otherwise the first profile for the same base
/// URL (one account usually serves several models). Profiles without a key
/// are skipped. Base URLs compare ASCII case-insensitively and ignore a
/// trailing slash.
pub fn pickKey(candidates: []const Candidate, base_url: []const u8, model: []const u8) ?[]const u8 {
    var same_endpoint: ?[]const u8 = null;
    for (candidates) |c| {
        if (c.api_key.len == 0 or !sameBaseUrl(c.base_url, base_url)) continue;
        if (std.mem.eql(u8, c.model, model)) return c.api_key;
        if (same_endpoint == null) same_endpoint = c.api_key;
    }
    return same_endpoint;
}

fn sameBaseUrl(a: []const u8, b: []const u8) bool {
    const ta = std.mem.trimRight(u8, std.mem.trim(u8, a, " \t"), "/");
    const tb = std.mem.trimRight(u8, std.mem.trim(u8, b, " \t"), "/");
    return ta.len != 0 and std.ascii.eqlIgnoreCase(ta, tb);
}

test "pickKey prefers the exact model, then the same endpoint" {
    const profiles = [_]Candidate{
        .{ .base_url = "https://api.one.test/v1", .model = "small", .api_key = "key-small" },
        .{ .base_url = "https://api.one.test/v1/", .model = "large", .api_key = "key-large" },
        .{ .base_url = "https://api.two.test", .model = "large", .api_key = "" },
        .{ .base_url = "https://api.three.test", .model = "m", .api_key = "key-three" },
    };
    try std.testing.expectEqualStrings("key-large", pickKey(&profiles, "https://api.one.test/v1", "large").?);
    // Unknown model on a known endpoint falls back to that endpoint's first key.
    try std.testing.expectEqualStrings("key-small", pickKey(&profiles, "HTTPS://API.ONE.TEST/v1/", "other").?);
    // A profile without a key never matches; an unknown endpoint matches nothing.
    try std.testing.expect(pickKey(&profiles, "https://api.two.test", "large") == null);
    try std.testing.expect(pickKey(&profiles, "https://api.four.test", "m") == null);
    try std.testing.expect(pickKey(&profiles, "", "m") == null);
}

test "resolve returns null until a resolver is registered" {
    var buf: [16]u8 = undefined;
    set(null);
    try std.testing.expect(resolve("https://x.test", "m", &buf) == null);
    const Fake = struct {
        fn cb(_: []const u8, _: []const u8, out: []u8) ?[]const u8 {
            @memcpy(out[0..3], "abc");
            return out[0..3];
        }
    };
    set(Fake.cb);
    defer set(null);
    try std.testing.expectEqualStrings("abc", resolve("https://x.test", "m", &buf).?);
}
