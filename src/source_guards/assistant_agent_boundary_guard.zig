//! Assistant/agent boundary guard. These feature/domain folders must not reach
//! up into AppWindow, and agent tool runtime must not depend on ai_chat.

const std = @import("std");

const max_source_bytes = 16 * 1024 * 1024;

fn hasImportTo(source: []const u8, target_file: []const u8) bool {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "@import(\"") != null and
            std.mem.indexOf(u8, line, target_file) != null)
        {
            return true;
        }
    }
    return false;
}

fn checkTreeNoImports(
    allocator: std.mem.Allocator,
    root: []const u8,
    forbidden: []const []const u8,
) !bool {
    var src_dir = try std.fs.cwd().openDir("src", .{ .iterate = true });
    defer src_dir.close();

    var ok = true;
    var walker = try src_dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.path, root)) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        const source = try src_dir.readFileAlloc(allocator, entry.path, max_source_bytes);
        defer allocator.free(source);

        for (forbidden) |target| {
            if (hasImportTo(source, target)) {
                std.debug.print(
                    "assistant_agent_boundary_guard: src/{s} must not import {s}\n",
                    .{ entry.path, target },
                );
                ok = false;
            }
        }
    }
    return ok;
}

fn sourceHasAny(source: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.mem.indexOf(u8, source, needle) != null) return true;
    }
    return false;
}

test "assistant and agent domains do not import AppWindow" {
    const forbidden = [_][]const u8{"AppWindow.zig"};
    const allocator = std.testing.allocator;
    var ok = true;
    ok = (try checkTreeNoImports(allocator, "assistant/conversation/", &forbidden)) and ok;
    ok = (try checkTreeNoImports(allocator, "assistant/sidebar/", &forbidden)) and ok;
    ok = (try checkTreeNoImports(allocator, "agent/", &forbidden)) and ok;
    ok = (try checkTreeNoImports(allocator, "agent_tools/", &forbidden)) and ok;
    try std.testing.expect(ok);
}

test "agent tools do not import ai_chat session" {
    const forbidden = [_][]const u8{"ai_chat.zig"};
    try std.testing.expect(try checkTreeNoImports(std.testing.allocator, "agent_tools/", &forbidden));
}

test "assistant input target lookup does not touch Session input internals" {
    const source = @embedFile("../input/assistant_conversation.zig");
    const forbidden = [_][]const u8{
        "input_buf",
        "input_len",
        "input_cursor",
    };
    try std.testing.expect(!sourceHasAny(source, &forbidden));
}

test "assistant agent boundary matcher detects import lines only" {
    try std.testing.expect(hasImportTo("const AppWindow = @import(\"../AppWindow.zig\");", "AppWindow.zig"));
    try std.testing.expect(!hasImportTo("// AppWindow.zig can be mentioned in prose", "AppWindow.zig"));
}
