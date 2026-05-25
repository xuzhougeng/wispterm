const std = @import("std");
const builtin = @import("builtin");

pub const Backend = enum {
    windows,
    unsupported,
};

pub fn backendForOs(os_tag: std.Target.Os.Tag) Backend {
    return switch (os_tag) {
        .windows => .windows,
        else => .unsupported,
    };
}

const impl = switch (backendForOs(builtin.os.tag)) {
    .windows => @import("file_dialog_windows.zig"),
    .unsupported => @import("file_dialog_unsupported.zig"),
};

pub const Owner = impl.Owner;
pub const Filter = impl.Filter;
pub const OpenRequest = impl.OpenRequest;
pub const SaveRequest = impl.SaveRequest;

pub const windowOwner = impl.windowOwner;
pub const openFile = impl.openFile;
pub const saveFile = impl.saveFile;

test "platform file dialog exposes typed open and save APIs" {
    const owner = windowOwner(1234);
    const filters = [_]Filter{.{ .name = "All Files", .pattern = "*.*" }};

    const open_request = OpenRequest{
        .owner = owner,
        .title = "Upload file",
        .filters = &filters,
    };
    const save_request = SaveRequest{
        .owner = owner,
        .title = "Save Markdown",
        .default_filename = "chat.md",
        .default_extension = "md",
        .filters = &filters,
    };

    try std.testing.expectEqual(@as(?usize, 1234), owner.native_window);
    try std.testing.expectEqualStrings("Upload file", open_request.title);
    try std.testing.expectEqualStrings("chat.md", save_request.default_filename.?);
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(@TypeOf(openFile)).@"fn".params.len);
    try std.testing.expect(@typeInfo(@TypeOf(openFile)).@"fn".params[0].type.? == std.mem.Allocator);
    try std.testing.expect(@typeInfo(@TypeOf(openFile)).@"fn".params[1].type.? == OpenRequest);
    try std.testing.expect(@typeInfo(@TypeOf(openFile)).@"fn".return_type.? == ?[]u8);
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(@TypeOf(saveFile)).@"fn".params.len);
    try std.testing.expect(@typeInfo(@TypeOf(saveFile)).@"fn".params[0].type.? == std.mem.Allocator);
    try std.testing.expect(@typeInfo(@TypeOf(saveFile)).@"fn".params[1].type.? == SaveRequest);
    try std.testing.expect(@typeInfo(@TypeOf(saveFile)).@"fn".return_type.? == ?[]u8);
}

test "platform file dialog selects backend by target OS" {
    try std.testing.expectEqual(Backend.windows, backendForOs(.windows));
    try std.testing.expectEqual(Backend.unsupported, backendForOs(.linux));
    try std.testing.expectEqual(Backend.unsupported, backendForOs(.macos));
}
