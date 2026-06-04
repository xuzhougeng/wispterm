pub const NativeWindowHandle = usize;
pub const Browser = opaque {};
pub const max_url_units = 2048;
pub const UrlBuffer = [max_url_units]u8;
pub const Url = [:0]const u8;

pub fn loaderAvailable() bool {
    return false;
}

pub fn urlFromUtf8(url: []const u8, out: *UrlBuffer) ?Url {
    if (url.len >= out.len) return null;
    @memcpy(out[0..url.len], url);
    out[url.len] = 0;
    return out[0..url.len :0];
}

pub fn create(parent: NativeWindowHandle, bounds: anytype, initial_url: Url) ?*Browser {
    _ = parent;
    _ = bounds;
    _ = initial_url;
    return null;
}

pub fn setBounds(browser: *Browser, bounds: anytype) void {
    _ = browser;
    _ = bounds;
}

pub fn setVisible(browser: *Browser, visible: bool) void {
    _ = browser;
    _ = visible;
}

pub fn focus(browser: *Browser) void {
    _ = browser;
}

pub fn navigate(browser: *Browser, url: Url) void {
    _ = browser;
    _ = url;
}

pub fn reload(browser: *Browser) void {
    _ = browser;
}

pub fn isReady(browser: *Browser) bool {
    _ = browser;
    return false;
}

pub fn lastError(browser: *Browser) i32 {
    _ = browser;
    return 0;
}

pub fn destroy(browser: *Browser) void {
    _ = browser;
}
