const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cDefine("_DEFAULT_SOURCE", "1");
    @cInclude("time.h");
});

/// Local timezone offset in seconds east of UTC for the current moment, or 0
/// (treat as UTC) on any failure. Computed by reinterpreting the broken-down
/// local time as UTC and subtracting the real UTC instant. Query once and cache
/// on the Session; the value is stable for a session's lifetime in practice.
pub fn localOffsetSeconds() i32 {
    const now: c.time_t = @intCast(std.time.timestamp());
    var local_tm: c.struct_tm = std.mem.zeroes(c.struct_tm);
    if (builtin.os.tag == .windows) {
        // MinGW (x86_64-windows-gnu) exposes neither localtime_r nor a linkable
        // localtime_s, so use non-reentrant localtime and copy the result out
        // immediately, then reinterpret it as UTC via _mkgmtime.
        const tm_ptr = c.localtime(&now) orelse return 0;
        local_tm = tm_ptr.*;
        const as_utc = c._mkgmtime(&local_tm);
        if (as_utc == @as(c.time_t, -1)) return 0;
        return @intCast(@as(i64, @intCast(as_utc)) - @as(i64, @intCast(now)));
    } else {
        if (c.localtime_r(&now, &local_tm) == null) return 0;
        const as_utc = c.timegm(&local_tm);
        if (as_utc == @as(c.time_t, -1)) return 0;
        return @intCast(@as(i64, @intCast(as_utc)) - @as(i64, @intCast(now)));
    }
}
