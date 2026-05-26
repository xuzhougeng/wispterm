const std = @import("std");

pub const Destination = enum {
    embedded_browser,
    system_browser,
};

pub const Mode = enum {
    embedded,
    system_browser,

    pub fn parse(value: []const u8) ?Mode {
        if (std.mem.eql(u8, value, "embedded")) return .embedded;
        if (std.mem.eql(u8, value, "embedded-browser")) return .embedded;
        if (std.mem.eql(u8, value, "webview")) return .embedded;
        if (std.mem.eql(u8, value, "system-browser")) return .system_browser;
        if (std.mem.eql(u8, value, "default-browser")) return .system_browser;
        if (std.mem.eql(u8, value, "external")) return .system_browser;
        return null;
    }

    pub fn name(self: Mode) []const u8 {
        return switch (self) {
            .embedded => "embedded",
            .system_browser => "system-browser",
        };
    }
};

pub fn destinationForUrlClick(embedded_browser_available: bool, mode: Mode) Destination {
    if (mode == .system_browser) return .system_browser;
    return if (embedded_browser_available) .embedded_browser else .system_browser;
}

test "URL clicks use the system browser when embedded WebView is unavailable" {
    try std.testing.expectEqual(Destination.system_browser, destinationForUrlClick(false, .embedded));
}

test "URL clicks use the embedded browser when it is available" {
    try std.testing.expectEqual(Destination.embedded_browser, destinationForUrlClick(true, .embedded));
}

test "URL clicks can force the system browser even when embedded WebView is available" {
    try std.testing.expectEqual(Destination.system_browser, destinationForUrlClick(true, .system_browser));
    try std.testing.expectEqual(Mode.system_browser, Mode.parse("default-browser").?);
    try std.testing.expectEqualStrings("system-browser", Mode.system_browser.name());
}
