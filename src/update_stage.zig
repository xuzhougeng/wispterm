//! In-place update staging and file swap. Follows magpie's Windows updater
//! (github.com/yetone/magpie internal/update): the new release is unpacked
//! beside the install (`<install>/.update/<tag>/`, same volume, so moving a
//! file in is a rename), then each file is swapped in by renaming the current
//! one aside and renaming the staged one into its place. Windows will not
//! overwrite a running exe or a loaded dll, but it will rename one. A failed
//! swap puts every moved file back (`Journal.rollback`); files moved aside are
//! removed by the next launch (`removeAsideFiles`), once nothing runs them.
//!
//! Pure std file operations: no platform imports, so the swap and rollback
//! run in the fast suite against a temp dir.
const std = @import("std");

/// Directory inside the install that holds downloads and unpacked releases.
pub const staging_dir_name = ".update";
/// Suffix of a file moved aside by a swap. Distinct from a plain `.old` so
/// cleanup never removes a file the user named that way.
pub const aside_suffix = ".wispterm-old";

/// Parse a GitHub release asset digest ("sha256:<64 hex>").
pub fn parseSha256Digest(digest: []const u8) ?[32]u8 {
    const prefix = "sha256:";
    if (!std.mem.startsWith(u8, digest, prefix)) return null;
    const hex = digest[prefix.len..];
    if (hex.len != 64) return null;
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch return null;
    return out;
}

pub fn sha256File(dir: std.fs.Dir, sub_path: []const u8) ![32]u8 {
    var file = try dir.openFile(sub_path, .{});
    defer file.close();
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }
    return hasher.finalResult();
}

pub fn verifySha256(dir: std.fs.Dir, sub_path: []const u8, expected: [32]u8) !void {
    const actual = try sha256File(dir, sub_path);
    if (!std.mem.eql(u8, &actual, &expected)) return error.ChecksumMismatch;
}

/// Unpack `zip_sub_path` (relative to `dir`) into `dest`. Backslash entry
/// names are accepted: Windows PowerShell's Compress-Archive writes them.
/// std.zip rejects absolute and `..` entry names.
pub fn extractZip(dir: std.fs.Dir, zip_sub_path: []const u8, dest: std.fs.Dir) !void {
    var file = try dir.openFile(zip_sub_path, .{});
    defer file.close();
    var read_buf: [16 * 1024]u8 = undefined;
    var reader = file.reader(&read_buf);
    try std.zip.extract(dest, &reader, .{ .allow_backslashes = true });
}

/// Release tags become directory names; accept only what a tag needs.
pub fn isSafeTag(tag: []const u8) bool {
    if (tag.len == 0 or tag.len > 32) return false;
    if (std.mem.eql(u8, tag, ".") or std.mem.eql(u8, tag, "..")) return false;
    for (tag) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '-', '_' => {},
        else => return false,
    };
    return true;
}

/// One swapped file: `rel` now holds the new version; `aside` is where the
/// file it replaced went, or null when the update added a new file.
pub const Entry = struct {
    rel: []u8,
    aside: ?[]u8,
};

/// Record of a swap, newest last, so a failure can undo it.
pub const Journal = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    pub fn deinit(self: *Journal) void {
        for (self.entries.items) |e| {
            self.allocator.free(e.rel);
            if (e.aside) |a| self.allocator.free(a);
        }
        self.entries.deinit(self.allocator);
    }

    /// Put every replaced file back, newest first. Best effort: an entry that
    /// cannot be restored is skipped so the rest still are; the first such
    /// error is returned.
    pub fn rollback(self: *Journal, install: std.fs.Dir) !void {
        var first_err: ?anyerror = null;
        var i = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const e = self.entries.items[i];
            if (e.aside) |aside| {
                // The new file is in place (and may be running if a relaunch
                // started it): move it aside too rather than deleting it.
                const new_aside = asideName(self.allocator, install, e.rel) catch |err| {
                    if (first_err == null) first_err = err;
                    continue;
                };
                defer self.allocator.free(new_aside);
                install.rename(e.rel, new_aside) catch |err| {
                    if (first_err == null) first_err = err;
                    continue;
                };
                install.rename(aside, e.rel) catch |err| {
                    if (first_err == null) first_err = err;
                    continue;
                };
            } else {
                install.deleteFile(e.rel) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => {
                        // In use: at least get it out of the way.
                        const new_aside = asideName(self.allocator, install, e.rel) catch continue;
                        defer self.allocator.free(new_aside);
                        install.rename(e.rel, new_aside) catch {};
                    },
                };
            }
        }
        if (first_err) |err| return err;
    }
};

/// First free `<rel>.wispterm-old`, `<rel>.wispterm-old-2`, ... A file moved
/// aside by an earlier update may still be running, so it cannot be reused.
pub fn asideName(allocator: std.mem.Allocator, install: std.fs.Dir, rel: []const u8) ![]u8 {
    var n: u32 = 1;
    while (n < 1000) : (n += 1) {
        const name = if (n == 1)
            try std.fmt.allocPrint(allocator, "{s}{s}", .{ rel, aside_suffix })
        else
            try std.fmt.allocPrint(allocator, "{s}{s}-{d}", .{ rel, aside_suffix, n });
        install.access(name, .{}) catch |err| switch (err) {
            error.FileNotFound => return name,
            else => {
                allocator.free(name);
                return err;
            },
        };
        allocator.free(name);
    }
    return error.TooManyAsideFiles;
}

/// Relative paths of every file under `staged`, with `main_exe` (if present)
/// moved last: a swap that stops part way then leaves the old program in
/// place. Caller frees with `freePaths`.
pub fn listStagedFiles(allocator: std.mem.Allocator, staged: std.fs.Dir, main_exe: []const u8) ![][]u8 {
    var list: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer freePathList(allocator, &list);
    var main_found: ?[]u8 = null;
    errdefer if (main_found) |m| allocator.free(m);

    var walker = try staged.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        const rel = try allocator.dupe(u8, entry.path);
        if (main_found == null and std.mem.eql(u8, rel, main_exe)) {
            main_found = rel;
            continue;
        }
        list.append(allocator, rel) catch |err| {
            allocator.free(rel);
            return err;
        };
    }
    std.mem.sort([]u8, list.items, {}, lessPath);
    if (main_found) |m| {
        try list.append(allocator, m);
        main_found = null;
    }
    return list.toOwnedSlice(allocator);
}

fn lessPath(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn freePathList(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged([]u8)) void {
    for (list.items) |p| allocator.free(p);
    list.deinit(allocator);
}

pub fn freePaths(allocator: std.mem.Allocator, paths: [][]u8) void {
    for (paths) |p| allocator.free(p);
    allocator.free(paths);
}

/// Move every file of `staged` into `install`, the current file of each name
/// moved aside first. Files the release does not carry are left alone (user
/// plugins, a portable config). On error everything already swapped is put
/// back before returning. On success the caller owns the journal: keep it to
/// roll back if the new version will not start, else `deinit` it.
pub fn swapIn(
    allocator: std.mem.Allocator,
    staged: std.fs.Dir,
    install: std.fs.Dir,
    main_exe: []const u8,
) !Journal {
    const files = try listStagedFiles(allocator, staged, main_exe);
    defer freePaths(allocator, files);
    if (files.len == 0) return error.EmptyUpdate;

    var journal: Journal = .{ .allocator = allocator };
    errdefer {
        journal.rollback(install) catch {};
        journal.deinit();
    }

    for (files) |rel| {
        if (std.fs.path.dirname(rel)) |parent| try install.makePath(parent);

        // Allocate everything before touching the file, so the journal always
        // records each rename that happened.
        try journal.entries.ensureUnusedCapacity(allocator, 1);
        const rel_owned = try allocator.dupe(u8, rel);
        errdefer allocator.free(rel_owned);

        const exists = blk: {
            install.access(rel, .{}) catch |err| switch (err) {
                error.FileNotFound => break :blk false,
                else => return err,
            };
            break :blk true;
        };
        const aside: ?[]u8 = if (exists) try asideName(allocator, install, rel) else null;
        errdefer if (aside) |name| allocator.free(name);

        if (aside) |name| try renameRetrying(install, rel, install, name);
        renameRetrying(staged, rel, install, rel) catch |err| {
            if (aside) |name| install.rename(name, rel) catch {};
            return err;
        };
        journal.entries.appendAssumeCapacity(.{ .rel = rel_owned, .aside = aside });
    }
    return journal;
}

/// An antivirus scanning a new file, or a sync client reading the current
/// one, holds it open for a moment and Windows refuses the rename meanwhile
/// (magpie's asideWaits). Try a few times before giving up.
fn renameRetrying(from_dir: std.fs.Dir, from: []const u8, to_dir: std.fs.Dir, to: []const u8) !void {
    const waits_ms = [_]u64{ 100, 200, 400, 800, 1500 };
    var i: usize = 0;
    while (true) : (i += 1) {
        std.fs.rename(from_dir, from, to_dir, to) catch |err| switch (err) {
            error.AccessDenied, error.FileBusy => {
                if (i >= waits_ms.len) return err;
                std.Thread.sleep(waits_ms[i] * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        return;
    }
}

/// Remove files earlier updates moved aside. One still running (an older
/// window that has not quit yet) cannot be removed and is left for the next
/// launch. Skips the staging directory.
pub fn removeAsideFiles(allocator: std.mem.Allocator, install: std.fs.Dir) void {
    var walker = install.walk(allocator) catch return;
    defer walker.deinit();
    var doomed: std.ArrayListUnmanaged([]u8) = .empty;
    defer freePathList(allocator, &doomed);
    while (walker.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.startsWith(u8, entry.path, staging_dir_name)) continue;
        if (!isAsideName(entry.basename)) continue;
        const p = allocator.dupe(u8, entry.path) catch continue;
        doomed.append(allocator, p) catch allocator.free(p);
    }
    for (doomed.items) |p| install.deleteFile(p) catch {};
}

pub fn isAsideName(name: []const u8) bool {
    if (std.mem.endsWith(u8, name, aside_suffix)) return true;
    const idx = std.mem.lastIndexOf(u8, name, aside_suffix ++ "-") orelse return false;
    const digits = name[idx + aside_suffix.len + 1 ..];
    if (digits.len == 0) return false;
    for (digits) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// Delete the staging directory (downloads and unpacked releases). Best effort.
pub fn removeStaging(install: std.fs.Dir) void {
    install.deleteTree(staging_dir_name) catch {};
}

fn writeFile(dir: std.fs.Dir, sub_path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(sub_path)) |parent| try dir.makePath(parent);
    try dir.writeFile(.{ .sub_path = sub_path, .data = data });
}

fn expectFile(dir: std.fs.Dir, sub_path: []const u8, data: []const u8) !void {
    var buf: [256]u8 = undefined;
    const got = try dir.readFile(sub_path, &buf);
    try std.testing.expectEqualStrings(data, got);
}

test "update_stage: parse sha256 digest" {
    const d = parseSha256Digest("sha256:c0629c7232a4550973d1bb548fe19335d2191767bd4e3c567bddd2d2a44e02a4").?;
    try std.testing.expectEqual(@as(u8, 0xc0), d[0]);
    try std.testing.expectEqual(@as(u8, 0xa4), d[31]);
    try std.testing.expect(parseSha256Digest("sha1:abcd") == null);
    try std.testing.expect(parseSha256Digest("sha256:abcd") == null);
    try std.testing.expect(parseSha256Digest("sha256:zz29c7232a4550973d1bb548fe19335d2191767bd4e3c567bddd2d2a44e02a4") == null);
}

test "update_stage: verifySha256 accepts the right hash and rejects another" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.bin", "abc");
    // sha256("abc")
    const want = parseSha256Digest("sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad").?;
    try verifySha256(tmp.dir, "a.bin", want);
    var wrong = want;
    wrong[0] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, verifySha256(tmp.dir, "a.bin", wrong));
}

test "update_stage: tags that are safe directory names" {
    try std.testing.expect(isSafeTag("v1.45.0"));
    try std.testing.expect(!isSafeTag(""));
    try std.testing.expect(!isSafeTag(".."));
    try std.testing.expect(!isSafeTag("v1/../x"));
    try std.testing.expect(!isSafeTag("v1\\x"));
}

test "update_stage: aside names" {
    try std.testing.expect(isAsideName("wispterm.exe.wispterm-old"));
    try std.testing.expect(isAsideName("wispterm.exe.wispterm-old-3"));
    try std.testing.expect(!isAsideName("wispterm.exe.wispterm-old-"));
    try std.testing.expect(!isAsideName("wispterm.exe.wispterm-old-x"));
    try std.testing.expect(!isAsideName("notes.old"));
}

test "update_stage: asideName skips a name still taken" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    try writeFile(tmp.dir, "wispterm.exe.wispterm-old", "still running");
    const name = try asideName(a, tmp.dir, "wispterm.exe");
    defer a.free(name);
    try std.testing.expectEqualStrings("wispterm.exe.wispterm-old-2", name);
}

test "update_stage: staged files list the main exe last" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const a = std.testing.allocator;
    try writeFile(tmp.dir, "wispterm.exe", "new");
    try writeFile(tmp.dir, "version.txt", "v2");
    try writeFile(tmp.dir, "plugins/skills/a.md", "skill");
    const files = try listStagedFiles(a, tmp.dir, "wispterm.exe");
    defer freePaths(a, files);
    try std.testing.expectEqual(@as(usize, 3), files.len);
    try std.testing.expectEqualStrings("wispterm.exe", files[2]);
}

test "update_stage: swapIn replaces files, adds new ones, keeps the rest" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const a = std.testing.allocator;
    try tmp.dir.makePath("install");
    try tmp.dir.makePath("staged");
    var install = try tmp.dir.openDir("install", .{ .iterate = true });
    defer install.close();
    var staged = try tmp.dir.openDir("staged", .{ .iterate = true });
    defer staged.close();

    try writeFile(install, "wispterm.exe", "old exe");
    try writeFile(install, "version.txt", "v1");
    try writeFile(install, "config", "user config");
    try writeFile(staged, "wispterm.exe", "new exe");
    try writeFile(staged, "version.txt", "v2");
    try writeFile(staged, "plugins/skills/a.md", "skill");

    var journal = try swapIn(a, staged, install, "wispterm.exe");
    defer journal.deinit();

    try expectFile(install, "wispterm.exe", "new exe");
    try expectFile(install, "version.txt", "v2");
    try expectFile(install, "plugins/skills/a.md", "skill");
    try expectFile(install, "config", "user config");
    try expectFile(install, "wispterm.exe.wispterm-old", "old exe");
    try std.testing.expectEqual(@as(usize, 3), journal.entries.items.len);
    try std.testing.expectEqualStrings("wispterm.exe", journal.entries.items[2].rel);

    removeAsideFiles(a, install);
    try std.testing.expectError(error.FileNotFound, install.access("wispterm.exe.wispterm-old", .{}));
    try expectFile(install, "config", "user config");
}

test "update_stage: rollback restores the previous install" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const a = std.testing.allocator;
    try tmp.dir.makePath("install");
    try tmp.dir.makePath("staged");
    var install = try tmp.dir.openDir("install", .{ .iterate = true });
    defer install.close();
    var staged = try tmp.dir.openDir("staged", .{ .iterate = true });
    defer staged.close();

    try writeFile(install, "wispterm.exe", "old exe");
    try writeFile(install, "version.txt", "v1");
    try writeFile(staged, "wispterm.exe", "new exe");
    try writeFile(staged, "version.txt", "v2");
    try writeFile(staged, "added.dll", "new dll");

    var journal = try swapIn(a, staged, install, "wispterm.exe");
    defer journal.deinit();
    try journal.rollback(install);

    try expectFile(install, "wispterm.exe", "old exe");
    try expectFile(install, "version.txt", "v1");
    try std.testing.expectError(error.FileNotFound, install.access("added.dll", .{}));
    // The rolled-back new files sit aside until the next launch cleans up.
    removeAsideFiles(a, install);
    var it = install.iterate();
    var count: usize = 0;
    while (try it.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "update_stage: a swap that fails part way puts back what it moved" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const a = std.testing.allocator;
    try tmp.dir.makePath("install");
    try tmp.dir.makePath("staged");
    var install = try tmp.dir.openDir("install", .{ .iterate = true });
    defer install.close();
    var staged = try tmp.dir.openDir("staged", .{ .iterate = true });
    defer staged.close();

    try writeFile(install, "a.txt", "old a");
    // A file where the release wants a directory: makePath("x") fails after
    // a.txt was already swapped.
    try writeFile(install, "x", "blocking file");
    try writeFile(staged, "a.txt", "new a");
    try writeFile(staged, "x/y", "new y");

    try std.testing.expect(std.meta.isError(swapIn(a, staged, install, "wispterm.exe")));
    try expectFile(install, "a.txt", "old a");
    try expectFile(install, "x", "blocking file");
}

test "update_stage: extractZip unpacks a stored archive" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // Minimal zip with one stored entry "dir/a.txt" = "hi".
    const zip = buildStoredZip("dir/a.txt", "hi");
    try tmp.dir.writeFile(.{ .sub_path = "u.zip", .data = &zip });
    try tmp.dir.makePath("out");
    var out = try tmp.dir.openDir("out", .{});
    defer out.close();
    try extractZip(tmp.dir, "u.zip", out);
    try expectFile(out, "dir/a.txt", "hi");
}

fn buildStoredZip(comptime name: []const u8, comptime data: []const u8) [30 + name.len + data.len + 46 + name.len + 22]u8 {
    var out: [30 + name.len + data.len + 46 + name.len + 22]u8 = undefined;
    var w = std.Io.Writer.fixed(&out);
    const crc = std.hash.Crc32.hash(data);
    // local file header
    w.writeAll(&[_]u8{ 'P', 'K', 3, 4 }) catch unreachable;
    w.writeInt(u16, 20, .little) catch unreachable; // version needed
    w.writeInt(u16, 0, .little) catch unreachable; // flags
    w.writeInt(u16, 0, .little) catch unreachable; // store
    w.writeInt(u16, 0, .little) catch unreachable; // time
    w.writeInt(u16, 0x21, .little) catch unreachable; // date
    w.writeInt(u32, crc, .little) catch unreachable;
    w.writeInt(u32, data.len, .little) catch unreachable;
    w.writeInt(u32, data.len, .little) catch unreachable;
    w.writeInt(u16, name.len, .little) catch unreachable;
    w.writeInt(u16, 0, .little) catch unreachable;
    w.writeAll(name) catch unreachable;
    w.writeAll(data) catch unreachable;
    const cd_offset: u32 = 30 + name.len + data.len;
    // central directory header
    w.writeAll(&[_]u8{ 'P', 'K', 1, 2 }) catch unreachable;
    w.writeInt(u16, 20, .little) catch unreachable; // version made by
    w.writeInt(u16, 20, .little) catch unreachable; // version needed
    w.writeInt(u16, 0, .little) catch unreachable;
    w.writeInt(u16, 0, .little) catch unreachable;
    w.writeInt(u16, 0, .little) catch unreachable;
    w.writeInt(u16, 0x21, .little) catch unreachable;
    w.writeInt(u32, crc, .little) catch unreachable;
    w.writeInt(u32, data.len, .little) catch unreachable;
    w.writeInt(u32, data.len, .little) catch unreachable;
    w.writeInt(u16, name.len, .little) catch unreachable;
    w.writeInt(u16, 0, .little) catch unreachable; // extra
    w.writeInt(u16, 0, .little) catch unreachable; // comment
    w.writeInt(u16, 0, .little) catch unreachable; // disk
    w.writeInt(u16, 0, .little) catch unreachable; // internal attrs
    w.writeInt(u32, 0, .little) catch unreachable; // external attrs
    w.writeInt(u32, 0, .little) catch unreachable; // local header offset
    w.writeAll(name) catch unreachable;
    // end of central directory
    w.writeAll(&[_]u8{ 'P', 'K', 5, 6 }) catch unreachable;
    w.writeInt(u16, 0, .little) catch unreachable;
    w.writeInt(u16, 0, .little) catch unreachable;
    w.writeInt(u16, 1, .little) catch unreachable;
    w.writeInt(u16, 1, .little) catch unreachable;
    w.writeInt(u32, 46 + name.len, .little) catch unreachable;
    w.writeInt(u32, cd_offset, .little) catch unreachable;
    w.writeInt(u16, 0, .little) catch unreachable;
    return out;
}
