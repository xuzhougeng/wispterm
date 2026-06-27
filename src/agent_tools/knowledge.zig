//! Agent knowledge tool runtime adapters.
const std = @import("std");
const ai_chat_skills = @import("../assistant/conversation/skills.zig");
const skill_registry = @import("../skill/registry.zig");
const wispterm_docs = @import("../wispterm_docs.zig");

pub fn skillInfo(allocator: std.mem.Allocator, skill_name: []const u8) ![]u8 {
    const roots = try ai_chat_skills.defaultSkillRootPaths(allocator);
    defer ai_chat_skills.freeSkillRootPaths(allocator, roots);
    return skillInfoFromRoots(allocator, skill_name, roots);
}

pub fn skillInfoFromRoots(allocator: std.mem.Allocator, skill_name: []const u8, root_paths: []const []const u8) ![]u8 {
    var snapshot = ai_chat_skills.loadSkillSnapshotFromRoots(allocator, skill_name, root_paths) catch |err| switch (err) {
        skill_registry.LookupError.SkillNotFound => return std.fmt.allocPrint(allocator, "Skill not found: {s}", .{skill_name}),
        skill_registry.LookupError.DuplicateSkillName => return std.fmt.allocPrint(allocator, "Duplicate skill name: {s}", .{skill_name}),
        skill_registry.LookupError.InvalidSkillMarkdown => return std.fmt.allocPrint(allocator, "Invalid SKILL.md for skill: {s}", .{skill_name}),
        skill_registry.LookupError.SkillTooLarge => return std.fmt.allocPrint(allocator, "SKILL.md too large for skill: {s}", .{skill_name}),
        else => |e| return std.fmt.allocPrint(allocator, "Failed to load skill {s}: {}", .{ skill_name, e }),
    };
    defer snapshot.deinit(allocator);
    return allocator.dupe(u8, snapshot.content);
}

pub fn wisptermDocs(allocator: std.mem.Allocator, topic: ?[]const u8) ![]u8 {
    if (topic) |name| {
        if (wispterm_docs.readTopic(name)) |content| {
            return allocator.dupe(u8, content);
        }
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.print(allocator, "Unknown topic \"{s}\". Available topics:", .{name});
        for (wispterm_docs.topics) |t| {
            try out.print(allocator, " {s}", .{t.name});
        }
        return out.toOwnedSlice(allocator);
    }
    return wispterm_docs.listTopics(allocator);
}

test "skill_info loads from explicit root paths" {
    const allocator = std.testing.allocator;
    const root = ".zig-cache/skill-root-load-test";
    std.fs.cwd().deleteTree(root) catch {};
    defer std.fs.cwd().deleteTree(root) catch {};

    try std.fs.cwd().makePath(root ++ "/bin/skills/web");
    try std.fs.cwd().writeFile(.{
        .sub_path = root ++ "/bin/skills/web/SKILL.md",
        .data = "---\nname: web\ndescription: Browse pages.\n---\n# Web Skill\n",
    });

    const roots = [_][]const u8{
        root ++ "/cwd/skills",
        root ++ "/bin/skills",
    };
    const output = try skillInfoFromRoots(allocator, "web", roots[0..]);
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "# Skill: web") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "# Web Skill") != null);
}

test "wispterm_docs lists topics when no topic is given" {
    const a = std.testing.allocator;
    const text = try wisptermDocs(a, null);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "faq") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "configuration") != null);
}

test "wispterm_docs returns content for a known topic" {
    const a = std.testing.allocator;
    const text = try wisptermDocs(a, "faq");
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "FAQ") != null);
}

test "wispterm_docs reports unknown topic with the topic list" {
    const a = std.testing.allocator;
    const text = try wisptermDocs(a, "does-not-exist");
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Unknown topic") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "faq") != null);
}
