const std = @import("std");

pub const Command = enum {
    websearch,
    webread,
    pubmed,
};

pub const Entry = struct {
    name: []const u8,
    description: []const u8,
    command: Command,
};

pub const entries = [_]Entry{
    .{ .name = "websearch", .description = "search the web (Jina)", .command = .websearch },
    .{ .name = "webread", .description = "read a web page or local file (Jina)", .command = .webread },
    .{ .name = "pubmed", .description = "search PubMed (NCBI)", .command = .pubmed },
};

pub fn parseToken(token: []const u8) ?Command {
    if (std.mem.eql(u8, token, "$websearch")) return .websearch;
    if (std.mem.eql(u8, token, "$webread")) return .webread;
    if (std.mem.eql(u8, token, "$pubmed")) return .pubmed;
    return null;
}

test "research commands parse only full dollar-prefixed tokens" {
    try std.testing.expectEqual(Command.websearch, parseToken("$websearch").?);
    try std.testing.expectEqual(Command.webread, parseToken("$webread").?);
    try std.testing.expectEqual(Command.pubmed, parseToken("$pubmed").?);
    try std.testing.expectEqual(@as(?Command, null), parseToken("$websearchx"));
    try std.testing.expectEqual(@as(?Command, null), parseToken("websearch"));
    try std.testing.expectEqual(@as(?Command, null), parseToken("/websearch"));
}

test "research commands expose composer suggestions" {
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqual(Command.websearch, entries[0].command);
    try std.testing.expectEqualStrings("websearch", entries[0].name);
    try std.testing.expectEqual(Command.pubmed, entries[2].command);
    try std.testing.expectEqualStrings("pubmed", entries[2].name);
}
