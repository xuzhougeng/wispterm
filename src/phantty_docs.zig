//! Built-in Phantty documentation, embedded at build time.
//!
//! The agent reads these on demand through the `phantty_docs` tool so the
//! system prompt only needs a one-line pointer instead of the full text.
//! Doc files live under `docs/` and are wired in as named embed imports by
//! build.zig (`createAppModuleWithRoot`). The import names below MUST match
//! the names registered there.

const std = @import("std");

pub const Topic = struct {
    name: []const u8,
    summary: []const u8,
    content: []const u8,
};

pub const topics = [_]Topic{
    .{
        .name = "faq",
        .summary = "Frequently asked questions and troubleshooting.",
        .content = @embedFile("phantty_doc_faq"),
    },
    .{
        .name = "configuration",
        .summary = "Config file location, options, keybindings, and clipboard behavior.",
        .content = @embedFile("phantty_doc_configuration"),
    },
    .{
        .name = "ai-agent",
        .summary = "AI chat and agent usage: profiles, providers, skills, and exports.",
        .content = @embedFile("phantty_doc_ai_agent"),
    },
    .{
        .name = "file-explorer",
        .summary = "Using the built-in file explorer and preview panel.",
        .content = @embedFile("phantty_doc_file_explorer"),
    },
    .{
        .name = "media",
        .summary = "Showing images, background images, and inline remote images.",
        .content = @embedFile("phantty_doc_media"),
    },
};

/// Returns the embedded markdown for an exact topic name, or null if unknown.
pub fn readTopic(name: []const u8) ?[]const u8 {
    for (topics) |topic| {
        if (std.mem.eql(u8, topic.name, name)) return topic.content;
    }
    return null;
}

/// Builds a model-readable list of topics: one `name — summary` line each,
/// plus a trailing hint. Caller owns the returned slice.
pub fn listTopics(allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "Phantty documentation topics:\n");
    for (topics) |topic| {
        try out.print(allocator, "- {s} — {s}\n", .{ topic.name, topic.summary });
    }
    try out.appendSlice(allocator, "\nCall phantty_docs again with one topic name to read its full text.");
    return out.toOwnedSlice(allocator);
}

test "phantty_docs: every topic has non-empty name, summary, and content" {
    for (topics) |topic| {
        try std.testing.expect(topic.name.len > 0);
        try std.testing.expect(topic.summary.len > 0);
        try std.testing.expect(topic.content.len > 0);
    }
}

test "phantty_docs: readTopic returns content for known topics and null otherwise" {
    try std.testing.expect(readTopic("faq") != null);
    try std.testing.expect(readTopic("configuration") != null);
    try std.testing.expect(readTopic("ai-agent") != null);
    try std.testing.expect(readTopic("file-explorer") != null);
    try std.testing.expect(readTopic("media") != null);
    try std.testing.expect(readTopic("nope") == null);
}

test "phantty_docs: listTopics lists every topic name and the read hint" {
    const text = try listTopics(std.testing.allocator);
    defer std.testing.allocator.free(text);
    for (topics) |topic| {
        try std.testing.expect(std.mem.indexOf(u8, text, topic.name) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, text, "phantty_docs") != null);
}
