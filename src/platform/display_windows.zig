const monitor_default_to_null: u32 = 0;

const Point = extern struct {
    x: i32,
    y: i32,
};

const HMONITOR = *opaque {};

pub const default_dpi: u32 = 96;

extern "user32" fn MonitorFromPoint(pt: Point, dwFlags: u32) callconv(.winapi) ?HMONITOR;

pub fn isPointOnAnyDisplay(x: i32, y: i32) bool {
    return MonitorFromPoint(.{ .x = x, .y = y }, monitor_default_to_null) != null;
}
