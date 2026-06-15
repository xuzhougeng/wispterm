//! Windows pseudo-console API resolution: prefers the redistributable
//! Microsoft.Windows.Console.ConPTY pair (conpty.dll + OpenConsole.exe)
//! placed next to wispterm.exe, falling back to the OS inbox kernel32
//! implementation. The bundled pair gives old Windows 10 conhosts the
//! modern ConPTY behaviors (mouse-mode passthrough, alt-screen passthrough)
//! that crossterm TUIs such as Codex rely on.
//!
//! Only `platform/pty_windows.zig` may import this module.

const std = @import("std");
const policy = @import("console_host_policy.zig");
const input_diagnostics = @import("../input_diagnostics.zig");

const windows = std.os.windows;
const HANDLE = windows.HANDLE;
const DWORD = windows.DWORD;
const HRESULT = i32;

const log = std.log.scoped(.conpty);

pub const COORD = extern struct {
    X: i16,
    Y: i16,
};

pub const HPCON = windows.HANDLE;

pub const CreateFn = *const fn (
    size: COORD,
    hInput: HANDLE,
    hOutput: HANDLE,
    dwFlags: DWORD,
    phPC: *HPCON,
) callconv(.winapi) HRESULT;
pub const ResizeFn = *const fn (hPC: HPCON, size: COORD) callconv(.winapi) HRESULT;
pub const CloseFn = *const fn (hPC: HPCON) callconv(.winapi) void;

pub const Api = struct {
    choice: policy.Choice,
    create: CreateFn,
    resize: ResizeFn,
    close: CloseFn,
};

extern "kernel32" fn CreatePseudoConsole(
    size: COORD,
    hInput: HANDLE,
    hOutput: HANDLE,
    dwFlags: DWORD,
    phPC: *HPCON,
) callconv(.winapi) HRESULT;
extern "kernel32" fn ResizePseudoConsole(hPC: HPCON, size: COORD) callconv(.winapi) HRESULT;
extern "kernel32" fn ClosePseudoConsole(hPC: HPCON) callconv(.winapi) void;

const system_api = Api{
    .choice = .system,
    .create = &CreatePseudoConsole,
    .resize = &ResizePseudoConsole,
    .close = &ClosePseudoConsole,
};

const bundled_dll_name = "conpty.dll";
const bundled_host_name = "OpenConsole.exe";

var g_mutex: std.Thread.Mutex = .{};
var g_preference: policy.Preference = .auto;
var g_resolved: ?*const Api = null;
var g_bundled_api: Api = undefined;

/// Set from the config layer before (or after) sessions exist. Resets the
/// cached resolution so the next `acquire` re-evaluates; already-created
/// sessions keep the api pointer they were born with.
pub fn setPreference(pref: policy.Preference) void {
    g_mutex.lock();
    defer g_mutex.unlock();
    if (g_preference == pref) return;
    g_preference = pref;
    g_resolved = null;
}

pub fn systemApi() *const Api {
    return &system_api;
}

/// Permanently downgrade to the inbox implementation (called after a bundled
/// create failure so one broken redistributable cannot break every new tab).
pub fn stickToSystem() void {
    g_mutex.lock();
    defer g_mutex.unlock();
    g_resolved = &system_api;
}

pub fn acquire() *const Api {
    g_mutex.lock();
    defer g_mutex.unlock();
    if (g_resolved) |api| return api;
    const api = resolveLocked();
    g_resolved = api;
    return api;
}

fn resolveLocked() *const Api {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_dir = std.fs.selfExeDirPath(&dir_buf) catch {
        log.warn("cannot resolve exe dir; using system pseudo console", .{});
        return &system_api;
    };

    const dll_present = siblingExists(exe_dir, bundled_dll_name);
    const host_present = siblingExists(exe_dir, bundled_host_name);
    if (input_diagnostics.enabled())
        input_diagnostics.log("conpty resolve: preference={s} conpty.dll_present={} OpenConsole.exe_present={} -> choice={s}", .{
            @tagName(g_preference), dll_present, host_present, @tagName(policy.choose(g_preference, dll_present, host_present)),
        });
    if (policy.choose(g_preference, dll_present, host_present) == .system) {
        if (g_preference == .auto and (dll_present != host_present)) {
            log.warn(
                "incomplete bundle next to exe (dll={}, host={}); using system pseudo console",
                .{ dll_present, host_present },
            );
        }
        return &system_api;
    }

    return loadBundled(exe_dir) orelse &system_api;
}

fn siblingExists(exe_dir: []const u8, name: []const u8) bool {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}\\{s}", .{ exe_dir, name }) catch return false;
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn loadBundled(exe_dir: []const u8) ?*const Api {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}\\{s}", .{ exe_dir, bundled_dll_name }) catch return null;

    var wide_buf: [windows.PATH_MAX_WIDE:0]u16 = undefined;
    const wide_len = std.unicode.utf8ToUtf16Le(&wide_buf, path) catch {
        log.warn("bundle path not encodable; using system pseudo console", .{});
        return null;
    };
    wide_buf[wide_len] = 0;

    const module = windows.kernel32.LoadLibraryW(wide_buf[0..wide_len :0].ptr) orelse {
        log.warn("LoadLibraryW(conpty.dll) failed ({}); using system pseudo console", .{windows.GetLastError()});
        return null;
    };

    const create = windows.kernel32.GetProcAddress(module, "ConptyCreatePseudoConsole") orelse {
        log.warn("ConptyCreatePseudoConsole missing; using system pseudo console", .{});
        return null;
    };
    const resize = windows.kernel32.GetProcAddress(module, "ConptyResizePseudoConsole") orelse {
        log.warn("ConptyResizePseudoConsole missing; using system pseudo console", .{});
        return null;
    };
    const close = windows.kernel32.GetProcAddress(module, "ConptyClosePseudoConsole") orelse {
        log.warn("ConptyClosePseudoConsole missing; using system pseudo console", .{});
        return null;
    };

    g_bundled_api = .{
        .choice = .bundled,
        .create = @ptrCast(create),
        .resize = @ptrCast(resize),
        .close = @ptrCast(close),
    };
    log.info("using bundled conpty.dll next to exe", .{});
    return &g_bundled_api;
}

test "conpty resolution falls back to system when no bundle is present" {
    // The test binary has no conpty.dll/OpenConsole.exe next to it, so auto
    // must resolve to the inbox implementation.
    setPreference(.auto);
    g_mutex.lock();
    g_resolved = null;
    g_mutex.unlock();
    try std.testing.expectEqual(policy.Choice.system, acquire().choice);
}

test "conpty resolution honors forced system preference" {
    setPreference(.system);
    try std.testing.expectEqual(policy.Choice.system, acquire().choice);
    setPreference(.auto);
}
