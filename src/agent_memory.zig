//! Copilot long-term memory: two-tier (global + project) markdown store.
//! Pure helpers (slug, project key, frontmatter parse/serialize, index block)
//! plus thin filesystem I/O and orchestration. Leaf module: depends only on
//! std + platform/dirs + platform/atomic_file. No Session/ai_chat deps.
const std = @import("std");
const dirs = @import("platform/dirs.zig");
const atomic_file = @import("platform/atomic_file.zig");

pub const MAX_MEMORY_MD_BYTES: usize = 64 * 1024;
pub const INDEX_BUDGET_BYTES: usize = 4096;
pub const MAX_PROJECT_KEY_LEN: usize = 200;
pub const SLUG_MAX_LEN: usize = 40;

pub const Tier = enum { global, project };

pub const MemoryType = enum {
    user,
    feedback,
    project,
    reference,

    pub fn fromString(s: []const u8) MemoryType {
        if (std.mem.eql(u8, s, "feedback")) return .feedback;
        if (std.mem.eql(u8, s, "project")) return .project;
        if (std.mem.eql(u8, s, "reference")) return .reference;
        return .user;
    }

    pub fn toString(self: MemoryType) []const u8 {
        return @tagName(self);
    }
};

pub const Entry = struct {
    name: []u8,
    description: []u8,
    type_: MemoryType = .user,
    created: []u8,
    updated: []u8,
    body: []u8,

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.created);
        allocator.free(self.updated);
        allocator.free(self.body);
        self.* = undefined;
    }
};

pub const IndexLine = struct {
    name: []const u8,
    description: []const u8,
    updated: []const u8,
};

/// UTC `YYYY-MM-DD` into `buf`; returns the written slice.
pub fn todayDate(buf: *[10]u8) []const u8 {
    const secs: u64 = @intCast(@max(@as(i64, 0), std.time.timestamp()));
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = secs };
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u32, month_day.day_index) + 1,
    }) catch "0000-00-00";
}

test "MemoryType round-trips through strings" {
    try std.testing.expectEqual(MemoryType.feedback, MemoryType.fromString("feedback"));
    try std.testing.expectEqual(MemoryType.user, MemoryType.fromString("nonsense"));
    try std.testing.expectEqualStrings("reference", MemoryType.reference.toString());
}

test "todayDate formats a YYYY-MM-DD slice" {
    var buf: [10]u8 = undefined;
    const s = todayDate(&buf);
    try std.testing.expectEqual(@as(usize, 10), s.len);
    try std.testing.expectEqual(@as(u8, '-'), s[4]);
    try std.testing.expectEqual(@as(u8, '-'), s[7]);
}

// --- Task 2: slugify ---

/// Lowercase hex of the first `n` bytes of `src` into `out` (must be 2*n bytes).
fn hexEncode(src: []const u8, out: []u8) void {
    const hex = "0123456789abcdef";
    for (src, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
}

/// Slug from arbitrary text: lowercase ASCII alnum kept, runs of non-alnum
/// replaced with a single '-', capped to SLUG_MAX_LEN, trailing dashes trimmed.
/// Empty result (e.g. all-CJK text) falls back to `mem-<date>-<sha6>`.
pub fn slugify(allocator: std.mem.Allocator, text: []const u8, date: []const u8) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    defer list.deinit(allocator);
    var prev_dash = false;
    for (text) |c| {
        if (list.items.len >= SLUG_MAX_LEN) break;
        const lower = std.ascii.toLower(c);
        const is_alnum = (lower >= 'a' and lower <= 'z') or (lower >= '0' and lower <= '9');
        if (is_alnum) {
            try list.append(allocator, lower);
            prev_dash = false;
        } else if (!prev_dash and list.items.len > 0) {
            try list.append(allocator, '-');
            prev_dash = true;
        }
    }
    while (list.items.len > 0 and list.items[list.items.len - 1] == '-') list.items.len -= 1;
    if (list.items.len == 0) {
        var h: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(text, &h, .{});
        var hex_buf: [6]u8 = undefined;
        hexEncode(h[0..3], &hex_buf);
        return std.fmt.allocPrint(allocator, "mem-{s}-{s}", .{ date, hex_buf[0..6] });
    }
    return allocator.dupe(u8, list.items);
}

test "slugify lowercases and dashes non-alphanumerics" {
    const a = std.testing.allocator;
    const s = try slugify(a, "  Prefers Chinese Replies!  ", "2026-06-08");
    defer a.free(s);
    try std.testing.expectEqualStrings("prefers-chinese-replies", s);
}

test "slugify caps length and trims trailing dash" {
    const a = std.testing.allocator;
    const s = try slugify(a, "a b c d e f g h i j k l m n o p q r s t u v w x y z 0 1 2 3 4 5", "2026-06-08");
    defer a.free(s);
    try std.testing.expect(s.len <= SLUG_MAX_LEN);
    try std.testing.expect(s[s.len - 1] != '-');
}

test "slugify falls back to mem-date-hash for non-ASCII text" {
    const a = std.testing.allocator;
    const s = try slugify(a, "用户偏好中文", "2026-06-08");
    defer a.free(s);
    try std.testing.expect(std.mem.startsWith(u8, s, "mem-2026-06-08-"));
}

// --- Task 3: projectKey ---

/// Filesystem-safe, human-readable key for a working directory path:
/// any char outside [A-Za-z0-9._-] becomes '-' (e.g. `/home/xzg/proj` ->
/// `-home-xzg-proj`). Paths longer than MAX_PROJECT_KEY_LEN are truncated
/// and suffixed with a sha256-derived hex so the mapping stays deterministic
/// and collision-resistant.
pub fn projectKey(allocator: std.mem.Allocator, working_dir: []const u8) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    defer list.deinit(allocator);
    for (working_dir) |c| {
        const keep = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '.' or c == '_' or c == '-';
        try list.append(allocator, if (keep) c else '-');
    }
    if (list.items.len <= MAX_PROJECT_KEY_LEN) return allocator.dupe(u8, list.items);
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(working_dir, &h, .{});
    const head = list.items[0 .. MAX_PROJECT_KEY_LEN - 9];
    var hex_buf: [8]u8 = undefined;
    hexEncode(h[0..4], &hex_buf);
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ head, hex_buf[0..8] });
}

test "projectKey sanitizes path separators to dashes" {
    const a = std.testing.allocator;
    const k = try projectKey(a, "/home/xzg/project/phantty");
    defer a.free(k);
    try std.testing.expectEqualStrings("-home-xzg-project-phantty", k);
}

test "projectKey hashes overly long paths" {
    const a = std.testing.allocator;
    const long = "/" ++ ("segment/" ** 60);
    const k = try projectKey(a, long);
    defer a.free(k);
    try std.testing.expect(k.len <= MAX_PROJECT_KEY_LEN);
}

// --- Task 4: parseEntry + serializeEntry ---

pub const ParseError = error{InvalidMemory};

pub fn serializeEntry(allocator: std.mem.Allocator, e: Entry) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "---\nname: {s}\ndescription: {s}\ntype: {s}\ncreated: {s}\nupdated: {s}\n---\n{s}\n",
        .{ e.name, e.description, e.type_.toString(), e.created, e.updated, e.body },
    );
}

/// Parse a memory file (frontmatter + body). Mirrors skill_registry's
/// line-oriented `key: value` frontmatter. Caller owns the returned Entry.
pub fn parseEntry(allocator: std.mem.Allocator, bytes: []const u8) (ParseError || std.mem.Allocator.Error)!Entry {
    var name: []const u8 = "";
    var description: []const u8 = "";
    var type_: MemoryType = .user;
    var created: []const u8 = "";
    var updated: []const u8 = "";

    var it = std.mem.splitScalar(u8, bytes, '\n');
    const first = it.next() orelse return error.InvalidMemory;
    if (!std.mem.eql(u8, std.mem.trim(u8, first, " \t\r"), "---")) return error.InvalidMemory;

    var consumed: usize = first.len + 1;
    var closed = false;
    while (it.next()) |line| {
        consumed += line.len + 1;
        const t = std.mem.trim(u8, line, " \t\r");
        if (std.mem.eql(u8, t, "---")) {
            closed = true;
            break;
        }
        const colon = std.mem.indexOfScalar(u8, t, ':') orelse continue;
        const key = std.mem.trim(u8, t[0..colon], " \t");
        const val = std.mem.trim(u8, t[colon + 1 ..], " \t");
        if (std.mem.eql(u8, key, "name")) {
            name = val;
        } else if (std.mem.eql(u8, key, "description")) {
            description = val;
        } else if (std.mem.eql(u8, key, "type")) {
            type_ = MemoryType.fromString(val);
        } else if (std.mem.eql(u8, key, "created")) {
            created = val;
        } else if (std.mem.eql(u8, key, "updated")) {
            updated = val;
        }
    }
    if (!closed or name.len == 0) return error.InvalidMemory;

    const body_start = @min(consumed, bytes.len);
    const body = std.mem.trim(u8, bytes[body_start..], " \t\r\n");

    var out = Entry{
        .name = try allocator.dupe(u8, name),
        .description = try allocator.dupe(u8, description),
        .type_ = type_,
        .created = try allocator.dupe(u8, created),
        .updated = try allocator.dupe(u8, updated),
        .body = try allocator.dupe(u8, body),
    };
    errdefer out.deinit(allocator);
    return out;
}

test "serializeEntry then parseEntry round-trips" {
    const a = std.testing.allocator;
    var e = Entry{
        .name = try a.dupe(u8, "prefers-chinese"),
        .description = try a.dupe(u8, "用户偏好中文回复"),
        .type_ = .user,
        .created = try a.dupe(u8, "2026-06-08"),
        .updated = try a.dupe(u8, "2026-06-08"),
        .body = try a.dupe(u8, "默认 zh-CN。"),
    };
    defer e.deinit(a);

    const text = try serializeEntry(a, e);
    defer a.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "---\n"));

    var parsed = try parseEntry(a, text);
    defer parsed.deinit(a);
    try std.testing.expectEqualStrings("prefers-chinese", parsed.name);
    try std.testing.expectEqualStrings("用户偏好中文回复", parsed.description);
    try std.testing.expectEqual(MemoryType.user, parsed.type_);
    try std.testing.expectEqualStrings("默认 zh-CN。", parsed.body);
}

test "parseEntry rejects content without frontmatter or name" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidMemory, parseEntry(a, "no frontmatter here"));
    try std.testing.expectError(error.InvalidMemory, parseEntry(a, "---\ndescription: x\n---\nbody"));
}

// --- Task 5: buildIndexBlock ---

/// Build the `<wispterm-memory>` index block injected into the system prompt.
/// `project_path` (display path) + `project` lines are optional. Returns an
/// empty (caller-freed) slice when both tiers are empty. Lines are emitted
/// until `budget` bytes are reached, then a `(... N more ...)` note is added.
pub fn buildIndexBlock(
    allocator: std.mem.Allocator,
    global: []const IndexLine,
    project_path: ?[]const u8,
    project: ?[]const IndexLine,
    budget: usize,
) ![]u8 {
    const project_lines = project orelse &[_]IndexLine{};
    if (global.len == 0 and project_lines.len == 0) return allocator.alloc(u8, 0);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    // Context block injected into system prompt — facts from past sessions, not instructions.
    try out.appendSlice(allocator, "<wispterm-memory>\n");

    var budget_left: usize = budget;
    var dropped: usize = 0;

    if (global.len > 0) {
        try out.appendSlice(allocator, "Global:\n");
        try appendLines(allocator, &out, global, &budget_left, &dropped);
    }
    if (project_lines.len > 0) {
        if (project_path) |path| {
            try out.appendSlice(allocator, "Project (");
            try out.appendSlice(allocator, path);
            try out.appendSlice(allocator, "):\n");
        } else {
            try out.appendSlice(allocator, "Project:\n");
        }
        try appendLines(allocator, &out, project_lines, &budget_left, &dropped);
    }
    if (dropped > 0) {
        const note = try std.fmt.allocPrint(allocator, "(... {d} more; use memory_recall <name> to fetch)\n", .{dropped});
        defer allocator.free(note);
        try out.appendSlice(allocator, note);
    }
    try out.appendSlice(allocator, "</wispterm-memory>\n");
    return out.toOwnedSlice(allocator);
}

fn appendLines(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    lines: []const IndexLine,
    budget_left: *usize,
    dropped: *usize,
) !void {
    for (lines) |l| {
        const cost = l.name.len + l.description.len + 6; // "- " + ": " + "\n"
        if (cost > budget_left.*) {
            dropped.* += 1;
            continue;
        }
        budget_left.* -= cost;
        try out.appendSlice(allocator, "- ");
        try out.appendSlice(allocator, l.name);
        try out.appendSlice(allocator, ": ");
        try out.appendSlice(allocator, l.description);
        try out.append(allocator, '\n');
    }
}

test "buildIndexBlock renders both tiers and is parseable as background context" {
    const a = std.testing.allocator;
    const g = [_]IndexLine{.{ .name = "prefers-chinese", .description = "用户偏好中文", .updated = "2026-06-08" }};
    const p = [_]IndexLine{.{ .name = "build-cmds", .description = "zig build test", .updated = "2026-06-08" }};
    const block = try buildIndexBlock(a, &g, "/home/xzg/p", &p, INDEX_BUDGET_BYTES);
    defer a.free(block);
    try std.testing.expect(std.mem.indexOf(u8, block, "<wispterm-memory>") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "prefers-chinese: 用户偏好中文") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "/home/xzg/p") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "build-cmds: zig build test") != null);
}

test "buildIndexBlock returns empty string when nothing to inject" {
    const a = std.testing.allocator;
    const block = try buildIndexBlock(a, &.{}, null, null, INDEX_BUDGET_BYTES);
    defer a.free(block);
    try std.testing.expectEqual(@as(usize, 0), block.len);
}

test "buildIndexBlock truncates to the byte budget" {
    const a = std.testing.allocator;
    var many: [200]IndexLine = undefined;
    for (&many, 0..) |*l, i| {
        _ = i;
        l.* = .{ .name = "some-long-memory-name", .description = "a fairly long description line here", .updated = "2026-06-08" };
    }
    const block = try buildIndexBlock(a, &many, null, null, 512);
    defer a.free(block);
    try std.testing.expect(block.len <= 512 + 128); // budget + header/footer slack
    try std.testing.expect(std.mem.indexOf(u8, block, "more") != null);
}

// --- Task 6: File I/O layer ---

pub fn freeEntries(allocator: std.mem.Allocator, list: []Entry) void {
    for (list) |*e| e.deinit(allocator);
    allocator.free(list);
}

/// `<configDir>/memory/global`
pub fn globalDir(allocator: std.mem.Allocator) ![]u8 {
    const cfg = try dirs.configDir(allocator);
    defer allocator.free(cfg);
    return std.fs.path.join(allocator, &.{ cfg, "memory", "global" });
}

/// `<configDir>/memory/projects/<key>`
pub fn projectDir(allocator: std.mem.Allocator, working_dir: []const u8) ![]u8 {
    const cfg = try dirs.configDir(allocator);
    defer allocator.free(cfg);
    const key = try projectKey(allocator, working_dir);
    defer allocator.free(key);
    return std.fs.path.join(allocator, &.{ cfg, "memory", "projects", key });
}

fn entryFileName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.md", .{name});
}

/// List every `*.md` entry (except MEMORY.md) in `dir_path`, parsed. Missing
/// directory -> empty list. Malformed files are skipped.
pub fn loadDirEntries(allocator: std.mem.Allocator, dir_path: []const u8) ![]Entry {
    var list: std.ArrayListUnmanaged(Entry) = .empty;
    errdefer {
        for (list.items) |*e| e.deinit(allocator);
        list.deinit(allocator);
    }
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return list.toOwnedSlice(allocator),
        else => return err,
    };
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |ent| {
        if (ent.kind != .file) continue;
        if (std.mem.eql(u8, ent.name, "MEMORY.md")) continue;
        if (!std.mem.endsWith(u8, ent.name, ".md")) continue;
        const bytes = dir.readFileAlloc(allocator, ent.name, MAX_MEMORY_MD_BYTES) catch continue;
        defer allocator.free(bytes);
        var parsed = parseEntry(allocator, bytes) catch continue;
        list.append(allocator, parsed) catch |e| {
            parsed.deinit(allocator);
            return e;
        };
    }
    std.sort.insertion(Entry, list.items, {}, entryUpdatedDesc);
    return list.toOwnedSlice(allocator);
}

fn entryUpdatedDesc(_: void, a: Entry, b: Entry) bool {
    return std.mem.order(u8, a.updated, b.updated) == .gt;
}

/// Write `entry` as `<dir_path>/<name>.md` (atomic) and refresh MEMORY.md.
pub fn saveEntryToDir(allocator: std.mem.Allocator, dir_path: []const u8, entry: Entry) !void {
    try std.fs.cwd().makePath(dir_path);
    const file_name = try entryFileName(allocator, entry.name);
    defer allocator.free(file_name);
    const path = try std.fs.path.join(allocator, &.{ dir_path, file_name });
    defer allocator.free(path);
    const text = try serializeEntry(allocator, entry);
    defer allocator.free(text);
    try atomic_file.writeFileReplaceSafe(path, text);
    try rewriteIndex(allocator, dir_path);
}

/// Delete `<dir_path>/<name>.md` and refresh MEMORY.md. Returns whether it existed.
pub fn deleteEntryFromDir(allocator: std.mem.Allocator, dir_path: []const u8, name: []const u8) !bool {
    const file_name = try entryFileName(allocator, name);
    defer allocator.free(file_name);
    const path = try std.fs.path.join(allocator, &.{ dir_path, file_name });
    defer allocator.free(path);
    std.fs.cwd().deleteFile(path) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    try rewriteIndex(allocator, dir_path);
    return true;
}

/// Re-derive MEMORY.md from the entry files in `dir_path`.
pub fn rewriteIndex(allocator: std.mem.Allocator, dir_path: []const u8) !void {
    const entries = try loadDirEntries(allocator, dir_path);
    defer freeEntries(allocator, entries);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "# Memory index\n");
    for (entries) |e| {
        try out.appendSlice(allocator, "- ");
        try out.appendSlice(allocator, e.name);
        try out.appendSlice(allocator, ": ");
        try out.appendSlice(allocator, e.description);
        try out.append(allocator, '\n');
    }
    try std.fs.cwd().makePath(dir_path);
    const idx_path = try std.fs.path.join(allocator, &.{ dir_path, "MEMORY.md" });
    defer allocator.free(idx_path);
    try atomic_file.writeFileReplaceSafe(idx_path, out.items);
}

test "saveEntryToDir + loadDirEntries + deleteEntryFromDir round-trip on disk" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    var e = Entry{
        .name = try a.dupe(u8, "uses-uv"),
        .description = try a.dupe(u8, "用 uv 管理 Python"),
        .type_ = .user,
        .created = try a.dupe(u8, "2026-06-08"),
        .updated = try a.dupe(u8, "2026-06-08"),
        .body = try a.dupe(u8, "Prefer uv sync/run/add."),
    };
    defer e.deinit(a);

    try saveEntryToDir(a, root, e);

    // MEMORY.md index written alongside the entry file.
    const idx = try tmp.dir.readFileAlloc(a, "MEMORY.md", MAX_MEMORY_MD_BYTES);
    defer a.free(idx);
    try std.testing.expect(std.mem.indexOf(u8, idx, "uses-uv: 用 uv 管理 Python") != null);

    const loaded = try loadDirEntries(a, root);
    defer freeEntries(a, loaded);
    try std.testing.expectEqual(@as(usize, 1), loaded.len);
    try std.testing.expectEqualStrings("uses-uv", loaded[0].name);

    try std.testing.expect(try deleteEntryFromDir(a, root, "uses-uv"));
    const after = try loadDirEntries(a, root);
    defer freeEntries(a, after);
    try std.testing.expectEqual(@as(usize, 0), after.len);
}

test "loadDirEntries skips malformed files and the index file" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);
    try tmp.dir.writeFile(.{ .sub_path = "broken.md", .data = "not a memory" });
    try tmp.dir.writeFile(.{ .sub_path = "MEMORY.md", .data = "# Memory index\n" });
    const loaded = try loadDirEntries(a, root);
    defer freeEntries(a, loaded);
    try std.testing.expectEqual(@as(usize, 0), loaded.len);
}

// --- Task 7: Orchestration layer ---

fn dirForTier(allocator: std.mem.Allocator, tier: Tier, working_dir: ?[]const u8) !?[]u8 {
    switch (tier) {
        .global => return try globalDir(allocator),
        .project => {
            const wd = working_dir orelse return null;
            if (wd.len == 0) return null;
            return try projectDir(allocator, wd);
        },
    }
}

/// Save or update a memory in the chosen tier; tier=project without a working
/// dir falls back to global. Returns a caller-freed human-readable message.
pub fn saveMemory(
    allocator: std.mem.Allocator,
    tier: Tier,
    working_dir: ?[]const u8,
    name: []const u8,
    description: []const u8,
    type_: MemoryType,
    body: []const u8,
) ![]u8 {
    var effective = tier;
    var dir = try dirForTier(allocator, tier, working_dir);
    if (dir == null) {
        effective = .global;
        dir = try globalDir(allocator);
    }
    defer allocator.free(dir.?);

    var date_buf: [10]u8 = undefined;
    const today = todayDate(&date_buf);

    // Preserve `created` if the entry already exists.
    var created_owned: ?[]u8 = null;
    defer if (created_owned) |c| allocator.free(c);
    {
        const existing = try loadDirEntries(allocator, dir.?);
        defer freeEntries(allocator, existing);
        for (existing) |e| {
            if (std.mem.eql(u8, e.name, name) and e.created.len > 0) {
                created_owned = try allocator.dupe(u8, e.created);
                break;
            }
        }
    }

    var entry = Entry{
        .name = try allocator.dupe(u8, name),
        .description = try allocator.dupe(u8, description),
        .type_ = type_,
        .created = if (created_owned) |c| try allocator.dupe(u8, c) else try allocator.dupe(u8, today),
        .updated = try allocator.dupe(u8, today),
        .body = try allocator.dupe(u8, body),
    };
    defer entry.deinit(allocator);

    try saveEntryToDir(allocator, dir.?, entry);
    return std.fmt.allocPrint(allocator, "Saved memory '{s}' to {s} tier.", .{ name, @tagName(effective) });
}

/// Full text of a memory: project tier first, then global. Caller frees.
pub fn recallMemory(allocator: std.mem.Allocator, working_dir: []const u8, name: []const u8) ![]u8 {
    const tiers = [_]Tier{ .project, .global };
    for (tiers) |tier| {
        const dir = (try dirForTier(allocator, tier, if (working_dir.len > 0) working_dir else null)) orelse continue;
        defer allocator.free(dir);
        const entries = try loadDirEntries(allocator, dir);
        defer freeEntries(allocator, entries);
        for (entries) |e| {
            if (std.mem.eql(u8, e.name, name)) {
                return std.fmt.allocPrint(allocator, "[{s}] {s}\n\n{s}", .{ @tagName(tier), e.description, e.body });
            }
        }
    }
    return std.fmt.allocPrint(allocator, "No memory named '{s}'. Use /memory to list current memories.", .{name});
}

/// Delete by name. `tier` null searches project then global. Caller frees msg.
pub fn deleteMemory(allocator: std.mem.Allocator, working_dir: []const u8, name: []const u8, tier: ?Tier) ![]u8 {
    const candidates = if (tier) |t| &[_]Tier{t} else &[_]Tier{ .project, .global };
    for (candidates) |cand| {
        const dir = (try dirForTier(allocator, cand, if (working_dir.len > 0) working_dir else null)) orelse continue;
        defer allocator.free(dir);
        if (try deleteEntryFromDir(allocator, dir, name)) {
            return std.fmt.allocPrint(allocator, "Deleted memory '{s}' from {s} tier.", .{ name, @tagName(cand) });
        }
    }
    return std.fmt.allocPrint(allocator, "No memory named '{s}' to delete.", .{name});
}

fn indexLinesFromEntries(allocator: std.mem.Allocator, entries: []const Entry) ![]IndexLine {
    const lines = try allocator.alloc(IndexLine, entries.len);
    for (entries, 0..) |e, i| lines[i] = .{ .name = e.name, .description = e.description, .updated = e.updated };
    return lines;
}

/// Compose the `<wispterm-memory>` block for the current working dir (both tiers).
pub fn buildInjectionBlock(allocator: std.mem.Allocator, working_dir: []const u8) ![]u8 {
    const g_dir = try globalDir(allocator);
    defer allocator.free(g_dir);
    const g_entries = try loadDirEntries(allocator, g_dir);
    defer freeEntries(allocator, g_entries);
    const g_lines = try indexLinesFromEntries(allocator, g_entries);
    defer allocator.free(g_lines);

    if (working_dir.len == 0) {
        return buildIndexBlock(allocator, g_lines, null, null, INDEX_BUDGET_BYTES);
    }
    const p_dir = try projectDir(allocator, working_dir);
    defer allocator.free(p_dir);
    const p_entries = try loadDirEntries(allocator, p_dir);
    defer freeEntries(allocator, p_entries);
    const p_lines = try indexLinesFromEntries(allocator, p_entries);
    defer allocator.free(p_lines);
    return buildIndexBlock(allocator, g_lines, working_dir, p_lines, INDEX_BUDGET_BYTES);
}

/// Human-readable listing for the `/memory` command. Caller frees.
pub fn listForDisplay(allocator: std.mem.Allocator, working_dir: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    const g_dir = try globalDir(allocator);
    defer allocator.free(g_dir);
    const g_entries = try loadDirEntries(allocator, g_dir);
    defer freeEntries(allocator, g_entries);
    try out.appendSlice(allocator, "Global memory:\n");
    if (g_entries.len == 0) try out.appendSlice(allocator, "  (none)\n");
    for (g_entries) |e| {
        try out.appendSlice(allocator, "  - ");
        try out.appendSlice(allocator, e.name);
        try out.appendSlice(allocator, ": ");
        try out.appendSlice(allocator, e.description);
        try out.append(allocator, '\n');
    }

    if (working_dir.len > 0) {
        const p_dir = try projectDir(allocator, working_dir);
        defer allocator.free(p_dir);
        const p_entries = try loadDirEntries(allocator, p_dir);
        defer freeEntries(allocator, p_entries);
        try out.appendSlice(allocator, "Project memory (");
        try out.appendSlice(allocator, working_dir);
        try out.appendSlice(allocator, "):\n");
        if (p_entries.len == 0) try out.appendSlice(allocator, "  (none)\n");
        for (p_entries) |e| {
            try out.appendSlice(allocator, "  - ");
            try out.appendSlice(allocator, e.name);
            try out.appendSlice(allocator, ": ");
            try out.appendSlice(allocator, e.description);
            try out.append(allocator, '\n');
        }
    }
    return out.toOwnedSlice(allocator);
}

test "orchestration: saveMemory then buildInjectionBlock and recallMemory" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);
    dirs.setTestConfigDirForCurrentThread(root);
    defer dirs.clearTestConfigDirForCurrentThread();

    const wd = "/home/xzg/project/phantty";

    const m1 = try saveMemory(a, .global, null, "prefers-chinese", "用户偏好中文", .user, "默认 zh-CN。");
    a.free(m1);
    const m2 = try saveMemory(a, .project, wd, "build-cmds", "zig build test-full", .project, "fast + full suites");
    a.free(m2);

    const block = try buildInjectionBlock(a, wd);
    defer a.free(block);
    try std.testing.expect(std.mem.indexOf(u8, block, "prefers-chinese") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "build-cmds") != null);

    const recalled = try recallMemory(a, wd, "build-cmds");
    defer a.free(recalled);
    try std.testing.expect(std.mem.indexOf(u8, recalled, "fast + full suites") != null);
}

test "orchestration: saveMemory tier=project without working dir falls back to global" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);
    dirs.setTestConfigDirForCurrentThread(root);
    defer dirs.clearTestConfigDirForCurrentThread();

    const msg = try saveMemory(a, .project, null, "x", "y", .user, "z");
    defer a.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "global") != null);

    const block = try buildInjectionBlock(a, "");
    defer a.free(block);
    try std.testing.expect(std.mem.indexOf(u8, block, "x: y") != null);
}

test "orchestration: deleteMemory and disabled-safe empty injection" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);
    dirs.setTestConfigDirForCurrentThread(root);
    defer dirs.clearTestConfigDirForCurrentThread();

    const m = try saveMemory(a, .global, null, "gone", "soon", .user, "body");
    a.free(m);
    const d = try deleteMemory(a, "", "gone", null);
    defer a.free(d);
    try std.testing.expect(std.mem.indexOf(u8, d, "Deleted") != null or std.mem.indexOf(u8, d, "删除") != null);

    const block = try buildInjectionBlock(a, "");
    defer a.free(block);
    try std.testing.expectEqual(@as(usize, 0), block.len);
}
