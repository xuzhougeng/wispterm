const std = @import("std");
const scan = @import("skill_scan.zig");
const inv = @import("skill_inventory.zig");

pub const Provider = scan.Provider;
pub const ServerScan = inv.ServerScan;

/// Relation of a single skill between the local hub and one selected server.
pub const Relation = enum {
    same, // present both sides, agg_hash equal
    differ, // present both sides, both hashable, agg_hash differ
    local_only, // present locally, server reachable and absent there
    remote_only, // absent locally, present on the server
    unknown, // present but a side has null hash, or the server is unreachable
};

/// One aligned row. All slices borrow from the input ServerScans — `pair()`
/// returns an owned *slice* but owns none of the strings; free with
/// `allocator.free(rows)` only (no per-element deinit).
pub const PairRow = struct {
    provider: Provider,
    name: []const u8,
    local_rel_path: ?[]const u8,
    remote_rel_path: ?[]const u8,
    relation: Relation,
};

fn lessThan(_: void, a: PairRow, b: PairRow) bool {
    if (a.provider != b.provider) return @intFromEnum(a.provider) < @intFromEnum(b.provider);
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn findRow(s: ServerScan, provider: Provider, name: []const u8) ?scan.SkillRow {
    for (s.rows) |r| {
        if (r.provider == provider and std.mem.eql(u8, r.name, name)) return r;
    }
    return null;
}

fn alreadySeen(rows: []const PairRow, provider: Provider, name: []const u8) bool {
    for (rows) |p| {
        if (p.provider == provider and std.mem.eql(u8, p.name, name)) return true;
    }
    return false;
}

/// Align `local` against `remote` into a sorted, deduped list of PairRow.
/// `remote_reachable` false (server offline) makes every row that exists
/// locally `unknown` on the remote side — "we couldn't check", never a false
/// `local_only`. Caller frees the returned slice with `allocator.free`.
pub fn pair(
    allocator: std.mem.Allocator,
    local: ServerScan,
    remote: ServerScan,
    remote_reachable: bool,
) ![]PairRow {
    var out: std.ArrayListUnmanaged(PairRow) = .empty;
    errdefer out.deinit(allocator);

    // Local skills first (the hub is the primary axis).
    for (local.rows) |lr| {
        if (alreadySeen(out.items, lr.provider, lr.name)) continue;
        const rr: ?scan.SkillRow = if (remote_reachable) findRow(remote, lr.provider, lr.name) else null;
        const relation: Relation = blk: {
            if (!remote_reachable) break :blk .unknown;
            const remote_row = rr orelse break :blk .local_only;
            const lh = lr.agg_hash orelse break :blk .unknown;
            const rh = remote_row.agg_hash orelse break :blk .unknown;
            break :blk if (std.mem.eql(u8, lh, rh)) .same else .differ;
        };
        try out.append(allocator, .{
            .provider = lr.provider,
            .name = lr.name,
            .local_rel_path = lr.rel_path,
            .remote_rel_path = if (rr) |r| r.rel_path else null,
            .relation = relation,
        });
    }

    // Remote-only skills (present on the server, absent locally).
    if (remote_reachable) {
        for (remote.rows) |rr| {
            if (alreadySeen(out.items, rr.provider, rr.name)) continue;
            if (findRow(local, rr.provider, rr.name) != null) continue;
            try out.append(allocator, .{
                .provider = rr.provider,
                .name = rr.name,
                .local_rel_path = null,
                .remote_rel_path = rr.rel_path,
                .relation = .remote_only,
            });
        }
    }

    const rows = try out.toOwnedSlice(allocator);
    std.sort.insertion(PairRow, rows, {}, lessThan);
    return rows;
}

// --- Tests ---

fn row(provider: Provider, name: []const u8, hash: ?[]const u8) scan.SkillRow {
    return .{
        .provider = provider,
        .name = @constCast(name),
        .rel_path = @constCast("x"),
        .agg_hash = if (hash) |h| @constCast(h) else null,
    };
}

test "skill_pairing: relations across both sides" {
    const allocator = std.testing.allocator;
    const local_rows = [_]scan.SkillRow{
        row(.claude, "same1", "h"),
        row(.claude, "diff1", "L"),
        row(.claude, "localonly", "h"),
        row(.claude, "noremotehash", "h"),
    };
    const remote_rows = [_]scan.SkillRow{
        row(.claude, "same1", "h"), // same
        row(.claude, "diff1", "R"), // differ
        row(.claude, "remoteonly", "h"), // remote_only
        row(.claude, "noremotehash", null), // unknown (remote null hash)
    };
    const local: ServerScan = .{ .source_id = "local", .reachable = true, .rows = &local_rows };
    const remote: ServerScan = .{ .source_id = "ssh:web", .reachable = true, .rows = &remote_rows };

    const rows = try pair(allocator, local, remote, true);
    defer allocator.free(rows);

    // Sorted by name within provider: diff1, localonly, noremotehash, remoteonly, same1
    try std.testing.expectEqual(@as(usize, 5), rows.len);
    try std.testing.expectEqualStrings("diff1", rows[0].name);
    try std.testing.expectEqual(Relation.differ, rows[0].relation);
    try std.testing.expectEqual(Relation.local_only, rows[1].relation); // localonly
    try std.testing.expectEqual(Relation.unknown, rows[2].relation); // noremotehash
    try std.testing.expectEqual(Relation.remote_only, rows[3].relation); // remoteonly
    try std.testing.expectEqual(Relation.same, rows[4].relation); // same1
}

test "skill_pairing: unreachable remote makes every local row unknown" {
    const allocator = std.testing.allocator;
    const local_rows = [_]scan.SkillRow{ row(.claude, "a", "h"), row(.codex, "b", "h") };
    const local: ServerScan = .{ .source_id = "local", .reachable = true, .rows = &local_rows };
    const remote: ServerScan = .{ .source_id = "ssh:off", .reachable = false, .rows = &.{} };

    const rows = try pair(allocator, local, remote, false);
    defer allocator.free(rows);

    try std.testing.expectEqual(@as(usize, 2), rows.len);
    for (rows) |r| try std.testing.expectEqual(Relation.unknown, r.relation);
}

test "skill_pairing: empty local with reachable remote yields remote_only" {
    const allocator = std.testing.allocator;
    const remote_rows = [_]scan.SkillRow{row(.claude, "x", "h")};
    const local: ServerScan = .{ .source_id = "local", .reachable = true, .rows = &.{} };
    const remote: ServerScan = .{ .source_id = "ssh:web", .reachable = true, .rows = &remote_rows };

    const rows = try pair(allocator, local, remote, true);
    defer allocator.free(rows);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqual(Relation.remote_only, rows[0].relation);
}
