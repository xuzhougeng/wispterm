//! wisptermctl client logic: arg parsing, escape decoding, and wait-for
//! matching. Pure (std-only) and unit-tested; the socket round-trip lives in
//! wisptermctl.zig which calls these helpers.
const std = @import("std");

pub const Action = union(enum) {
    panes,
    get_text: struct { id: []const u8, recent: ?u32 },
    send_text: struct { id: []const u8, data: []const u8 }, // data still escaped
    wait_for: struct { id: []const u8, pattern: []const u8, timeout_ms: u32 },
    ui_state,
    // command is the argv tail after `--` (joined with spaces by the caller);
    // empty = open a plain shell tab.
    spawn: struct { cwd: []const u8, command: []const []const u8 },
    help,
};

/// Decode C-style escapes (\n \r \t \0 \\ \xNN) into raw bytes. Unknown escapes
/// are passed through verbatim (backslash kept). Caller owns the result.
pub fn decodeEscapes(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '\\' or i + 1 >= s.len) {
            try out.append(allocator, s[i]);
            continue;
        }
        i += 1;
        switch (s[i]) {
            'n' => try out.append(allocator, '\n'),
            'r' => try out.append(allocator, '\r'),
            't' => try out.append(allocator, '\t'),
            '0' => try out.append(allocator, 0),
            '\\' => try out.append(allocator, '\\'),
            'x' => {
                if (i + 2 < s.len) {
                    const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
                        try out.appendSlice(allocator, "\\x");
                        continue;
                    };
                    const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
                        try out.appendSlice(allocator, "\\x");
                        continue;
                    };
                    try out.append(allocator, hi * 16 + lo);
                    i += 2;
                } else {
                    try out.appendSlice(allocator, "\\x");
                }
            },
            else => {
                try out.append(allocator, '\\');
                try out.append(allocator, s[i]);
            },
        }
    }
    return out.toOwnedSlice(allocator);
}

/// MVP wait-for matching = literal substring (case-sensitive).
pub fn waitMatch(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    return std.mem.indexOf(u8, haystack, needle) != null;
}

/// Parse argv[1..] into an Action. A missing or unknown command is an error
/// (so the CLI exits non-zero), distinct from an explicit help request
/// (`help`/`-h`/`--help`), which prints usage to stdout and exits 0.
pub fn parseArgs(args: []const []const u8) !Action {
    if (args.len == 0) return error.NoCommand;
    const cmd = args[0];
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "--help")) return .help;
    if (std.mem.eql(u8, cmd, "panes")) return .panes;
    if (std.mem.eql(u8, cmd, "ui-state")) return .ui_state;
    if (std.mem.eql(u8, cmd, "get-text")) {
        const id = (try flagValue(args, "-t")) orelse return error.MissingTarget;
        const recent = if (try flagValue(args, "--recent")) |r| try std.fmt.parseInt(u32, r, 10) else null;
        return .{ .get_text = .{ .id = id, .recent = recent } };
    }
    if (std.mem.eql(u8, cmd, "send-text")) {
        const id = (try flagValue(args, "-t")) orelse return error.MissingTarget;
        const text = positionalAfterFlags(args) orelse return error.MissingText;
        return .{ .send_text = .{ .id = id, .data = text } };
    }
    if (std.mem.eql(u8, cmd, "spawn")) {
        const cwd = (try flagValue(args, "--cwd")) orelse "";
        return .{ .spawn = .{ .cwd = cwd, .command = argsAfterDoubleDash(args) } };
    }
    if (std.mem.eql(u8, cmd, "wait-for")) {
        const id = (try flagValue(args, "-t")) orelse return error.MissingTarget;
        const pat = positionalAfterFlags(args) orelse return error.MissingText;
        const timeout = if (try flagValue(args, "--timeout")) |s| blk: {
            // Widen before *1000 so a large --timeout cannot overflow u32 (panic).
            const secs: u64 = try std.fmt.parseInt(u32, s, 10);
            break :blk @as(u32, @intCast(@min(secs * 1000, @as(u64, std.math.maxInt(u32)))));
        } else 60_000;
        return .{ .wait_for = .{ .id = id, .pattern = pat, .timeout_ms = timeout } };
    }
    return error.UnknownCommand;
}

const known_flags = [_][]const u8{ "-t", "--recent", "--timeout" };

fn flagValue(args: []const []const u8, flag: []const u8) !?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) return null; // end-of-options; rest is positional
        if (std.mem.eql(u8, args[i], flag)) {
            if (i + 1 >= args.len) return error.MissingFlagValue;
            return args[i + 1];
        }
    }
    return null;
}

/// First token (after the command) that is neither a known flag nor a flag's
/// value. A literal `--` ends option parsing, so the token after it is taken
/// verbatim (lets you send a body that is itself a reserved flag string).
fn positionalAfterFlags(args: []const []const u8) ?[]const u8 {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) {
            return if (i + 1 < args.len) args[i + 1] else null;
        }
        if (isKnownFlag(args[i])) {
            i += 1; // skip its value
            continue;
        }
        return args[i];
    }
    return null;
}

/// Everything after a literal `--` (the program + its args for `spawn`). Empty
/// slice when there is no `--` or nothing follows it.
fn argsAfterDoubleDash(args: []const []const u8) []const []const u8 {
    for (args, 0..) |a, i| {
        if (std.mem.eql(u8, a, "--")) return args[i + 1 ..];
    }
    return &.{};
}

fn isKnownFlag(a: []const u8) bool {
    for (known_flags) |f| {
        if (std.mem.eql(u8, a, f)) return true;
    }
    return false;
}

// ---- tests ----
const t = std.testing;

test "decodeEscapes handles \\n \\t \\x1b and passes unknowns through" {
    const out = try decodeEscapes(t.allocator, "a\\tb\\nc\\x1bd\\q");
    defer t.allocator.free(out);
    try t.expectEqualSlices(u8, &[_]u8{ 'a', '\t', 'b', '\n', 'c', 0x1b, 'd', '\\', 'q' }, out);
}

test "decodeEscapes leaves a trailing lone backslash" {
    const out = try decodeEscapes(t.allocator, "ab\\");
    defer t.allocator.free(out);
    try t.expectEqualStrings("ab\\", out);
}

test "waitMatch substring" {
    try t.expect(waitMatch("...done.", "done"));
    try t.expect(!waitMatch("running", "done"));
    try t.expect(waitMatch("anything", ""));
}

test "parseArgs covers every command and required-flag errors" {
    try t.expectEqual(Action.panes, try parseArgs(&.{"panes"}));

    const g = try parseArgs(&.{ "get-text", "-t", "s1", "--recent", "200" });
    try t.expectEqualStrings("s1", g.get_text.id);
    try t.expectEqual(@as(?u32, 200), g.get_text.recent);

    const s = try parseArgs(&.{ "send-text", "-t", "s1", "ls\\n" });
    try t.expectEqualStrings("ls\\n", s.send_text.data);
    try t.expectEqualStrings("s1", s.send_text.id);

    const w = try parseArgs(&.{ "wait-for", "-t", "s1", "done", "--timeout", "5" });
    try t.expectEqualStrings("done", w.wait_for.pattern);
    try t.expectEqual(@as(u32, 5000), w.wait_for.timeout_ms);

    try t.expectError(error.MissingTarget, parseArgs(&.{"get-text"}));
    try t.expectError(error.MissingText, parseArgs(&.{ "send-text", "-t", "s1" }));
    // No command at all is an error (non-zero exit), like an unknown command —
    // only an explicit help request prints usage and exits 0.
    try t.expectError(error.NoCommand, parseArgs(&.{}));
    try t.expectEqual(Action.help, try parseArgs(&.{"help"}));
    try t.expectEqual(Action.help, try parseArgs(&.{"-h"}));
    try t.expectEqual(Action.help, try parseArgs(&.{"--help"}));
    // Unknown command is an error (non-zero exit), not silent help.
    try t.expectError(error.UnknownCommand, parseArgs(&.{"bogus"}));
}

test "parseArgs maps ui-state to its no-arg action" {
    try t.expectEqual(Action.ui_state, try parseArgs(&.{"ui-state"}));
}

test "parseArgs spawn: cwd + command tail after --" {
    const a = try parseArgs(&.{ "spawn", "--cwd", "F:\\proj", "--", "claude", "-r", "abc" });
    try t.expectEqualStrings("F:\\proj", a.spawn.cwd);
    try t.expectEqual(@as(usize, 3), a.spawn.command.len);
    try t.expectEqualStrings("claude", a.spawn.command[0]);
    try t.expectEqualStrings("abc", a.spawn.command[2]);
}

test "parseArgs spawn: bare (no cwd, no command) is a plain shell tab" {
    const a = try parseArgs(&.{"spawn"});
    try t.expectEqualStrings("", a.spawn.cwd);
    try t.expectEqual(@as(usize, 0), a.spawn.command.len);
}

test "parseArgs: large --timeout does not overflow u32 (clamps)" {
    const w = try parseArgs(&.{ "wait-for", "-t", "s1", "done", "--timeout", "5000000" });
    try t.expectEqual(@as(u32, std.math.maxInt(u32)), w.wait_for.timeout_ms); // 5_000_000 * 1000 clamped
    // An out-of-u32 seconds value is a clean parse error, not a crash.
    try t.expectError(error.Overflow, parseArgs(&.{ "wait-for", "-t", "s1", "done", "--timeout", "99999999999" }));
}

test "parseArgs: -- lets a body equal to a reserved flag through" {
    const s = try parseArgs(&.{ "send-text", "-t", "s1", "--", "--timeout" });
    try t.expectEqualStrings("s1", s.send_text.id);
    try t.expectEqualStrings("--timeout", s.send_text.data);
}
