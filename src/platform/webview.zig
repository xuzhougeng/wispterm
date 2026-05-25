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
    .windows => @import("webview_windows.zig"),
    .unsupported => @import("webview_unsupported.zig"),
};

pub const NativeWindowHandle = impl.NativeWindowHandle;
pub const ErrorCode = i32;
pub const Browser = impl.Browser;
pub const max_url_units = impl.max_url_units;
pub const UrlBuffer = impl.UrlBuffer;
pub const Url = impl.Url;

pub const Bounds = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

pub fn loaderAvailable() bool {
    return impl.loaderAvailable();
}

pub fn urlFromUtf8(url: []const u8, out: *UrlBuffer) ?Url {
    return impl.urlFromUtf8(url, out);
}

pub fn create(parent: NativeWindowHandle, bounds: Bounds, initial_url: Url) ?*Browser {
    return impl.create(parent, bounds, initial_url);
}

pub fn setBounds(browser: *Browser, bounds: Bounds) void {
    impl.setBounds(browser, bounds);
}

pub fn setVisible(browser: *Browser, visible: bool) void {
    impl.setVisible(browser, visible);
}

pub fn focus(browser: *Browser) void {
    impl.focus(browser);
}

pub fn navigate(browser: *Browser, url: Url) void {
    impl.navigate(browser, url);
}

pub fn isReady(browser: *Browser) bool {
    return impl.isReady(browser);
}

pub fn lastError(browser: *Browser) ErrorCode {
    return impl.lastError(browser);
}

pub fn destroy(browser: *Browser) void {
    impl.destroy(browser);
}

pub fn failed(code: ErrorCode) bool {
    return code < 0;
}

test "platform webview exposes backend-neutral browser API" {
    try std.testing.expect(@hasDecl(@This(), "NativeWindowHandle"));
    try std.testing.expect(@hasDecl(@This(), "Browser"));
    try std.testing.expect(@hasDecl(@This(), "Bounds"));
    try std.testing.expect(@hasDecl(@This(), "ErrorCode"));
    try std.testing.expect(@hasDecl(@This(), "UrlBuffer"));
    try std.testing.expect(@hasDecl(@This(), "Url"));
    try std.testing.expect(@hasDecl(@This(), "urlFromUtf8"));

    const create_info = @typeInfo(@TypeOf(create)).@"fn";
    try std.testing.expectEqual(@as(usize, 3), create_info.params.len);
    try std.testing.expect(create_info.params[0].type.? == @This().NativeWindowHandle);
    try std.testing.expect(create_info.params[1].type.? == @This().Bounds);
    try std.testing.expect(create_info.params[2].type.? == @This().Url);

    const set_bounds_info = @typeInfo(@TypeOf(setBounds)).@"fn";
    try std.testing.expectEqual(@as(usize, 2), set_bounds_info.params.len);
    try std.testing.expect(set_bounds_info.params[0].type.? == *@This().Browser);
    try std.testing.expect(set_bounds_info.params[1].type.? == @This().Bounds);

    const navigate_info = @typeInfo(@TypeOf(navigate)).@"fn";
    try std.testing.expectEqual(@as(usize, 2), navigate_info.params.len);
    try std.testing.expect(navigate_info.params[1].type.? == @This().Url);

    var url_buf: UrlBuffer = undefined;
    const url = urlFromUtf8("https://example.test", &url_buf).?;
    try std.testing.expect(url.len > 0);
    try std.testing.expect(url[0] == @as(@TypeOf(url[0]), 'h'));

    try std.testing.expect(failed(@as(@This().ErrorCode, -1)));
    try std.testing.expect(!failed(@as(@This().ErrorCode, 0)));
}

test "platform webview reports unavailable when backend is unsupported" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try std.testing.expect(!loaderAvailable());
}

test "platform webview selects backend by target OS" {
    try std.testing.expectEqual(Backend.windows, backendForOs(.windows));
    try std.testing.expectEqual(Backend.unsupported, backendForOs(.linux));
    try std.testing.expectEqual(Backend.unsupported, backendForOs(.macos));
}
