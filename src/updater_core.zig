const std = @import("std");

pub const Options = struct {
    pid: u32,
    source: []const u8,
    target: []const u8,
    restart: bool,
};

pub const ManifestEntry = struct {
    path: []const u8,
    directory: bool = false,
    optional: bool = false,
};

pub const replacement_manifest = [_]ManifestEntry{
    .{ .path = "phantty.exe" },
    .{ .path = "phantty-updater.exe" },
    .{ .path = "version.txt" },
    .{ .path = "plugins", .directory = true },
    .{ .path = "WebView2Loader.dll", .optional = true },
};

pub const ArgError = error{
    MissingPid,
    MissingSource,
    MissingTarget,
    InvalidPid,
    UnknownArgument,
    SourceEqualsTarget,
    RelativeSource,
    RelativeTarget,
};

pub const ReplacementError = error{
    MissingSourcePayload,
    MissingTargetPayload,
    MismatchedSourcePayload,
    MismatchedTargetPayload,
    RollbackFailed,
};

pub fn parseArgs(args: []const []const u8) ArgError!Options {
    var pid: ?u32 = null;
    var source: ?[]const u8 = null;
    var target: ?[]const u8 = null;
    var restart = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--pid")) {
            i += 1;
            if (i >= args.len) return error.MissingPid;
            pid = std.fmt.parseInt(u32, args[i], 10) catch return error.InvalidPid;
        } else if (std.mem.eql(u8, arg, "--source")) {
            i += 1;
            if (i >= args.len) return error.MissingSource;
            source = args[i];
        } else if (std.mem.eql(u8, arg, "--target")) {
            i += 1;
            if (i >= args.len) return error.MissingTarget;
            target = args[i];
        } else if (std.mem.eql(u8, arg, "--restart")) {
            restart = true;
        } else {
            return error.UnknownArgument;
        }
    }

    const options = Options{
        .pid = pid orelse return error.MissingPid,
        .source = source orelse return error.MissingSource,
        .target = target orelse return error.MissingTarget,
        .restart = restart,
    };
    try validateOptions(options);
    return options;
}

fn isAbsoluteWindowsOrNative(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) return true;
    return path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '\\' or path[2] == '/');
}

fn trimTrailingSeparators(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and (path[end - 1] == '\\' or path[end - 1] == '/')) : (end -= 1) {}
    return path[0..end];
}

fn isWindowsDriveAbsolute(path: []const u8) bool {
    return path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '\\' or path[2] == '/');
}

fn windowsAbsolutePathEqual(a: []const u8, b: []const u8) bool {
    if (!isWindowsDriveAbsolute(a) or !isWindowsDriveAbsolute(b)) return false;
    const a_trimmed = trimTrailingSeparators(a);
    const b_trimmed = trimTrailingSeparators(b);
    if (a_trimmed.len != b_trimmed.len) return false;

    for (a_trimmed, b_trimmed) |a_ch, b_ch| {
        const a_norm = if (a_ch == '/') '\\' else std.ascii.toLower(a_ch);
        const b_norm = if (b_ch == '/') '\\' else std.ascii.toLower(b_ch);
        if (a_norm != b_norm) return false;
    }
    return true;
}

fn nativeAbsolutePathEqual(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, trimTrailingSeparators(a), trimTrailingSeparators(b));
}

fn absolutePathEqual(a: []const u8, b: []const u8) bool {
    if (windowsAbsolutePathEqual(a, b)) return true;
    return nativeAbsolutePathEqual(a, b);
}

pub fn validateOptions(options: Options) ArgError!void {
    if (options.source.len == 0) return error.MissingSource;
    if (options.target.len == 0) return error.MissingTarget;
    if (absolutePathEqual(options.source, options.target)) return error.SourceEqualsTarget;
    if (!isAbsoluteWindowsOrNative(options.source)) return error.RelativeSource;
    if (!isAbsoluteWindowsOrNative(options.target)) return error.RelativeTarget;
}

fn joinAlloc(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]u8 {
    return try std.fs.path.join(allocator, &.{ a, b });
}

fn pathExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn deletePath(path: []const u8, directory: bool) !void {
    if (directory) {
        std.fs.deleteTreeAbsolute(path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    } else {
        std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
}

fn copyDirRecursive(allocator: std.mem.Allocator, source: []const u8, target: []const u8) !void {
    try std.fs.cwd().makePath(target);
    var src_dir = try std.fs.openDirAbsolute(source, .{ .iterate = true });
    defer src_dir.close();
    var it = src_dir.iterate();
    while (try it.next()) |entry| {
        const src_child = try joinAlloc(allocator, source, entry.name);
        defer allocator.free(src_child);
        const dst_child = try joinAlloc(allocator, target, entry.name);
        defer allocator.free(dst_child);
        switch (entry.kind) {
            .directory => try copyDirRecursive(allocator, src_child, dst_child),
            .file => try std.fs.copyFileAbsolute(src_child, dst_child, .{}),
            else => {},
        }
    }
}

fn manifestPathKind(path: []const u8) ?std.fs.File.Kind {
    var dir = std.fs.openDirAbsolute(path, .{}) catch {
        const file = std.fs.openFileAbsolute(path, .{}) catch return null;
        file.close();
        return .file;
    };
    dir.close();
    return .directory;
}

fn manifestEntryMatches(path: []const u8, directory: bool) bool {
    const kind = manifestPathKind(path) orelse return false;
    return if (directory) kind == .directory else kind == .file;
}

fn copyPath(allocator: std.mem.Allocator, source: []const u8, target: []const u8, directory: bool) !void {
    if (directory) {
        try copyDirRecursive(allocator, source, target);
    } else {
        try std.fs.copyFileAbsolute(source, target, .{});
    }
}

pub fn preflightReplacement(allocator: std.mem.Allocator, source: []const u8, target: []const u8) ReplacementError!void {
    for (replacement_manifest) |entry| {
        const source_path = joinAlloc(allocator, source, entry.path) catch return error.MissingSourcePayload;
        defer allocator.free(source_path);
        const source_kind = manifestPathKind(source_path);
        if (source_kind == null) {
            if (entry.optional) continue;
            return error.MissingSourcePayload;
        }
        if (!manifestEntryMatches(source_path, entry.directory)) return error.MismatchedSourcePayload;

        const target_path = joinAlloc(allocator, target, entry.path) catch return error.MissingTargetPayload;
        defer allocator.free(target_path);
        const target_kind = manifestPathKind(target_path);
        if (target_kind == null) {
            if (entry.optional) continue;
            return error.MissingTargetPayload;
        }
        if (!manifestEntryMatches(target_path, entry.directory)) return error.MismatchedTargetPayload;
    }
}

pub fn backupDirForSource(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const parent = std.fs.path.dirname(source) orelse return error.MissingSourceParent;
    return try std.fs.path.join(allocator, &.{ parent, "backup" });
}

pub fn backupCurrentPayload(allocator: std.mem.Allocator, target: []const u8, backup: []const u8) !void {
    std.fs.deleteTreeAbsolute(backup) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try std.fs.makeDirAbsolute(backup);
    for (replacement_manifest) |entry| {
        const target_path = try joinAlloc(allocator, target, entry.path);
        defer allocator.free(target_path);
        if (!pathExists(target_path)) {
            if (entry.optional) continue;
            return error.MissingTargetPayload;
        }
        const backup_path = try joinAlloc(allocator, backup, entry.path);
        defer allocator.free(backup_path);
        try copyPath(allocator, target_path, backup_path, entry.directory);
    }
}

pub fn copyNewPayload(allocator: std.mem.Allocator, source: []const u8, target: []const u8) !void {
    for (replacement_manifest) |entry| {
        const source_path = try joinAlloc(allocator, source, entry.path);
        defer allocator.free(source_path);
        if (!pathExists(source_path)) {
            if (entry.optional) continue;
            return error.MissingSourcePayload;
        }
        const target_path = try joinAlloc(allocator, target, entry.path);
        defer allocator.free(target_path);
        try deletePath(target_path, entry.directory);
        try copyPath(allocator, source_path, target_path, entry.directory);
    }
}

pub fn restoreBackup(allocator: std.mem.Allocator, backup: []const u8, target: []const u8) bool {
    var restored_all = true;
    for (replacement_manifest) |entry| {
        const backup_path = joinAlloc(allocator, backup, entry.path) catch {
            restored_all = false;
            continue;
        };
        defer allocator.free(backup_path);
        if (!pathExists(backup_path)) continue;
        const target_path = joinAlloc(allocator, target, entry.path) catch {
            restored_all = false;
            continue;
        };
        defer allocator.free(target_path);
        deletePath(target_path, entry.directory) catch {
            restored_all = false;
            continue;
        };
        copyPath(allocator, backup_path, target_path, entry.directory) catch {
            restored_all = false;
            continue;
        };
    }
    return restored_all;
}

pub fn replacePayload(allocator: std.mem.Allocator, source: []const u8, target: []const u8) !void {
    const backup = try backupDirForSource(allocator, source);
    defer allocator.free(backup);
    try preflightReplacement(allocator, source, target);
    try backupCurrentPayload(allocator, target, backup);
    copyNewPayload(allocator, source, target) catch |err| {
        if (!restoreBackup(allocator, backup, target)) return error.RollbackFailed;
        return err;
    };
}

pub fn targetExePath(allocator: std.mem.Allocator, target: []const u8) ![]u8 {
    return try std.fs.path.join(allocator, &.{ target, "phantty.exe" });
}

test "updater_core: parses updater arguments" {
    const args = [_][]const u8{
        "phantty-updater.exe",
        "--pid",
        "123",
        "--source",
        "C:\\Temp\\payload",
        "--target",
        "C:\\Apps\\Phantty",
        "--restart",
    };

    const options = try parseArgs(args[1..]);
    try std.testing.expectEqual(@as(u32, 123), options.pid);
    try std.testing.expectEqualStrings("C:\\Temp\\payload", options.source);
    try std.testing.expectEqualStrings("C:\\Apps\\Phantty", options.target);
    try std.testing.expect(options.restart);
}

test "updater_core: manifest excludes portable user config" {
    for (replacement_manifest) |entry| {
        try std.testing.expect(!std.mem.eql(u8, entry.path, "phantty.conf"));
    }
}

test "updater_core: rejects equal source and target paths" {
    try std.testing.expectError(error.SourceEqualsTarget, validateOptions(.{
        .pid = 1,
        .source = "C:\\Apps\\Phantty",
        .target = "C:\\Apps\\Phantty",
        .restart = false,
    }));
}

test "updater_core: rejects equal Windows paths ignoring case and trailing separators" {
    try std.testing.expectError(error.SourceEqualsTarget, validateOptions(.{
        .pid = 1,
        .source = "C:\\Apps\\Phantty",
        .target = "c:\\apps\\phantty\\",
        .restart = false,
    }));

    try std.testing.expectError(error.SourceEqualsTarget, validateOptions(.{
        .pid = 1,
        .source = "D:/Tools/Phantty/",
        .target = "d:/tools/phantty",
        .restart = false,
    }));
}

test "updater_core: successful replacement preserves portable user config" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writePayload(tmp.dir, "source", "new");
    try writePayload(tmp.dir, "target", "old");
    try tmp.dir.writeFile(.{ .sub_path = "target/phantty.conf", .data = "user config" });

    const source = try tmp.dir.realpathAlloc(std.testing.allocator, "source");
    defer std.testing.allocator.free(source);
    const target = try tmp.dir.realpathAlloc(std.testing.allocator, "target");
    defer std.testing.allocator.free(target);

    try replacePayload(std.testing.allocator, source, target);

    try expectFileContents(tmp.dir, "target/phantty.exe", "new exe");
    try expectFileContents(tmp.dir, "target/phantty-updater.exe", "new updater");
    try expectFileContents(tmp.dir, "target/version.txt", "new version");
    try expectFileContents(tmp.dir, "target/plugins/core.plugin", "new plugin");
    try expectFileContents(tmp.dir, "target/phantty.conf", "user config");
}

test "updater_core: missing required source payload fails before target changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("source/plugins");
    try tmp.dir.writeFile(.{ .sub_path = "source/phantty.exe", .data = "new exe" });
    try tmp.dir.writeFile(.{ .sub_path = "source/version.txt", .data = "new version" });
    try writePayload(tmp.dir, "target", "old");

    const source = try tmp.dir.realpathAlloc(std.testing.allocator, "source");
    defer std.testing.allocator.free(source);
    const target = try tmp.dir.realpathAlloc(std.testing.allocator, "target");
    defer std.testing.allocator.free(target);

    try std.testing.expectError(error.MissingSourcePayload, replacePayload(std.testing.allocator, source, target));
    try expectFileContents(tmp.dir, "target/phantty.exe", "old exe");
    try expectFileContents(tmp.dir, "target/phantty-updater.exe", "old updater");
    try expectFileContents(tmp.dir, "target/version.txt", "old version");
    try expectFileContents(tmp.dir, "target/plugins/core.plugin", "old plugin");
}

test "updater_core: optional WebView2 missing is allowed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writePayload(tmp.dir, "source", "new");
    try writePayload(tmp.dir, "target", "old");

    const source = try tmp.dir.realpathAlloc(std.testing.allocator, "source");
    defer std.testing.allocator.free(source);
    const target = try tmp.dir.realpathAlloc(std.testing.allocator, "target");
    defer std.testing.allocator.free(target);

    try preflightReplacement(std.testing.allocator, source, target);
    try replacePayload(std.testing.allocator, source, target);
}

test "updater_core: preflight rejects mismatched manifest kinds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writePayload(tmp.dir, "source", "new");
    try writePayload(tmp.dir, "target", "old");
    try tmp.dir.deleteFile("source/phantty.exe");
    try tmp.dir.makeDir("source/phantty.exe");

    const source = try tmp.dir.realpathAlloc(std.testing.allocator, "source");
    defer std.testing.allocator.free(source);
    const target = try tmp.dir.realpathAlloc(std.testing.allocator, "target");
    defer std.testing.allocator.free(target);

    try std.testing.expectError(error.MismatchedSourcePayload, preflightReplacement(std.testing.allocator, source, target));
}

test "updater_core: restore backup reports failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writePayload(tmp.dir, "backup", "old");
    try tmp.dir.makePath("target/phantty.exe");

    const backup = try tmp.dir.realpathAlloc(std.testing.allocator, "backup");
    defer std.testing.allocator.free(backup);
    const target = try tmp.dir.realpathAlloc(std.testing.allocator, "target");
    defer std.testing.allocator.free(target);

    try std.testing.expect(!restoreBackup(std.testing.allocator, backup, target));
}

fn writePayload(dir: std.fs.Dir, base: []const u8, label: []const u8) !void {
    var plugins_buf: [256]u8 = undefined;
    const plugins_path = try std.fmt.bufPrint(&plugins_buf, "{s}/plugins", .{base});
    try dir.makePath(base);
    try dir.makePath(plugins_path);

    var path_buf: [256]u8 = undefined;
    var data_buf: [128]u8 = undefined;

    try dir.writeFile(.{
        .sub_path = try std.fmt.bufPrint(&path_buf, "{s}/phantty.exe", .{base}),
        .data = try std.fmt.bufPrint(&data_buf, "{s} exe", .{label}),
    });
    try dir.writeFile(.{
        .sub_path = try std.fmt.bufPrint(&path_buf, "{s}/phantty-updater.exe", .{base}),
        .data = try std.fmt.bufPrint(&data_buf, "{s} updater", .{label}),
    });
    try dir.writeFile(.{
        .sub_path = try std.fmt.bufPrint(&path_buf, "{s}/version.txt", .{base}),
        .data = try std.fmt.bufPrint(&data_buf, "{s} version", .{label}),
    });
    try dir.writeFile(.{
        .sub_path = try std.fmt.bufPrint(&path_buf, "{s}/plugins/core.plugin", .{base}),
        .data = try std.fmt.bufPrint(&data_buf, "{s} plugin", .{label}),
    });
}

fn expectFileContents(dir: std.fs.Dir, path: []const u8, expected: []const u8) !void {
    const actual = try dir.readFileAlloc(std.testing.allocator, path, 1024);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}
