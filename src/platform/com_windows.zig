const std = @import("std");

pub const Apartment = struct {
    initialized: bool = false,
    ole32: ?std.os.windows.HMODULE = null,

    pub fn deinit(self: Apartment) void {
        if (self.initialized) {
            if (self.ole32) |h| {
                if (std.os.windows.kernel32.GetProcAddress(h, "CoUninitialize")) |f| {
                    const coUninitFn: *const fn () callconv(.winapi) void = @ptrCast(f);
                    coUninitFn();
                }
            }
        }
    }
};

pub fn initUiThread() Apartment {
    const ole32 = std.os.windows.kernel32.GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("ole32.dll"));
    if (ole32) |h| {
        if (std.os.windows.kernel32.GetProcAddress(h, "CoInitializeEx")) |f| {
            const coInitFn: *const fn (?*anyopaque, u32) callconv(.winapi) i32 = @ptrCast(f);
            const coinit_apartmentthreaded: u32 = 0x2;
            const hr = coInitFn(null, coinit_apartmentthreaded);
            return .{
                .initialized = hr >= 0,
                .ole32 = h,
            };
        }
    }
    return .{ .ole32 = ole32 };
}
