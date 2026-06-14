//! Native (no-shell) implementations of the Skill Center's LOCAL-side
//! operations: scanning a skills root and copying a skill directory. The
//! existing flow shells out to a POSIX shell (`find`/`sha256sum`/`tar`) via
//! `remote_file.localPosixExec`, which is unavailable on native Windows (no
//! WSL). These `std.fs`-based equivalents let the local library show up and the
//! local↔local transfer work on every platform. Linux/macOS keep the POSIX path
//! (which preserves their existing hashes); this module is used only where the
//! local host is non-POSIX.
//!
//! The aggregate hash here reproduces the POSIX recipe byte-for-byte so a
//! natively-scanned library skill and a server skill scanned with the shell
//! command compare equal:
//!     cd <dir> && find . -type f | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -d' ' -f1
//! i.e. sha256( for each regular file, in bytewise-sorted "./path" order:
//!              <lowercase-hex sha256 of file content> + "  " + "./path" + "\n" ).
const std = @import("std");
const skill_scan = @import("skill_scan.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

/// Aggregate hash of a skill directory, matching the POSIX scan recipe for the
/// plain-ASCII filenames real skills use. `dir` must be opened iterable. Callers
/// only invoke this on dirs that contain a SKILL.md (≥1 file), so the degenerate
/// empty-dir case (where the shell pipeline would hash a `sha256sum </dev/null`
/// line) never arises. Files whose paths contain whitespace, quotes, or
/// backslashes are dropped to mirror default `xargs` word-splitting; the rarer
/// single-quote case (which makes the shell drop all later-sorted files too) is
/// not byte-replicated — acceptable since skills never use such names.
pub fn aggHashHex(allocator: std.mem.Allocator, dir: std.fs.Dir) ![64]u8 {
    const Item = struct { path: []u8, hex: [64]u8 };
    var items: std.ArrayListUnmanaged(Item) = .empty;
    defer {
        for (items.items) |it| allocator.free(it.path);
        items.deinit(allocator);
    }

    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue; // `find -type f`: regular files only
        // The shell recipe pipes `find` through default `xargs`, which word-splits
        // on whitespace and mangles quotes/backslashes — so a file whose path
        // contains any of these is silently dropped from the shell's aggregate.
        // Drop the same files here to preserve byte parity. (Real skill files are
        // plain ASCII paths, so this never fires in practice; the rarer
        // single-quote case, where the shell also drops every later-sorted file,
        // is not replicated — see the doc comment.)
        if (std.mem.indexOfAny(u8, entry.path, " \t\n'\"\\") != null) continue;
        const hex = try sha256FileHex(entry.dir, entry.basename);
        const path = try findStylePath(allocator, entry.path);
        items.append(allocator, .{ .path = path, .hex = hex }) catch |e| {
            allocator.free(path);
            return e;
        };
    }

    // LC_ALL=C sort == bytewise ascending on the full "./path" string.
    std.mem.sort(Item, items.items, {}, struct {
        fn lt(_: void, a: Item, b: Item) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lt);

    var agg = Sha256.init(.{});
    for (items.items) |it| {
        agg.update(&it.hex);
        agg.update("  "); // sha256sum prints TWO spaces before the filename
        agg.update(it.path);
        agg.update("\n");
    }
    var digest: [32]u8 = undefined;
    agg.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

/// `./` + the path with `/` separators (what `find .` prints). `entry.path` is
/// relative to the walked dir and uses the platform separator (`\` on Windows).
fn findStylePath(allocator: std.mem.Allocator, rel: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, rel.len + 2);
    out[0] = '.';
    out[1] = '/';
    for (rel, 0..) |c, i| out[i + 2] = if (c == '\\') '/' else c;
    return out;
}

fn sha256FileHex(dir: std.fs.Dir, sub_path: []const u8) ![64]u8 {
    var file = try dir.openFile(sub_path, .{});
    defer file.close();
    var h = Sha256.init(.{});
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;
        h.update(buf[0..n]);
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

/// Enumerate `<root_abs>/<name>/SKILL.md` skills natively. Mirrors the POSIX
/// location scan output: rows `{ name, rel_path = "<name>/SKILL.md", agg_hash }`,
/// provider forced to `.claude` (v2 keys by name). Hidden dirs (`.`-prefixed)
/// are skipped, matching the shell's `"$R"/*/` glob — this also skips the
/// `.install-tmp` / `.wispterm-xfer` staging dirs. A missing root yields an
/// empty slice (not an error), matching the shell's "missing root prints
/// nothing".
pub fn scanRows(allocator: std.mem.Allocator, root_abs: []const u8) ![]skill_scan.SkillRow {
    var root = std.fs.openDirAbsolute(root_abs, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => return allocator.alloc(skill_scan.SkillRow, 0),
        else => return e,
    };
    defer root.close();

    var rows: std.ArrayListUnmanaged(skill_scan.SkillRow) = .empty;
    errdefer {
        for (rows.items) |*r| r.deinit(allocator);
        rows.deinit(allocator);
    }

    var it = root.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;

        var sd = root.openDir(entry.name, .{ .iterate = true }) catch continue;
        defer sd.close();
        sd.access("SKILL.md", .{}) catch continue; // no SKILL.md → not a skill
        const hex = aggHashHex(allocator, sd) catch continue;

        const name = try allocator.dupe(u8, entry.name);
        const rel = std.fmt.allocPrint(allocator, "{s}/SKILL.md", .{entry.name}) catch |e| {
            allocator.free(name);
            return e;
        };
        const h = allocator.dupe(u8, &hex) catch |e| {
            allocator.free(name);
            allocator.free(rel);
            return e;
        };
        rows.append(allocator, .{
            .provider = .claude,
            .name = name,
            .rel_path = rel,
            .agg_hash = h,
        }) catch |e| {
            allocator.free(name);
            allocator.free(rel);
            allocator.free(h);
            return e;
        };
    }

    return rows.toOwnedSlice(allocator);
}

/// Native equivalent of `skill_scan.scanLocation` for a local root. A missing
/// root is reachable-but-empty; an unexpected error (OOM / permission) yields an
/// unreachable outcome so the column renders `?` rather than a phantom-empty.
pub fn scanOutcome(allocator: std.mem.Allocator, root_abs: []const u8) skill_scan.ScanOutcome {
    const rows = scanRows(allocator, root_abs) catch {
        return .{ .reachable = false, .rows = &.{} };
    };
    return .{ .reachable = true, .rows = rows };
}

/// `mkdir -p` for an absolute path (std.fs.makeDirAbsolute is single-level).
pub fn ensureDirAbsolute(path: []const u8) !void {
    std.fs.makeDirAbsolute(path) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        error.FileNotFound => {
            const parent = std.fs.path.dirname(path) orelse return e;
            try ensureDirAbsolute(parent);
            std.fs.makeDirAbsolute(path) catch |e2| switch (e2) {
                error.PathAlreadyExists => {},
                else => return e2,
            };
        },
        else => return e,
    };
}

/// Copy every entry of `src` into `dst` (recursive). Symlinks are skipped (the
/// scan/transfer only deals with regular skill files).
fn copyTree(allocator: std.mem.Allocator, src: std.fs.Dir, dst: std.fs.Dir) !void {
    var walker = try src.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| switch (entry.kind) {
        .directory => try dst.makePath(entry.path),
        .file => {
            if (std.fs.path.dirname(entry.path)) |d| try dst.makePath(d);
            try entry.dir.copyFile(entry.basename, dst, entry.path, .{});
        },
        else => {},
    };
}

/// Copy skill `name` from `<src_root>/<name>` to `<dst_root>/<name>`, atomically
/// replacing any existing copy (stage under `<dst_root>/.wispterm-xfer`, then
/// rename). All paths absolute. Used for local↔local deploy/import on hosts
/// without a POSIX shell; both roots are on the same filesystem so the rename is
/// atomic and a failed copy leaves the live skill untouched.
pub fn transferLocalToLocal(
    allocator: std.mem.Allocator,
    src_root_abs: []const u8,
    dst_root_abs: []const u8,
    name: []const u8,
) !void {
    try ensureDirAbsolute(dst_root_abs);

    const staging = try std.fs.path.join(allocator, &.{ dst_root_abs, ".wispterm-xfer" });
    defer allocator.free(staging);
    std.fs.deleteTreeAbsolute(staging) catch {};
    defer std.fs.deleteTreeAbsolute(staging) catch {};

    const staged_skill = try std.fs.path.join(allocator, &.{ staging, name });
    defer allocator.free(staged_skill);
    try ensureDirAbsolute(staged_skill);

    const src_skill = try std.fs.path.join(allocator, &.{ src_root_abs, name });
    defer allocator.free(src_skill);
    {
        var src = try std.fs.openDirAbsolute(src_skill, .{ .iterate = true });
        defer src.close();
        var dst = try std.fs.openDirAbsolute(staged_skill, .{});
        defer dst.close();
        try copyTree(allocator, src, dst);
    } // handles closed before the swap (Windows can't rename an open dir)

    const final = try std.fs.path.join(allocator, &.{ dst_root_abs, name });
    defer allocator.free(final);
    std.fs.deleteTreeAbsolute(final) catch {};
    try std.fs.renameAbsolute(staged_skill, final);
}

// --- Tests ---

const testing = std.testing;

fn contains(rows: []skill_scan.SkillRow, name: []const u8) bool {
    for (rows) |r| if (std.mem.eql(u8, r.name, name)) return true;
    return false;
}

test "skill_local_fs: aggHashHex is content-sensitive and order-independent" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("s1/refs");
    try tmp.dir.writeFile(.{ .sub_path = "s1/SKILL.md", .data = "hello" });
    try tmp.dir.writeFile(.{ .sub_path = "s1/refs/a.md", .data = "AAA" });
    var s1 = try tmp.dir.openDir("s1", .{ .iterate = true });
    defer s1.close();
    const h1 = try aggHashHex(a, s1);

    // Identical content, files created in a different order → identical hash.
    try tmp.dir.makePath("s2/refs");
    try tmp.dir.writeFile(.{ .sub_path = "s2/refs/a.md", .data = "AAA" });
    try tmp.dir.writeFile(.{ .sub_path = "s2/SKILL.md", .data = "hello" });
    var s2 = try tmp.dir.openDir("s2", .{ .iterate = true });
    defer s2.close();
    const h2 = try aggHashHex(a, s2);
    try testing.expectEqualSlices(u8, &h1, &h2);

    // Changed content → different hash.
    try tmp.dir.writeFile(.{ .sub_path = "s2/SKILL.md", .data = "hello!" });
    const h3 = try aggHashHex(a, s2);
    try testing.expect(!std.mem.eql(u8, &h1, &h3));
}

test "skill_local_fs: scanRows lists skill dirs, skips hidden and non-skill dirs" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("alpha");
    try tmp.dir.writeFile(.{ .sub_path = "alpha/SKILL.md", .data = "a" });
    try tmp.dir.makePath("beta");
    try tmp.dir.writeFile(.{ .sub_path = "beta/SKILL.md", .data = "b" });
    try tmp.dir.makePath("noskill");
    try tmp.dir.writeFile(.{ .sub_path = "noskill/readme.md", .data = "x" });
    try tmp.dir.makePath(".hidden");
    try tmp.dir.writeFile(.{ .sub_path = ".hidden/SKILL.md", .data = "h" });

    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);
    const rows = try scanRows(a, root);
    defer skill_scan.freeRows(a, rows);

    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expect(contains(rows, "alpha"));
    try testing.expect(contains(rows, "beta"));
    for (rows) |r| {
        try testing.expect(r.agg_hash != null);
        var buf: [64]u8 = undefined;
        const want = try std.fmt.bufPrint(&buf, "{s}/SKILL.md", .{r.name});
        try testing.expectEqualStrings(want, r.rel_path);
    }
}

test "skill_local_fs: scanOutcome on a missing root is reachable-but-empty" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(base);
    const missing = try std.fs.path.join(a, &.{ base, "does-not-exist" });
    defer a.free(missing);

    var outcome = scanOutcome(a, missing);
    defer outcome.deinit(a);
    try testing.expect(outcome.reachable);
    try testing.expectEqual(@as(usize, 0), outcome.rows.len);
}

test "skill_local_fs: transferLocalToLocal copies and overwrites a skill dir" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("lib/pdf/refs");
    try tmp.dir.writeFile(.{ .sub_path = "lib/pdf/SKILL.md", .data = "v1" });
    try tmp.dir.writeFile(.{ .sub_path = "lib/pdf/refs/x.md", .data = "ref" });

    const src_root = try tmp.dir.realpathAlloc(a, "lib");
    defer a.free(src_root);
    const base = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(base);
    const dst_root = try std.fs.path.join(a, &.{ base, "dst" }); // created by transfer
    defer a.free(dst_root);

    try transferLocalToLocal(a, src_root, dst_root, "pdf");

    {
        var f = try tmp.dir.openFile("dst/pdf/SKILL.md", .{});
        defer f.close();
        const md = try f.readToEndAlloc(a, 100);
        defer a.free(md);
        try testing.expectEqualStrings("v1", md);
    }
    {
        var f = try tmp.dir.openFile("dst/pdf/refs/x.md", .{});
        defer f.close();
        const rx = try f.readToEndAlloc(a, 100);
        defer a.free(rx);
        try testing.expectEqualStrings("ref", rx);
    }

    // Overwrite with new content.
    try tmp.dir.writeFile(.{ .sub_path = "lib/pdf/SKILL.md", .data = "v2" });
    try transferLocalToLocal(a, src_root, dst_root, "pdf");
    {
        var f = try tmp.dir.openFile("dst/pdf/SKILL.md", .{});
        defer f.close();
        const md2 = try f.readToEndAlloc(a, 100);
        defer a.free(md2);
        try testing.expectEqualStrings("v2", md2);
    }
}
