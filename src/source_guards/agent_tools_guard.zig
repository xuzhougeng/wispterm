//! Agent tool runtime ownership guard. The old `ai_chat_tools.zig` entrypoint
//! was removed without a compatibility wrapper; keep it gone and keep
//! `agent_tools/**` as a leaf that does not import AppWindow.

const std = @import("std");

fn containsOldRuntimePath(source: []const u8) bool {
    return std.mem.indexOf(u8, source, "@import(\"ai_chat_tools.zig\")") != null or
        std.mem.indexOf(u8, source, "ai_chat_tools.") != null;
}

fn containsPublicAgentToolsReexport(source: []const u8) bool {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "pub const ") and
            std.mem.indexOf(u8, line, "= @import(\"agent_tools/") != null)
        {
            return true;
        }
    }
    return false;
}

fn agentToolImportsAppWindow(path: []const u8, source: []const u8) bool {
    return std.mem.startsWith(u8, path, "agent_tools/") and
        std.mem.indexOf(u8, source, "AppWindow.zig") != null;
}

test "agent tools guard detects old runtime aliases" {
    try std.testing.expect(containsOldRuntimePath("const tools = @import(\"ai_chat_tools.zig\");"));
    try std.testing.expect(containsOldRuntimePath("return ai_chat_tools.executeToolCall(ctx, call);"));
    try std.testing.expect(!containsOldRuntimePath("const tools = @import(\"agent_tools/mod.zig\");"));
}

test "agent tools guard detects public reexports and AppWindow imports" {
    try std.testing.expect(containsPublicAgentToolsReexport("pub const tools = @import(\"agent_tools/mod.zig\");\n"));
    try std.testing.expect(!containsPublicAgentToolsReexport("const tools = @import(\"agent_tools/mod.zig\");\n"));
    try std.testing.expect(agentToolImportsAppWindow("agent_tools/mod.zig", "const AppWindow = @import(\"../AppWindow.zig\");"));
    try std.testing.expect(!agentToolImportsAppWindow("assistant/conversation/session.zig", "const AppWindow = @import(\"../../AppWindow.zig\");"));
}

test "active sources do not recreate old agent tool runtime paths" {
    const gpa = std.testing.allocator;
    var dir = std.fs.cwd().openDir("src", .{ .iterate = true }) catch return;
    defer dir.close();

    var offenders = std.ArrayList(u8).empty;
    defer offenders.deinit(gpa);

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (std.mem.eql(u8, entry.basename, "agent_tools_guard.zig")) continue;

        const source = try dir.readFileAlloc(gpa, entry.path, 16 * 1024 * 1024);
        defer gpa.free(source);

        if (containsOldRuntimePath(source)) {
            try offenders.writer(gpa).print(
                "  src/{s}: imports or references removed ai_chat_tools runtime path\n",
                .{entry.path},
            );
        }
        if (containsPublicAgentToolsReexport(source)) {
            try offenders.writer(gpa).print(
                "  src/{s}: reexports agent_tools through a public alias; import the real owner directly\n",
                .{entry.path},
            );
        }
        if (agentToolImportsAppWindow(entry.path, source)) {
            try offenders.writer(gpa).print(
                "  src/{s}: agent_tools must not import AppWindow.zig\n",
                .{entry.path},
            );
        }
    }

    if (offenders.items.len != 0) {
        std.debug.print(
            "\nagent_tools_guard: old runtime paths or layer violations found:\n{s}",
            .{offenders.items},
        );
        return error.AgentToolsRuntimePathRegression;
    }
}
