const std = @import("std");
const profile_codec = @import("../../renderer/overlays/profile_codec.zig");
const platform_dirs = @import("../../platform/dirs.zig");
const platform_atomic_file = @import("../../platform/atomic_file.zig");

const AI_PROFILES_HEADER = "# WispTerm AI Chat profiles. Fields are hex encoded: name, base_url, api_key, model, system_prompt, thinking, reasoning_effort, stream, agent, protocol, max_tokens, vision, command.\n";

pub fn profilesPath(allocator: std.mem.Allocator) ![]const u8 {
    return platform_dirs.aiProfilesPath(allocator);
}

pub fn loadProfiles(allocator: std.mem.Allocator, out: []profile_codec.AiProfile) usize {
    const path = profilesPath(allocator) catch return 0;
    defer allocator.free(path);
    const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch return 0;
    defer allocator.free(content);
    return loadProfilesFromContent(content, out);
}

pub fn loadProfilesFromContent(content: []const u8, out: []profile_codec.AiProfile) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line_raw| {
        if (count >= out.len) break;
        const line = std.mem.trimRight(u8, line_raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        const profile = profile_codec.decodeAiProfileLine(line) orelse continue;
        out[count] = profile;
        count += 1;
    }
    return count;
}

pub fn saveProfiles(allocator: std.mem.Allocator, profiles: []const profile_codec.AiProfile) bool {
    const path = profilesPath(allocator) catch return false;
    defer allocator.free(path);
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch return false;
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    out.appendSlice(allocator, AI_PROFILES_HEADER) catch return false;
    for (profiles) |*profile| {
        appendProfileLine(allocator, &out, profile) catch return false;
    }
    platform_atomic_file.writeFileReplaceSafe(path, out.items) catch return false;
    return true;
}

pub fn appendProfileLine(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), profile: *const profile_codec.AiProfile) !void {
    for (0..profile_codec.AI_FIELD_COUNT) |i| {
        if (i > 0) try out.append(allocator, '\t');
        try appendHexField(allocator, out, profile.fields[i][0..profile.lens[i]]);
    }
    try out.append(allocator, '\n');
}

fn appendHexField(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |ch| {
        try out.append(allocator, hex[ch >> 4]);
        try out.append(allocator, hex[ch & 0x0f]);
    }
}

fn appendEncodedProfileForTest(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), fields: []const []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (fields, 0..) |field, idx| {
        if (idx > 0) try out.append(allocator, '\t');
        for (field) |ch| {
            try out.append(allocator, hex[ch >> 4]);
            try out.append(allocator, hex[ch & 0x0f]);
        }
    }
    try out.append(allocator, '\n');
}

test "assistant profile store: loadProfilesFromContent decodes bounded profiles" {
    var content: std.ArrayListUnmanaged(u8) = .empty;
    defer content.deinit(std.testing.allocator);
    try appendEncodedProfileForTest(std.testing.allocator, &content, &.{
        "one", "https://api.example.com", "key", "model", "sys",
    });
    try appendEncodedProfileForTest(std.testing.allocator, &content, &.{
        "two", "https://api.example.com", "key", "model-2", "sys",
    });

    var profiles: [1]profile_codec.AiProfile = undefined;
    const count = loadProfilesFromContent(content.items, &profiles);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualStrings("one", profile_codec.aiProfileField(&profiles[0], .name));
    try std.testing.expectEqualStrings("8192", profile_codec.aiProfileField(&profiles[0], .max_tokens));
}

test "assistant profile store: appendProfileLine writes all AI fields as hex" {
    var profile = profile_codec.AiProfile{};
    profile_codec.setProfileDefault(&profile, .name, "ai");
    profile_codec.setProfileDefault(&profile, .base_url, "https://api.example.com");
    profile_codec.setProfileDefault(&profile, .api_key, "key");
    profile_codec.setProfileDefault(&profile, .model, "model");
    profile_codec.setProfileDefault(&profile, .system_prompt, "sys");
    profile_codec.setProfileDefault(&profile, .thinking, "enabled");
    profile_codec.setProfileDefault(&profile, .reasoning_effort, "high");
    profile_codec.setProfileDefault(&profile, .stream, "false");
    profile_codec.setProfileDefault(&profile, .agent, "true");
    profile_codec.setProfileDefault(&profile, .protocol, "anthropic");
    profile_codec.setProfileDefault(&profile, .max_tokens, "4096");
    profile_codec.setProfileDefault(&profile, .vision, "on");

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try appendProfileLine(std.testing.allocator, &out, &profile);

    const decoded = profile_codec.decodeAiProfileLine(std.mem.trimRight(u8, out.items, "\n")) orelse return error.ExpectedProfile;
    try std.testing.expectEqualStrings("ai", profile_codec.aiProfileField(&decoded, .name));
    try std.testing.expectEqualStrings("4096", profile_codec.aiProfileField(&decoded, .max_tokens));
    try std.testing.expectEqualStrings("on", profile_codec.aiProfileField(&decoded, .vision));
}
