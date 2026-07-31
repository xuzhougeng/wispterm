const std = @import("std");

pub fn parse(allocator: std.mem.Allocator, text: []const u8) ?std.json.Parsed(std.json.Value) {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const body = if (trimmed.len == 0) "{}" else trimmed;
    return std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch null;
}

pub fn string(root: std.json.Value, name: []const u8) ?[]const u8 {
    if (root != .object) return null;
    const value = root.object.get(name) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

pub fn int(root: std.json.Value, name: []const u8) ?u32 {
    if (root != .object) return null;
    const value = root.object.get(name) orelse return null;
    return switch (value) {
        .integer => |v| if (v > 0 and v <= std.math.maxInt(u32)) @intCast(v) else null,
        .float => |v| if (v > 0 and v <= @as(f64, @floatFromInt(std.math.maxInt(u32)))) @intFromFloat(v) else null,
        else => null,
    };
}

pub fn index(root: std.json.Value, name: []const u8) ?usize {
    if (root != .object) return null;
    const value = root.object.get(name) orelse return null;
    return switch (value) {
        .integer => |v| if (v >= 0 and v <= std.math.maxInt(usize)) @intCast(v) else null,
        .float => |v| if (v >= 0 and v <= @as(f64, @floatFromInt(std.math.maxInt(usize)))) @intFromFloat(v) else null,
        else => null,
    };
}

pub fn boolean(root: std.json.Value, name: []const u8) ?bool {
    if (root != .object) return null;
    const value = root.object.get(name) orelse return null;
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
}

pub fn stringArray(allocator: std.mem.Allocator, value: std.json.Value, key: []const u8) ![]const []const u8 {
    if (value != .object) return error.InvalidToolArguments;
    const array_value = value.object.get(key) orelse return allocator.alloc([]const u8, 0);
    if (array_value != .array) return error.InvalidToolArguments;

    var out = try allocator.alloc([]const u8, array_value.array.items.len);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |item| allocator.free(item);
        allocator.free(out);
    }

    for (array_value.array.items) |item| {
        if (item != .string) return error.InvalidToolArguments;
        out[n] = try allocator.dupe(u8, item.string);
        n += 1;
    }

    return out;
}

pub fn freeStringArray(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

test "agent tool args parses empty input as object and rejects invalid json" {
    const allocator = std.testing.allocator;
    var empty = parse(allocator, " \t\n").?;
    defer empty.deinit();
    try std.testing.expect(empty.value == .object);
    try std.testing.expect(parse(allocator, "{") == null);
}

test "agent tool args read typed scalar fields" {
    const allocator = std.testing.allocator;
    var parsed = parse(allocator,
        \\{"s":"text","empty":"","i":42,"zero":0,"idx":0,"b":true,"not_b":"true"}
    ).?;
    defer parsed.deinit();

    try std.testing.expectEqualStrings("text", string(parsed.value, "s").?);
    try std.testing.expectEqual(@as(?[]const u8, null), string(parsed.value, "empty"));
    try std.testing.expectEqual(@as(u32, 42), int(parsed.value, "i").?);
    try std.testing.expectEqual(@as(?u32, null), int(parsed.value, "zero"));
    try std.testing.expectEqual(@as(usize, 0), index(parsed.value, "idx").?);
    try std.testing.expectEqual(true, boolean(parsed.value, "b").?);
    try std.testing.expectEqual(@as(?bool, null), boolean(parsed.value, "not_b"));
}

test "agent tool args read and free string arrays" {
    const allocator = std.testing.allocator;
    var parsed = parse(allocator,
        \\{"args":["hello","world"]}
    ).?;
    defer parsed.deinit();

    const values = try stringArray(allocator, parsed.value, "args");
    defer freeStringArray(allocator, values);

    try std.testing.expectEqual(@as(usize, 2), values.len);
    try std.testing.expectEqualStrings("hello", values[0]);
    try std.testing.expectEqualStrings("world", values[1]);
}

test "agent tool args reject non-string array items" {
    const allocator = std.testing.allocator;
    var parsed = parse(allocator,
        \\{"args":["ok",1]}
    ).?;
    defer parsed.deinit();

    try std.testing.expectError(error.InvalidToolArguments, stringArray(allocator, parsed.value, "args"));
}
