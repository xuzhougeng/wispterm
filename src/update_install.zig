const std = @import("std");
const build_options = @import("build_options");
const platform_process = @import("platform/process.zig");
const platform_update_package = @import("platform/update_package.zig");
const update_check = @import("update_check.zig");

pub const PayloadError = error{
    MissingPhanttyExe,
    MissingUpdaterExe,
    MissingVersionFile,
    MissingPluginsDir,
    MissingRequiredPayloadFile,
    UnsupportedReleasePackage,
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

pub fn runtimePackage(webview_enabled: bool, has_embedded_browser_payload: bool) update_check.ReleasePackage {
    return platform_update_package.runtimePackage(webview_enabled, has_embedded_browser_payload);
}

pub fn defaultPackage() update_check.ReleasePackage {
    return platform_update_package.defaultPackage();
}

fn fileExists(dir: std.fs.Dir, sub_path: []const u8) bool {
    const stat = dir.statFile(sub_path) catch return false;
    return stat.kind == .file;
}

fn dirExists(dir: std.fs.Dir, sub_path: []const u8) bool {
    var child = dir.openDir(sub_path, .{}) catch return false;
    child.close();
    return true;
}

pub fn validatePayloadDirForPackage(dir: std.fs.Dir, package: update_check.ReleasePackage) PayloadError!void {
    const manifest = platform_update_package.payloadManifest(package) catch return error.UnsupportedReleasePackage;
    for (manifest) |entry| {
        const exists = if (entry.directory) dirExists(dir, entry.path) else fileExists(dir, entry.path);
        if (exists) continue;
        if (entry.optional) continue;
        return payloadMissingError(package, entry);
    }
}

fn payloadMissingError(package: update_check.ReleasePackage, entry: platform_update_package.PayloadEntry) PayloadError {
    const path = entry.path;
    if (platform_update_package.mainExecutablePath(package)) |main_exe| {
        if (std.mem.eql(u8, path, main_exe)) return error.MissingPhanttyExe;
    } else |_| {}
    if (platform_update_package.updaterExecutablePath(package)) |updater_exe| {
        if (std.mem.eql(u8, path, updater_exe)) return error.MissingUpdaterExe;
    } else |_| {}
    if (std.mem.eql(u8, path, "version.txt")) return error.MissingVersionFile;
    if (std.mem.eql(u8, path, "plugins")) return error.MissingPluginsDir;
    if (!entry.directory) return error.MissingRequiredPayloadFile;
    return error.UnsupportedReleasePackage;
}

pub fn currentPackage(allocator: std.mem.Allocator) !update_check.ReleasePackage {
    return platform_update_package.currentPackage(allocator, build_options.webview);
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

fn validateZipEntryNames(zip_file: *std.fs.File, read_buf: []u8) !void {
    try zip_file.seekTo(0);
    var reader = zip_file.reader(read_buf);
    var iter = try std.zip.Iterator.init(&reader);
    var filename_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (try iter.next()) |entry| {
        if (entry.filename_len > filename_buf.len) return error.ZipInsufficientBuffer;
        try reader.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        try reader.interface.readSliceAll(filename_buf[0..entry.filename_len]);
        try platform_update_package.validateArchiveEntryName(filename_buf[0..entry.filename_len]);
    }
    try zip_file.seekTo(0);
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
        try validateZipEntryNames(&zip_file, &read_buf);
        var reader = zip_file.reader(&read_buf);
        try std.zip.extract(payload, &reader, .{ .allow_backslashes = true });
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
    package: update_check.ReleasePackage,
    payload_dir: []const u8,
    target_dir: []const u8,
    pid: u32,
) !void {
    const updater_executable = platform_update_package.updaterExecutablePath(package) catch return error.UnsupportedReleasePackage;
    const updater_path = try std.fs.path.join(allocator, &.{ payload_dir, updater_executable });
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
    try platform_process.spawnDetachedWithOptions(allocator, .{
        .argv = &argv,
        .cwd = payload_dir,
        .create_no_window = true,
    });
}

fn writeExecutablePayloadsForTest(dir: std.fs.Dir, package: update_check.ReleasePackage) !void {
    try dir.writeFile(.{ .sub_path = try platform_update_package.mainExecutablePath(package), .data = "exe" });
    try dir.writeFile(.{ .sub_path = try platform_update_package.updaterExecutablePath(package), .data = "updater" });
}

fn makeMainExecutablePayloadDirForTest(dir: std.fs.Dir, package: update_check.ReleasePackage) !void {
    try dir.makeDir(try platform_update_package.mainExecutablePath(package));
}

fn writeUpdaterExecutablePayloadForTest(dir: std.fs.Dir, package: update_check.ReleasePackage) !void {
    try dir.writeFile(.{ .sub_path = try platform_update_package.updaterExecutablePath(package), .data = "updater" });
}

test "update_install: runtime package carries installer requirements" {
    const package_with_required_extra_payload = platform_update_package.packageForScenario(.with_required_embedded_browser_payload);
    const required_extra_manifest = try platform_update_package.payloadManifest(package_with_required_extra_payload);
    try std.testing.expect(!required_extra_manifest[required_extra_manifest.len - 1].optional);

    const package_without_required_extra_payload = platform_update_package.packageForScenario(.baseline);
    const optional_extra_manifest = try platform_update_package.payloadManifest(package_without_required_extra_payload);
    try std.testing.expect(optional_extra_manifest[optional_extra_manifest.len - 1].optional);

    const package_without_embedded_browser_payload = platform_update_package.packageForScenario(.without_embedded_browser_payload);
    const disabled_extra_manifest = try platform_update_package.payloadManifest(package_without_embedded_browser_payload);
    try std.testing.expect(disabled_extra_manifest[disabled_extra_manifest.len - 1].optional);

    const linux = platform_update_package.runtimePackageForOs(.linux, true, true);
    try std.testing.expectEqual(update_check.ReleasePlatform.linux, linux.platform);

    const macos = platform_update_package.runtimePackageForOs(.macos, true, true);
    try std.testing.expectEqual(update_check.ReleasePlatform.macos, macos.platform);
}

test "update_install: payload validation requires packaged files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const portable_package = platform_update_package.packageForScenario(.baseline);
    const package_with_required_extra_payload = platform_update_package.packageForScenario(.with_required_embedded_browser_payload);
    const required_extra_payload = blk: {
        const manifest = try platform_update_package.payloadManifest(package_with_required_extra_payload);
        break :blk manifest[manifest.len - 1].path;
    };

    try writeExecutablePayloadsForTest(tmp.dir, portable_package);
    try tmp.dir.writeFile(.{ .sub_path = "version.txt", .data = "v0.28.0" });
    try tmp.dir.makeDir("plugins");

    try validatePayloadDirForPackage(tmp.dir, portable_package);
    try std.testing.expectError(
        error.MissingRequiredPayloadFile,
        validatePayloadDirForPackage(tmp.dir, package_with_required_extra_payload),
    );

    try tmp.dir.writeFile(.{ .sub_path = required_extra_payload, .data = "extra payload" });
    try validatePayloadDirForPackage(tmp.dir, package_with_required_extra_payload);
}

test "update_install: payload validation rejects directories for required files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const portable_package = platform_update_package.packageForScenario(.baseline);
    try makeMainExecutablePayloadDirForTest(tmp.dir, portable_package);
    try writeUpdaterExecutablePayloadForTest(tmp.dir, portable_package);
    try tmp.dir.writeFile(.{ .sub_path = "version.txt", .data = "v0.28.0" });
    try tmp.dir.makeDir("plugins");
    try std.testing.expectError(
        error.MissingPhanttyExe,
        validatePayloadDirForPackage(tmp.dir, portable_package),
    );
}

test "update_install: payload validation rejects directories for required extra files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const package_with_required_extra_payload = platform_update_package.packageForScenario(.with_required_embedded_browser_payload);
    const required_extra_payload = blk: {
        const manifest = try platform_update_package.payloadManifest(package_with_required_extra_payload);
        break :blk manifest[manifest.len - 1].path;
    };

    try writeExecutablePayloadsForTest(tmp.dir, package_with_required_extra_payload);
    try tmp.dir.writeFile(.{ .sub_path = "version.txt", .data = "v0.28.0" });
    try tmp.dir.makeDir("plugins");
    try tmp.dir.makeDir(required_extra_payload);
    try std.testing.expectError(
        error.MissingRequiredPayloadFile,
        validatePayloadDirForPackage(tmp.dir, package_with_required_extra_payload),
    );
}

test "update_install: payload validation requires plugins directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const portable_package = platform_update_package.packageForScenario(.baseline);
    try writeExecutablePayloadsForTest(tmp.dir, portable_package);
    try tmp.dir.writeFile(.{ .sub_path = "version.txt", .data = "v0.28.0" });

    try std.testing.expectError(error.MissingPluginsDir, validatePayloadDirForPackage(tmp.dir, portable_package));
    try tmp.dir.writeFile(.{ .sub_path = "plugins", .data = "not a directory" });
    try std.testing.expectError(error.MissingPluginsDir, validatePayloadDirForPackage(tmp.dir, portable_package));
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
