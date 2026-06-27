//! Skill and custom-command root-path loading, plus slash-command listing output.
//! Leaf module: imports only std, skill_registry, command_registry, platform_dirs,
//! and ai_chat_composer. No Session state.
const std = @import("std");
const skill_registry = @import("skill_registry.zig");
const command_registry = @import("command/registry.zig");
const platform_dirs = @import("platform/dirs.zig");
const ai_chat_composer = @import("ai_chat_composer.zig");
const ai_skill_distill = @import("ai_skill_distill.zig");

const SlashCommand = ai_chat_composer.SlashCommand;
const slash_command_entries = ai_chat_composer.slash_command_entries;

pub fn slashCommandListOutput(allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "Available commands:");
    for (slash_command_entries) |entry| {
        try out.print(allocator, "\n{s} - {s}", .{ entry.suggestion.command, entry.suggestion.description });
    }
    return out.toOwnedSlice(allocator);
}

pub fn listSkillsForDisplay(allocator: std.mem.Allocator) ![]u8 {
    const roots = try defaultSkillRootPaths(allocator);
    defer freeSkillRootPaths(allocator, roots);

    return listSkillsForDisplayFromRoots(allocator, roots);
}

fn listSkillsForDisplayFromRoots(allocator: std.mem.Allocator, root_paths: []const []const u8) ![]u8 {
    const merged = try loadSkillSuggestionListFromRoots(allocator, root_paths);
    defer {
        freeOwnedSkillMetaList(allocator, merged);
        allocator.free(merged);
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    if (merged.len == 0) {
        try out.appendSlice(allocator, "No skills found under configured skill roots.");
    } else {
        try out.appendSlice(allocator, "Available skills:\n");
        for (merged) |meta| {
            try out.print(allocator, "- ${s}: {s}\n", .{ meta.name, meta.description });
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn loadSkillSuggestionListFromRoots(allocator: std.mem.Allocator, root_paths: []const []const u8) ![]skill_registry.SkillMeta {
    var merged: std.ArrayListUnmanaged(skill_registry.SkillMeta) = .empty;
    errdefer {
        freeOwnedSkillMetaList(allocator, merged.items);
        merged.deinit(allocator);
    }

    for (root_paths) |root_path| {
        var root = openSkillRoot(root_path) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue,
            else => |e| return e,
        };
        defer root.deinit();

        const list = try skill_registry.listSkills(allocator, root.dir, root.skills_rel);
        defer allocator.free(list);
        for (list) |*meta| {
            if (skillMetaNameExists(merged.items, meta.name)) {
                meta.deinit(allocator);
                continue;
            }
            try merged.append(allocator, meta.*);
            meta.* = undefined;
        }
    }

    std.sort.insertion(skill_registry.SkillMeta, merged.items, {}, skillMetaNameLessThan);
    return merged.toOwnedSlice(allocator);
}

pub fn loadSkillPreloadContent(allocator: std.mem.Allocator, skill_name: []const u8) !?[]u8 {
    const roots = try defaultSkillRootPaths(allocator);
    defer freeSkillRootPaths(allocator, roots);
    return loadSkillPreloadContentFromRoots(allocator, skill_name, roots);
}

fn loadSkillPreloadContentFromRoots(allocator: std.mem.Allocator, skill_name: []const u8, root_paths: []const []const u8) !?[]u8 {
    var snapshot = loadSkillSnapshotFromRoots(allocator, skill_name, root_paths) catch |err| switch (err) {
        skill_registry.LookupError.SkillNotFound,
        skill_registry.LookupError.DuplicateSkillName,
        skill_registry.LookupError.InvalidSkillMarkdown,
        skill_registry.LookupError.SkillTooLarge,
        => return null,
        else => |e| return e,
    };
    defer snapshot.deinit(allocator);
    return try allocator.dupe(u8, snapshot.content);
}

pub fn loadSkillSnapshotFromRoots(
    allocator: std.mem.Allocator,
    skill_name: []const u8,
    root_paths: []const []const u8,
) !skill_registry.Snapshot {
    for (root_paths) |root_path| {
        var root = openSkillRoot(root_path) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue,
            else => |e| return e,
        };
        defer root.deinit();

        return skill_registry.loadSkillSnapshot(allocator, root.dir, root.skills_rel, skill_name) catch |err| switch (err) {
            skill_registry.LookupError.SkillNotFound => continue,
            else => |e| return e,
        };
    }
    return skill_registry.LookupError.SkillNotFound;
}

const SkillRoot = struct {
    dir: std.fs.Dir,
    skills_rel: []const u8,
    owns_dir: bool,

    fn deinit(self: *SkillRoot) void {
        if (self.owns_dir) self.dir.close();
        self.* = undefined;
    }
};

fn openSkillRoot(root_path: []const u8) !SkillRoot {
    if (std.fs.path.dirname(root_path)) |parent| {
        return .{
            .dir = try openDirectoryPath(parent),
            .skills_rel = std.fs.path.basename(root_path),
            .owns_dir = true,
        };
    }
    return .{
        .dir = std.fs.cwd(),
        .skills_rel = root_path,
        .owns_dir = false,
    };
}

pub fn openDirectoryPath(path: []const u8) !std.fs.Dir {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.openDirAbsolute(path, .{ .iterate = true });
    }
    return std.fs.cwd().openDir(path, .{ .iterate = true });
}

pub fn defaultSkillRootPaths(allocator: std.mem.Allocator) ![][]const u8 {
    var roots: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (roots.items) |root| allocator.free(root);
        roots.deinit(allocator);
    }

    if (platform_dirs.skillsDir(allocator)) |appdata_skills| {
        try appendOwnedSkillRootPath(allocator, &roots, appdata_skills);
    } else |_| {}
    if (platform_dirs.pluginSkillsDir(allocator)) |appdata_plugin_skills| {
        try appendOwnedSkillRootPath(allocator, &roots, appdata_plugin_skills);
    } else |_| {}

    try appendSkillRootPath(allocator, &roots, "skills");
    try appendSkillRootPath(allocator, &roots, "plugins/skills");

    if (std.fs.selfExeDirPathAlloc(allocator)) |exe_dir| {
        defer allocator.free(exe_dir);
        const exe_skills = try std.fs.path.join(allocator, &.{ exe_dir, "skills" });
        try appendOwnedSkillRootPath(allocator, &roots, exe_skills);
        const exe_plugin_skills = try std.fs.path.join(allocator, &.{ exe_dir, "plugins", "skills" });
        try appendOwnedSkillRootPath(allocator, &roots, exe_plugin_skills);

        // macOS .app bundle layout: the executable lives in Contents/MacOS and
        // the bundled plugins are shipped under Contents/Resources/plugins.
        const res_skills = try std.fs.path.join(allocator, &.{ exe_dir, "..", "Resources", "skills" });
        try appendOwnedSkillRootPath(allocator, &roots, res_skills);
        const res_plugin_skills = try std.fs.path.join(allocator, &.{ exe_dir, "..", "Resources", "plugins", "skills" });
        try appendOwnedSkillRootPath(allocator, &roots, res_plugin_skills);
    } else |_| {}

    return roots.toOwnedSlice(allocator);
}

pub fn defaultCommandRootPaths(allocator: std.mem.Allocator) ![][]const u8 {
    var roots: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (roots.items) |r| allocator.free(r);
        roots.deinit(allocator);
    }
    if (platform_dirs.commandsDir(allocator)) |d| {
        try appendOwnedSkillRootPath(allocator, &roots, d);
    } else |_| {}
    try appendSkillRootPath(allocator, &roots, "commands");
    return roots.toOwnedSlice(allocator);
}

pub const DistilledSkillSaveResult = struct {
    skill_name: []u8,
    skill_path: []u8,

    pub fn deinit(self: *DistilledSkillSaveResult, allocator: std.mem.Allocator) void {
        allocator.free(self.skill_name);
        allocator.free(self.skill_path);
        self.* = undefined;
    }
};

pub fn defaultWritableSkillRootPath(allocator: std.mem.Allocator) ![]const u8 {
    return platform_dirs.skillsDir(allocator);
}

pub fn saveDistilledCandidate(
    allocator: std.mem.Allocator,
    candidate: ai_skill_distill.Candidate,
) !DistilledSkillSaveResult {
    if (!ai_skill_distill.isValidSlug(candidate.name)) return error.InvalidSkillName;

    const root = try defaultWritableSkillRootPath(allocator);
    defer allocator.free(root);
    try std.fs.cwd().makePath(root);

    const skill_dir = try std.fs.path.join(allocator, &.{ root, candidate.name });
    defer allocator.free(skill_dir);
    std.fs.cwd().makeDir(skill_dir) catch |err| switch (err) {
        error.PathAlreadyExists => return error.SkillAlreadyExists,
        else => |e| return e,
    };
    var created_skill_dir = true;
    errdefer if (created_skill_dir) std.fs.cwd().deleteTree(skill_dir) catch {};

    const markdown = try ai_skill_distill.renderSkillMarkdown(allocator, candidate);
    defer allocator.free(markdown);
    if (markdown.len > skill_registry.MAX_SKILL_MD_BYTES) return error.SkillTooLarge;
    if (ai_skill_distill.containsSensitiveMaterial(markdown)) return error.SensitiveCandidate;

    var dir = try openDirectoryPath(skill_dir);
    defer dir.close();
    var write_buffer: [0]u8 = .{};
    var atomic = try dir.atomicFile("SKILL.md", .{ .write_buffer = &write_buffer });
    defer atomic.deinit();
    try atomic.file_writer.file.writeAll(markdown);
    try atomic.finish();
    created_skill_dir = false;

    const skill_name = try allocator.dupe(u8, candidate.name);
    errdefer allocator.free(skill_name);
    const skill_path = try std.fs.path.join(allocator, &.{ root, candidate.name, "SKILL.md" });
    errdefer allocator.free(skill_path);
    return .{
        .skill_name = skill_name,
        .skill_path = skill_path,
    };
}

fn appendSkillRootPath(
    allocator: std.mem.Allocator,
    roots: *std.ArrayListUnmanaged([]const u8),
    root_path: []const u8,
) !void {
    const owned = try allocator.dupe(u8, root_path);
    errdefer allocator.free(owned);
    try appendOwnedSkillRootPath(allocator, roots, owned);
}

fn appendOwnedSkillRootPath(
    allocator: std.mem.Allocator,
    roots: *std.ArrayListUnmanaged([]const u8),
    owned_root_path: []const u8,
) !void {
    for (roots.items) |existing| {
        if (std.mem.eql(u8, existing, owned_root_path)) {
            allocator.free(owned_root_path);
            return;
        }
    }
    errdefer allocator.free(owned_root_path);
    try roots.append(allocator, owned_root_path);
}

pub fn freeSkillRootPaths(allocator: std.mem.Allocator, roots: [][]const u8) void {
    for (roots) |root| allocator.free(root);
    allocator.free(roots);
}

/// Maps a custom command's `action:` frontmatter value to the built-in slash
/// command it triggers. Returns null for unrecognized actions (those commands
/// are dropped during load).
pub fn knownActionFromName(value: []const u8) ?SlashCommand {
    if (std.mem.eql(u8, value, "clear_context")) return .clear;
    if (std.mem.eql(u8, value, "restore_session")) return .resume_session;
    if (std.mem.eql(u8, value, "set_permission")) return .permission;
    if (std.mem.eql(u8, value, "export_markdown")) return .export_markdown;
    return null;
}

/// True when `name` (without a leading slash) collides with a built-in slash
/// command. The registry stores names without a slash (e.g. "review"); built-in
/// entries store them with one (e.g. "/clear").
pub fn isBuiltinCommandName(name: []const u8) bool {
    if (name.len == 0) return false;
    var buf: [128]u8 = undefined;
    if (name.len + 1 > buf.len) return false;
    buf[0] = '/';
    @memcpy(buf[1 .. 1 + name.len], name);
    const slashed = buf[0 .. 1 + name.len];
    for (slash_command_entries) |entry| {
        if (std.mem.eql(u8, slashed, entry.suggestion.command)) return true;
    }
    return false;
}

pub fn hasName(items: []const command_registry.CustomCommand, name: []const u8) bool {
    for (items) |c| {
        if (std.mem.eql(u8, c.name, name)) return true;
    }
    return false;
}

pub fn freeOwnedSkillMetaList(allocator: std.mem.Allocator, list: []skill_registry.SkillMeta) void {
    for (list) |*skill| {
        skill.deinit(allocator);
    }
}

fn skillMetaNameExists(list: []const skill_registry.SkillMeta, name: []const u8) bool {
    for (list) |meta| {
        if (std.mem.eql(u8, meta.name, name)) return true;
    }
    return false;
}

fn skillMetaNameLessThan(_: void, lhs: skill_registry.SkillMeta, rhs: skill_registry.SkillMeta) bool {
    return std.mem.lessThan(u8, lhs.name, rhs.name);
}

test "isBuiltinCommandName recognizes built-in slash commands only" {
    try std.testing.expect(isBuiltinCommandName("clear"));
    try std.testing.expect(isBuiltinCommandName("commands"));
    try std.testing.expect(!isBuiltinCommandName("review"));
    try std.testing.expect(!isBuiltinCommandName(""));
}

test "session loads custom commands from a commands directory" {
    const a = std.testing.allocator;
    const root = ".zig-cache/tmp/cmdtest";
    std.fs.cwd().deleteTree(root) catch {};
    try std.fs.cwd().makePath(root ++ "/commands");
    defer std.fs.cwd().deleteTree(root) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = root ++ "/commands/review.md", .data = "---\nname: review\ndescription: review diff\n---\nReview the diff." });

    var dir = try std.fs.cwd().openDir(root, .{});
    defer dir.close();
    const cmds = try command_registry.listCommands(a, dir, "commands");
    defer command_registry.freeCommandList(a, cmds);
    try std.testing.expectEqual(@as(usize, 1), cmds.len);
    try std.testing.expectEqualStrings("review", cmds[0].name);
}

test "ai chat lists skills from explicit root paths" {
    const allocator = std.testing.allocator;
    const root = ".zig-cache/skill-root-list-test";
    std.fs.cwd().deleteTree(root) catch {};
    defer std.fs.cwd().deleteTree(root) catch {};

    try std.fs.cwd().makePath(root ++ "/exe/skills/pdf");
    try std.fs.cwd().writeFile(.{
        .sub_path = root ++ "/exe/skills/pdf/SKILL.md",
        .data = "---\nname: pdf\ndescription: Work with PDF files.\n---\n# PDF\n",
    });

    const roots = [_][]const u8{
        root ++ "/missing/skills",
        root ++ "/exe/skills",
    };
    const output = try listSkillsForDisplayFromRoots(allocator, roots[0..]);
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "- $pdf: Work with PDF files.") != null);
}

test "ai chat default skill roots include plugin skills directory" {
    const roots = try defaultSkillRootPaths(std.testing.allocator);
    defer freeSkillRootPaths(std.testing.allocator, roots);

    var found_plugins_skills = false;
    for (roots) |root| {
        if (std.mem.eql(u8, root, "plugins/skills")) {
            found_plugins_skills = true;
            break;
        }
    }

    try std.testing.expect(found_plugins_skills);
}

test "distilled skills save only to user config skills root and refuse overwrite" {
    const allocator = std.testing.allocator;
    const root = ".zig-cache/tmp/distilled-skill-save-test";
    std.fs.cwd().deleteTree(root) catch {};
    defer std.fs.cwd().deleteTree(root) catch {};
    try std.fs.cwd().makePath(root);

    platform_dirs.setTestConfigDirForCurrentThread(root);
    defer platform_dirs.clearTestConfigDirForCurrentThread();

    const writable_root = try defaultWritableSkillRootPath(allocator);
    defer allocator.free(writable_root);
    const expected_root = try std.fs.path.join(allocator, &.{ root, "skills" });
    defer allocator.free(expected_root);
    try std.testing.expectEqualStrings(expected_root, writable_root);

    const candidate = ai_skill_distill.Candidate{
        .name = @constCast("ssh-transfer"),
        .description = @constCast("Diagnose SSH transfer failures."),
        .body = @constCast("# Steps\n\nRun checks."),
        .source_summary = @constCast("Do not write this summary."),
    };
    var saved = try saveDistilledCandidate(allocator, candidate);
    defer saved.deinit(allocator);

    try std.testing.expectEqualStrings("ssh-transfer", saved.skill_name);
    const expected_skill_path = try std.fs.path.join(allocator, &.{ root, "skills", "ssh-transfer", "SKILL.md" });
    defer allocator.free(expected_skill_path);
    try std.testing.expectEqualStrings(expected_skill_path, saved.skill_path);

    const markdown = try std.fs.cwd().readFileAlloc(allocator, root ++ "/skills/ssh-transfer/SKILL.md", skill_registry.MAX_SKILL_MD_BYTES);
    defer allocator.free(markdown);
    try std.testing.expect(std.mem.containsAtLeast(u8, markdown, 1, "name: ssh-transfer"));
    try std.testing.expect(std.mem.containsAtLeast(u8, markdown, 1, "description: Diagnose SSH transfer failures."));
    try std.testing.expect(!std.mem.containsAtLeast(u8, markdown, 1, "Do not write this summary."));

    try std.testing.expectError(error.SkillAlreadyExists, saveDistilledCandidate(allocator, candidate));
}
