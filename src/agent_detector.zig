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

pub fn detect(title: []const u8, recent_output: []const u8) Detection {
    _ = title;
    _ = recent_output;
    return .{};
}

test "agent detector ignores legacy Codex halted PTY output" {
    const detection = detect("[ ! ]", "Execution halted\nWorking (3m 11s - esc to interrupt)");
    try std.testing.expectEqual(App.none, detection.app);
    try std.testing.expectEqual(State.none, detection.state);
    try std.testing.expect(!detection.visible());
}

test "agent detector ignores legacy Codex running PTY output" {
    const detection = detect("codex", "Working (12s - esc to interrupt)");
    try std.testing.expectEqual(App.none, detection.app);
    try std.testing.expectEqual(State.none, detection.state);
}

test "agent detector ignores legacy Codex approval PTY output" {
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
    try std.testing.expectEqual(App.none, detection.app);
    try std.testing.expectEqual(State.none, detection.state);
}

test "agent detector ignores stale legacy Codex approval PTY output" {
    const output =
        \\Would you like to make the following edits?
        \\Reason: command failed; retry without sandbox?
        \\Press enter to confirm or esc to cancel
        \\You approved codex to run python3 this time
        \\Working (3s - esc to interrupt)
    ;
    const detection = detect("codex", output);
    try std.testing.expectEqual(App.none, detection.app);
    try std.testing.expectEqual(State.none, detection.state);
}

test "agent detector ignores legacy Codex completion PTY output" {
    const output =
        \\Working (12s - esc to interrupt)
        \\You approved codex to run zsh this time
        \\Ran zsh -lc 'node /data1/home/xzg/hell.js'
        \\Worked for 2m 14s
        \\› use /skills to list available skills
    ;
    const detection = detect("codex", output);
    try std.testing.expectEqual(App.none, detection.app);
    try std.testing.expectEqual(State.none, detection.state);
}

test "agent detector ignores legacy Codex completion and running PTY output" {
    const output =
        \\Worked for 2m 14s
        \\Working (3s - esc to interrupt)
    ;
    const detection = detect("codex", output);
    try std.testing.expectEqual(App.none, detection.app);
    try std.testing.expectEqual(State.none, detection.state);
}

test "agent detector ignores legacy Claude Code approval PTY output" {
    const output =
        \\Claude Code v2.1.140
        \\Update(tools/clashmate/index.html)
        \\Do you want to make this edit to index.html?
        \\  1. Yes
        \\  2. Yes, allow all edits during this session (shift+tab)
        \\  3. No
    ;
    const detection = detect("Claude Code v2.1.140", output);
    try std.testing.expectEqual(App.none, detection.app);
    try std.testing.expectEqual(State.none, detection.state);
}

test "agent detector ignores legacy Claude Code title marker" {
    const detection = detect("\xe2\x9c\xbb Hiding advanced features", "Read 5 files, listed 5 directories, ran 1 shell command");
    try std.testing.expectEqual(App.none, detection.app);
    try std.testing.expectEqual(State.none, detection.state);
}

test "agent detector ignores stale legacy Claude Code approval PTY output" {
    const output =
        \\Do you want to make this edit to index.html?
        \\  1. Yes
        \\Update(tools/clashmate/index.html)
    ;
    const detection = detect("Claude Code", output);
    try std.testing.expectEqual(App.none, detection.app);
    try std.testing.expectEqual(State.none, detection.state);
}

test "agent detector ignores normal shell output" {
    const detection = detect("Local Shell", "$ ls");
    try std.testing.expectEqual(App.none, detection.app);
    try std.testing.expectEqual(State.none, detection.state);
    try std.testing.expect(!detection.visible());
}

test "agent detector ignores legacy Codex ready screen" {
    const output =
        \\OpenAI Codex (v0.135.0)
        \\model:     gpt-5.5 xhigh   /model to change
        \\directory: ~
    ;
    const detection = detect("xzg", output);
    try std.testing.expectEqual(App.none, detection.app);
    try std.testing.expectEqual(State.none, detection.state);
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
