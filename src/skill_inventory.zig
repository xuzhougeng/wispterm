const std = @import("std");
const scan = @import("skill_scan.zig");

pub const Provider = scan.Provider;
pub const SkillRow = scan.SkillRow;

/// One server's scan result: the unit stored by the cache and compared by
/// `skill_pairing`. `rows` are borrowed by consumers (no ownership transfer).
pub const ServerScan = struct {
    source_id: []const u8,
    reachable: bool,
    rows: []const SkillRow,
};
