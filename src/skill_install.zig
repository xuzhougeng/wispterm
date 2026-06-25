//! Pure logic for installing skills from a GitHub URL: parse a github.com
//! tree/blob/repo URL into owner/repo/ref/subpath, build the Git Trees and
//! Contents API download URLs, and enumerate the SKILL.md-rooted skill
//! directories found in a Trees API response. No network or disk I/O lives here
//! — the AppWindow jobs do the HTTP + file writes.
const std = @import("std");

pub const ParseError = error{ NotGithubUrl, MissingRepo };

/// A parsed GitHub location. `ref == null` means "resolve the default branch".
/// `subpath == ""` means the repository root.
pub const RepoRef = struct {
    owner: []u8,
    repo: []u8,
    ref: ?[]u8,
    subpath: []u8,

    pub fn deinit(self: *RepoRef, a: std.mem.Allocator) void {
        a.free(self.owner);
        a.free(self.repo);
        if (self.ref) |r| a.free(r);
        a.free(self.subpath);
        self.* = undefined;
    }

    pub fn clone(self: RepoRef, a: std.mem.Allocator) !RepoRef {
        const owner = try a.dupe(u8, self.owner);
        errdefer a.free(owner);
        const repo = try a.dupe(u8, self.repo);
        errdefer a.free(repo);
        const ref: ?[]u8 = if (self.ref) |r| try a.dupe(u8, r) else null;
        errdefer if (ref) |r| a.free(r);
        const subpath = try a.dupe(u8, self.subpath);
        return .{ .owner = owner, .repo = repo, .ref = ref, .subpath = subpath };
    }
};

/// Parse a github.com URL. Accepts:
///   https://github.com/<owner>/<repo>
///   https://github.com/<owner>/<repo>/tree/<ref>/<subpath...>
///   https://github.com/<owner>/<repo>/blob/<ref>/<dir...>/SKILL.md
/// Tolerates http(s)://, a www. prefix, a trailing slash, and a .git suffix on
/// the repo. v1 assumes <ref> is a single path segment (a slash-free branch, a
/// tag, or a commit SHA). For a blob URL the file segment is dropped so the
/// subpath is the containing directory. Caller owns the result.
pub fn parseGithubUrl(a: std.mem.Allocator, url_in: []const u8) !RepoRef {
    var s = std.mem.trim(u8, url_in, " \t\r\n");
    if (std.mem.startsWith(u8, s, "https://")) {
        s = s["https://".len..];
    } else if (std.mem.startsWith(u8, s, "http://")) {
        s = s["http://".len..];
    }
    if (std.mem.startsWith(u8, s, "www.")) s = s["www.".len..];
    if (!std.mem.startsWith(u8, s, "github.com/")) return ParseError.NotGithubUrl;
    s = s["github.com/".len..];
    while (s.len > 0 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
    if (s.len == 0) return ParseError.MissingRepo;

    var segs: [64][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, s, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (n >= segs.len) break;
        segs[n] = seg;
        n += 1;
    }
    if (n < 2) return ParseError.MissingRepo;

    const owner = segs[0];
    var repo = segs[1];
    if (std.mem.endsWith(u8, repo, ".git")) repo = repo[0 .. repo.len - ".git".len];
    if (owner.len == 0 or repo.len == 0) return ParseError.MissingRepo;

    var ref: ?[]const u8 = null;
    var sp_start: usize = 0;
    var sp_end: usize = 0; // exclusive; [start,end) empty -> subpath ""
    if (n >= 4 and (std.mem.eql(u8, segs[2], "tree") or std.mem.eql(u8, segs[2], "blob"))) {
        ref = segs[3];
        const is_blob = std.mem.eql(u8, segs[2], "blob");
        sp_start = 4;
        sp_end = if (is_blob) n - 1 else n; // blob: drop the file segment
        if (sp_end < sp_start) sp_end = sp_start;
    }

    const owner_o = try a.dupe(u8, owner);
    errdefer a.free(owner_o);
    const repo_o = try a.dupe(u8, repo);
    errdefer a.free(repo_o);
    const ref_o: ?[]u8 = if (ref) |r| try a.dupe(u8, r) else null;
    errdefer if (ref_o) |r| a.free(r);

    var sp: std.ArrayListUnmanaged(u8) = .empty;
    errdefer sp.deinit(a);
    var i = sp_start;
    while (i < sp_end) : (i += 1) {
        if (sp.items.len > 0) try sp.append(a, '/');
        try sp.appendSlice(a, segs[i]);
    }
    const subpath_o = try sp.toOwnedSlice(a);

    return .{ .owner = owner_o, .repo = repo_o, .ref = ref_o, .subpath = subpath_o };
}

/// `https://api.github.com/repos/<owner>/<repo>/git/trees/<ref>?recursive=1`
pub fn treeApiUrl(a: std.mem.Allocator, owner: []const u8, repo: []const u8, ref: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "https://api.github.com/repos/{s}/{s}/git/trees/{s}?recursive=1", .{ owner, repo, ref });
}

/// `https://api.github.com/repos/<owner>/<repo>` (for default_branch).
pub fn repoApiUrl(a: std.mem.Allocator, owner: []const u8, repo: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "https://api.github.com/repos/{s}/{s}", .{ owner, repo });
}

/// `https://api.github.com/repos/<owner>/<repo>/contents/<path>?ref=<ref>` — the
/// GitHub Contents API. Fetched with `Accept: application/vnd.github.raw` it
/// returns the file's raw bytes from the **api.github.com** host, which is far
/// more widely reachable than raw.githubusercontent.com on some networks (the
/// latter is commonly DNS-blocked). Downloads use this so all traffic stays on
/// the same host that enumeration already proved reachable. (Raw responses are
/// served for files up to 1 MiB; larger files would need the blobs API.)
pub fn contentsApiUrl(a: std.mem.Allocator, owner: []const u8, repo: []const u8, path: []const u8, ref: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "https://api.github.com/repos/{s}/{s}/contents/{s}?ref={s}", .{ owner, repo, path, ref });
}

/// Pull `default_branch` from a `/repos/<owner>/<repo>` response. Caller owns.
pub fn parseDefaultBranch(a: std.mem.Allocator, repo_json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, a, repo_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRepoJson;
    const v = parsed.value.object.get("default_branch") orelse return error.InvalidRepoJson;
    if (v != .string) return error.InvalidRepoJson;
    return a.dupe(u8, v.string);
}

// --- Tests ---

test "skill_install: parseGithubUrl tree URL with subpath" {
    const a = std.testing.allocator;
    var r = try parseGithubUrl(a, "https://github.com/fei0810/bear-research-skills/tree/main/skills");
    defer r.deinit(a);
    try std.testing.expectEqualStrings("fei0810", r.owner);
    try std.testing.expectEqualStrings("bear-research-skills", r.repo);
    try std.testing.expectEqualStrings("main", r.ref.?);
    try std.testing.expectEqualStrings("skills", r.subpath);
}

test "skill_install: parseGithubUrl bare repo -> null ref, empty subpath" {
    const a = std.testing.allocator;
    var r = try parseGithubUrl(a, "https://github.com/o/r");
    defer r.deinit(a);
    try std.testing.expectEqual(@as(?[]u8, null), r.ref);
    try std.testing.expectEqualStrings("", r.subpath);
}

test "skill_install: parseGithubUrl strips .git and trailing slash" {
    const a = std.testing.allocator;
    var r = try parseGithubUrl(a, "https://github.com/o/r.git/");
    defer r.deinit(a);
    try std.testing.expectEqualStrings("r", r.repo);
    try std.testing.expectEqual(@as(?[]u8, null), r.ref);
}

test "skill_install: parseGithubUrl blob URL drops the file segment" {
    const a = std.testing.allocator;
    var r = try parseGithubUrl(a, "https://github.com/o/r/blob/main/skills/foo/SKILL.md");
    defer r.deinit(a);
    try std.testing.expectEqualStrings("main", r.ref.?);
    try std.testing.expectEqualStrings("skills/foo", r.subpath);
}

test "skill_install: parseGithubUrl nested subpath" {
    const a = std.testing.allocator;
    var r = try parseGithubUrl(a, "https://github.com/o/r/tree/v1.2/a/b/c");
    defer r.deinit(a);
    try std.testing.expectEqualStrings("v1.2", r.ref.?);
    try std.testing.expectEqualStrings("a/b/c", r.subpath);
}

test "skill_install: parseGithubUrl rejects non-github" {
    try std.testing.expectError(ParseError.NotGithubUrl, parseGithubUrl(std.testing.allocator, "https://gitlab.com/o/r"));
}

test "skill_install: URL builders produce exact strings" {
    const a = std.testing.allocator;
    const t = try treeApiUrl(a, "o", "r", "main");
    defer a.free(t);
    try std.testing.expectEqualStrings("https://api.github.com/repos/o/r/git/trees/main?recursive=1", t);
    const rp = try repoApiUrl(a, "o", "r");
    defer a.free(rp);
    try std.testing.expectEqualStrings("https://api.github.com/repos/o/r", rp);
    const c = try contentsApiUrl(a, "o", "r", "skills/foo/SKILL.md", "main");
    defer a.free(c);
    try std.testing.expectEqualStrings("https://api.github.com/repos/o/r/contents/skills/foo/SKILL.md?ref=main", c);
}

test "skill_install: parseDefaultBranch reads the field" {
    const a = std.testing.allocator;
    const b = try parseDefaultBranch(a, "{\"name\":\"r\",\"default_branch\":\"master\"}");
    defer a.free(b);
    try std.testing.expectEqualStrings("master", b);
}

/// One installable skill discovered in a Trees response. `files` are
/// repo-relative blob paths under `root_path` (including SKILL.md). Owned.
pub const SkillEntry = struct {
    name: []u8,
    root_path: []u8,
    files: [][]u8,

    pub fn deinit(self: *SkillEntry, a: std.mem.Allocator) void {
        a.free(self.name);
        a.free(self.root_path);
        for (self.files) |f| a.free(f);
        a.free(self.files);
        self.* = undefined;
    }

    pub fn clone(self: SkillEntry, a: std.mem.Allocator) !SkillEntry {
        const name = try a.dupe(u8, self.name);
        errdefer a.free(name);
        const root_path = try a.dupe(u8, self.root_path);
        errdefer a.free(root_path);
        var files = try a.alloc([]u8, self.files.len);
        var done: usize = 0;
        errdefer {
            for (files[0..done]) |f| a.free(f);
            a.free(files);
        }
        for (self.files, 0..) |f, i| {
            files[i] = try a.dupe(u8, f);
            done = i + 1;
        }
        return .{ .name = name, .root_path = root_path, .files = files };
    }
};

pub fn freeEntries(a: std.mem.Allocator, entries: []SkillEntry) void {
    for (entries) |*e| e.deinit(a);
    a.free(entries);
}

pub const FindResult = struct {
    entries: []SkillEntry,
    truncated: bool,
};

fn skillDirOf(path: []const u8) ?[]const u8 {
    if (std.mem.endsWith(u8, path, "/SKILL.md")) return path[0 .. path.len - "/SKILL.md".len];
    if (std.mem.eql(u8, path, "SKILL.md")) return ""; // repo-root skill -> empty dir, skipped (name empty)
    return null;
}

fn underSubpath(dir: []const u8, subpath: []const u8) bool {
    if (subpath.len == 0) return true;
    if (std.mem.eql(u8, dir, subpath)) return true;
    return dir.len > subpath.len and std.mem.startsWith(u8, dir, subpath) and dir[subpath.len] == '/';
}

fn isUnderDir(path: []const u8, dir: []const u8) bool {
    return path.len > dir.len and std.mem.startsWith(u8, path, dir) and path[dir.len] == '/';
}

fn baseName(dir: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, dir, '/')) |i| return dir[i + 1 ..];
    return dir;
}

fn entryLessThan(_: void, x: SkillEntry, y: SkillEntry) bool {
    return std.mem.order(u8, x.name, y.name) == .lt;
}

/// Enumerate skills in a Git Trees (`?recursive=1`) response: every directory
/// that directly contains a `SKILL.md` blob and that is `subpath` itself or
/// nested under `subpath` (any directory when subpath == ""). Each entry
/// bundles every blob under its directory (so nested `references/` files come
/// along). Sorted by name; deduped by directory. Caller owns the result.
pub fn findSkills(a: std.mem.Allocator, tree_json: []const u8, subpath: []const u8) !FindResult {
    var parsed = try std.json.parseFromSlice(std.json.Value, a, tree_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidTree;

    const truncated = blk: {
        const t = parsed.value.object.get("truncated") orelse break :blk false;
        break :blk (t == .bool and t.bool);
    };
    const tree = parsed.value.object.get("tree") orelse return error.InvalidTree;
    if (tree != .array) return error.InvalidTree;

    var blobs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer blobs.deinit(a);
    for (tree.array.items) |item| {
        if (item != .object) continue;
        const ty = item.object.get("type") orelse continue;
        if (ty != .string or !std.mem.eql(u8, ty.string, "blob")) continue;
        const p = item.object.get("path") orelse continue;
        if (p != .string) continue;
        try blobs.append(a, p.string);
    }

    var entries: std.ArrayListUnmanaged(SkillEntry) = .empty;
    errdefer {
        for (entries.items) |*e| e.deinit(a);
        entries.deinit(a);
    }

    for (blobs.items) |p| {
        const dir = skillDirOf(p) orelse continue;
        if (dir.len == 0) continue; // repo-root SKILL.md -> no name; skip
        if (!underSubpath(dir, subpath)) continue;

        var seen = false;
        for (entries.items) |e| {
            if (std.mem.eql(u8, e.root_path, dir)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;

        var files: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (files.items) |f| a.free(f);
            files.deinit(a);
        }
        for (blobs.items) |q| {
            if (isUnderDir(q, dir)) {
                const dup = try a.dupe(u8, q);
                errdefer a.free(dup);
                try files.append(a, dup);
            }
        }

        const name_o = try a.dupe(u8, baseName(dir));
        errdefer a.free(name_o);
        const dir_o = try a.dupe(u8, dir);
        errdefer a.free(dir_o);
        const files_o = try files.toOwnedSlice(a);
        errdefer {
            for (files_o) |f| a.free(f);
            a.free(files_o);
        }
        try entries.append(a, .{ .name = name_o, .root_path = dir_o, .files = files_o });
    }

    std.sort.insertion(SkillEntry, entries.items, {}, entryLessThan);
    return .{ .entries = try entries.toOwnedSlice(a), .truncated = truncated };
}

/// Path under which a skill file should be staged/installed: the blob path with
/// the skill directory's *parent* prefix stripped, so it begins with the skill
/// name. `root_path == "skills/foo"`, `file == "skills/foo/references/x.md"` ->
/// `"foo/references/x.md"`. Returns null if `file` is not under `root_path`'s
/// parent. When `root_path` has no parent, `file` already starts with the name.
pub fn relInstallPath(root_path: []const u8, file_path: []const u8) ?[]const u8 {
    if (std.mem.lastIndexOfScalar(u8, root_path, '/')) |idx| {
        const parent = root_path[0..idx];
        if (file_path.len > parent.len and std.mem.startsWith(u8, file_path, parent) and file_path[parent.len] == '/')
            return file_path[parent.len + 1 ..];
        return null;
    }
    return file_path;
}

const sample_tree =
    \\{"sha":"x","truncated":false,"tree":[
    \\{"path":"skills","type":"tree"},
    \\{"path":"skills/bear-map","type":"tree"},
    \\{"path":"skills/bear-map/SKILL.md","type":"blob"},
    \\{"path":"skills/bear-map/references","type":"tree"},
    \\{"path":"skills/bear-map/references/sci-cli.md","type":"blob"},
    \\{"path":"skills/bear-counter/SKILL.md","type":"blob"},
    \\{"path":"README.md","type":"blob"}
    \\]}
;

test "skill_install: findSkills enumerates skill dirs under subpath, bundling subtrees" {
    const a = std.testing.allocator;
    const res = try findSkills(a, sample_tree, "skills");
    defer freeEntries(a, res.entries);
    try std.testing.expect(!res.truncated);
    try std.testing.expectEqual(@as(usize, 2), res.entries.len);
    // sorted by name: bear-counter, bear-map
    try std.testing.expectEqualStrings("bear-counter", res.entries[0].name);
    try std.testing.expectEqualStrings("bear-map", res.entries[1].name);
    try std.testing.expectEqualStrings("skills/bear-map", res.entries[1].root_path);
    // bear-map bundles SKILL.md + references file
    try std.testing.expectEqual(@as(usize, 2), res.entries[1].files.len);
}

test "skill_install: findSkills with subpath pointing at one skill dir" {
    const a = std.testing.allocator;
    const res = try findSkills(a, sample_tree, "skills/bear-map");
    defer freeEntries(a, res.entries);
    try std.testing.expectEqual(@as(usize, 1), res.entries.len);
    try std.testing.expectEqualStrings("bear-map", res.entries[0].name);
}

test "skill_install: findSkills at repo root finds all skills" {
    const a = std.testing.allocator;
    const res = try findSkills(a, sample_tree, "");
    defer freeEntries(a, res.entries);
    try std.testing.expectEqual(@as(usize, 2), res.entries.len);
}

test "skill_install: findSkills reports truncated and empty results" {
    const a = std.testing.allocator;
    const res = try findSkills(a, "{\"truncated\":true,\"tree\":[]}", "skills");
    defer freeEntries(a, res.entries);
    try std.testing.expect(res.truncated);
    try std.testing.expectEqual(@as(usize, 0), res.entries.len);
}

test "skill_install: relInstallPath strips the skill dir's parent prefix" {
    try std.testing.expectEqualStrings("foo/SKILL.md", relInstallPath("skills/foo", "skills/foo/SKILL.md").?);
    try std.testing.expectEqualStrings("foo/references/x.md", relInstallPath("skills/foo", "skills/foo/references/x.md").?);
    try std.testing.expectEqualStrings("foo/SKILL.md", relInstallPath("foo", "foo/SKILL.md").?);
    try std.testing.expectEqual(@as(?[]const u8, null), relInstallPath("skills/foo", "other/x.md"));
}

test "skill_install: SkillEntry.clone is an independent deep copy" {
    const a = std.testing.allocator;
    var orig: SkillEntry = .{
        .name = try a.dupe(u8, "foo"),
        .root_path = try a.dupe(u8, "skills/foo"),
        .files = try a.alloc([]u8, 1),
    };
    orig.files[0] = try a.dupe(u8, "skills/foo/SKILL.md");
    var copy = try orig.clone(a);
    orig.deinit(a); // free original first; copy must be independent
    defer copy.deinit(a);
    try std.testing.expectEqualStrings("foo", copy.name);
    try std.testing.expectEqualStrings("skills/foo", copy.root_path);
    try std.testing.expectEqual(@as(usize, 1), copy.files.len);
    try std.testing.expectEqualStrings("skills/foo/SKILL.md", copy.files[0]);
}
