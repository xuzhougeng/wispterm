//! Native macOS platform-service smoke-test entry point.

const std = @import("std");

const clipboard = @import("platform/clipboard.zig");
const config_watcher = @import("platform/config_watcher.zig");
const cursor = @import("platform/cursor.zig");
const display = @import("platform/display.zig");
const file_dialog = @import("platform/file_dialog.zig");
const global_hotkey = @import("platform/global_hotkey.zig");
const global_hotkey_macos = @import("platform/global_hotkey_macos.zig");
const notifications = @import("platform/notifications.zig");
const open_url = @import("platform/open_url.zig");
const remote_transport = @import("platform/remote_transport.zig");
const text = @import("platform/text.zig");
const update_package = @import("platform/update_package.zig");

test "macOS services select native or supported platform backends" {
    try std.testing.expectEqualStrings("macos", @tagName(clipboard.backendForOs(.macos)));
    try std.testing.expectEqualStrings("macos", @tagName(file_dialog.backendForOs(.macos)));
    try std.testing.expectEqualStrings("macos", @tagName(cursor.backendForOs(.macos)));
    try std.testing.expectEqualStrings("macos", @tagName(notifications.backendForOs(.macos)));
    try std.testing.expectEqualStrings("macos", @tagName(global_hotkey.backendForOs(.macos)));
    try std.testing.expectEqualStrings("macos", @tagName(config_watcher.backendForOs(.macos)));
    try std.testing.expectEqualStrings("macos", @tagName(display.backendForOs(.macos)));
    try std.testing.expectEqualStrings("macos", @tagName(text.backendForOs(.macos)));
    try std.testing.expectEqualStrings("macos", @tagName(open_url.backendForOs(.macos)));
    try std.testing.expectEqualStrings("macos", @tagName(update_package.backendForOs(.macos)));
}

test "macOS clipboard round-trips UTF-8 text through NSPasteboard" {
    const owner = clipboard.windowOwner(0);
    try std.testing.expect(clipboard.writeText(std.testing.allocator, owner, "wispterm mac clipboard"));
    const text_value = clipboard.readText(std.testing.allocator, owner) orelse return error.ExpectedClipboardText;
    defer std.testing.allocator.free(text_value);
    try std.testing.expectEqualStrings("wispterm mac clipboard", text_value);
}

extern fn wispterm_macos_clipboard_write_image_png(bytes: [*]const u8, len: i32) bool;

// A valid 1x1 RGBA PNG, generated with a real PNG encoder.
const sample_png = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4,
    0x89, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0xf8, 0xcf, 0xc0, 0xf0,
    0x1f, 0x00, 0x05, 0x00, 0x01, 0xff, 0x56, 0xc7, 0x2f, 0x0d, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
    0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
};

test "macOS clipboard reads a pasted image as a temp PNG file" {
    try std.testing.expect(wispterm_macos_clipboard_write_image_png(&sample_png, @intCast(sample_png.len)));

    const owner = clipboard.windowOwner(0);
    const path = clipboard.readImageAsPngTemp(std.testing.allocator, owner) orelse return error.ExpectedClipboardImage;
    defer std.testing.allocator.free(path);
    defer std.fs.deleteFileAbsolute(path) catch {};

    try std.testing.expect(std.fs.path.isAbsolute(path));
    try std.testing.expect(std.mem.endsWith(u8, path, ".png"));

    const data = try std.fs.cwd().readFileAlloc(std.testing.allocator, path, 1024 * 1024);
    defer std.testing.allocator.free(data);

    // The PNG signature must survive the clipboard round-trip, and for a
    // ready-made image/png the bytes pass through verbatim.
    try std.testing.expect(std.mem.startsWith(u8, data, "\x89PNG\r\n\x1a\n"));
    try std.testing.expectEqualSlices(u8, &sample_png, data);
}

test "macOS remote transport selects the native backend and fails closed on a dead endpoint" {
    try std.testing.expectEqualStrings("macos", @tagName(remote_transport.backendForOs(.macos)));

    // Nothing is listening on this loopback port, so connect must fail promptly
    // and tear the native session down cleanly (exercises the connect + shutdown
    // path of the NSURLSessionWebSocketTask bridge; full duplex needs a live
    // relay server and is verified on-device).
    const result = remote_transport.connect(std.testing.allocator, .{
        .secure = false,
        .host = "127.0.0.1",
        .port = 9,
        .object_name = "/ws",
    });
    try std.testing.expectError(error.RemoteTransportConnectFailed, result);
}

test "macOS display and text services return native answers" {
    try std.testing.expect(display.isPointOnAnyDisplay(0, 0));
    try std.testing.expectEqual(@as(?bool, true), text.nativeOrdinalIgnoreCaseUtf8Equal("WispTerm", "wispterm"));
    try std.testing.expectEqual(@as(?bool, false), text.nativeOrdinalIgnoreCaseUtf8Equal("WispTerm", "Ghostty"));
}

test "macOS config watcher observes directory changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const real_dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(real_dir);

    var watcher = config_watcher.DirectoryWatcher.initPath(real_dir) orelse return error.ExpectedConfigWatcher;
    defer watcher.deinit();
    try std.testing.expect(!watcher.hasChanged());

    {
        var file = try tmp.dir.createFile("config", .{ .truncate = true });
        defer file.close();
        try file.writeAll("font-family = Menlo\n");
    }

    var observed = false;
    for (0..20) |_| {
        if (watcher.hasChanged()) {
            observed = true;
            break;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    try std.testing.expect(observed);
}

test "macOS noninteractive service calls are safe" {
    cursor.set(.arrow);
    notifications.bell();

    const trigger = global_hotkey.Trigger{ .ctrl = true, .key_code = 'P' };
    try std.testing.expect(global_hotkey.modifiersForTrigger(trigger) != 0);
    try std.testing.expect(global_hotkey_macos.canTranslateForTest(
        global_hotkey.modifiersForTrigger(.{ .ctrl = true, .key_code = 0xC0 }),
        0xC0,
    ));
    try std.testing.expect(global_hotkey_macos.canTranslateForTest(
        global_hotkey.modifiersForTrigger(.{ .ctrl = true, .shift = true, .alt = true, .win = true, .key_code = 0x82 }),
        0x82,
    ));
}

test {
    _ = file_dialog;
    _ = open_url;
    _ = update_package;
}
