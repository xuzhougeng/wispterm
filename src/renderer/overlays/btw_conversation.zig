//! State and layout for the temporary `/btw` conversation overlay.
//! Rendering stays in the overlay facade; the conversation itself is a normal
//! assistant Session so input, streaming, and Markdown behavior stay shared.

const std = @import("std");

pub const Layout = struct {
    chat_x: f32,
    chat_w: f32,
    banner_top_px: f32,
    banner_h: f32,
    chat_top_px: f32,
};

pub const State = struct {
    session: ?*anyopaque = null,
    deinit_session: ?*const fn (*anyopaque) void = null,

    pub fn visible(self: *const State) bool {
        return self.session != null;
    }

    pub fn set(self: *State, session: *anyopaque, deinit_session: *const fn (*anyopaque) void) void {
        self.close();
        self.session = session;
        self.deinit_session = deinit_session;
    }

    pub fn close(self: *State) void {
        if (self.session) |session| if (self.deinit_session) |deinit_session| deinit_session(session);
        self.session = null;
        self.deinit_session = null;
    }
};

pub fn layout(window_width: f32, top_offset: f32) Layout {
    const margin = @round(@min(80.0, @max(16.0, window_width * 0.08)));
    const banner_h: f32 = 44;
    return .{
        .chat_x = margin,
        .chat_w = @max(1.0, window_width - margin * 2),
        .banner_top_px = top_offset + 16,
        .banner_h = banner_h,
        .chat_top_px = top_offset + 16 + banner_h,
    };
}

test "btw overlay layout keeps a usable chat width" {
    const narrow = layout(240, 36);
    try std.testing.expectEqual(@as(f32, 19), narrow.chat_x);
    try std.testing.expectEqual(@as(f32, 202), narrow.chat_w);

    const wide = layout(1600, 36);
    try std.testing.expectEqual(@as(f32, 80), wide.chat_x);
    try std.testing.expectEqual(@as(f32, 1440), wide.chat_w);
    try std.testing.expectEqual(narrow.banner_top_px + narrow.banner_h, narrow.chat_top_px);
}
