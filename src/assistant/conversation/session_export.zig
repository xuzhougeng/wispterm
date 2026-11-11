//! Text a conversation `Session` hands to the outside: clipboard text, the
//! Markdown export, and the remote-console snapshot.
//!
//! All of it is a read-only projection of the transcript under
//! `Session.mutex`. The selection state itself (begin / update / finish) stays
//! in session.zig with the rest of the UI state; this file only renders it.
const std = @import("std");
const ai_chat = @import("session.zig");
const ai_chat_input_text = @import("input_text.zig");
const ai_chat_markdown = @import("markdown.zig");
const session_question_select = @import("session_question_select.zig");
const markdown_text = @import("../../markdown_text.zig");
const input_key = @import("../../input/key.zig");

const Session = ai_chat.Session;
const Message = ai_chat.Message;
const MarkdownExportMode = ai_chat.MarkdownExportMode;

/// Byte budget for one remote-console snapshot.
const REMOTE_SNAPSHOT_MAX_BYTES: usize = 24 * 1024;

const clampUtf8Boundary = ai_chat_input_text.clampUtf8Boundary;
const appendClipboardSection = ai_chat_markdown.appendClipboardSection;
const appendMarkdownDocumentHeader = ai_chat_markdown.appendMarkdownDocumentHeader;
const appendMarkdownSection = ai_chat_markdown.appendMarkdownSection;
const appendMarkdownCodeSection = ai_chat_markdown.appendMarkdownCodeSection;
const appendMarkdownBody = ai_chat_markdown.appendMarkdownBody;

pub fn allocMarkdownExport(self: *Session, allocator: std.mem.Allocator, mode: MarkdownExportMode) ![]u8 {
    self.mutex.lock();
    defer self.mutex.unlock();
    return allocMarkdownExportLocked(self, allocator, mode);
}

pub fn allocClipboardText(self: *Session, allocator: std.mem.Allocator) ![]u8 {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.input_select_all and self.composer.len > 0) {
        return allocator.dupe(u8, self.input());
    }
    if (try session_question_select.allocTextLocked(self, allocator)) |selected| return selected;
    if (allocTranscriptSelectionTextLocked(self, allocator)) |selected| {
        return selected;
    } else |err| switch (err) {
        error.NoSelection => {},
        else => return err,
    }
    if (self.messages.items.len > 0) {
        return allocTranscriptClipboardTextLocked(self, allocator);
    }
    if (self.composer.len > 0) {
        return allocator.dupe(u8, self.input());
    }
    return allocator.dupe(u8, "");
}

pub fn allocRemoteSnapshot(self: *Session, allocator: std.mem.Allocator) ![]u8 {
    // Capture any pending approval under approval_mutex BEFORE taking
    // self.mutex (sequential locks, never nested — no reverse ordering
    // exists, so this cannot deadlock). A resolution racing the gap between
    // the two locks costs at most one extra Approval snapshot, which the
    // remote consumer's once-per-episode announcer already de-dupes.
    var cap_tool_buf: [64]u8 = undefined;
    var cap_cmd_buf: [1024]u8 = undefined;
    var cap_tool: []const u8 = "";
    var cap_command: []const u8 = "";
    {
        self.approval_mutex.lock();
        defer self.approval_mutex.unlock();
        if (self.approval_pending and !self.approval_resolved) {
            const tl = self.approval_tool_len;
            @memcpy(cap_tool_buf[0..tl], self.approval_tool_buf[0..tl]);
            cap_tool = cap_tool_buf[0..tl];
            const cl = self.approval_command_len;
            @memcpy(cap_cmd_buf[0..cl], self.approval_command_buf[0..cl]);
            cap_command = cap_cmd_buf[0..cl];
        }
    }

    // Capture any pending ask_user question the same way as the approval
    // above: under its own mutex, into an owned formatted blob, BEFORE taking
    // self.mutex. Numbered options are language-neutral; the WeChat layer adds
    // the Chinese wrapper when it pushes.
    var question_section: ?[]u8 = null;
    defer if (question_section) |qs| allocator.free(qs);
    {
        self.question_mutex.lock();
        defer self.question_mutex.unlock();
        if (self.question_pending and !self.question_resolved) {
            var qbuf: std.ArrayListUnmanaged(u8) = .empty;
            errdefer qbuf.deinit(allocator);
            try qbuf.appendSlice(allocator, self.question_text);
            for (self.question_options, 0..) |opt, i| {
                try qbuf.writer(allocator).print("\n{d}. {s}", .{ i + 1, opt.label });
                if (opt.description.len != 0) {
                    try qbuf.appendSlice(allocator, " — ");
                    try qbuf.appendSlice(allocator, opt.description);
                }
            }
            question_section = try qbuf.toOwnedSlice(allocator);
        }
    }

    self.mutex.lock();
    defer self.mutex.unlock();

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try appendLimitedSection(allocator, &out, "Model", self.model(), REMOTE_SNAPSHOT_MAX_BYTES);
    try appendLimitedSection(allocator, &out, "Status", self.status(), REMOTE_SNAPSHOT_MAX_BYTES);

    if (cap_tool.len != 0) {
        var approval_text: std.ArrayListUnmanaged(u8) = .empty;
        defer approval_text.deinit(allocator);
        try approval_text.appendSlice(allocator, cap_tool);
        if (cap_command.len != 0) {
            try approval_text.append(allocator, '\n');
            try approval_text.appendSlice(allocator, cap_command);
        }
        try appendLimitedSection(allocator, &out, "Approval", approval_text.items, REMOTE_SNAPSHOT_MAX_BYTES);
    }

    if (question_section) |qs| {
        try appendLimitedSection(allocator, &out, "Question", qs, REMOTE_SNAPSHOT_MAX_BYTES);
    }

    var sections: std.ArrayListUnmanaged(RemoteSnapshotSection) = .empty;
    defer sections.deinit(allocator);
    var tool_summaries: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (tool_summaries.items) |summary| allocator.free(summary);
        tool_summaries.deinit(allocator);
    }
    for (self.messages.items) |msg| {
        if (msg.role == .tool) {
            const summary = try allocRemoteToolSummary(allocator, msg);
            var summary_owned = true;
            errdefer if (summary_owned) allocator.free(summary);
            try sections.append(allocator, .{ .label = msg.role.label(), .text = summary, .priority = true });
            try tool_summaries.append(allocator, summary);
            summary_owned = false;
        } else {
            try sections.append(allocator, .{ .label = msg.role.label(), .text = msg.content, .priority = true });
        }
        // Reasoning and the usage footer are auxiliary: useful for the web
        // mirror, but the remote reply detector only needs the message bodies.
        // Mark them low-priority so a huge reasoning block can never evict the
        // latest assistant answer from the byte budget (issue #118).
        if (msg.reasoning) |reasoning| {
            if (reasoning.len > 0) try sections.append(allocator, .{ .label = "Reasoning", .text = reasoning, .priority = false });
        }
        if (msg.usage_footer) |footer| {
            if (footer.len > 0) try sections.append(allocator, .{ .label = "Usage", .text = footer, .priority = false });
        }
    }
    try appendRecentLimitedSections(allocator, &out, sections.items, REMOTE_SNAPSHOT_MAX_BYTES);
    if (out.items.len == 0) try out.appendSlice(allocator, "No messages yet.");
    return out.toOwnedSlice(allocator);
}

pub fn allocMessageClipboardText(self: *Session, allocator: std.mem.Allocator, message_index: usize) ![]u8 {
    self.mutex.lock();
    defer self.mutex.unlock();
    if (message_index >= self.messages.items.len) return allocator.dupe(u8, "");
    return allocator.dupe(u8, self.messages.items[message_index].content);
}

/// Copy a byte sub-range of a message's raw content — a single code block or
/// table the renderer located for its per-block copy button. Bounds are
/// clamped so a range stale from a streaming edit can never read OOB.
pub fn allocMessageSpanText(self: *Session, allocator: std.mem.Allocator, message_index: usize, start: usize, end: usize) ![]u8 {
    self.mutex.lock();
    defer self.mutex.unlock();
    if (message_index >= self.messages.items.len) return allocator.dupe(u8, "");
    const content = self.messages.items[message_index].content;
    const s = @min(start, content.len);
    const e = @min(end, content.len);
    if (e <= s) return allocator.dupe(u8, "");
    return allocator.dupe(u8, content[s..e]);
}

fn allocTranscriptClipboardTextLocked(self: *Session, allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (self.messages.items) |msg| {
        try appendClipboardSection(allocator, &out, msg.role.label(), msg.content);
        if (msg.reasoning) |reasoning| {
            if (reasoning.len > 0) try appendClipboardSection(allocator, &out, "Reasoning", reasoning);
        }
        if (msg.usage_footer) |footer| {
            if (footer.len > 0) try appendClipboardSection(allocator, &out, "Usage", footer);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn allocMarkdownExportLocked(self: *Session, allocator: std.mem.Allocator, mode: MarkdownExportMode) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try appendMarkdownDocumentHeader(allocator, &out, self.title(), self.model(), self.sessionId(), mode == .full);
    switch (mode) {
        .full => try appendFullMarkdownExportLocked(self, allocator, &out),
        .clean => try appendCleanMarkdownExportLocked(self, allocator, &out),
    }

    if (out.items.len == 0) try out.appendSlice(allocator, "# WispTerm Copilot\n\nNo messages yet.\n");
    return out.toOwnedSlice(allocator);
}

fn appendFullMarkdownExportLocked(self: *Session, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    if (self.messages.items.len == 0) {
        try out.appendSlice(allocator, "No messages yet.\n");
        return;
    }

    for (self.messages.items) |msg| {
        const heading = if (msg.role == .tool and msg.tool_name != null and msg.tool_name.?.len > 0)
            "Tool"
        else
            msg.role.label();
        try appendMarkdownSection(allocator, out, heading, msg.content);

        if (msg.reasoning) |reasoning| {
            if (reasoning.len > 0) try appendMarkdownCodeSection(allocator, out, "Thinking", reasoning);
        }
        if (msg.usage_footer) |footer| {
            if (footer.len > 0) try appendMarkdownCodeSection(allocator, out, "Usage", footer);
        }
    }
}

fn appendCleanMarkdownExportLocked(self: *Session, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    var user_count: usize = 0;
    for (self.messages.items) |msg| {
        if (msg.role == .user and msg.content.len > 0) user_count += 1;
    }

    try out.appendSlice(allocator, "## User Input\n\n");
    if (user_count == 0) {
        try out.appendSlice(allocator, "No user input yet.\n\n");
    } else {
        var seen: usize = 0;
        for (self.messages.items) |msg| {
            if (msg.role != .user or msg.content.len == 0) continue;
            if (user_count > 1) {
                try out.writer(allocator).print("### {d}\n\n", .{seen + 1});
            }
            try appendMarkdownBody(allocator, out, msg.content);
            seen += 1;
            try out.appendSlice(allocator, "\n");
        }
    }

    try out.appendSlice(allocator, "## Final Result\n\n");
    if (latestAssistantContent(self.messages.items)) |content| {
        try appendMarkdownBody(allocator, out, content);
        try out.append(allocator, '\n');
    } else {
        try out.appendSlice(allocator, "No assistant result yet.\n");
    }
}

fn allocTranscriptSelectionTextLocked(self: *Session, allocator: std.mem.Allocator) (error{NoSelection} || std.mem.Allocator.Error)![]u8 {
    const selection = self.transcript_selection orelse return error.NoSelection;
    const range = selection.range() orelse return error.NoSelection;
    if (selection.message_index >= self.messages.items.len) return error.NoSelection;
    const msg = self.messages.items[selection.message_index];
    if (msg.role != .assistant) return error.NoSelection;
    const display = try markdown_text.allocDisplayText(allocator, msg.content);
    defer allocator.free(display);
    const start = clampUtf8Boundary(display, @min(range.start, display.len));
    const end = clampUtf8Boundary(display, @min(range.end, display.len));
    if (start >= end) return error.NoSelection;
    return allocator.dupe(u8, display[start..end]);
}

fn latestAssistantContent(messages: []const Message) ?[]const u8 {
    var i = messages.len;
    while (i > 0) {
        i -= 1;
        const msg = messages[i];
        if (msg.role == .assistant and msg.content.len > 0) return msg.content;
    }
    return null;
}

fn appendLimitedSection(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    label: []const u8,
    text: []const u8,
    max_bytes: usize,
) !void {
    if (out.items.len >= max_bytes) return;
    if (out.items.len > 0) try out.appendSlice(allocator, "\r\n\r\n");
    try out.appendSlice(allocator, label);
    try out.appendSlice(allocator, ":\r\n");
    if (out.items.len >= max_bytes) return;

    const remaining = max_bytes - out.items.len;
    const take = @min(text.len, remaining);
    try out.appendSlice(allocator, text[0..take]);
    if (take < text.len and out.items.len + 18 <= max_bytes) {
        try out.appendSlice(allocator, "\r\n...[truncated]");
    }
}

const RemoteSnapshotSection = struct {
    label: []const u8,
    text: []const u8,
    /// High-priority sections (message bodies) are budgeted before low-priority
    /// auxiliary sections (reasoning, usage), so bulky reasoning can never push
    /// the latest answer out of the snapshot.
    priority: bool = true,
};

/// Appends the most recent sections that fit in `max_bytes`, in two priority
/// passes. Pass one reserves budget for message bodies newest-first, always
/// keeping the newest body (truncated if it alone overflows). Pass two fills any
/// remaining budget with auxiliary sections (reasoning/usage), also newest-first.
/// Sections are emitted in their original order. This guarantees the latest
/// assistant answer survives even when an earlier-walked reasoning block is huge.
fn appendRecentLimitedSections(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    sections: []const RemoteSnapshotSection,
    max_bytes: usize,
) !void {
    if (sections.len == 0 or out.items.len >= max_bytes) return;

    const included = try allocator.alloc(bool, sections.len);
    defer allocator.free(included);
    @memset(included, false);

    // Model + Status are always emitted first, so every section here pays the
    // 4-byte separator; the per-section cost is therefore position-independent.
    var used = out.items.len;

    // Pass 1: message bodies, newest-first. Always include the newest body so
    // the reply detector and the user can always see the latest answer; if it
    // alone overflows, appendLimitedSection truncates it.
    var newest_body_seen = false;
    var i = sections.len;
    while (i > 0) : (i -= 1) {
        const section = sections[i - 1];
        if (!section.priority) continue;
        const cost = remoteSnapshotSectionCost(section.label, section.text);
        if (!newest_body_seen) {
            included[i - 1] = true;
            used = @min(used + cost, max_bytes);
            newest_body_seen = true;
        } else if (used + cost <= max_bytes) {
            included[i - 1] = true;
            used += cost;
        }
    }

    // Pass 2: auxiliary sections (reasoning/usage), newest-first, best effort.
    i = sections.len;
    while (i > 0) : (i -= 1) {
        const section = sections[i - 1];
        if (section.priority) continue;
        const cost = remoteSnapshotSectionCost(section.label, section.text);
        if (used + cost <= max_bytes) {
            included[i - 1] = true;
            used += cost;
        }
    }

    for (sections, 0..) |section, idx| {
        if (included[idx]) try appendLimitedSection(allocator, out, section.label, section.text, max_bytes);
    }
}

fn remoteSnapshotSectionCost(label: []const u8, text: []const u8) usize {
    return "\r\n\r\n".len + label.len + ":\r\n".len + text.len;
}

fn allocRemoteToolSummary(allocator: std.mem.Allocator, msg: Message) ![]u8 {
    if (msg.tool_name) |name| {
        if (name.len > 0) {
            return std.fmt.allocPrint(allocator, "{s} completed. Output omitted in remote chat.", .{name});
        }
    }

    const trimmed = std.mem.trim(u8, msg.content, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > 160) {
        return allocator.dupe(u8, "Tool activity. Output omitted in remote chat.");
    }
    return allocator.dupe(u8, trimmed);
}

test "ai chat remote snapshot omits local draft input" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator,
        "DeepSeek",
        ai_chat.DEFAULT_BASE_URL,
        "key",
        ai_chat.DEFAULT_MODEL,
        ai_chat.DEFAULT_SYSTEM_PROMPT,
        ai_chat.DEFAULT_THINKING,
        ai_chat.DEFAULT_REASONING_EFFORT,
        ai_chat.DEFAULT_STREAM,
        ai_chat.DEFAULT_AGENT,
    );
    defer session.deinit();

    session.appendInputText("local draft only");
    const snapshot = try session.allocRemoteSnapshot(allocator);
    defer allocator.free(snapshot);

    try std.testing.expect(std.mem.indexOf(u8, snapshot, "local draft only") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Draft") == null);
}

test "ai chat remote snapshot keeps latest messages after large tool output" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator,
        "DeepSeek",
        ai_chat.DEFAULT_BASE_URL,
        "key",
        ai_chat.DEFAULT_MODEL,
        ai_chat.DEFAULT_SYSTEM_PROMPT,
        ai_chat.DEFAULT_THINKING,
        ai_chat.DEFAULT_REASONING_EFFORT,
        ai_chat.DEFAULT_STREAM,
        ai_chat.DEFAULT_AGENT,
    );
    defer session.deinit();

    const large_tool_output = try allocator.alloc(u8, REMOTE_SNAPSHOT_MAX_BYTES + 1024);
    @memset(large_tool_output, 'x');
    try session.messages.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "latest user message"),
    });
    try session.messages.append(allocator, .{
        .role = .tool,
        .content = large_tool_output,
        .tool_name = try allocator.dupe(u8, "terminal_repl_exec"),
    });
    try session.messages.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "latest assistant reply"),
    });

    const snapshot = try session.allocRemoteSnapshot(allocator);
    defer allocator.free(snapshot);

    try std.testing.expect(std.mem.indexOf(u8, snapshot, "latest user message") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "latest assistant reply") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "terminal_repl_exec") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx") == null);
}

test "ai chat remote snapshot keeps final answer when reasoning is huge (issue 118)" {
    // A reasoning-heavy turn (e.g. GLM thinking) on a large context once evicted
    // the final assistant answer from the byte budget, so the weixin reply
    // detector never saw the answer and never reported the turn done.
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }
    session.setStatusLocked("Done in 280.9s");

    const big_reasoning = try allocator.alloc(u8, REMOTE_SNAPSHOT_MAX_BYTES + 4096);
    @memset(big_reasoning, 'r');
    try session.messages.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "explain the captain model"),
    });
    try session.messages.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "FINAL_ANSWER_MARKER the captain model is ..."),
        .reasoning = big_reasoning,
    });

    const snapshot = try session.allocRemoteSnapshot(allocator);
    defer allocator.free(snapshot);

    // The answer body survives; the oversized reasoning is dropped, not the answer.
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "FINAL_ANSWER_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Done in 280.9s") != null);
}

test "ai chat remote snapshot still includes reasoning when it fits" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }

    try session.messages.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "status?"),
    });
    try session.messages.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "all good"),
        .reasoning = try allocator.dupe(u8, "checked the state first"),
    });

    const snapshot = try session.allocRemoteSnapshot(allocator);
    defer allocator.free(snapshot);

    try std.testing.expect(std.mem.indexOf(u8, snapshot, "all good") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "checked the state first") != null);
}

test "ai chat remote snapshot includes a pending approval section" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }
    try session.messages.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "clean up"),
    });

    const tool = "terminal_repl_exec";
    const command = "rm -rf /tmp/x";
    @memcpy(session.approval_tool_buf[0..tool.len], tool);
    session.approval_tool_len = tool.len;
    @memcpy(session.approval_command_buf[0..command.len], command);
    session.approval_command_len = command.len;
    session.approval_pending = true;
    session.approval_resolved = false;

    const with = try session.allocRemoteSnapshot(allocator);
    defer allocator.free(with);
    try std.testing.expect(std.mem.indexOf(u8, with, "Approval:") != null);
    try std.testing.expect(std.mem.indexOf(u8, with, "terminal_repl_exec") != null);
    try std.testing.expect(std.mem.indexOf(u8, with, "rm -rf /tmp/x") != null);

    // Once resolved, the section disappears.
    try std.testing.expect(session.resolveApprovalExternal(true));
    const without = try session.allocRemoteSnapshot(allocator);
    defer allocator.free(without);
    try std.testing.expect(std.mem.indexOf(u8, without, "Approval:") == null);
}

test "ai chat remote snapshot approval section omits the command line when empty" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }

    const tool = "weather_lookup";
    @memcpy(session.approval_tool_buf[0..tool.len], tool);
    session.approval_tool_len = tool.len;
    session.approval_command_len = 0; // no command argument
    session.approval_pending = true;
    session.approval_resolved = false;

    const snapshot = try session.allocRemoteSnapshot(allocator);
    defer allocator.free(snapshot);
    // The tool-only approval still emits a section naming the tool, with no
    // trailing command line (the `\n<command>` branch is skipped).
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Approval:\r\nweather_lookup") != null);
}

test "ai chat remote snapshot emits a Question section with numbered options" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }

    session.question_text = @constCast("Which database?");
    var opts = [_]ai_chat.QuestionOption{
        .{ .label = "Postgres", .description = "prod default" },
        .{ .label = "SQLite" },
    };
    session.question_options = &opts;
    session.question_pending = true;
    session.question_resolved = false;

    const with = try session.allocRemoteSnapshot(allocator);
    defer allocator.free(with);
    try std.testing.expect(std.mem.indexOf(u8, with, "Question:") != null);
    try std.testing.expect(std.mem.indexOf(u8, with, "Which database?") != null);
    try std.testing.expect(std.mem.indexOf(u8, with, "1. Postgres — prod default") != null);
    try std.testing.expect(std.mem.indexOf(u8, with, "2. SQLite") != null);

    // Once resolved, the section disappears.
    session.question_pending = false;
    const without = try session.allocRemoteSnapshot(allocator);
    defer allocator.free(without);
    try std.testing.expect(std.mem.indexOf(u8, without, "Question:") == null);
}

test "ai chat clipboard text exports transcript when input is empty" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }

    try session.messages.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "status?"),
        .reasoning = null,
    });
    try session.messages.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "ready"),
        .reasoning = try allocator.dupe(u8, "checked state"),
    });

    session.handleKey(.{ .key = input_key.Key.key_a, .ctrl = true });
    try std.testing.expect(session.transcript_select_all);

    const copied = try session.allocClipboardText(allocator);
    defer allocator.free(copied);
    try std.testing.expect(std.mem.indexOf(u8, copied, "You:\r\nstatus?") != null);
    try std.testing.expect(std.mem.indexOf(u8, copied, "AI:\r\nready") != null);
    try std.testing.expect(std.mem.indexOf(u8, copied, "Reasoning:\r\nchecked state") != null);
}

test "ai chat clipboard text prefers selected assistant answer range" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }

    try session.messages.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "alpha beta gamma"),
    });

    session.beginTranscriptSelection(0, 6);
    session.updateTranscriptSelection(0, 10);

    const copied = try session.allocClipboardText(allocator);
    defer allocator.free(copied);
    try std.testing.expectEqualStrings("beta", copied);

    session.clearSelection();
    try std.testing.expect(session.transcript_selection == null);
}

test "ai chat transcript selection clamps to utf8 boundaries" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }

    try session.messages.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "你好吗"),
    });

    session.beginTranscriptSelection(0, 1);
    session.updateTranscriptSelection(0, 8);

    const copied = try session.allocClipboardText(allocator);
    defer allocator.free(copied);
    try std.testing.expectEqualStrings("你好", copied);
}

test "ai chat transcript selection copies cleaned markdown text" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }

    try session.messages.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "**生成的完整 `Markdown`**"),
    });

    // Display text is "生成的完整 Markdown\n"; select the whole visible run.
    session.beginTranscriptSelection(0, 0);
    session.updateTranscriptSelection(0, "生成的完整 Markdown".len);

    const copied = try session.allocClipboardText(allocator);
    defer allocator.free(copied);
    try std.testing.expectEqualStrings("生成的完整 Markdown", copied);
}

test "ai chat transcript selection over table is not truncated to raw length" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }

    try session.messages.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "a|b|c\n-|-|-\nd|e|f"),
    });

    // Raw content is 17 bytes; the cleaned display text
    // "a | b | c\nd | e | f\n" is 20 bytes (borderless table: each '|' → " | ").
    // Selecting the whole thing must not truncate the selection to the raw length.
    session.beginTranscriptSelection(0, 0);
    session.updateTranscriptSelection(0, 20);

    const copied = try session.allocClipboardText(allocator);
    defer allocator.free(copied);
    try std.testing.expectEqualStrings("a | b | c\nd | e | f\n", copied);
}

test "ai chat message clipboard exports one bubble" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }

    try session.messages.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "first"),
        .reasoning = null,
    });
    try session.messages.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "second"),
        .reasoning = try allocator.dupe(u8, "not part of the bubble"),
    });

    const copied = try session.allocMessageClipboardText(allocator, 1);
    defer allocator.free(copied);
    try std.testing.expectEqualStrings("second", copied);
}

test "ai chat Markdown export includes full transcript details" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }
    session.setTitle("Chat Export");
    session.copyModel("model-x");
    session.copySessionId("session-export");

    try session.messages.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "status?"),
    });
    try session.messages.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "ready"),
        .reasoning = try allocator.dupe(u8, "checked state"),
        .usage_footer = try allocator.dupe(u8, "total 3"),
    });

    const markdown = try session.allocMarkdownExport(allocator, .full);
    defer allocator.free(markdown);

    try std.testing.expect(std.mem.indexOf(u8, markdown, "# Chat Export") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "## You\n\nstatus?") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "## AI\n\nready") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "## Thinking") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "checked state") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "## Usage") != null);
}

test "ai chat clean Markdown export keeps user inputs and final answer only" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }
    session.setTitle("Clean Export");
    session.copyModel("model-hidden");
    session.copySessionId("session-hidden");

    try session.messages.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "first prompt"),
    });
    try session.messages.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "intermediate answer"),
        .reasoning = try allocator.dupe(u8, "hidden thinking"),
    });
    try session.messages.append(allocator, .{
        .role = .tool,
        .content = try allocator.dupe(u8, "tool output"),
    });
    try session.messages.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "second prompt"),
    });
    try session.messages.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "final answer"),
        .usage_footer = try allocator.dupe(u8, "total 9"),
    });

    const markdown = try session.allocMarkdownExport(allocator, .clean);
    defer allocator.free(markdown);

    try std.testing.expect(std.mem.indexOf(u8, markdown, "first prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "second prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "final answer") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "intermediate answer") == null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "hidden thinking") == null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "tool output") == null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "total 9") == null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "model-hidden") == null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "session-hidden") == null);
}
