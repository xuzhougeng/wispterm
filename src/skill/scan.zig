const std = @import("std");

pub const Provider = enum {
    claude,
    codex,
};

/// One skill discovered on one server. `agg_hash == null` means the server
/// could not hash (no sha256sum/shasum) — presence is known, version is not.
pub const SkillRow = struct {
    provider: Provider,
    name: []u8,
    rel_path: []u8,
    agg_hash: ?[]u8,

    pub fn deinit(self: *SkillRow, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.rel_path);
        if (self.agg_hash) |h| allocator.free(h);
        self.* = undefined;
    }
};

pub fn freeRows(allocator: std.mem.Allocator, rows: []SkillRow) void {
    for (rows) |*r| r.deinit(allocator);
    allocator.free(rows);
}

/// Structurally identical to `ai_history_session.RemoteExecHost`; defined here
/// so this pure leaf does not import the large session module. The integration
/// layer adapts the real local/WSL/SSH exec functions into this shape.
pub const ExecFn = *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror![]u8;
pub const ExecHost = struct {
    ctx: *anyopaque,
    exec: ExecFn,
};

pub const ScanOutcome = struct {
    reachable: bool,
    rows: []SkillRow,

    pub fn deinit(self: *ScanOutcome, allocator: std.mem.Allocator) void {
        freeRows(allocator, self.rows);
        self.* = undefined;
    }
};

/// Build a command that lists+hashes skill dirs directly under `root_expr`,
/// printing `name \t <name>/SKILL.md \t hash` per skill. Same hash recipe as the
/// skill_md target block, so a library skill and a target skill with identical
/// content hash equal. Missing root prints nothing.
pub fn buildLocationScanCommand(allocator: std.mem.Allocator, root_expr: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\HASHCMD="";
        \\if command -v sha256sum >/dev/null 2>&1; then HASHCMD="sha256sum";
        \\elif command -v shasum >/dev/null 2>&1; then HASHCMD="shasum -a 256"; fi;
        \\R={s};
        \\if [ -d "$R" ]; then for d in "$R"/*/; do
        \\[ -f "${{d}}SKILL.md" ] || continue;
        \\n=$(basename "$d");
        \\if [ -n "$HASHCMD" ]; then h=$(cd "$d" && find . -type f | LC_ALL=C sort | xargs $HASHCMD | $HASHCMD | cut -d' ' -f1); else h=""; fi;
        \\printf '%s\t%s/SKILL.md\t%s\n' "$n" "$n" "$h";
        \\done; fi;
        \\
    , .{root_expr});
}

/// Parse `name \t rel \t hash` lines into rows (provider forced to .claude — v2
/// keys by name; provider is unused). Blank/short lines skipped; empty hash → null.
pub fn parseLocationOutput(allocator: std.mem.Allocator, bytes: []const u8) ![]SkillRow {
    var rows: std.ArrayListUnmanaged(SkillRow) = .empty;
    errdefer {
        for (rows.items) |*r| r.deinit(allocator);
        rows.deinit(allocator);
    }
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        if (line.len == 0) continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        const name = f.next() orelse continue;
        const rel = f.next() orelse continue;
        const hash = f.next() orelse continue;
        if (name.len == 0 or rel.len == 0) continue;
        const name_c = try allocator.dupe(u8, name);
        errdefer allocator.free(name_c);
        const rel_c = try allocator.dupe(u8, rel);
        errdefer allocator.free(rel_c);
        const hash_c: ?[]u8 = if (hash.len == 0) null else try allocator.dupe(u8, hash);
        errdefer if (hash_c) |h| allocator.free(h);
        try rows.append(allocator, .{ .provider = .claude, .name = name_c, .rel_path = rel_c, .agg_hash = hash_c });
    }
    return rows.toOwnedSlice(allocator);
}

/// Run the location scan on a host. exec error → reachable=false.
pub fn scanLocation(allocator: std.mem.Allocator, root_expr: []const u8, host: ExecHost) !ScanOutcome {
    const command = try buildLocationScanCommand(allocator, root_expr);
    defer allocator.free(command);
    const out = host.exec(host.ctx, allocator, command) catch return .{ .reachable = false, .rows = &.{} };
    defer allocator.free(out);
    const rows = try parseLocationOutput(allocator, out);
    return .{ .reachable = true, .rows = rows };
}

const HostFixture = struct {
    output: ?[]const u8,

    fn exec(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8) anyerror![]u8 {
        const self: *HostFixture = @ptrCast(@alignCast(ctx));
        const out = self.output orelse return error.RemoteExecFailed;
        return allocator.dupe(u8, out);
    }

    fn host(self: *HostFixture) ExecHost {
        return .{ .ctx = self, .exec = exec };
    }
};

test "skill_scan: buildLocationScanCommand roots at the expression" {
    const a = std.testing.allocator;
    const cmd = try buildLocationScanCommand(a, "'/cfg/skills'");
    defer a.free(cmd);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "R='/cfg/skills';") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "SKILL.md") != null);
}

test "skill_scan: parseLocationOutput parses name/rel/hash" {
    const a = std.testing.allocator;
    const rows = try parseLocationOutput(a, "pdf\tpdf/SKILL.md\tabc\n\ngarbage\nfoo\tfoo/SKILL.md\t\n");
    defer freeRows(a, rows);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("pdf", rows[0].name);
    try std.testing.expectEqualStrings("abc", rows[0].agg_hash.?);
    try std.testing.expectEqual(@as(?[]u8, null), rows[1].agg_hash);
}

test "skill_scan: scanLocation parses reachable output" {
    const a = std.testing.allocator;
    var fake = HostFixture{ .output = "pdf\tpdf/SKILL.md\thh\n" };
    var outcome = try scanLocation(a, "'/cfg/skills'", fake.host());
    defer outcome.deinit(a);

    try std.testing.expect(outcome.reachable);
    try std.testing.expectEqual(@as(usize, 1), outcome.rows.len);
    try std.testing.expectEqualStrings("pdf", outcome.rows[0].name);
}

test "skill_scan: scanLocation marks offline host unreachable" {
    const a = std.testing.allocator;
    var fake = HostFixture{ .output = null };
    var outcome = try scanLocation(a, "'/cfg/skills'", fake.host());
    defer outcome.deinit(a);

    try std.testing.expect(!outcome.reachable);
    try std.testing.expectEqual(@as(usize, 0), outcome.rows.len);
}
