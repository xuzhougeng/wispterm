//! WeChat direct (embedded ilink) UI-thread control bridge.
//!
//! The weixin poller runs on its own thread, but tab state (tab.g_tabs etc.) is
//! threadlocal to the UI thread. So the Control vtable marshals each request to
//! the UI thread via SendMessage (.weixin_control), where handleControlRequest
//! reads/acts on tab state, mirroring the remote .remote_ai_input path.
//!
//! UNVERIFIED AT RUNTIME: cross-compiles to the Windows exe, but has not been run
//! (no Windows runtime / live WeChat here). AI progress follow-up timers remain
//! in the poller backlog; the UI control surface below exposes terminal writes
//! and AI transcript snapshots for that layer.

const std = @import("std");
const Surface = @import("../Surface.zig");
const ai_chat = @import("../ai_chat.zig");
const weixin_control = @import("../weixin/control.zig");
const weixin_types = @import("../weixin/types.zig");
const window_backend = @import("../platform/window_backend.zig");
const active_tab_state = @import("active_tab.zig");
const remote_sync = @import("remote_sync.zig");
const tab = @import("tab.zig");
const thread_message = @import("thread_message.zig");

pub const Host = struct {
    markUiDirty: *const fn () void,
    openDefaultAgentSession: *const fn () weixin_control.OpenResult,
    openAgentSessionProfile: *const fn ([]const u8) weixin_control.OpenResult,
    modelProfiles: *const fn (std.mem.Allocator) anyerror![]u8,
    switchSessionModelProfile: *const fn (*ai_chat.Session, []const u8) weixin_control.SwitchModelResult,
};

var g_weixin_ui_handle = std.atomic.Value(usize).init(0);
var g_weixin_ctx: u8 = 0;
var g_weixin_transcript_mutex: std.Thread.Mutex = .{};
var g_weixin_transcript_owned: []u8 = &.{};
/// The AI conversation WeChat is pinned to (independent of the on-screen active
/// tab). UI-thread-only - read/written exclusively inside handleControlRequest,
/// so no lock is needed. Cleared automatically when its conversation closes
/// (see weixinActiveAiTabIndex).
var g_weixin_pinned_session: ?*ai_chat.Session = null;

pub const WeixinRequest = struct {
    op: enum { find_ai, find_term, open_ai, open_ai_profile, model_profiles, switch_ai_profile, send_input, latest_transcript, ai_approval_pending, resolve_ai_approval, ai_question_option_count, resolve_ai_question, inbound_file_dir, list_conversations, pin_by_index },
    // operation inputs (valid for the duration of the synchronous call):
    surface_id: [16]u8 = [_]u8{0} ** 16, // send_input
    bytes: []const u8 = "", // send_input
    reply_context: ?weixin_types.ReplyContext = null, // send_input
    profile_name: []const u8 = "", // open_ai_profile / switch_ai_profile
    approve: bool = false, // resolve_ai_approval
    // resolve_ai_question input. A `.custom` reply borrows the caller's bytes,
    // which stay alive because dispatch is synchronous (SendMessage).
    question_reply: weixin_types.QuestionReply = .ignore,
    pin_index: usize = 0, // pin_by_index input
    conv_list_out: ?*weixin_control.ConversationList = null, // list_conversations output
    conv_one_out: ?*weixin_control.Conversation = null, // pin_by_index output
    // outputs filled by the UI-thread handler:
    found: bool = false,
    out_surface_id: [16]u8 = [_]u8{0} ** 16,
    open_result: weixin_control.OpenResult = .failed,
    switch_result: weixin_control.SwitchModelResult = .failed,
    sent: bool = false,
    busy: bool = false, // send_input: AI chat rejected the prompt (request inflight)
    option_count: usize = 0, // ai_question_option_count output
    transcript: []u8 = &.{},
    profiles: []u8 = &.{}, // model_profiles (heap, page_allocator)
    dir: []u8 = &.{}, // inbound_file_dir (heap, page_allocator)
};

pub fn setUiHandle(handle_bits: usize) void {
    g_weixin_ui_handle.store(handle_bits, .release);
}

/// The *ai_chat.Session a tab contributes as its AI conversation, or null:
/// a dedicated AI-chat tab's session, or a terminal tab's Copilot sidebar
/// session (once opened). A tab contributes at most one.
fn tabConversationSession(ts: *tab.TabState) ?*ai_chat.Session {
    if (ts.kind == .ai_chat) return ts.ai_chat_session;
    return ts.copilot_session;
}

/// Index of the AI-chat tab to target: the active tab if it is AI chat, else the
/// first AI-chat tab. UI-thread only (reads threadlocal tab state).
fn weixinActiveAiTabIndex() ?usize {
    // 1) Honor an explicit WeChat pin if its conversation is still open.
    //    Pointer identity only - never dereference a possibly-stale pointer.
    if (g_weixin_pinned_session) |pinned| {
        for (0..tab.g_tab_count) |i| {
            if (tab.g_tabs[i]) |ts| {
                if (tabConversationSession(ts) == pinned) return i;
            }
        }
        // The pinned conversation was closed: drop the stale pin and fall back.
        g_weixin_pinned_session = null;
    }
    // 2) Default (unchanged): the active tab if it is an AI-chat tab, else the
    //    first AI-chat tab. Copilot sidebars are reachable only via an explicit
    //    /switch pin, not the default.
    if (active_tab_state.g_active_tab < tab.g_tab_count) {
        if (tab.g_tabs[active_tab_state.g_active_tab]) |ts| {
            if (ts.kind == .ai_chat) return active_tab_state.g_active_tab;
        }
    }
    for (0..tab.g_tab_count) |i| {
        if (tab.g_tabs[i]) |ts| {
            if (ts.kind == .ai_chat) return i;
        }
    }
    return null;
}

fn weixinTabIndexFromSurfaceId(id: [16]u8) ?usize {
    if (!std.mem.eql(u8, id[0..6], "aichat")) return null;
    return std.fmt.parseInt(usize, id[6..16], 10) catch null;
}

fn weixinActiveTerminalSurface() ?*Surface {
    if (active_tab_state.g_active_tab < tab.g_tab_count) {
        if (tab.g_tabs[active_tab_state.g_active_tab]) |ts| {
            if (ts.kind == .terminal) {
                if (ts.focusedSurface()) |surface| return surface;
            }
        }
    }
    for (0..tab.g_tab_count) |i| {
        if (tab.g_tabs[i]) |ts| {
            if (ts.kind == .terminal) {
                if (ts.focusedSurface()) |surface| return surface;
            }
        }
    }
    return null;
}

fn weixinTerminalSurfaceFromId(id: [16]u8) ?*Surface {
    for (0..tab.g_tab_count) |tab_index| {
        const tab_state = tab.g_tabs[tab_index] orelse continue;
        if (tab_state.kind != .terminal) continue;
        var it = tab_state.tree.surfaces();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.surface.remote_id[0..], id[0..])) return entry.surface;
        }
    }
    return null;
}

/// Runs on the UI thread (dispatched from the window message pump).
pub fn handleControlRequest(req: *WeixinRequest, host: Host) void {
    switch (req.op) {
        .find_ai => {
            if (weixinActiveAiTabIndex()) |idx| {
                req.out_surface_id = remote_sync.remoteAiSurfaceId(idx);
                req.found = true;
            }
        },
        .find_term => {
            if (weixinActiveTerminalSurface()) |surface| {
                req.out_surface_id = surface.remote_id;
                req.found = true;
            }
        },
        .open_ai => {
            req.open_result = host.openDefaultAgentSession();
            if (req.open_result == .opened) host.markUiDirty();
        },
        .open_ai_profile => {
            req.open_result = host.openAgentSessionProfile(req.profile_name);
            if (req.open_result == .opened) host.markUiDirty();
        },
        .model_profiles => {
            req.profiles = host.modelProfiles(std.heap.page_allocator) catch return;
            req.found = true;
        },
        .switch_ai_profile => {
            const idx = weixinActiveAiTabIndex() orelse {
                req.switch_result = .no_ai;
                return;
            };
            const tab_state = tab.g_tabs[idx] orelse {
                req.switch_result = .no_ai;
                return;
            };
            const session = tabConversationSession(tab_state) orelse {
                req.switch_result = .no_ai;
                return;
            };
            req.switch_result = host.switchSessionModelProfile(session, req.profile_name);
            if (req.switch_result == .switched) host.markUiDirty();
        },
        .send_input => {
            if (weixinTabIndexFromSurfaceId(req.surface_id)) |idx| {
                if (idx >= tab.g_tab_count) return;
                const tab_state = tab.g_tabs[idx] orelse return;
                // copilot_session is unreachable here in practice: aichat{N} surface
                // IDs are only issued for .ai_chat tabs. The fallthrough keeps this
                // correct if the surface registry is ever extended to Copilot panes.
                const session = tabConversationSession(tab_state) orelse return;
                if (req.reply_context) |ctx| {
                    req.busy = !session.applyWeixinInput(req.bytes, ctx);
                } else {
                    session.applyRemoteInput(req.bytes);
                }
                host.markUiDirty();
                req.sent = true;
                return;
            }
            const surface = weixinTerminalSurfaceFromId(req.surface_id) orelse return;
            surface.queuePtyWrite(req.bytes);
            req.sent = true;
        },
        .latest_transcript => {
            const idx = weixinActiveAiTabIndex() orelse return;
            const tab_state = tab.g_tabs[idx] orelse return;
            const session = tabConversationSession(tab_state) orelse return;
            req.transcript = session.allocRemoteSnapshot(std.heap.page_allocator) catch return;
            req.found = true;
        },
        .ai_approval_pending => {
            const idx = weixinActiveAiTabIndex() orelse return;
            const tab_state = tab.g_tabs[idx] orelse return;
            const session = tabConversationSession(tab_state) orelse return;
            req.found = session.approvalView() != null;
        },
        .resolve_ai_approval => {
            const idx = weixinActiveAiTabIndex() orelse return;
            const tab_state = tab.g_tabs[idx] orelse return;
            const session = tabConversationSession(tab_state) orelse return;
            req.sent = session.resolveApprovalExternal(req.approve);
            if (req.sent) host.markUiDirty();
        },
        .ai_question_option_count => {
            const idx = weixinActiveAiTabIndex() orelse return;
            const tab_state = tab.g_tabs[idx] orelse return;
            const session = tabConversationSession(tab_state) orelse return;
            if (session.questionView()) |view| {
                req.option_count = view.options.len;
                req.found = true;
            }
        },
        .resolve_ai_question => {
            const idx = weixinActiveAiTabIndex() orelse return;
            const tab_state = tab.g_tabs[idx] orelse return;
            const session = tabConversationSession(tab_state) orelse return;
            req.sent = switch (req.question_reply) {
                .option => |i| session.resolveQuestionOption(i),
                .custom => |txt| session.resolveQuestionCustom(txt),
                .ignore => false,
            };
            if (req.sent) host.markUiDirty();
        },
        .inbound_file_dir => {
            // Per-conversation working dir if set, else the global default.
            if (weixinActiveAiTabIndex()) |idx| {
                if (tab.g_tabs[idx]) |tab_state| {
                    if (tabConversationSession(tab_state)) |session| {
                        if (session.workingDirOverride()) |w| {
                            req.dir = std.heap.page_allocator.dupe(u8, w) catch return;
                            req.found = true;
                            return;
                        }
                    }
                }
            }
            if (ai_chat.defaultWorkingDir()) |w| {
                req.dir = std.heap.page_allocator.dupe(u8, w) catch return;
                req.found = true;
            }
        },
        .list_conversations => {
            const out = req.conv_list_out orelse return;
            // Also clears g_weixin_pinned_session as a side effect if the pin is
            // stale (its conversation closed) - listing then correctly marks no
            // row current and drops the dead pin.
            const cur = weixinActiveAiTabIndex();
            var n: usize = 0;
            for (0..tab.g_tab_count) |i| {
                if (n >= out.items.len) break;
                const ts = tab.g_tabs[i] orelse continue;
                const session = tabConversationSession(ts) orelse continue;
                var c = &out.items[n];
                c.* = .{};
                c.is_copilot = (ts.kind != .ai_chat);
                c.is_current = (cur != null and cur.? == i);
                c.busy = session.request_inflight;
                c.setTitle(ts.getTitle());
                c.setModel(session.model());
                if (session.workingDirOverride()) |w| c.setCwd(w);
                n += 1;
            }
            out.count = n;
            req.found = true;
        },
        .pin_by_index => {
            const out = req.conv_one_out orelse return;
            var n: usize = 0;
            for (0..tab.g_tab_count) |i| {
                const ts = tab.g_tabs[i] orelse continue;
                const session = tabConversationSession(ts) orelse continue;
                if (n == req.pin_index) {
                    g_weixin_pinned_session = session;
                    out.* = .{};
                    out.is_copilot = (ts.kind != .ai_chat);
                    out.is_current = true;
                    out.busy = session.request_inflight;
                    out.setTitle(ts.getTitle());
                    out.setModel(session.model());
                    if (session.workingDirOverride()) |w| out.setCwd(w);
                    req.found = true;
                    return;
                }
                n += 1;
            }
        },
    }
}

/// Marshals a request to the UI thread synchronously. Returns false if no UI
/// window is currently published. Called from the poller thread.
fn weixinDispatch(req: *WeixinRequest) bool {
    const bits = g_weixin_ui_handle.load(.acquire);
    if (bits == 0) return false;
    const handle = window_backend.nativeHandleFromBits(bits) orelse return false;
    _ = thread_message.sendPointer(handle, .weixin_control, @intFromPtr(req));
    return true;
}

fn wxIsConnected(_: *anyopaque) bool {
    return g_weixin_ui_handle.load(.acquire) != 0;
}

fn wxFindAiSurface(_: *anyopaque) ?weixin_control.Surface {
    var req = WeixinRequest{ .op = .find_ai };
    if (!weixinDispatch(&req) or !req.found) return null;
    return .{ .id = req.out_surface_id, .title = "" };
}

fn wxFindTerminalSurface(_: *anyopaque) ?weixin_control.Surface {
    var req = WeixinRequest{ .op = .find_term };
    if (!weixinDispatch(&req) or !req.found) return null;
    return .{ .id = req.out_surface_id, .title = "" };
}

fn wxOpenAiAgent(_: *anyopaque, _: u32) weixin_control.OpenResult {
    var req = WeixinRequest{ .op = .open_ai };
    if (!weixinDispatch(&req)) return .offline;
    return req.open_result;
}

fn wxOpenAiAgentProfile(_: *anyopaque, profile_name: []const u8, _: u32) weixin_control.OpenResult {
    var req = WeixinRequest{ .op = .open_ai_profile, .profile_name = profile_name };
    if (!weixinDispatch(&req)) return .offline;
    return req.open_result;
}

fn wxModelProfiles(_: *anyopaque, buf: []u8) []const u8 {
    var req = WeixinRequest{ .op = .model_profiles };
    if (!weixinDispatch(&req) or !req.found) return "";
    defer if (req.profiles.len != 0) std.heap.page_allocator.free(req.profiles);
    const n = @min(req.profiles.len, buf.len);
    @memcpy(buf[0..n], req.profiles[0..n]);
    return buf[0..n];
}

fn wxSwitchAiProfile(_: *anyopaque, profile_name: []const u8) weixin_control.SwitchModelResult {
    var req = WeixinRequest{ .op = .switch_ai_profile, .profile_name = profile_name };
    if (!weixinDispatch(&req)) return .offline;
    return req.switch_result;
}

fn wxSendInput(_: *anyopaque, surface_id: [16]u8, bytes: []const u8, reply_context: ?weixin_types.ReplyContext) weixin_control.SendResult {
    var req = WeixinRequest{ .op = .send_input, .surface_id = surface_id, .bytes = bytes, .reply_context = reply_context };
    if (!weixinDispatch(&req) or !req.sent) return .offline;
    return if (req.busy) .busy else .ok;
}

fn wxTranscript(_: *anyopaque) []const u8 {
    var req = WeixinRequest{ .op = .latest_transcript };
    if (!weixinDispatch(&req) or !req.found) return "";

    g_weixin_transcript_mutex.lock();
    defer g_weixin_transcript_mutex.unlock();
    if (g_weixin_transcript_owned.len != 0) std.heap.page_allocator.free(g_weixin_transcript_owned);
    g_weixin_transcript_owned = req.transcript;
    return g_weixin_transcript_owned;
}

fn wxInboundFileDir(_: *anyopaque, buf: []u8) []const u8 {
    var req = WeixinRequest{ .op = .inbound_file_dir };
    if (!weixinDispatch(&req) or !req.found or req.dir.len == 0) return "";
    defer std.heap.page_allocator.free(req.dir);
    const n = @min(req.dir.len, buf.len);
    @memcpy(buf[0..n], req.dir[0..n]);
    return buf[0..n];
}

fn wxListAiConversations(_: *anyopaque, out: *weixin_control.ConversationList) void {
    out.count = 0;
    var req = WeixinRequest{ .op = .list_conversations, .conv_list_out = out };
    _ = weixinDispatch(&req);
    // On dispatch failure (no UI window) out stays count=0, which is correct.
}

fn wxPinAiConversationByIndex(_: *anyopaque, idx0: usize, out: *weixin_control.Conversation) bool {
    var req = WeixinRequest{ .op = .pin_by_index, .pin_index = idx0, .conv_one_out = out };
    if (!weixinDispatch(&req)) return false;
    return req.found;
}

fn wxAiApprovalPending(_: *anyopaque) bool {
    var req = WeixinRequest{ .op = .ai_approval_pending };
    if (!weixinDispatch(&req)) return false;
    return req.found;
}

fn wxAiQuestionOptionCount(_: *anyopaque) usize {
    var req = WeixinRequest{ .op = .ai_question_option_count };
    if (!weixinDispatch(&req) or !req.found) return 0;
    return req.option_count;
}

fn wxResolveAiQuestion(_: *anyopaque, reply: weixin_types.QuestionReply) bool {
    var req = WeixinRequest{ .op = .resolve_ai_question, .question_reply = reply };
    if (!weixinDispatch(&req)) return false;
    return req.sent;
}

fn wxResolveAiApproval(_: *anyopaque, approve: bool) bool {
    var req = WeixinRequest{ .op = .resolve_ai_approval, .approve = approve };
    if (!weixinDispatch(&req)) return false;
    return req.sent;
}

const weixin_vtable = weixin_control.Control.VTable{
    .is_connected = wxIsConnected,
    .find_ai_surface = wxFindAiSurface,
    .find_terminal_surface = wxFindTerminalSurface,
    .open_ai_agent = wxOpenAiAgent,
    .open_ai_agent_profile = wxOpenAiAgentProfile,
    .model_profiles = wxModelProfiles,
    .switch_ai_profile = wxSwitchAiProfile,
    .send_input = wxSendInput,
    .latest_transcript = wxTranscript,
    .ai_approval_pending = wxAiApprovalPending,
    .resolve_ai_approval = wxResolveAiApproval,
    .ai_question_option_count = wxAiQuestionOptionCount,
    .resolve_ai_question = wxResolveAiQuestion,
    .inbound_file_dir = wxInboundFileDir,
    .list_ai_conversations = wxListAiConversations,
    .pin_ai_conversation_by_index = wxPinAiConversationByIndex,
};

/// The Control the weixin controller drives. Backed by process-global state, so
/// the dummy ctx is unused.
pub fn control() weixin_control.Control {
    return .{ .ctx = &g_weixin_ctx, .vtable = &weixin_vtable };
}

pub fn clearTranscriptCache() void {
    g_weixin_transcript_mutex.lock();
    defer g_weixin_transcript_mutex.unlock();
    if (g_weixin_transcript_owned.len != 0) std.heap.page_allocator.free(g_weixin_transcript_owned);
    g_weixin_transcript_owned = &.{};
}
