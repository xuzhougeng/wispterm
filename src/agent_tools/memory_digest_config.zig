//! Native tool `memory_digest_config`: allow the built-in agent to inspect and
//! change only Memory Digest config keys. Mutations use the same main config
//! file path and hot-reload path as the Settings page.
const std = @import("std");
const Config = @import("../config.zig");
const types = @import("../assistant/conversation/types.zig");
const dirs = @import("../platform/dirs.zig");
const tool_args = @import("args.zig");
const tool_output = @import("output.zig");

const ToolContext = types.ToolContext;

const KeyKind = enum { boolean, string, time_hh_mm, uint };

const KeySpec = struct {
    name: []const u8,
    kind: KeyKind,
    default_value: []const u8,
    description: []const u8,
};

const key_specs = [_]KeySpec{
    .{ .name = "memory-digest-enabled", .kind = .boolean, .default_value = "false", .description = "Enable the daily AI conversation Memory Digest job." },
    .{ .name = "memory-digest-profile", .kind = .string, .default_value = "", .description = "Saved AI profile used for digest summarization; empty uses the first saved profile." },
    .{ .name = "memory-digest-run-after", .kind = .time_hh_mm, .default_value = "04:00", .description = "Local HH:MM time after which the daily digest may run." },
    .{ .name = "memory-digest-scan-remote", .kind = .boolean, .default_value = "false", .description = "Scan Windows WSL and all saved SSH profiles for Claude Code and Codex histories." },
    .{ .name = "memory-digest-backfill-days", .kind = .uint, .default_value = "7", .description = "Maximum catch-up days for first or missed digest runs." },
    .{ .name = "memory-digest-max-chars", .kind = .uint, .default_value = "2000", .description = "Maximum characters retained from a single message before digesting." },
    .{ .name = "memory-digest-input-budget-chars", .kind = .uint, .default_value = "96000", .description = "Maximum bytes fed to one digest map prompt before chunking." },
};

fn findSpec(key: []const u8) ?KeySpec {
    for (key_specs) |spec| {
        if (std.mem.eql(u8, spec.name, key)) return spec;
    }
    return null;
}

pub fn isAllowedKey(key: []const u8) bool {
    return findSpec(key) != null;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn validateTime(value: []const u8) bool {
    if (value.len != 5) return false;
    if (!isDigit(value[0]) or !isDigit(value[1]) or value[2] != ':' or !isDigit(value[3]) or !isDigit(value[4])) return false;
    const hour = (value[0] - '0') * 10 + (value[1] - '0');
    const minute = (value[3] - '0') * 10 + (value[4] - '0');
    return hour < 24 and minute < 60;
}

pub fn normalizeValue(allocator: std.mem.Allocator, key: []const u8, value_raw: []const u8) ![]u8 {
    const spec = findSpec(key) orelse return error.UnsupportedKey;
    const value = std.mem.trim(u8, value_raw, " \t\r\n");
    switch (spec.kind) {
        .boolean => {
            if (std.ascii.eqlIgnoreCase(value, "true")) return allocator.dupe(u8, "true");
            if (std.ascii.eqlIgnoreCase(value, "false")) return allocator.dupe(u8, "false");
            return error.InvalidValue;
        },
        .string => return allocator.dupe(u8, value),
        .time_hh_mm => {
            if (!validateTime(value)) return error.InvalidValue;
            return allocator.dupe(u8, value);
        },
        .uint => {
            _ = std.fmt.parseInt(u32, value, 10) catch return error.InvalidValue;
            return allocator.dupe(u8, value);
        },
    }
}

fn valueFromJsonOwned(allocator: std.mem.Allocator, root: std.json.Value) ![]u8 {
    if (root != .object) return error.InvalidToolArguments;
    const value = root.object.get("value") orelse return error.MissingValue;
    return switch (value) {
        .string => |s| allocator.dupe(u8, s),
        .bool => |b| allocator.dupe(u8, if (b) "true" else "false"),
        .integer => |n| if (n >= 0 and n <= std.math.maxInt(u32))
            std.fmt.allocPrint(allocator, "{d}", .{n})
        else
            error.InvalidValue,
        else => error.InvalidValue,
    };
}

fn currentValue(cfg: Config, key: []const u8) []const u8 {
    if (std.mem.eql(u8, key, "memory-digest-enabled")) return if (cfg.@"memory-digest-enabled") "true" else "false";
    if (std.mem.eql(u8, key, "memory-digest-profile")) return cfg.@"memory-digest-profile";
    if (std.mem.eql(u8, key, "memory-digest-run-after")) return cfg.@"memory-digest-run-after";
    if (std.mem.eql(u8, key, "memory-digest-scan-remote")) return if (cfg.@"memory-digest-scan-remote") "true" else "false";
    if (std.mem.eql(u8, key, "memory-digest-backfill-days")) return "";
    if (std.mem.eql(u8, key, "memory-digest-max-chars")) return "";
    if (std.mem.eql(u8, key, "memory-digest-input-budget-chars")) return "";
    return "";
}

fn printValue(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), cfg: Config, spec: KeySpec) !void {
    if (std.mem.eql(u8, spec.name, "memory-digest-backfill-days")) {
        try out.print(allocator, "{d}", .{cfg.@"memory-digest-backfill-days"});
    } else if (std.mem.eql(u8, spec.name, "memory-digest-max-chars")) {
        try out.print(allocator, "{d}", .{cfg.@"memory-digest-max-chars"});
    } else if (std.mem.eql(u8, spec.name, "memory-digest-input-budget-chars")) {
        try out.print(allocator, "{d}", .{cfg.@"memory-digest-input-budget-chars"});
    } else {
        try out.appendSlice(allocator, currentValue(cfg, spec.name));
    }
}

pub fn listText(allocator: std.mem.Allocator) ![]u8 {
    var cfg = try Config.load(allocator);
    defer cfg.deinit(allocator);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "Memory Digest config:\n");
    if (cfg.config_path) |path| {
        try out.print(allocator, "file: {s}\n", .{path});
    }
    for (key_specs) |spec| {
        try out.print(allocator, "- {s} = ", .{spec.name});
        try printValue(allocator, &out, cfg, spec);
        try out.print(allocator, " (default {s})\n  {s}\n", .{ spec.default_value, spec.description });
    }
    return out.toOwnedSlice(allocator);
}

fn approve(ctx: *ToolContext, action: []const u8, key: []const u8, value: []const u8) bool {
    switch (ctx.settings.permission) {
        .full => return true,
        .confirm, .auto => {},
    }
    var buf: [256]u8 = undefined;
    const summary = std.fmt.bufPrint(&buf, "memory_digest_config {s} {s} {s}", .{ action, key, value }) catch "memory_digest_config change";
    return ctx.requestApproval("memory_digest_config", summary, "Change Memory Digest configuration");
}

fn configPathText(allocator: std.mem.Allocator) ![]const u8 {
    return Config.configFilePath(allocator) catch allocator.dupe(u8, "(unknown config path)");
}

fn errText(allocator: std.mem.Allocator, err: anyerror) ![]u8 {
    return std.fmt.allocPrint(allocator, "Memory Digest config error: {s}", .{@errorName(err)});
}

pub fn run(ctx: *ToolContext, arguments_json: []const u8) ![]u8 {
    var parsed = tool_args.parse(ctx.allocator, arguments_json) orelse
        return ctx.allocator.dupe(u8, "Invalid tool arguments.");
    defer parsed.deinit();
    const value = parsed.value;
    const action = tool_args.string(value, "action") orelse "list";

    if (std.mem.eql(u8, action, "list")) return listText(ctx.allocator);

    const key_raw = tool_args.string(value, "key") orelse return ctx.allocator.dupe(u8, "set/remove requires a \"key\".");
    const key = std.mem.trim(u8, key_raw, " \t\r\n");
    if (!isAllowedKey(key)) {
        return std.fmt.allocPrint(ctx.allocator, "Unsupported key \"{s}\". This tool only edits memory-digest-* keys.", .{key});
    }

    if (std.mem.eql(u8, action, "set")) {
        const raw = valueFromJsonOwned(ctx.allocator, value) catch |err| return errText(ctx.allocator, err);
        defer ctx.allocator.free(raw);
        const normalized = normalizeValue(ctx.allocator, key, raw) catch |err| return errText(ctx.allocator, err);
        defer ctx.allocator.free(normalized);
        if (!approve(ctx, "set", key, normalized)) {
            return tool_output.deniedResult(ctx.allocator, key, "operator denied Memory Digest config change");
        }
        Config.setConfigValue(ctx.allocator, key, normalized) catch |err| return errText(ctx.allocator, err);
        const path = try configPathText(ctx.allocator);
        defer ctx.allocator.free(path);
        return std.fmt.allocPrint(ctx.allocator, "Set {s} = {s} in {s}. Existing config hot-reload will apply it.", .{ key, normalized, path });
    }

    if (std.mem.eql(u8, action, "remove")) {
        if (!approve(ctx, "remove", key, "")) {
            return tool_output.deniedResult(ctx.allocator, key, "operator denied Memory Digest config change");
        }
        const keys = [_][]const u8{key};
        Config.removeConfigKeys(ctx.allocator, keys[0..]) catch |err| return errText(ctx.allocator, err);
        const path = try configPathText(ctx.allocator);
        defer ctx.allocator.free(path);
        return std.fmt.allocPrint(ctx.allocator, "Removed active {s} from {s}; the default will apply after hot-reload.", .{ key, path });
    }

    return std.fmt.allocPrint(ctx.allocator, "Unknown action \"{s}\". Use: list, set, remove.", .{action});
}

fn allowApprove(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8) bool {
    return true;
}

fn notCancelled(_: *anyopaque) bool {
    return false;
}

fn setupTempConfig(a: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    dirs.setTestConfigDirOverride(dir_path);
    return dir_path;
}

test "memory_digest_config validates allowed keys and values" {
    const a = std.testing.allocator;
    try std.testing.expect(isAllowedKey("memory-digest-scan-remote"));
    try std.testing.expect(!isAllowedKey("font-size"));

    const bool_value = try normalizeValue(a, "memory-digest-scan-remote", "TRUE");
    defer a.free(bool_value);
    try std.testing.expectEqualStrings("true", bool_value);

    const time_value = try normalizeValue(a, "memory-digest-run-after", "23:59");
    defer a.free(time_value);
    try std.testing.expectEqualStrings("23:59", time_value);

    try std.testing.expectError(error.InvalidValue, normalizeValue(a, "memory-digest-run-after", "24:00"));
    try std.testing.expectError(error.InvalidValue, normalizeValue(a, "memory-digest-enabled", "yes"));
    try std.testing.expectError(error.UnsupportedKey, normalizeValue(a, "font-size", "12"));
}

test "memory_digest_config run set and remove write the main config file" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try setupTempConfig(a, &tmp);
    defer a.free(dir_path);
    defer dirs.setTestConfigDirOverride(null);

    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{ .permission = .full },
        .approve = allowApprove,
        .cancelled = notCancelled,
    };

    const set_out = try run(&ctx, "{\"action\":\"set\",\"key\":\"memory-digest-scan-remote\",\"value\":true}");
    defer a.free(set_out);
    try std.testing.expect(std.mem.indexOf(u8, set_out, "memory-digest-scan-remote = true") != null);

    {
        var cfg = try Config.load(a);
        defer cfg.deinit(a);
        try std.testing.expect(cfg.@"memory-digest-scan-remote");
    }

    const remove_out = try run(&ctx, "{\"action\":\"remove\",\"key\":\"memory-digest-scan-remote\"}");
    defer a.free(remove_out);
    try std.testing.expect(std.mem.indexOf(u8, remove_out, "Removed active memory-digest-scan-remote") != null);

    {
        var cfg = try Config.load(a);
        defer cfg.deinit(a);
        try std.testing.expect(!cfg.@"memory-digest-scan-remote");
    }
}
