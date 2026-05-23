const std = @import("std");
const builtin = @import("builtin");

extern "kernel32" fn CompareStringOrdinal(
    lpString1: [*]const u16,
    cchCount1: i32,
    lpString2: [*]const u16,
    cchCount2: i32,
    bIgnoreCase: i32,
) callconv(.winapi) i32;

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

fn isAbsoluteWindowsOrNative(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) return true;
    return isWindowsAbsolute(path);
}

fn windowsRootLen(path: []const u8) usize {
    if (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '\\' or path[2] == '/')) return 3;

    if (path.len >= 4 and (path[0] == '\\' or path[0] == '/') and (path[1] == '\\' or path[1] == '/') and path[2] == '?' and (path[3] == '\\' or path[3] == '/')) {
        if (path.len >= 8 and std.ascii.eqlIgnoreCase(path[4..7], "UNC") and (path[7] == '\\' or path[7] == '/')) {
            return uncRootLenFrom(path, 8);
        }
        if (path.len >= 7 and std.ascii.isAlphabetic(path[4]) and path[5] == ':' and (path[6] == '\\' or path[6] == '/')) return 7;
        return 4;
    }

    if (path.len >= 2 and (path[0] == '\\' or path[0] == '/') and (path[1] == '\\' or path[1] == '/')) {
        return uncRootLenFrom(path, 2);
    }

    return 0;
}

fn canonicalWindowsPath(path: []const u8) []const u8 {
    if (path.len >= 7 and (path[0] == '\\' or path[0] == '/') and (path[1] == '\\' or path[1] == '/') and path[2] == '?' and (path[3] == '\\' or path[3] == '/') and std.ascii.isAlphabetic(path[4]) and path[5] == ':' and (path[6] == '\\' or path[6] == '/')) {
        return path[4..];
    }
    return path;
}

fn uncRootLenFrom(path: []const u8, start: usize) usize {
    const server_end = findSeparator(path, start) orelse return path.len;
    const share_start = server_end + 1;
    const share_end = findSeparator(path, share_start) orelse return path.len;
    return share_end;
}

fn findSeparator(path: []const u8, start: usize) ?usize {
    var i = start;
    while (i < path.len) : (i += 1) {
        if (path[i] == '\\' or path[i] == '/') return i;
    }
    return null;
}

fn trimTrailingSeparators(path: []const u8, root_len: usize) []const u8 {
    var end = path.len;
    while (end > root_len and (path[end - 1] == '\\' or path[end - 1] == '/')) : (end -= 1) {}
    return path[0..end];
}

fn isWindowsAbsolute(path: []const u8) bool {
    return windowsRootLen(path) > 0;
}

fn normalizeWindowsPath(path: []const u8, buf: []u8) ?[]const u8 {
    var out_len: usize = 0;
    if (path.len >= 8 and (path[0] == '\\' or path[0] == '/') and (path[1] == '\\' or path[1] == '/') and path[2] == '?' and (path[3] == '\\' or path[3] == '/') and std.ascii.eqlIgnoreCase(path[4..7], "UNC") and (path[7] == '\\' or path[7] == '/')) {
        if (buf.len < 2) return null;
        buf[0] = '\\';
        buf[1] = '\\';
        out_len = 2;
        for (path[8..]) |ch| {
            if (out_len >= buf.len) return null;
            buf[out_len] = if (ch == '/') '\\' else ch;
            out_len += 1;
        }
    } else {
        const source = canonicalWindowsPath(path);
        for (source) |ch| {
            if (out_len >= buf.len) return null;
            buf[out_len] = if (ch == '/') '\\' else ch;
            out_len += 1;
        }
    }

    const normalized = buf[0..out_len];
    const root_len = windowsRootLen(normalized);
    if (root_len == 0) return null;
    return trimTrailingSeparators(normalized, root_len);
}

fn simpleWindowsCaseFold(codepoint: u21) u21 {
    if (codepoint >= 'A' and codepoint <= 'Z') return codepoint + 0x20;
    if (codepoint >= 0x00C0 and codepoint <= 0x00D6) return codepoint + 0x20;
    if (codepoint >= 0x00D8 and codepoint <= 0x00DE) return codepoint + 0x20;
    if (codepoint == 0x0178) return 0x00FF;
    if (codepoint >= 0x0100 and codepoint <= 0x0177 and codepoint % 2 == 0) return codepoint + 1;
    if (codepoint >= 0x0181 and codepoint <= 0x024E) {
        return switch (codepoint) {
            0x0181 => 0x0253,
            0x0182, 0x0184, 0x0187, 0x018B, 0x0191, 0x0198, 0x01A0, 0x01A2, 0x01A4, 0x01A7, 0x01AC, 0x01AF, 0x01B3, 0x01B5, 0x01B8, 0x01BC, 0x01CD, 0x01CF, 0x01D1, 0x01D3, 0x01D5, 0x01D7, 0x01D9, 0x01DB, 0x01DE, 0x01E0, 0x01E2, 0x01E4, 0x01E6, 0x01E8, 0x01EA, 0x01EC, 0x01EE, 0x01F4, 0x01F8, 0x01FA, 0x01FC, 0x01FE, 0x0200, 0x0202, 0x0204, 0x0206, 0x0208, 0x020A, 0x020C, 0x020E, 0x0210, 0x0212, 0x0214, 0x0216, 0x0218, 0x021A, 0x021C, 0x021E, 0x0220, 0x0222, 0x0224, 0x0226, 0x0228, 0x022A, 0x022C, 0x022E, 0x0230, 0x0232, 0x0246, 0x0248, 0x024A, 0x024C, 0x024E => codepoint + 1,
            0x0186 => 0x0254,
            0x0189 => 0x0256,
            0x018A => 0x0257,
            0x018E => 0x01DD,
            0x018F => 0x0259,
            0x0190 => 0x025B,
            0x0193 => 0x0260,
            0x0194 => 0x0263,
            0x0196 => 0x0269,
            0x0197 => 0x0268,
            0x019C => 0x026F,
            0x019D => 0x0272,
            0x019F => 0x0275,
            0x01A6 => 0x0280,
            0x01A9 => 0x0283,
            0x01AE => 0x0288,
            0x01B1 => 0x028A,
            0x01B2 => 0x028B,
            0x01B7 => 0x0292,
            0x01F1, 0x01F2 => 0x01F3,
            0x023A => 0x2C65,
            0x023B => 0x023C,
            0x023D => 0x019A,
            0x023E => 0x2C66,
            0x0241 => 0x0242,
            0x0243 => 0x0180,
            0x0244 => 0x0289,
            0x0245 => 0x028C,
            else => codepoint,
        };
    }
    if (codepoint >= 0x0391 and codepoint <= 0x03A1) return codepoint + 0x20;
    if (codepoint >= 0x03A3 and codepoint <= 0x03AB) return codepoint + 0x20;
    if (codepoint == 0x0386) return 0x03AC;
    if (codepoint >= 0x0388 and codepoint <= 0x038A) return codepoint + 0x25;
    if (codepoint == 0x038C) return 0x03CC;
    if (codepoint >= 0x038E and codepoint <= 0x038F) return codepoint + 0x3F;
    if (codepoint >= 0x0400 and codepoint <= 0x040F) return codepoint + 0x50;
    if (codepoint >= 0x0410 and codepoint <= 0x042F) return codepoint + 0x20;
    return codepoint;
}

fn windowsCaseInsensitiveUtf8Equal(a: []const u8, b: []const u8) bool {
    if (comptime builtin.os.tag == .windows) {
        if (windowsCaseInsensitiveUtf16Equal(a, b)) |equal| return equal;
    }

    const a_view = std.unicode.Utf8View.init(a) catch return std.mem.eql(u8, a, b);
    const b_view = std.unicode.Utf8View.init(b) catch return std.mem.eql(u8, a, b);
    var a_it = a_view.iterator();
    var b_it = b_view.iterator();
    while (true) {
        const a_cp = a_it.nextCodepoint();
        const b_cp = b_it.nextCodepoint();
        if (a_cp == null or b_cp == null) return a_cp == null and b_cp == null;
        if (simpleWindowsCaseFold(a_cp.?) != simpleWindowsCaseFold(b_cp.?)) return false;
    }
}

fn windowsCaseInsensitiveUtf16Equal(a: []const u8, b: []const u8) ?bool {
    var a_buf: [4096]u16 = undefined;
    var b_buf: [4096]u16 = undefined;
    const a_len = std.unicode.utf8ToUtf16Le(&a_buf, a) catch return null;
    const b_len = std.unicode.utf8ToUtf16Le(&b_buf, b) catch return null;
    const result = CompareStringOrdinal(
        a_buf[0..a_len].ptr,
        @intCast(a_len),
        b_buf[0..b_len].ptr,
        @intCast(b_len),
        1,
    );
    return switch (result) {
        2 => true,
        1, 3 => false,
        else => null,
    };
}

fn windowsAbsolutePathEqual(a: []const u8, b: []const u8) bool {
    var a_buf: [4096]u8 = undefined;
    var b_buf: [4096]u8 = undefined;
    const a_normalized = normalizeWindowsPath(a, &a_buf) orelse return false;
    const b_normalized = normalizeWindowsPath(b, &b_buf) orelse return false;
    return windowsCaseInsensitiveUtf8Equal(a_normalized, b_normalized);
}

fn nativeAbsolutePathEqual(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, trimTrailingSeparators(a, 1), trimTrailingSeparators(b, 1));
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

fn targetEntryRequired(entry: ManifestEntry) bool {
    return std.mem.eql(u8, entry.path, "phantty.exe");
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

test "updater_core: rejects equal Windows paths with non-ASCII case differences" {
    try std.testing.expectError(error.SourceEqualsTarget, validateOptions(.{
        .pid = 1,
        .source = "C:\\Apps\\Ångström",
        .target = "c:\\apps\\ångström\\",
        .restart = false,
    }));
}

test "updater_core: rejects equal UNC Windows paths ignoring case and trailing separators" {
    try std.testing.expectError(error.SourceEqualsTarget, validateOptions(.{
        .pid = 1,
        .source = "\\\\Server\\Share\\Apps\\Phantty",
        .target = "\\\\server\\share\\apps\\phantty\\",
        .restart = false,
    }));

    try std.testing.expectError(error.SourceEqualsTarget, validateOptions(.{
        .pid = 1,
        .source = "//Server/Share/Apps/Phantty",
        .target = "\\\\server\\share\\apps\\phantty",
        .restart = false,
    }));
}

test "updater_core: rejects equal extended Windows paths ignoring case and trailing separators" {
    try std.testing.expectError(error.SourceEqualsTarget, validateOptions(.{
        .pid = 1,
        .source = "\\\\?\\C:\\Apps\\Phantty",
        .target = "\\\\?\\c:\\apps\\phantty\\",
        .restart = false,
    }));

    try std.testing.expectError(error.SourceEqualsTarget, validateOptions(.{
        .pid = 1,
        .source = "\\\\?\\UNC\\Server\\Share\\Apps\\Phantty",
        .target = "\\\\?\\UNC\\server\\share\\apps\\phantty\\",
        .restart = false,
    }));
}

test "updater_core: rejects equal extended and non-extended Windows paths" {
    try std.testing.expectError(error.SourceEqualsTarget, validateOptions(.{
        .pid = 1,
        .source = "\\\\?\\C:\\Apps\\Phantty",
        .target = "C:\\Apps\\Phantty",
        .restart = false,
    }));

    try std.testing.expectError(error.SourceEqualsTarget, validateOptions(.{
        .pid = 1,
        .source = "\\\\?\\UNC\\Server\\Share\\App",
        .target = "\\\\server\\share\\App",
        .restart = false,
    }));
}

test "updater_core: rejects equal UNC share roots with optional trailing separator" {
    try std.testing.expectError(error.SourceEqualsTarget, validateOptions(.{
        .pid = 1,
        .source = "\\\\server\\share",
        .target = "\\\\SERVER\\SHARE\\",
        .restart = false,
    }));

    try std.testing.expectError(error.SourceEqualsTarget, validateOptions(.{
        .pid = 1,
        .source = "\\\\?\\UNC\\server\\share",
        .target = "\\\\server\\share\\",
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

test "updater_core: optional WebView2 is removed when selected payload omits it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writePayload(tmp.dir, "source", "new");
    try writePayload(tmp.dir, "target", "old");
    try tmp.dir.writeFile(.{ .sub_path = "target/WebView2Loader.dll", .data = "stale dll" });

    const source = try tmp.dir.realpathAlloc(std.testing.allocator, "source");
    defer std.testing.allocator.free(source);
    const target = try tmp.dir.realpathAlloc(std.testing.allocator, "target");
    defer std.testing.allocator.free(target);

    try replacePayload(std.testing.allocator, source, target);

    try std.testing.expectError(error.FileNotFound, tmp.dir.access("target/WebView2Loader.dll", .{}));
    try expectFileContents(tmp.dir, "target/phantty.exe", "new exe");
}

test "updater_core: restore removes optional target entry absent from backup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writePayload(tmp.dir, "backup", "old");
    try writePayload(tmp.dir, "target", "new");
    try tmp.dir.writeFile(.{ .sub_path = "target/WebView2Loader.dll", .data = "new dll" });

    const backup = try tmp.dir.realpathAlloc(std.testing.allocator, "backup");
    defer std.testing.allocator.free(backup);
    const target = try tmp.dir.realpathAlloc(std.testing.allocator, "target");
    defer std.testing.allocator.free(target);

    try std.testing.expect(restoreBackup(std.testing.allocator, backup, target));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("target/WebView2Loader.dll", .{}));
    try expectFileContents(tmp.dir, "target/phantty.exe", "old exe");
}

test "updater_core: restore reports failure for missing required backup entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writePayload(tmp.dir, "backup", "old");
    try writePayload(tmp.dir, "target", "new");
    try tmp.dir.deleteFile("backup/phantty.exe");

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
    try tmp.dir.deleteFile("source/phantty.exe");
    try tmp.dir.makeDir("source/phantty.exe");

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
    try tmp.dir.deleteFile("target/phantty.exe");

    const source = try tmp.dir.realpathAlloc(std.testing.allocator, "source");
    defer std.testing.allocator.free(source);
    const target = try tmp.dir.realpathAlloc(std.testing.allocator, "target");
    defer std.testing.allocator.free(target);

    try std.testing.expectError(error.MissingTargetPayload, replacePayload(std.testing.allocator, source, target));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("target/phantty.exe", .{}));
    try expectFileContents(tmp.dir, "target/version.txt", "old version");
    try expectFileContents(tmp.dir, "target/plugins/core.plugin", "old plugin");
}

test "updater_core: missing target updater is repaired from new payload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writePayload(tmp.dir, "source", "new");
    try writePayload(tmp.dir, "target", "old");
    try tmp.dir.deleteFile("target/phantty-updater.exe");

    const source = try tmp.dir.realpathAlloc(std.testing.allocator, "source");
    defer std.testing.allocator.free(source);
    const target = try tmp.dir.realpathAlloc(std.testing.allocator, "target");
    defer std.testing.allocator.free(target);

    try replacePayload(std.testing.allocator, source, target);

    try expectFileContents(tmp.dir, "target/phantty.exe", "new exe");
    try expectFileContents(tmp.dir, "target/phantty-updater.exe", "new updater");
    try expectFileContents(tmp.dir, "target/version.txt", "new version");
    try expectFileContents(tmp.dir, "target/plugins/core.plugin", "new plugin");
}

test "updater_core: preflight rejects target file manifest entry as directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writePayload(tmp.dir, "source", "new");
    try writePayload(tmp.dir, "target", "old");
    try tmp.dir.deleteFile("target/phantty.exe");
    try tmp.dir.makeDir("target/phantty.exe");

    const source = try tmp.dir.realpathAlloc(std.testing.allocator, "source");
    defer std.testing.allocator.free(source);
    const target = try tmp.dir.realpathAlloc(std.testing.allocator, "target");
    defer std.testing.allocator.free(target);

    try std.testing.expectError(error.MismatchedTargetPayload, replacePayload(std.testing.allocator, source, target));
    try expectFileContents(tmp.dir, "target/phantty-updater.exe", "old updater");
    try expectFileContents(tmp.dir, "target/version.txt", "old version");
    try expectFileContents(tmp.dir, "target/plugins/core.plugin", "old plugin");
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
