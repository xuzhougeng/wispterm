# Install Skills from a GitHub URL — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user paste a GitHub URL (e.g. `https://github.com/fei0810/bear-research-skills/tree/main/skills`) into the Skill Center, pick which skills under that path to install, and download them into the local library (`<config>/skills`), where the existing deploy flow takes over.

**Architecture:** A new pure module `src/skill_install.zig` parses the URL and enumerates skills via the GitHub Git Trees API (the same pattern `skill_update.zig` already uses for wisptermʼs own skills). The Skill Center gains two background ops — *enumerate* (fetch tree → list skills for a checklist) and *download* (fetch selected skills → atomic-install into the library) — reusing the existing `startOp`/`OpResult`/overlay machinery. A new `g` key opens a URL-input overlay; a checklist overlay follows.

**Tech Stack:** Zig, `std.http.Client` (via the existing `update_install` helpers), `std.json`, the Skill Center v2 model/renderer/session.

**Spec:** `docs/superpowers/specs/2026-06-13-install-skills-from-github-design.md`

---

## File Structure

- **Create:** `src/skill_install.zig` — pure: `RepoRef`, `SkillEntry`/`FindResult`, `parseGithubUrl`, `treeApiUrl`/`repoApiUrl`/`rawUrl`, `parseDefaultBranch`, `findSkills`, `relInstallPath`. No I/O. Fully unit-tested.
- **Modify:** `src/skill_center.zig` — two new `OpResult` variants (`install_enumerate`, `install_done`) and two new `Overlay` variants (`url_input: UrlInputState`, `install_pick: InstallPickState`) with their state structs + edit/selection helpers + `deinit` arms + tests.
- **Modify:** `src/renderer/skill_center_renderer.zig` — a new `input: InputView` overlay variant + render branch (URL prompt + editable line). The checklist reuses the existing `list` overlay (checkbox encoded in the label).
- **Modify:** `src/update_install.zig` — add `httpGetAlloc` (GET a URL into memory), sibling of `downloadAsset`.
- **Modify:** `src/AppWindow.zig` — `SkillInstallEnumerateJob` + `SkillInstallDownloadJob`; `downloadSelectedSkillsToLibrary` (impure install); URL-input open/insert/backspace/paste/submit; install-pick toggle/select-all/confirm; render-frame overlay mapping + `skillCenterMove`/`skillCenterOverlaySelect`/`skillCenterSpacePreview` arms; `pollSkillCenterOp` branches.
- **Modify:** `src/input.zig` — `g` opens URL input; gate `r/d/i/g`/space shortcuts when text-capturing; backspace + typed chars + Ctrl+V routed to the URL buffer; space/`a` routed to the checklist.
- **Modify:** `src/input/clipboard.zig` — expose `readClipboardTextOwned`.
- **Modify:** `src/i18n.zig` — new `sc_*` strings (en + zh) + updated `sc_legend_v2`.
- **Modify:** `src/test_fast.zig`, `src/test_main.zig` — register `skill_install.zig`.

**Conventions verified in this codebase:**
- `zig build test` runs the fast native suite (where pure-module tests execute on this host). `zig build test-full` compiles the full suite (default target `windows-gnu`). A pre-existing unrelated failure in `web_read_cache.zig` under the windows target is expected and not caused by this work.
- Pure modules are registered in *both* `src/test_fast.zig` and `src/test_main.zig`.
- Background ops implement `skill_center.OpWork` (`run(ctx, allocator) OpResult` + `destroy`), are started via `Session.startOp(work, wake, busy_msg)`, and their results consumed in `pollSkillCenterOp` via `Session.takePendingOp()`.
- `update_install.downloadAsset(allocator, url, dest_abs)` HTTP-GETs to an **absolute** path and `makePath`s the parent dir.

---

## Phase 1 — Pure module `src/skill_install.zig`

### Task 1: `RepoRef` + `parseGithubUrl` + register in test suites

**Files:**
- Create: `src/skill_install.zig`
- Modify: `src/test_fast.zig` (near line 94, beside the other `skill_*` imports)
- Modify: `src/test_main.zig` (near line 761, beside the other `skill_*` imports)

- [ ] **Step 1: Create the module with `RepoRef`, `parseGithubUrl`, and failing tests**

```zig
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
```

- [ ] **Step 2: Register the module in both test suites**

In `src/test_fast.zig`, beside the other `skill_*` imports (after line 94's `_ = @import("skill_scan.zig");`):

```zig
    _ = @import("skill_install.zig");
```

In `src/test_main.zig`, beside the other `skill_*` imports (after line 761's `_ = @import("skill_scan.zig");`):

```zig
    _ = @import("skill_install.zig");
```

- [ ] **Step 3: Run the fast suite to verify the tests pass**

Run: `zig build test`
Expected: PASS (the suite compiles `skill_install.zig` and all six parse tests pass). If it fails, fix `parseGithubUrl` until green.

- [ ] **Step 4: Commit**

```bash
git add src/skill_install.zig src/test_fast.zig src/test_main.zig
git commit -m "feat(skill-install): parse GitHub tree/blob/repo URLs into RepoRef"
```

---

### Task 2: API + raw URL builders + `parseDefaultBranch`

**Files:**
- Modify: `src/skill_install.zig`

- [ ] **Step 1: Add the builders + parser with failing tests**

Append to `src/skill_install.zig` (before the `// --- Tests ---` line, move that marker down — or add a second test block at the end):

```zig
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
```

Add tests at the end of the file:

```zig
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
```

- [ ] **Step 2: Run the fast suite**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add src/skill_install.zig
git commit -m "feat(skill-install): tree/repo/raw URL builders + parseDefaultBranch"
```

---

### Task 3: `SkillEntry` + `findSkills` + `relInstallPath`

**Files:**
- Modify: `src/skill_install.zig`

- [ ] **Step 1: Add the types, enumerator, helper, and failing tests**

Append to `src/skill_install.zig`:

```zig
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
            if (isUnderDir(q, dir)) try files.append(a, try a.dupe(u8, q));
        }

        const name_o = try a.dupe(u8, baseName(dir));
        errdefer a.free(name_o);
        const dir_o = try a.dupe(u8, dir);
        errdefer a.free(dir_o);
        const files_o = try files.toOwnedSlice(a);
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
```

Add tests at the end (the `sample_tree` mirrors the real `bear-research-skills` layout, condensed to two skills):

```zig
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
    var res = try findSkills(a, sample_tree, "skills");
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
    var res = try findSkills(a, sample_tree, "skills/bear-map");
    defer freeEntries(a, res.entries);
    try std.testing.expectEqual(@as(usize, 1), res.entries.len);
    try std.testing.expectEqualStrings("bear-map", res.entries[0].name);
}

test "skill_install: findSkills at repo root finds all skills" {
    const a = std.testing.allocator;
    var res = try findSkills(a, sample_tree, "");
    defer freeEntries(a, res.entries);
    try std.testing.expectEqual(@as(usize, 2), res.entries.len);
}

test "skill_install: findSkills reports truncated and empty results" {
    const a = std.testing.allocator;
    var res = try findSkills(a, "{\"truncated\":true,\"tree\":[]}", "skills");
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
```

- [ ] **Step 2: Run the fast suite**

Run: `zig build test`
Expected: PASS (all `findSkills`/`relInstallPath` tests green). The testing allocator also verifies there are no leaks in the owned `SkillEntry`/`files` slices.

- [ ] **Step 3: Commit**

```bash
git add src/skill_install.zig
git commit -m "feat(skill-install): findSkills enumerator + relInstallPath staging helper"
```

---

## Phase 2 — Skill Center model additions `src/skill_center.zig`

### Task 4: New `OpResult` variants `install_enumerate` + `install_done`

**Files:**
- Modify: `src/skill_center.zig` (add `const install = @import("skill_install.zig");` at the top beside `const scan = ...`; extend the `OpResult` union near line 257 and its `deinit` near line 269)

- [ ] **Step 1: Add the import and the two variants + deinit arms**

At the top of `src/skill_center.zig`, after `const scan = @import("skill_scan.zig");`:

```zig
const install = @import("skill_install.zig");
```

In the `OpResult` union (after the `preview` variant, before `failed`):

```zig
    /// install-enumerate finished: show the checklist built from `entries`.
    install_enumerate: struct { repo: install.RepoRef, entries: []install.SkillEntry, truncated: bool },
    /// install-download finished: report counts via toast.
    install_done: struct { installed: usize, overwritten: usize, failed: usize },
```

In `OpResult.deinit`, add arms (before the `.failed => {}` arm):

```zig
            .install_enumerate => |*v| {
                v.repo.deinit(allocator);
                install.freeEntries(allocator, v.entries);
            },
            .install_done => {},
```

- [ ] **Step 2: Add a leak-safety test**

Add to the test section of `src/skill_center.zig`:

```zig
test "skill_center: OpResult.install_enumerate deinit frees repo and entries" {
    const a = std.testing.allocator;
    var repo = try install.parseGithubUrl(a, "https://github.com/o/r/tree/main/skills");
    errdefer repo.deinit(a);
    var entries = try a.alloc(install.SkillEntry, 1);
    {
        var files = try a.alloc([]u8, 1);
        files[0] = try a.dupe(u8, "skills/foo/SKILL.md");
        entries[0] = .{ .name = try a.dupe(u8, "foo"), .root_path = try a.dupe(u8, "skills/foo"), .files = files };
    }
    var r: OpResult = .{ .install_enumerate = .{ .repo = repo, .entries = entries, .truncated = false } };
    r.deinit(a); // testing allocator catches a leak
    try std.testing.expect(r == .failed);
}

test "skill_center: OpResult.install_done deinit is a no-op" {
    const a = std.testing.allocator;
    var r: OpResult = .{ .install_done = .{ .installed = 3, .overwritten = 1, .failed = 0 } };
    r.deinit(a);
    try std.testing.expect(r == .failed);
}
```

- [ ] **Step 3: Run the fast suite**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/skill_center.zig
git commit -m "feat(skill-center): OpResult install_enumerate + install_done variants"
```

---

### Task 5: `UrlInputState` + `url_input` overlay

**Files:**
- Modify: `src/skill_center.zig` (add `UrlInputState`; extend the `Overlay` union near line 155 and its `deinit` near line 162)

- [ ] **Step 1: Add `UrlInputState`, the overlay variant, deinit arm, and tests**

Add the state struct near the other overlay state structs (e.g. after `ConfirmState`):

```zig
/// Editable single-line URL buffer for the "install from GitHub" overlay.
pub const UrlInputState = struct {
    buf: std.ArrayListUnmanaged(u8) = .empty,

    pub fn insertSlice(self: *UrlInputState, allocator: std.mem.Allocator, bytes: []const u8) void {
        self.buf.appendSlice(allocator, bytes) catch {};
    }
    pub fn backspace(self: *UrlInputState) void {
        if (self.buf.items.len > 0) self.buf.items.len -= 1;
    }
    pub fn text(self: *const UrlInputState) []const u8 {
        return self.buf.items;
    }
    fn deinit(self: *UrlInputState, allocator: std.mem.Allocator) void {
        self.buf.deinit(allocator);
        self.* = undefined;
    }
};
```

In the `Overlay` union, add (after `busy`):

```zig
    url_input: UrlInputState,
```

In `Overlay.deinit`, add an arm:

```zig
            .url_input => |*u| u.deinit(allocator),
```

Add a test:

```zig
test "skill_center: UrlInputState edits and frees" {
    const a = std.testing.allocator;
    var m = PanelModel.init(a);
    defer m.deinit();
    m.setOverlay(.{ .url_input = .{} });
    switch (m.overlay) {
        .url_input => |*u| {
            u.insertSlice(a, "https://github.com/o/r");
            u.backspace();
            try std.testing.expectEqualStrings("https://github.com/o/", u.text());
        },
        else => return error.WrongOverlay,
    }
    // PanelModel.deinit frees the overlay buffer; testing allocator catches leaks.
}
```

- [ ] **Step 2: Run the fast suite**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add src/skill_center.zig
git commit -m "feat(skill-center): url_input overlay state for GitHub install"
```

---

### Task 6: `InstallPickState` + `install_pick` overlay

**Files:**
- Modify: `src/skill_center.zig`

- [ ] **Step 1: Add `InstallPickState`, the overlay variant, deinit arm, and tests**

Add the state struct (after `UrlInputState`):

```zig
/// Checklist of skills enumerated from a GitHub URL. Owns the resolved RepoRef
/// (with its ref filled in) and the entry list; `checked` is parallel to
/// `entries`. `sel` is the cursor row.
pub const InstallPickState = struct {
    repo: install.RepoRef,
    entries: []install.SkillEntry,
    checked: []bool,
    sel: usize = 0,

    pub fn toggle(self: *InstallPickState) void {
        if (self.sel < self.checked.len) self.checked[self.sel] = !self.checked[self.sel];
    }
    pub fn setAll(self: *InstallPickState, value: bool) void {
        for (self.checked) |*c| c.* = value;
    }
    pub fn anyChecked(self: *const InstallPickState) bool {
        for (self.checked) |c| if (c) return true;
        return false;
    }
    /// Owned clone of just the checked entries (caller frees via freeEntries).
    pub fn selectedEntries(self: *const InstallPickState, allocator: std.mem.Allocator) ![]install.SkillEntry {
        var out: std.ArrayListUnmanaged(install.SkillEntry) = .empty;
        errdefer {
            for (out.items) |*e| e.deinit(allocator);
            out.deinit(allocator);
        }
        for (self.entries, 0..) |e, i| {
            if (i < self.checked.len and self.checked[i]) try out.append(allocator, try e.clone(allocator));
        }
        return out.toOwnedSlice(allocator);
    }
    fn deinit(self: *InstallPickState, allocator: std.mem.Allocator) void {
        self.repo.deinit(allocator);
        install.freeEntries(allocator, self.entries);
        allocator.free(self.checked);
        self.* = undefined;
    }
};
```

In the `Overlay` union, add (after `url_input`):

```zig
    install_pick: InstallPickState,
```

In `Overlay.deinit`, add an arm:

```zig
            .install_pick => |*p| p.deinit(allocator),
```

Add a test:

```zig
test "skill_center: InstallPickState toggle/setAll/selectedEntries" {
    const a = std.testing.allocator;
    var repo = try install.parseGithubUrl(a, "https://github.com/o/r/tree/main/skills");
    errdefer repo.deinit(a);
    var entries = try a.alloc(install.SkillEntry, 2);
    inline for (.{ "a", "b" }, 0..) |nm, i| {
        var files = try a.alloc([]u8, 1);
        files[0] = try std.fmt.allocPrint(a, "skills/{s}/SKILL.md", .{nm});
        entries[i] = .{ .name = try a.dupe(u8, nm), .root_path = try std.fmt.allocPrint(a, "skills/{s}", .{nm}), .files = files };
    }
    const checked = try a.alloc(bool, 2);
    checked[0] = false;
    checked[1] = false;

    var m = PanelModel.init(a);
    defer m.deinit();
    m.setOverlay(.{ .install_pick = .{ .repo = repo, .entries = entries, .checked = checked } });
    switch (m.overlay) {
        .install_pick => |*p| {
            p.sel = 1;
            p.toggle();
            try std.testing.expect(p.anyChecked());
            const sel = try p.selectedEntries(a);
            defer install.freeEntries(a, sel);
            try std.testing.expectEqual(@as(usize, 1), sel.len);
            try std.testing.expectEqualStrings("b", sel[0].name);
            p.setAll(true);
        },
        else => return error.WrongOverlay,
    }
}
```

- [ ] **Step 2: Run the fast suite**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add src/skill_center.zig
git commit -m "feat(skill-center): install_pick checklist overlay state"
```

---

## Phase 3 — Renderer

### Task 7: `input` overlay variant in `skill_center_renderer.zig`

**Files:**
- Modify: `src/renderer/skill_center_renderer.zig`

- [ ] **Step 1: Add `InputView`, the `input` Overlay variant, and a render branch**

After the `ListView` struct, add:

```zig
/// A single-line text-input overlay (the GitHub URL field).
pub const InputView = struct {
    prompt: []const u8,
    text: []const u8,
};
```

Extend the `Overlay` union:

```zig
pub const Overlay = union(enum) {
    none,
    list: ListView,
    confirm: []const u8,
    input: InputView,
};
```

In `render`, the `switch (view.overlay)` currently has `.list` and `else`. Change it to handle `.input` explicitly while keeping the skill-list + legend visible underneath:

```zig
    switch (view.overlay) {
        .list => |lv| {
            renderList(draw, lv, content_x, content_w, window_height, body_top, fg, muted, accent, line, selected_bg);
        },
        else => {
            renderSkillList(draw, view, content_x, content_w, window_height, top, body_top, fg, muted, accent, line, selected_bg);
            if (view.overlay == .confirm) {
                const bar_h = rowHeight(draw.cell_h);
                const bar_y = legendHeight(draw.cell_h);
                draw.fillQuadAlpha(content_x, bar_y, content_w, bar_h, mixColor(bg, accent, 0.22), 0.97);
                const t_y = bar_y + (bar_h - draw.cell_h) / 2;
                _ = draw.renderTextLimited(view.overlay.confirm, content_x + PAD_X, t_y, fg, content_w - PAD_X * 2);
                return; // confirm replaces the legend line
            }
            if (view.overlay == .input) {
                const iv = view.overlay.input;
                const bar_h = rowHeight(draw.cell_h) * 2;
                const bar_y = legendHeight(draw.cell_h);
                draw.fillQuadAlpha(content_x, bar_y, content_w, bar_h, mixColor(bg, accent, 0.22), 0.97);
                const prompt_y = bar_y + bar_h - draw.cell_h - 6;
                _ = draw.renderTextLimited(iv.prompt, content_x + PAD_X, prompt_y, muted, content_w - PAD_X * 2);
                // editable line with a trailing caret
                var line_buf: [600]u8 = undefined;
                const shown = std.fmt.bufPrint(&line_buf, "{s}_", .{iv.text}) catch iv.text;
                const text_y = bar_y + (rowHeight(draw.cell_h) - draw.cell_h) / 2;
                _ = draw.renderTextLimited(shown, content_x + PAD_X, text_y, fg, content_w - PAD_X * 2);
                return; // input replaces the legend line
            }
        },
    }
```

- [ ] **Step 2: Add a no-crash render-capacity test (the renderer has no draw backend in tests, so test the pure helper)**

The existing tests cover `clampScroll`/`bodyVisibleCapacity`; add one asserting the new union tag compiles and is distinct:

```zig
test "skill_center_renderer: input overlay variant is constructible" {
    const ov: Overlay = .{ .input = .{ .prompt = "Paste URL", .text = "https://github.com/o/r" } };
    try std.testing.expect(ov == .input);
    try std.testing.expectEqualStrings("https://github.com/o/r", ov.input.text);
}
```

- [ ] **Step 3: Run the fast suite**

Run: `zig build test`
Expected: PASS (renderer is registered in `test_fast.zig`).

- [ ] **Step 4: Commit**

```bash
git add src/renderer/skill_center_renderer.zig
git commit -m "feat(skill-center): renderer input overlay for the URL field"
```

---

## Phase 4 — Network primitive, i18n, clipboard, AppWindow wiring

### Task 8: `httpGetAlloc` in `update_install.zig`

**Files:**
- Modify: `src/update_install.zig` (add beside `downloadAsset`)

- [ ] **Step 1: Add the GET-to-memory helper**

Add to `src/update_install.zig`:

```zig
/// HTTP GET `url` into an owned byte slice (caller frees). Errors on non-200 or
/// a body larger than `max_bytes`. Network I/O — not unit-tested, validated
/// manually like `downloadAsset`.
pub fn httpGetAlloc(allocator: std.mem.Allocator, url: []const u8, max_bytes: usize) ![]u8 {
    var client: std.http.Client = .{ .allocator = allocator, .write_buffer_size = 16 * 1024 };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();

    const response = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .keep_alive = false,
        .headers = .{ .user_agent = .{ .override = "wispterm" } },
        .response_writer = &body.writer,
    });
    if (response.status != .ok) return error.HttpStatus;

    var list = body.toArrayList();
    errdefer list.deinit(allocator);
    if (list.items.len > max_bytes) {
        list.deinit(allocator);
        return error.ResponseTooLarge;
    }
    return list.toOwnedSlice(allocator);
}
```

> Note: this mirrors the private `fetchTreeJson` in `skill_update.zig`. If the compiler reports the `std.Io.Writer.Allocating` / `toArrayList` API differs from what `skill_update.zig` and `downloadAsset` use, copy the exact body-collection pattern from `skill_update.zig:113-135` verbatim — they are known-good against this Zig version.

- [ ] **Step 2: Compile-check via the shared suite**

Run: `zig build test-shared`
Expected: PASS (compiles `update_install.zig`, which is in `shared_compile_test.zig`).

- [ ] **Step 3: Commit**

```bash
git add src/update_install.zig
git commit -m "feat(update-install): httpGetAlloc GET-to-memory helper"
```

---

### Task 9: i18n strings (en + zh) + legend update

**Files:**
- Modify: `src/i18n.zig` (struct fields near line 102; en table near line 290; zh table near line 474; legends at lines 278 and 462)

- [ ] **Step 1: Add the struct fields**

In the `Strings` struct, after `sc_empty: []const u8,` (line 102):

```zig
    sc_url_prompt: []const u8,
    sc_pick_install: []const u8,
    sc_busy_fetching: []const u8,
    sc_busy_installing: []const u8,
    sc_toast_installed: []const u8,
    sc_toast_install_partial: []const u8,
    sc_toast_no_skills: []const u8,
    sc_toast_bad_url: []const u8,
    sc_toast_truncated: []const u8,
```

- [ ] **Step 2: Add the English values and update the English legend**

Change line 278:

```zig
    .sc_legend_v2 = "[space] preview   [↵] deploy   [i] import   [g] get   [r] rescan",
```

After `.sc_empty = ...` (line 290) add:

```zig
    .sc_url_prompt = "Paste a GitHub skills URL, then ↵   (esc to cancel)",
    .sc_pick_install = "Select skills to install   ([space] toggle  [a] all  [↵] install  esc cancel)",
    .sc_busy_fetching = "Fetching…",
    .sc_busy_installing = "Installing…",
    .sc_toast_installed = "Skills installed",
    .sc_toast_install_partial = "Some skills failed to install",
    .sc_toast_no_skills = "No skills found at that URL",
    .sc_toast_bad_url = "Couldn't parse that GitHub URL",
    .sc_toast_truncated = "Repo is large — the skill list may be incomplete",
```

- [ ] **Step 3: Add the Chinese values and update the Chinese legend**

Change line 462:

```zig
    .sc_legend_v2 = "[space] 预览   [↵] 部署   [i] 导入   [g] 获取   [r] 重新扫描",
```

After `.sc_empty = ...` (line 474) add:

```zig
    .sc_url_prompt = "粘贴 GitHub 技能链接，然后按 ↵   (esc 取消)",
    .sc_pick_install = "选择要安装的技能   ([space] 选择  [a] 全选  [↵] 安装  esc 取消)",
    .sc_busy_fetching = "获取中…",
    .sc_busy_installing = "安装中…",
    .sc_toast_installed = "技能已安装",
    .sc_toast_install_partial = "部分技能安装失败",
    .sc_toast_no_skills = "该链接下未找到技能",
    .sc_toast_bad_url = "无法解析该 GitHub 链接",
    .sc_toast_truncated = "仓库较大 —— 技能列表可能不完整",
```

- [ ] **Step 4: Compile-check**

Run: `zig build test`
Expected: PASS (i18n tables stay exhaustive; a missing field is a compile error).

- [ ] **Step 5: Commit**

```bash
git add src/i18n.zig
git commit -m "feat(skill-center): i18n strings for GitHub skill install (en+zh)"
```

---

### Task 10: Expose `readClipboardTextOwned` in `clipboard.zig`

**Files:**
- Modify: `src/input/clipboard.zig` (the private `readClipboardText` is at line 357)

- [ ] **Step 1: Add a public wrapper**

After the private `readClipboardText` (line 360), add:

```zig
/// Public: read the system clipboard as owned text (caller frees), or null.
pub fn readClipboardTextOwned(allocator: std.mem.Allocator) ?[]u8 {
    return readClipboardText(allocator);
}
```

- [ ] **Step 2: Compile-check**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add src/input/clipboard.zig
git commit -m "feat(clipboard): expose readClipboardTextOwned for panel inputs"
```

---

### Task 11: AppWindow — enumerate job, URL-input open/edit/submit, render mapping (url_input)

**Files:**
- Modify: `src/AppWindow.zig` (add `const skill_install = @import("skill_install.zig");` near line 55 beside `skill_center`; add the job near `SkillImportScanJob` ~line 2357; add the public fns near the other `skillCenter*` fns ~line 1456; extend the render mapping ~line 877, `skillCenterMove` ~1436, `skillCenterOverlaySelect` ~1879, `skillCenterSpacePreview` ~1996)

- [ ] **Step 1: Add the import**

Near line 55 (`pub const skill_center = @import("skill_center.zig");`):

```zig
const skill_install = @import("skill_install.zig");
```

- [ ] **Step 2: Add the enumerate job (after `SkillPreviewJob`, ~line 2490)**

```zig
/// Background op: parse the URL, resolve the default branch if absent, fetch the
/// Git Trees response, and enumerate skills for the checklist.
const SkillInstallEnumerateJob = struct {
    url: []u8, // owned

    fn run(ctx: *anyopaque, allocator: std.mem.Allocator) skill_center.OpResult {
        const job: *SkillInstallEnumerateJob = @ptrCast(@alignCast(ctx));
        var repo = skill_install.parseGithubUrl(allocator, job.url) catch return .failed;
        errdefer repo.deinit(allocator);

        // Resolve the ref if the URL had none.
        if (repo.ref == null) {
            const ref = resolveDefaultBranch(allocator, repo.owner, repo.repo) catch
                allocator.dupe(u8, "main") catch return .failed;
            repo.ref = ref;
        }

        const api = skill_install.treeApiUrl(allocator, repo.owner, repo.repo, repo.ref.?) catch return .failed;
        defer allocator.free(api);
        const json = update_install.httpGetAlloc(allocator, api, 8 * 1024 * 1024) catch return .failed;
        defer allocator.free(json);

        var res = skill_install.findSkills(allocator, json, repo.subpath) catch return .failed;
        return .{ .install_enumerate = .{ .repo = repo, .entries = res.entries, .truncated = res.truncated } };
    }
    fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const job: *SkillInstallEnumerateJob = @ptrCast(@alignCast(ctx));
        allocator.free(job.url);
        allocator.destroy(job);
    }
};

/// Best-effort default-branch resolution. Tries the repo API's `default_branch`,
/// then falls back to "master" (the caller defaults to "main" on total failure).
fn resolveDefaultBranch(allocator: std.mem.Allocator, owner: []const u8, repo: []const u8) ![]u8 {
    const api = try skill_install.repoApiUrl(allocator, owner, repo);
    defer allocator.free(api);
    const json = update_install.httpGetAlloc(allocator, api, 1024 * 1024) catch return allocator.dupe(u8, "master");
    defer allocator.free(json);
    return skill_install.parseDefaultBranch(allocator, json) catch allocator.dupe(u8, "master");
}
```

- [ ] **Step 3: Add the URL-input public fns (near `skillCenterOverlayCancel`, ~line 1464)**

```zig
/// True when the URL-input overlay is capturing text. UI thread.
pub fn skillCenterUrlInputActive() bool {
    const session = activeSkillCenter() orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    return session.model.overlay == .url_input;
}

/// 'g': open the URL-input overlay, prefilled from the clipboard if it looks
/// like a GitHub URL. UI thread.
pub fn skillCenterOpenUrlInput() bool {
    const session = activeSkillCenter() orelse return false;
    const allocator = g_allocator orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    if (session.model.overlay != .none) return false;
    var st: skill_center.UrlInputState = .{};
    if (clipboard.readClipboardTextOwned(allocator)) |clip| {
        defer allocator.free(clip);
        const trimmed = std.mem.trim(u8, clip, " \t\r\n");
        if (std.mem.indexOf(u8, trimmed, "github.com/") != null and trimmed.len < 512)
            st.insertSlice(allocator, trimmed);
    }
    session.model.setOverlay(.{ .url_input = st });
    markUiDirty();
    return true;
}

/// Append a typed codepoint to the URL buffer (no-op unless url_input active).
pub fn skillCenterUrlInsertChar(codepoint: u21) bool {
    if (codepoint < 0x20 or codepoint == 0x7f) return false;
    const session = activeSkillCenter() orelse return false;
    const allocator = g_allocator orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    switch (session.model.overlay) {
        .url_input => |*u| {
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(codepoint, &buf) catch return false;
            u.insertSlice(allocator, buf[0..len]);
            markUiDirty();
            return true;
        },
        else => return false,
    }
}

/// Backspace in the URL buffer. UI thread.
pub fn skillCenterUrlBackspace() bool {
    const session = activeSkillCenter() orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    switch (session.model.overlay) {
        .url_input => |*u| {
            u.backspace();
            markUiDirty();
            return true;
        },
        else => return false,
    }
}

/// Ctrl/Cmd+V: append clipboard text to the URL buffer. UI thread.
pub fn skillCenterUrlPaste() bool {
    const session = activeSkillCenter() orelse return false;
    const allocator = g_allocator orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    switch (session.model.overlay) {
        .url_input => |*u| {
            if (clipboard.readClipboardTextOwned(allocator)) |clip| {
                defer allocator.free(clip);
                const trimmed = std.mem.trim(u8, clip, " \t\r\n");
                u.insertSlice(allocator, trimmed);
            }
            markUiDirty();
            return true;
        },
        else => return false,
    }
}

/// Enter in the URL-input overlay: snapshot the URL, clear the overlay, start
/// the enumerate op. UI thread.
fn skillCenterStartEnumerate(session: *skill_center.Session, allocator: std.mem.Allocator) void {
    var url_owned: ?[]u8 = null;
    {
        session.mutex.lock();
        defer session.mutex.unlock();
        switch (session.model.overlay) {
            .url_input => |*u| {
                const t = std.mem.trim(u8, u.text(), " \t\r\n");
                if (t.len > 0) url_owned = allocator.dupe(u8, t) catch null;
                session.model.clearOverlay();
            },
            else => return,
        }
    }
    const url = url_owned orelse {
        markUiDirty();
        return;
    };
    const job = allocator.create(SkillInstallEnumerateJob) catch {
        allocator.free(url);
        return;
    };
    job.* = .{ .url = url };
    if (!session.startOp(.{ .ctx = job, .run = SkillInstallEnumerateJob.run, .destroy = SkillInstallEnumerateJob.destroy }, window_backend.postWakeup, i18n.s().sc_busy_fetching)) {
        SkillInstallEnumerateJob.destroy(@ptrCast(job), allocator);
        overlays.showStatusToast(i18n.s().sc_toast_op_busy);
    }
    markUiDirty();
}
```

> `clipboard` is already imported in `AppWindow.zig` as the input clipboard module — confirm the existing import alias (search for `clipboard` near the top of `AppWindow.zig`); if it is imported under a different name (e.g. `input_clipboard`), use that alias in the four call sites above.

- [ ] **Step 4: Map `url_input` in `renderSkillCenterFrame` (~line 877) and set its legend (~line 902)**

In the overlay `switch (m.overlay)` mapping, add an arm:

```zig
            .url_input => |*u| .{ .input = .{ .prompt = i18n.s().sc_url_prompt, .text = u.text() } },
```

Change the legend selection (line 902) to:

```zig
            .legend = switch (m.overlay) {
                .import_list => i18n.s().sc_legend_import,
                .install_pick => i18n.s().sc_pick_install,
                else => i18n.s().sc_legend_v2,
            },
```

- [ ] **Step 5: Add `url_input` arms to `skillCenterMove`, `skillCenterOverlaySelect`, `skillCenterSpacePreview`**

In `skillCenterMove` (the `switch (session.model.overlay)` at line 1436), the existing `else =>` branch moves the library selection. Add an explicit no-op arm so `url_input` does not move the library cursor:

```zig
        .url_input => {},
```

In `skillCenterOverlaySelect` (the `switch` at line 1879), add:

```zig
            .url_input => {
                // handled outside the lock below
            },
```

…and, immediately after the `switch` block closes (before `markUiDirty();` at line 1923), short-circuit to the enumerate starter when the overlay was `url_input`. The cleanest form: at the top of `skillCenterOverlaySelect`, before taking the snapshot, handle url_input directly:

```zig
pub fn skillCenterOverlaySelect() bool {
    const session = activeSkillCenter() orelse return false;
    const allocator = g_allocator orelse return false;
    // URL input submits to the enumerate op (manages its own lock).
    if (skillCenterUrlInputActive()) {
        skillCenterStartEnumerate(session, allocator);
        return true;
    }
    // ... existing snapshot-and-act body unchanged ...
```

(With this guard at the top, the `.url_input => {}` arm added to the inner switch is only a safety no-op.)

In `skillCenterSpacePreview` (the `switch` at line 1996), add:

```zig
            .url_input => kind = .none,
```

- [ ] **Step 6: Build (full app) to verify compilation**

Run: `zig build`
Expected: PASS (compiles `AppWindow.zig` with the new job, fns, and overlay arms). Fix any exhaustive-switch errors the compiler flags for `url_input`.

- [ ] **Step 7: Commit**

```bash
git add src/AppWindow.zig
git commit -m "feat(skill-center): GitHub URL-input overlay + enumerate op"
```

---

### Task 12: AppWindow — download-and-install, download job, install_pick handling, poll branches

**Files:**
- Modify: `src/AppWindow.zig`

- [ ] **Step 1: Add the impure install function (near `skillCenterLibraryDir`, ~line 1469)**

```zig
/// Download every selected skill's files into a temp staging dir under the
/// library, then per-skill atomically replace `<config>/skills/<name>`. Returns
/// {installed, overwritten, failed}. A skill whose download fails is skipped
/// (counted in `failed`); others still install. Staging dir is always removed.
fn downloadSelectedSkillsToLibrary(
    allocator: std.mem.Allocator,
    repo: skill_install.RepoRef,
    entries: []const skill_install.SkillEntry,
) struct { installed: usize, overwritten: usize, failed: usize } {
    var installed: usize = 0;
    var overwritten: usize = 0;
    var failed: usize = 0;

    const lib_dir = skillCenterLibraryDir(allocator) orelse return .{ .installed = 0, .overwritten = 0, .failed = entries.len };
    defer allocator.free(lib_dir);
    const ref = repo.ref orelse "main";

    const tmp_dir = std.fs.path.join(allocator, &.{ lib_dir, ".install-tmp" }) catch
        return .{ .installed = 0, .overwritten = 0, .failed = entries.len };
    defer allocator.free(tmp_dir);
    std.fs.deleteTreeAbsolute(tmp_dir) catch {};
    defer std.fs.deleteTreeAbsolute(tmp_dir) catch {};

    for (entries) |entry| {
        var ok = true;
        for (entry.files) |file_path| {
            const rel = skill_install.relInstallPath(entry.root_path, file_path) orelse continue;
            const url = skill_install.rawUrl(allocator, repo.owner, repo.repo, ref, file_path) catch {
                ok = false;
                break;
            };
            defer allocator.free(url);
            const dest = std.fs.path.join(allocator, &.{ tmp_dir, rel }) catch {
                ok = false;
                break;
            };
            defer allocator.free(dest);
            update_install.downloadAsset(allocator, url, dest) catch {
                ok = false;
                break;
            };
        }
        if (!ok) {
            failed += 1;
            continue;
        }

        const final = std.fs.path.join(allocator, &.{ lib_dir, entry.name }) catch {
            failed += 1;
            continue;
        };
        defer allocator.free(final);
        const staged = std.fs.path.join(allocator, &.{ tmp_dir, entry.name }) catch {
            failed += 1;
            continue;
        };
        defer allocator.free(staged);

        const existed = blk: {
            std.fs.accessAbsolute(final, .{}) catch break :blk false;
            break :blk true;
        };
        std.fs.deleteTreeAbsolute(final) catch {
            failed += 1;
            continue;
        };
        std.fs.renameAbsolute(staged, final) catch {
            failed += 1;
            continue;
        };
        installed += 1;
        if (existed) overwritten += 1;
    }

    return .{ .installed = installed, .overwritten = overwritten, .failed = failed };
}
```

- [ ] **Step 2: Add the download job (after `SkillInstallEnumerateJob`)**

```zig
/// Background op: download + install the selected skills into the library.
const SkillInstallDownloadJob = struct {
    repo: skill_install.RepoRef, // owned
    entries: []skill_install.SkillEntry, // owned

    fn run(ctx: *anyopaque, allocator: std.mem.Allocator) skill_center.OpResult {
        const job: *SkillInstallDownloadJob = @ptrCast(@alignCast(ctx));
        const r = downloadSelectedSkillsToLibrary(allocator, job.repo, job.entries);
        return .{ .install_done = .{ .installed = r.installed, .overwritten = r.overwritten, .failed = r.failed } };
    }
    fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const job: *SkillInstallDownloadJob = @ptrCast(@alignCast(ctx));
        job.repo.deinit(allocator);
        skill_install.freeEntries(allocator, job.entries);
        allocator.destroy(job);
    }
};
```

- [ ] **Step 3: Add install_pick toggle/select-all/start fns (near the URL fns)**

```zig
/// True when the install checklist is active. UI thread.
pub fn skillCenterPickActive() bool {
    const session = activeSkillCenter() orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    return session.model.overlay == .install_pick;
}

/// Space: toggle the highlighted checklist row. UI thread.
pub fn skillCenterPickToggle() bool {
    const session = activeSkillCenter() orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    switch (session.model.overlay) {
        .install_pick => |*p| {
            p.toggle();
            markUiDirty();
            return true;
        },
        else => return false,
    }
}

/// 'a': toggle select-all in the checklist. UI thread.
pub fn skillCenterPickSelectAll() bool {
    const session = activeSkillCenter() orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    switch (session.model.overlay) {
        .install_pick => |*p| {
            p.setAll(!p.anyChecked());
            markUiDirty();
            return true;
        },
        else => return false,
    }
}

/// Enter in the checklist: snapshot the selection + repo, clear the overlay,
/// start the download op. UI thread.
fn skillCenterStartInstall(session: *skill_center.Session, allocator: std.mem.Allocator) void {
    var repo_owned: ?skill_install.RepoRef = null;
    var entries_owned: ?[]skill_install.SkillEntry = null;
    var empty = false;
    {
        session.mutex.lock();
        defer session.mutex.unlock();
        switch (session.model.overlay) {
            .install_pick => |*p| {
                if (!p.anyChecked()) {
                    empty = true;
                } else {
                    repo_owned = p.repo.clone(allocator) catch null;
                    entries_owned = p.selectedEntries(allocator) catch null;
                    session.model.clearOverlay();
                }
            },
            else => return,
        }
    }
    if (empty) {
        overlays.showStatusToast(i18n.s().sc_toast_no_skills);
        markUiDirty();
        return;
    }
    const repo = repo_owned orelse {
        if (entries_owned) |e| skill_install.freeEntries(allocator, e);
        markUiDirty();
        return;
    };
    const entries = entries_owned orelse {
        var rr = repo;
        rr.deinit(allocator);
        markUiDirty();
        return;
    };
    const job = allocator.create(SkillInstallDownloadJob) catch {
        var rr = repo;
        rr.deinit(allocator);
        skill_install.freeEntries(allocator, entries);
        return;
    };
    job.* = .{ .repo = repo, .entries = entries };
    if (!session.startOp(.{ .ctx = job, .run = SkillInstallDownloadJob.run, .destroy = SkillInstallDownloadJob.destroy }, window_backend.postWakeup, i18n.s().sc_busy_installing)) {
        SkillInstallDownloadJob.destroy(@ptrCast(job), allocator);
        overlays.showStatusToast(i18n.s().sc_toast_op_busy);
    }
    markUiDirty();
}
```

> Contract: an empty selection shows the `sc_toast_no_skills` toast and starts no op (the `empty` flag is read under the lock, toasted after the `defer`-unlock — no nested lock/unlock).

- [ ] **Step 4: Map `install_pick` to the renderer `list` overlay + its accessor**

In `renderSkillCenterFrame` overlay mapping (~line 877), add:

```zig
            .install_pick => |*p| .{ .list = .{
                .title = i18n.s().sc_pick_install,
                .len = p.entries.len,
                .ctx = @ptrCast(p),
                .itemAt = scInstallPickItemAt,
                .sel = p.sel,
            } },
```

Add the accessor beside `scImportItemAt` (~line 1021). It encodes the checkbox in the label and shows the file count as the marker:

```zig
fn scInstallPickItemAt(ctx: *anyopaque, i: usize) skill_center_renderer.ListItem {
    const p: *const skill_center.InstallPickState = @ptrCast(@alignCast(ctx));
    if (i >= p.entries.len) return .{ .label = "", .marker = "" };
    // Static buffers keyed off a small ring so labels survive the frame draw.
    const checked = i < p.checked.len and p.checked[i];
    const box = if (checked) "[x] " else "[ ] ";
    g_sc_pick_label_buf[i % g_sc_pick_label_buf.len] = undefined;
    const slot = &g_sc_pick_label_buf[i % g_sc_pick_label_buf.len];
    const label = std.fmt.bufPrint(slot, "{s}{s}", .{ box, p.entries[i].name }) catch p.entries[i].name;
    return .{ .label = label, .marker = "" };
}
var g_sc_pick_label_buf: [64][256]u8 = undefined;
```

> The renderer calls `itemAt` once per visible row during a single synchronous frame (under the session lock), so a per-index static buffer is safe. If the existing codebase has a tidier per-frame label arena, prefer it; otherwise this fixed buffer is acceptable and bounded.

- [ ] **Step 5: Add `install_pick` arms to `skillCenterMove`, `skillCenterOverlaySelect`, `skillCenterSpacePreview`**

In `skillCenterMove` (line 1436):

```zig
        .install_pick => |*p| scMoveSel(&p.sel, p.entries.len, delta),
```

In `skillCenterOverlaySelect`, add the early guard beside the url_input one at the top of the fn:

```zig
    if (skillCenterPickActive()) {
        skillCenterStartInstall(session, allocator);
        return true;
    }
```

…and a safety no-op arm in the inner switch:

```zig
            .install_pick => {},
```

In `skillCenterSpacePreview` (line 1996): space should toggle the checkbox, not preview. Add the explicit arm and short-circuit at the top of the fn:

```zig
pub fn skillCenterSpacePreview() bool {
    if (skillCenterPickActive()) return skillCenterPickToggle();
    // ... existing body ...
```

and in the inner switch:

```zig
            .install_pick => kind = .none,
```

- [ ] **Step 6: Add the `pollSkillCenterOp` branches (~line 4015 switch)**

Before the `.preview` arm (or after it, order doesn't matter), add:

```zig
        .install_enumerate => |*v| {
            if (v.entries.len == 0) {
                overlays.showStatusToast(i18n.s().sc_toast_no_skills);
            } else {
                if (v.truncated) overlays.showStatusToast(i18n.s().sc_toast_truncated);
                // Move ownership of repo+entries into the overlay; null them so
                // result.deinit (the outer defer) won't double-free.
                const repo = v.repo;
                const entries = v.entries;
                v.repo = skill_install.RepoRef{ .owner = &.{}, .repo = &.{}, .ref = null, .subpath = &.{} };
                v.entries = &.{};
                const checked = allocator.alloc(bool, entries.len) catch {
                    var rr = repo;
                    rr.deinit(allocator);
                    skill_install.freeEntries(allocator, entries);
                    markUiDirty();
                    return;
                };
                for (checked) |*c| c.* = true; // default: all selected
                session.mutex.lock();
                session.model.setOverlay(.{ .install_pick = .{ .repo = repo, .entries = entries, .checked = checked } });
                session.mutex.unlock();
            }
        },
        .install_done => |*v| {
            if (v.failed == 0) {
                overlays.showStatusToast(i18n.s().sc_toast_installed);
            } else {
                overlays.showStatusToast(i18n.s().sc_toast_install_partial);
            }
            log.info("skill install: {d} installed, {d} updated, {d} failed", .{ v.installed, v.overwritten, v.failed });
            startSkillCenterScan(allocator, session); // refresh the library list
        },
```

> The ownership-transfer dance for `install_enumerate` mirrors how `importScanResult`/`deploy_scan` move rows out of an outcome. The zero-length sentinel slices (`&.{}`) on the drained `RepoRef`/entries are safe to `deinit`/`freeEntries` (freeing an empty slice is a no-op; `RepoRef.deinit` frees four empty slices). Verify `RepoRef{ ... }` literal with empty `[]u8` fields compiles; if `&.{}` is rejected for `[]u8`, use `@constCast(&[_]u8{})` or restructure so the moved-out result is set to `.failed` (which `result.deinit` then no-ops): set `result = .failed;` after extracting — but note `result` is the `var` from `takePendingOp`; reassigning it before the outer `defer result.deinit` runs is the simplest correct approach. Prefer: `const moved = result; result = .failed;` then use `moved.install_enumerate`. Use whichever pattern the compiler accepts; the invariant is **no double-free and no leak**.

- [ ] **Step 7: Build the full app**

Run: `zig build`
Expected: PASS. Resolve any exhaustive-switch or ownership errors for the new variants.

- [ ] **Step 8: Run both suites**

Run: `zig build test` then `zig build test-full`
Expected: PASS (fast suite fully green; `test-full` green except the known pre-existing `web_read_cache.zig` windows-target failure).

- [ ] **Step 9: Commit**

```bash
git add src/AppWindow.zig
git commit -m "feat(skill-center): download+install selected skills into the library"
```

---

### Task 13: Input routing in `input.zig`

**Files:**
- Modify: `src/input.zig` (keydown skill-center block ~line 2022; char-input path ~line 1436)

- [ ] **Step 1: Extend the keydown skill-center block (line 2022)**

Replace the block beginning at line 2023 (`if (AppWindow.activeSkillCenter() != null) {`) so it: opens the URL input on `g`; routes backspace/paste to the URL buffer when text-capturing; gates the letter shortcuts and space when text-capturing; routes `a` and space to the checklist when picking.

```zig
    // Skill Center: ↑/↓ move, space preview/toggle, ⏎ confirm, esc cancel,
    // d deploy, i import, g get-from-GitHub, r rescan. The URL-input overlay
    // captures text; the checklist captures space + 'a'.
    if (AppWindow.activeSkillCenter() != null) {
        const plain = !ev.ctrl and !ev.alt and !ev.super;
        const text_capture = AppWindow.skillCenterUrlInputActive();
        const picking = AppWindow.skillCenterPickActive();
        // Ctrl/Cmd+V paste into the URL field.
        if (text_capture and (ev.ctrl or ev.super) and ev.key_code == 0x56) { // 'V'
            _ = AppWindow.skillCenterUrlPaste();
            return;
        }
        switch (ev.key_code) {
            platform_input.key_up => {
                _ = AppWindow.skillCenterMove(-1);
                return;
            },
            platform_input.key_down => {
                _ = AppWindow.skillCenterMove(1);
                return;
            },
            platform_input.key_enter => {
                if (AppWindow.skillCenterOverlayActive()) {
                    _ = AppWindow.skillCenterOverlaySelect();
                } else {
                    _ = AppWindow.skillCenterDeploy();
                }
                return;
            },
            platform_input.key_escape => {
                _ = AppWindow.skillCenterOverlayCancel();
                return;
            },
            platform_input.key_backspace => {
                if (text_capture) {
                    _ = AppWindow.skillCenterUrlBackspace();
                    return;
                }
            },
            0x52 => if (plain and !ev.shift and !text_capture) { // 'R'
                _ = AppWindow.skillCenterRescan();
                return;
            },
            0x44 => if (plain and !ev.shift and !text_capture and !picking) { // 'D'
                _ = AppWindow.skillCenterDeploy();
                return;
            },
            0x49 => if (plain and !ev.shift and !text_capture and !picking) { // 'I'
                _ = AppWindow.skillCenterImport();
                return;
            },
            0x47 => if (plain and !ev.shift and !text_capture and !picking) { // 'G'
                _ = AppWindow.skillCenterOpenUrlInput();
                return;
            },
            0x41 => if (plain and !ev.shift and picking) { // 'A' select-all
                _ = AppWindow.skillCenterPickSelectAll();
                return;
            },
            platform_input.key_space => if (plain and !ev.shift and !text_capture) {
                _ = AppWindow.skillCenterSpacePreview(); // toggles when picking
                return;
            },
            else => {},
        }
        return;
    }
```

> Note: when `text_capture` is true, the letter keys `r/d/i/g/a` and space fall through the switch (their guards fail) and reach the trailing `return;`, so they do NOT trigger shortcuts. Their *character* events are what edit the URL (Step 2). This is the same separation the AI-history filter and port-forwarding form rely on.

- [ ] **Step 2: Add a skill-center branch to the char-input path (line 1436)**

After the `activeAiHistory` char branch (ends line 1436) and before the `activePortForwarding` branch, add:

```zig
    if (AppWindow.activeSkillCenter() != null) {
        if (!ev.ctrl and !ev.alt and !ev.super) {
            _ = AppWindow.skillCenterUrlInsertChar(ev.codepoint); // no-op unless url_input active
        }
        return;
    }
```

- [ ] **Step 3: Build the full app**

Run: `zig build`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/input.zig
git commit -m "feat(skill-center): route 'g' + URL text input keys in the panel"
```

---

## Phase 5 — Verification

### Task 14: Full verification + manual smoke + memory

**Files:** none (verification only)

- [ ] **Step 1: Run the full build + both test suites + cross-compile**

```bash
zig build
zig build test
zig build test-full
zig build -Dtarget=x86_64-windows-gnu
```

Expected:
- `zig build` — PASS
- `zig build test` — PASS (all `skill_install` + `skill_center` tests green)
- `zig build test-full` — PASS except the known pre-existing `web_read_cache.zig` windows-target failure (unrelated to this work; confirm it is the *only* failure)
- windows-gnu cross-compile — PASS

- [ ] **Step 2: Manual smoke (GUI host — macOS/Windows; WSLg cannot screenshot GL)**

Verify end-to-end against the real example URL:
1. Open the Skill Center (command center → "Skill Center", or its existing entry).
2. Press `g`. The URL-input overlay appears (prefilled from clipboard if a GitHub URL was copied).
3. Type/paste `https://github.com/fei0810/bear-research-skills/tree/main/skills`, press Enter. Status shows "Fetching…".
4. The checklist shows 8 skills (`bear-counter` … `bear-trace`), all checked. Toggle a couple with Space; press `a` to select-all/none.
5. Press Enter. Status shows "Installing…", then "Skills installed".
6. The library list now lists the installed skills. Open `<config>/skills/bear-map/` and confirm `SKILL.md` + `references/` are present.
7. Select an installed skill, press Enter/`d`, and deploy to local Claude via the existing picker; confirm it lands in `~/.claude/skills/bear-map/`.
8. Error paths: a non-GitHub URL → "Couldn't parse that GitHub URL"; a URL with no skills → "No skills found at that URL".

- [ ] **Step 3: Update project memory**

Update `/home/xzg/.claude/projects/-home-xzg-project-phantty/memory/MEMORY.md` and add a topic file `wispterm-skill-install-from-github.md` recording: the `skill_install.zig` pure module, the two ops/overlays added to Skill Center, the `g` keybinding, the library-then-deploy flow, scope guards, branch/PR status, and that GUI verification is pending. Link `[[wispterm-skill-center]]`.

- [ ] **Step 4: Final commit (if any docs/memory tracked in-repo changed)**

```bash
git add -A
git commit -m "docs(skill-install): mark install-from-GitHub complete pending GUI smoke"
```

---

## Self-Review notes (filled during planning)

- **Spec coverage:** URL parser (Task 1), default-branch resolution (Task 11/`resolveDefaultBranch`), tree enumeration incl. nested `references/` (Task 3), `g` entry point + URL overlay (Tasks 9/11/13), checklist multi-select (Tasks 6/12/13), download-into-library + atomic replace + overwrite count (Task 12), deploy reuse (manual Step 2.7), error handling — bad URL / network / zero / truncated / partial (Tasks 11/12), i18n en+zh (Task 9), tests (Tasks 1–6), build gates (Task 14). All spec sections map to a task.
- **Type consistency:** `RepoRef`/`SkillEntry`/`FindResult` (skill_install) are used identically across `skill_center` (`install.RepoRef`, `install.SkillEntry`) and `AppWindow` (`skill_install.*`). `findSkills` returns `FindResult{entries, truncated}` everywhere. `relInstallPath(root_path, file_path)` signature is stable. The renderer `Overlay.input: InputView{prompt, text}` matches the AppWindow mapping.
- **Scope:** single subsystem (Skill Center acquisition), one plan.
