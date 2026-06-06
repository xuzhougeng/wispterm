const std = @import("std");
const scan = @import("skill_scan.zig");
const inv = @import("skill_inventory.zig");
const inv_cache = @import("skill_inventory_cache.zig");

/// Source descriptor for a scan column. `id` is the stable column identity;
/// `name` is the display label.
pub const ScanSource = struct {
    id: []const u8,
    name: []const u8,
};

/// Seam that produces an `ExecHost` for a source (or errors -> unreachable
/// column). The integration layer supplies a real factory; tests use a fake.
pub const HostFactory = struct {
    ctx: *anyopaque,
    make: *const fn (*anyopaque, std.mem.Allocator, ScanSource) anyerror!scan.ExecHost,
};

/// Scan every source and return owned `[]inv.ServerScan` (free with
/// `inv_cache.freeServerScans` then free the slice). A source whose host cannot
/// be created, or whose scan reports unreachable, becomes an unreachable column
/// with no rows.
pub fn runScan(
    allocator: std.mem.Allocator,
    sources: []const ScanSource,
    factory: HostFactory,
) ![]inv.ServerScan {
    var out = try allocator.alloc(inv.ServerScan, sources.len);
    var built: usize = 0;
    errdefer {
        inv_cache.freeServerScans(allocator, out[0..built]);
        allocator.free(out);
    }

    for (sources, 0..) |src, i| {
        const id_copy = try allocator.dupe(u8, src.id);
        errdefer allocator.free(id_copy);

        const host = factory.make(factory.ctx, allocator, src) catch {
            out[i] = .{ .source_id = id_copy, .reachable = false, .rows = &.{} };
            built += 1;
            continue;
        };

        var outcome = scan.scanSource(allocator, scan.defaultTargets(), host) catch {
            out[i] = .{ .source_id = id_copy, .reachable = false, .rows = &.{} };
            built += 1;
            continue;
        };
        out[i] = .{ .source_id = id_copy, .reachable = outcome.reachable, .rows = outcome.rows };
        outcome.rows = &.{}; // ownership moved into the ServerScan
        built += 1;
    }

    return out;
}

/// Build a command that prints one skill's SKILL.md / prompt file from a
/// server, given its `rel_path` (relative to $HOME, as produced by the scan).
pub fn previewCommand(allocator: std.mem.Allocator, rel_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "cat \"$HOME/{s}\"", .{rel_path});
}

// --- Tests ---

const ScriptHost = struct {
    fn make(_: *anyopaque, _: std.mem.Allocator, src: ScanSource) anyerror!scan.ExecHost {
        if (std.mem.eql(u8, src.id, "off")) return error.Unreachable;
        return .{ .ctx = @constCast(@ptrCast(src.id.ptr)), .exec = exec };
    }
    fn exec(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8) anyerror![]u8 {
        const id_ptr: [*]const u8 = @ptrCast(ctx);
        const id = id_ptr[0..5]; // "local" / "webxx"
        if (std.mem.startsWith(u8, id, "local")) {
            return allocator.dupe(u8, "claude\tpdf\t.claude/skills/pdf/SKILL.md\th1\n");
        }
        return allocator.dupe(u8, "claude\tpdf\t.claude/skills/pdf/SKILL.md\tDIFF\n");
    }
};

test "skill_center: runScan over sources builds a matrix" {
    const allocator = std.testing.allocator;
    const sources = [_]ScanSource{
        .{ .id = "local", .name = "Local" },
        .{ .id = "webxx", .name = "web" },
        .{ .id = "off", .name = "offline" },
    };
    var dummy: u8 = 0;
    const factory = HostFactory{ .ctx = &dummy, .make = ScriptHost.make };

    const servers = try runScan(allocator, &sources, factory);
    defer {
        inv_cache.freeServerScans(allocator, servers);
        allocator.free(servers);
    }

    try std.testing.expectEqual(@as(usize, 3), servers.len);
    try std.testing.expect(!servers[2].reachable); // off

    var m = try inv.buildMatrix(allocator, servers);
    defer m.deinit();
    try std.testing.expectEqual(@as(usize, 1), m.skills.len); // pdf
    try std.testing.expectEqual(inv.CellState.differ, m.cellAt(0, 0).state); // local h1 != ref(DIFF)
    try std.testing.expectEqual(inv.CellState.match, m.cellAt(0, 1).state); // web DIFF == ref
    try std.testing.expectEqual(inv.CellState.unknown, m.cellAt(0, 2).state); // off
}

/// Panel state for the Skill Center UI: owns the current scan results + matrix,
/// the focused cell, scroll offset, a status string, and a stale flag. The
/// background scan worker (integration layer) calls `setServers` to swap in new
/// results; `seedFromCache` loads the last persisted scan for instant display.
pub const PanelModel = struct {
    allocator: std.mem.Allocator,
    servers: []inv.ServerScan = &.{},
    matrix: ?inv.Matrix = null,
    sel_row: usize = 0,
    sel_col: usize = 0,
    scroll: usize = 0,
    stale: bool = false,

    pub fn init(allocator: std.mem.Allocator) PanelModel {
        return .{ .allocator = allocator };
    }

    /// Seed from the persisted cache so the panel renders immediately; mark stale.
    pub fn seedFromCache(self: *PanelModel) void {
        const cached = inv_cache.load(self.allocator) catch return;
        if (cached.len == 0) {
            self.allocator.free(cached);
            return;
        }
        self.setServers(cached);
        self.stale = true;
    }

    /// Take ownership of a fresh `[]inv.ServerScan`, rebuild the matrix, clear stale.
    pub fn setServers(self: *PanelModel, servers: []inv.ServerScan) void {
        self.freeServers();
        self.servers = servers;
        if (self.matrix) |*m| m.deinit();
        self.matrix = inv.buildMatrix(self.allocator, servers) catch null;
        self.stale = false;
        self.clampSelection();
    }

    fn clampSelection(self: *PanelModel) void {
        const m = self.matrix orelse return;
        if (m.skills.len == 0) {
            self.sel_row = 0;
        } else if (self.sel_row >= m.skills.len) {
            self.sel_row = m.skills.len - 1;
        }
        if (m.servers.len == 0) {
            self.sel_col = 0;
        } else if (self.sel_col >= m.servers.len) {
            self.sel_col = m.servers.len - 1;
        }
    }

    fn freeServers(self: *PanelModel) void {
        if (self.servers.len != 0) {
            inv_cache.freeServerScans(self.allocator, self.servers);
            self.allocator.free(self.servers);
            self.servers = &.{};
        }
    }

    pub fn deinit(self: *PanelModel) void {
        if (self.matrix) |*m| m.deinit();
        self.freeServers();
        self.* = undefined;
    }
};

test "skill_center: previewCommand cats the rel path under HOME" {
    const allocator = std.testing.allocator;
    const cmd = try previewCommand(allocator, ".claude/skills/pdf/SKILL.md");
    defer allocator.free(cmd);
    try std.testing.expectEqualStrings("cat \"$HOME/.claude/skills/pdf/SKILL.md\"", cmd);
}

test "skill_center: PanelModel setServers rebuilds matrix and clamps selection" {
    const allocator = std.testing.allocator;
    var model = PanelModel.init(allocator);
    defer model.deinit();

    // First scan: 2 skills.
    const rows1 = [_]scan.SkillRow{
        .{ .provider = .claude, .name = @constCast("a"), .rel_path = @constCast(".claude/skills/a/SKILL.md"), .agg_hash = @constCast("h") },
        .{ .provider = .claude, .name = @constCast("b"), .rel_path = @constCast(".claude/skills/b/SKILL.md"), .agg_hash = @constCast("h") },
    };
    const s1 = try allocator.alloc(inv.ServerScan, 1);
    s1[0] = .{ .source_id = try allocator.dupe(u8, "local"), .reachable = true, .rows = try dupRows(allocator, &rows1) };
    model.setServers(s1);
    model.sel_row = 1; // select the 2nd skill

    try std.testing.expect(model.matrix != null);
    try std.testing.expectEqual(@as(usize, 2), model.matrix.?.skills.len);

    // Replace with a scan that has only 1 skill -> selection must clamp to 0.
    const rows2 = [_]scan.SkillRow{
        .{ .provider = .claude, .name = @constCast("a"), .rel_path = @constCast(".claude/skills/a/SKILL.md"), .agg_hash = @constCast("h") },
    };
    const s2 = try allocator.alloc(inv.ServerScan, 1);
    s2[0] = .{ .source_id = try allocator.dupe(u8, "local"), .reachable = true, .rows = try dupRows(allocator, &rows2) };
    model.setServers(s2);

    try std.testing.expectEqual(@as(usize, 1), model.matrix.?.skills.len);
    try std.testing.expectEqual(@as(usize, 0), model.sel_row); // clamped
}

// Helper: deep-dupe borrowed rows into owned rows the model/cache can free.
fn dupRows(allocator: std.mem.Allocator, src: []const scan.SkillRow) ![]scan.SkillRow {
    const out = try allocator.alloc(scan.SkillRow, src.len);
    for (src, 0..) |r, i| {
        out[i] = .{
            .provider = r.provider,
            .name = try allocator.dupe(u8, r.name),
            .rel_path = try allocator.dupe(u8, r.rel_path),
            .agg_hash = if (r.agg_hash) |h| try allocator.dupe(u8, h) else null,
        };
    }
    return out;
}
