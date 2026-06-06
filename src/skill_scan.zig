const std = @import("std");

pub const Provider = enum {
    claude,
    codex,

    pub fn toString(self: Provider) []const u8 {
        return switch (self) {
            .claude => "claude",
            .codex => "codex",
        };
    }

    pub fn fromString(s: []const u8) ?Provider {
        if (std.mem.eql(u8, s, "claude")) return .claude;
        if (std.mem.eql(u8, s, "codex")) return .codex;
        return null;
    }
};

pub const Format = enum { skill_md, prompt_md };

/// A directory on each server to scan. `root_rel` is relative to `$HOME`.
pub const ScanTarget = struct {
    provider: Provider,
    root_rel: []const u8,
    format: Format,
};

/// v1 default scan targets. Roots that don't exist on a server are skipped.
pub fn defaultTargets() []const ScanTarget {
    return &[_]ScanTarget{
        .{ .provider = .claude, .root_rel = ".claude/skills", .format = .skill_md },
        .{ .provider = .codex, .root_rel = ".codex/skills", .format = .skill_md },
        .{ .provider = .codex, .root_rel = ".codex/prompts", .format = .prompt_md },
    };
}

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

/// Parse the tab-separated scan output into owned rows. Each valid line is
/// `provider\tname\trel_path\thash`. Lines that are blank, have fewer than 4
/// fields, have an empty name, or an unknown provider are skipped. An empty
/// hash field yields `agg_hash = null`.
pub fn parseScanOutput(allocator: std.mem.Allocator, bytes: []const u8) ![]SkillRow {
    var rows: std.ArrayListUnmanaged(SkillRow) = .empty;
    errdefer {
        for (rows.items) |*r| r.deinit(allocator);
        rows.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        if (line.len == 0) continue;

        var fields = std.mem.splitScalar(u8, line, '\t');
        const prov_str = fields.next() orelse continue;
        const name = fields.next() orelse continue;
        const rel_path = fields.next() orelse continue;
        const hash = fields.next() orelse continue;

        const provider = Provider.fromString(prov_str) orelse continue;
        if (name.len == 0 or rel_path.len == 0) continue;

        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        const rel_copy = try allocator.dupe(u8, rel_path);
        errdefer allocator.free(rel_copy);
        const hash_copy: ?[]u8 = if (hash.len == 0) null else try allocator.dupe(u8, hash);
        errdefer if (hash_copy) |h| allocator.free(h);

        try rows.append(allocator, .{
            .provider = provider,
            .name = name_copy,
            .rel_path = rel_copy,
            .agg_hash = hash_copy,
        });
    }

    return rows.toOwnedSlice(allocator);
}

test "skill_scan: parseScanOutput parses good rows and skips garbage" {
    const allocator = std.testing.allocator;
    const out =
        "claude\tpdf-tools\t.claude/skills/pdf-tools/SKILL.md\tabc123\n" ++
        "codex\tfoo\t.codex/prompts/foo.md\t\n" ++ // empty hash -> null
        "\n" ++ // blank line skipped
        "garbage-without-tabs\n" ++ // skipped
        "bogusprov\tx\t.x/x\thash\n"; // unknown provider skipped

    const rows = try parseScanOutput(allocator, out);
    defer freeRows(allocator, rows);

    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqual(Provider.claude, rows[0].provider);
    try std.testing.expectEqualStrings("pdf-tools", rows[0].name);
    try std.testing.expectEqualStrings(".claude/skills/pdf-tools/SKILL.md", rows[0].rel_path);
    try std.testing.expectEqualStrings("abc123", rows[0].agg_hash.?);
    try std.testing.expectEqual(Provider.codex, rows[1].provider);
    try std.testing.expectEqualStrings("foo", rows[1].name);
    try std.testing.expectEqual(@as(?[]u8, null), rows[1].agg_hash);
}

const hash_probe =
    \\HASHCMD="";
    \\if command -v sha256sum >/dev/null 2>&1; then HASHCMD="sha256sum";
    \\elif command -v shasum >/dev/null 2>&1; then HASHCMD="shasum -a 256"; fi;
    \\
;

/// Build a single POSIX-shell command that discovers skills under every target
/// root (relative to $HOME) and prints one `provider\tname\trel_path\thash`
/// line per skill. Missing roots are skipped; when no hash tool exists the hash
/// field is empty. Caller frees.
pub fn buildScanCommand(allocator: std.mem.Allocator, targets: []const ScanTarget) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, hash_probe);

    for (targets) |t| {
        const prov = t.provider.toString();
        switch (t.format) {
            .skill_md => {
                const block = try std.fmt.allocPrint(allocator,
                    \\R="$HOME/{s}";
                    \\if [ -d "$R" ]; then for d in "$R"/*/; do
                    \\[ -f "${{d}}SKILL.md" ] || continue;
                    \\n=$(basename "$d");
                    \\if [ -n "$HASHCMD" ]; then h=$(cd "$d" && find . -type f | LC_ALL=C sort | xargs $HASHCMD | $HASHCMD | cut -d' ' -f1); else h=""; fi;
                    \\printf '{s}\t%s\t{s}/%s/SKILL.md\t%s\n' "$n" "$n" "$h";
                    \\done; fi;
                    \\
                , .{ t.root_rel, prov, t.root_rel });
                defer allocator.free(block);
                try buf.appendSlice(allocator, block);
            },
            .prompt_md => {
                const block = try std.fmt.allocPrint(allocator,
                    \\R="$HOME/{s}";
                    \\if [ -d "$R" ]; then for f in "$R"/*.md; do
                    \\[ -f "$f" ] || continue;
                    \\n=$(basename "$f" .md);
                    \\if [ -n "$HASHCMD" ]; then h=$($HASHCMD "$f" | cut -d' ' -f1); else h=""; fi;
                    \\printf '{s}\t%s\t{s}/%s.md\t%s\n' "$n" "$n" "$h";
                    \\done; fi;
                    \\
                , .{ t.root_rel, prov, t.root_rel });
                defer allocator.free(block);
                try buf.appendSlice(allocator, block);
            },
        }
    }

    return buf.toOwnedSlice(allocator);
}

test "skill_scan: buildScanCommand probes hash tool and covers all targets" {
    const allocator = std.testing.allocator;
    const cmd = try buildScanCommand(allocator, defaultTargets());
    defer allocator.free(cmd);

    try std.testing.expect(std.mem.indexOf(u8, cmd, "sha256sum") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "shasum -a 256") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "$HOME/.claude/skills") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "$HOME/.codex/skills") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "$HOME/.codex/prompts") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "SKILL.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, ".codex/prompts/%s.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "printf 'claude\\t") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "printf 'codex\\t") != null);
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

/// Run the scan command on one host and parse the result. An exec error
/// (offline / auth failure) yields `{ reachable = false, rows = &.{} }` rather
/// than propagating — one bad server must not abort the whole inventory.
pub fn scanSource(allocator: std.mem.Allocator, targets: []const ScanTarget, host: ExecHost) !ScanOutcome {
    const cmd = try buildScanCommand(allocator, targets);
    defer allocator.free(cmd);

    const out = host.exec(host.ctx, allocator, cmd) catch {
        return .{ .reachable = false, .rows = &.{} };
    };
    defer allocator.free(out);

    const rows = try parseScanOutput(allocator, out);
    return .{ .reachable = true, .rows = rows };
}

const FakeHost = struct {
    output: ?[]const u8, // null => simulate exec failure (offline)
    fn exec(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8) anyerror![]u8 {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        const out = self.output orelse return error.RemoteExecFailed;
        return allocator.dupe(u8, out);
    }
    fn host(self: *FakeHost) ExecHost {
        return .{ .ctx = self, .exec = exec };
    }
};

test "skill_scan: scanSource parses reachable output" {
    const allocator = std.testing.allocator;
    var fake = FakeHost{ .output = "claude\tpdf\t.claude/skills/pdf/SKILL.md\thh\n" };
    var outcome = try scanSource(allocator, defaultTargets(), fake.host());
    defer outcome.deinit(allocator);

    try std.testing.expect(outcome.reachable);
    try std.testing.expectEqual(@as(usize, 1), outcome.rows.len);
    try std.testing.expectEqualStrings("pdf", outcome.rows[0].name);
}

test "skill_scan: scanSource marks offline host unreachable" {
    const allocator = std.testing.allocator;
    var fake = FakeHost{ .output = null };
    var outcome = try scanSource(allocator, defaultTargets(), fake.host());
    defer outcome.deinit(allocator);

    try std.testing.expect(!outcome.reachable);
    try std.testing.expectEqual(@as(usize, 0), outcome.rows.len);
}

test "skill_scan: parseScanOutput returns empty slice on empty input" {
    const rows = try parseScanOutput(std.testing.allocator, "");
    defer freeRows(std.testing.allocator, rows);
    try std.testing.expectEqual(@as(usize, 0), rows.len);
}

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
