const std = @import("std");

pub const App = enum {
    none,
    codex,
    claude_code,

    pub fn label(self: App) []const u8 {
        return switch (self) {
            .none => "none",
            .codex => "codex",
            .claude_code => "claude_code",
        };
    }
};

pub const State = enum {
    none,
    running,
    waiting_approval,
    needs_input,
    halted,
    failed,
    done,

    pub fn label(self: State) []const u8 {
        return switch (self) {
            .none => "none",
            .running => "running",
            .waiting_approval => "waiting_approval",
            .needs_input => "needs_input",
            .halted => "halted",
            .failed => "failed",
            .done => "done",
        };
    }

    pub fn badge(self: State) []const u8 {
        return switch (self) {
            .none => "",
            .running => "run",
            .waiting_approval => "ask",
            .needs_input => "!",
            .halted => "halt",
            .failed => "err",
            .done => "done",
        };
    }
};

pub const Detection = struct {
    app: App = .none,
    state: State = .none,
    confidence: u8 = 0,

    pub fn visible(self: Detection) bool {
        return self.app != .none and self.state != .none and self.confidence > 0;
    }

    pub fn appLabel(self: Detection) []const u8 {
        return self.app.label();
    }

    pub fn stateLabel(self: Detection) []const u8 {
        return self.state.label();
    }

    pub fn badge(self: Detection) []const u8 {
        return self.state.badge();
    }
};

pub const SessionText = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,

    pub fn set(self: *SessionText, value: []const u8) !void {
        if (value.len > self.buf.len) return error.SessionFieldTooLong;
        for (value) |ch| {
            if (ch < 0x20 or ch == 0x7f) return error.SessionFieldContainsControl;
        }
        @memcpy(self.buf[0..value.len], value);
        self.len = value.len;
    }

    pub fn slice(self: *const SessionText) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const SessionMarker = struct {
    app: App = .none,
    session_id: SessionText = .{},
    session_path: SessionText = .{},
    session_start_source: SessionText = .{},
};

fn lowerAscii(ch: u8) u8 {
    return if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var matched = true;
        for (needle, 0..) |needle_ch, i| {
            if (lowerAscii(haystack[start + i]) != lowerAscii(needle_ch)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

fn containsAnyIgnoreCase(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (containsIgnoreCase(haystack, needle)) return true;
    }
    return false;
}

fn lastIndexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return haystack.len;
    if (needle.len > haystack.len) return null;

    var start = haystack.len - needle.len;
    while (true) {
        var matched = true;
        for (needle, 0..) |needle_ch, i| {
            if (lowerAscii(haystack[start + i]) != lowerAscii(needle_ch)) {
                matched = false;
                break;
            }
        }
        if (matched) return start;
        if (start == 0) return null;
        start -= 1;
    }
}

fn lastAnyIgnoreCase(haystack: []const u8, needles: []const []const u8) ?usize {
    var latest: ?usize = null;
    for (needles) |needle| {
        if (lastIndexOfIgnoreCase(haystack, needle)) |idx| {
            if (latest == null or idx > latest.?) latest = idx;
        }
    }
    return latest;
}

fn newerThan(idx: usize, other: ?usize) bool {
    return other == null or idx > other.?;
}

fn titleHasAttentionMarker(title: []const u8) bool {
    return containsIgnoreCase(title, "[ ! ]") or
        containsIgnoreCase(title, "[!]") or
        containsIgnoreCase(title, " ! ");
}

fn titleHasRunningMarker(title: []const u8) bool {
    return containsIgnoreCase(title, "[ * ]") or
        containsIgnoreCase(title, "[*]");
}

fn titleHasClaudeStatusMarker(title: []const u8) bool {
    return containsAnyIgnoreCase(title, &.{
        "\xe2\x9c\xbb", // U+273B
        "\xe2\x9c\xa2", // U+2722
        "\xe2\x9c\xbd", // U+273D
    });
}

fn detectClaudeCode(title: []const u8, recent_output: []const u8) ?Detection {
    const claude_seen = containsAnyIgnoreCase(title, &.{
        "claude",
        "claude code",
        "claude-code",
    }) or titleHasClaudeStatusMarker(title) or
        containsAnyIgnoreCase(recent_output, &.{
            "claude code",
            "claude.ai/code/session",
            "do you want to make this edit",
            "do you want to make this change",
            "do you want to run this command",
            "yes, allow all edits during this session",
            "yes, allow all tools during this session",
        });
    if (!claude_seen) return null;

    const approval_idx = lastAnyIgnoreCase(recent_output, &.{
        "do you want to make this edit",
        "do you want to make this change",
        "do you want to create",
        "do you want to run this command",
        "do you want to proceed",
        "yes, allow all edits during this session",
        "yes, allow all tools during this session",
        "yes, allow all commands during this session",
    });
    const running_idx = lastAnyIgnoreCase(recent_output, &.{
        "thinking",
        "Update(",
        "Edit(",
        "MultiEdit(",
        "Write(",
        "Bash(",
        "Read(",
        "Grep(",
        "Glob(",
        "Task(",
        "TodoWrite(",
        "WebFetch(",
    });
    const halted_idx = lastAnyIgnoreCase(recent_output, &.{
        "interrupted by user",
        "operation cancelled",
        "operation canceled",
        "aborted",
    });
    const failure_idx = lastAnyIgnoreCase(recent_output, &.{
        "permission denied",
        "command failed",
        "error:",
        "failed",
    });
    const done_idx = lastAnyIgnoreCase(recent_output, &.{
        "no changes to make",
        "completed successfully",
        "all set",
    });

    if (approval_idx) |idx| {
        if (newerThan(idx, running_idx) and newerThan(idx, halted_idx) and newerThan(idx, failure_idx) and newerThan(idx, done_idx)) {
            return .{ .app = .claude_code, .state = .waiting_approval, .confidence = 90 };
        }
    }
    if (halted_idx) |idx| {
        if (newerThan(idx, done_idx) and newerThan(idx, running_idx)) {
            return .{ .app = .claude_code, .state = .halted, .confidence = 92 };
        }
    }
    if (failure_idx) |idx| {
        if (newerThan(idx, done_idx) and newerThan(idx, running_idx) and newerThan(idx, halted_idx)) {
            return .{ .app = .claude_code, .state = .failed, .confidence = 76 };
        }
    }
    if (done_idx) |idx| {
        if (newerThan(idx, running_idx) and newerThan(idx, halted_idx) and newerThan(idx, failure_idx)) {
            return .{ .app = .claude_code, .state = .done, .confidence = 76 };
        }
    }
    if (titleHasAttentionMarker(title)) {
        return .{ .app = .claude_code, .state = .needs_input, .confidence = 72 };
    }
    if (running_idx) |idx| {
        if (newerThan(idx, done_idx) and newerThan(idx, halted_idx)) {
            return .{ .app = .claude_code, .state = .running, .confidence = 82 };
        }
    }
    if (titleHasRunningMarker(title) or titleHasClaudeStatusMarker(title)) {
        return .{ .app = .claude_code, .state = .running, .confidence = 82 };
    }

    return .{ .app = .claude_code, .state = .none, .confidence = 45 };
}

pub fn detect(title: []const u8, recent_output: []const u8) Detection {
    if (detectClaudeCode(title, recent_output)) |detection| return detection;

    const codex_seen = containsAnyIgnoreCase(title, &.{ "codex", "[ ! ]", "[!]", "[ * ]", "[*]" }) or
        containsAnyIgnoreCase(recent_output, &.{
            "codex",
            "execution halted",
            "esc to interrupt",
            "transcript)",
            "background terminal",
            "approved codex",
            "would you like to make the following edits",
            "press enter to confirm or esc to cancel",
            "retry without sandbox",
        });
    if (!codex_seen) return .{};

    const approval_idx = lastAnyIgnoreCase(recent_output, &.{
        "do you want codex",
        "approve codex",
        "approval required",
        "would you like to make the following edits",
        "press enter to confirm or esc to cancel",
        "yes, proceed",
        "don't ask again",
        "retry without sandbox",
    });
    const approved_idx = lastAnyIgnoreCase(recent_output, &.{
        "you approved codex",
        "you approved",
    });
    const active_approval = if (approval_idx) |prompt_idx|
        approved_idx == null or prompt_idx > approved_idx.?
    else
        false;

    if (active_approval) {
        return .{ .app = .codex, .state = .waiting_approval, .confidence = 90 };
    }

    const halted_idx = lastAnyIgnoreCase(recent_output, &.{
        "execution halted",
    });
    const done_idx = lastAnyIgnoreCase(recent_output, &.{
        "worked for ",
    });
    const running_idx = lastAnyIgnoreCase(recent_output, &.{
        "working (",
        "esc to interrupt",
        "waited for background terminal",
    });
    const failure_idx = lastAnyIgnoreCase(recent_output, &.{ "permission denied", "command failed" });
    const ready_idx = lastAnyIgnoreCase(recent_output, &.{
        "openai codex",
        "model:",
        "directory:",
        "/model to change",
    });

    if (halted_idx) |idx| {
        if (newerThan(idx, done_idx)) {
            return .{ .app = .codex, .state = .halted, .confidence = 96 };
        }
    }
    if (failure_idx) |idx| {
        const is_after_approval = approved_idx == null or idx > approved_idx.?;
        if (is_after_approval and newerThan(idx, done_idx) and newerThan(idx, running_idx) and newerThan(idx, halted_idx)) {
            return .{ .app = .codex, .state = .failed, .confidence = 78 };
        }
    }
    if (done_idx) |idx| {
        if (newerThan(idx, running_idx) and newerThan(idx, halted_idx) and newerThan(idx, failure_idx)) {
            return .{ .app = .codex, .state = .done, .confidence = 82 };
        }
    }
    if (titleHasAttentionMarker(title)) {
        return .{ .app = .codex, .state = .needs_input, .confidence = 72 };
    }
    if (running_idx) |idx| {
        if (newerThan(idx, done_idx) and newerThan(idx, halted_idx)) {
            return .{ .app = .codex, .state = .running, .confidence = 82 };
        }
    }
    if (titleHasRunningMarker(title)) {
        return .{ .app = .codex, .state = .running, .confidence = 82 };
    }
    if (ready_idx) |idx| {
        if (newerThan(idx, running_idx) and newerThan(idx, done_idx) and newerThan(idx, halted_idx) and newerThan(idx, failure_idx)) {
            return .{ .app = .codex, .state = .needs_input, .confidence = 74 };
        }
    }

    return .{ .app = .codex, .state = .none, .confidence = 45 };
}

test "agent detector recognizes Codex halted output" {
    const detection = detect("[ ! ]", "Execution halted\nWorking (3m 11s - esc to interrupt)");
    try std.testing.expectEqual(App.codex, detection.app);
    try std.testing.expectEqual(State.halted, detection.state);
    try std.testing.expect(detection.visible());
}

test "agent detector recognizes Codex running output" {
    const detection = detect("codex", "Working (12s - esc to interrupt)");
    try std.testing.expectEqual(App.codex, detection.app);
    try std.testing.expectEqual(State.running, detection.state);
}

test "agent detector treats Codex sandbox retry prompt as approval" {
    const output =
        \\Would you like to make the following edits?
        \\
        \\Reason: command failed; retry without sandbox?
        \\
        \\> 1. Yes, proceed (y)
        \\  2. Yes, and don't ask again for these files (a)
        \\  3. No, and tell codex what to do differently (esc)
        \\
        \\Press enter to confirm or esc to cancel
    ;
    const detection = detect("[ ! ]", output);
    try std.testing.expectEqual(App.codex, detection.app);
    try std.testing.expectEqual(State.waiting_approval, detection.state);
    try std.testing.expectEqualStrings("ask", detection.badge());
}

test "agent detector ignores stale approval prompt after Codex approval" {
    const output =
        \\Would you like to make the following edits?
        \\Reason: command failed; retry without sandbox?
        \\Press enter to confirm or esc to cancel
        \\You approved codex to run python3 this time
        \\Working (3s - esc to interrupt)
    ;
    const detection = detect("codex", output);
    try std.testing.expectEqual(App.codex, detection.app);
    try std.testing.expectEqual(State.running, detection.state);
}

test "agent detector marks Codex completion after running output as done" {
    const output =
        \\Working (12s - esc to interrupt)
        \\You approved codex to run zsh this time
        \\Ran zsh -lc 'node /data1/home/xzg/hell.js'
        \\Worked for 2m 14s
        \\› use /skills to list available skills
    ;
    const detection = detect("codex", output);
    try std.testing.expectEqual(App.codex, detection.app);
    try std.testing.expectEqual(State.done, detection.state);
    try std.testing.expectEqualStrings("done", detection.badge());
}

test "agent detector prefers newer running marker after old completion" {
    const output =
        \\Worked for 2m 14s
        \\Working (3s - esc to interrupt)
    ;
    const detection = detect("codex", output);
    try std.testing.expectEqual(App.codex, detection.app);
    try std.testing.expectEqual(State.running, detection.state);
}

test "agent detector recognizes Claude Code approval prompt" {
    const output =
        \\Claude Code v2.1.140
        \\Update(tools/clashmate/index.html)
        \\Do you want to make this edit to index.html?
        \\  1. Yes
        \\  2. Yes, allow all edits during this session (shift+tab)
        \\  3. No
    ;
    const detection = detect("Claude Code v2.1.140", output);
    try std.testing.expectEqual(App.claude_code, detection.app);
    try std.testing.expectEqual(State.waiting_approval, detection.state);
    try std.testing.expectEqualStrings("ask", detection.badge());
}

test "agent detector recognizes Claude Code proceed prompt for bash approval" {
    const output =
        \\Bash command
        \\du -sh /home/data/xzg/.claude/projects/-home-data-xzg/memory/ 2>&1
        \\find with '-exec' executes commands or modifies files - cannot be auto-allowed by a Bash(find:*) prefix rule
        \\
        \\Do you want to proceed?
        \\> 1. Yes
        \\  2. No
    ;
    const detection = detect("Claude Code v2.1.144", output);
    try std.testing.expectEqual(App.claude_code, detection.app);
    try std.testing.expectEqual(State.waiting_approval, detection.state);
    try std.testing.expectEqualStrings("ask", detection.badge());
}

test "agent detector recognizes Claude Code running title marker" {
    const detection = detect("\xe2\x9c\xbb Hiding advanced features", "Read 5 files, listed 5 directories, ran 1 shell command");
    try std.testing.expectEqual(App.claude_code, detection.app);
    try std.testing.expectEqual(State.running, detection.state);
}

test "agent detector ignores stale Claude Code approval after newer tool output" {
    const output =
        \\Do you want to make this edit to index.html?
        \\  1. Yes
        \\Update(tools/clashmate/index.html)
    ;
    const detection = detect("Claude Code", output);
    try std.testing.expectEqual(App.claude_code, detection.app);
    try std.testing.expectEqual(State.running, detection.state);
}

test "agent detector ignores normal shell output" {
    const detection = detect("Local Shell", "$ ls");
    try std.testing.expectEqual(App.none, detection.app);
    try std.testing.expectEqual(State.none, detection.state);
    try std.testing.expect(!detection.visible());
}

test "agent detector recognizes Codex ready screen" {
    const output =
        \\OpenAI Codex (v0.135.0)
        \\model:     gpt-5.5 xhigh   /model to change
        \\directory: ~
    ;
    const detection = detect("xzg", output);
    try std.testing.expectEqual(App.codex, detection.app);
    try std.testing.expectEqual(State.needs_input, detection.state);
}

// ---------------------------------------------------------------------------
// OSC 7748 authoritative marker (replaces the old agent_state.zig vocabulary)
// ---------------------------------------------------------------------------

/// Our private agent-state OSC: OSC 7748 ; wispterm-agent ; state=<label> [; app=<label>] ST
/// Emitted by agent hooks (e.g. Claude Code) for an AUTHORITATIVE state signal
/// that overrides the heuristic `detect`. The wire labels are this module's own
/// State/App `.label()` strings (running/waiting_approval/needs_input/halted/
/// failed/done; codex/claude_code), so no separate vocabulary exists.
pub const OSC_NUM: u16 = 7748;
pub const TAG = "wispterm-agent";

/// Inverse of State.label().
pub fn stateFromLabel(s: []const u8) ?State {
    if (std.mem.eql(u8, s, "none")) return .none;
    if (std.mem.eql(u8, s, "running")) return .running;
    if (std.mem.eql(u8, s, "waiting_approval")) return .waiting_approval;
    if (std.mem.eql(u8, s, "needs_input")) return .needs_input;
    if (std.mem.eql(u8, s, "halted")) return .halted;
    if (std.mem.eql(u8, s, "failed")) return .failed;
    if (std.mem.eql(u8, s, "done")) return .done;
    return null;
}

/// Inverse of App.label().
pub fn appFromLabel(s: []const u8) ?App {
    if (std.mem.eql(u8, s, "none")) return .none;
    if (std.mem.eql(u8, s, "codex")) return .codex;
    if (std.mem.eql(u8, s, "claude_code")) return .claude_code;
    return null;
}

/// Map a tmux `#{pane_current_command}` (process basename) to an App.
pub fn appFromCommand(cmd: []const u8) App {
    const base = std.fs.path.basename(std.mem.trim(u8, cmd, " "));
    if (std.mem.eql(u8, base, "claude")) return .claude_code;
    if (std.mem.eql(u8, base, "codex")) return .codex;
    return .none;
}

/// Parse the OSC 7748 payload (after `OSC 7748;`, terminator stripped):
/// `wispterm-agent;state=running;app=claude_code`. Returns an authoritative
/// Detection (confidence 100). Requires a recognized `state=`; `app=` optional
/// (defaults .none). Returns null if the tag is missing or state is absent/unknown.
pub fn parseMarker(payload: []const u8) ?Detection {
    var it = std.mem.splitScalar(u8, payload, ';');
    const first = it.next() orelse return null;
    if (!std.mem.eql(u8, std.mem.trim(u8, first, " "), TAG)) return null;
    var st: ?State = null;
    var app: App = .none;
    while (it.next()) |field| {
        const f = std.mem.trim(u8, field, " ");
        if (std.mem.startsWith(u8, f, "state=")) {
            st = stateFromLabel(f["state=".len..]);
        } else if (std.mem.startsWith(u8, f, "app=")) {
            if (appFromLabel(f["app=".len..])) |a| app = a;
        }
    }
    const state = st orelse return null;
    return .{ .app = app, .state = state, .confidence = 100 };
}

/// Parse metadata-only OSC 7748 session marker:
/// `wispterm-agent;event=session;app=claude_code;data=<base64url-json>`.
/// Returns null for state markers or malformed metadata. This is intentionally
/// not an authoritative Detection and must not suppress heuristic detection.
pub fn parseSessionMarker(allocator: std.mem.Allocator, payload: []const u8) !?SessionMarker {
    var it = std.mem.splitScalar(u8, payload, ';');
    const first = it.next() orelse return null;
    if (!std.mem.eql(u8, std.mem.trim(u8, first, " "), TAG)) return null;

    var event_session = false;
    var app: App = .none;
    var data: ?[]const u8 = null;
    while (it.next()) |field| {
        const f = std.mem.trim(u8, field, " ");
        if (std.mem.eql(u8, f, "event=session")) {
            event_session = true;
        } else if (std.mem.startsWith(u8, f, "app=")) {
            if (appFromLabel(f["app=".len..])) |a| app = a;
        } else if (std.mem.startsWith(u8, f, "data=")) {
            data = f["data=".len..];
        } else if (std.mem.startsWith(u8, f, "state=")) {
            return null;
        }
    }

    if (!event_session or app == .none) return null;
    const encoded = data orelse return null;

    const decoder = std.base64.url_safe_no_pad.Decoder;
    const decoded_len = decoder.calcSizeForSlice(encoded) catch return null;
    if (decoded_len == 0 or decoded_len > 4096) return null;
    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);
    decoder.decode(decoded, encoded) catch return null;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, decoded, .{
        .allocate = .alloc_always,
    }) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    const sid_val = parsed.value.object.get("session_id") orelse return null;
    if (sid_val != .string or sid_val.string.len == 0) return null;

    var marker: SessionMarker = .{ .app = app };
    marker.session_id.set(sid_val.string) catch return null;

    if (parsed.value.object.get("session_path")) |path_val| {
        if (path_val == .string and path_val.string.len > 0) {
            marker.session_path.set(path_val.string) catch return null;
        }
    }
    if (parsed.value.object.get("session_start_source")) |source_val| {
        if (source_val == .string and source_val.string.len > 0) {
            marker.session_start_source.set(source_val.string) catch return null;
        }
    }

    return marker;
}

/// Aggregate pane states into one tab-level indicator by attention priority.
/// Empty -> .none.
pub fn aggregate(states: []const State) State {
    var best: State = .none;
    for (states) |s| if (rank(s) > rank(best)) {
        best = s;
    };
    return best;
}

fn rank(s: State) u8 {
    return switch (s) {
        .none => 0,
        .done => 1,
        .running => 2,
        .halted, .failed => 3,
        .needs_input => 4,
        .waiting_approval => 5,
    };
}

test "parseMarker yields an authoritative Detection in the existing vocabulary" {
    const d = parseMarker("wispterm-agent;state=running;app=claude_code").?;
    try std.testing.expectEqual(App.claude_code, d.app);
    try std.testing.expectEqual(State.running, d.state);
    try std.testing.expectEqual(@as(u8, 100), d.confidence);
    try std.testing.expect(d.visible());
}

test "parseMarker maps waiting_approval and done" {
    try std.testing.expectEqual(State.waiting_approval, parseMarker("wispterm-agent;state=waiting_approval;app=claude_code").?.state);
    try std.testing.expectEqual(State.done, parseMarker("wispterm-agent;state=done;app=claude_code").?.state);
}

test "parseMarker rejects wrong tag / missing or unknown state" {
    try std.testing.expect(parseMarker("other;state=running") == null);
    try std.testing.expect(parseMarker("wispterm-agent;app=claude_code") == null);
    try std.testing.expect(parseMarker("wispterm-agent;state=bogus") == null);
}

test "parseSessionMarker decodes metadata-only OSC 7748 session markers" {
    const payload =
        "wispterm-agent;event=session;app=claude_code;data=eyJzZXNzaW9uX2lkIjoiY2xhdWRlLTEyMyIsInNlc3Npb25fcGF0aCI6Ii9ob21lL21lLy5jbGF1ZGUvcHJvamVjdHMveC5qc29ubCIsInNlc3Npb25fc3RhcnRfc291cmNlIjoic3RhcnR1cCJ9";
    const marker = try parseSessionMarker(std.testing.allocator, payload);
    try std.testing.expect(marker != null);
    try std.testing.expectEqual(App.claude_code, marker.?.app);
    try std.testing.expectEqualStrings("claude-123", marker.?.session_id.slice());
    try std.testing.expectEqualStrings("/home/me/.claude/projects/x.jsonl", marker.?.session_path.slice());
    try std.testing.expectEqualStrings("startup", marker.?.session_start_source.slice());
}

test "parseSessionMarker rejects state markers and unsafe metadata" {
    try std.testing.expect(try parseSessionMarker(std.testing.allocator, "wispterm-agent;state=running;app=claude_code") == null);
    try std.testing.expect(try parseSessionMarker(std.testing.allocator, "wispterm-agent;event=session;app=codex;data=not-base64") == null);
    const control_json = "eyJzZXNzaW9uX2lkIjoiYVx1MDAwN2IifQ";
    try std.testing.expect(try parseSessionMarker(std.testing.allocator, std.fmt.comptimePrint("wispterm-agent;event=session;app=codex;data={s}", .{control_json})) == null);
}

test "appFromCommand maps known agents" {
    try std.testing.expectEqual(App.claude_code, appFromCommand("claude"));
    try std.testing.expectEqual(App.codex, appFromCommand("/usr/bin/codex"));
    try std.testing.expectEqual(App.none, appFromCommand("bash"));
}

test "aggregate prefers the most attention-worthy state" {
    try std.testing.expectEqual(State.waiting_approval, aggregate(&.{ .running, .done, .waiting_approval }));
    try std.testing.expectEqual(State.running, aggregate(&.{ .none, .done, .running }));
    try std.testing.expectEqual(State.none, aggregate(&.{}));
}
