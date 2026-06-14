//! Pure generator/merger/remover of Claude Code hook config that makes the
//! agent emit WispTerm's OSC 7748 agent-state marker. No IO — callers read/write
//! ~/.claude/settings.json. Our hook commands all contain TAG, so we can
//! detect/skip/remove them idempotently without disturbing the user's hooks.

const std = @import("std");
const agent_detector = @import("agent_detector.zig");

const TAG = agent_detector.TAG; // "wispterm-agent"

const HookSpec = struct { event: []const u8, state: []const u8, matcher: ?[]const u8 };
const HOOKS = [_]HookSpec{
    .{ .event = "UserPromptSubmit", .state = "running", .matcher = null },
    .{ .event = "PreToolUse", .state = "running", .matcher = "*" },
    .{ .event = "Notification", .state = "waiting_approval", .matcher = null },
    .{ .event = "Stop", .state = "done", .matcher = null },
};

/// The shell command for one hook: emit the OSC 7748 marker to the controlling
/// tty (`> /dev/tty` so it reaches the terminal even when the hook's stdout is
/// captured by Claude Code). `buf` must be large enough (~160 bytes).
pub fn hookCommand(buf: []u8, state: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(
        buf,
        "printf '\\033]7748;{s};state={s};app=claude_code\\007' > /dev/tty 2>/dev/null || true",
        .{ TAG, state },
    ) catch null;
}

/// True if settings JSON text already contains a WispTerm agent hook.
pub fn isInstalled(settings_json: []const u8) bool {
    return std.mem.indexOf(u8, settings_json, TAG) != null;
}

/// Return new settings.json text with our hooks merged in idempotently.
/// `existing` may be empty (treated as `{}`). Caller owns the returned slice
/// (allocated with `alloc`).
pub fn install(alloc: std.mem.Allocator, existing: []const u8) ![]u8 {
    // Use an arena for the parsed JSON tree so all Value nodes are freed together.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    // Treat empty/blank input as an empty JSON object.
    const src = blk: {
        const trimmed = std.mem.trim(u8, existing, " \t\r\n");
        break :blk if (trimmed.len == 0) "{}" else trimmed;
    };

    // Parse with alloc_always so no parsed strings alias the input buffer.
    var parsed = try std.json.parseFromSlice(std.json.Value, aa, src, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    // parsed is arena-owned — no explicit deinit needed.

    // Ensure root is an object.
    if (parsed.value != .object) return error.InvalidSettingsJson;
    var root = &parsed.value.object;

    // Get-or-create the top-level "hooks" object.
    // ObjectMap = StringArrayHashMap(Value) which is managed (holds its allocator),
    // so getOrPutValue takes (key, value) — no allocator argument.
    const hooks_entry = try root.getOrPutValue("hooks", std.json.Value{ .object = std.json.ObjectMap.init(aa) });
    if (hooks_entry.value_ptr.* != .object) return error.InvalidSettingsJson;
    var hooks_obj = &hooks_entry.value_ptr.*.object;

    // For each event we manage, ensure our command is present.
    // Use a regular (non-inline) loop to allow runtime control flow (continue).
    for (&HOOKS) |spec| {
        // Get-or-create the event array.
        // Array = std.array_list.Managed(Value), ObjectMap = StringArrayHashMap(Value).
        const event_entry = try hooks_obj.getOrPutValue(spec.event, std.json.Value{ .array = std.json.Array.init(aa) });
        if (event_entry.value_ptr.* != .array) return error.InvalidSettingsJson;
        const event_arr = &event_entry.value_ptr.*.array;

        // Check idempotency: skip if any existing group already has our TAG command.
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

        // Build the command string.
        var cmd_buf: [256]u8 = undefined;
        const cmd = hookCommand(&cmd_buf, spec.state) orelse return error.CommandBufferTooSmall;
        const cmd_owned = try aa.dupe(u8, cmd);

        // Build: {"type":"command","command":"<cmd>"}
        // ObjectMap = StringArrayHashMap(Value): managed, put(key, value) — no allocator arg.
        var h_obj = std.json.ObjectMap.init(aa);
        try h_obj.put("type", std.json.Value{ .string = "command" });
        try h_obj.put("command", std.json.Value{ .string = cmd_owned });

        // Build inner hooks array.
        // Array = std.array_list.Managed(Value): managed, append(item) — no allocator arg.
        var h_arr = std.json.Array.init(aa);
        try h_arr.append(std.json.Value{ .object = h_obj });

        // Build the group object: { ["matcher": ...,] "hooks": [...] }
        var group_obj = std.json.ObjectMap.init(aa);
        if (spec.matcher) |m| {
            try group_obj.put("matcher", std.json.Value{ .string = m });
        }
        try group_obj.put("hooks", std.json.Value{ .array = h_arr });

        try event_arr.append(std.json.Value{ .object = group_obj });
    }

    // Stringify the mutated root value to an owned slice.
    return try std.json.Stringify.valueAlloc(alloc, parsed.value, .{ .whitespace = .indent_2 });
}

/// Return new settings.json text with all WispTerm agent hooks removed
/// (prune now-empty event arrays / `hooks` object). Caller owns the result.
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

    if (parsed.value != .object) return error.InvalidSettingsJson;
    var root = &parsed.value.object;

    const hooks_val = root.getPtr("hooks") orelse {
        // No hooks key — nothing to remove.
        return try std.json.Stringify.valueAlloc(alloc, parsed.value, .{ .whitespace = .indent_2 });
    };
    if (hooks_val.* != .object) {
        return try std.json.Stringify.valueAlloc(alloc, parsed.value, .{ .whitespace = .indent_2 });
    }
    var hooks_obj = &hooks_val.*.object;

    // For each known event, remove groups that contain our TAG.
    for (&HOOKS) |spec| {
        const event_val = hooks_obj.getPtr(spec.event) orelse continue;
        if (event_val.* != .array) continue;
        const event_arr = &event_val.*.array;

        // Build a new array excluding our groups.
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
            // Drop the empty event array entirely.
            _ = hooks_obj.orderedRemove(spec.event);
        } else {
            event_val.* = std.json.Value{ .array = kept };
        }
    }

    // If the hooks object is now empty, remove the "hooks" key from root.
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

test "hookCommand emits the marker for a state" {
    var b: [200]u8 = undefined;
    const c = hookCommand(&b, "running").?;
    try std.testing.expect(std.mem.indexOf(u8, c, "7748;wispterm-agent;state=running;app=claude_code") != null);
    try std.testing.expect(std.mem.indexOf(u8, c, "/dev/tty") != null);
}

test "install adds all four hooks to empty settings" {
    const out = try install(std.testing.allocator, "");
    defer std.testing.allocator.free(out);
    try std.testing.expect(isInstalled(out));
    inline for (.{ "UserPromptSubmit", "PreToolUse", "Notification", "Stop" }) |ev| {
        try std.testing.expect(std.mem.indexOf(u8, out, ev) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, out, "state=waiting_approval") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "state=done") != null);
}

test "install is idempotent (no duplicate Stop hook)" {
    const once = try install(std.testing.allocator, "");
    defer std.testing.allocator.free(once);
    const twice = try install(std.testing.allocator, once);
    defer std.testing.allocator.free(twice);
    try std.testing.expectEqual(count(once, "state=done"), count(twice, "state=done"));
    try std.testing.expectEqual(@as(usize, 1), count(twice, "state=done"));
}

test "install preserves an unrelated existing hook" {
    const existing =
        \\{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo keep-me"}]}]}}
    ;
    const out = try install(std.testing.allocator, existing);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "keep-me") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "state=done") != null);
}

test "uninstall removes only our hooks" {
    const installed = try install(std.testing.allocator,
        \\{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo keep-me"}]}]}}
    );
    defer std.testing.allocator.free(installed);
    const out = try uninstall(std.testing.allocator, installed);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "keep-me") != null);
    try std.testing.expect(!isInstalled(out));
}
