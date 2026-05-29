//! Built-in skill updater: pulls the latest skills from the phantty repo's
//! `plugins/skills/` directory into the user's `<config>/plugins/skills`.
//!
//! Pure helpers (path/URL/JSON mapping) live here and are unit-tested. The
//! network + disk orchestration (`downloadAndInstall`) is impure and validated
//! manually, consistent with the program-update flow.
const std = @import("std");
const platform_dirs = @import("platform/dirs.zig");
const update_install = @import("update_install.zig");

pub const skills_tree_api_url =
    "https://api.github.com/repos/xuzhougeng/phantty/git/trees/main?recursive=1";
pub const raw_base =
    "https://raw.githubusercontent.com/xuzhougeng/phantty/main/";
pub const skills_prefix = "plugins/skills/";

pub const State = enum { idle, downloading, done, failed };

pub const Outcome = struct {
    state: State,
    count: usize = 0,
};

/// Free a `[][]u8` list of owned strings.
pub fn freeStringList(allocator: std.mem.Allocator, list: [][]u8) void {
    for (list) |item| allocator.free(item);
    allocator.free(list);
}

/// Parse a GitHub Git Trees response (`?recursive=1`) and return owned paths
/// for every blob whose path is under `plugins/skills/`. Directory ("tree")
/// entries and paths outside the prefix are skipped.
pub fn parseSkillPaths(allocator: std.mem.Allocator, tree_json: []const u8) ![][]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, tree_json, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidTree;
    const tree = root.object.get("tree") orelse return error.InvalidTree;
    if (tree != .array) return error.InvalidTree;

    var out: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit(allocator);
    }

    for (tree.array.items) |item| {
        if (item != .object) continue;
        const type_val = item.object.get("type") orelse continue;
        if (type_val != .string or !std.mem.eql(u8, type_val.string, "blob")) continue;
        const path_val = item.object.get("path") orelse continue;
        if (path_val != .string) continue;
        if (!std.mem.startsWith(u8, path_val.string, skills_prefix)) continue;
        // Skip the prefix dir itself with no file after it.
        if (path_val.string.len <= skills_prefix.len) continue;
        const owned = try allocator.dupe(u8, path_val.string);
        errdefer allocator.free(owned);
        try out.append(allocator, owned);
    }

    return out.toOwnedSlice(allocator);
}

/// `raw_base ++ path` (the raw.githubusercontent.com URL for a repo path).
pub fn rawUrlForPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.mem.concat(allocator, u8, &.{ raw_base, path });
}

/// The path of a remote skill file relative to the skills root, i.e. the
/// remote path with the `plugins/skills/` prefix stripped. Returns null when
/// the path is not under the prefix.
pub fn installSubpath(path: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, skills_prefix)) return null;
    const sub = path[skills_prefix.len..];
    if (sub.len == 0) return null;
    return sub;
}

/// Deduplicated top-level skill directory names from a list of remote paths.
/// `plugins/skills/foo/SKILL.md` -> `foo`.
pub fn skillNamesFromPaths(allocator: std.mem.Allocator, paths: []const []const u8) ![][]u8 {
    var out: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit(allocator);
    }

    for (paths) |path| {
        const sub = installSubpath(path) orelse continue;
        const slash = std.mem.indexOfScalar(u8, sub, '/') orelse continue;
        const name = sub[0..slash];
        if (name.len == 0) continue;

        var already = false;
        for (out.items) |existing| {
            if (std.mem.eql(u8, existing, name)) {
                already = true;
                break;
            }
        }
        if (already) continue;

        const owned = try allocator.dupe(u8, name);
        errdefer allocator.free(owned);
        try out.append(allocator, owned);
    }

    return out.toOwnedSlice(allocator);
}

const testing = std.testing;

const sample_tree =
    \\{"sha":"abc","tree":[
    \\{"path":"plugins/skills","type":"tree"},
    \\{"path":"plugins/skills/foo","type":"tree"},
    \\{"path":"plugins/skills/foo/SKILL.md","type":"blob"},
    \\{"path":"plugins/skills/foo/scripts/run.py","type":"blob"},
    \\{"path":"plugins/skills/bar/SKILL.md","type":"blob"},
    \\{"path":"src/main.zig","type":"blob"},
    \\{"path":"README.md","type":"blob"}
    \\],"truncated":false}
;

test "skill_update: parseSkillPaths keeps only plugins/skills blobs" {
    const paths = try parseSkillPaths(testing.allocator, sample_tree);
    defer freeStringList(testing.allocator, paths);

    try testing.expectEqual(@as(usize, 3), paths.len);
    try testing.expectEqualStrings("plugins/skills/foo/SKILL.md", paths[0]);
    try testing.expectEqualStrings("plugins/skills/foo/scripts/run.py", paths[1]);
    try testing.expectEqualStrings("plugins/skills/bar/SKILL.md", paths[2]);
}

test "skill_update: rawUrlForPath joins the raw base" {
    const url = try rawUrlForPath(testing.allocator, "plugins/skills/foo/SKILL.md");
    defer testing.allocator.free(url);
    try testing.expectEqualStrings(
        "https://raw.githubusercontent.com/xuzhougeng/phantty/main/plugins/skills/foo/SKILL.md",
        url,
    );
}

test "skill_update: installSubpath strips the prefix" {
    try testing.expectEqualStrings("foo/SKILL.md", installSubpath("plugins/skills/foo/SKILL.md").?);
    try testing.expectEqual(@as(?[]const u8, null), installSubpath("src/main.zig"));
    try testing.expectEqual(@as(?[]const u8, null), installSubpath("plugins/skills/"));
}

test "skill_update: skillNamesFromPaths dedups top-level names" {
    const paths = [_][]const u8{
        "plugins/skills/foo/SKILL.md",
        "plugins/skills/foo/scripts/run.py",
        "plugins/skills/bar/SKILL.md",
        "plugins/skills/baz", // no file segment -> skipped
    };
    const names = try skillNamesFromPaths(testing.allocator, &paths);
    defer freeStringList(testing.allocator, names);

    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("foo", names[0]);
    try testing.expectEqualStrings("bar", names[1]);
}
