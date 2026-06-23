const std = @import("std");

pub const CommandStyle = enum { posix, windows };

pub const ClaudeOptions = struct {
    session_hook_path: []const u8,
    notifier_command: []const u8,
    command_style: CommandStyle = .posix,
};

pub const CodexHooksOptions = struct {
    session_hook_path: []const u8,
    command_style: CommandStyle = .posix,
};

pub const CodexNotifyStatus = enum {
    added,
    already_present,
    conflict,
};

pub const CodexConfigOptions = struct {
    notifier_command: []const u8,
    notify_value: ?[]const u8 = null,
};

pub const CodexConfigUpdate = struct {
    content: []u8,
    notify_status: CodexNotifyStatus,
};

pub fn buildClaudeSettings(allocator: std.mem.Allocator, existing: []const u8, opts: ClaudeOptions) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const src = jsonSource(existing);
    var parsed = try std.json.parseFromSlice(std.json.Value, aa, src, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    if (parsed.value != .object) return error.InvalidSettingsJson;

    const root = &parsed.value.object;
    const hooks_obj = try ensureObject(aa, root, "hooks");

    const session_command = try hookCommand(aa, opts.command_style, opts.session_hook_path);
    try ensureCommandHook(aa, hooks_obj, "SessionStart", session_command, .{
        .matcher = "*",
        .timeout = 10,
        .dedupe_needle = "wispterm-agent-session",
    });
    try ensureCommandHook(aa, hooks_obj, "Stop", opts.notifier_command, .{
        .dedupe_needle = opts.notifier_command,
    });
    try ensureCommandHook(aa, hooks_obj, "Notification", opts.notifier_command, .{
        .dedupe_needle = opts.notifier_command,
    });

    return try std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 });
}

pub fn buildCodexHooksJson(allocator: std.mem.Allocator, existing: []const u8, opts: CodexHooksOptions) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const src = jsonSource(existing);
    var parsed = try std.json.parseFromSlice(std.json.Value, aa, src, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    if (parsed.value != .object) return error.InvalidHooksJson;

    const root = &parsed.value.object;
    const hooks_obj = try ensureObject(aa, root, "hooks");
    const session_command = try hookCommand(aa, opts.command_style, opts.session_hook_path);
    try ensureCommandHook(aa, hooks_obj, "SessionStart", session_command, .{
        .timeout = 10,
        .dedupe_needle = "wispterm-agent-session",
    });

    return try std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 });
}

pub fn buildCodexConfigToml(allocator: std.mem.Allocator, existing: []const u8, opts: CodexConfigOptions) !CodexConfigUpdate {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer lines.deinit(aa);
    var it = std.mem.splitScalar(u8, existing, '\n');
    while (it.next()) |line| {
        if (line.len == 0 and it.index == null and std.mem.endsWith(u8, existing, "\n")) break;
        try lines.append(aa, line);
    }
    if (existing.len == 0) lines.clearRetainingCapacity();

    var notify_status: CodexNotifyStatus = .added;
    var first_header_index = lines.items.len;
    for (lines.items, 0..) |line, i| {
        if (tomlTableHeader(line) != null) {
            first_header_index = i;
            break;
        }
    }
    var notify_index: ?usize = null;
    for (lines.items[0..first_header_index], 0..) |line, i| {
        if (isTomlKey(line, "notify")) {
            notify_index = i;
            break;
        }
    }
    const notify_value = opts.notify_value orelse try std.fmt.allocPrint(aa, "[\"{s}\"]", .{opts.notifier_command});
    const notify_line = try std.fmt.allocPrint(aa, "notify = {s}", .{notify_value});
    if (notify_index) |i| {
        if (std.mem.indexOf(u8, lines.items[i], opts.notifier_command) != null) {
            notify_status = .already_present;
        } else {
            notify_status = .conflict;
        }
    } else {
        try lines.insert(aa, 0, notify_line);
        notify_status = .added;
    }

    try ensureTopLevelFeaturesHooks(aa, &lines);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    for (lines.items, 0..) |line, i| {
        if (i > 0) try out.append(allocator, '\n');
        try out.appendSlice(allocator, line);
    }
    if (existing.len == 0 or std.mem.endsWith(u8, existing, "\n")) {
        try out.append(allocator, '\n');
    }
    return .{
        .content = try out.toOwnedSlice(allocator),
        .notify_status = notify_status,
    };
}

const HookOptions = struct {
    matcher: ?[]const u8 = null,
    timeout: ?i64 = null,
    dedupe_needle: []const u8,
};

fn jsonSource(existing: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, existing, " \t\r\n");
    return if (trimmed.len == 0) "{}" else trimmed;
}

fn hookCommand(allocator: std.mem.Allocator, style: CommandStyle, path: []const u8) ![]u8 {
    return switch (style) {
        .posix => blk: {
            const quoted = try shellQuote(allocator, path);
            break :blk try std.fmt.allocPrint(allocator, "bash {s} session", .{quoted});
        },
        .windows => try std.fmt.allocPrint(allocator, "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"{s}\" session", .{path}),
    };
}

fn shellQuote(allocator: std.mem.Allocator, arg: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '\'');
    for (arg) |ch| {
        if (ch == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, ch);
        }
    }
    try out.append(allocator, '\'');
    return try out.toOwnedSlice(allocator);
}

fn ensureObject(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8) !*std.json.ObjectMap {
    const entry = try object.getOrPutValue(key, std.json.Value{ .object = std.json.ObjectMap.init(allocator) });
    if (entry.value_ptr.* != .object) return error.InvalidJsonShape;
    return &entry.value_ptr.*.object;
}

fn ensureArray(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8) !*std.json.Array {
    const entry = try object.getOrPutValue(key, std.json.Value{ .array = std.json.Array.init(allocator) });
    if (entry.value_ptr.* != .array) return error.InvalidJsonShape;
    return &entry.value_ptr.*.array;
}

fn ensureCommandHook(
    allocator: std.mem.Allocator,
    hooks_obj: *std.json.ObjectMap,
    event: []const u8,
    command: []const u8,
    opts: HookOptions,
) !void {
    const event_arr = try ensureArray(allocator, hooks_obj, event);
    if (eventHasCommand(event_arr, opts.dedupe_needle)) return;

    var hook_obj = std.json.ObjectMap.init(allocator);
    try hook_obj.put("type", std.json.Value{ .string = "command" });
    try hook_obj.put("command", std.json.Value{ .string = try allocator.dupe(u8, command) });
    if (opts.timeout) |timeout| {
        try hook_obj.put("timeout", std.json.Value{ .integer = timeout });
    }

    var hook_arr = std.json.Array.init(allocator);
    try hook_arr.append(std.json.Value{ .object = hook_obj });

    var group_obj = std.json.ObjectMap.init(allocator);
    if (opts.matcher) |matcher| {
        try group_obj.put("matcher", std.json.Value{ .string = matcher });
    }
    try group_obj.put("hooks", std.json.Value{ .array = hook_arr });

    try event_arr.append(std.json.Value{ .object = group_obj });
}

fn eventHasCommand(event_arr: *const std.json.Array, needle: []const u8) bool {
    for (event_arr.items) |group| {
        if (group != .object) continue;
        const inner = group.object.get("hooks") orelse continue;
        if (inner != .array) continue;
        for (inner.array.items) |hook| {
            if (hook != .object) continue;
            const cmd = hook.object.get("command") orelse continue;
            if (cmd != .string) continue;
            if (std.mem.indexOf(u8, cmd.string, needle) != null) return true;
        }
    }
    return false;
}

fn ensureTopLevelFeaturesHooks(allocator: std.mem.Allocator, lines: *std.ArrayListUnmanaged([]const u8)) !void {
    var features_start: ?usize = null;
    var features_end: usize = lines.items.len;
    for (lines.items, 0..) |line, i| {
        if (tomlTableHeader(line)) |header| {
            if (features_start == null and std.mem.eql(u8, header, "features")) {
                features_start = i;
                features_end = lines.items.len;
            } else if (features_start != null) {
                features_end = i;
                break;
            }
        }
    }

    if (features_start == null) {
        if (lines.items.len > 0 and lines.items[lines.items.len - 1].len != 0) {
            try lines.append(allocator, "");
        }
        try lines.append(allocator, "[features]");
        try lines.append(allocator, "hooks = true");
        return;
    }

    var hooks_index: ?usize = null;
    var i = features_start.? + 1;
    while (i < features_end) {
        if (isTomlKey(lines.items[i], "codex_hooks")) {
            _ = lines.orderedRemove(i);
            features_end -= 1;
            continue;
        }
        if (isTomlKey(lines.items[i], "hooks")) {
            hooks_index = i;
        }
        i += 1;
    }

    if (hooks_index) |idx| {
        lines.items[idx] = "hooks = true";
    } else {
        try lines.insert(allocator, features_start.? + 1, "hooks = true");
    }
}

fn tomlTableHeader(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') return null;
    if (trimmed.len >= 4 and trimmed[1] == '[') return null;
    return std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r");
}

fn isTomlKey(line: []const u8, key: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return false;
    const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return false;
    const actual = std.mem.trim(u8, trimmed[0..eq], " \t\r");
    return std.mem.eql(u8, actual, key);
}

test "Claude settings install SessionStart identity and notification hooks" {
    const out = try buildClaudeSettings(std.testing.allocator, "", .{
        .session_hook_path = "/home/me/.claude/hooks/wispterm-agent-session.sh",
        .notifier_command = "/home/me/.config/wispterm/wispterm-notify.sh",
    });
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\"SessionStart\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"matcher\": \"*\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "bash '/home/me/.claude/hooks/wispterm-agent-session.sh' session") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"timeout\": 10") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"Stop\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"Notification\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/home/me/.config/wispterm/wispterm-notify.sh") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "state=running") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "state=done") == null);
}

test "Claude settings merge is idempotent and preserves user hooks" {
    const existing =
        \\{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo keep-me"}]}]}}
    ;
    const once = try buildClaudeSettings(std.testing.allocator, existing, .{
        .session_hook_path = "/home/me/.claude/hooks/wispterm-agent-session.sh",
        .notifier_command = "/home/me/.config/wispterm/wispterm-notify.sh",
    });
    defer std.testing.allocator.free(once);
    const twice = try buildClaudeSettings(std.testing.allocator, once, .{
        .session_hook_path = "/home/me/.claude/hooks/wispterm-agent-session.sh",
        .notifier_command = "/home/me/.config/wispterm/wispterm-notify.sh",
    });
    defer std.testing.allocator.free(twice);

    try std.testing.expect(std.mem.indexOf(u8, twice, "keep-me") != null);
    try std.testing.expectEqual(count(twice, "wispterm-agent-session.sh"), @as(usize, 1));
    try std.testing.expectEqual(count(twice, "wispterm-notify.sh"), @as(usize, 2));
}

test "Codex hooks install SessionStart identity hook" {
    const out = try buildCodexHooksJson(std.testing.allocator, "", .{
        .session_hook_path = "/home/me/.codex/wispterm-agent-session.sh",
    });
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\"SessionStart\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "bash '/home/me/.codex/wispterm-agent-session.sh' session") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"timeout\": 10") != null);
}

test "Codex config enables hooks and prepends top-level notify" {
    const update = try buildCodexConfigToml(std.testing.allocator,
        \\model = "gpt-5"
        \\
        \\[profiles.work]
        \\model = "gpt-5-codex"
        \\
    , .{ .notifier_command = "/home/me/.config/wispterm/wispterm-notify.sh" });
    defer std.testing.allocator.free(update.content);

    try std.testing.expectEqual(CodexNotifyStatus.added, update.notify_status);
    try std.testing.expect(std.mem.startsWith(u8, update.content, "notify = [\"/home/me/.config/wispterm/wispterm-notify.sh\"]\n"));
    try std.testing.expect(std.mem.indexOf(u8, update.content, "[features]\nhooks = true") != null);
    try std.testing.expect(std.mem.indexOf(u8, update.content, "[profiles.work]") != null);
}

test "Codex config preserves existing different notify and only top-level features" {
    const update = try buildCodexConfigToml(std.testing.allocator,
        \\notify = ["/other/notifier"]
        \\
        \\[features]
        \\codex_hooks = true
        \\
        \\[profiles.work.features]
        \\hooks = false
        \\codex_hooks = false
        \\
    , .{ .notifier_command = "/home/me/.config/wispterm/wispterm-notify.sh" });
    defer std.testing.allocator.free(update.content);

    try std.testing.expectEqual(CodexNotifyStatus.conflict, update.notify_status);
    try std.testing.expect(std.mem.indexOf(u8, update.content, "notify = [\"/other/notifier\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, update.content, "[features]\nhooks = true") != null);
    try std.testing.expect(std.mem.indexOf(u8, update.content, "[profiles.work.features]\nhooks = false\ncodex_hooks = false") != null);
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, i, needle)) |p| : (i = p + needle.len) n += 1;
    return n;
}
