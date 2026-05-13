const std = @import("std");

pub const App = enum {
    none,
    codex,

    pub fn label(self: App) []const u8 {
        return switch (self) {
            .none => "none",
            .codex => "codex",
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

fn titleHasAttentionMarker(title: []const u8) bool {
    return containsIgnoreCase(title, "[ ! ]") or
        containsIgnoreCase(title, "[!]") or
        containsIgnoreCase(title, " ! ");
}

fn titleHasRunningMarker(title: []const u8) bool {
    return containsIgnoreCase(title, "[ * ]") or
        containsIgnoreCase(title, "[*]");
}

pub fn detect(title: []const u8, recent_output: []const u8) Detection {
    const codex_seen = containsAnyIgnoreCase(title, &.{ "codex", "[ ! ]", "[!]", "[ * ]", "[*]" }) or
        containsAnyIgnoreCase(recent_output, &.{
            "codex",
            "execution halted",
            "esc to interrupt",
            "transcript)",
            "background terminal",
            "approved codex",
        });
    if (!codex_seen) return .{};

    if (containsIgnoreCase(recent_output, "execution halted")) {
        return .{ .app = .codex, .state = .halted, .confidence = 96 };
    }
    if (containsAnyIgnoreCase(recent_output, &.{ "permission denied", "command failed" })) {
        return .{ .app = .codex, .state = .failed, .confidence = 78 };
    }
    if (containsAnyIgnoreCase(recent_output, &.{ "do you want codex", "approve codex", "approval required" }) and
        !containsIgnoreCase(recent_output, "you approved codex"))
    {
        return .{ .app = .codex, .state = .waiting_approval, .confidence = 88 };
    }
    if (titleHasAttentionMarker(title)) {
        return .{ .app = .codex, .state = .needs_input, .confidence = 72 };
    }
    if (containsAnyIgnoreCase(recent_output, &.{ "working (", "esc to interrupt", "waited for background terminal" }) or
        titleHasRunningMarker(title))
    {
        return .{ .app = .codex, .state = .running, .confidence = 82 };
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

test "agent detector ignores normal shell output" {
    const detection = detect("PowerShell", "PS C:\\Users> ls");
    try std.testing.expectEqual(App.none, detection.app);
    try std.testing.expectEqual(State.none, detection.state);
    try std.testing.expect(!detection.visible());
}
