const std = @import("std");
const platform_local_path = @import("platform/local_path.zig");
const platform_update_package = @import("platform/update_package.zig");

pub const Options = struct {
    pid: u32,
    source: []const u8,
    target: []const u8,
    restart: bool,
};

pub const ManifestEntry = platform_update_package.PayloadEntry;

pub const replacement_manifest = platform_update_package.updaterReplacementManifest();

const absent_marker_dir = ".phantty-backup-absent";

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

pub fn validateOptions(options: Options) ArgError!void {
    if (options.source.len == 0) return error.MissingSource;
    if (options.target.len == 0) return error.MissingTarget;
    if (platform_local_path.absolutePathEqual(options.source, options.target)) return error.SourceEqualsTarget;
    if (!platform_local_path.isAbsoluteInstallPath(options.source)) return error.RelativeSource;
    if (!platform_local_path.isAbsoluteInstallPath(options.target)) return error.RelativeTarget;
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

fn targetEntryRequired(entry: ManifestEntry) bool {
    const package = platform_update_package.updaterReplacementPackage();
    const main_exe = platform_update_package.mainExecutablePath(package) catch return false;
    return std.mem.eql(u8, entry.path, main_exe);
}

fn absentMarkerPath(allocator: std.mem.Allocator, backup: []const u8, index: usize) ![]u8 {
    const name = try std.fmt.allocPrint(allocator, "{d}", .{index});
    defer allocator.free(name);
    return try std.fs.path.join(allocator, &.{ backup, absent_marker_dir, name });
}

fn writeAbsentMarker(allocator: std.mem.Allocator, backup: []const u8, index: usize) !void {
    const marker_dir = try std.fs.path.join(allocator, &.{ backup, absent_marker_dir });
    defer allocator.free(marker_dir);
    try std.fs.cwd().makePath(marker_dir);

    const marker = try absentMarkerPath(allocator, backup, index);
    defer allocator.free(marker);
    var file = try std.fs.createFileAbsolute(marker, .{ .truncate = true });
    file.close();
}

fn absentMarkerExists(allocator: std.mem.Allocator, backup: []const u8, index: usize) bool {
    const marker = absentMarkerPath(allocator, backup, index) catch return false;
    defer allocator.free(marker);
    std.fs.accessAbsolute(marker, .{}) catch return false;
    return true;
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
            if (!targetEntryRequired(entry)) continue;
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
    for (replacement_manifest, 0..) |entry, index| {
        const target_path = try joinAlloc(allocator, target, entry.path);
        defer allocator.free(target_path);
        if (!pathExists(target_path)) {
            try writeAbsentMarker(allocator, backup, index);
            continue;
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
        const target_path = try joinAlloc(allocator, target, entry.path);
        defer allocator.free(target_path);

        if (!pathExists(source_path)) {
            if (entry.optional) {
                try deletePath(target_path, entry.directory);
                continue;
            }
            return error.MissingSourcePayload;
        }

        try deletePath(target_path, entry.directory);
        try copyPath(allocator, source_path, target_path, entry.directory);
    }
}

pub fn restoreBackup(allocator: std.mem.Allocator, backup: []const u8, target: []const u8) bool {
    var restored_all = true;
    for (replacement_manifest, 0..) |entry, index| {
        const backup_path = joinAlloc(allocator, backup, entry.path) catch {
            restored_all = false;
            continue;
        };
        defer allocator.free(backup_path);
        const target_path = joinAlloc(allocator, target, entry.path) catch {
            restored_all = false;
            continue;
        };
        defer allocator.free(target_path);
        if (!pathExists(backup_path)) {
            if (!entry.optional and !absentMarkerExists(allocator, backup, index)) {
                restored_all = false;
                continue;
            }
            deletePath(target_path, entry.directory) catch |err| switch (err) {
                error.FileNotFound => {},
                else => restored_all = false,
            };
            continue;
        }
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
    const package = platform_update_package.updaterReplacementPackage();
    return try std.fs.path.join(allocator, &.{ target, try platform_update_package.mainExecutablePath(package) });
}

fn updaterPackageForTest() @TypeOf(platform_update_package.updaterReplacementPackage()) {
    return platform_update_package.updaterReplacementPackage();
}

fn mainExecutablePayloadPathForTest() []const u8 {
    return platform_update_package.mainExecutablePath(updaterPackageForTest()) catch unreachable;
}

fn updaterExecutablePayloadPathForTest() []const u8 {
    return platform_update_package.updaterExecutablePath(updaterPackageForTest()) catch unreachable;
}

fn manifestEntryForPathForTest(path: []const u8) ManifestEntry {
    for (replacement_manifest) |entry| {
        if (std.mem.eql(u8, entry.path, path)) return entry;
    }
    unreachable;
}

fn mainExecutableManifestEntryForTest() ManifestEntry {
    return manifestEntryForPathForTest(mainExecutablePayloadPathForTest());
}

fn updaterExecutableManifestEntryForTest() ManifestEntry {
    return manifestEntryForPathForTest(updaterExecutablePayloadPathForTest());
}

fn versionManifestEntryForTest() ManifestEntry {
    return manifestEntryForPathForTest("version.txt");
}

test "updater_core: parses updater arguments" {
    const args = [_][]const u8{
        "updater",
        "--pid",
        "123",
        "--source",
        "/tmp/payload",
        "--target",
        "/opt/phantty",
        "--restart",
    };

    const options = try parseArgs(args[1..]);
    try std.testing.expectEqual(@as(u32, 123), options.pid);
    try std.testing.expectEqualStrings("/tmp/payload", options.source);
    try std.testing.expectEqualStrings("/opt/phantty", options.target);
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
        .source = "/opt/phantty",
        .target = "/opt/phantty/",
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

    try expectManifestFileContents(tmp.dir, "target", mainExecutableManifestEntryForTest(), "new exe");
    try expectManifestFileContents(tmp.dir, "target", updaterExecutableManifestEntryForTest(), "new updater");
    try expectManifestFileContents(tmp.dir, "target", versionManifestEntryForTest(), "new version");
    try expectFileContents(tmp.dir, "target/plugins/core.plugin", "new plugin");
    try expectFileContents(tmp.dir, "target/phantty.conf", "user config");
}

test "updater_core: replacement manifest is sourced from release package entries" {
    comptime {
        if (@TypeOf(replacement_manifest[0]) != platform_update_package.PayloadEntry) {
            @compileError("updater replacement manifest must use platform_update_package.PayloadEntry");
        }
    }
}

test "updater_core: missing required source payload fails before target changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writePayload(tmp.dir, "source", "new");
    try deleteManifestPath(tmp.dir, "source", updaterExecutableManifestEntryForTest());
    try writePayload(tmp.dir, "target", "old");

    const source = try tmp.dir.realpathAlloc(std.testing.allocator, "source");
    defer std.testing.allocator.free(source);
    const target = try tmp.dir.realpathAlloc(std.testing.allocator, "target");
    defer std.testing.allocator.free(target);

    try std.testing.expectError(error.MissingSourcePayload, replacePayload(std.testing.allocator, source, target));
    try expectManifestFileContents(tmp.dir, "target", mainExecutableManifestEntryForTest(), "old exe");
    try expectManifestFileContents(tmp.dir, "target", updaterExecutableManifestEntryForTest(), "old updater");
    try expectManifestFileContents(tmp.dir, "target", versionManifestEntryForTest(), "old version");
    try expectFileContents(tmp.dir, "target/plugins/core.plugin", "old plugin");
}

test "updater_core: optional manifest payload missing is allowed" {
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

test "updater_core: optional manifest payload is removed when selected payload omits it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const optional_entry = optionalFileManifestEntry();

    try writePayload(tmp.dir, "source", "new");
    try writePayload(tmp.dir, "target", "old");
    try writeManifestFile(tmp.dir, "target", optional_entry, "stale optional payload");

    const source = try tmp.dir.realpathAlloc(std.testing.allocator, "source");
    defer std.testing.allocator.free(source);
    const target = try tmp.dir.realpathAlloc(std.testing.allocator, "target");
    defer std.testing.allocator.free(target);

    try replacePayload(std.testing.allocator, source, target);

    var optional_path_buf: [256]u8 = undefined;
    const optional_path = try manifestSubPath(&optional_path_buf, "target", optional_entry);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(optional_path, .{}));
    try expectManifestFileContents(tmp.dir, "target", mainExecutableManifestEntryForTest(), "new exe");
}

test "updater_core: restore removes optional target entry absent from backup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const optional_entry = optionalFileManifestEntry();

    try writePayload(tmp.dir, "backup", "old");
    try writePayload(tmp.dir, "target", "new");
    try writeManifestFile(tmp.dir, "target", optional_entry, "new optional payload");

    const backup = try tmp.dir.realpathAlloc(std.testing.allocator, "backup");
    defer std.testing.allocator.free(backup);
    const target = try tmp.dir.realpathAlloc(std.testing.allocator, "target");
    defer std.testing.allocator.free(target);

    try std.testing.expect(restoreBackup(std.testing.allocator, backup, target));
    var optional_path_buf: [256]u8 = undefined;
    const optional_path = try manifestSubPath(&optional_path_buf, "target", optional_entry);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(optional_path, .{}));
    try expectManifestFileContents(tmp.dir, "target", mainExecutableManifestEntryForTest(), "old exe");
}

test "updater_core: restore reports failure for missing required backup entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writePayload(tmp.dir, "backup", "old");
    try writePayload(tmp.dir, "target", "new");
    try deleteManifestPath(tmp.dir, "backup", mainExecutableManifestEntryForTest());

    const backup = try tmp.dir.realpathAlloc(std.testing.allocator, "backup");
    defer std.testing.allocator.free(backup);
    const target = try tmp.dir.realpathAlloc(std.testing.allocator, "target");
    defer std.testing.allocator.free(target);

    try std.testing.expect(!restoreBackup(std.testing.allocator, backup, target));
}

test "updater_core: preflight rejects mismatched manifest kinds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writePayload(tmp.dir, "source", "new");
    try writePayload(tmp.dir, "target", "old");
    try deleteManifestPath(tmp.dir, "source", mainExecutableManifestEntryForTest());
    try makeManifestDirPath(tmp.dir, "source", mainExecutableManifestEntryForTest());

    const source = try tmp.dir.realpathAlloc(std.testing.allocator, "source");
    defer std.testing.allocator.free(source);
    const target = try tmp.dir.realpathAlloc(std.testing.allocator, "target");
    defer std.testing.allocator.free(target);

    try std.testing.expectError(error.MismatchedSourcePayload, preflightReplacement(std.testing.allocator, source, target));
}

test "updater_core: preflight rejects missing required target before changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writePayload(tmp.dir, "source", "new");
    try writePayload(tmp.dir, "target", "old");
    try deleteManifestPath(tmp.dir, "target", mainExecutableManifestEntryForTest());

    const source = try tmp.dir.realpathAlloc(std.testing.allocator, "source");
    defer std.testing.allocator.free(source);
    const target = try tmp.dir.realpathAlloc(std.testing.allocator, "target");
    defer std.testing.allocator.free(target);

    try std.testing.expectError(error.MissingTargetPayload, replacePayload(std.testing.allocator, source, target));
    try expectManifestPathMissing(tmp.dir, "target", mainExecutableManifestEntryForTest());
    try expectManifestFileContents(tmp.dir, "target", versionManifestEntryForTest(), "old version");
    try expectFileContents(tmp.dir, "target/plugins/core.plugin", "old plugin");
}

test "updater_core: missing target updater is repaired from new payload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writePayload(tmp.dir, "source", "new");
    try writePayload(tmp.dir, "target", "old");
    try deleteManifestPath(tmp.dir, "target", updaterExecutableManifestEntryForTest());

    const source = try tmp.dir.realpathAlloc(std.testing.allocator, "source");
    defer std.testing.allocator.free(source);
    const target = try tmp.dir.realpathAlloc(std.testing.allocator, "target");
    defer std.testing.allocator.free(target);

    try replacePayload(std.testing.allocator, source, target);

    try expectManifestFileContents(tmp.dir, "target", mainExecutableManifestEntryForTest(), "new exe");
    try expectManifestFileContents(tmp.dir, "target", updaterExecutableManifestEntryForTest(), "new updater");
    try expectManifestFileContents(tmp.dir, "target", versionManifestEntryForTest(), "new version");
    try expectFileContents(tmp.dir, "target/plugins/core.plugin", "new plugin");
}

test "updater_core: preflight rejects target file manifest entry as directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writePayload(tmp.dir, "source", "new");
    try writePayload(tmp.dir, "target", "old");
    try deleteManifestPath(tmp.dir, "target", mainExecutableManifestEntryForTest());
    try makeManifestDirPath(tmp.dir, "target", mainExecutableManifestEntryForTest());

    const source = try tmp.dir.realpathAlloc(std.testing.allocator, "source");
    defer std.testing.allocator.free(source);
    const target = try tmp.dir.realpathAlloc(std.testing.allocator, "target");
    defer std.testing.allocator.free(target);

    try std.testing.expectError(error.MismatchedTargetPayload, replacePayload(std.testing.allocator, source, target));
    try expectManifestFileContents(tmp.dir, "target", updaterExecutableManifestEntryForTest(), "old updater");
    try expectManifestFileContents(tmp.dir, "target", versionManifestEntryForTest(), "old version");
    try expectFileContents(tmp.dir, "target/plugins/core.plugin", "old plugin");
}

test "updater_core: restore backup reports failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writePayload(tmp.dir, "backup", "old");
    try makeManifestDirPath(tmp.dir, "target", mainExecutableManifestEntryForTest());

    const backup = try tmp.dir.realpathAlloc(std.testing.allocator, "backup");
    defer std.testing.allocator.free(backup);
    const target = try tmp.dir.realpathAlloc(std.testing.allocator, "target");
    defer std.testing.allocator.free(target);

    try std.testing.expect(!restoreBackup(std.testing.allocator, backup, target));
}

fn writePayload(dir: std.fs.Dir, base: []const u8, label: []const u8) !void {
    try dir.makePath(base);

    var path_buf: [256]u8 = undefined;
    var data_buf: [128]u8 = undefined;

    for (replacement_manifest) |entry| {
        const sub_path = try manifestSubPath(&path_buf, base, entry);
        if (entry.directory) {
            try dir.makePath(sub_path);
            continue;
        }
        if (entry.optional) continue;
        try dir.writeFile(.{
            .sub_path = sub_path,
            .data = try payloadDataForTest(&data_buf, entry, label),
        });
    }

    try dir.writeFile(.{
        .sub_path = try std.fmt.bufPrint(&path_buf, "{s}/plugins/core.plugin", .{base}),
        .data = try std.fmt.bufPrint(&data_buf, "{s} plugin", .{label}),
    });
}

fn payloadDataForTest(buf: []u8, entry: ManifestEntry, label: []const u8) ![]const u8 {
    if (std.mem.eql(u8, entry.path, mainExecutablePayloadPathForTest())) {
        return try std.fmt.bufPrint(buf, "{s} exe", .{label});
    }
    if (std.mem.eql(u8, entry.path, updaterExecutablePayloadPathForTest())) {
        return try std.fmt.bufPrint(buf, "{s} updater", .{label});
    }
    if (std.mem.eql(u8, entry.path, versionManifestEntryForTest().path)) {
        return try std.fmt.bufPrint(buf, "{s} version", .{label});
    }
    return try std.fmt.bufPrint(buf, "{s} payload", .{label});
}

fn optionalFileManifestEntry() ManifestEntry {
    for (replacement_manifest) |entry| {
        if (entry.optional and !entry.directory) return entry;
    }
    unreachable;
}

fn manifestSubPath(buf: []u8, base: []const u8, entry: ManifestEntry) ![]const u8 {
    return try std.fmt.bufPrint(buf, "{s}/{s}", .{ base, entry.path });
}

fn deleteManifestPath(dir: std.fs.Dir, base: []const u8, entry: ManifestEntry) !void {
    var path_buf: [256]u8 = undefined;
    try dir.deleteFile(try manifestSubPath(&path_buf, base, entry));
}

fn makeManifestDirPath(dir: std.fs.Dir, base: []const u8, entry: ManifestEntry) !void {
    var path_buf: [256]u8 = undefined;
    try dir.makeDir(try manifestSubPath(&path_buf, base, entry));
}

fn writeManifestFile(dir: std.fs.Dir, base: []const u8, entry: ManifestEntry, data: []const u8) !void {
    var path_buf: [256]u8 = undefined;
    const sub_path = try manifestSubPath(&path_buf, base, entry);
    if (std.fs.path.dirname(sub_path)) |parent| try dir.makePath(parent);
    try dir.writeFile(.{ .sub_path = sub_path, .data = data });
}

fn expectManifestFileContents(dir: std.fs.Dir, base: []const u8, entry: ManifestEntry, expected: []const u8) !void {
    var path_buf: [256]u8 = undefined;
    try expectFileContents(dir, try manifestSubPath(&path_buf, base, entry), expected);
}

fn expectManifestPathMissing(dir: std.fs.Dir, base: []const u8, entry: ManifestEntry) !void {
    var path_buf: [256]u8 = undefined;
    try std.testing.expectError(error.FileNotFound, dir.access(try manifestSubPath(&path_buf, base, entry), .{}));
}

fn expectFileContents(dir: std.fs.Dir, path: []const u8, expected: []const u8) !void {
    const actual = try dir.readFileAlloc(std.testing.allocator, path, 1024);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}
