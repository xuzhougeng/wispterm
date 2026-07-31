//! Shared types for the memory digest pipeline. Spec:
//! docs/superpowers/specs/2026-07-07-ai-memory-digest-design.md
const std = @import("std");
const ai_types = @import("../terminal_agents/sessions/types.zig");

/// Providers the digest scans. Superset of the AI-history browser's
/// ProviderId: adds WispTerm's own copilot history.
pub const DigestProvider = enum {
    wispterm,
    claude,
    codex,
    reasonix,
};

/// One session carrying only the messages that are new since the last run.
/// All slices are owned by the collector's arena.
pub const CollectedSession = struct {
    provider: DigestProvider,
    source_id: []const u8, // "local" | "wsl:<distro>" | "ssh:<profile>"
    session_id: []const u8,
    title: []const u8,
    /// cwd of the session; "" = unknown → UNASSIGNED_SLUG.
    project_path: []const u8,
    started_at_ms: i64,
    ended_at_ms: i64,
    total_messages: u32,
    new_messages: []ai_types.TranscriptMessage,
    source_file: []const u8,
    /// Cursor stamp (file size/mtime at collection time), used by run.zig to
    /// advance the cursor for this session after it has been processed.
    file_size: u64 = 0,
    file_mtime_ns: i128 = 0,
};

pub const UNASSIGNED_SLUG = "unassigned";

/// Derive a project slug from a cwd path: last path component, lowercased,
/// [a-z0-9._-] kept, everything else mapped to '-'. Empty → "unassigned".
/// ponytail: two different paths with the same dirname share a slug; hash
/// suffix disambiguation lands with project.json in M2 (spec §10).
pub fn projectSlug(path: []const u8, buf: []u8) []const u8 {
    const trimmed = std.mem.trimRight(u8, path, "/\\");
    if (trimmed.len == 0) return UNASSIGNED_SLUG;
    const base = if (std.mem.lastIndexOfAny(u8, trimmed, "/\\")) |i|
        trimmed[i + 1 ..]
    else
        trimmed;
    if (base.len == 0) return UNASSIGNED_SLUG;
    const n = @min(base.len, buf.len);
    var out_len: usize = 0;
    var last_was_dash = false;
    for (base[0..n]) |c| {
        const lower = std.ascii.toLower(c);
        const ch = if (std.ascii.isAlphanumeric(lower) or lower == '.' or lower == '_' or lower == '-')
            lower
        else
            '-';
        if (ch == '-') {
            if (!last_was_dash and out_len < buf.len) {
                buf[out_len] = ch;
                out_len += 1;
                last_was_dash = true;
            }
        } else {
            if (out_len < buf.len) {
                buf[out_len] = ch;
                out_len += 1;
            }
            last_was_dash = false;
        }
    }
    // Trim trailing dash
    if (out_len > 0 and buf[out_len - 1] == '-') {
        out_len -= 1;
    }
    // Trim leading dash and shift content left
    if (out_len > 0 and buf[0] == '-') {
        std.mem.copyForwards(u8, buf[0 .. out_len - 1], buf[1..out_len]);
        out_len -= 1;
    }
    if (out_len == 0) return UNASSIGNED_SLUG;
    return buf[0..out_len];
}

test "memory_digest_types: slug takes last component lowercased" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("phantty", projectSlug("/Users/me/Documents/Code/Phantty", &buf));
}

test "memory_digest_types: slug handles windows paths and trailing separators" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("proj", projectSlug("C:\\code\\Proj\\", &buf));
    try std.testing.expectEqualStrings("proj", projectSlug("/home/me/proj///", &buf));
}

test "memory_digest_types: slug maps unsafe chars and empty to unassigned" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("my-dir-1", projectSlug("/tmp/My Dir(1)", &buf));
    try std.testing.expectEqualStrings("a-b", projectSlug("/tmp/a  b", &buf));
    try std.testing.expectEqualStrings("unassigned", projectSlug("/tmp/!!!", &buf));
    try std.testing.expectEqualStrings("unassigned", projectSlug("", &buf));
    try std.testing.expectEqualStrings("unassigned", projectSlug("///", &buf));
}
