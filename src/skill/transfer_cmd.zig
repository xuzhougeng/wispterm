//! Pure builders for the POSIX shell strings used by the skill transfer runner.
//! Names are single-quote-escaped; "$HOME" stays expandable. No I/O here so the
//! quoting/path logic is unit-testable in isolation.
const std = @import("std");

pub fn appendQuoted(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try buf.append(allocator, '\'');
    for (s) |c| {
        if (c == '\'') try buf.appendSlice(allocator, "'\\''") else try buf.append(allocator, c);
    }
    try buf.append(allocator, '\'');
}

/// `tar -czf '<tmp>' -C <root_expr> '<name>'`. root_expr is a caller-built shell
/// expression for the skills root (e.g. `"$HOME"/.claude/skills` or a single-
/// quoted absolute library path). name is the skill dir name.
pub fn tarCreateCmd(allocator: std.mem.Allocator, root_expr: []const u8, name: []const u8, tmp: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "tar -czf ");
    try appendQuoted(&buf, allocator, tmp);
    try buf.appendSlice(allocator, " -C ");
    try buf.appendSlice(allocator, root_expr);
    try buf.append(allocator, ' ');
    try appendQuoted(&buf, allocator, name);
    return buf.toOwnedSlice(allocator);
}

/// Stage-then-swap extract of <tmp> into <root_expr>, atomically replacing
/// <root_expr>/<name>. A failed extract leaves the live skill untouched.
pub fn tarExtractCmd(allocator: std.mem.Allocator, root_expr: []const u8, name: []const u8, tmp: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "D=");
    try buf.appendSlice(allocator, root_expr);
    try buf.appendSlice(allocator, "; mkdir -p \"$D\"; S=\"$D/.wisptmp.$$\"; rm -rf \"$S\"; mkdir -p \"$S\"; ");
    try buf.appendSlice(allocator, "tar -xzf ");
    try appendQuoted(&buf, allocator, tmp);
    try buf.appendSlice(allocator, " -C \"$S\" && rm -rf \"$D\"/");
    try appendQuoted(&buf, allocator, name);
    try buf.appendSlice(allocator, " && mv \"$S\"/");
    try appendQuoted(&buf, allocator, name);
    try buf.appendSlice(allocator, " \"$D\"/");
    try appendQuoted(&buf, allocator, name);
    try buf.appendSlice(allocator, "; rm -rf \"$S\"");
    return buf.toOwnedSlice(allocator);
}

/// `cat <root_expr>/'<name>'/'SKILL.md'` — read one skill's SKILL.md under a
/// shell root expression (e.g. `"$HOME"/'.claude/skills'` or `'/abs/lib'`).
/// root_expr is already shell-ready (built by homeRootExpr/absRootExpr); name
/// and the SKILL.md literal are single-quote-escaped.
pub fn catSkillMdCmd(allocator: std.mem.Allocator, root_expr: []const u8, name: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "cat ");
    try buf.appendSlice(allocator, root_expr);
    try buf.append(allocator, '/');
    try appendQuoted(&buf, allocator, name);
    try buf.append(allocator, '/');
    try appendQuoted(&buf, allocator, "SKILL.md");
    return buf.toOwnedSlice(allocator);
}

/// Shell expression for a target software root under $HOME, e.g.
/// homeRootExpr(".claude/skills") → `"$HOME"/'<rel>'`.
pub fn homeRootExpr(allocator: std.mem.Allocator, rel: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "\"$HOME\"/");
    try appendQuoted(&buf, allocator, rel);
    return buf.toOwnedSlice(allocator);
}

/// Shell expression for an absolute root (the local library), single-quoted.
pub fn absRootExpr(allocator: std.mem.Allocator, abs: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try appendQuoted(&buf, allocator, abs);
    return buf.toOwnedSlice(allocator);
}

/// Staging dir name used by the native (scp -r) transfer path on both ends.
pub const XFER_STAGING = ".wispterm-xfer";

/// `D=<root>; mkdir -p "$D"; rm -rf "$D"/'.wispterm-xfer'; mkdir -p "$D"/'.wispterm-xfer'`
/// — prepare a fresh remote staging dir for an `scp -r` upload.
pub fn remoteStagePrepCmd(allocator: std.mem.Allocator, root_expr: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "D=");
    try buf.appendSlice(allocator, root_expr);
    try buf.appendSlice(allocator, "; mkdir -p \"$D\"; rm -rf \"$D\"/");
    try appendQuoted(&buf, allocator, XFER_STAGING);
    try buf.appendSlice(allocator, "; mkdir -p \"$D\"/");
    try appendQuoted(&buf, allocator, XFER_STAGING);
    return buf.toOwnedSlice(allocator);
}

/// `D=<root>; rm -rf "$D"/'<name>' && mv "$D"/'.wispterm-xfer'/'<name>' "$D"/'<name>' && rm -rf "$D"/'.wispterm-xfer'`
/// — atomically swap the staged skill into place, then remove the staging dir.
/// The whole chain is `&&`-joined so the command's exit status reflects the
/// `mv` (the operation that matters): a failed mv propagates non-zero, letting
/// the caller report failure instead of masking it behind the cleanup `rm`.
pub fn remoteStageSwapCmd(allocator: std.mem.Allocator, root_expr: []const u8, name: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "D=");
    try buf.appendSlice(allocator, root_expr);
    try buf.appendSlice(allocator, "; rm -rf \"$D\"/");
    try appendQuoted(&buf, allocator, name);
    try buf.appendSlice(allocator, " && mv \"$D\"/");
    try appendQuoted(&buf, allocator, XFER_STAGING);
    try buf.append(allocator, '/');
    try appendQuoted(&buf, allocator, name);
    try buf.appendSlice(allocator, " \"$D\"/");
    try appendQuoted(&buf, allocator, name);
    try buf.appendSlice(allocator, " && rm -rf \"$D\"/");
    try appendQuoted(&buf, allocator, XFER_STAGING);
    return buf.toOwnedSlice(allocator);
}

// --- Tests ---

test "skill_transfer_cmd: homeRootExpr + tarCreateCmd for a $HOME target" {
    const a = std.testing.allocator;
    const root = try homeRootExpr(a, ".claude/skills");
    defer a.free(root);
    try std.testing.expectEqualStrings("\"$HOME\"/'.claude/skills'", root);
    const c = try tarCreateCmd(a, root, "pdf", "/tmp/x.tgz");
    defer a.free(c);
    try std.testing.expectEqualStrings("tar -czf '/tmp/x.tgz' -C \"$HOME\"/'.claude/skills' 'pdf'", c);
}

test "skill_transfer_cmd: absRootExpr + tarExtractCmd for the local library" {
    const a = std.testing.allocator;
    const root = try absRootExpr(a, "/cfg/skills");
    defer a.free(root);
    const c = try tarExtractCmd(a, root, "pdf", "/tmp/x.tgz");
    defer a.free(c);
    try std.testing.expect(std.mem.indexOf(u8, c, "D='/cfg/skills'") != null);
    try std.testing.expect(std.mem.indexOf(u8, c, "tar -xzf '/tmp/x.tgz' -C \"$S\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, c, "mv \"$S\"/'pdf' \"$D\"/'pdf'") != null);
}

test "skill_transfer_cmd: catSkillMdCmd reads SKILL.md under a $HOME root" {
    const a = std.testing.allocator;
    const root = try homeRootExpr(a, ".claude/skills");
    defer a.free(root);
    const c = try catSkillMdCmd(a, root, "pdf");
    defer a.free(c);
    try std.testing.expectEqualStrings("cat \"$HOME\"/'.claude/skills'/'pdf'/'SKILL.md'", c);
}

test "skill_transfer_cmd: catSkillMdCmd shell-escapes a tricky name" {
    const a = std.testing.allocator;
    const root = try absRootExpr(a, "/cfg/skills");
    defer a.free(root);
    const c = try catSkillMdCmd(a, root, "it's mine");
    defer a.free(c);
    try std.testing.expectEqualStrings("cat '/cfg/skills'/'it'\\''s mine'/'SKILL.md'", c);
}

test "skill_transfer_cmd: remoteStagePrepCmd makes a fresh staging dir" {
    const a = std.testing.allocator;
    const root = try homeRootExpr(a, ".codex/skills");
    defer a.free(root);
    const c = try remoteStagePrepCmd(a, root);
    defer a.free(c);
    try std.testing.expectEqualStrings(
        "D=\"$HOME\"/'.codex/skills'; mkdir -p \"$D\"; rm -rf \"$D\"/'.wispterm-xfer'; mkdir -p \"$D\"/'.wispterm-xfer'",
        c,
    );
}

test "skill_transfer_cmd: remoteStageSwapCmd swaps staged skill into place" {
    const a = std.testing.allocator;
    const root = try absRootExpr(a, "/cfg/skills");
    defer a.free(root);
    const c = try remoteStageSwapCmd(a, root, "pdf");
    defer a.free(c);
    try std.testing.expectEqualStrings(
        "D='/cfg/skills'; rm -rf \"$D\"/'pdf' && mv \"$D\"/'.wispterm-xfer'/'pdf' \"$D\"/'pdf' && rm -rf \"$D\"/'.wispterm-xfer'",
        c,
    );
}

test "skill_transfer_cmd: remoteStageSwapCmd shell-escapes a tricky name" {
    const a = std.testing.allocator;
    const root = try homeRootExpr(a, ".claude/skills");
    defer a.free(root);
    const c = try remoteStageSwapCmd(a, root, "it's mine");
    defer a.free(c);
    try std.testing.expect(std.mem.indexOf(u8, c, "'it'\\''s mine'") != null);
    try std.testing.expect(std.mem.indexOf(u8, c, "mv \"$D\"/'.wispterm-xfer'/'it'\\''s mine'") != null);
}
