const std = @import("std");

/// Terminal agents WispTerm can recognize. The wire labels (`label()`) are the
/// canonical names herdr uses for the same agents, so the screen-detection
/// manifests under `manifests/` and the OSC 7748 marker share one vocabulary.
/// `claude_code` keeps its historical label; "claude" is accepted as an alias.
pub const App = enum {
    none,
    codex,
    claude_code,
    /// In-app AI session (AI-chat tab / copilot sidebar), not a PTY agent.
    /// Lets tab badges reuse Detection for those sessions.
    assistant,
    pi,
    gemini,
    cursor,
    devin,
    agy,
    cline,
    opencode,
    copilot,
    kimi,
    kiro,
    droid,
    amp,
    grok,
    hermes,
    kilo,
    qodercli,
    qwen,
    letta,
    maki,
    muse,

    pub fn label(self: App) []const u8 {
        return switch (self) {
            .none => "none",
            .codex => "codex",
            .claude_code => "claude_code",
            .assistant => "assistant",
            .pi => "pi",
            .gemini => "gemini",
            .cursor => "cursor",
            .devin => "devin",
            .agy => "agy",
            .cline => "cline",
            .opencode => "opencode",
            .copilot => "copilot",
            .kimi => "kimi",
            .kiro => "kiro",
            .droid => "droid",
            .amp => "amp",
            .grok => "grok",
            .hermes => "hermes",
            .kilo => "kilo",
            .qodercli => "qodercli",
            .qwen => "qwen",
            .letta => "letta",
            .maki => "maki",
            .muse => "muse",
        };
    }

    /// Human-facing name for notification titles.
    pub fn displayName(self: App) []const u8 {
        return switch (self) {
            .none => "Agent",
            .codex => "Codex",
            .claude_code => "Claude Code",
            .assistant => "Copilot",
            .pi => "Pi",
            .gemini => "Gemini CLI",
            .cursor => "Cursor Agent",
            .devin => "Devin CLI",
            .agy => "Antigravity CLI",
            .cline => "Cline",
            .opencode => "OpenCode",
            .copilot => "Copilot CLI",
            .kimi => "Kimi Code",
            .kiro => "Kiro CLI",
            .droid => "Droid",
            .amp => "Amp",
            .grok => "Grok CLI",
            .hermes => "Hermes Agent",
            .kilo => "Kilo Code",
            .qodercli => "Qoder CLI",
            .qwen => "Qwen Code",
            .letta => "Letta Code",
            .maki => "Maki",
            .muse => "Muse Code",
        };
    }

    /// True for agents that run in a PTY and have a screen-detection manifest.
    pub fn isTerminalAgent(self: App) bool {
        return switch (self) {
            .none, .assistant => false,
            else => true,
        };
    }
};

pub const State = enum {
    none,
    /// Agent is at its prompt, ready for input, and nothing has finished
    /// since the user last looked (screen detection's "idle"; `done` is the
    /// unseen-completion variant).
    idle,
    running,
    waiting_approval,
    needs_input,
    halted,
    failed,
    done,

    pub fn label(self: State) []const u8 {
        return switch (self) {
            .none => "none",
            .idle => "idle",
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
            .idle => "idle",
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
/// failed/done; codex/claude_code/pi), so no separate vocabulary exists.
pub const OSC_NUM: u16 = 7748;
pub const TAG = "wispterm-agent";

/// Inverse of State.label().
pub fn stateFromLabel(s: []const u8) ?State {
    if (std.mem.eql(u8, s, "none")) return .none;
    if (std.mem.eql(u8, s, "idle")) return .idle;
    if (std.mem.eql(u8, s, "running")) return .running;
    if (std.mem.eql(u8, s, "waiting_approval")) return .waiting_approval;
    if (std.mem.eql(u8, s, "needs_input")) return .needs_input;
    if (std.mem.eql(u8, s, "halted")) return .halted;
    if (std.mem.eql(u8, s, "failed")) return .failed;
    if (std.mem.eql(u8, s, "done")) return .done;
    return null;
}

/// Inverse of App.label(). Accepts "claude" for `.claude_code` so the herdr
/// canonical label round-trips too.
pub fn appFromLabel(s: []const u8) ?App {
    if (std.mem.eql(u8, s, "none")) return .none;
    if (std.mem.eql(u8, s, "assistant")) return .assistant;
    if (std.mem.eql(u8, s, "claude_code")) return .claude_code;
    inline for (std.meta.fields(App)) |field| {
        const app: App = @enumFromInt(field.value);
        if (app != .none and app != .assistant and std.mem.eql(u8, s, app.label())) return app;
    }
    if (std.mem.eql(u8, s, "claude")) return .claude_code;
    return null;
}

/// Executable / process names (and the aliases herdr accepts) for each
/// terminal agent. Lookups go through `appFromProcessName`.
const process_aliases = [_]struct { name: []const u8, app: App }{
    .{ .name = "pi", .app = .pi },
    .{ .name = "claude", .app = .claude_code },
    .{ .name = "claude-code", .app = .claude_code },
    .{ .name = "codex", .app = .codex },
    .{ .name = "gemini", .app = .gemini },
    .{ .name = "cursor", .app = .cursor },
    .{ .name = "cursor-agent", .app = .cursor },
    .{ .name = "devin", .app = .devin },
    .{ .name = "devin-cli", .app = .devin },
    .{ .name = "agy", .app = .agy },
    .{ .name = "antigravity", .app = .agy },
    .{ .name = "antigravity-cli", .app = .agy },
    .{ .name = "cline", .app = .cline },
    .{ .name = ".cline", .app = .cline },
    .{ .name = "opencode", .app = .opencode },
    .{ .name = "opencode2", .app = .opencode },
    .{ .name = "open-code", .app = .opencode },
    .{ .name = "copilot", .app = .copilot },
    .{ .name = "github-copilot", .app = .copilot },
    .{ .name = "ghcs", .app = .copilot },
    .{ .name = "kimi", .app = .kimi },
    .{ .name = "kimi-code", .app = .kimi },
    .{ .name = "kiro", .app = .kiro },
    .{ .name = "kiro-cli", .app = .kiro },
    .{ .name = "droid", .app = .droid },
    .{ .name = "amp", .app = .amp },
    .{ .name = "amp-local", .app = .amp },
    .{ .name = "grok", .app = .grok },
    .{ .name = "grok-build", .app = .grok },
    .{ .name = "hermes", .app = .hermes },
    .{ .name = "hermes-agent", .app = .hermes },
    .{ .name = "kilo", .app = .kilo },
    .{ .name = "kilo-code", .app = .kilo },
    .{ .name = "qodercli", .app = .qodercli },
    .{ .name = "qoderclicn", .app = .qodercli },
    .{ .name = "qoder", .app = .qodercli },
    .{ .name = "qodercn", .app = .qodercli },
    .{ .name = "qwen", .app = .qwen },
    .{ .name = "qwen-code", .app = .qwen },
    .{ .name = "letta", .app = .letta },
    .{ .name = "letta-code", .app = .letta },
    .{ .name = "maki", .app = .maki },
    .{ .name = "muse", .app = .muse },
    .{ .name = "muse-code", .app = .muse },
    .{ .name = "muse-cli", .app = .muse },
};

/// Map a process or executable name to an App: the basename is taken, a
/// Windows launcher extension (`.exe`, `.cmd`, `.bat`, `.ps1`) is dropped,
/// and the lookup is case-insensitive. Muse's versioned launcher
/// (`muse-bin-<version>`) is recognized like herdr does. Unknown → `.none`.
pub fn appFromProcessName(name: []const u8) App {
    var buf: [128]u8 = undefined;
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    var base = std.fs.path.basename(trimmed);
    if (std.mem.lastIndexOfScalar(u8, base, '\\')) |i| base = base[i + 1 ..];
    if (base.len == 0 or base.len > buf.len) return .none;
    const lower = std.ascii.lowerString(buf[0..base.len], base);
    var stem: []const u8 = lower;
    inline for (.{ ".exe", ".cmd", ".bat", ".ps1" }) |ext| {
        if (std.mem.endsWith(u8, stem, ext)) stem = stem[0 .. stem.len - ext.len];
    }
    for (process_aliases) |alias| if (std.mem.eql(u8, stem, alias.name)) return alias.app;
    if (std.mem.startsWith(u8, stem, "muse-bin-") and stem.len > "muse-bin-".len and std.ascii.isDigit(stem["muse-bin-".len])) return .muse;
    return .none;
}

/// Map a tmux `#{pane_current_command}` (process basename) to an App.
pub fn appFromCommand(cmd: []const u8) App {
    return appFromProcessName(cmd);
}

pub const AgentCapabilities = packed struct {
    graceful_exit: bool = false,
    session_path: bool = false,
};

pub const MarkerInfo = struct {
    detection: Detection,
    capabilities: AgentCapabilities = .{},
    session_path: []const u8 = "",
};

fn hexValue(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

fn decodeSessionPath(encoded: []const u8, out: ?[]u8) ?[]const u8 {
    const buffer = out orelse return "";
    var pos: usize = 0;
    var i: usize = 0;
    while (i < encoded.len) : (i += 1) {
        const byte = if (encoded[i] == '%') blk: {
            if (i + 2 >= encoded.len) return null;
            const hi = hexValue(encoded[i + 1]) orelse return null;
            const lo = hexValue(encoded[i + 2]) orelse return null;
            i += 2;
            break :blk (hi << 4) | lo;
        } else encoded[i];
        if (pos >= buffer.len) return null;
        buffer[pos] = byte;
        pos += 1;
    }
    return buffer[0..pos];
}

/// Parse the OSC 7748 payload (after `OSC 7748;`, terminator stripped):
/// `wispterm-agent;state=running;app=pi;capabilities=graceful_exit,session_path;session_path=%2F...`.
/// `session_path` is percent-decoded into `path_buf` when supplied. Returns
/// authoritative detection plus capability metadata; malformed encoded paths
/// are rejected rather than persisted as an unsafe restore command.
pub fn parseMarkerInfo(payload: []const u8, path_buf: ?[]u8) ?MarkerInfo {
    var it = std.mem.splitScalar(u8, payload, ';');
    const first = it.next() orelse return null;
    if (!std.mem.eql(u8, std.mem.trim(u8, first, " "), TAG)) return null;

    var st: ?State = null;
    var app: App = .none;
    var capabilities: AgentCapabilities = .{};
    var session_path: []const u8 = "";

    while (it.next()) |field| {
        const f = std.mem.trim(u8, field, " ");
        if (std.mem.startsWith(u8, f, "state=")) {
            st = stateFromLabel(f["state=".len..]);
        } else if (std.mem.startsWith(u8, f, "app=")) {
            if (appFromLabel(f["app=".len..])) |a| app = a;
        } else if (std.mem.startsWith(u8, f, "capabilities=")) {
            var caps = std.mem.splitScalar(u8, f["capabilities=".len..], ',');
            while (caps.next()) |cap| {
                if (std.mem.eql(u8, cap, "graceful_exit")) capabilities.graceful_exit = true;
                if (std.mem.eql(u8, cap, "session_path")) capabilities.session_path = true;
            }
        } else if (std.mem.startsWith(u8, f, "session_path=")) {
            session_path = decodeSessionPath(f["session_path=".len..], path_buf) orelse return null;
        }
    }

    const state = st orelse return null;
    return .{
        .detection = .{ .app = app, .state = state, .confidence = 100 },
        .capabilities = capabilities,
        .session_path = session_path,
    };
}

/// Backward-compatible detection-only parser for existing callers.
pub fn parseMarker(payload: []const u8) ?Detection {
    return if (parseMarkerInfo(payload, null)) |info| info.detection else null;
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
        .idle => 1,
        .done => 2,
        .running => 3,
        .halted, .failed => 4,
        .needs_input => 5,
        .waiting_approval => 6,
    };
}

test "parseMarker yields an authoritative Detection in the existing vocabulary" {
    const d = parseMarker("wispterm-agent;state=running;app=claude_code").?;
    try std.testing.expectEqual(App.claude_code, d.app);
    try std.testing.expectEqual(State.running, d.state);
    try std.testing.expectEqual(@as(u8, 100), d.confidence);
    try std.testing.expect(d.visible());
}

test "parseMarker maps Pi as an authoritative app" {
    const d = parseMarker("wispterm-agent;state=running;app=pi").?;
    try std.testing.expectEqual(App.pi, d.app);
    try std.testing.expectEqual(State.running, d.state);
}

test "parseMarkerInfo decodes Pi restore metadata and capabilities" {
    var path_buf: [256]u8 = undefined;
    const info = parseMarkerInfo("wispterm-agent;state=running;app=pi;capabilities=graceful_exit,session_path;session_path=%2Fhome%2Fpi%2F.pi%2Fagent%2Fsessions%2Fa%3Bb.jsonl", &path_buf).?;
    try std.testing.expectEqual(App.pi, info.detection.app);
    try std.testing.expect(info.capabilities.graceful_exit);
    try std.testing.expect(info.capabilities.session_path);
    try std.testing.expectEqualStrings("/home/pi/.pi/agent/sessions/a;b.jsonl", info.session_path);
}

test "parseMarker remains compatible with metadata markers" {
    const detection = parseMarker("wispterm-agent;state=done;app=pi;capabilities=graceful_exit;session_path=%2Ftmp%2Fpi.jsonl").?;
    try std.testing.expectEqual(App.pi, detection.app);
    try std.testing.expectEqual(State.done, detection.state);
}

test "parseMarkerInfo rejects malformed session paths" {
    var path_buf: [64]u8 = undefined;
    try std.testing.expect(parseMarkerInfo("wispterm-agent;state=running;app=pi;session_path=%ZZ", &path_buf) == null);
    try std.testing.expect(parseMarkerInfo("wispterm-agent;state=running;app=pi;session_path=%2", &path_buf) == null);
}

test "parseMarker maps waiting_approval and done" {
    try std.testing.expectEqual(State.waiting_approval, parseMarker("wispterm-agent;state=waiting_approval;app=claude_code").?.state);
    try std.testing.expectEqual(State.done, parseMarker("wispterm-agent;state=done;app=claude_code").?.state);
}

test "parseMarker keeps similarly named app labels distinct from Pi" {
    const d = parseMarker("wispterm-agent;state=running;app=pilot").?;
    try std.testing.expectEqual(App.none, d.app);
}

test "parseMarker rejects wrong tag / missing or unknown state" {
    try std.testing.expect(parseMarker("other;state=running") == null);
    try std.testing.expect(parseMarker("wispterm-agent;app=claude_code") == null);
    try std.testing.expect(parseMarker("wispterm-agent;state=bogus") == null);
}

test "appFromCommand maps known agents" {
    try std.testing.expectEqual(App.claude_code, appFromCommand("claude"));
    try std.testing.expectEqual(App.codex, appFromCommand("/usr/bin/codex"));
    try std.testing.expectEqual(App.pi, appFromCommand("pi"));
    try std.testing.expectEqual(App.none, appFromCommand("bash"));
}

test "appFromProcessName accepts herdr aliases, Windows launchers, and paths" {
    try std.testing.expectEqual(App.claude_code, appFromProcessName("claude.exe"));
    try std.testing.expectEqual(App.claude_code, appFromProcessName("C:\\Users\\me\\AppData\\Local\\Programs\\claude\\Claude.exe"));
    try std.testing.expectEqual(App.codex, appFromProcessName("codex.cmd"));
    try std.testing.expectEqual(App.cursor, appFromProcessName("cursor-agent"));
    try std.testing.expectEqual(App.agy, appFromProcessName("antigravity-cli"));
    try std.testing.expectEqual(App.copilot, appFromProcessName("ghcs"));
    try std.testing.expectEqual(App.kimi, appFromProcessName("kimi-code"));
    try std.testing.expectEqual(App.opencode, appFromProcessName("opencode2"));
    try std.testing.expectEqual(App.muse, appFromProcessName("/opt/muse/muse-bin-0.1.0-R708.1"));
    try std.testing.expectEqual(App.none, appFromProcessName("muse-binary"));
    try std.testing.expectEqual(App.none, appFromProcessName("node"));
    try std.testing.expectEqual(App.none, appFromProcessName(""));
    try std.testing.expectEqual(App.none, appFromProcessName("pilot"));
}

test "App labels round-trip for every terminal agent" {
    inline for (std.meta.fields(App)) |field| {
        const app: App = @enumFromInt(field.value);
        try std.testing.expectEqual(app, appFromLabel(app.label()).?);
        try std.testing.expect(app.displayName().len > 0);
    }
    try std.testing.expectEqual(App.claude_code, appFromLabel("claude").?);
    try std.testing.expect(App.gemini.isTerminalAgent());
    try std.testing.expect(!App.assistant.isTerminalAgent());
    try std.testing.expect(!App.none.isTerminalAgent());
}

test "idle state ranks below every attention state and round-trips its label" {
    try std.testing.expectEqual(State.idle, stateFromLabel("idle").?);
    try std.testing.expectEqualStrings("idle", State.idle.badge());
    try std.testing.expectEqual(State.done, aggregate(&.{ .idle, .done }));
    try std.testing.expectEqual(State.idle, aggregate(&.{ .none, .idle }));
    try std.testing.expectEqual(State.running, aggregate(&.{ .idle, .running, .done }));
}

test "assistant App round-trips its label and has a display name" {
    try std.testing.expectEqualStrings("assistant", App.assistant.label());
    try std.testing.expectEqual(App.assistant, appFromLabel("assistant").?);
    try std.testing.expectEqual(App.pi, appFromLabel("pi").?);
    try std.testing.expectEqualStrings("Copilot", App.assistant.displayName());
    try std.testing.expectEqualStrings("Claude Code", App.claude_code.displayName());
    try std.testing.expectEqualStrings("Codex", App.codex.displayName());
    try std.testing.expectEqualStrings("Pi", App.pi.displayName());
    try std.testing.expectEqualStrings("Agent", App.none.displayName());
}

test "aggregate prefers the most attention-worthy state" {
    try std.testing.expectEqual(State.waiting_approval, aggregate(&.{ .running, .done, .waiting_approval }));
    try std.testing.expectEqual(State.running, aggregate(&.{ .none, .done, .running }));
    try std.testing.expectEqual(State.none, aggregate(&.{}));
}
