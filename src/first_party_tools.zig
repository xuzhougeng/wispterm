const std = @import("std");
const platform_atomic_file = @import("platform/atomic_file.zig");
const platform_dirs = @import("platform/dirs.zig");
const platform_process = @import("platform/process.zig");
const platform_pty_command = @import("platform/pty_command.zig");

const MAX_STATE_BYTES: usize = 64 * 1024;
const STATE_BASENAME = "agent_tools.json";

pub const Category = enum {
    terminal,
    file,
    web,
    docs,
    memory,
    integration,
    session,
    agent,
};

pub const Definition = struct {
    name: []const u8,
    label: []const u8,
    description: []const u8,
    category: Category,
    disableable: bool = true,
};

const static_definitions = [_]Definition{
    .{ .name = "terminal_list", .label = "terminal_list", .description = "List WispTerm terminal surfaces visible to the agent.", .category = .terminal },
    .{ .name = "terminal_context", .label = "terminal_context", .description = "Report the current selected terminal write context.", .category = .terminal },
    .{ .name = "terminal_snapshot", .label = "terminal_snapshot", .description = "Read a bounded text snapshot from terminal surfaces.", .category = .terminal },
    .{ .name = "terminal_select", .label = "terminal_select", .description = "Select the terminal surface used for subsequent write tools.", .category = .terminal },
    .{ .name = "ssh_session_exec", .label = "ssh_session_exec", .description = "Run a shell command in an already-open SSH terminal surface.", .category = .terminal },
    .{ .name = "terminal_repl_exec", .label = "terminal_repl_exec", .description = "Send text to an already-open interactive REPL or agent app.", .category = .terminal },
    .{ .name = "terminal_answer_prompt", .label = "terminal_answer_prompt", .description = "Answer an approval prompt in an agent terminal surface.", .category = .terminal },
    .{ .name = "ask_user", .label = "ask_user", .description = "Ask the user a blocking multiple-choice question.", .category = .agent },
    .{ .name = "read_file", .label = "read_file", .description = "Read a local or remote text file.", .category = .file },
    .{ .name = "copy_file", .label = "copy_file", .description = "Copy a file between local, WSL, and SSH contexts.", .category = .file },
    .{ .name = "write_file", .label = "write_file", .description = "Create or overwrite a local or remote text file.", .category = .file },
    .{ .name = "edit_file", .label = "edit_file", .description = "Replace exact text in a local or remote text file.", .category = .file },
    .{ .name = "ssh_profile_save", .label = "ssh_profile_save", .description = "Create or update a saved WispTerm SSH profile.", .category = .session },
    .{ .name = "ssh_profile_connect", .label = "ssh_profile_connect", .description = "Open a new tab from a saved WispTerm SSH profile.", .category = .session },
    .{ .name = "tab_new", .label = "tab_new", .description = "Open a new WispTerm terminal tab.", .category = .session },
    .{ .name = "tab_close", .label = "tab_close", .description = "Close a selected terminal tab.", .category = .session },
    .{ .name = "skill_info", .label = "skill_info", .description = "Load a WispTerm skill by stable name.", .category = .agent },
    .{ .name = "wispterm_docs", .label = "wispterm_docs", .description = "Read WispTerm's own documentation.", .category = .docs },
    .{ .name = "websearch", .label = "websearch", .description = "Search the web for current information via Jina.", .category = .web },
    .{ .name = "webread", .label = "webread", .description = "Read a web page or local document into markdown via Jina Reader.", .category = .web },
    .{ .name = "pubmed", .label = "pubmed", .description = "Search PubMed biomedical literature.", .category = .web },
    .{ .name = "subagent", .label = "subagent", .description = "Delegate a self-contained research task to a background subagent.", .category = .agent },
    .{ .name = "weixin_send_attachment", .label = "weixin_send_attachment", .description = "Send a local file back to the active Weixin conversation.", .category = .integration },
    .{ .name = "memory_save", .label = "memory_save", .description = "Save a durable long-term memory.", .category = .memory },
    .{ .name = "memory_recall", .label = "memory_recall", .description = "Read a durable long-term memory.", .category = .memory },
    .{ .name = "memory_delete", .label = "memory_delete", .description = "Delete a durable long-term memory.", .category = .memory },
};

pub const DisabledTools = struct {
    names: [][]u8,

    pub fn empty() DisabledTools {
        return .{ .names = &.{} };
    }

    pub fn deinit(self: *DisabledTools, allocator: std.mem.Allocator) void {
        for (self.names) |name| allocator.free(name);
        if (self.names.len > 0) allocator.free(self.names);
        self.* = empty();
    }

    pub fn contains(self: DisabledTools, name: []const u8) bool {
        return isDisabledName(self.names, name);
    }
};

pub fn platformLocalCommandNameForTest() []const u8 {
    return platform_process.localCommandToolName();
}

pub fn activeDefinitions(allocator: std.mem.Allocator) ![]Definition {
    var list: std.ArrayListUnmanaged(Definition) = .empty;
    errdefer list.deinit(allocator);

    const local_name = platform_process.localCommandToolName();
    try list.append(allocator, .{
        .name = local_name,
        .label = local_name,
        .description = platform_process.localCommandToolDescription(),
        .category = .terminal,
    });

    for (static_definitions) |definition| try list.append(allocator, definition);

    if (platform_pty_command.wslSessionToolsEnabled()) {
        const wsl_name = platform_pty_command.wslSessionToolName();
        try list.append(allocator, .{
            .name = wsl_name,
            .label = wsl_name,
            .description = platform_pty_command.wslSessionToolDescription(),
            .category = .terminal,
        });
    }

    return list.toOwnedSlice(allocator);
}

pub fn freeDefinitions(allocator: std.mem.Allocator, defs: []Definition) void {
    allocator.free(defs);
}

pub fn isKnown(name: []const u8) bool {
    if (std.mem.eql(u8, name, platform_process.localCommandToolName())) return true;
    if (platform_pty_command.wslSessionToolsEnabled() and std.mem.eql(u8, name, platform_pty_command.wslSessionToolName())) return true;
    for (static_definitions) |definition| {
        if (std.mem.eql(u8, definition.name, name)) return true;
    }
    return false;
}

pub fn isKnownActive(defs: []const Definition, name: []const u8) bool {
    for (defs) |definition| {
        if (std.mem.eql(u8, definition.name, name)) return true;
    }
    return false;
}

pub fn isDisabledName(disabled_names: []const []const u8, name: []const u8) bool {
    for (disabled_names) |disabled| {
        if (std.mem.eql(u8, disabled, name)) return true;
    }
    return false;
}

pub fn parseDisabledToolsJson(allocator: std.mem.Allocator, bytes: []const u8) !DisabledTools {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidAgentToolsState;

    const disabled_value = parsed.value.object.get("disabled") orelse return DisabledTools.empty();
    if (disabled_value != .array) return error.InvalidAgentToolsState;

    var list: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (list.items) |name| allocator.free(name);
        list.deinit(allocator);
    }

    for (disabled_value.array.items) |item| {
        if (item != .string) continue;
        if (!isKnown(item.string)) continue;
        if (isDisabledName(list.items, item.string)) continue;
        try list.append(allocator, try allocator.dupe(u8, item.string));
    }

    return .{ .names = try list.toOwnedSlice(allocator) };
}

pub fn loadDisabledToolsFromPath(allocator: std.mem.Allocator, path: []const u8) !DisabledTools {
    const bytes = std.fs.cwd().readFileAlloc(allocator, path, MAX_STATE_BYTES) catch |err| switch (err) {
        error.FileNotFound => return DisabledTools.empty(),
        else => return err,
    };
    defer allocator.free(bytes);
    return parseDisabledToolsJson(allocator, bytes) catch DisabledTools.empty();
}

pub fn loadDisabledTools(allocator: std.mem.Allocator) !DisabledTools {
    const path = platform_dirs.pathInConfigDir(allocator, STATE_BASENAME) catch return DisabledTools.empty();
    defer allocator.free(path);
    return loadDisabledToolsFromPath(allocator, path) catch DisabledTools.empty();
}

pub fn disabledToolsJson(allocator: std.mem.Allocator, disabled: DisabledTools) ![]u8 {
    const State = struct {
        disabled: []const []const u8,
    };
    return std.json.Stringify.valueAlloc(allocator, State{ .disabled = disabled.names }, .{ .whitespace = .indent_2 });
}

pub fn writeDisabledToolsToPath(allocator: std.mem.Allocator, path: []const u8, disabled: DisabledTools) !void {
    const json = try disabledToolsJson(allocator, disabled);
    defer allocator.free(json);
    try platform_atomic_file.writeFileReplaceSafe(path, json);
}

pub fn writeDisabledTools(allocator: std.mem.Allocator, disabled: DisabledTools) !void {
    const config_dir = try platform_dirs.configDir(allocator);
    defer allocator.free(config_dir);
    try std.fs.cwd().makePath(config_dir);
    const path = try std.fs.path.join(allocator, &.{ config_dir, STATE_BASENAME });
    defer allocator.free(path);
    try writeDisabledToolsToPath(allocator, path, disabled);
}

pub fn toggledDisabledTools(allocator: std.mem.Allocator, current: DisabledTools, name: []const u8) !DisabledTools {
    if (!isKnown(name)) return error.UnknownFirstPartyTool;
    var list: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (list.items) |owned| allocator.free(owned);
        list.deinit(allocator);
    }

    var removed = false;
    for (current.names) |existing| {
        if (std.mem.eql(u8, existing, name)) {
            removed = true;
            continue;
        }
        try list.append(allocator, try allocator.dupe(u8, existing));
    }

    if (!removed) try list.append(allocator, try allocator.dupe(u8, name));
    return .{ .names = try list.toOwnedSlice(allocator) };
}

test "first_party_tools: active definitions include webread and the local command tool" {
    const a = std.testing.allocator;
    const defs = try activeDefinitions(a);
    defer freeDefinitions(a, defs);

    try std.testing.expect(isKnownActive(defs, "webread"));
    try std.testing.expect(isKnown(platformLocalCommandNameForTest()));
}

test "first_party_tools: disabled state json filters unknown and duplicate names" {
    const a = std.testing.allocator;
    var disabled = try parseDisabledToolsJson(a,
        \\{"disabled":["webread","missing_tool","webread","pubmed"]}
    );
    defer disabled.deinit(a);

    try std.testing.expect(disabled.contains("webread"));
    try std.testing.expect(disabled.contains("pubmed"));
    try std.testing.expect(!disabled.contains("missing_tool"));
    try std.testing.expectEqual(@as(usize, 2), disabled.names.len);
}

test "first_party_tools: malformed state falls back to empty when loaded from path" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "agent_tools.json", .data = "not json" });
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, "agent_tools.json" });
    defer a.free(path);

    var disabled = loadDisabledToolsFromPath(a, path) catch DisabledTools.empty();
    defer disabled.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), disabled.names.len);
}

test "first_party_tools: toggled state writes and reads atomically" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, "agent_tools.json" });
    defer a.free(path);

    const current = DisabledTools.empty();
    var next = try toggledDisabledTools(a, current, "webread");
    defer next.deinit(a);
    try writeDisabledToolsToPath(a, path, next);

    var loaded = try loadDisabledToolsFromPath(a, path);
    defer loaded.deinit(a);
    try std.testing.expect(loaded.contains("webread"));

    var enabled_again = try toggledDisabledTools(a, loaded, "webread");
    defer enabled_again.deinit(a);
    try std.testing.expect(!enabled_again.contains("webread"));
}
