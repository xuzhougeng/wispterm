//! Boundary between the ctl server thread and the live WispTerm surfaces.
//! The real vtable is supplied by AppWindow (cross-platform: get_text/send_text
//! pin the surface through surface_registry; list_panes reads a UI-published
//! JSON buffer). Tests supply a fake. Mirrors weixin/control.zig.
const std = @import("std");

pub const Control = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Allocator-owned panes JSON object, or null if not yet published.
        list_panes: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!?[]u8,
        /// Allocator-owned snapshot text for `id`, or null if no live surface.
        get_text: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, id: []const u8, recent: ?u32) anyerror!?[]u8,
        /// Queue raw bytes to surface `id`. Returns false if no live surface.
        send_text: *const fn (ctx: *anyopaque, id: []const u8, data: []const u8) bool,
        /// Allocator-owned overlay/UI semantic-state JSON object, or null if not
        /// yet published. Complements list_panes (topology) with the overlay layer.
        ui_state: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!?[]u8,
    };

    pub fn listPanes(self: Control, allocator: std.mem.Allocator) anyerror!?[]u8 {
        return self.vtable.list_panes(self.ctx, allocator);
    }
    pub fn getText(self: Control, allocator: std.mem.Allocator, id: []const u8, recent: ?u32) anyerror!?[]u8 {
        return self.vtable.get_text(self.ctx, allocator, id, recent);
    }
    pub fn sendText(self: Control, id: []const u8, data: []const u8) bool {
        return self.vtable.send_text(self.ctx, id, data);
    }
    pub fn uiState(self: Control, allocator: std.mem.Allocator) anyerror!?[]u8 {
        return self.vtable.ui_state(self.ctx, allocator);
    }
};

const t = std.testing;

test "Control forwards to the vtable" {
    const Fake = struct {
        fn list_panes(_: *anyopaque, a: std.mem.Allocator) anyerror!?[]u8 {
            return try a.dupe(u8, "{\"tabs\":[]}");
        }
        fn get_text(_: *anyopaque, a: std.mem.Allocator, id: []const u8, _: ?u32) anyerror!?[]u8 {
            if (std.mem.eql(u8, id, "live")) return try a.dupe(u8, "hello");
            return null;
        }
        fn send_text(_: *anyopaque, id: []const u8, _: []const u8) bool {
            return std.mem.eql(u8, id, "live");
        }
        fn ui_state(_: *anyopaque, a: std.mem.Allocator) anyerror!?[]u8 {
            return try a.dupe(u8, "{\"activeOverlay\":\"none\"}");
        }
        var dummy: u8 = 0;
        fn iface() Control {
            return .{ .ctx = &dummy, .vtable = &.{ .list_panes = list_panes, .get_text = get_text, .send_text = send_text, .ui_state = ui_state } };
        }
    };
    const c = Fake.iface();
    const panes = (try c.listPanes(t.allocator)).?;
    defer t.allocator.free(panes);
    try t.expectEqualStrings("{\"tabs\":[]}", panes);
    const ui = (try c.uiState(t.allocator)).?;
    defer t.allocator.free(ui);
    try t.expectEqualStrings("{\"activeOverlay\":\"none\"}", ui);
    const text = (try c.getText(t.allocator, "live", null)).?;
    defer t.allocator.free(text);
    try t.expectEqualStrings("hello", text);
    try t.expect((try c.getText(t.allocator, "gone", null)) == null);
    try t.expect(c.sendText("live", "x"));
    try t.expect(!c.sendText("gone", "x"));
}
