const std = @import("std");
const builtin = @import("builtin");

pub const Backend = enum {
    windows,
    none,
};

pub fn backendForOs(os_tag: std.Target.Os.Tag) Backend {
    return switch (os_tag) {
        .windows => .windows,
        else => .none,
    };
}

const impl = switch (backendForOs(builtin.os.tag)) {
    .windows => @import("console_windows.zig"),
    .none => @import("console_none.zig"),
};

pub const ConsoleAttachMode = enum {
    none,
    parent_process,
};

pub fn prepareCliConsole() void {
    impl.prepareCliConsole();
}

pub fn consoleAttachMode(os_tag: std.Target.Os.Tag) ConsoleAttachMode {
    return switch (backendForOs(os_tag)) {
        .windows => .parent_process,
        .none => .none,
    };
}

test "platform console exposes CLI console preparation API" {
    try std.testing.expectEqual(@as(usize, 0), @typeInfo(@TypeOf(prepareCliConsole)).@"fn".params.len);
    try std.testing.expect(@typeInfo(@TypeOf(prepareCliConsole)).@"fn".return_type.? == void);
    try std.testing.expectEqual(ConsoleAttachMode.parent_process, consoleAttachMode(.windows));
    try std.testing.expectEqual(ConsoleAttachMode.none, consoleAttachMode(.linux));
    try std.testing.expectEqual(ConsoleAttachMode.none, consoleAttachMode(.macos));
}

test "platform console selects backend by target OS" {
    try std.testing.expectEqual(Backend.windows, backendForOs(.windows));
    try std.testing.expectEqual(Backend.none, backendForOs(.linux));
    try std.testing.expectEqual(Backend.none, backendForOs(.macos));
}
