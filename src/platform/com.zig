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
    .windows => @import("com_windows.zig"),
    .unsupported => @import("com_unsupported.zig"),
};

pub const UiThreadApartmentMode = enum {
    unsupported,
    single_threaded,
};

pub const Apartment = impl.Apartment;
pub const initUiThread = impl.initUiThread;

pub fn uiThreadApartmentMode(os_tag: std.Target.Os.Tag) UiThreadApartmentMode {
    return switch (backendForOs(os_tag)) {
        .windows => .single_threaded,
        .unsupported => .unsupported,
    };
}

test "platform com chooses STA only for Windows UI threads" {
    try std.testing.expectEqual(UiThreadApartmentMode.single_threaded, uiThreadApartmentMode(.windows));
    try std.testing.expectEqual(UiThreadApartmentMode.unsupported, uiThreadApartmentMode(.macos));
    try std.testing.expectEqual(UiThreadApartmentMode.unsupported, uiThreadApartmentMode(.linux));
}

test "platform com selects backend by target OS" {
    try std.testing.expectEqual(Backend.windows, backendForOs(.windows));
    try std.testing.expectEqual(Backend.unsupported, backendForOs(.linux));
    try std.testing.expectEqual(Backend.unsupported, backendForOs(.macos));
}

test "platform com exposes UI thread apartment lifecycle" {
    const apartment = initUiThread();
    defer apartment.deinit();

    try std.testing.expect(@typeInfo(@TypeOf(initUiThread)).@"fn".return_type.? == Apartment);
    try std.testing.expect(@hasDecl(Apartment, "deinit"));
}
