const std = @import("std");
const scan = @import("skill_scan.zig");

pub const Provider = scan.Provider;
pub const SkillRow = scan.SkillRow;

/// One server's scan result, the input to `buildMatrix`. `rows` are borrowed
/// for the duration of the build (the matrix copies what it needs).
pub const ServerScan = struct {
    source_id: []const u8,
    reachable: bool,
    rows: []const SkillRow,
};

pub const CellState = enum { match, differ, absent, unknown };

pub const Cell = struct { state: CellState };

pub const RowKey = struct {
    provider: Provider,
    name: []u8,

    pub fn deinit(self: *RowKey, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub const ServerCol = struct {
    source_id: []u8,
    reachable: bool,

    pub fn deinit(self: *ServerCol, allocator: std.mem.Allocator) void {
        allocator.free(self.source_id);
        self.* = undefined;
    }
};

pub const Matrix = struct {
    allocator: std.mem.Allocator,
    skills: []RowKey, // sorted rows
    servers: []ServerCol, // columns, in input order
    cells: []Cell, // row-major: cells[row * servers.len + col]

    pub fn cellAt(self: *const Matrix, row: usize, col: usize) Cell {
        return self.cells[row * self.servers.len + col];
    }

    pub fn deinit(self: *Matrix) void {
        for (self.skills) |*s| s.deinit(self.allocator);
        self.allocator.free(self.skills);
        for (self.servers) |*c| c.deinit(self.allocator);
        self.allocator.free(self.servers);
        self.allocator.free(self.cells);
        self.* = undefined;
    }
};

fn rowKeyLessThan(_: void, a: RowKey, b: RowKey) bool {
    if (a.provider != b.provider) return @intFromEnum(a.provider) < @intFromEnum(b.provider);
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn sameKey(provider: Provider, name: []const u8, r: SkillRow) bool {
    return r.provider == provider and std.mem.eql(u8, r.name, name);
}

/// Find a server's row for (provider,name); null if absent.
fn findRow(server: ServerScan, provider: Provider, name: []const u8) ?SkillRow {
    for (server.rows) |r| {
        if (sameKey(provider, name, r)) return r;
    }
    return null;
}

/// Modal non-null hash among present servers for one skill; ties broken by the
/// lexicographically smallest hash for determinism. Null if no server has a hash.
fn referenceHash(servers: []const ServerScan, provider: Provider, name: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_count: usize = 0;
    for (servers) |candidate_server| {
        const cand = findRow(candidate_server, provider, name) orelse continue;
        const ch = cand.agg_hash orelse continue;
        var count: usize = 0;
        for (servers) |s| {
            const r = findRow(s, provider, name) orelse continue;
            const h = r.agg_hash orelse continue;
            if (std.mem.eql(u8, h, ch)) count += 1;
        }
        const replace = best == null or count > best_count or
            (count == best_count and std.mem.order(u8, ch, best.?) == .lt);
        if (replace) {
            best = ch;
            best_count = count;
        }
    }
    return best;
}

pub fn buildMatrix(allocator: std.mem.Allocator, servers: []const ServerScan) !Matrix {
    // 1. Union of (provider,name) keys.
    var keys: std.ArrayListUnmanaged(RowKey) = .empty;
    errdefer {
        for (keys.items) |*k| k.deinit(allocator);
        keys.deinit(allocator);
    }
    for (servers) |s| {
        for (s.rows) |r| {
            var seen = false;
            for (keys.items) |k| {
                if (sameKey(k.provider, k.name, r)) {
                    seen = true;
                    break;
                }
            }
            if (seen) continue;
            const name_copy = try allocator.dupe(u8, r.name);
            errdefer allocator.free(name_copy);
            try keys.append(allocator, .{ .provider = r.provider, .name = name_copy });
        }
    }
    std.sort.insertion(RowKey, keys.items, {}, rowKeyLessThan);

    // 2. Columns.
    const cols = try allocator.alloc(ServerCol, servers.len);
    var cols_init: usize = 0;
    errdefer {
        for (cols[0..cols_init]) |*c| c.deinit(allocator);
        allocator.free(cols);
    }
    for (servers, 0..) |s, i| {
        cols[i] = .{ .source_id = try allocator.dupe(u8, s.source_id), .reachable = s.reachable };
        cols_init += 1;
    }

    // 3. Cells.
    const cells = try allocator.alloc(Cell, keys.items.len * servers.len);
    errdefer allocator.free(cells);
    for (keys.items, 0..) |k, ri| {
        const ref = referenceHash(servers, k.provider, k.name);
        for (servers, 0..) |s, ci| {
            const state: CellState = blk: {
                const r = findRow(s, k.provider, k.name) orelse {
                    break :blk if (s.reachable) .absent else .unknown;
                };
                const h = r.agg_hash orelse break :blk .unknown;
                const reference = ref orelse break :blk .unknown;
                break :blk if (std.mem.eql(u8, h, reference)) .match else .differ;
            };
            cells[ri * servers.len + ci] = .{ .state = state };
        }
    }

    const skills = try keys.toOwnedSlice(allocator);
    return .{ .allocator = allocator, .skills = skills, .servers = cols, .cells = cells };
}

// --- Tests ---

fn makeRow(provider: Provider, name: []const u8, hash: ?[]const u8) SkillRow {
    return .{
        .provider = provider,
        .name = @constCast(name),
        .rel_path = @constCast("x"),
        .agg_hash = if (hash) |h| @constCast(h) else null,
    };
}

test "skill_inventory: buildMatrix unions skills and applies cell rule" {
    const allocator = std.testing.allocator;

    const local_rows = [_]SkillRow{
        makeRow(.claude, "pdf", "h1"),
        makeRow(.claude, "brainstorm", "hb"),
    };
    const web_rows = [_]SkillRow{
        makeRow(.claude, "pdf", "h1"), // matches reference
        makeRow(.claude, "brainstorm", "DIFF"), // differs
        makeRow(.claude, "extra", "hx"), // only on web
    };
    const gpu_rows = [_]SkillRow{
        makeRow(.claude, "pdf", null), // present, no hash -> unknown
    };

    const servers = [_]ServerScan{
        .{ .source_id = "local", .reachable = true, .rows = &local_rows },
        .{ .source_id = "web", .reachable = true, .rows = &web_rows },
        .{ .source_id = "gpu", .reachable = true, .rows = &gpu_rows },
        .{ .source_id = "off", .reachable = false, .rows = &.{} },
    };

    var m = try buildMatrix(allocator, &servers);
    defer m.deinit();

    // Rows are the union, sorted: brainstorm, extra, pdf (claude).
    try std.testing.expectEqual(@as(usize, 3), m.skills.len);
    try std.testing.expectEqualStrings("brainstorm", m.skills[0].name);
    try std.testing.expectEqualStrings("extra", m.skills[1].name);
    try std.testing.expectEqualStrings("pdf", m.skills[2].name);
    try std.testing.expectEqual(@as(usize, 4), m.servers.len);

    // pdf row (index 2): local match, web match (h1 is modal), gpu unknown, off unknown.
    try std.testing.expectEqual(CellState.match, m.cellAt(2, 0).state);
    try std.testing.expectEqual(CellState.match, m.cellAt(2, 1).state);
    try std.testing.expectEqual(CellState.unknown, m.cellAt(2, 2).state);
    try std.testing.expectEqual(CellState.unknown, m.cellAt(2, 3).state);

    // brainstorm row (index 0): only local(hb) & web(DIFF) present, single each ->
    // modal tie broken lexicographically: "DIFF" < "hb", so DIFF is reference.
    try std.testing.expectEqual(CellState.differ, m.cellAt(0, 0).state); // local hb != DIFF
    try std.testing.expectEqual(CellState.match, m.cellAt(0, 1).state); // web DIFF == ref
    try std.testing.expectEqual(CellState.absent, m.cellAt(0, 2).state); // gpu reachable, absent
    try std.testing.expectEqual(CellState.unknown, m.cellAt(0, 3).state); // off unreachable

    // extra row (index 1): only on web -> web match, others absent / off unknown.
    try std.testing.expectEqual(CellState.absent, m.cellAt(1, 0).state);
    try std.testing.expectEqual(CellState.match, m.cellAt(1, 1).state);
    try std.testing.expectEqual(CellState.absent, m.cellAt(1, 2).state);
    try std.testing.expectEqual(CellState.unknown, m.cellAt(1, 3).state);
}

test "skill_inventory: uniform row is all match" {
    const allocator = std.testing.allocator;
    const a = [_]SkillRow{makeRow(.codex, "x", "same")};
    const b = [_]SkillRow{makeRow(.codex, "x", "same")};
    const servers = [_]ServerScan{
        .{ .source_id = "a", .reachable = true, .rows = &a },
        .{ .source_id = "b", .reachable = true, .rows = &b },
    };
    var m = try buildMatrix(allocator, &servers);
    defer m.deinit();
    try std.testing.expectEqual(CellState.match, m.cellAt(0, 0).state);
    try std.testing.expectEqual(CellState.match, m.cellAt(0, 1).state);
}

test "skill_inventory: empty servers produces empty matrix" {
    const allocator = std.testing.allocator;
    const servers = [_]ServerScan{};
    var m = try buildMatrix(allocator, &servers);
    defer m.deinit();
    try std.testing.expectEqual(@as(usize, 0), m.skills.len);
    try std.testing.expectEqual(@as(usize, 0), m.servers.len);
    try std.testing.expectEqual(@as(usize, 0), m.cells.len);
}

test "skill_inventory: no-hash-anywhere row is all unknown for reachable" {
    const allocator = std.testing.allocator;
    const a = [_]SkillRow{makeRow(.claude, "nohash", null)};
    const b = [_]SkillRow{makeRow(.claude, "nohash", null)};
    const servers = [_]ServerScan{
        .{ .source_id = "a", .reachable = true, .rows = &a },
        .{ .source_id = "b", .reachable = true, .rows = &b },
    };
    var m = try buildMatrix(allocator, &servers);
    defer m.deinit();
    try std.testing.expectEqual(@as(usize, 1), m.skills.len);
    try std.testing.expectEqual(CellState.unknown, m.cellAt(0, 0).state);
    try std.testing.expectEqual(CellState.unknown, m.cellAt(0, 1).state);
}
