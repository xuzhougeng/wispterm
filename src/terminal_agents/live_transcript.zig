//! Live transcript for a terminal pane that runs Claude Code / Codex. Finds the
//! agent's own session log (the OSC 7748 `session_path=` field when the hook
//! sends it, else the newest log for the pane's cwd) and renders its tail as
//! JSON for the remote layout, so a phone can show the pane as a conversation
//! instead of a 1:1 terminal. Pure file I/O, no UI.
const std = @import("std");
const types = @import("sessions/types.zig");
const claude = @import("sessions/provider_claude.zig");
const codex = @import("sessions/provider_codex.zig");
const prompt_answer = @import("prompt_answer.zig");
const detector = @import("detector.zig");

pub const MAX_MESSAGES = 40;
pub const MAX_TEXT_BYTES = 4000;
/// Only the tail of the log is parsed; a Claude Code session can grow to many MB.
pub const TAIL_BYTES = 2 * 1024 * 1024;
const LOOKUP_INTERVAL_MS = 10_000;
/// A running agent appends to its log many times a second; re-parsing the 2 MB
/// tail on every layout sync would stall the UI thread, so renders are rate-limited.
const RENDER_INTERVAL_MS = 1_000;
const CODEX_CANDIDATES = 8;

// ponytail: i64 ns (good until 2262) so the embedding Surface keeps 8-byte alignment.
const Stamp = struct { size: u64 = 0, mtime: i64 = 0 };

pub const LiveTranscript = struct {
    path: ?[]u8 = null,
    from_marker: bool = false,
    stamp: Stamp = .{},
    /// Cached JSON object (`{"provider":...}`) for the current file stamp.
    json: ?[]u8 = null,
    next_lookup_ms: i64 = 0,
    next_render_ms: i64 = 0,

    pub fn deinit(self: *LiveTranscript, allocator: std.mem.Allocator) void {
        if (self.path) |p| allocator.free(p);
        if (self.json) |j| allocator.free(j);
        self.* = .{};
    }

    /// Authoritative path from the agent hook (`session_path=` marker field).
    pub fn setPath(self: *LiveTranscript, allocator: std.mem.Allocator, path: []const u8) void {
        self.replacePath(allocator, path) catch return;
        self.from_marker = true;
    }

    /// JSON for the pane's current transcript, or null when no log is known.
    /// Cheap when nothing changed: one stat, no parsing.
    pub fn refresh(self: *LiveTranscript, allocator: std.mem.Allocator, app: detector.App, cwd: ?[]const u8) ?[]const u8 {
        const now = std.time.milliTimestamp();
        if (!self.from_marker and now >= self.next_lookup_ms) {
            self.next_lookup_ms = now + LOOKUP_INTERVAL_MS;
            if (lookup(allocator, app, cwd orelse "")) |found| {
                defer allocator.free(found);
                if (self.path == null or !std.mem.eql(u8, self.path.?, found)) self.replacePath(allocator, found) catch {};
            }
        }
        const path = self.path orelse return null;
        const stat = std.fs.cwd().statFile(path) catch return self.json;
        const stamp: Stamp = .{ .size = stat.size, .mtime = @intCast(stat.mtime) };
        if (self.json != null and stamp.size == self.stamp.size and stamp.mtime == self.stamp.mtime) return self.json;
        if (self.json != null and now < self.next_render_ms) return self.json;
        self.next_render_ms = now + RENDER_INTERVAL_MS;
        const json = render(allocator, app, path) catch return self.json;
        if (self.json) |old| allocator.free(old);
        self.json = json;
        self.stamp = stamp;
        return json;
    }

    fn replacePath(self: *LiveTranscript, allocator: std.mem.Allocator, path: []const u8) !void {
        const owned = try allocator.dupe(u8, path);
        if (self.path) |p| allocator.free(p);
        if (self.json) |j| allocator.free(j);
        self.path = owned;
        self.json = null;
        self.stamp = .{};
    }
};

fn providerLabel(app: detector.App) []const u8 {
    return switch (app) {
        .claude_code => "claude",
        .codex => "codex",
        else => "",
    };
}

const WireMessage = struct { role: []const u8, kind: []const u8, text: []const u8, ts: i64 };
const WireTranscript = struct { provider: []const u8, path: []const u8, total: usize, messages: []const WireMessage };

fn render(allocator: std.mem.Allocator, app: detector.App, path: []const u8) ![]u8 {
    const bytes = try readTail(allocator, path);
    defer allocator.free(bytes);
    const messages = switch (app) {
        .claude_code => try claude.parseTranscript(allocator, bytes),
        .codex => try codex.parseTranscript(allocator, bytes),
        else => return error.UnsupportedAgent,
    };
    defer switch (app) {
        .claude_code => claude.freeTranscript(allocator, messages),
        .codex => codex.freeTranscript(allocator, messages),
        else => {},
    };
    return renderMessages(allocator, providerLabel(app), path, messages);
}

pub fn renderMessages(allocator: std.mem.Allocator, provider: []const u8, path: []const u8, messages: []const types.TranscriptMessage) ![]u8 {
    const start = messages.len -| MAX_MESSAGES;
    var wire: std.ArrayListUnmanaged(WireMessage) = .empty;
    defer wire.deinit(allocator);
    for (messages[start..]) |m| {
        try wire.append(allocator, .{
            .role = @tagName(m.role),
            .kind = @tagName(m.kind),
            .text = truncateUtf8(m.content, MAX_TEXT_BYTES),
            .ts = m.timestamp_ms,
        });
    }
    const doc: WireTranscript = .{ .provider = provider, .path = path, .total = messages.len, .messages = wire.items };
    return std.json.Stringify.valueAlloc(allocator, doc, .{});
}

fn readTail(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const size = (try file.stat()).size;
    const want: usize = @intCast(@min(size, @as(u64, TAIL_BYTES)));
    const buf = try allocator.alloc(u8, want);
    errdefer allocator.free(buf);
    try file.seekTo(size - want);
    const n = try file.readAll(buf);
    var tail = buf[0..n];
    // A truncated first line is not valid JSONL; the parsers skip it anyway, but
    // dropping it keeps a half record from ever matching.
    if (want < size) {
        if (std.mem.indexOfScalar(u8, tail, '\n')) |nl| tail = tail[nl + 1 ..];
    }
    if (tail.ptr != buf.ptr or tail.len != buf.len) {
        const owned = try allocator.dupe(u8, tail);
        allocator.free(buf);
        return owned;
    }
    return buf;
}

/// Cut at a UTF-8 boundary so the JSON stays decodable on the phone.
pub fn truncateUtf8(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var end = max;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

// ---------------------------------------------------------------------------
// Session log lookup by cwd
// ---------------------------------------------------------------------------

fn homeDir(allocator: std.mem.Allocator) ?[]u8 {
    return std.process.getEnvVarOwned(allocator, "HOME") catch
        (std.process.getEnvVarOwned(allocator, "USERPROFILE") catch null);
}

fn lookup(allocator: std.mem.Allocator, app: detector.App, cwd: []const u8) ?[]u8 {
    if (cwd.len == 0) return null;
    const home = homeDir(allocator) orelse return null;
    defer allocator.free(home);
    return switch (app) {
        .claude_code => newestClaudeLog(allocator, home, cwd) catch null,
        .codex => newestCodexLog(allocator, home, cwd) catch null,
        else => null,
    };
}

/// Claude Code keeps `~/.claude/projects/<cwd with every non-alphanumeric byte
/// replaced by '-'>/<session>.jsonl`.
pub fn claudeProjectDirName(cwd: []const u8, out: []u8) []const u8 {
    const n = @min(cwd.len, out.len);
    for (cwd[0..n], 0..) |c, i| out[i] = if (std.ascii.isAlphanumeric(c)) c else '-';
    return out[0..n];
}

fn newestClaudeLog(allocator: std.mem.Allocator, home: []const u8, cwd: []const u8) !?[]u8 {
    var name_buf: [512]u8 = undefined;
    const dir_path = try std.fs.path.join(allocator, &.{ home, ".claude", "projects", claudeProjectDirName(cwd, &name_buf) });
    defer allocator.free(dir_path);
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return null;
    defer dir.close();

    var best_name: ?[]u8 = null;
    var best_mtime: i128 = 0;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        const stat = dir.statFile(entry.name) catch continue;
        if (best_name != null and stat.mtime <= best_mtime) continue;
        if (best_name) |old| allocator.free(old);
        best_name = try allocator.dupe(u8, entry.name);
        best_mtime = stat.mtime;
    }
    const name = best_name orelse return null;
    defer allocator.free(name);
    return try std.fs.path.join(allocator, &.{ dir_path, name });
}

const Candidate = struct { path: []u8, mtime: i128 };

/// Codex keeps `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`; the first line
/// (`session_meta`) carries the cwd. Newest few files are checked, newest first.
/// ponytail: full walk every LOOKUP_INTERVAL_MS on the UI thread; restrict to the
/// newest day directories if a huge sessions tree ever makes this noticeable.
fn newestCodexLog(allocator: std.mem.Allocator, home: []const u8, cwd: []const u8) !?[]u8 {
    const root = try std.fs.path.join(allocator, &.{ home, ".codex", "sessions" });
    defer allocator.free(root);
    var dir = std.fs.openDirAbsolute(root, .{ .iterate = true }) catch return null;
    defer dir.close();

    var top: std.ArrayListUnmanaged(Candidate) = .empty;
    defer {
        for (top.items) |c| allocator.free(c.path);
        top.deinit(allocator);
    }
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".jsonl")) continue;
        const stat = entry.dir.statFile(entry.basename) catch continue;
        if (top.items.len == CODEX_CANDIDATES and stat.mtime <= top.items[top.items.len - 1].mtime) continue;
        const path = try std.fs.path.join(allocator, &.{ root, entry.path });
        var i: usize = top.items.len;
        while (i > 0 and top.items[i - 1].mtime < stat.mtime) i -= 1;
        try top.insert(allocator, i, .{ .path = path, .mtime = stat.mtime });
        if (top.items.len > CODEX_CANDIDATES) allocator.free(top.pop().?.path);
    }

    for (top.items) |c| {
        if (try codexLogMatchesCwd(allocator, c.path, cwd)) return try allocator.dupe(u8, c.path);
    }
    return null;
}

fn codexLogMatchesCwd(allocator: std.mem.Allocator, path: []const u8, cwd: []const u8) !bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    defer file.close();
    var buf: [8192]u8 = undefined;
    const n = file.readAll(&buf) catch return false;
    const first = std.mem.sliceTo(buf[0..n], '\n');
    const meta = try codex.parseMetadata(allocator, path, first);
    defer codex.freeMetadata(allocator, meta);
    return std.mem.eql(u8, meta.project_dir, cwd);
}

// ---------------------------------------------------------------------------
// Pending prompt (approval menu) from the live screen
// ---------------------------------------------------------------------------

const WireOption = struct { n: u8, label: []const u8, highlighted: bool };
const WirePrompt = struct { text: []const u8, options: []const WireOption, confirmEnter: bool, inlineYesNo: bool };

/// JSON for the approval/question menu currently on screen, or null when the
/// screen shows neither numbered options nor an inline y/n prompt.
pub fn allocPromptJson(allocator: std.mem.Allocator, screen: []const u8) !?[]u8 {
    var opts: [9]prompt_answer.Option = undefined;
    const count = prompt_answer.parsePromptOptions(screen, &opts);
    const inline_yn = count == 0 and prompt_answer.hasInlineYesNo(screen);
    if (count == 0 and !inline_yn) return null;

    var wire: [9]WireOption = undefined;
    for (opts[0..count], 0..) |o, i| wire[i] = .{ .n = o.number, .label = o.label, .highlighted = o.highlighted };

    const text = try promptText(allocator, screen);
    defer allocator.free(text);
    const doc: WirePrompt = .{
        .text = text,
        .options = wire[0..count],
        .confirmEnter = prompt_answer.containsIgnoreCase(screen, "press enter to confirm"),
        .inlineYesNo = inline_yn,
    };
    return try std.json.Stringify.valueAlloc(allocator, doc, .{});
}

/// Up to 8 non-empty lines above the first option (or the last lines of the
/// screen for an inline prompt), box-drawing borders stripped.
fn promptText(allocator: std.mem.Allocator, screen: []const u8) ![]u8 {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer lines.deinit(allocator);
    var one: [1]prompt_answer.Option = undefined;
    var it = std.mem.splitScalar(u8, screen, '\n');
    while (it.next()) |line| {
        if (prompt_answer.parsePromptOptions(line, &one) == 1) break;
        try lines.append(allocator, line);
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var kept: usize = 0;
    var idx = lines.items.len;
    var pieces: [8][]const u8 = undefined;
    while (idx > 0 and kept < pieces.len) {
        idx -= 1;
        const clean = prompt_answer.stripBorder(lines.items[idx]);
        if (clean.len == 0) {
            if (kept > 0) break; // paragraph boundary above the menu
            continue;
        }
        pieces[kept] = clean;
        kept += 1;
    }
    while (kept > 0) {
        kept -= 1;
        try out.appendSlice(allocator, pieces[kept]);
        if (kept > 0) try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------

test "live transcript renders the tail of a transcript as JSON" {
    const allocator = std.testing.allocator;
    var messages: [MAX_MESSAGES + 2]types.TranscriptMessage = undefined;
    for (&messages, 0..) |*m, i| m.* = .{ .role = if (i % 2 == 0) .user else .assistant, .content = "hi", .timestamp_ms = @intCast(i) };
    messages[messages.len - 1] = .{ .role = .tool, .kind = .tool_result, .content = "ls output", .timestamp_ms = 99 };
    const json = try renderMessages(allocator, "claude", "/tmp/x.jsonl", &messages);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"provider\":\"claude\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"total\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"tool_result\",\"text\":\"ls output\",\"ts\":99") != null);
    // Only the last MAX_MESSAGES survive: ts 0 and 1 are gone.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ts\":1}") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ts\":2}") != null);
}

test "live transcript truncates text at a UTF-8 boundary" {
    try std.testing.expectEqualStrings("ab", truncateUtf8("ab中", 3));
    try std.testing.expectEqualStrings("ab中", truncateUtf8("ab中", 5));
}

test "live transcript maps a cwd to the Claude Code project dir" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("-Users-me-Code-wispterm-ios", claudeProjectDirName("/Users/me/Code/wispterm-ios", &buf));
    try std.testing.expectEqualStrings("-home-me--config", claudeProjectDirName("/home/me/.config", &buf));
}

test "live transcript finds the newest Claude Code log for a cwd" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath(".claude/projects/-work-app");
    try tmp.dir.writeFile(.{ .sub_path = ".claude/projects/-work-app/old.jsonl", .data = "{}\n" });
    try tmp.dir.writeFile(.{ .sub_path = ".claude/projects/-work-app/new.jsonl", .data = "{}\n" });
    const home = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(home);
    // Make `new` strictly newer regardless of filesystem timestamp granularity.
    const new_path = try std.fs.path.join(allocator, &.{ home, ".claude/projects/-work-app/new.jsonl" });
    defer allocator.free(new_path);
    const f = try std.fs.openFileAbsolute(new_path, .{ .mode = .read_write });
    defer f.close();
    const st = try f.stat();
    try f.updateTimes(st.atime, st.mtime + 5 * std.time.ns_per_s);

    const found = (try newestClaudeLog(allocator, home, "/work/app")) orelse return error.TestExpectedEqual;
    defer allocator.free(found);
    try std.testing.expect(std.mem.endsWith(u8, found, "new.jsonl"));
    try std.testing.expect((try newestClaudeLog(allocator, home, "/elsewhere")) == null);
}

test "live transcript finds the Codex log whose session_meta cwd matches" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath(".codex/sessions/2026/11/01");
    try tmp.dir.writeFile(.{
        .sub_path = ".codex/sessions/2026/11/01/rollout-a.jsonl",
        .data = "{\"timestamp\":\"2026-11-01T00:00:00.000Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"a\",\"cwd\":\"/work/app\"}}\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = ".codex/sessions/2026/11/01/rollout-b.jsonl",
        .data = "{\"timestamp\":\"2026-11-01T00:00:00.000Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"b\",\"cwd\":\"/other\"}}\n",
    });
    const home = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(home);
    const found = (try newestCodexLog(allocator, home, "/work/app")) orelse return error.TestExpectedEqual;
    defer allocator.free(found);
    try std.testing.expect(std.mem.endsWith(u8, found, "rollout-a.jsonl"));
    try std.testing.expect((try newestCodexLog(allocator, home, "/nowhere")) == null);
}

test "live transcript refresh re-renders only when the file changes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "s.jsonl", .data = "{\"sessionId\":\"s\",\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"first\"}}\n" });
    const path = try tmp.dir.realpathAlloc(allocator, "s.jsonl");
    defer allocator.free(path);

    var live: LiveTranscript = .{};
    defer live.deinit(allocator);
    live.setPath(allocator, path);
    const a = live.refresh(allocator, .claude_code, null) orelse return error.TestExpectedEqual;
    try std.testing.expect(std.mem.indexOf(u8, a, "\"text\":\"first\"") != null);
    const again = live.refresh(allocator, .claude_code, null) orelse return error.TestExpectedEqual;
    try std.testing.expect(again.ptr == a.ptr); // cached, no re-parse

    const f = try tmp.dir.openFile("s.jsonl", .{ .mode = .read_write });
    defer f.close();
    try f.seekFromEnd(0);
    try f.writeAll("{\"sessionId\":\"s\",\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"second\"}]}}\n");
    // Within RENDER_INTERVAL_MS the change is deliberately not re-rendered yet.
    const throttled = live.refresh(allocator, .claude_code, null) orelse return error.TestExpectedEqual;
    try std.testing.expect(throttled.ptr == a.ptr);
    live.next_render_ms = 0;
    const b = live.refresh(allocator, .claude_code, null) orelse return error.TestExpectedEqual;
    try std.testing.expect(std.mem.indexOf(u8, b, "\"text\":\"second\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, b, "\"total\":2") != null);
}

test "live transcript prompt json carries options, context and confirm flag" {
    const allocator = std.testing.allocator;
    const screen =
        \\╭──────────────────────────────────────╮
        \\│ Bash command                         │
        \\│   rm -rf build                       │
        \\│                                      │
        \\│ Do you want to proceed?              │
        \\│ ❯ 1. Yes                             │
        \\│   2. Yes, and don't ask again        │
        \\│   3. No, and tell Claude what to do  │
        \\╰──────────────────────────────────────╯
    ;
    const json = (try allocPromptJson(allocator, screen)) orelse return error.TestExpectedEqual;
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"text\":\"Do you want to proceed?\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "{\"n\":1,\"label\":\"Yes\",\"highlighted\":true}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"n\":3,\"label\":\"No, and tell Claude what to do\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"confirmEnter\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"inlineYesNo\":false") != null);

    const codex_screen = "Would you like to run it?\n> 1. Yes, proceed (y)\n  2. No (esc)\nPress enter to confirm or esc to cancel";
    const cj = (try allocPromptJson(allocator, codex_screen)) orelse return error.TestExpectedEqual;
    defer allocator.free(cj);
    try std.testing.expect(std.mem.indexOf(u8, cj, "\"confirmEnter\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, cj, "\"text\":\"Would you like to run it?\"") != null);

    try std.testing.expect((try allocPromptJson(allocator, "$ ls\nREADME.md\n")) == null);
}
