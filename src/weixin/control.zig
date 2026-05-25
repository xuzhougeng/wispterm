//! Boundary between WeChat routing and the live Phantty surfaces. The real
//! vtable is supplied by controller.zig; tests supply a fake.
const std = @import("std");

pub const Surface = struct { id: [16]u8, title: []const u8 };

pub const OpenResult = enum { opened, no_profile, failed, offline, timeout };

pub const Control = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        is_connected: *const fn (ctx: *anyopaque) bool,
        find_ai_surface: *const fn (ctx: *anyopaque) ?Surface,
        find_terminal_surface: *const fn (ctx: *anyopaque) ?Surface,
        open_ai_agent: *const fn (ctx: *anyopaque, timeout_ms: u32) OpenResult,
        send_input: *const fn (ctx: *anyopaque, surface_id: [16]u8, bytes: []const u8) bool,
        latest_transcript: *const fn (ctx: *anyopaque) []const u8,
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
    pub fn sendInput(self: Control, surface_id: [16]u8, bytes: []const u8) bool {
        return self.vtable.send_input(self.ctx, surface_id, bytes);
    }
    pub fn latestTranscript(self: Control) []const u8 {
        return self.vtable.latest_transcript(self.ctx);
    }
};
