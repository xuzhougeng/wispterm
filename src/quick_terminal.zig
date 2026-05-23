const std = @import("std");

pub const HOTKEY_ID: i32 = 0x5154; // "QT"
pub const VK_OEM_3: u32 = 0xC0; // US keyboard backquote / tilde key.

pub const Hotkey = struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    win: bool = false,
    vk: u32,
};

pub const Position = enum {
    top,
};

pub const Settings = struct {
    enabled: bool = true,
    position: Position = .top,
    height_percent: u8 = 50,
    hotkey: Hotkey = .{ .ctrl = true, .vk = VK_OEM_3 },
};

pub const WorkArea = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

pub const Frame = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const FrameRequest = struct {
    work_area: WorkArea,
    position: Position = .top,
    height_percent: u8 = 50,
};

pub fn defaultSettings() Settings {
    return .{};
}

pub fn calculateFrame(request: FrameRequest) Frame {
    const work_width = @max(1, request.work_area.right - request.work_area.left);
    const work_height = @max(1, request.work_area.bottom - request.work_area.top);
    const percent: i32 = @intCast(@min(100, @max(10, request.height_percent)));

    return switch (request.position) {
        .top => .{
            .x = request.work_area.left,
            .y = request.work_area.top,
            .width = work_width,
            .height = @max(1, @divTrunc(work_height * percent, 100)),
        },
    };
}

test "quick terminal defaults are enabled and use ctrl grave" {
    const defaults = defaultSettings();

    try std.testing.expect(defaults.enabled);
    try std.testing.expectEqual(Hotkey{ .ctrl = true, .vk = VK_OEM_3 }, defaults.hotkey);
}

test "quick terminal top frame uses full work area width and half height" {
    const frame = calculateFrame(.{
        .work_area = .{ .left = 100, .top = 50, .right = 2020, .bottom = 1130 },
        .height_percent = 50,
    });

    try std.testing.expectEqual(Frame{ .x = 100, .y = 50, .width = 1920, .height = 540 }, frame);
}
