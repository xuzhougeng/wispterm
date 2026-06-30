//! Pure state + logic for the "Quick Configure AI" overlay: the single-key form
//! state, the DeepSeek constants, and the two-profile upsert. No I/O, no threads,
//! no drawing — those live in overlays.zig / quick_verify.zig so this stays
//! unit-tested in the fast suite.
const std = @import("std");
const profile_codec = @import("profile_codec.zig");

const AiProfile = profile_codec.AiProfile;

pub const KEY_FIELD_MAX: usize = 256;

// Form rows: 0 = open register page, 1 = open tutorial page, 2 = API key field, 3 = Verify.
pub const ROW_OPEN_REGISTER: usize = 0;
pub const ROW_OPEN_TUTORIAL: usize = 1;
pub const ROW_KEY: usize = 2;
pub const ROW_VERIFY: usize = 3;
pub const ROW_COUNT: usize = 4;

pub const REGISTER_URL = "https://platform.deepseek.com";
// Placeholder: wiki has no DeepSeek section yet. Change this one line when it does.
pub const TUTORIAL_URL = "https://github.com/xuzhougeng/wispterm/wiki/AI-Copilot-zh";
pub const BASE_URL = "https://api.deepseek.com";

pub const MAIN_PROFILE_NAME = "DeepSeek";
pub const MAIN_MODEL = "deepseek-v4-pro";
pub const SUB_PROFILE_NAME = "DeepSeek Flash";
pub const SUB_MODEL = "deepseek-v4-flash";

pub const VerifyStatus = enum { idle, verifying, ok, empty, invalid, network };

pub const State = struct {
    key_buf: [KEY_FIELD_MAX]u8 = undefined,
    key_len: usize = 0,
    focus: usize = ROW_KEY,
    status: VerifyStatus = .idle,

    pub fn reset(self: *State) void {
        self.key_len = 0;
        self.focus = ROW_KEY;
        self.status = .idle;
    }

    pub fn key(self: *const State) []const u8 {
        return self.key_buf[0..self.key_len];
    }

    pub fn append(self: *State, bytes: []const u8) void {
        for (bytes) |b| {
            if (self.key_len >= KEY_FIELD_MAX) return; // truncate, no overflow
            self.key_buf[self.key_len] = b;
            self.key_len += 1;
        }
    }

    pub fn backspace(self: *State) void {
        if (self.key_len == 0) return;
        var n = self.key_len - 1;
        while (n > 0 and (self.key_buf[n] & 0xC0) == 0x80) : (n -= 1) {} // back one UTF-8 codepoint
        self.key_len = n;
    }

    pub fn focusNextRow(self: *State) void {
        if (self.focus < ROW_COUNT - 1) self.focus += 1;
    }

    pub fn focusPrevRow(self: *State) void {
        if (self.focus > 0) self.focus -= 1;
    }
};

fn indexByName(profiles: []const AiProfile, count: usize, name: []const u8) ?usize {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (std.mem.eql(u8, profile_codec.aiProfileField(&profiles[i], .name), name)) return i;
    }
    return null;
}

fn writeConnectionFields(p: *AiProfile, name: []const u8, model: []const u8, api_key: []const u8) void {
    profile_codec.setProfileDefault(p, .name, name);
    profile_codec.setProfileDefault(p, .base_url, BASE_URL);
    profile_codec.setProfileDefault(p, .api_key, api_key);
    profile_codec.setProfileDefault(p, .model, model);
    profile_codec.setProfileDefault(p, .protocol, "chat_completions");
}

fn fillNewProfileDefaults(p: *AiProfile) void {
    profile_codec.setProfileDefault(p, .thinking, "enabled");
    profile_codec.setProfileDefault(p, .reasoning_effort, "high");
    profile_codec.setProfileDefault(p, .stream, "false");
    profile_codec.setProfileDefault(p, .agent, "true");
    profile_codec.setProfileDefault(p, .max_tokens, "8192");
    profile_codec.setProfileDefault(p, .vision, "off");
}

fn upsertOne(profiles: []AiProfile, count: usize, name: []const u8, model: []const u8, api_key: []const u8) usize {
    if (indexByName(profiles, count, name)) |idx| {
        writeConnectionFields(&profiles[idx], name, model, api_key); // keep other fields as-is
        return count;
    }
    if (count >= profiles.len) return count; // store full — skip rather than overflow
    profiles[count] = .{};
    writeConnectionFields(&profiles[count], name, model, api_key);
    fillNewProfileDefaults(&profiles[count]);
    return count + 1;
}

/// Upsert the two DeepSeek quick-config profiles by name into `profiles[0..count]`.
/// Existing same-named profiles have only their connection fields refreshed; new
/// ones are appended with documented defaults. Returns the new count.
pub fn upsertProfiles(profiles: []AiProfile, count: usize, api_key: []const u8) usize {
    var n = upsertOne(profiles, count, MAIN_PROFILE_NAME, MAIN_MODEL, api_key);
    n = upsertOne(profiles, n, SUB_PROFILE_NAME, SUB_MODEL, api_key);
    return n;
}

test "State: append, key, backspace, reset" {
    var s = State{};
    s.append("sk-abc");
    try std.testing.expectEqualStrings("sk-abc", s.key());
    s.backspace();
    try std.testing.expectEqualStrings("sk-ab", s.key());
    s.reset();
    try std.testing.expectEqualStrings("", s.key());
    try std.testing.expectEqual(ROW_KEY, s.focus);
    try std.testing.expectEqual(VerifyStatus.idle, s.status);
}

test "State: append truncates at KEY_FIELD_MAX without overflow" {
    var s = State{};
    const big = "x" ** (KEY_FIELD_MAX + 40);
    s.append(big);
    try std.testing.expectEqual(KEY_FIELD_MAX, s.key().len);
}

test "State: backspace drops a whole multibyte codepoint" {
    var s = State{};
    s.append("a\u{4f60}"); // "a你"
    s.backspace();
    try std.testing.expectEqualStrings("a", s.key());
}

test "State: focus navigation clamps within rows" {
    var s = State{};
    s.focus = ROW_OPEN_REGISTER;
    s.focusPrevRow();
    try std.testing.expectEqual(ROW_OPEN_REGISTER, s.focus);
    s.focusNextRow();
    s.focusNextRow();
    s.focusNextRow();
    try std.testing.expectEqual(ROW_VERIFY, s.focus);
    s.focusNextRow();
    try std.testing.expectEqual(ROW_VERIFY, s.focus);
}

test "upsertProfiles: appends two profiles into an empty store" {
    const profiles = try std.testing.allocator.alloc(AiProfile, 8);
    defer std.testing.allocator.free(profiles);
    const n = upsertProfiles(profiles, 0, "sk-key-1");
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("DeepSeek", profile_codec.aiProfileField(&profiles[0], .name));
    try std.testing.expectEqualStrings("deepseek-v4-pro", profile_codec.aiProfileField(&profiles[0], .model));
    try std.testing.expectEqualStrings("https://api.deepseek.com", profile_codec.aiProfileField(&profiles[0], .base_url));
    try std.testing.expectEqualStrings("sk-key-1", profile_codec.aiProfileField(&profiles[0], .api_key));
    try std.testing.expectEqualStrings("chat_completions", profile_codec.aiProfileField(&profiles[0], .protocol));
    try std.testing.expectEqualStrings("DeepSeek Flash", profile_codec.aiProfileField(&profiles[1], .name));
    try std.testing.expectEqualStrings("deepseek-v4-flash", profile_codec.aiProfileField(&profiles[1], .model));
    try std.testing.expectEqualStrings("true", profile_codec.aiProfileField(&profiles[1], .agent));
}

test "upsertProfiles: updates an existing same-named profile in place" {
    const profiles = try std.testing.allocator.alloc(AiProfile, 8);
    defer std.testing.allocator.free(profiles);
    // Seed an existing "DeepSeek" profile with an old key and a custom system prompt.
    profiles[0] = .{};
    profile_codec.setProfileDefault(&profiles[0], .name, "DeepSeek");
    profile_codec.setProfileDefault(&profiles[0], .api_key, "sk-old");
    profile_codec.setProfileDefault(&profiles[0], .system_prompt, "keep me");
    const n = upsertProfiles(profiles, 1, "sk-new");
    try std.testing.expectEqual(@as(usize, 2), n); // DeepSeek updated, DeepSeek Flash appended
    try std.testing.expectEqualStrings("sk-new", profile_codec.aiProfileField(&profiles[0], .api_key));
    try std.testing.expectEqualStrings("deepseek-v4-pro", profile_codec.aiProfileField(&profiles[0], .model));
    try std.testing.expectEqualStrings("keep me", profile_codec.aiProfileField(&profiles[0], .system_prompt)); // preserved
}
