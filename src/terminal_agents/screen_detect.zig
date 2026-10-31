//! Screen-based terminal-agent detection driver: the glue between a live
//! `Surface` and the pure manifest engine (`screen_manifest.zig`).
//!
//! Hook markers (OSC 7748) stay authoritative: while `agent_osc_active` is
//! set this module does nothing. Otherwise, once per frame per surface, it
//!
//!   1. refreshes the agent *identity* (throttled to ~1 Hz): the PTY's
//!      foreground process on local tabs, a seed from tmux / the launcher,
//!      or Claude Code's unmistakable title glyph for SSH tabs where the
//!      process is not visible;
//!   2. when the identity is known and output arrived since the last pass,
//!      snapshots the viewport text (never scrollback) and classifies it with
//!      that agent's manifest, mapping the result into `agent_detection`.
//!
//! Feature-owned state lives in `SurfaceState` (embedded in `Surface`) and
//! the enable flag below; the integration layer only calls `poll` and
//! repaints when it reports a change.

const std = @import("std");
const Surface = @import("../Surface.zig");
const detector = @import("detector.zig");
const manifest = @import("screen_manifest.zig");
const foreground_process = @import("../platform/foreground_process.zig");
const remote_snapshot = @import("../remote_snapshot.zig");
const session_types = @import("sessions/types.zig");

pub const IdentitySource = enum { none, process, seed, title };

/// The agent an AI-history resume launches, for seeding its tab's identity.
pub fn appForProvider(provider: session_types.ProviderId) detector.App {
    return switch (provider) {
        .codex => .codex,
        .claude => .claude_code,
        .kimi => .kimi,
        .opencode => .opencode,
        .pi => .pi,
    };
}

/// Per-surface bookkeeping. The IO thread only touches `output_epoch`.
pub const SurfaceState = struct {
    /// Bumped by the IO thread per output chunk; the UI thread compares it to
    /// `seen_epoch` to skip re-classifying an unchanged screen.
    output_epoch: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    seen_epoch: u32 = 0,
    /// A classification is due (new output, identity change, or seen-reset).
    pending: bool = false,
    last_screen_ms: i64 = 0,
    last_identity_ms: i64 = 0,
    identity: IdentitySource = .none,
    app: detector.App = .none,
    /// A working state was observed since the user last looked at the pane.
    has_worked: bool = false,
    /// Consecutive identity ticks where a title-identified agent's title no
    /// longer looked like an agent.
    title_miss_ticks: u8 = 0,

    pub fn noteOutput(self: *SurfaceState) void {
        _ = self.output_epoch.fetchAdd(1, .monotonic);
    }

    /// Identity from a reliable external source (tmux `pane_current_command`,
    /// the resume launcher). `.none` releases a seeded identity.
    pub fn seed(self: *SurfaceState, app: detector.App) void {
        if (app == .none) {
            if (self.identity == .seed) self.clear();
            return;
        }
        if (self.identity == .process) return;
        self.app = app;
        self.identity = .seed;
        self.pending = true;
    }

    pub fn clear(self: *SurfaceState) void {
        self.app = .none;
        self.identity = .none;
        self.has_worked = false;
        self.title_miss_ticks = 0;
        self.pending = false;
    }
};

var g_enabled: bool = true;

/// Config toggle (`agent-screen-detection`).
pub fn setEnabled(enabled: bool) void {
    g_enabled = enabled;
}

pub fn isEnabled() bool {
    return g_enabled;
}

pub const screen_interval_ms: i64 = 120;
pub const identity_interval_ms: i64 = 1000;
const title_release_ticks: u8 = 3;

fn recognizes(name: []const u8) bool {
    return detector.appFromProcessName(name) != .none;
}

/// Run on the UI thread once per frame for each surface. `focused` is true
/// when the surface is the focused pane of the active tab (an unseen `done`
/// becomes `idle` once the user looks). Returns true when `agent_detection`
/// changed, so the caller can request a repaint.
pub fn poll(surface: *Surface, focused: bool, now_ms: i64) bool {
    if (!g_enabled) return false;
    if (surface.agent_osc_active) return false;
    const st = &surface.agent_screen;
    var changed = false;

    if (now_ms - st.last_identity_ms >= identity_interval_ms) {
        st.last_identity_ms = now_ms;
        if (refreshIdentity(surface, st)) changed = true;
    }
    if (st.app == .none) return changed;

    if (focused and st.has_worked and surface.agent_detection.state == .done) {
        st.has_worked = false;
        st.pending = true;
    }

    const epoch = st.output_epoch.load(.monotonic);
    if (epoch != st.seen_epoch) {
        st.seen_epoch = epoch;
        st.pending = true;
    }
    if (!st.pending) return changed;
    if (now_ms - st.last_screen_ms < screen_interval_ms) return changed;
    st.pending = false;
    st.last_screen_ms = now_ms;
    if (classify(surface, st)) changed = true;
    return changed;
}

fn windowTitle(surface: *const Surface) []const u8 {
    return surface.window_title[0..surface.window_title_len];
}

/// Claude Code titles its terminal "✳ <project>" at the prompt and lead with
/// a spinner glyph while working; no other supported agent uses the ✳/✻
/// marks, so they identify Claude on SSH tabs where the process is unseen.
fn titleLooksLikeClaude(title: []const u8) bool {
    return std.mem.startsWith(u8, title, "✳ ") or std.mem.startsWith(u8, title, "✻ ");
}

fn titleStillAgentLike(title: []const u8) bool {
    if (titleLooksLikeClaude(title)) return true;
    if (title.len < 3) return false;
    const cp = std.unicode.utf8Decode(title[0..std.math.clamp(std.unicode.utf8ByteSequenceLength(title[0]) catch 1, 1, title.len)]) catch return false;
    // Braille spinner or half-circle spinner, followed by a space.
    const spinner = (cp >= 0x2800 and cp <= 0x28FF) or (cp >= 0x25D0 and cp <= 0x25D3);
    return spinner and std.mem.indexOfScalar(u8, title, ' ') != null;
}

fn refreshIdentity(surface: *Surface, st: *SurfaceState) bool {
    var changed = false;
    var name_buf: [512]u8 = undefined;
    // Only a local tab's child is a shell. An SSH or WSL tab's child is the
    // transport (`ssh`, `wsl.exe`): it is always "in the foreground" and says
    // nothing about the remote agent, so it can neither identify nor release.
    const child_is_shell = surface.launchKind() == .local;
    if (child_is_shell) {
        if (foreground_process.query(&surface.pty, &surface.command.impl, &name_buf, recognizes)) |info| {
            const app = if (info.is_shell) .none else detector.appFromProcessName(info.name);
            if (app != .none) {
                if (st.app != app or st.identity != .process) {
                    st.app = app;
                    st.identity = .process;
                    st.pending = true;
                }
            } else if (info.is_shell and st.identity != .none) {
                // The agent exited back to the shell prompt.
                if (clearDetection(surface, st)) changed = true;
            }
            // A non-agent foreground program (pager, editor) keeps whatever
            // identity we had: the agent may have spawned it.
        }
    }

    if (st.app == .none) {
        if (titleLooksLikeClaude(windowTitle(surface))) {
            st.app = .claude_code;
            st.identity = .title;
            st.title_miss_ticks = 0;
            st.pending = true;
        }
    } else if (st.identity == .title) {
        if (titleStillAgentLike(windowTitle(surface))) {
            st.title_miss_ticks = 0;
        } else {
            st.title_miss_ticks += 1;
            if (st.title_miss_ticks >= title_release_ticks) {
                if (clearDetection(surface, st)) changed = true;
            }
        }
    }
    return changed;
}

fn clearDetection(surface: *Surface, st: *SurfaceState) bool {
    st.clear();
    if (surface.agent_detection.app == .none and surface.agent_detection.state == .none) return false;
    surface.agent_detection = .{};
    return true;
}

const ScreenText = struct {
    buf: []u8,
    len: usize,

    fn text(self: ScreenText) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Viewport text with CRLF row separators normalized to LF (the manifests'
/// regions and regexes are written for '\n'-separated lines).
fn allocScreenText(surface: *Surface) !ScreenText {
    const raw = blk: {
        surface.render_state.mutex.lock();
        defer surface.render_state.mutex.unlock();
        break :blk try remote_snapshot.allocTerminalSnapshot(surface.allocator, &surface.terminal, 0);
    };
    var w: usize = 0;
    var r: usize = 0;
    while (r < raw.len) : (r += 1) {
        if (raw[r] == '\r' and r + 1 < raw.len and raw[r + 1] == '\n') continue;
        raw[w] = raw[r];
        w += 1;
    }
    return .{ .buf = raw, .len = w };
}

fn classify(surface: *Surface, st: *SurfaceState) bool {
    const screen = allocScreenText(surface) catch return false;
    defer surface.allocator.free(screen.buf);
    const res = manifest.detect(st.app, .{
        .screen = screen.text(),
        .osc_title = windowTitle(surface),
    }) orelse return false;
    const next = manifest.mapToDetection(st.app, res, &st.has_worked) orelse return false;
    if (std.meta.eql(next, surface.agent_detection)) return false;
    surface.agent_detection = next;
    return true;
}

test "title signatures: Claude's prompt glyph identifies, spinners keep, others release" {
    try std.testing.expect(titleLooksLikeClaude("✳ wispterm"));
    try std.testing.expect(titleLooksLikeClaude("✻ Hiding advanced features"));
    try std.testing.expect(!titleLooksLikeClaude("codex"));
    try std.testing.expect(titleStillAgentLike("⠋ Thinking"));
    try std.testing.expect(titleStillAgentLike("◐ Claude Code"));
    try std.testing.expect(!titleStillAgentLike("user@host: ~"));
    try std.testing.expect(!titleStillAgentLike(""));
}

test "SurfaceState seeding never overrides a process identity" {
    var st = SurfaceState{};
    st.seed(.codex);
    try std.testing.expectEqual(detector.App.codex, st.app);
    try std.testing.expectEqual(IdentitySource.seed, st.identity);
    try std.testing.expect(st.pending);
    st.identity = .process;
    st.app = .claude_code;
    st.seed(.codex);
    try std.testing.expectEqual(detector.App.claude_code, st.app);
    st.seed(.none);
    try std.testing.expectEqual(detector.App.claude_code, st.app);
    st.identity = .seed;
    st.seed(.none);
    try std.testing.expectEqual(detector.App.none, st.app);
    try std.testing.expectEqual(IdentitySource.none, st.identity);
}
