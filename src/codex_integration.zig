const std = @import("std");
const agent_detector = @import("agent_detector.zig");

const TAG = agent_detector.TAG;

const HookSpec = struct { event: []const u8, state: []const u8, matcher: ?[]const u8 };
const HOOKS = [_]HookSpec{
    .{ .event = "SessionStart", .state = "needs_input", .matcher = null },
    .{ .event = "UserPromptSubmit", .state = "running", .matcher = null },
    .{ .event = "PreToolUse", .state = "running", .matcher = "*" },
    .{ .event = "PermissionRequest", .state = "waiting_approval", .matcher = "*" },
    .{ .event = "PostToolUse", .state = "running", .matcher = "*" },
    .{ .event = "Stop", .state = "done", .matcher = null },
};

/// The POSIX shell command for one Codex hook. Hook stdout is consumed by Codex,
/// so write the marker to the controlling tty.
pub fn hookCommand(buf: []u8, state: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(
        buf,
        "printf '\\033]7748;{s};state={s};app=codex\\007' > /dev/tty 2>/dev/null || true",
        .{ TAG, state },
    ) catch null;
}

pub fn isInstalled(hooks_json: []const u8) bool {
    return std.mem.indexOf(u8, hooks_json, TAG) != null;
}

pub fn install(alloc: std.mem.Allocator, existing: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    const src = blk: {
        const trimmed = std.mem.trim(u8, existing, " \t\r\n");
        break :blk if (trimmed.len == 0) "{}" else trimmed;
    };

    var parsed = try std.json.parseFromSlice(std.json.Value, aa, src, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });

    if (parsed.value != .object) return error.InvalidHooksJson;
    var root = &parsed.value.object;

    const hooks_entry = try root.getOrPutValue("hooks", std.json.Value{ .object = std.json.ObjectMap.init(aa) });
    if (hooks_entry.value_ptr.* != .object) return error.InvalidHooksJson;
    var hooks_obj = &hooks_entry.value_ptr.*.object;

    for (&HOOKS) |spec| {
        const event_entry = try hooks_obj.getOrPutValue(spec.event, std.json.Value{ .array = std.json.Array.init(aa) });
        if (event_entry.value_ptr.* != .array) return error.InvalidHooksJson;
        const event_arr = &event_entry.value_ptr.*.array;

        const already = blk: {
            for (event_arr.items) |group| {
                if (group != .object) continue;
                const inner = group.object.get("hooks") orelse continue;
                if (inner != .array) continue;
                for (inner.array.items) |h| {
                    if (h != .object) continue;
                    const cmd = h.object.get("command") orelse continue;
                    if (cmd != .string) continue;
                    if (std.mem.indexOf(u8, cmd.string, TAG) != null) break :blk true;
                }
            }
            break :blk false;
        };
        if (already) continue;

        var cmd_buf: [256]u8 = undefined;
        const cmd = hookCommand(&cmd_buf, spec.state) orelse return error.CommandBufferTooSmall;
        const cmd_owned = try aa.dupe(u8, cmd);

        var h_obj = std.json.ObjectMap.init(aa);
        try h_obj.put("type", std.json.Value{ .string = "command" });
        try h_obj.put("command", std.json.Value{ .string = cmd_owned });

        var h_arr = std.json.Array.init(aa);
        try h_arr.append(std.json.Value{ .object = h_obj });

        var group_obj = std.json.ObjectMap.init(aa);
        if (spec.matcher) |m| {
            try group_obj.put("matcher", std.json.Value{ .string = m });
        }
        try group_obj.put("hooks", std.json.Value{ .array = h_arr });

        try event_arr.append(std.json.Value{ .object = group_obj });
    }

    return try std.json.Stringify.valueAlloc(alloc, parsed.value, .{ .whitespace = .indent_2 });
}

pub fn uninstall(alloc: std.mem.Allocator, existing: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    const src = blk: {
        const trimmed = std.mem.trim(u8, existing, " \t\r\n");
        break :blk if (trimmed.len == 0) "{}" else trimmed;
    };

    var parsed = try std.json.parseFromSlice(std.json.Value, aa, src, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });

    if (parsed.value != .object) return error.InvalidHooksJson;
    var root = &parsed.value.object;

    const hooks_val = root.getPtr("hooks") orelse {
        return try std.json.Stringify.valueAlloc(alloc, parsed.value, .{ .whitespace = .indent_2 });
    };
    if (hooks_val.* != .object) {
        return try std.json.Stringify.valueAlloc(alloc, parsed.value, .{ .whitespace = .indent_2 });
    }
    var hooks_obj = &hooks_val.*.object;

    for (&HOOKS) |spec| {
        const event_val = hooks_obj.getPtr(spec.event) orelse continue;
        if (event_val.* != .array) continue;
        const event_arr = &event_val.*.array;

        var kept = std.json.Array.init(aa);
        for (event_arr.items) |group| {
            const has_our_hook = blk: {
                if (group != .object) break :blk false;
                const inner = group.object.get("hooks") orelse break :blk false;
                if (inner != .array) break :blk false;
                for (inner.array.items) |h| {
                    if (h != .object) continue;
                    const cmd = h.object.get("command") orelse continue;
                    if (cmd != .string) continue;
                    if (std.mem.indexOf(u8, cmd.string, TAG) != null) break :blk true;
                }
                break :blk false;
            };
            if (!has_our_hook) {
                try kept.append(group);
            }
        }

        if (kept.items.len == 0) {
            _ = hooks_obj.orderedRemove(spec.event);
        } else {
            event_val.* = std.json.Value{ .array = kept };
        }
    }

    if (hooks_obj.count() == 0) {
        _ = root.orderedRemove("hooks");
    }

    return try std.json.Stringify.valueAlloc(alloc, parsed.value, .{ .whitespace = .indent_2 });
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, i, needle)) |p| : (i = p + needle.len) n += 1;
    return n;
}

test "hookCommand emits the marker for a Codex state" {
    var b: [200]u8 = undefined;
    const c = hookCommand(&b, "running").?;
    try std.testing.expect(std.mem.indexOf(u8, c, "7748;wispterm-agent;state=running;app=codex") != null);
    try std.testing.expect(std.mem.indexOf(u8, c, "/dev/tty") != null);
}

test "install adds Codex lifecycle hooks to empty hooks.json" {
    const out = try install(std.testing.allocator, "");
    defer std.testing.allocator.free(out);
    try std.testing.expect(isInstalled(out));
    inline for (.{ "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "Stop" }) |ev| {
        try std.testing.expect(std.mem.indexOf(u8, out, ev) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, out, "state=needs_input") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "state=waiting_approval") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "state=done") != null);
}

test "install is idempotent for Codex Stop hook" {
    const once = try install(std.testing.allocator, "");
    defer std.testing.allocator.free(once);
    const twice = try install(std.testing.allocator, once);
    defer std.testing.allocator.free(twice);
    try std.testing.expectEqual(@as(usize, 1), count(twice, "state=done"));
}

test "install preserves unrelated Codex hooks" {
    const existing =
        \\{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo keep-me"}]}]}}
    ;
    const out = try install(std.testing.allocator, existing);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "keep-me") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "state=done") != null);
}

test "uninstall removes only WispTerm Codex hooks" {
    const installed = try install(std.testing.allocator,
        \\{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo keep-me"}]}]}}
    );
    defer std.testing.allocator.free(installed);
    const out = try uninstall(std.testing.allocator, installed);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "keep-me") != null);
    try std.testing.expect(!isInstalled(out));
}
