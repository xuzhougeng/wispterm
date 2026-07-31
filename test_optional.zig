const std = @import("std");
pub fn main() void {
    var buf: [16]u8 = .{0} ** 16;
    const ptr: *?u8 = @ptrCast(@alignCast(&buf[0]));
    std.debug.print("zeroed ?u8 is null: {}\n", .{ptr.* == null});
    std.debug.print("zeroed ?u8 raw bytes: 0x{x} 0x{x}\n", .{buf[0], buf[1]});
    std.debug.print("sizeOf(?u8) = {}\n", .{@sizeOf(?u8)});

    // Set to non-null value 3
    ptr.* = 3;
    std.debug.print("after set to 3: bytes = 0x{x} 0x{x}\n", .{buf[0], buf[1]});

    // Set to null
    ptr.* = null;
    std.debug.print("after set to null: bytes = 0x{x} 0x{x}\n", .{buf[0], buf[1]});

    // Set to non-null value 0
    ptr.* = 0;
    std.debug.print("after set to 0 (non-null): bytes = 0x{x} 0x{x}\n", .{buf[0], buf[1]});
    std.debug.print("is null after set to 0: {}\n", .{ptr.* == null});
}
