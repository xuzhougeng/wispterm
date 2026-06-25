//! Pure map from an SDL windowID (u32) to an opaque window pointer, so the
//! main-thread pump can route each event to the owning window's queues. Stored
//! as *anyopaque to avoid an import cycle with apprt/sdl.zig.
const std = @import("std");

const MAX_WINDOWS = 64;

pub const Registry = struct {
    const Entry = struct { id: u32, ptr: *anyopaque };
    entries: [MAX_WINDOWS]?Entry = [_]?Entry{null} ** MAX_WINDOWS,
    mutex: std.Thread.Mutex = .{},

    pub fn set(self: *Registry, id: u32, ptr: *anyopaque) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var free: ?usize = null;
        for (self.entries, 0..) |e, i| {
            if (e) |entry| {
                if (entry.id == id) {
                    self.entries[i] = .{ .id = id, .ptr = ptr };
                    return;
                }
            } else if (free == null) free = i;
        }
        if (free) |i| self.entries[i] = .{ .id = id, .ptr = ptr };
    }

    pub fn find(self: *Registry, id: u32) ?*anyopaque {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries) |e| if (e) |entry| {
            if (entry.id == id) return entry.ptr;
        };
        return null;
    }

    pub fn remove(self: *Registry, id: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries, 0..) |e, i| if (e) |entry| {
            if (entry.id == id) {
                self.entries[i] = null;
                return;
            }
        };
    }
};

test "register, find, and remove by id" {
    var reg = Registry{};
    var a: u8 = 1;
    var b: u8 = 2;
    reg.set(10, &a);
    reg.set(20, &b);
    try std.testing.expect(reg.find(10).? == @as(*anyopaque, &a));
    try std.testing.expect(reg.find(20).? == @as(*anyopaque, &b));
    try std.testing.expect(reg.find(30) == null);
    reg.remove(10);
    try std.testing.expect(reg.find(10) == null);
}
