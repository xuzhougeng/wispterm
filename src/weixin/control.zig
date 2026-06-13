//! Boundary between WeChat routing and the live WispTerm surfaces. The real
//! vtable is supplied by controller.zig; tests supply a fake.
const std = @import("std");
const types = @import("types.zig");

pub const Surface = struct { id: [16]u8, title: []const u8 };

pub const OpenResult = enum { opened, no_profile, failed, offline, timeout };

/// Outcome of sendInput. `busy` is AI-surface only: a chat request is already
/// inflight, so the message was rejected rather than silently swallowed.
pub const SendResult = enum { ok, offline, busy };

pub const Control = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        is_connected: *const fn (ctx: *anyopaque) bool,
        find_ai_surface: *const fn (ctx: *anyopaque) ?Surface,
        find_terminal_surface: *const fn (ctx: *anyopaque) ?Surface,
        open_ai_agent: *const fn (ctx: *anyopaque, timeout_ms: u32) OpenResult,
        send_input: *const fn (ctx: *anyopaque, surface_id: [16]u8, bytes: []const u8, reply_context: ?types.ReplyContext) SendResult,
        latest_transcript: *const fn (ctx: *anyopaque) []const u8,
        ai_approval_pending: *const fn (ctx: *anyopaque) bool,
        resolve_ai_approval: *const fn (ctx: *anyopaque, approve: bool) bool,
        /// Writes the effective agent working directory into `buf` and returns
        /// the slice; empty when no working dir is configured. UI-thread backed.
        inbound_file_dir: *const fn (ctx: *anyopaque, buf: []u8) []const u8,
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
        var dummy: u8 = 0;
        fn iface() Control {
            return .{ .ctx = &dummy, .vtable = &.{
                .is_connected = is_connected,
                .find_ai_surface = find_ai_surface,
                .find_terminal_surface = find_terminal_surface,
                .open_ai_agent = open_ai_agent,
                .send_input = send_input,
                .latest_transcript = latest_transcript,
                .ai_approval_pending = ai_approval_pending,
                .resolve_ai_approval = resolve_ai_approval,
                .inbound_file_dir = inbound_file_dir,
            } };
        }
    };

    var buf: [512]u8 = undefined;
    try t.expectEqualStrings("/tmp/proj", Fake.iface().inboundFileDir(&buf));
}
