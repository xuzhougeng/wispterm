//! wisptermctl client logic: arg parsing, escape decoding, wait-for matching,
//! and agent-state predicates. Pure (std + the terminal_agents screen regex)
//! and unit-tested; the socket round-trip lives in wisptermctl.zig which calls
//! these helpers.
const std = @import("std");
const protocol = @import("protocol.zig");
const screen_regex = @import("../terminal_agents/screen_regex.zig");
const agent_detector = @import("../terminal_agents/detector.zig");

pub const AgentState = agent_detector.State;
pub const AgentApp = agent_detector.App;

/// Agent lifecycle states a wait can stop on, as `--until` spells them.
/// `ready` = idle / done / waiting_approval / needs_input (the default set:
/// the agent can take input, or needs a decision first).
pub const UntilSet = struct {
    bits: u16 = 0,

    pub fn with(self: UntilSet, state: AgentState) UntilSet {
        return .{ .bits = self.bits | (@as(u16, 1) << @intFromEnum(state)) };
    }

    pub fn contains(self: UntilSet, state: AgentState) bool {
        return (self.bits >> @intFromEnum(state)) & 1 == 1;
    }

    pub fn isEmpty(self: UntilSet) bool {
        return self.bits == 0;
    }

    pub const ready: UntilSet = (UntilSet{}).with(.idle).with(.done).with(.waiting_approval).with(.needs_input);
    pub const blocked: UntilSet = (UntilSet{}).with(.waiting_approval).with(.needs_input);

    /// Parse one `--until` value. Accepts the state labels plus the short
    /// badge spellings (`run`, `ask`, `input`) and `blocked` / `ready`.
    pub fn parseOne(self: UntilSet, word: []const u8) ?UntilSet {
        if (std.mem.eql(u8, word, "ready")) return .{ .bits = self.bits | ready.bits };
        if (std.mem.eql(u8, word, "blocked") or std.mem.eql(u8, word, "ask")) return .{ .bits = self.bits | blocked.bits };
        if (std.mem.eql(u8, word, "run") or std.mem.eql(u8, word, "working")) return self.with(.running);
        if (std.mem.eql(u8, word, "input")) return self.with(.needs_input);
        if (agent_detector.stateFromLabel(word)) |s| return self.with(s);
        return null;
    }
};

pub const Action = union(enum) {
    panes,
    get_text: struct { id: []const u8, recent: ?u32 },
    send_text: struct { id: []const u8, data: []const u8 }, // data still escaped
    wait_for: struct {
        id: []const u8,
        pattern: []const u8,
        timeout_ms: u32,
        /// Match `pattern` as a regex against each line instead of a substring.
        regex: bool,
        /// Only the last N lines of the text are searched (null = all).
        lines: ?u32,
    },
    ui_state,
    // command is the argv tail after `--` (joined with spaces by the caller);
    // empty = open a plain shell tab (or `kind`'s executable when set).
    spawn: struct {
        cwd: []const u8,
        command: []const []const u8,
        /// Agent kind label (`--kind codex`); "" = plain command.
        kind: []const u8,
        split: protocol.SpawnSplit,
        /// Block until the agent reports a ready state (requires `kind`).
        wait_ready: bool,
        timeout_ms: u32,
    },
    agent_state: struct { id: []const u8 },
    wait_agent: struct { id: []const u8, until: UntilSet, timeout_ms: u32 },
    prompt: struct {
        id: []const u8,
        text: []const u8, // still escaped
        wait: bool,
        until: UntilSet,
        timeout_ms: u32,
    },
    help,
};

/// Default `spawn --wait-ready` and `wait-agent` timeouts (herdr uses 30 s for
/// start and no default for waits; we always bound a wait).
pub const default_ready_timeout_ms: u32 = 30_000;
pub const default_wait_timeout_ms: u32 = 60_000;

/// Resolve `--kind` to the executable to run and the canonical label sent to
/// the server. Null for an unknown kind.
pub fn resolveKind(word: []const u8) ?struct { app: AgentApp, executable: []const u8, label: []const u8 } {
    const app = agent_detector.appFromProcessName(word);
    if (!app.isTerminalAgent()) return null;
    return .{ .app = app, .executable = app.executable(), .label = app.label() };
}

/// `wait-for` matching: substring (default) or per-line regex, optionally
/// restricted to the last `lines` lines of `haystack`.
pub fn waitMatchText(allocator: std.mem.Allocator, haystack: []const u8, pattern: []const u8, regex: bool, lines: ?u32) !bool {
    const scope = if (lines) |n| lastLines(haystack, n) else haystack;
    if (!regex) return waitMatch(scope, pattern);
    var re = try screen_regex.Regex.compile(allocator, pattern);
    defer re.deinit();
    return re.anyLineMatches(scope);
}

/// The last `n` lines of `text` (Rust `lines()` semantics for counting).
pub fn lastLines(text: []const u8, n: u32) []const u8 {
    if (n == 0) return "";
    var count: usize = 0;
    var i = text.len;
    // Count newlines from the end; a trailing newline does not start a line.
    if (i > 0 and text[i - 1] == '\n') i -= 1;
    while (i > 0) {
        i -= 1;
        if (text[i] == '\n') {
            count += 1;
            if (count == n) return text[i + 1 ..];
        }
    }
    return text;
}

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
        const kind = (try flagValue(args, "--kind")) orelse "";
        if (kind.len != 0 and resolveKind(kind) == null) return error.UnknownKind;
        const split = if (try flagValue(args, "--split")) |s| (protocol.SpawnSplit.parse(s) orelse return error.InvalidSplit) else .none;
        const wait_ready = hasFlag(args, "--wait-ready");
        if (wait_ready and kind.len == 0) return error.WaitReadyNeedsKind;
        const timeout = (try timeoutFlag(args)) orelse default_ready_timeout_ms;
        return .{ .spawn = .{
            .cwd = cwd,
            .command = argsAfterDoubleDash(args),
            .kind = kind,
            .split = split,
            .wait_ready = wait_ready,
            .timeout_ms = timeout,
        } };
    }
    if (std.mem.eql(u8, cmd, "wait-for")) {
        const id = (try flagValue(args, "-t")) orelse return error.MissingTarget;
        const pat = positionalAfterFlags(args) orelse return error.MissingText;
        const timeout = (try timeoutFlag(args)) orelse default_wait_timeout_ms;
        const lines = if (try flagValue(args, "--lines")) |l| try std.fmt.parseInt(u32, l, 10) else null;
        return .{ .wait_for = .{ .id = id, .pattern = pat, .timeout_ms = timeout, .regex = hasFlag(args, "--regex"), .lines = lines } };
    }
    if (std.mem.eql(u8, cmd, "agent-state")) {
        const id = (try flagValue(args, "-t")) orelse return error.MissingTarget;
        return .{ .agent_state = .{ .id = id } };
    }
    if (std.mem.eql(u8, cmd, "wait-agent")) {
        const id = (try flagValue(args, "-t")) orelse return error.MissingTarget;
        const until = try untilFlags(args);
        const timeout = (try timeoutFlag(args)) orelse default_wait_timeout_ms;
        return .{ .wait_agent = .{ .id = id, .until = if (until.isEmpty()) UntilSet.ready else until, .timeout_ms = timeout } };
    }
    if (std.mem.eql(u8, cmd, "prompt")) {
        const id = (try flagValue(args, "-t")) orelse return error.MissingTarget;
        const text = positionalAfterFlags(args) orelse return error.MissingText;
        const wait = hasFlag(args, "--wait");
        const until = try untilFlags(args);
        if (!until.isEmpty() and !wait) return error.UntilNeedsWait;
        const timeout = (try timeoutFlag(args)) orelse default_wait_timeout_ms;
        return .{ .prompt = .{ .id = id, .text = text, .wait = wait, .until = if (until.isEmpty()) UntilSet.ready else until, .timeout_ms = timeout } };
    }
    return error.UnknownCommand;
}

const known_flags = [_][]const u8{ "-t", "--recent", "--timeout", "--cwd", "--kind", "--split", "--lines", "--until" };
const known_switches = [_][]const u8{ "--regex", "--wait", "--wait-ready" };

/// `--timeout SECONDS` → milliseconds, clamped so a large value cannot
/// overflow u32 (panic). Null when absent.
fn timeoutFlag(args: []const []const u8) !?u32 {
    const s = (try flagValue(args, "--timeout")) orelse return null;
    const secs: u64 = try std.fmt.parseInt(u32, s, 10);
    return @as(u32, @intCast(@min(secs * 1000, @as(u64, std.math.maxInt(u32)))));
}

/// Every `--until X` occurrence, OR-ed together.
fn untilFlags(args: []const []const u8) !UntilSet {
    var set = UntilSet{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) break;
        if (!std.mem.eql(u8, args[i], "--until")) continue;
        if (i + 1 >= args.len) return error.MissingFlagValue;
        set = set.parseOne(args[i + 1]) orelse return error.UnknownState;
        i += 1;
    }
    return set;
}

fn hasFlag(args: []const []const u8, flag: []const u8) bool {
    for (args) |a| {
        if (std.mem.eql(u8, a, "--")) return false;
        if (std.mem.eql(u8, a, flag)) return true;
    }
    return false;
}

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
        if (isKnownSwitch(args[i])) continue;
        return args[i];
    }
    return null;
}

fn isKnownSwitch(a: []const u8) bool {
    for (known_switches) |f| {
        if (std.mem.eql(u8, a, f)) return true;
    }
    return false;
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
    try t.expect(!w.wait_for.regex);
    try t.expect(w.wait_for.lines == null);

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
    try t.expectEqualStrings("", a.spawn.kind);
    try t.expectEqual(protocol.SpawnSplit.none, a.spawn.split);
    try t.expect(!a.spawn.wait_ready);
}

test "parseArgs spawn: --kind / --split / --wait-ready" {
    const a = try parseArgs(&.{ "spawn", "--kind", "codex", "--split", "right", "--wait-ready", "--timeout", "45", "--", "-m", "gpt-5.4" });
    try t.expectEqualStrings("codex", a.spawn.kind);
    try t.expectEqual(protocol.SpawnSplit.right, a.spawn.split);
    try t.expect(a.spawn.wait_ready);
    try t.expectEqual(@as(u32, 45_000), a.spawn.timeout_ms);
    try t.expectEqualStrings("-m", a.spawn.command[0]);
    const r = resolveKind("codex").?;
    try t.expectEqualStrings("codex", r.executable);
    try t.expectEqualStrings("codex", r.label);
    // Aliases resolve to the canonical label and launcher.
    const c = resolveKind("claude").?;
    try t.expectEqual(AgentApp.claude_code, c.app);
    try t.expectEqualStrings("claude", c.executable);
    try t.expectEqualStrings("claude_code", c.label);
    try t.expectEqualStrings("cursor-agent", resolveKind("cursor").?.executable);

    try t.expectError(error.UnknownKind, parseArgs(&.{ "spawn", "--kind", "vim" }));
    try t.expectError(error.InvalidSplit, parseArgs(&.{ "spawn", "--split", "left" }));
    try t.expectError(error.WaitReadyNeedsKind, parseArgs(&.{ "spawn", "--wait-ready" }));
    const d = try parseArgs(&.{ "spawn", "--kind", "codex" });
    try t.expectEqual(default_ready_timeout_ms, d.spawn.timeout_ms);
}

test "parseArgs wait-for: --regex and --lines" {
    const w = try parseArgs(&.{ "wait-for", "-t", "s1", "--regex", "--lines", "80", "passed|failed" });
    try t.expectEqualStrings("passed|failed", w.wait_for.pattern);
    try t.expect(w.wait_for.regex);
    try t.expectEqual(@as(?u32, 80), w.wait_for.lines);
}

test "parseArgs agent-state / wait-agent / prompt" {
    const s = try parseArgs(&.{ "agent-state", "-t", "s1" });
    try t.expectEqualStrings("s1", s.agent_state.id);

    const w = try parseArgs(&.{ "wait-agent", "-t", "s1" });
    try t.expect(w.wait_agent.until.contains(.idle));
    try t.expect(w.wait_agent.until.contains(.done));
    try t.expect(w.wait_agent.until.contains(.waiting_approval));
    try t.expect(!w.wait_agent.until.contains(.running));
    try t.expectEqual(default_wait_timeout_ms, w.wait_agent.timeout_ms);

    const wb = try parseArgs(&.{ "wait-agent", "-t", "s1", "--until", "blocked", "--until", "done", "--timeout", "2" });
    try t.expect(wb.wait_agent.until.contains(.waiting_approval));
    try t.expect(wb.wait_agent.until.contains(.needs_input));
    try t.expect(wb.wait_agent.until.contains(.done));
    try t.expect(!wb.wait_agent.until.contains(.idle));
    try t.expectEqual(@as(u32, 2000), wb.wait_agent.timeout_ms);
    try t.expectError(error.UnknownState, parseArgs(&.{ "wait-agent", "-t", "s1", "--until", "sleepy" }));

    const p = try parseArgs(&.{ "prompt", "-t", "s1", "Review the diff", "--wait", "--until", "run" });
    try t.expectEqualStrings("Review the diff", p.prompt.text);
    try t.expect(p.prompt.wait);
    try t.expect(p.prompt.until.contains(.running));
    try t.expect(!p.prompt.until.contains(.idle));
    const pn = try parseArgs(&.{ "prompt", "-t", "s1", "hello" });
    try t.expect(!pn.prompt.wait);
    try t.expect(pn.prompt.until.contains(.idle));
    try t.expectError(error.UntilNeedsWait, parseArgs(&.{ "prompt", "-t", "s1", "hello", "--until", "done" }));
    try t.expectError(error.MissingText, parseArgs(&.{ "prompt", "-t", "s1", "--wait" }));
}

test "waitMatchText: substring, regex per line, and last-N-lines scope" {
    try t.expect(try waitMatchText(t.allocator, "a\nb\ntest result: ok\n", "result:", false, null));
    try t.expect(try waitMatchText(t.allocator, "a\n12 passed\n", "^\\d+ (passed|failed)$", true, null));
    try t.expect(!try waitMatchText(t.allocator, "a\n12 passed\n", "^passed$", true, null));
    try t.expect(try waitMatchText(t.allocator, "old passed\nnew\n", "passed", false, null));
    try t.expect(!try waitMatchText(t.allocator, "old passed\nnew\n", "passed", false, 1));
    try t.expectError(error.UnterminatedClass, waitMatchText(t.allocator, "x", "[", true, null));
    try t.expectEqualStrings("b\nc", lastLines("a\nb\nc", 2));
    try t.expectEqualStrings("c\n", lastLines("a\nb\nc\n", 1));
    try t.expectEqualStrings("a\nb", lastLines("a\nb", 9));
    try t.expectEqualStrings("", lastLines("a\nb", 0));
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
