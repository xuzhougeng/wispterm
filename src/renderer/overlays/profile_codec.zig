//! Pure SSH/AI profile codec: fixed-buffer profile records plus the
//! tab-separated, hex-encoded line decode used to persist them. Extracted from
//! renderer/overlays.zig so the parsing / round-trip / legacy-field rules are
//! unit-tested in the fast suite without the AppWindow / Surface / GL graph.
//! overlays.zig keeps the form state, persistence I/O, and drawing, and
//! re-exports these symbols so its call sites are unchanged.
const std = @import("std");
const ai_chat_protocol = @import("../../assistant/conversation/protocol.zig");
const ssh_connection = @import("../../ssh/connection.zig");

pub const SSH_FIELD_COUNT = 8;
pub const SSH_FIELD_MAX = ssh_connection.IDENTITY_FILE_MAX;
pub const AI_FIELD_COUNT = 12;
pub const AI_FIELD_MAX = 8192;

pub const SshField = enum(usize) {
    name = 0,
    ip = 1,
    user = 2,
    password = 3,
    port = 4,
    proxy_jump = 5,
    auth_method = 6,
    identity_file = 7,
};

pub const AiField = enum(usize) {
    name = 0,
    base_url = 1,
    api_key = 2,
    model = 3,
    system_prompt = 4,
    thinking = 5,
    reasoning_effort = 6,
    stream = 7,
    agent = 8,
    protocol = 9,
    max_tokens = 10,
    vision = 11,
};

pub const SshProfile = struct {
    fields: [SSH_FIELD_COUNT][SSH_FIELD_MAX]u8 = undefined,
    lens: [SSH_FIELD_COUNT]usize = .{0} ** SSH_FIELD_COUNT,
};

pub const AiProfile = struct {
    fields: [AI_FIELD_COUNT][AI_FIELD_MAX]u8 = undefined,
    lens: [AI_FIELD_COUNT]usize = .{0} ** AI_FIELD_COUNT,
};

pub fn profileField(profile: *const SshProfile, field: SshField) []const u8 {
    const idx: usize = @intFromEnum(field);
    return profile.fields[idx][0..profile.lens[idx]];
}

pub fn copySshProfileField(profile: *SshProfile, field: SshField, value: []const u8) void {
    const idx: usize = @intFromEnum(field);
    const len = @min(value.len, SSH_FIELD_MAX);
    @memcpy(profile.fields[idx][0..len], value[0..len]);
    profile.lens[idx] = len;
}

pub fn makeSshProfile(name: []const u8, host: []const u8, user: []const u8, port: []const u8) SshProfile {
    var profile = SshProfile{};
    copySshProfileField(&profile, .name, name);
    copySshProfileField(&profile, .ip, host);
    copySshProfileField(&profile, .user, user);
    copySshProfileField(&profile, .port, port);
    copySshProfileField(&profile, .auth_method, ssh_connection.SshAuthMethod.credentials.fieldValue());
    return profile;
}

pub fn defaultSshFormAuthMethod() []const u8 {
    return ssh_connection.SshAuthMethod.password.fieldValue();
}

pub fn aiProfileField(profile: *const AiProfile, field: AiField) []const u8 {
    const idx: usize = @intFromEnum(field);
    return profile.fields[idx][0..profile.lens[idx]];
}

pub fn setProfileDefault(profile: *AiProfile, field: AiField, value: []const u8) void {
    const idx: usize = @intFromEnum(field);
    const len = @min(value.len, AI_FIELD_MAX);
    @memcpy(profile.fields[idx][0..len], value[0..len]);
    profile.lens[idx] = len;
}

pub fn hexValue(ch: u8) ?u8 {
    if (ch >= '0' and ch <= '9') return ch - '0';
    if (ch >= 'a' and ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' and ch <= 'F') return ch - 'A' + 10;
    return null;
}

pub fn decodeHexFieldToSlice(value: []const u8, out: []u8) ?usize {
    if (value.len % 2 != 0) return null;
    const len = @min(value.len / 2, out.len);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const hi = hexValue(value[i * 2]) orelse return null;
        const lo = hexValue(value[i * 2 + 1]) orelse return null;
        out[i] = (hi << 4) | lo;
    }
    return len;
}

pub fn decodeHexField(value: []const u8, out: *[SSH_FIELD_MAX]u8) ?usize {
    return decodeHexFieldToSlice(value, out[0..]);
}

/// Decode one tab-separated, hex-encoded SSH profile line into an `SshProfile`.
/// Returns null only when a present field contains malformed hex; trailing
/// fields absent from the line are left empty so profiles written by older
/// builds (with fewer fields) still load after the schema grows.
pub fn decodeSshProfileLine(line: []const u8) ?SshProfile {
    var profile = SshProfile{};
    var parts = std.mem.splitScalar(u8, line, '\t');
    var field_idx: usize = 0;
    while (field_idx < SSH_FIELD_COUNT) : (field_idx += 1) {
        const part = parts.next() orelse break;
        const decoded = decodeHexField(part, &profile.fields[field_idx]) orelse return null;
        profile.lens[field_idx] = decoded;
    }
    if (profile.lens[@intFromEnum(SshField.auth_method)] == 0) {
        const legacy_method: ssh_connection.SshAuthMethod = if (profile.lens[@intFromEnum(SshField.password)] > 0)
            .password
        else
            .credentials;
        copySshProfileField(&profile, .auth_method, legacy_method.fieldValue());
    }
    return profile;
}

pub fn decodeAiProfileLine(line: []const u8) ?AiProfile {
    var profile = AiProfile{};
    var parts = std.mem.splitScalar(u8, line, '\t');
    var field_idx: usize = 0;
    while (field_idx < AI_FIELD_COUNT) : (field_idx += 1) {
        const part = parts.next() orelse break;
        const decoded = decodeHexFieldToSlice(part, profile.fields[field_idx][0..]) orelse return null;
        profile.lens[field_idx] = decoded;
    }
    if (field_idx < 5) return null;
    if (profile.lens[@intFromEnum(AiField.thinking)] == 0) setProfileDefault(&profile, .thinking, ai_chat_protocol.DEFAULT_THINKING);
    if (profile.lens[@intFromEnum(AiField.reasoning_effort)] == 0) setProfileDefault(&profile, .reasoning_effort, ai_chat_protocol.DEFAULT_REASONING_EFFORT);
    if (profile.lens[@intFromEnum(AiField.stream)] == 0) setProfileDefault(&profile, .stream, ai_chat_protocol.DEFAULT_STREAM);
    if (profile.lens[@intFromEnum(AiField.agent)] == 0) setProfileDefault(&profile, .agent, ai_chat_protocol.DEFAULT_AGENT);
    if (profile.lens[@intFromEnum(AiField.protocol)] == 0) setProfileDefault(&profile, .protocol, ai_chat_protocol.DEFAULT_PROTOCOL);
    if (profile.lens[@intFromEnum(AiField.max_tokens)] == 0) setProfileDefault(&profile, .max_tokens, ai_chat_protocol.DEFAULT_MAX_TOKENS);
    if (profile.lens[@intFromEnum(AiField.vision)] == 0) setProfileDefault(&profile, .vision, ai_chat_protocol.DEFAULT_VISION);
    return profile;
}

fn testEncodeProfileLine(buf: []u8, fields: []const []const u8) []const u8 {
    const hex = "0123456789ABCDEF";
    var len: usize = 0;
    for (fields, 0..) |field, fi| {
        if (fi > 0) {
            buf[len] = '\t';
            len += 1;
        }
        for (field) |ch| {
            buf[len] = hex[ch >> 4];
            buf[len + 1] = hex[ch & 0x0f];
            len += 2;
        }
    }
    return buf[0..len];
}

test "overlays: SSH profile line decode preserves all fields including proxy jump" {
    var buf: [512]u8 = undefined;
    const line = testEncodeProfileLine(&buf, &.{ "Prod", "10.0.0.9", "root", "secret", "2222", "admin@jump.test:22" });
    const profile = decodeSshProfileLine(line) orelse return error.ExpectedProfile;
    try std.testing.expectEqualStrings("Prod", profileField(&profile, .name));
    try std.testing.expectEqualStrings("10.0.0.9", profileField(&profile, .ip));
    try std.testing.expectEqualStrings("root", profileField(&profile, .user));
    try std.testing.expectEqualStrings("secret", profileField(&profile, .password));
    try std.testing.expectEqualStrings("2222", profileField(&profile, .port));
    try std.testing.expectEqualStrings("admin@jump.test:22", profileField(&profile, .proxy_jump));
    try std.testing.expectEqualStrings("password", profileField(&profile, .auth_method));
    try std.testing.expectEqualStrings("", profileField(&profile, .identity_file));
}

test "overlays: SSH profile line decode accepts legacy lines without a proxy jump field" {
    // Profiles saved before ProxyJump existed have only the first five fields.
    // They must still load, with an empty proxy jump, rather than being dropped.
    var buf: [512]u8 = undefined;
    const legacy = testEncodeProfileLine(&buf, &.{ "Old", "10.0.0.1", "user", "", "22" });
    const profile = decodeSshProfileLine(legacy) orelse return error.ExpectedProfile;
    try std.testing.expectEqualStrings("Old", profileField(&profile, .name));
    try std.testing.expectEqualStrings("10.0.0.1", profileField(&profile, .ip));
    try std.testing.expectEqualStrings("22", profileField(&profile, .port));
    try std.testing.expectEqualStrings("", profileField(&profile, .proxy_jump));
    try std.testing.expectEqualStrings("credentials", profileField(&profile, .auth_method));
    try std.testing.expectEqualStrings("", profileField(&profile, .identity_file));
}

test "overlays: SSH profile line decode preserves auth method and identity file" {
    var buf: [1024]u8 = undefined;
    const line = testEncodeProfileLine(&buf, &.{
        "KeyBox",
        "key.example",
        "alice",
        "",
        "2222",
        "jump.example",
        "key",
        "C:/Users/alice/.ssh/id_ed25519",
    });
    const profile = decodeSshProfileLine(line) orelse return error.ExpectedProfile;
    try std.testing.expectEqualStrings("key", profileField(&profile, .auth_method));
    try std.testing.expectEqualStrings("C:/Users/alice/.ssh/id_ed25519", profileField(&profile, .identity_file));
}

test "overlays: SSH profile line decode defaults auth method for legacy password profile" {
    var buf: [1024]u8 = undefined;
    const legacy = testEncodeProfileLine(&buf, &.{ "Old", "10.0.0.1", "user", "secret", "22", "" });
    const profile = decodeSshProfileLine(legacy) orelse return error.ExpectedProfile;
    try std.testing.expectEqualStrings("password", profileField(&profile, .auth_method));
    try std.testing.expectEqualStrings("", profileField(&profile, .identity_file));
}

test "overlays: SSH profile line decode defaults auth method for legacy credential profile" {
    var buf: [1024]u8 = undefined;
    const legacy = testEncodeProfileLine(&buf, &.{ "Old", "10.0.0.1", "user", "", "22", "" });
    const profile = decodeSshProfileLine(legacy) orelse return error.ExpectedProfile;
    try std.testing.expectEqualStrings("credentials", profileField(&profile, .auth_method));
    try std.testing.expectEqualStrings("", profileField(&profile, .identity_file));
}

test "overlays: new SSH form defaults to password auth" {
    try std.testing.expectEqualStrings("password", defaultSshFormAuthMethod());
}

test "overlays: SSH profile line decode rejects malformed hex" {
    try std.testing.expect(decodeSshProfileLine("not-hex\tzz") == null);
}

test "overlays: AI profile line decode round-trips all fields including max_tokens" {
    var buf: [1024]u8 = undefined;
    const line = testEncodeProfileLine(&buf, &.{
        "Claude", "https://api.anthropic.com", "sk-key", "claude-x",
        "sys",    "enabled",                   "high",   "false",
        "true",   "anthropic",                 "4096",
    });
    const profile = decodeAiProfileLine(line) orelse return error.ExpectedProfile;
    try std.testing.expectEqualStrings("Claude", aiProfileField(&profile, .name));
    try std.testing.expectEqualStrings("anthropic", aiProfileField(&profile, .protocol));
    try std.testing.expectEqualStrings("4096", aiProfileField(&profile, .max_tokens));
}

test "overlays: AI profile line decode defaults max_tokens for legacy 10-field profiles" {
    // Profiles written before max_tokens existed have only the first ten fields
    // (indices 0-9). They must still load, with the new trailing field defaulted
    // to 8192, and the existing positional fields staying aligned.
    var buf: [1024]u8 = undefined;
    const legacy = testEncodeProfileLine(&buf, &.{
        "Legacy", "https://api.anthropic.com", "sk-key", "claude-x",
        "sys",    "enabled",                   "high",   "false",
        "true",   "anthropic",
    });
    const profile = decodeAiProfileLine(legacy) orelse return error.ExpectedProfile;
    try std.testing.expectEqualStrings("Legacy", aiProfileField(&profile, .name));
    try std.testing.expectEqualStrings("anthropic", aiProfileField(&profile, .protocol));
    try std.testing.expectEqualStrings("8192", aiProfileField(&profile, .max_tokens));
}

test "overlays: AI profile line decode defaults max_tokens when the field is empty" {
    var buf: [1024]u8 = undefined;
    const line = testEncodeProfileLine(&buf, &.{
        "Empty", "https://api.anthropic.com", "sk-key", "claude-x",
        "sys",   "enabled",                   "high",   "false",
        "true",  "anthropic",                 "",
    });
    const profile = decodeAiProfileLine(line) orelse return error.ExpectedProfile;
    try std.testing.expectEqualStrings("8192", aiProfileField(&profile, .max_tokens));
}

test "overlays: AI profile line decode round-trips the vision field" {
    var buf: [1024]u8 = undefined;
    const line = testEncodeProfileLine(&buf, &.{
        "Vision", "https://api.openai.com", "sk-key", "gpt-4o",
        "sys",    "enabled",                "high",   "false",
        "true",   "chat_completions",       "8192",   "on",
    });
    const profile = decodeAiProfileLine(line) orelse return error.ExpectedProfile;
    try std.testing.expectEqualStrings("Vision", aiProfileField(&profile, .name));
    try std.testing.expectEqualStrings("8192", aiProfileField(&profile, .max_tokens));
    try std.testing.expectEqualStrings("on", aiProfileField(&profile, .vision));
}

test "overlays: AI profile line decode defaults vision off for legacy 11-field profiles" {
    // Profiles written before the vision field existed have only the first eleven
    // fields (indices 0-10). They must still load, with vision defaulted off and the
    // existing positional fields staying aligned.
    var buf: [1024]u8 = undefined;
    const legacy = testEncodeProfileLine(&buf, &.{
        "Legacy", "https://api.anthropic.com", "sk-key", "claude-x",
        "sys",    "enabled",                   "high",   "false",
        "true",   "anthropic",                 "4096",
    });
    const profile = decodeAiProfileLine(legacy) orelse return error.ExpectedProfile;
    try std.testing.expectEqualStrings("4096", aiProfileField(&profile, .max_tokens));
    try std.testing.expectEqualStrings("off", aiProfileField(&profile, .vision));
}
