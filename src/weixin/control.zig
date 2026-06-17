//! Boundary between WeChat routing and the live WispTerm surfaces. The real
//! vtable is supplied by controller.zig; tests supply a fake.
const std = @import("std");
const types = @import("types.zig");

pub const Surface = struct { id: [16]u8, title: []const u8 };

/// A single AI conversation as seen by the WeChat bridge: a dedicated AI-chat
/// tab or a terminal tab's Copilot sidebar. Uses fixed inline buffers so the
/// whole struct is a POD value that marshals across the UI-thread boundary with
/// no allocation (mirrors ai_chat.Session's title_buf style).
pub const Conversation = struct {
    title_buf: [128]u8 = undefined,
    title_len: usize = 0,
    model_buf: [64]u8 = undefined,
    model_len: usize = 0,
    cwd_buf: [256]u8 = undefined,
    cwd_len: usize = 0,
    busy: bool = false,
    is_copilot: bool = false,
    is_current: bool = false,

    pub fn title(self: *const Conversation) []const u8 {
        return self.title_buf[0..self.title_len];
    }
    pub fn model(self: *const Conversation) []const u8 {
        return self.model_buf[0..self.model_len];
    }
    pub fn cwd(self: *const Conversation) []const u8 {
        return self.cwd_buf[0..self.cwd_len];
    }
    pub fn setTitle(self: *Conversation, s: []const u8) void {
        self.title_len = copyClamp(&self.title_buf, s);
    }
    pub fn setModel(self: *Conversation, s: []const u8) void {
        self.model_len = copyClamp(&self.model_buf, s);
    }
    pub fn setCwd(self: *Conversation, s: []const u8) void {
        self.cwd_len = copyClamp(&self.cwd_buf, s);
    }
};

/// A bounded list of conversations (one per tab; tabs are capped at 32).
pub const ConversationList = struct {
    items: [32]Conversation = [_]Conversation{.{}} ** 32,
    count: usize = 0,

    pub fn slice(self: *const ConversationList) []const Conversation {
        return self.items[0..self.count];
    }
};

/// Copy `s` into `buf`, clamped to fit and never splitting a UTF-8 sequence.
/// Returns the number of bytes written.
fn copyClamp(buf: []u8, s: []const u8) usize {
    var n = @min(buf.len, s.len);
    // s[n] is read only when n < s.len (second clause), so this never goes OOB.
    while (n > 0 and n < s.len and (s[n] & 0xC0) == 0x80) : (n -= 1) {}
    @memcpy(buf[0..n], s[0..n]);
    return n;
}

pub const OpenResult = enum { opened, no_profile, unknown_profile, failed, offline, timeout };

/// Outcome of sendInput. `busy` is AI-surface only: a chat request is already
/// inflight, so the message was rejected rather than silently swallowed.
pub const SendResult = enum { ok, offline, busy };

pub const SwitchModelResult = enum { switched, no_ai, no_profile, unknown_profile, failed, offline };

pub const Control = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        is_connected: *const fn (ctx: *anyopaque) bool,
        find_ai_surface: *const fn (ctx: *anyopaque) ?Surface,
        find_terminal_surface: *const fn (ctx: *anyopaque) ?Surface,
        open_ai_agent: *const fn (ctx: *anyopaque, timeout_ms: u32) OpenResult,
        open_ai_agent_profile: *const fn (ctx: *anyopaque, profile_name: []const u8, timeout_ms: u32) OpenResult,
        model_profiles: *const fn (ctx: *anyopaque, buf: []u8) []const u8,
        switch_ai_profile: *const fn (ctx: *anyopaque, profile_name: []const u8) SwitchModelResult,
        send_input: *const fn (ctx: *anyopaque, surface_id: [16]u8, bytes: []const u8, reply_context: ?types.ReplyContext) SendResult,
        latest_transcript: *const fn (ctx: *anyopaque) []const u8,
        ai_approval_pending: *const fn (ctx: *anyopaque) bool,
        resolve_ai_approval: *const fn (ctx: *anyopaque, approve: bool) bool,
        /// Writes the effective agent working directory into `buf` and returns
        /// the slice; empty when no working dir is configured. UI-thread backed.
        inbound_file_dir: *const fn (ctx: *anyopaque, buf: []u8) []const u8,
        /// Fill `out` with every open AI conversation (dedicated AI-chat tabs and
        /// terminal-tab Copilot sidebars), in tab order. UI-thread backed.
        list_ai_conversations: *const fn (ctx: *anyopaque, out: *ConversationList) void,
        /// Pin the Nth conversation (0-based, same order as list_ai_conversations).
        /// On success fills `out` and returns true; false if out of range.
        pin_ai_conversation_by_index: *const fn (ctx: *anyopaque, idx0: usize, out: *Conversation) bool,
    };

    pub fn isConnected(self: Control) bool {
        return self.vtable.is_connected(self.ctx);
    }
    pub fn findAiSurface(self: Control) ?Surface {
        return self.vtable.find_ai_surface(self.ctx);
    }
    pub fn findTerminalSurface(self: Control) ?Surface {
        return self.vtable.find_terminal_surface(self.ctx);
    }
    pub fn openAiAgent(self: Control, timeout_ms: u32) OpenResult {
        return self.vtable.open_ai_agent(self.ctx, timeout_ms);
    }
    pub fn openAiAgentProfile(self: Control, profile_name: []const u8, timeout_ms: u32) OpenResult {
        return self.vtable.open_ai_agent_profile(self.ctx, profile_name, timeout_ms);
    }
    pub fn modelProfiles(self: Control, buf: []u8) []const u8 {
        return self.vtable.model_profiles(self.ctx, buf);
    }
    pub fn switchAiProfile(self: Control, profile_name: []const u8) SwitchModelResult {
        return self.vtable.switch_ai_profile(self.ctx, profile_name);
    }
    pub fn sendInput(self: Control, surface_id: [16]u8, bytes: []const u8, reply_context: ?types.ReplyContext) SendResult {
        return self.vtable.send_input(self.ctx, surface_id, bytes, reply_context);
    }
    pub fn latestTranscript(self: Control) []const u8 {
        return self.vtable.latest_transcript(self.ctx);
    }
    pub fn aiApprovalPending(self: Control) bool {
        return self.vtable.ai_approval_pending(self.ctx);
    }
    pub fn resolveAiApproval(self: Control, approve: bool) bool {
        return self.vtable.resolve_ai_approval(self.ctx, approve);
    }
    pub fn inboundFileDir(self: Control, buf: []u8) []const u8 {
        return self.vtable.inbound_file_dir(self.ctx, buf);
    }
    pub fn listAiConversations(self: Control, out: *ConversationList) void {
        self.vtable.list_ai_conversations(self.ctx, out);
    }
    pub fn pinAiConversationByIndex(self: Control, idx0: usize, out: *Conversation) bool {
        return self.vtable.pin_ai_conversation_by_index(self.ctx, idx0, out);
    }
};

const t = std.testing;

test "inboundFileDir forwards to the vtable and copies into the caller buffer" {
    const Fake = struct {
        fn is_connected(_: *anyopaque) bool {
            return true;
        }
        fn find_ai_surface(_: *anyopaque) ?Surface {
            return null;
        }
        fn find_terminal_surface(_: *anyopaque) ?Surface {
            return null;
        }
        fn open_ai_agent(_: *anyopaque, _: u32) OpenResult {
            return .offline;
        }
        fn open_ai_agent_profile(_: *anyopaque, _: []const u8, _: u32) OpenResult {
            return .offline;
        }
        fn model_profiles(_: *anyopaque, _: []u8) []const u8 {
            return "";
        }
        fn switch_ai_profile(_: *anyopaque, _: []const u8) SwitchModelResult {
            return .offline;
        }
        fn send_input(_: *anyopaque, _: [16]u8, _: []const u8, _: ?types.ReplyContext) SendResult {
            return .offline;
        }
        fn latest_transcript(_: *anyopaque) []const u8 {
            return "";
        }
        fn ai_approval_pending(_: *anyopaque) bool {
            return false;
        }
        fn resolve_ai_approval(_: *anyopaque, _: bool) bool {
            return false;
        }
        fn inbound_file_dir(_: *anyopaque, buf: []u8) []const u8 {
            const dir = "/tmp/proj";
            @memcpy(buf[0..dir.len], dir);
            return buf[0..dir.len];
        }
        fn list_ai_conversations(_: *anyopaque, out: *ConversationList) void {
            out.count = 0;
        }
        fn pin_ai_conversation_by_index(_: *anyopaque, _: usize, _: *Conversation) bool {
            return false;
        }
        var dummy: u8 = 0;
        fn iface() Control {
            return .{ .ctx = &dummy, .vtable = &.{
                .is_connected = is_connected,
                .find_ai_surface = find_ai_surface,
                .find_terminal_surface = find_terminal_surface,
                .open_ai_agent = open_ai_agent,
                .open_ai_agent_profile = open_ai_agent_profile,
                .model_profiles = model_profiles,
                .switch_ai_profile = switch_ai_profile,
                .send_input = send_input,
                .latest_transcript = latest_transcript,
                .ai_approval_pending = ai_approval_pending,
                .resolve_ai_approval = resolve_ai_approval,
                .inbound_file_dir = inbound_file_dir,
                .list_ai_conversations = list_ai_conversations,
                .pin_ai_conversation_by_index = pin_ai_conversation_by_index,
            } };
        }
    };

    var buf: [512]u8 = undefined;
    try t.expectEqualStrings("/tmp/proj", Fake.iface().inboundFileDir(&buf));
}

test "Conversation setters clamp on UTF-8 boundaries" {
    var c: Conversation = .{};
    try t.expectEqualStrings("", c.title());

    c.setTitle("Claude");
    try t.expectEqualStrings("Claude", c.title());

    c.setModel("glm-5.2");
    try t.expectEqualStrings("glm-5.2", c.model());

    // A 3-byte CJK char must never be split when it overflows the buffer.
    var big: [400]u8 = undefined;
    var i: usize = 0;
    while (i + 3 <= big.len) : (i += 3) {
        big[i] = 0xE4;
        big[i + 1] = 0xBD;
        big[i + 2] = 0xA0; // "你"
    }
    c.setTitle(big[0..i]);
    try t.expect(c.title().len <= 128);
    try t.expect(std.unicode.utf8ValidateSlice(c.title()));
}

test "ConversationList slice reflects count" {
    var list: ConversationList = .{};
    try t.expectEqual(@as(usize, 0), list.slice().len);
    list.items[0].setTitle("A");
    list.items[1].setTitle("B");
    list.count = 2;
    try t.expectEqual(@as(usize, 2), list.slice().len);
    try t.expectEqualStrings("B", list.slice()[1].title());
}
