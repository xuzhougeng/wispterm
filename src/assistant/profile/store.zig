const std = @import("std");
const profile_codec = @import("../../renderer/overlays/profile_codec.zig");
const platform_dirs = @import("../../platform/dirs.zig");
const platform_atomic_file = @import("../../platform/atomic_file.zig");

pub const magpie = @import("magpie.zig");

pub const PERSONAL_PROFILE_MAX: usize = 16;

/// The UI reserves one additional slot for a read-only Magpie profile.
pub fn loadAvailableProfiles(allocator: std.mem.Allocator, out: []profile_codec.AiProfile) usize {
    const count = loadProfiles(allocator, out[0..@min(out.len, PERSONAL_PROFILE_MAX)]);
    const managed = magpie.load(allocator) orelse return count;
    return magpie.append(managed, out, count);
}

pub const AI_PROFILES_HEADER = "# WispTerm AI Chat profiles. Fields are hex encoded: name, base_url, api_key, model, system_prompt, thinking, reasoning_effort, stream, agent, protocol, max_tokens, vision, command.\n";

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
    return saveProfilesKeepingNew(allocator, profiles, null);
}

/// Save a cached list without dropping profiles that appeared on disk since it
/// was loaded (a sync or another window wrote them). `known` = hashes of every
/// name the cache has seen (`profile_codec.profileNameHash`); null overwrites.
pub fn saveProfilesKeepingNew(allocator: std.mem.Allocator, profiles: []const profile_codec.AiProfile, known: ?[]const u64) bool {
    const path = profilesPath(allocator) catch return false;
    defer allocator.free(path);
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch return false;
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    out.appendSlice(allocator, AI_PROFILES_HEADER) catch return false;
    for (profiles) |*profile| {
        if (profile.managed_by_magpie) continue;
        appendProfileLine(allocator, &out, profile) catch return false;
    }
    if (known) |seen| {
        const disk = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => @as([]u8, &.{}),
            else => return false,
        };
        defer allocator.free(disk);
        const names = allocator.alloc([]const u8, profiles.len) catch return false;
        defer allocator.free(names);
        var name_count: usize = 0;
        for (profiles) |*profile| {
            if (profile.managed_by_magpie) continue;
            names[name_count] = profile_codec.aiProfileField(profile, .name);
            name_count += 1;
        }
        profile_codec.appendNewDiskLines(allocator, &out, disk, names[0..name_count], seen) catch return false;
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

test "Magpie profile never persists and saving preserves other disk profiles" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir);
    platform_dirs.setTestConfigDirForCurrentThread(dir);
    defer platform_dirs.clearTestConfigDirForCurrentThread();
    var personal = profile_codec.AiProfile{};
    profile_codec.setProfileDefault(&personal, .name, "Personal");
    profile_codec.setProfileDefault(&personal, .model, "local-model");
    var other = profile_codec.AiProfile{};
    profile_codec.setProfileDefault(&other, .name, "Added elsewhere");
    profile_codec.setProfileDefault(&other, .model, "other-model");
    var managed = profile_codec.AiProfile{ .managed_by_magpie = true };
    profile_codec.setProfileDefault(&managed, .name, "Magpie");
    profile_codec.setProfileDefault(&managed, .api_key, "must-not-be-saved");
    try std.testing.expect(saveProfiles(a, &.{ personal, other }));
    const known = [_]u64{profile_codec.profileNameHash("Personal")};
    try std.testing.expect(saveProfilesKeepingNew(a, &.{ personal, managed }, &known));
    var reloaded: [3]profile_codec.AiProfile = undefined;
    const count = loadProfiles(a, &reloaded);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("Personal", profile_codec.aiProfileField(&reloaded[0], .name));
    try std.testing.expectEqualStrings("Added elsewhere", profile_codec.aiProfileField(&reloaded[1], .name));
    try std.testing.expect(!reloaded[0].managed_by_magpie and !reloaded[1].managed_by_magpie);
    try std.testing.expect(saveProfiles(a, &.{ personal, managed }));
    try std.testing.expectEqual(@as(usize, 1), loadProfiles(a, &reloaded));
}
