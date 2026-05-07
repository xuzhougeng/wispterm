//! Optional WebView2 browser pane support.
//!
//! The default build keeps this disabled. When compiled with
//! `zig build -Dwebview2=true`, this module dynamically loads
//! WebView2Loader.dll at runtime and hosts WebView2 inside Phantty's HWND.

const std = @import("std");
const build_options = @import("build_options");
const win32 = @import("apprt/win32.zig");

pub const enabled = build_options.webview2;

const windows = std.os.windows;
const HRESULT = i32;
const ULONG = u32;
const BOOL = win32.BOOL;
const HWND = win32.HWND;
const RECT = win32.RECT;
const GUID = win32.GUID;

const S_OK: HRESULT = 0;
const S_FALSE: HRESULT = 1;
const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
const E_FAIL: HRESULT = @bitCast(@as(u32, 0x80004005));
const COINIT_APARTMENTTHREADED: u32 = 0x2;
const RPC_E_CHANGED_MODE: HRESULT = @bitCast(@as(u32, 0x80010106));
const invalid_com_ptr = std.math.maxInt(usize);
const min_valid_ptr = 0x10000;
const max_live_panes = 256;

extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: u32) callconv(.winapi) HRESULT;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;

const IUnknownIID = GUID{ .Data1 = 0x00000000, .Data2 = 0x0000, .Data3 = 0x0000, .Data4 = .{ 0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 } };
const EnvHandlerIID = GUID{ .Data1 = 0x4e8a3389, .Data2 = 0xc9d8, .Data3 = 0x4bd2, .Data4 = .{ 0xb6, 0xb5, 0x12, 0x4f, 0xee, 0x6c, 0xc1, 0x4d } };
const ControllerHandlerIID = GUID{ .Data1 = 0x6c4819f3, .Data2 = 0xc9b7, .Data3 = 0x4260, .Data4 = .{ 0x81, 0x27, 0xc9, 0xf5, 0xbd, 0xe7, 0xf6, 0x8c } };

fn succeeded(hr: HRESULT) bool {
    return hr >= 0;
}

fn guidEql(a: *const GUID, b: *const GUID) bool {
    return a.Data1 == b.Data1 and
        a.Data2 == b.Data2 and
        a.Data3 == b.Data3 and
        std.mem.eql(u8, a.Data4[0..], b.Data4[0..]);
}

fn validComPtr(ptr: anytype) bool {
    const value = @intFromPtr(ptr);
    return value >= min_valid_ptr and value != invalid_com_ptr;
}

fn validFnPtr(ptr: anytype) bool {
    const value = @intFromPtr(ptr);
    return value >= min_valid_ptr and value != invalid_com_ptr;
}

const ICoreWebView2 = extern struct {
    lpVtbl: *const Vtbl,

    const Vtbl = extern struct {
        QueryInterface: *const fn (*ICoreWebView2, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ICoreWebView2) callconv(.winapi) ULONG,
        Release: *const fn (*ICoreWebView2) callconv(.winapi) ULONG,
        get_Settings: *const fn (*ICoreWebView2, *?*anyopaque) callconv(.winapi) HRESULT,
        get_Source: *const fn (*ICoreWebView2, *?[*:0]u16) callconv(.winapi) HRESULT,
        Navigate: *const fn (*ICoreWebView2, [*:0]const u16) callconv(.winapi) HRESULT,
        NavigateToString: *const fn (*ICoreWebView2, [*:0]const u16) callconv(.winapi) HRESULT,
    };
};

const ICoreWebView2Controller = extern struct {
    lpVtbl: *const Vtbl,

    const Vtbl = extern struct {
        QueryInterface: *const fn (*ICoreWebView2Controller, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ICoreWebView2Controller) callconv(.winapi) ULONG,
        Release: *const fn (*ICoreWebView2Controller) callconv(.winapi) ULONG,
        get_IsVisible: *const fn (*ICoreWebView2Controller, *BOOL) callconv(.winapi) HRESULT,
        put_IsVisible: *const fn (*ICoreWebView2Controller, BOOL) callconv(.winapi) HRESULT,
        get_Bounds: *const fn (*ICoreWebView2Controller, *RECT) callconv(.winapi) HRESULT,
        put_Bounds: *const fn (*ICoreWebView2Controller, RECT) callconv(.winapi) HRESULT,
        get_ZoomFactor: *const fn (*ICoreWebView2Controller, *f64) callconv(.winapi) HRESULT,
        put_ZoomFactor: *const fn (*ICoreWebView2Controller, f64) callconv(.winapi) HRESULT,
        add_ZoomFactorChanged: *const fn (*ICoreWebView2Controller, ?*anyopaque, *i64) callconv(.winapi) HRESULT,
        remove_ZoomFactorChanged: *const fn (*ICoreWebView2Controller, i64) callconv(.winapi) HRESULT,
        SetBoundsAndZoomFactor: *const fn (*ICoreWebView2Controller, RECT, f64) callconv(.winapi) HRESULT,
        MoveFocus: *const fn (*ICoreWebView2Controller, i32) callconv(.winapi) HRESULT,
        add_MoveFocusRequested: *const fn (*ICoreWebView2Controller, ?*anyopaque, *i64) callconv(.winapi) HRESULT,
        remove_MoveFocusRequested: *const fn (*ICoreWebView2Controller, i64) callconv(.winapi) HRESULT,
        add_GotFocus: *const fn (*ICoreWebView2Controller, ?*anyopaque, *i64) callconv(.winapi) HRESULT,
        remove_GotFocus: *const fn (*ICoreWebView2Controller, i64) callconv(.winapi) HRESULT,
        add_LostFocus: *const fn (*ICoreWebView2Controller, ?*anyopaque, *i64) callconv(.winapi) HRESULT,
        remove_LostFocus: *const fn (*ICoreWebView2Controller, i64) callconv(.winapi) HRESULT,
        add_AcceleratorKeyPressed: *const fn (*ICoreWebView2Controller, ?*anyopaque, *i64) callconv(.winapi) HRESULT,
        remove_AcceleratorKeyPressed: *const fn (*ICoreWebView2Controller, i64) callconv(.winapi) HRESULT,
        get_ParentWindow: *const fn (*ICoreWebView2Controller, *HWND) callconv(.winapi) HRESULT,
        put_ParentWindow: *const fn (*ICoreWebView2Controller, HWND) callconv(.winapi) HRESULT,
        NotifyParentWindowPositionChanged: *const fn (*ICoreWebView2Controller) callconv(.winapi) HRESULT,
        Close: *const fn (*ICoreWebView2Controller) callconv(.winapi) HRESULT,
        get_CoreWebView2: *const fn (*ICoreWebView2Controller, *?*ICoreWebView2) callconv(.winapi) HRESULT,
    };
};

const ICoreWebView2Environment = extern struct {
    lpVtbl: *const Vtbl,

    const Vtbl = extern struct {
        QueryInterface: *const fn (*ICoreWebView2Environment, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ICoreWebView2Environment) callconv(.winapi) ULONG,
        Release: *const fn (*ICoreWebView2Environment) callconv(.winapi) ULONG,
        CreateCoreWebView2Controller: *const fn (*ICoreWebView2Environment, HWND, *ControllerCompletedHandler) callconv(.winapi) HRESULT,
        CreateWebResourceResponse: *const fn (*ICoreWebView2Environment, ?*anyopaque, i32, [*:0]const u16, [*:0]const u16, *?*anyopaque) callconv(.winapi) HRESULT,
        get_BrowserVersionString: *const fn (*ICoreWebView2Environment, *?[*:0]u16) callconv(.winapi) HRESULT,
        add_NewBrowserVersionAvailable: *const fn (*ICoreWebView2Environment, ?*anyopaque, *i64) callconv(.winapi) HRESULT,
        remove_NewBrowserVersionAvailable: *const fn (*ICoreWebView2Environment, i64) callconv(.winapi) HRESULT,
    };
};

const EnvCompletedHandler = extern struct {
    lpVtbl: *const Vtbl,
    ref_count: ULONG,
    pane: *BrowserPane,

    const Vtbl = extern struct {
        QueryInterface: *const fn (*EnvCompletedHandler, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*EnvCompletedHandler) callconv(.winapi) ULONG,
        Release: *const fn (*EnvCompletedHandler) callconv(.winapi) ULONG,
        Invoke: *const fn (*EnvCompletedHandler, HRESULT, ?*ICoreWebView2Environment) callconv(.winapi) HRESULT,
    };
};

const ControllerCompletedHandler = extern struct {
    lpVtbl: *const Vtbl,
    ref_count: ULONG,
    pane: *BrowserPane,

    const Vtbl = extern struct {
        QueryInterface: *const fn (*ControllerCompletedHandler, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ControllerCompletedHandler) callconv(.winapi) ULONG,
        Release: *const fn (*ControllerCompletedHandler) callconv(.winapi) ULONG,
        Invoke: *const fn (*ControllerCompletedHandler, HRESULT, ?*ICoreWebView2Controller) callconv(.winapi) HRESULT,
    };
};

const EnvCompletedVtbl = EnvCompletedHandler.Vtbl{
    .QueryInterface = envQueryInterface,
    .AddRef = envAddRef,
    .Release = envRelease,
    .Invoke = envInvoke,
};

const ControllerCompletedVtbl = ControllerCompletedHandler.Vtbl{
    .QueryInterface = controllerQueryInterface,
    .AddRef = controllerAddRef,
    .Release = controllerRelease,
    .Invoke = controllerInvoke,
};

pub const SshTarget = struct {
    user: []const u8,
    host: []const u8,
    port: []const u8,
    password: []const u8,
    password_auth: bool,
};

pub const Tunnel = struct {
    child: std.process.Child,
    local_port: u16,

    pub fn deinit(self: *Tunnel) void {
        _ = self.child.kill() catch {};
    }
};

pub const BrowserPane = struct {
    allocator: std.mem.Allocator,
    parent_hwnd: HWND,
    url: [:0]u16,
    url_utf8: []u8,
    pending_bounds: RECT,
    environment: ?*ICoreWebView2Environment = null,
    controller: ?*ICoreWebView2Controller = null,
    webview: ?*ICoreWebView2 = null,
    env_handler: EnvCompletedHandler,
    controller_handler: ControllerCompletedHandler,
    tunnel: ?Tunnel,
    desired_visible: bool = false,
    ready: bool = false,
    failed: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        parent_hwnd: HWND,
        url_utf8: []const u8,
        initial_bounds: RECT,
        tunnel: ?Tunnel,
    ) !*BrowserPane {
        if (!enabled) return error.WebView2Disabled;

        const pane = try allocator.create(BrowserPane);

        const url_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, url_utf8) catch |err| {
            allocator.destroy(pane);
            return err;
        };

        const url_copy = allocator.dupe(u8, url_utf8) catch |err| {
            allocator.free(url_w);
            allocator.destroy(pane);
            return err;
        };

        pane.* = .{
            .allocator = allocator,
            .parent_hwnd = parent_hwnd,
            .url = url_w,
            .url_utf8 = url_copy,
            .pending_bounds = initial_bounds,
            .env_handler = .{ .lpVtbl = &EnvCompletedVtbl, .ref_count = 1, .pane = pane },
            .controller_handler = .{ .lpVtbl = &ControllerCompletedVtbl, .ref_count = 1, .pane = pane },
            .tunnel = tunnel,
            .desired_visible = true,
        };
        registerPane(pane);

        pane.start() catch |err| {
            pane.deinit();
            return err;
        };

        return pane;
    }

    pub fn deinit(self: *BrowserPane) void {
        unregisterPane(self);
        // Be deliberately conservative while the pane lifetime is hosted inside
        // the split tree: corrupted or asynchronously released COM pointers have
        // shown up as 0xffffffffffffffff during close. Leaking the controller is
        // preferable to crashing the terminal; process teardown releases it.
        self.webview = null;
        self.controller = null;
        self.environment = null;
        if (self.tunnel) |*tunnel| {
            tunnel.deinit();
            self.tunnel = null;
        }
        self.allocator.free(self.url_utf8);
        self.allocator.free(self.url);
        self.allocator.destroy(self);
    }

    pub fn setBounds(self: *BrowserPane, bounds: RECT) void {
        self.pending_bounds = bounds;
        if (self.usableController()) |controller| {
            if (!validFnPtr(controller.lpVtbl.put_Bounds) or !validFnPtr(controller.lpVtbl.NotifyParentWindowPositionChanged)) {
                self.failed = true;
                std.debug.print("WebView2 controller vtable has invalid bounds function pointers\n", .{});
                return;
            }
            _ = controller.lpVtbl.put_Bounds(controller, bounds);
            _ = controller.lpVtbl.NotifyParentWindowPositionChanged(controller);
        }
    }

    pub fn setVisible(self: *BrowserPane, visible: bool) void {
        self.desired_visible = visible;
        if (self.usableController()) |controller| {
            if (!validFnPtr(controller.lpVtbl.put_IsVisible)) {
                self.failed = true;
                std.debug.print("WebView2 controller vtable has invalid visibility function pointer\n", .{});
                return;
            }
            _ = controller.lpVtbl.put_IsVisible(controller, if (visible) 1 else 0);
        }
    }

    fn usableController(self: *BrowserPane) ?*ICoreWebView2Controller {
        if (!self.ready or self.failed) return null;
        const controller = self.controller orelse return null;
        if (!validComPtr(controller)) return null;
        if (!validComPtr(controller.lpVtbl)) {
            self.failed = true;
            std.debug.print("WebView2 controller has an invalid vtable pointer\n", .{});
            return null;
        }
        return controller;
    }

    fn start(self: *BrowserPane) !void {
        const init_hr = CoInitializeEx(null, COINIT_APARTMENTTHREADED);
        if (!succeeded(init_hr) and init_hr != RPC_E_CHANGED_MODE) {
            return error.ComInitFailed;
        }
        if (init_hr == S_OK or init_hr == S_FALSE) {
            g_com_initialized = true;
        }

        const loader = loadLoader() orelse return error.WebView2LoaderMissing;
        const proc = win32.GetProcAddress(loader, "CreateCoreWebView2EnvironmentWithOptions") orelse return error.WebView2EntryPointMissing;
        const create_env: CreateEnvironmentFn = @ptrCast(proc);

        const user_data = webviewUserDataFolder(self.allocator) catch null;
        defer if (user_data) |folder| self.allocator.free(folder);

        const hr = create_env(
            null,
            if (user_data) |folder| folder.ptr else null,
            null,
            &self.env_handler,
        );
        if (!succeeded(hr)) return error.CreateEnvironmentFailed;
        std.debug.print("WebView2 environment creation requested for {s}\n", .{self.url_utf8});
    }
};

const CreateEnvironmentFn = *const fn (
    browser_executable_folder: ?[*:0]const u16,
    user_data_folder: ?[*:0]const u16,
    environment_options: ?*anyopaque,
    environment_created_handler: *EnvCompletedHandler,
) callconv(.winapi) HRESULT;

var g_loader: ?win32.HINSTANCE = null;
var g_com_initialized: bool = false;
var g_live_panes: [max_live_panes]?*BrowserPane = .{null} ** max_live_panes;

fn registerPane(pane: *BrowserPane) void {
    for (&g_live_panes) |*slot| {
        if (slot.* == null) {
            slot.* = pane;
            return;
        }
    }
    std.debug.print("WebView2 pane registry is full\n", .{});
}

fn unregisterPane(pane: *BrowserPane) void {
    for (&g_live_panes) |*slot| {
        if (slot.* == pane) {
            slot.* = null;
            return;
        }
    }
}

fn isLivePane(pane: *BrowserPane) bool {
    if (!validComPtr(pane)) return false;
    for (&g_live_panes) |slot| {
        if (slot == pane) return true;
    }
    return false;
}

pub fn setPaneVisible(pane: *BrowserPane, visible: bool) void {
    if (!isLivePane(pane)) return;
    pane.setVisible(visible);
}

pub fn setPaneBounds(pane: *BrowserPane, bounds: RECT) void {
    if (!isLivePane(pane)) return;
    pane.setBounds(bounds);
}

pub fn deinitPaneIfLive(pane: *BrowserPane) void {
    if (!isLivePane(pane)) return;
    pane.deinit();
}

fn loadLoader() ?win32.HINSTANCE {
    if (g_loader) |loader| return loader;
    const loader = win32.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("WebView2Loader.dll")) orelse return null;
    g_loader = loader;
    return loader;
}

fn webviewUserDataFolder(allocator: std.mem.Allocator) ![:0]u16 {
    const local = std.process.getEnvVarOwned(allocator, "LOCALAPPDATA") catch
        try std.process.getEnvVarOwned(allocator, "APPDATA");
    defer allocator.free(local);

    const path = try std.fs.path.join(allocator, &.{ local, "phantty", "webview2" });
    defer allocator.free(path);
    std.fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {},
    };
    return try std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
}

fn envQueryInterface(self: *EnvCompletedHandler, riid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
    if (guidEql(riid, &IUnknownIID) or guidEql(riid, &EnvHandlerIID)) {
        out.* = @ptrCast(self);
        _ = envAddRef(self);
        return S_OK;
    }
    out.* = null;
    return E_NOINTERFACE;
}

fn envAddRef(self: *EnvCompletedHandler) callconv(.winapi) ULONG {
    self.ref_count += 1;
    return self.ref_count;
}

fn envRelease(self: *EnvCompletedHandler) callconv(.winapi) ULONG {
    if (self.ref_count > 0) self.ref_count -= 1;
    return self.ref_count;
}

fn envInvoke(self: *EnvCompletedHandler, error_code: HRESULT, environment: ?*ICoreWebView2Environment) callconv(.winapi) HRESULT {
    const pane = self.pane;
    if (!succeeded(error_code) or environment == null) {
        pane.failed = true;
        std.debug.print("WebView2 environment creation failed: 0x{x}\n", .{@as(u32, @bitCast(error_code))});
        return S_OK;
    }

    pane.environment = environment;
    std.debug.print("WebView2 environment ready for {s}\n", .{pane.url_utf8});
    const hr = environment.?.lpVtbl.CreateCoreWebView2Controller(environment.?, pane.parent_hwnd, &pane.controller_handler);
    if (!succeeded(hr)) {
        pane.failed = true;
        std.debug.print("WebView2 controller creation failed: 0x{x}\n", .{@as(u32, @bitCast(hr))});
    }
    return S_OK;
}

fn controllerQueryInterface(self: *ControllerCompletedHandler, riid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
    if (guidEql(riid, &IUnknownIID) or guidEql(riid, &ControllerHandlerIID)) {
        out.* = @ptrCast(self);
        _ = controllerAddRef(self);
        return S_OK;
    }
    out.* = null;
    return E_NOINTERFACE;
}

fn controllerAddRef(self: *ControllerCompletedHandler) callconv(.winapi) ULONG {
    self.ref_count += 1;
    return self.ref_count;
}

fn controllerRelease(self: *ControllerCompletedHandler) callconv(.winapi) ULONG {
    if (self.ref_count > 0) self.ref_count -= 1;
    return self.ref_count;
}

fn controllerInvoke(self: *ControllerCompletedHandler, error_code: HRESULT, controller: ?*ICoreWebView2Controller) callconv(.winapi) HRESULT {
    const pane = self.pane;
    if (!succeeded(error_code) or controller == null) {
        pane.failed = true;
        std.debug.print("WebView2 controller callback failed: 0x{x}\n", .{@as(u32, @bitCast(error_code))});
        return S_OK;
    }

    const controller_ptr = controller.?;
    if (!validComPtr(controller_ptr)) {
        pane.failed = true;
        std.debug.print("WebView2 controller callback returned an invalid pointer\n", .{});
        return S_OK;
    }
    if (!validComPtr(controller_ptr.lpVtbl) or !validFnPtr(controller_ptr.lpVtbl.get_CoreWebView2)) {
        pane.failed = true;
        std.debug.print("WebView2 controller callback returned an invalid vtable\n", .{});
        return S_OK;
    }

    var webview: ?*ICoreWebView2 = null;
    const hr = controller_ptr.lpVtbl.get_CoreWebView2(controller_ptr, &webview);
    if (!succeeded(hr) or webview == null) {
        pane.failed = true;
        std.debug.print("WebView2 get_CoreWebView2 failed: 0x{x}\n", .{@as(u32, @bitCast(hr))});
        if (validFnPtr(controller_ptr.lpVtbl.Close)) {
            _ = controller_ptr.lpVtbl.Close(controller_ptr);
        }
        if (validFnPtr(controller_ptr.lpVtbl.Release)) {
            _ = controller_ptr.lpVtbl.Release(controller_ptr);
        }
        return S_OK;
    }
    if (!validComPtr(webview.?) or !validComPtr(webview.?.lpVtbl) or !validFnPtr(webview.?.lpVtbl.Navigate)) {
        pane.failed = true;
        std.debug.print("WebView2 core callback returned an invalid vtable\n", .{});
        if (validFnPtr(controller_ptr.lpVtbl.Close)) {
            _ = controller_ptr.lpVtbl.Close(controller_ptr);
        }
        if (validFnPtr(controller_ptr.lpVtbl.Release)) {
            _ = controller_ptr.lpVtbl.Release(controller_ptr);
        }
        return S_OK;
    }

    pane.controller = controller_ptr;
    pane.webview = webview.?;
    pane.ready = true;
    std.debug.print(
        "WebView2 controller ready for {s}, bounds=({},{})->({},{})\n",
        .{ pane.url_utf8, pane.pending_bounds.left, pane.pending_bounds.top, pane.pending_bounds.right, pane.pending_bounds.bottom },
    );
    if (validFnPtr(controller_ptr.lpVtbl.put_Bounds)) {
        _ = controller_ptr.lpVtbl.put_Bounds(controller_ptr, pane.pending_bounds);
    }
    if (validFnPtr(controller_ptr.lpVtbl.put_IsVisible)) {
        _ = controller_ptr.lpVtbl.put_IsVisible(controller_ptr, if (pane.desired_visible) 1 else 0);
    }
    const nav_hr = webview.?.lpVtbl.Navigate(webview.?, pane.url.ptr);
    if (!succeeded(nav_hr)) {
        pane.failed = true;
        std.debug.print("WebView2 Navigate failed for {s}: 0x{x}\n", .{ pane.url_utf8, @as(u32, @bitCast(nav_hr)) });
    } else {
        std.debug.print("WebView2 Navigate requested for {s}\n", .{pane.url_utf8});
    }
    return S_OK;
}

pub fn deinitProcessGlobals() void {
    if (g_com_initialized) {
        CoUninitialize();
        g_com_initialized = false;
    }
    if (g_loader) |loader| {
        _ = win32.FreeLibrary(loader);
        g_loader = null;
    }
}

pub fn startSshTunnel(allocator: std.mem.Allocator, target: SshTarget, remote_port: u16) ?Tunnel {
    if (!enabled) return null;

    const local_port = reserveLocalPort() orelse remote_port;
    const forward = std.fmt.allocPrint(allocator, "127.0.0.1:{d}:127.0.0.1:{d}", .{ local_port, remote_port }) catch return null;
    defer allocator.free(forward);

    const dest = std.fmt.allocPrint(allocator, "{s}@{s}", .{ target.user, target.host }) catch return null;
    defer allocator.free(dest);

    var askpass_path: ?[]u8 = null;
    defer if (askpass_path) |path| allocator.free(path);
    var env_map: ?std.process.EnvMap = null;
    defer if (env_map) |*map| map.deinit();

    if (target.password_auth) {
        askpass_path = ensureAskPassScript(allocator) orelse return null;
        env_map = std.process.getEnvMap(allocator) catch return null;
        if (env_map) |*map| {
            map.put("SSH_ASKPASS", askpass_path.?) catch return null;
            map.put("SSH_ASKPASS_REQUIRE", "force") catch return null;
            map.put("DISPLAY", "phantty") catch return null;
            map.put("PHANTTY_SSH_PASSWORD", target.password) catch return null;
        }
    }

    var argv: [32][]const u8 = undefined;
    var argc: usize = 0;
    argv[argc] = "ssh.exe";
    argc += 1;
    argv[argc] = "-N";
    argc += 1;
    argv[argc] = "-L";
    argc += 1;
    argv[argc] = forward;
    argc += 1;
    argc = appendSshOptions(&argv, argc, target);
    argv[argc] = dest;
    argc += 1;

    var child = std.process.Child.init(argv[0..argc], allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;
    if (env_map) |*map| child.env_map = map;

    child.spawn() catch |err| {
        std.debug.print("SSH tunnel spawn failed: {}\n", .{err});
        return null;
    };

    waitForLocalPort(allocator, local_port, 2500);
    return .{ .child = child, .local_port = local_port };
}

fn appendSshOptions(argv: *[32][]const u8, start_argc: usize, target: SshTarget) usize {
    var argc = start_argc;
    argv[argc] = "-o";
    argc += 1;
    argv[argc] = "StrictHostKeyChecking=accept-new";
    argc += 1;
    argv[argc] = "-o";
    argc += 1;
    argv[argc] = "ExitOnForwardFailure=yes";
    argc += 1;
    if (target.password_auth) {
        argv[argc] = "-o";
        argc += 1;
        argv[argc] = "PreferredAuthentications=publickey,password,keyboard-interactive";
        argc += 1;
        argv[argc] = "-o";
        argc += 1;
        argv[argc] = "NumberOfPasswordPrompts=1";
        argc += 1;
    } else {
        argv[argc] = "-o";
        argc += 1;
        argv[argc] = "BatchMode=yes";
        argc += 1;
    }
    if (target.port.len > 0) {
        argv[argc] = "-p";
        argc += 1;
        argv[argc] = target.port;
        argc += 1;
    }
    return argc;
}

fn reserveLocalPort() ?u16 {
    const addr = std.net.Address.parseIp4("127.0.0.1", 0) catch return null;
    var server = std.net.Address.listen(addr, .{}) catch return null;
    const port = server.listen_address.getPort();
    server.deinit();
    return port;
}

fn waitForLocalPort(allocator: std.mem.Allocator, port: u16, timeout_ms: i64) void {
    const started = std.time.milliTimestamp();
    while (std.time.milliTimestamp() - started < timeout_ms) {
        if (std.net.tcpConnectToHost(allocator, "127.0.0.1", port)) |stream| {
            stream.close();
            return;
        } else |_| {}
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }
}

fn ensureAskPassScript(allocator: std.mem.Allocator) ?[]u8 {
    const temp = std.process.getEnvVarOwned(allocator, "TEMP") catch
        std.process.getEnvVarOwned(allocator, "TMP") catch return null;
    defer allocator.free(temp);

    const path = std.fmt.allocPrint(allocator, "{s}\\phantty-ssh-askpass.cmd", .{temp}) catch return null;
    errdefer allocator.free(path);

    const file = std.fs.createFileAbsolute(path, .{ .truncate = true }) catch return null;
    defer file.close();

    file.writeAll(
        "@echo off\r\n" ++
            "powershell.exe -NoLogo -NoProfile -Command \"[Console]::Out.Write($env:PHANTTY_SSH_PASSWORD)\"\r\n",
    ) catch return null;
    return path;
}

pub fn makeLocalhostUrl(
    allocator: std.mem.Allocator,
    original_url: []const u8,
    local_port: u16,
) ?[]u8 {
    const parsed = parseUrl(original_url) orelse return null;
    return std.fmt.allocPrint(
        allocator,
        "{s}://127.0.0.1:{d}{s}",
        .{ parsed.scheme, local_port, parsed.path_and_query },
    ) catch null;
}

pub const ParsedUrl = struct {
    scheme: []const u8,
    host: []const u8,
    port: ?u16,
    path_and_query: []const u8,
};

pub fn parseUrl(url: []const u8) ?ParsedUrl {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return null;
    const scheme = url[0..scheme_end];
    if (!std.mem.eql(u8, scheme, "http") and !std.mem.eql(u8, scheme, "https")) return null;

    const authority_start = scheme_end + 3;
    var authority_end = authority_start;
    while (authority_end < url.len and url[authority_end] != '/' and url[authority_end] != '?' and url[authority_end] != '#') {
        authority_end += 1;
    }
    const authority = url[authority_start..authority_end];
    if (authority.len == 0) return null;

    const path_and_query = if (authority_end < url.len) url[authority_end..] else "/";

    var host = authority;
    var port: ?u16 = null;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        const port_text = authority[colon + 1 ..];
        if (port_text.len > 0) {
            port = std.fmt.parseInt(u16, port_text, 10) catch null;
            if (port != null) host = authority[0..colon];
        }
    }

    return .{
        .scheme = scheme,
        .host = host,
        .port = port,
        .path_and_query = path_and_query,
    };
}

pub fn isLocalhostUrl(url: []const u8) bool {
    const parsed = parseUrl(url) orelse return false;
    return std.ascii.eqlIgnoreCase(parsed.host, "localhost") or
        std.mem.eql(u8, parsed.host, "127.0.0.1") or
        std.mem.eql(u8, parsed.host, "::1") or
        std.mem.eql(u8, parsed.host, "[::1]");
}

pub fn defaultPortForUrl(url: []const u8) ?u16 {
    const parsed = parseUrl(url) orelse return null;
    if (parsed.port) |port| return port;
    if (std.mem.eql(u8, parsed.scheme, "http")) return 80;
    if (std.mem.eql(u8, parsed.scheme, "https")) return 443;
    return null;
}

test "parse localhost url" {
    const parsed = parseUrl("http://127.0.0.1:1234/path?q=1").?;
    try std.testing.expectEqualStrings("http", parsed.scheme);
    try std.testing.expectEqualStrings("127.0.0.1", parsed.host);
    try std.testing.expectEqual(@as(?u16, 1234), parsed.port);
    try std.testing.expectEqualStrings("/path?q=1", parsed.path_and_query);
}
