const std = @import("std");

const windows = std.os.windows;
const kernel32 = windows.kernel32;

pub const DirectoryWatcher = struct {
    dir_handle: windows.HANDLE,
    event: windows.HANDLE,
    overlapped: windows.OVERLAPPED,
    buf: [4096]u8 align(@alignOf(windows.FILE_NOTIFY_INFORMATION)),
    active: bool,

    pub fn initPath(dir_path: []const u8) ?DirectoryWatcher {
        var dir_path_buf: [windows.PATH_MAX_WIDE]u16 = undefined;
        const dir_path_len = std.unicode.utf8ToUtf16Le(&dir_path_buf, dir_path) catch {
            std.debug.print("ConfigWatcher: failed to convert dir path to UTF-16\n", .{});
            return null;
        };
        dir_path_buf[dir_path_len] = 0;
        const dir_path_z: [*:0]const u16 = dir_path_buf[0..dir_path_len :0];

        const file_flag_backup_semantics = 0x02000000;
        const file_flag_overlapped = 0x40000000;
        const file_list_directory = 0x0001;

        const dir_handle = kernel32.CreateFileW(
            dir_path_z,
            file_list_directory,
            windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
            null,
            windows.OPEN_EXISTING,
            file_flag_backup_semantics | file_flag_overlapped,
            null,
        );

        if (dir_handle == windows.INVALID_HANDLE_VALUE) {
            std.debug.print("ConfigWatcher: failed to open directory\n", .{});
            return null;
        }

        const event = kernel32.CreateEventExW(null, null, 0, 0x001F0003) orelse {
            std.debug.print("ConfigWatcher: failed to create event\n", .{});
            windows.CloseHandle(dir_handle);
            return null;
        };

        var self = DirectoryWatcher{
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
        return self;
    }

    fn startWatch(self: *DirectoryWatcher) void {
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
            windows.FALSE,
            .{ .last_write = true, .file_name = true, .size = true },
            null,
            &self.overlapped,
            null,
        );
        if (result != 0) {
            self.active = true;
        } else {
            const err = kernel32.GetLastError();
            if (err == .IO_PENDING) {
                self.active = true;
            } else {
                self.active = false;
                std.debug.print("ConfigWatcher: ReadDirectoryChangesW failed: {}\n", .{err});
            }
        }
    }

    pub fn hasChanged(self: *DirectoryWatcher) bool {
        if (!self.active) return false;

        const result = kernel32.WaitForSingleObject(self.event, 0);
        if (result != 0) return false;

        self.startWatch();
        return true;
    }

    pub fn deinit(self: *DirectoryWatcher) void {
        _ = kernel32.CancelIo(self.dir_handle);
        windows.CloseHandle(self.event);
        windows.CloseHandle(self.dir_handle);
    }
};
