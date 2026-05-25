//! AI-reply progress detection by diffing the rendered AI chat transcript
//! against a baseline. Port of poller.ts aiReplyProgress + parseAiSections.
const std = @import("std");

pub const Progress = struct { done: bool = false, text: []const u8 = "" };

const Role = enum { metadata, user, assistant, tool, reasoning };
const Section = struct { role: Role, label: []const u8, content: []const u8 };

const MAX_SECTIONS = 256;

/// Compares baseline vs current transcript. `text` borrows from `current`
/// (or from a static literal for the in-progress messages).
pub fn progress(baseline: []const u8, current: []const u8) Progress {
    var base_buf: [MAX_SECTIONS]Section = undefined;
    var cur_buf: [MAX_SECTIONS]Section = undefined;
    var base_msg_buf: [MAX_SECTIONS]Section = undefined;
    var cur_msg_buf: [MAX_SECTIONS]Section = undefined;

    const base_sections = parseSections(baseline, &base_buf);
    const cur_sections = parseSections(current, &cur_buf);
    const base_msgs = filterMessages(base_sections, &base_msg_buf);
    const cur_msgs = filterMessages(cur_sections, &cur_msg_buf);
    const new_msgs = afterBaseline(base_msgs, cur_msgs);
    const status = latestStatus(cur_sections);

    var last_assistant: ?[]const u8 = null;
    for (new_msgs) |m| {
        if (m.role == .assistant and trim(m.content).len != 0) last_assistant = trim(m.content);
    }

    if (last_assistant) |content| {
        if (!isActiveStatus(status)) return .{ .done = true, .text = content };
    }
    if (containsIgnoreCase(status, "running tools") or hasRole(new_msgs, .tool)) {
        return .{ .done = false, .text = "还在处理中，工具调用仍在执行。" };
    }
    if (new_msgs.len != 0 or last_assistant != null) {
        return .{ .done = false, .text = "还在处理中，等待 AI 回复。" };
    }
    return .{ .done = false, .text = "" };
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

/// A section starts at a line that is exactly a known label followed by ':'.
/// Content is every following line until the next label (whitespace-trimmed).
fn parseSections(transcript: []const u8, buf: []Section) []Section {
    var count: usize = 0;
    var pos: usize = 0;
    var cur_role: ?Role = null;
    var cur_label: []const u8 = "";
    var content_start: usize = 0;
    var content_end: usize = 0;

    while (pos <= transcript.len) {
        const nl = std.mem.indexOfScalarPos(u8, transcript, pos, '\n') orelse transcript.len;
        const line = transcript[pos..nl];
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (asLabel(trimmed)) |role| {
            if (cur_role) |r| {
                if (count < buf.len) {
                    buf[count] = .{ .role = r, .label = cur_label, .content = trim(transcript[content_start..content_end]) };
                    count += 1;
                }
            }
            cur_role = role;
            cur_label = trimmed[0 .. trimmed.len - 1]; // strip trailing ':'
            content_start = if (nl < transcript.len) nl + 1 else transcript.len;
            content_end = content_start;
        } else if (cur_role != null) {
            content_end = nl;
        }
        if (nl == transcript.len) break;
        pos = nl + 1;
    }
    if (cur_role) |r| {
        if (count < buf.len) {
            buf[count] = .{ .role = r, .label = cur_label, .content = trim(transcript[content_start..content_end]) };
            count += 1;
        }
    }
    return buf[0..count];
}

fn asLabel(line: []const u8) ?Role {
    if (line.len < 2 or line[line.len - 1] != ':') return null;
    const name = line[0 .. line.len - 1];
    if (eq(name, "You") or eq(name, "User")) return .user;
    if (eq(name, "AI") or eq(name, "Assistant")) return .assistant;
    if (eq(name, "Tool")) return .tool;
    if (eq(name, "Reasoning")) return .reasoning;
    if (eq(name, "Model") or eq(name, "Status")) return .metadata;
    return null;
}

fn filterMessages(sections: []const Section, out: []Section) []Section {
    var n: usize = 0;
    for (sections) |s| {
        if (s.role == .user or s.role == .assistant or s.role == .tool) {
            if (n >= out.len) break;
            out[n] = s;
            n += 1;
        }
    }
    return out[0..n];
}

/// Returns the suffix of `current` that does not overlap the tail of `baseline`.
fn afterBaseline(baseline: []const Section, current: []const Section) []const Section {
    if (baseline.len == 0) return current;
    if (current.len == 0) return current[0..0];
    const max_overlap = @min(baseline.len, current.len);
    var overlap = max_overlap;
    while (overlap > 0) : (overlap -= 1) {
        const base_start = baseline.len - overlap;
        var matched = true;
        var i: usize = 0;
        while (i < overlap) : (i += 1) {
            if (baseline[base_start + i].role != current[i].role or
                !std.mem.eql(u8, baseline[base_start + i].content, current[i].content))
            {
                matched = false;
                break;
            }
        }
        if (matched) return current[overlap..];
    }
    return current;
}

fn latestStatus(sections: []const Section) []const u8 {
    var i: usize = sections.len;
    while (i > 0) : (i -= 1) {
        if (eq(sections[i - 1].label, "Status")) return trim(sections[i - 1].content);
    }
    return "";
}

fn isActiveStatus(status: []const u8) bool {
    return containsIgnoreCase(status, "running tools") or containsIgnoreCase(status, "thinking") or
        containsIgnoreCase(status, "streaming") or containsIgnoreCase(status, "stopping");
}

fn hasRole(msgs: []const Section, role: Role) bool {
    for (msgs) |m| if (m.role == role) return true;
    return false;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

const t = std.testing;

test "done when a new assistant message exists and status is idle" {
    const baseline = "You:\nhi\n";
    const current = "You:\nhi\nAI:\nthere\nStatus:\nidle\n";
    const p = progress(baseline, current);
    try t.expect(p.done);
    try t.expectEqualStrings("there", p.text);
}

test "not done while tools are running" {
    const baseline = "You:\nhi\n";
    const current = "You:\nhi\nStatus:\nrunning tools\n";
    const p = progress(baseline, current);
    try t.expect(!p.done);
    try t.expect(p.text.len != 0);
}

test "empty when nothing new" {
    const p = progress("You:\nhi\n", "You:\nhi\n");
    try t.expect(!p.done);
}
