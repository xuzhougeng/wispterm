//! Native tool `wispterm_config`: inspect and edit WispTerm's main config file.
//! It is intentionally narrower than edit_file: only known single-value config
//! keys are accepted, and values are lightly type-checked before writing.
const std = @import("std");
const Config = @import("../config.zig");
const types = @import("../assistant/conversation/types.zig");
const dirs = @import("../platform/dirs.zig");
const tool_args = @import("args.zig");
const tool_output = @import("output.zig");

const ToolContext = types.ToolContext;

const KeyKind = enum {
    boolean,
    string,
    uint,
    port,
    float,
    unit_float,
    split_opacity,
    color,
    time_hh_mm,
    one_of,
};

const KeySpec = struct {
    name: []const u8,
    kind: KeyKind,
    default_value: []const u8,
    values: []const []const u8 = &.{},
};

const bool_values = [_][]const u8{ "true", "false" };
const font_styles = [_][]const u8{ "thin", "extra-light", "extralight", "light", "regular", "normal", "medium", "semi-bold", "semibold", "bold", "extra-bold", "extrabold", "black", "heavy" };
const cursor_styles = [_][]const u8{ "block", "bar", "underline", "block_hollow" };
const right_click_actions = [_][]const u8{ "ignore", "copy", "paste", "copy-or-paste" };
const url_open_modes = [_][]const u8{ "embedded", "system-browser" };
const agent_permissions = [_][]const u8{ "ask", "confirm", "auto", "guarded", "full", "full-permission" };
const windows_conpty_values = [_][]const u8{ "auto", "system" };
const language_values = [_][]const u8{ "auto", "en", "zh", "zh-CN", "zh_CN", "ZH" };
const image_modes = [_][]const u8{ "fill", "fit", "center", "tile" };

const key_specs = [_]KeySpec{
    .{ .name = "font-family", .kind = .string, .default_value = "JetBrains Mono" },
    .{ .name = "font-family-cjk", .kind = .string, .default_value = "" },
    .{ .name = "font-family-fallback", .kind = .string, .default_value = "" },
    .{ .name = "font-style", .kind = .one_of, .default_value = "regular", .values = font_styles[0..] },
    .{ .name = "font-size", .kind = .uint, .default_value = "13" },
    .{ .name = "cursor-style", .kind = .one_of, .default_value = "block", .values = cursor_styles[0..] },
    .{ .name = "cursor-style-blink", .kind = .boolean, .default_value = "true", .values = bool_values[0..] },
    .{ .name = "theme", .kind = .string, .default_value = "" },
    .{ .name = "custom-shader", .kind = .string, .default_value = "" },
    .{ .name = "window-height", .kind = .uint, .default_value = "0" },
    .{ .name = "window-width", .kind = .uint, .default_value = "0" },
    .{ .name = "scrollback-limit", .kind = .uint, .default_value = "10000000" },
    .{ .name = "copy-on-select", .kind = .boolean, .default_value = "false", .values = bool_values[0..] },
    .{ .name = "right-click-action", .kind = .one_of, .default_value = "copy", .values = right_click_actions[0..] },
    .{ .name = "url-open-mode", .kind = .one_of, .default_value = "embedded", .values = url_open_modes[0..] },
    .{ .name = "ssh-legacy-algorithms", .kind = .boolean, .default_value = "false", .values = bool_values[0..] },
    .{ .name = "desktop-notifications", .kind = .boolean, .default_value = "true", .values = bool_values[0..] },
    .{ .name = "confirm-close-running-program", .kind = .boolean, .default_value = "true", .values = bool_values[0..] },
    .{ .name = "ai-memory-enabled", .kind = .boolean, .default_value = "true", .values = bool_values[0..] },
    .{ .name = "ai-distill-suggest", .kind = .boolean, .default_value = "false", .values = bool_values[0..] },
    .{ .name = "ai-agent-enabled", .kind = .boolean, .default_value = "false", .values = bool_values[0..] },
    .{ .name = "ai-agent-permission", .kind = .one_of, .default_value = "ask", .values = agent_permissions[0..] },
    .{ .name = "ai-agent-command-timeout-ms", .kind = .uint, .default_value = "60000" },
    .{ .name = "ai-agent-output-limit", .kind = .uint, .default_value = "16384" },
    .{ .name = "ai-agent-working-dir", .kind = .string, .default_value = "" },
    .{ .name = "jina-api-key", .kind = .string, .default_value = "" },
    .{ .name = "windows-conpty", .kind = .one_of, .default_value = "auto", .values = windows_conpty_values[0..] },
    .{ .name = "shell", .kind = .string, .default_value = "platform default" },
    .{ .name = "working-directory", .kind = .string, .default_value = "" },
    .{ .name = "ai-default-profile", .kind = .string, .default_value = "" },
    .{ .name = "ai-subagent-profile", .kind = .string, .default_value = "" },
    .{ .name = "language", .kind = .one_of, .default_value = "auto", .values = language_values[0..] },
    .{ .name = "remote-enabled", .kind = .boolean, .default_value = "false", .values = bool_values[0..] },
    .{ .name = "remote-server-url", .kind = .string, .default_value = "" },
    .{ .name = "remote-server-fingerprint", .kind = .string, .default_value = "" },
    .{ .name = "remote-device-name", .kind = .string, .default_value = "" },
    .{ .name = "remote-session-key", .kind = .string, .default_value = "" },
    .{ .name = "feishu-enabled", .kind = .boolean, .default_value = "false", .values = bool_values[0..] },
    .{ .name = "feishu-international", .kind = .boolean, .default_value = "false", .values = bool_values[0..] },
    .{ .name = "feishu-app-id", .kind = .string, .default_value = "" },
    .{ .name = "feishu-app-secret", .kind = .string, .default_value = "" },
    .{ .name = "feishu-allowed-user", .kind = .string, .default_value = "" },
    .{ .name = "weixin-direct-enabled", .kind = .boolean, .default_value = "false", .values = bool_values[0..] },
    .{ .name = "weixin-base-url", .kind = .string, .default_value = "" },
    .{ .name = "weixin-reply-timeout-ms", .kind = .uint, .default_value = "120000" },
    .{ .name = "weixin-allowed-user", .kind = .string, .default_value = "" },
    .{ .name = "weixin-notify-forward", .kind = .boolean, .default_value = "false", .values = bool_values[0..] },
    .{ .name = "agent-control-enabled", .kind = .boolean, .default_value = "false", .values = bool_values[0..] },
    .{ .name = "agent-control-port", .kind = .port, .default_value = "0" },
    .{ .name = "wispterm-debug-fps", .kind = .boolean, .default_value = "false", .values = bool_values[0..] },
    .{ .name = "wispterm-debug-draw-calls", .kind = .boolean, .default_value = "false", .values = bool_values[0..] },
    .{ .name = "wispterm-debug-memory", .kind = .boolean, .default_value = "false", .values = bool_values[0..] },
    .{ .name = "wispterm-debug-render", .kind = .boolean, .default_value = "false", .values = bool_values[0..] },
    .{ .name = "wispterm-d3d-present", .kind = .boolean, .default_value = "true", .values = bool_values[0..] },
    .{ .name = "unfocused-split-opacity", .kind = .split_opacity, .default_value = "0.7" },
    .{ .name = "split-divider-color", .kind = .color, .default_value = "" },
    .{ .name = "focus-follows-mouse", .kind = .boolean, .default_value = "false", .values = bool_values[0..] },
    .{ .name = "restore-tabs-on-startup", .kind = .boolean, .default_value = "false", .values = bool_values[0..] },
    .{ .name = "auto-update-check", .kind = .boolean, .default_value = "true", .values = bool_values[0..] },
    .{ .name = "whats-new-on-update", .kind = .boolean, .default_value = "true", .values = bool_values[0..] },
    .{ .name = "copilot-hint", .kind = .boolean, .default_value = "true", .values = bool_values[0..] },
    .{ .name = "memory-digest-enabled", .kind = .boolean, .default_value = "false", .values = bool_values[0..] },
    .{ .name = "memory-digest-profile", .kind = .string, .default_value = "" },
    .{ .name = "memory-digest-run-after", .kind = .time_hh_mm, .default_value = "04:00" },
    .{ .name = "memory-digest-scan-remote", .kind = .boolean, .default_value = "false", .values = bool_values[0..] },
    .{ .name = "memory-digest-backfill-days", .kind = .uint, .default_value = "7" },
    .{ .name = "memory-digest-max-chars", .kind = .uint, .default_value = "2000" },
    .{ .name = "memory-digest-input-budget-chars", .kind = .uint, .default_value = "96000" },
    .{ .name = "background", .kind = .color, .default_value = "" },
    .{ .name = "foreground", .kind = .color, .default_value = "" },
    .{ .name = "cursor-color", .kind = .color, .default_value = "" },
    .{ .name = "cursor-text", .kind = .color, .default_value = "" },
    .{ .name = "selection-background", .kind = .color, .default_value = "" },
    .{ .name = "selection-foreground", .kind = .color, .default_value = "" },
    .{ .name = "background-image", .kind = .string, .default_value = "" },
    .{ .name = "background-opacity", .kind = .unit_float, .default_value = "1.0" },
    .{ .name = "background-image-mode", .kind = .one_of, .default_value = "fill", .values = image_modes[0..] },
    .{ .name = "title", .kind = .string, .default_value = "" },
    .{ .name = "maximize", .kind = .boolean, .default_value = "false", .values = bool_values[0..] },
    .{ .name = "fullscreen", .kind = .boolean, .default_value = "false", .values = bool_values[0..] },
    .{ .name = "quake-mode", .kind = .boolean, .default_value = "false", .values = bool_values[0..] },
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

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHex(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn validateColor(value: []const u8) bool {
    const s = if (std.mem.startsWith(u8, value, "#")) value[1..] else value;
    if (s.len != 6) return false;
    for (s) |c| {
        if (!isHex(c)) return false;
    }
    return true;
}

fn validateTime(value: []const u8) bool {
    if (value.len != 5) return false;
    if (!isDigit(value[0]) or !isDigit(value[1]) or value[2] != ':' or !isDigit(value[3]) or !isDigit(value[4])) return false;
    const hour = (value[0] - '0') * 10 + (value[1] - '0');
    const minute = (value[3] - '0') * 10 + (value[4] - '0');
    return hour < 24 and minute < 60;
}

fn matchesOneOf(value: []const u8, values: []const []const u8) bool {
    for (values) |allowed| {
        if (std.mem.eql(u8, value, allowed)) return true;
    }
    return false;
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
        .uint => {
            _ = std.fmt.parseInt(u32, value, 10) catch return error.InvalidValue;
            return allocator.dupe(u8, value);
        },
        .port => {
            _ = std.fmt.parseInt(u16, value, 10) catch return error.InvalidValue;
            return allocator.dupe(u8, value);
        },
        .float => {
            _ = std.fmt.parseFloat(f32, value) catch return error.InvalidValue;
            return allocator.dupe(u8, value);
        },
        .unit_float => {
            const n = std.fmt.parseFloat(f32, value) catch return error.InvalidValue;
            if (n < 0.0 or n > 1.0) return error.InvalidValue;
            return allocator.dupe(u8, value);
        },
        .split_opacity => {
            const n = std.fmt.parseFloat(f32, value) catch return error.InvalidValue;
            if (n < 0.15 or n > 1.0) return error.InvalidValue;
            return allocator.dupe(u8, value);
        },
        .color => {
            if (value.len == 0) return allocator.dupe(u8, value);
            if (!validateColor(value)) return error.InvalidValue;
            return allocator.dupe(u8, value);
        },
        .time_hh_mm => {
            if (!validateTime(value)) return error.InvalidValue;
            return allocator.dupe(u8, value);
        },
        .one_of => {
            if (!matchesOneOf(value, spec.values)) return error.InvalidValue;
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
        .float => |n| if (n >= 0)
            std.fmt.allocPrint(allocator, "{d}", .{n})
        else
            error.InvalidValue,
        else => error.InvalidValue,
    };
}

fn activeLineValue(line: []const u8, key: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return null;
    const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return null;
    const lhs = std.mem.trim(u8, trimmed[0..eq], " \t");
    if (!std.mem.eql(u8, lhs, key)) return null;
    return std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
}

fn activeValueInContent(content: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (activeLineValue(line, key)) |value| return value;
    }
    return null;
}

fn kindName(kind: KeyKind) []const u8 {
    return switch (kind) {
        .boolean => "bool",
        .string => "string",
        .uint => "uint",
        .port => "port",
        .float => "float",
        .unit_float => "0..1",
        .split_opacity => "0.15..1",
        .color => "color",
        .time_hh_mm => "HH:MM",
        .one_of => "enum",
    };
}

pub fn listText(allocator: std.mem.Allocator, query: ?[]const u8) ![]u8 {
    const path = try Config.configFilePath(allocator);
    defer allocator.free(path);

    const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    defer if (content.len > 0) allocator.free(content);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "WispTerm config file: {s}\n", .{path});
    try out.appendSlice(allocator, "Editable single-value keys");
    if (query) |q| try out.print(allocator, " matching \"{s}\"", .{q});
    try out.appendSlice(allocator, ":\n");

    var shown: usize = 0;
    for (key_specs) |spec| {
        if (query) |q| {
            if (!containsIgnoreCase(spec.name, q)) continue;
        }
        shown += 1;
        try out.print(allocator, "- {s} [{s}, default {s}]", .{ spec.name, kindName(spec.kind), spec.default_value });
        if (activeValueInContent(content, spec.name)) |value| {
            try out.print(allocator, " active={s}", .{value});
        }
        if (spec.values.len > 0) {
            try out.appendSlice(allocator, " values=");
            for (spec.values, 0..) |v, i| {
                if (i > 0) try out.append(allocator, '|');
                try out.appendSlice(allocator, v);
            }
        }
        try out.append(allocator, '\n');
    }
    if (shown == 0) try out.appendSlice(allocator, "No matching editable keys.\n");
    try out.appendSlice(allocator, "Repeatable directives keybind, palette, and config-file are intentionally not edited by this tool.\n");
    return out.toOwnedSlice(allocator);
}

fn approve(ctx: *ToolContext, action: []const u8, key: []const u8, value: []const u8) bool {
    switch (ctx.settings.permission) {
        .full => return true,
        .confirm, .auto => {},
    }
    var buf: [256]u8 = undefined;
    const summary = std.fmt.bufPrint(&buf, "wispterm_config {s} {s} {s}", .{ action, key, value }) catch "wispterm_config change";
    return ctx.requestApproval("wispterm_config", summary, "Change WispTerm configuration");
}

fn configPathText(allocator: std.mem.Allocator) ![]const u8 {
    return Config.configFilePath(allocator) catch allocator.dupe(u8, "(unknown config path)");
}

fn errText(allocator: std.mem.Allocator, err: anyerror) ![]u8 {
    return std.fmt.allocPrint(allocator, "WispTerm config error: {s}", .{@errorName(err)});
}

pub fn run(ctx: *ToolContext, arguments_json: []const u8) ![]u8 {
    var parsed = tool_args.parse(ctx.allocator, arguments_json) orelse
        return ctx.allocator.dupe(u8, "Invalid tool arguments.");
    defer parsed.deinit();
    const value = parsed.value;
    const action = tool_args.string(value, "action") orelse "list";

    if (std.mem.eql(u8, action, "list")) {
        return listText(ctx.allocator, tool_args.string(value, "query"));
    }

    const key_raw = tool_args.string(value, "key") orelse return ctx.allocator.dupe(u8, "set/remove requires a \"key\".");
    const key = std.mem.trim(u8, key_raw, " \t\r\n");
    if (!isAllowedKey(key)) {
        return std.fmt.allocPrint(ctx.allocator, "Unsupported key \"{s}\". This tool only edits known single-value WispTerm config keys.", .{key});
    }

    if (std.mem.eql(u8, action, "set")) {
        const raw = valueFromJsonOwned(ctx.allocator, value) catch |err| return errText(ctx.allocator, err);
        defer ctx.allocator.free(raw);
        const normalized = normalizeValue(ctx.allocator, key, raw) catch |err| return errText(ctx.allocator, err);
        defer ctx.allocator.free(normalized);
        if (!approve(ctx, "set", key, normalized)) {
            return tool_output.deniedResult(ctx.allocator, key, "operator denied WispTerm config change");
        }
        Config.setConfigValue(ctx.allocator, key, normalized) catch |err| return errText(ctx.allocator, err);
        const path = try configPathText(ctx.allocator);
        defer ctx.allocator.free(path);
        return std.fmt.allocPrint(ctx.allocator, "Set {s} = {s} in {s}. Existing config hot-reload will apply it.", .{ key, normalized, path });
    }

    if (std.mem.eql(u8, action, "remove")) {
        if (!approve(ctx, "remove", key, "")) {
            return tool_output.deniedResult(ctx.allocator, key, "operator denied WispTerm config change");
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

test "wispterm_config validates known scalar keys and values" {
    const a = std.testing.allocator;
    try std.testing.expect(isAllowedKey("font-size"));
    try std.testing.expect(isAllowedKey("memory-digest-scan-remote"));
    try std.testing.expect(!isAllowedKey("keybind"));
    try std.testing.expect(!isAllowedKey("palette"));

    const bool_value = try normalizeValue(a, "memory-digest-scan-remote", "TRUE");
    defer a.free(bool_value);
    try std.testing.expectEqualStrings("true", bool_value);

    const time_value = try normalizeValue(a, "memory-digest-run-after", "23:59");
    defer a.free(time_value);
    try std.testing.expectEqualStrings("23:59", time_value);

    const color_value = try normalizeValue(a, "background", "#112233");
    defer a.free(color_value);
    try std.testing.expectEqualStrings("#112233", color_value);

    try std.testing.expectError(error.InvalidValue, normalizeValue(a, "memory-digest-run-after", "24:00"));
    try std.testing.expectError(error.InvalidValue, normalizeValue(a, "font-size", "big"));
    try std.testing.expectError(error.InvalidValue, normalizeValue(a, "background-opacity", "1.5"));
    try std.testing.expectError(error.InvalidValue, normalizeValue(a, "cursor-style", "triangle"));
    try std.testing.expectError(error.UnsupportedKey, normalizeValue(a, "keybind", "ctrl+x=copy"));
}

test "wispterm_config run set and remove write the main config file" {
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

    const set_out = try run(&ctx, "{\"action\":\"set\",\"key\":\"font-size\",\"value\":\"16\"}");
    defer a.free(set_out);
    try std.testing.expect(std.mem.indexOf(u8, set_out, "font-size = 16") != null);

    {
        var cfg = try Config.load(a);
        defer cfg.deinit(a);
        try std.testing.expectEqual(@as(u32, 16), cfg.@"font-size");
    }

    const list_out = try run(&ctx, "{\"action\":\"list\",\"query\":\"font-size\"}");
    defer a.free(list_out);
    try std.testing.expect(std.mem.indexOf(u8, list_out, "active=16") != null);

    const remove_out = try run(&ctx, "{\"action\":\"remove\",\"key\":\"font-size\"}");
    defer a.free(remove_out);
    try std.testing.expect(std.mem.indexOf(u8, remove_out, "Removed active font-size") != null);

    {
        var cfg = try Config.load(a);
        defer cfg.deinit(a);
        try std.testing.expectEqual(@as(u32, 13), cfg.@"font-size");
    }
}
