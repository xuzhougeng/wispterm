//! tmux pane I/O bridge.
//!
//! Owns the controller side of each pane's virtual PTY (the other end of a
//! `Pty.openVirtual` pair, whose `pty` end feeds a `Surface.initVirtual`
//! surface). Backs the Phase 2 `session.PaneSink` — pane `%output` is written
//! to the matching controller, where the pane's Surface reads it via its normal
//! `ReadThread` (render path unchanged) — and drains pane keystrokes
//! (controller → `Session.sendKeys`).
//!
//! Surface-agnostic: it touches only virtual controllers and the `Session`, so it is
//! unit-testable with bare `Pty.openVirtual` pairs (see `pane_io_test.zig`).
//! Phase 3c/3d pair each controller's other end with a real Surface and poll
//! all controllers alongside the ssh stream.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Pty = @import("../platform/pty.zig").Pty;
const session = @import("session.zig");

pub const PaneMap = struct {
    alloc: Allocator,
    panes: std.ArrayListUnmanaged(Pane) = .empty,
    /// Drain scratch for pumpKeystrokes. The pump is single-threaded (the
    /// controller loop), so one shared buffer is safe.
    read_buf: [4096]u8 = undefined,

    pub const Pane = struct {
        id: usize,
        controller: Pty.VirtualController,
        /// Borrowed pointer to this pane's `*Surface` (owned by the SplitTree
        /// that holds it; the bridge sets it via `setSurface`). Stored as an
        /// opaque pointer so `pane.zig` stays Surface-free and unit-testable.
        /// `removePane`/`deinit` never touch it — the tree owns the ref.
        surface: ?*anyopaque = null,
        /// Bytes of a UTF-8 sequence left incomplete at the end of the last
        /// read. `sendKeys` encodes codepoints, so a character split across
        /// two 4096-byte reads (a large CJK or emoji paste) must be held back
        /// and joined with the next read, not sent as stray bytes.
        key_carry: [3]u8 = undefined,
        key_carry_len: u8 = 0,
    };

    pub fn init(alloc: Allocator) PaneMap {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *PaneMap) void {
        for (self.panes.items) |*p| p.controller.deinit();
        self.panes.deinit(self.alloc);
    }

    /// Register a pane and take ownership of its controller side.
    /// `removePane`/`deinit` close it, which gives the pane's Surface an EOF.
    pub fn addPane(self: *PaneMap, id: usize, controller: Pty.VirtualController) Allocator.Error!void {
        try self.panes.append(self.alloc, .{ .id = id, .controller = controller });
    }

    pub fn find(self: *PaneMap, id: usize) ?*Pane {
        for (self.panes.items) |*p| {
            if (p.id == id) return p;
        }
        return null;
    }

    /// Attach a borrowed `*Surface` (as an opaque pointer) to a registered
    /// pane. No-op if the pane is unknown. The bridge owns the lifecycle; this
    /// map never refs/unrefs/frees it.
    pub fn setSurface(self: *PaneMap, id: usize, surface: *anyopaque) void {
        if (self.find(id)) |p| p.surface = surface;
    }

    /// Reverse lookup: the pane id whose borrowed surface pointer matches.
    pub fn findIdBySurface(self: *PaneMap, surface: *anyopaque) ?usize {
        for (self.panes.items) |p| {
            if (p.surface) |s| if (s == surface) return p.id;
        }
        return null;
    }

    /// Drop a pane and close its controller. Closing the controller end
    /// gives the pane's Surface an EOF on its next read, so its ReadThread
    /// marks the surface exited. No-op if the pane is unknown.
    pub fn removePane(self: *PaneMap, id: usize) void {
        var i: usize = 0;
        while (i < self.panes.items.len) : (i += 1) {
            if (self.panes.items[i].id == id) {
                self.panes.items[i].controller.deinit();
                _ = self.panes.orderedRemove(i);
                return;
            }
        }
    }

    /// A `session.PaneSink` that delivers `%output` bytes to each pane's
    /// controller. Output for an unknown pane is dropped.
    pub fn sink(self: *PaneMap) session.PaneSink {
        return .{ .ctx = self, .writeFn = writeImpl };
    }

    /// Non-blocking drain: forward any keystrokes the panes' Surfaces have
    /// written into their virtual PTYs as hex `send-keys` on the Session's
    /// command queue. Intended to be called from the controller loop after a
    /// poll; safe to call when nothing is pending. A `read` of 0 (the Surface
    /// closed its end) stops draining that pane — its removal is driven by the
    /// layout reconcile, not here.
    pub fn pumpKeystrokes(self: *PaneMap, s: *session.Session) Allocator.Error!void {
        for (self.panes.items) |*p| {
            while (p.controller.inputAvailable()) {
                const carried: usize = p.key_carry_len;
                @memcpy(self.read_buf[0..carried], p.key_carry[0..carried]);
                const n = p.controller.readInput(self.read_buf[carried..]) orelse break;
                if (n == 0) break;
                const total = carried + n;
                const complete = completeUtf8PrefixLen(self.read_buf[0..total]);
                p.key_carry_len = @intCast(total - complete);
                @memcpy(p.key_carry[0..p.key_carry_len], self.read_buf[complete..total]);
                if (complete > 0) try s.sendKeys(p.id, self.read_buf[0..complete]);
            }
        }
    }

    /// Length of the longest prefix of `bytes` that does not end inside a
    /// UTF-8 sequence. Only a genuinely incomplete trailing sequence (a lead
    /// byte whose continuation bytes have not arrived yet) is held back;
    /// malformed input is passed through unchanged.
    fn completeUtf8PrefixLen(bytes: []const u8) usize {
        var back: usize = 0;
        while (back < 3 and back < bytes.len) : (back += 1) {
            const idx = bytes.len - 1 - back;
            const b = bytes[idx];
            if ((b & 0xC0) == 0x80) continue; // continuation byte: keep looking for its lead
            const need = std.unicode.utf8ByteSequenceLength(b) catch return bytes.len;
            return if (need > back + 1) idx else bytes.len;
        }
        return bytes.len;
    }

    fn writeImpl(ctx: *anyopaque, pane_id: usize, bytes: []const u8) void {
        const self: *PaneMap = @ptrCast(@alignCast(ctx));
        const pane = self.find(pane_id) orelse return;
        pane.controller.writeOutput(bytes);
    }
};

// ----- tests -----

test "setSurface stores a borrowed pointer and findIdBySurface reverses it" {
    var sentinels: [4]u8 = undefined;
    const a: *anyopaque = @ptrCast(&sentinels[0]);
    const b: *anyopaque = @ptrCast(&sentinels[1]);

    var map = PaneMap.init(std.testing.allocator);
    // Free only the backing array, NOT via map.deinit(): these are fake
    // controllers that are intentionally never closed.
    defer map.panes.deinit(map.alloc);

    try map.panes.append(map.alloc, .{ .id = 1, .controller = Pty.VirtualController.invalidForTest() });
    try map.panes.append(map.alloc, .{ .id = 2, .controller = Pty.VirtualController.invalidForTest() });

    map.setSurface(1, a);
    map.setSurface(2, b);

    try std.testing.expectEqual(@as(?usize, 1), map.findIdBySurface(a));
    try std.testing.expectEqual(@as(?usize, 2), map.findIdBySurface(b));
    try std.testing.expectEqual(a, map.find(1).?.surface.?);

    const c: *anyopaque = @ptrCast(&sentinels[2]);
    try std.testing.expectEqual(@as(?usize, null), map.findIdBySurface(c));
}

test "completeUtf8PrefixLen holds back only an incomplete trailing sequence" {
    const f = PaneMap.completeUtf8PrefixLen;
    try std.testing.expectEqual(@as(usize, 3), f("abc"));
    try std.testing.expectEqual(@as(usize, 0), f(""));
    // "a" + first two bytes of U+4F60 (E4 BD A0): hold the partial character.
    try std.testing.expectEqual(@as(usize, 1), f("a\xE4\xBD"));
    try std.testing.expectEqual(@as(usize, 1), f("a\xE4"));
    try std.testing.expectEqual(@as(usize, 4), f("a\xE4\xBD\xA0"));
    // First three bytes of a four-byte emoji.
    try std.testing.expectEqual(@as(usize, 0), f("\xF0\x9F\x98"));
    try std.testing.expectEqual(@as(usize, 4), f("\xF0\x9F\x98\x80"));
    // Stray continuation bytes are not a pending sequence.
    try std.testing.expectEqual(@as(usize, 2), f("\x80\x80"));
}
