const std = @import("std");
const windows = std.os.windows;
const Entry = @import("shell_integration.zig").Entry;

const HRESULT = windows.HRESULT;
const GUID = windows.GUID;
const MAX_PATH = 260;
const COINIT_APARTMENTTHREADED: u32 = 0x2;
const CLSCTX_INPROC_SERVER: u32 = 0x1;
const CSIDL_PROGRAMS: c_int = 0x0002;
const CSIDL_STARTUP: c_int = 0x0007;
const SHGFP_TYPE_CURRENT: u32 = 0;

const CLSID_ShellLink = GUID{ .Data1 = 0x00021401, .Data2 = 0x0000, .Data3 = 0x0000, .Data4 = .{ 0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 } };
const IID_IShellLinkW = GUID{ .Data1 = 0x000214f9, .Data2 = 0x0000, .Data3 = 0x0000, .Data4 = .{ 0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 } };
const IID_IPersistFile = GUID{ .Data1 = 0x0000010b, .Data2 = 0x0000, .Data3 = 0x0000, .Data4 = .{ 0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 } };

const IShellLinkW = extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        QueryInterface: *const fn (*IShellLinkW, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IShellLinkW) callconv(.winapi) u32,
        Release: *const fn (*IShellLinkW) callconv(.winapi) u32,
        GetPath: *const anyopaque,
        GetIDList: *const anyopaque,
        SetIDList: *const anyopaque,
        GetDescription: *const anyopaque,
        SetDescription: *const anyopaque,
        GetWorkingDirectory: *const anyopaque,
        SetWorkingDirectory: *const fn (*IShellLinkW, [*:0]const u16) callconv(.winapi) HRESULT,
        GetArguments: *const anyopaque,
        SetArguments: *const anyopaque,
        GetHotkey: *const anyopaque,
        SetHotkey: *const anyopaque,
        GetShowCmd: *const anyopaque,
        SetShowCmd: *const anyopaque,
        GetIconLocation: *const anyopaque,
        SetIconLocation: *const fn (*IShellLinkW, [*:0]const u16, c_int) callconv(.winapi) HRESULT,
        SetRelativePath: *const anyopaque,
        Resolve: *const anyopaque,
        SetPath: *const fn (*IShellLinkW, [*:0]const u16) callconv(.winapi) HRESULT,
    };
};

const IPersistFile = extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        QueryInterface: *const fn (*IPersistFile, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IPersistFile) callconv(.winapi) u32,
        Release: *const fn (*IPersistFile) callconv(.winapi) u32,
        GetClassID: *const anyopaque,
        IsDirty: *const anyopaque,
        Load: *const anyopaque,
        Save: *const fn (*IPersistFile, [*:0]const u16, windows.BOOL) callconv(.winapi) HRESULT,
        SaveCompleted: *const anyopaque,
        GetCurFile: *const anyopaque,
    };
};

extern "ole32" fn CoInitializeEx(?*anyopaque, u32) callconv(.winapi) HRESULT;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;
extern "ole32" fn CoCreateInstance(*const GUID, ?*anyopaque, u32, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT;
extern "shell32" fn SHGetFolderPathW(?windows.HWND, c_int, ?windows.HANDLE, u32, [*]u16) callconv(.winapi) HRESULT;

fn shortcutPath(allocator: std.mem.Allocator, entry: Entry) ![]u8 {
    var folder: [MAX_PATH]u16 = [_]u16{0} ** MAX_PATH;
    const csidl = switch (entry) {
        .start_menu => CSIDL_PROGRAMS,
        .startup => CSIDL_STARTUP,
    };
    if (SHGetFolderPathW(null, csidl, null, SHGFP_TYPE_CURRENT, &folder) < 0) return error.FolderUnavailable;
    const len = std.mem.indexOfScalar(u16, &folder, 0) orelse return error.InvalidFolder;
    const utf8 = try std.unicode.utf16LeToUtf8Alloc(allocator, folder[0..len]);
    defer allocator.free(utf8);
    return std.fs.path.join(allocator, &.{ utf8, "WispTerm.lnk" });
}

pub fn isEnabled(allocator: std.mem.Allocator, entry: Entry) bool {
    const path = shortcutPath(allocator, entry) catch return false;
    defer allocator.free(path);
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

pub fn setEnabled(allocator: std.mem.Allocator, entry: Entry, enabled: bool) !void {
    const path = try shortcutPath(allocator, entry);
    defer allocator.free(path);
    if (!enabled) {
        std.fs.deleteFileAbsolute(path) catch |err| if (err != error.FileNotFound) return err;
        return;
    }

    const exe = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe);
    const dir = std.fs.path.dirname(exe) orelse return error.InvalidExecutablePath;
    const exe_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, exe);
    defer allocator.free(exe_w);
    const dir_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, dir);
    defer allocator.free(dir_w);
    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
    defer allocator.free(path_w);

    const init_hr = CoInitializeEx(null, COINIT_APARTMENTTHREADED);
    defer if (init_hr >= 0) CoUninitialize();

    var raw_link: ?*anyopaque = null;
    if (CoCreateInstance(&CLSID_ShellLink, null, CLSCTX_INPROC_SERVER, &IID_IShellLinkW, &raw_link) < 0) return error.ShortcutCreateFailed;
    const link: *IShellLinkW = @ptrCast(@alignCast(raw_link.?));
    defer _ = link.vtable.Release(link);

    if (link.vtable.SetPath(link, exe_w.ptr) < 0 or
        link.vtable.SetWorkingDirectory(link, dir_w.ptr) < 0 or
        link.vtable.SetIconLocation(link, exe_w.ptr, 0) < 0) return error.ShortcutConfigureFailed;

    var raw_file: ?*anyopaque = null;
    if (link.vtable.QueryInterface(link, &IID_IPersistFile, &raw_file) < 0) return error.ShortcutSaveFailed;
    const file: *IPersistFile = @ptrCast(@alignCast(raw_file.?));
    defer _ = file.vtable.Release(file);
    if (file.vtable.Save(file, path_w.ptr, 1) < 0) return error.ShortcutSaveFailed;
}
