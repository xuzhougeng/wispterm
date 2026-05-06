/// Watches the config file directory for changes using ReadDirectoryChangesW.
///
/// Usage:
///   var watcher = ConfigWatcher.init(allocator);
///   defer if (watcher) |*w| w.deinit();
///
///   // In main loop:
///   if (watcher) |*w| {
///       if (w.hasChanged()) { /* reload config */ }
///   }
const std = @import("std");
const Config = @import("config.zig");

const windows = std.os.windows;
const kernel32 = windows.kernel32;

const ConfigWatcher = @This();

dir_handle: windows.HANDLE,
event: windows.HANDLE,
overlapped: windows.OVERLAPPED,
buf: [4096]u8 align(@alignOf(windows.FILE_NOTIFY_INFORMATION)),
active: bool,

/// Open the config directory and start watching for changes.
pub fn init(allocator: std.mem.Allocator) ?ConfigWatcher {
    const path = Config.configFilePath(allocator) catch |err| {
        std.debug.print("ConfigWatcher: failed to get config path: {}\n", .{err});
        return null;
    };
    defer allocator.free(path);

    const dir_path = std.fs.path.dirname(path) orelse {
        std.debug.print("ConfigWatcher: failed to get directory from path\n", .{});
        return null;
    };

    // Open directory with FILE_FLAG_OVERLAPPED | FILE_FLAG_BACKUP_SEMANTICS
    // Required for async ReadDirectoryChangesW on a directory handle.
    const dir_path_w = std.unicode.utf8ToUtf16LeStringLiteral(""); // placeholder
    _ = dir_path_w;

    // We need a UTF-16 path for CreateFileW
    var dir_path_buf: [windows.PATH_MAX_WIDE]u16 = undefined;
    const dir_path_len = std.unicode.utf8ToUtf16Le(&dir_path_buf, dir_path) catch {
        std.debug.print("ConfigWatcher: failed to convert dir path to UTF-16\n", .{});
        return null;
    };
    dir_path_buf[dir_path_len] = 0;
    const dir_path_z: [*:0]const u16 = dir_path_buf[0..dir_path_len :0];

    const FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
    const FILE_FLAG_OVERLAPPED = 0x40000000;
    const FILE_LIST_DIRECTORY = 0x0001;

    const dir_handle = kernel32.CreateFileW(
        dir_path_z,
        FILE_LIST_DIRECTORY,
        windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
        null,
        windows.OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED,
        null,
    );

    if (dir_handle == windows.INVALID_HANDLE_VALUE) {
        std.debug.print("ConfigWatcher: failed to open directory\n", .{});
        return null;
    }

    // Create an auto-reset event for overlapped I/O
    const event = kernel32.CreateEventExW(null, null, 0, 0x001F0003) orelse {
        std.debug.print("ConfigWatcher: failed to create event\n", .{});
        windows.CloseHandle(dir_handle);
        return null;
    };

    var self = ConfigWatcher{
        .dir_handle = dir_handle,
        .event = event,
        .overlapped = .{
            .Internal = 0,
            .InternalHigh = 0,
            .DUMMYUNIONNAME = .{ .Pointer = null },
            .hEvent = event,
        },
        .buf = undefined,
        .active = false,
    };

    self.startWatch();
    std.debug.print("ConfigWatcher: watching {s}\n", .{dir_path});
    return self;
}

/// Issue an async ReadDirectoryChangesW call.
fn startWatch(self: *ConfigWatcher) void {
    self.overlapped = .{
        .Internal = 0,
        .InternalHigh = 0,
        .DUMMYUNIONNAME = .{ .Pointer = null },
        .hEvent = self.event,
    };

    const result = kernel32.ReadDirectoryChangesW(
        self.dir_handle,
        &self.buf,
        self.buf.len,
        windows.FALSE, // don't watch subtree
        .{ .last_write = true, .file_name = true, .size = true },
        null, // bytes returned (not used for async)
        &self.overlapped,
        null, // no completion routine, we use the event
    );
    if (result != 0) {
        self.active = true;
    } else {
        // For overlapped I/O, FALSE with ERROR_IO_PENDING means the operation
        // was successfully queued and is still active.
        const err = kernel32.GetLastError();
        if (err == .IO_PENDING) {
            self.active = true;
        } else {
            self.active = false;
            std.debug.print("ConfigWatcher: ReadDirectoryChangesW failed: {}\n", .{err});
        }
    }
}

/// Non-blocking check: has the directory changed?
/// If true, the caller should reload the config. The watch is
/// automatically re-armed.
pub fn hasChanged(self: *ConfigWatcher) bool {
    if (!self.active) return false;

    // Non-blocking wait (timeout = 0)
    const result = kernel32.WaitForSingleObject(self.event, 0);
    if (result != 0) return false; // WAIT_OBJECT_0 == 0

    // Event signaled — directory changed. Re-arm the watch.
    self.startWatch();
    return true;
}

pub fn deinit(self: *ConfigWatcher) void {
    // Always cancel pending IO before closing the handle
    _ = kernel32.CancelIo(self.dir_handle);
    windows.CloseHandle(self.event);
    windows.CloseHandle(self.dir_handle);
}
