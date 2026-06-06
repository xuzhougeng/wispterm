//! Pure builders for the POSIX shell strings used by the skill transfer runner.
//! Names are single-quote-escaped; "$HOME" stays expandable. No I/O here so the
//! quoting/path logic is unit-testable in isolation.
const std = @import("std");

/// Split a scan rel_path into the tar root and the item under it.
/// - skill_md:  ".claude/skills/<name>/SKILL.md" -> root ".claude/skills", item "<name>"
/// - prompt_md: ".codex/prompts/<name>.md"       -> root ".codex/prompts", item "<name>.md"
pub const SkillPath = struct { root_rel: []const u8, item: []const u8 };

pub fn splitSkillPath(rel_path: []const u8) ?SkillPath {
    if (std.mem.endsWith(u8, rel_path, "/SKILL.md")) {
        const dir = rel_path[0 .. rel_path.len - "/SKILL.md".len]; // ".../<name>"
        const slash = std.mem.lastIndexOfScalar(u8, dir, '/') orelse return null;
        return .{ .root_rel = dir[0..slash], .item = dir[slash + 1 ..] };
    }
    const slash = std.mem.lastIndexOfScalar(u8, rel_path, '/') orelse return null;
    return .{ .root_rel = rel_path[0..slash], .item = rel_path[slash + 1 ..] };
}

fn appendQuoted(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try buf.append(allocator, '\'');
    for (s) |c| {
        if (c == '\'') try buf.appendSlice(allocator, "'\\''") else try buf.append(allocator, c);
    }
    try buf.append(allocator, '\'');
}

/// `tar -czf '<tmp>' -C "$HOME"/'<root>' '<item>'` — package a skill into <tmp>.
pub fn tarCreateCmd(allocator: std.mem.Allocator, root_rel: []const u8, item: []const u8, tmp: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "tar -czf ");
    try appendQuoted(&buf, allocator, tmp);
    try buf.appendSlice(allocator, " -C \"$HOME\"/");
    try appendQuoted(&buf, allocator, root_rel);
    try buf.append(allocator, ' ');
    try appendQuoted(&buf, allocator, item);
    return buf.toOwnedSlice(allocator);
}

/// Stage-then-swap extract: extract <tmp> into a staging dir under the root,
/// then atomically replace "$HOME/<root>/<item>". A failed extract leaves the
/// live skill untouched. Uses $$ for staging uniqueness.
pub fn tarExtractCmd(allocator: std.mem.Allocator, root_rel: []const u8, item: []const u8, tmp: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    // D="$HOME"/'<root>'
    try buf.appendSlice(allocator, "D=\"$HOME\"/");
    try appendQuoted(&buf, allocator, root_rel);
    try buf.appendSlice(allocator, "; mkdir -p \"$D\"; S=\"$D/.wisptmp.$$\"; rm -rf \"$S\"; mkdir -p \"$S\"; ");
    // tar -xzf '<tmp>' -C "$S" && rm -rf "$D"/'<item>' && mv "$S"/'<item>' "$D"/'<item>'; rm -rf "$S"
    try buf.appendSlice(allocator, "tar -xzf ");
    try appendQuoted(&buf, allocator, tmp);
    try buf.appendSlice(allocator, " -C \"$S\" && rm -rf \"$D\"/");
    try appendQuoted(&buf, allocator, item);
    try buf.appendSlice(allocator, " && mv \"$S\"/");
    try appendQuoted(&buf, allocator, item);
    try buf.appendSlice(allocator, " \"$D\"/");
    try appendQuoted(&buf, allocator, item);
    try buf.appendSlice(allocator, "; rm -rf \"$S\"");
    return buf.toOwnedSlice(allocator);
}

// --- Tests ---

test "skill_transfer_cmd: splitSkillPath for skill_md and prompt_md" {
    const a = splitSkillPath(".claude/skills/roundtable/SKILL.md").?;
    try std.testing.expectEqualStrings(".claude/skills", a.root_rel);
    try std.testing.expectEqualStrings("roundtable", a.item);
    const b = splitSkillPath(".codex/prompts/foo.md").?;
    try std.testing.expectEqualStrings(".codex/prompts", b.root_rel);
    try std.testing.expectEqualStrings("foo.md", b.item);
}

test "skill_transfer_cmd: tarCreateCmd shape + quoting" {
    const allocator = std.testing.allocator;
    const cmd = try tarCreateCmd(allocator, ".claude/skills", "a'b", "/tmp/x.tgz");
    defer allocator.free(cmd);
    try std.testing.expectEqualStrings(
        "tar -czf '/tmp/x.tgz' -C \"$HOME\"/'.claude/skills' 'a'\\''b'",
        cmd,
    );
}

test "skill_transfer_cmd: tarExtractCmd stages then swaps" {
    const allocator = std.testing.allocator;
    const cmd = try tarExtractCmd(allocator, ".claude/skills", "pdf", "/tmp/x.tgz");
    defer allocator.free(cmd);
    try std.testing.expect(std.mem.indexOf(u8, cmd, ".wisptmp.$$") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "tar -xzf '/tmp/x.tgz' -C \"$S\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "mv \"$S\"/'pdf' \"$D\"/'pdf'") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "&& rm -rf \"$D\"/'pdf'") != null);
}
