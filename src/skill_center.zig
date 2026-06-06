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
