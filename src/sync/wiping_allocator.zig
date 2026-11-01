//! An allocator that zeroes memory before handing it back. A sync run decrypts
//! password-store secrets into its arena; putting this under the arena means
//! every page holding them is wiped when the run ends, without tracking each
//! plaintext buffer by hand.
const std = @import("std");

pub const WipingAllocator = struct {
    child: std.mem.Allocator,

    pub fn allocator(self: *WipingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *WipingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *WipingAllocator = @ptrCast(@alignCast(ctx));
        if (new_len < memory.len) std.crypto.secureZero(u8, memory[new_len..]);
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    /// Never move: a moved block would leave an unwiped copy behind.
    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *WipingAllocator = @ptrCast(@alignCast(ctx));
        std.crypto.secureZero(u8, memory);
        self.child.rawFree(memory, alignment, ret_addr);
    }

    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };
};

test "wiping allocator backs an arena and frees cleanly" {
    var wiping = WipingAllocator{ .child = std.testing.allocator };
    var arena = std.heap.ArenaAllocator.init(wiping.allocator());
    defer arena.deinit();
    const a = arena.allocator();
    const secret = try a.dupe(u8, "hunter2");
    try std.testing.expectEqualStrings("hunter2", secret);
    var list: std.ArrayListUnmanaged(u8) = .empty;
    for (0..10_000) |_| try list.append(a, 'x');
    try std.testing.expectEqual(@as(usize, 10_000), list.items.len);
}
