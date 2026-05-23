const std = @import("std");
const build_options = @import("build_options");
const update_check = @import("update_check.zig");

pub const PayloadValidation = struct {
    require_webview2_loader: bool,
};

pub const PayloadError = error{
    MissingPhanttyExe,
    MissingUpdaterExe,
    MissingVersionFile,
    MissingPluginsDir,
    MissingWebView2Loader,
};

pub const PreparedUpdate = struct {
    work_dir: []u8,
    zip_path: []u8,
    payload_dir: []u8,

    pub fn deinit(self: PreparedUpdate, allocator: std.mem.Allocator) void {
        allocator.free(self.work_dir);
        allocator.free(self.zip_path);
        allocator.free(self.payload_dir);
    }
};

pub fn runtimeFlavor(webview_enabled: bool, has_webview2_loader: bool) update_check.PortableFlavor {
    if (!webview_enabled) return .portable_no_webview;
    if (has_webview2_loader) return .portable_webview2;
    return .portable;
}

fn fileExists(dir: std.fs.Dir, sub_path: []const u8) bool {
    var file = dir.openFile(sub_path, .{}) catch return false;
    file.close();
    return true;
}

fn dirExists(dir: std.fs.Dir, sub_path: []const u8) bool {
    var child = dir.openDir(sub_path, .{}) catch return false;
    child.close();
    return true;
}

pub fn validatePayloadDir(dir: std.fs.Dir, options: PayloadValidation) PayloadError!void {
    if (!fileExists(dir, "phantty.exe")) return error.MissingPhanttyExe;
    if (!fileExists(dir, "phantty-updater.exe")) return error.MissingUpdaterExe;
    if (!fileExists(dir, "version.txt")) return error.MissingVersionFile;
    if (!dirExists(dir, "plugins")) return error.MissingPluginsDir;
    if (options.require_webview2_loader and !fileExists(dir, "WebView2Loader.dll")) return error.MissingWebView2Loader;
}

pub fn currentFlavor(allocator: std.mem.Allocator) !update_check.PortableFlavor {
    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);
    const exe_dir = std.fs.path.dirname(exe_path) orelse return .portable;
    const loader_path = try std.fs.path.join(allocator, &.{ exe_dir, "WebView2Loader.dll" });
    defer allocator.free(loader_path);
    const has_loader = blk: {
        var file = std.fs.openFileAbsolute(loader_path, .{}) catch break :blk false;
        file.close();
        break :blk true;
    };
    return runtimeFlavor(build_options.webview, has_loader);
}

pub fn updateWorkDir(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
    const appdata = try std.fs.getAppDataDir(allocator, "Phantty");
    defer allocator.free(appdata);
    return try std.fs.path.join(allocator, &.{ appdata, "updates", version });
}

pub fn prepareWorkPaths(allocator: std.mem.Allocator, version: []const u8, asset_name: []const u8) !PreparedUpdate {
    const work_dir = try updateWorkDir(allocator, version);
    errdefer allocator.free(work_dir);
    const zip_path = try std.fs.path.join(allocator, &.{ work_dir, asset_name });
    errdefer allocator.free(zip_path);
    const payload_dir = try std.fs.path.join(allocator, &.{ work_dir, "payload" });
    errdefer allocator.free(payload_dir);
    return .{ .work_dir = work_dir, .zip_path = zip_path, .payload_dir = payload_dir };
}

fn siblingTempPath(allocator: std.mem.Allocator, path: []const u8, suffix: []const u8) ![]u8 {
    return try std.mem.concat(allocator, u8, &.{ path, suffix });
}

fn replaceDirWithBackup(temp_dir: []const u8, final_dir: []const u8, backup_dir: []const u8) !void {
    std.fs.deleteTreeAbsolute(backup_dir) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    var moved_existing = false;
    if (std.fs.renameAbsolute(final_dir, backup_dir)) {
        moved_existing = true;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    std.fs.renameAbsolute(temp_dir, final_dir) catch |rename_err| {
        if (moved_existing) {
            std.fs.renameAbsolute(backup_dir, final_dir) catch {};
        }
        return rename_err;
    };

    std.fs.deleteTreeAbsolute(backup_dir) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

pub fn extractZipToPayload(zip_path: []const u8, payload_dir: []const u8) !void {
    const temp_payload_dir = try siblingTempPath(std.heap.page_allocator, payload_dir, ".tmp");
    defer std.heap.page_allocator.free(temp_payload_dir);
    const backup_payload_dir = try siblingTempPath(std.heap.page_allocator, payload_dir, ".old");
    defer std.heap.page_allocator.free(backup_payload_dir);

    std.fs.deleteTreeAbsolute(temp_payload_dir) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    errdefer std.fs.deleteTreeAbsolute(temp_payload_dir) catch {};

    try std.fs.makeDirAbsolute(temp_payload_dir);
    {
        var payload = try std.fs.openDirAbsolute(temp_payload_dir, .{});
        defer payload.close();

        var zip_file = try std.fs.openFileAbsolute(zip_path, .{});
        defer zip_file.close();
        var read_buf: [16 * 1024]u8 = undefined;
        var reader = zip_file.reader(&read_buf);
        try std.zip.extract(payload, &reader, .{ .allow_backslashes = false });
    }

    try replaceDirWithBackup(temp_payload_dir, payload_dir, backup_payload_dir);
}

pub fn downloadAsset(allocator: std.mem.Allocator, url: []const u8, zip_path: []const u8) !void {
    if (std.fs.path.dirname(zip_path)) |dir_path| {
        try std.fs.cwd().makePath(dir_path);
    }

    const temp_zip_path = try siblingTempPath(allocator, zip_path, ".part");
    defer allocator.free(temp_zip_path);
    std.fs.deleteFileAbsolute(temp_zip_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    errdefer std.fs.deleteFileAbsolute(temp_zip_path) catch {};

    var client: std.http.Client = .{
        .allocator = allocator,
        .write_buffer_size = 16 * 1024,
    };
    defer client.deinit();

    const status = blk: {
        var out = try std.fs.createFileAbsolute(temp_zip_path, .{ .truncate = true });
        errdefer out.close();
        var file_buf: [16 * 1024]u8 = undefined;
        var writer = out.writer(&file_buf);

        const response = try client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .keep_alive = false,
            .headers = .{ .user_agent = .{ .override = "phantty" } },
            .response_writer = &writer.interface,
        });
        try writer.end();
        out.close();
        break :blk response.status;
    };
    if (status != .ok) return error.DownloadFailed;

    try std.fs.renameAbsolute(temp_zip_path, zip_path);
}

pub fn currentExeDir(allocator: std.mem.Allocator) ![]u8 {
    const exe_path = try std.fs.selfExePathAlloc(allocator);
    errdefer allocator.free(exe_path);
    const exe_dir = std.fs.path.dirname(exe_path) orelse return error.MissingExeDir;
    const owned = try allocator.dupe(u8, exe_dir);
    allocator.free(exe_path);
    return owned;
}

pub fn launchUpdater(
    allocator: std.mem.Allocator,
    payload_dir: []const u8,
    target_dir: []const u8,
    pid: u32,
) !void {
    const updater_path = try std.fs.path.join(allocator, &.{ payload_dir, "phantty-updater.exe" });
    defer allocator.free(updater_path);
    var pid_buf: [32]u8 = undefined;
    const pid_text = try std.fmt.bufPrint(&pid_buf, "{d}", .{pid});
    const argv = [_][]const u8{
        updater_path,
        "--pid",
        pid_text,
        "--source",
        payload_dir,
        "--target",
        target_dir,
        "--restart",
    };
    var child = std.process.Child.init(&argv, allocator);
    child.cwd = payload_dir;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.create_no_window = true;
    try child.spawn();
    std.os.windows.CloseHandle(child.id);
    std.os.windows.CloseHandle(child.thread_handle);
}

test "update_install: runtime flavor preserves current portable flavor" {
    try std.testing.expectEqual(update_check.PortableFlavor.portable_no_webview, runtimeFlavor(false, true));
    try std.testing.expectEqual(update_check.PortableFlavor.portable_webview2, runtimeFlavor(true, true));
    try std.testing.expectEqual(update_check.PortableFlavor.portable, runtimeFlavor(true, false));
}

test "update_install: payload validation requires packaged files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "phantty.exe", .data = "exe" });
    try tmp.dir.writeFile(.{ .sub_path = "phantty-updater.exe", .data = "updater" });
    try tmp.dir.writeFile(.{ .sub_path = "version.txt", .data = "v0.28.0" });
    try tmp.dir.makeDir("plugins");

    try validatePayloadDir(tmp.dir, .{ .require_webview2_loader = false });
    try std.testing.expectError(error.MissingWebView2Loader, validatePayloadDir(tmp.dir, .{ .require_webview2_loader = true }));

    try tmp.dir.writeFile(.{ .sub_path = "WebView2Loader.dll", .data = "dll" });
    try validatePayloadDir(tmp.dir, .{ .require_webview2_loader = true });
}

test "update_install: payload validation rejects directories for required files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("phantty.exe");
    try tmp.dir.writeFile(.{ .sub_path = "phantty-updater.exe", .data = "updater" });
    try tmp.dir.writeFile(.{ .sub_path = "version.txt", .data = "v0.28.0" });
    try tmp.dir.makeDir("plugins");
    try std.testing.expectError(error.MissingPhanttyExe, validatePayloadDir(tmp.dir, .{ .require_webview2_loader = false }));
}

test "update_install: payload validation rejects directory WebView2 loader when required" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "phantty.exe", .data = "exe" });
    try tmp.dir.writeFile(.{ .sub_path = "phantty-updater.exe", .data = "updater" });
    try tmp.dir.writeFile(.{ .sub_path = "version.txt", .data = "v0.28.0" });
    try tmp.dir.makeDir("plugins");
    try tmp.dir.makeDir("WebView2Loader.dll");
    try std.testing.expectError(error.MissingWebView2Loader, validatePayloadDir(tmp.dir, .{ .require_webview2_loader = true }));
}

test "update_install: payload validation requires plugins directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "phantty.exe", .data = "exe" });
    try tmp.dir.writeFile(.{ .sub_path = "phantty-updater.exe", .data = "updater" });
    try tmp.dir.writeFile(.{ .sub_path = "version.txt", .data = "v0.28.0" });

    try std.testing.expectError(error.MissingPluginsDir, validatePayloadDir(tmp.dir, .{ .require_webview2_loader = false }));
    try tmp.dir.writeFile(.{ .sub_path = "plugins", .data = "not a directory" });
    try std.testing.expectError(error.MissingPluginsDir, validatePayloadDir(tmp.dir, .{ .require_webview2_loader = false }));
}

test "update_install: replacing payload preserves old payload until temp moves into place" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("payload");
    try tmp.dir.writeFile(.{ .sub_path = "payload/old.txt", .data = "old" });
    try tmp.dir.makeDir("payload.tmp");
    try tmp.dir.writeFile(.{ .sub_path = "payload.tmp/new.txt", .data = "new" });

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const payload_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "payload" });
    defer std.testing.allocator.free(payload_dir);
    const temp_payload_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "payload.tmp" });
    defer std.testing.allocator.free(temp_payload_dir);
    const backup_payload_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "payload.old" });
    defer std.testing.allocator.free(backup_payload_dir);

    try replaceDirWithBackup(temp_payload_dir, payload_dir, backup_payload_dir);

    try std.testing.expect(!dirExists(tmp.dir, "payload.old"));
    try std.testing.expect(!dirExists(tmp.dir, "payload.tmp"));
    try std.testing.expect(fileExists(tmp.dir, "payload/new.txt"));
    try std.testing.expect(!fileExists(tmp.dir, "payload/old.txt"));
}
