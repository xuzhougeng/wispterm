//! Pure logic for installing skills from a GitHub URL: parse a github.com
//! tree/blob/repo URL into owner/repo/ref/subpath, build the Git Trees + raw
//! download URLs, and enumerate the SKILL.md-rooted skill directories found in
//! a Trees API response. No network or disk I/O lives here — the AppWindow
//! jobs do the HTTP + file writes. Mirrors the pure-helper style of
//! `skill_update.zig`.
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

/// `https://raw.githubusercontent.com/<owner>/<repo>/<ref>/<path>`
pub fn rawUrl(a: std.mem.Allocator, owner: []const u8, repo: []const u8, ref: []const u8, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "https://raw.githubusercontent.com/{s}/{s}/{s}/{s}", .{ owner, repo, ref, path });
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
    const raw = try rawUrl(a, "o", "r", "main", "skills/foo/SKILL.md");
    defer a.free(raw);
    try std.testing.expectEqualStrings("https://raw.githubusercontent.com/o/r/main/skills/foo/SKILL.md", raw);
}

test "skill_install: parseDefaultBranch reads the field" {
    const a = std.testing.allocator;
    const b = try parseDefaultBranch(a, "{\"name\":\"r\",\"default_branch\":\"master\"}");
    defer a.free(b);
    try std.testing.expectEqualStrings("master", b);
}
