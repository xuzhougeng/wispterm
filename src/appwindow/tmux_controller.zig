//! Platform dispatcher for the tmux control-mode driver (Phase 3d). Mirrors the
//! `pty.zig` backend-select pattern so `AppWindow` can call the controller
//! without branching on the OS itself (AppWindow.zig must stay free of
//! `os.tag`). The real driver exists for POSIX and Windows; on other targets
//! every entry point is a no-op stub.

const builtin = @import("builtin");
const std = @import("std");
const Config = @import("../config.zig");

const impl = switch (builtin.os.tag) {
    .windows => @import("tmux_controller_windows.zig"),
    .linux, .macos => @import("tmux_controller_posix.zig"),
    else => struct {
        const Allocator = std.mem.Allocator;
        pub fn start(_: Allocator, _: []const u8, _: []const u8, _: []const u8, _: u16, _: u16, _: u32, _: Config.CursorStyle, _: bool) bool {
            return false;
        }
        pub fn activeProfileNames(_: Allocator) []const []const u8 {
            return &.{};
        }
        pub fn tickAll(_: Allocator, _: u16, _: u16) void {}
        pub fn shutdownAll(_: Allocator) void {}
        pub fn forgetClosedTab(_: *anyopaque) void {}
        pub fn anyActive() bool {
            return false;
        }
        pub fn requestSplit(_: *anyopaque, _: bool) bool {
            return false;
        }
        pub fn requestClosePane(_: *anyopaque) bool {
            return false;
        }
        pub fn requestNewWindow(_: *anyopaque) bool {
            return false;
        }
    },
};

pub const start = impl.start;
pub const tickAll = impl.tickAll;
pub const shutdownAll = impl.shutdownAll;
pub const forgetClosedTab = impl.forgetClosedTab;
pub const anyActive = impl.anyActive;
pub const activeProfileNames = impl.activeProfileNames;
pub const requestSplit = impl.requestSplit;
pub const requestClosePane = impl.requestClosePane;
pub const requestNewWindow = impl.requestNewWindow;
