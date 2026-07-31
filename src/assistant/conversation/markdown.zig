//! Transcript → Markdown export helpers for the AI chat (document header,
//! sections, code fences, inline escaping). Operates on plain string slices
//! only — no Session or Message dependency, making this a true leaf module.
const std = @import("std");

pub fn appendClipboardSection(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    label: []const u8,
    text: []const u8,
) !void {
    if (out.items.len > 0) try out.appendSlice(allocator, "\r\n\r\n");
    try out.appendSlice(allocator, label);
    try out.appendSlice(allocator, ":\r\n");
    try out.appendSlice(allocator, text);
}

pub fn appendMarkdownDocumentHeader(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    title: []const u8,
    model: []const u8,
    session_id: []const u8,
    include_metadata: bool,
) !void {
    try out.appendSlice(allocator, "# ");
    try appendMarkdownInline(allocator, out, if (title.len > 0) title else "WispTerm Copilot");
    try out.appendSlice(allocator, "\n\n");
    if (!include_metadata) return;
    if (model.len > 0) {
        try out.appendSlice(allocator, "- Model: `");
        try appendMarkdownInline(allocator, out, model);
        try out.appendSlice(allocator, "`\n");
    }
    if (session_id.len > 0) {
        try out.appendSlice(allocator, "- Session: `");
        try appendMarkdownInline(allocator, out, session_id);
        try out.appendSlice(allocator, "`\n");
    }
    try out.appendSlice(allocator, "\n");
}

pub fn appendMarkdownSection(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    label: []const u8,
    text: []const u8,
) !void {
    try out.appendSlice(allocator, "## ");
    try appendMarkdownInline(allocator, out, label);
    try out.appendSlice(allocator, "\n\n");
    try appendMarkdownBody(allocator, out, text);
    try out.appendSlice(allocator, "\n\n");
}

pub fn appendMarkdownCodeSection(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    label: []const u8,
    text: []const u8,
) !void {
    try out.appendSlice(allocator, "## ");
    try appendMarkdownInline(allocator, out, label);
    try out.appendSlice(allocator, "\n\n");
    try appendMarkdownFence(allocator, out, text);
    try out.appendSlice(allocator, "\n");
}

fn appendMarkdownInline(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    text: []const u8,
) !void {
    var previous_space = false;
    for (text) |ch| {
        if (ch == '\r' or ch == '\n' or ch == '\t') {
            if (!previous_space) {
                try out.append(allocator, ' ');
                previous_space = true;
            }
            continue;
        }
        try out.append(allocator, ch);
        previous_space = ch == ' ';
    }
}

pub fn appendMarkdownBody(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    text: []const u8,
) !void {
    if (text.len == 0) {
        try out.appendSlice(allocator, "_(empty)_\n");
        return;
    }
    try out.appendSlice(allocator, text);
    if (text[text.len - 1] != '\n') try out.append(allocator, '\n');
}

fn appendMarkdownFence(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    text: []const u8,
) !void {
    const fence_len = @max(@as(usize, 3), longestBacktickRun(text) + 1);
    try appendRepeatedByte(allocator, out, '`', fence_len);
    try out.appendSlice(allocator, "text\n");
    try out.appendSlice(allocator, text);
    if (text.len == 0 or text[text.len - 1] != '\n') try out.append(allocator, '\n');
    try appendRepeatedByte(allocator, out, '`', fence_len);
    try out.appendSlice(allocator, "\n");
}

fn appendRepeatedByte(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    byte: u8,
    count: usize,
) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) try out.append(allocator, byte);
}

fn longestBacktickRun(text: []const u8) usize {
    var longest: usize = 0;
    var current: usize = 0;
    for (text) |ch| {
        if (ch == '`') {
            current += 1;
            longest = @max(longest, current);
        } else {
            current = 0;
        }
    }
    return longest;
}
