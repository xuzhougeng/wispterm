//! Reasoning levels a session may switch between without editing a profile.
//! Runtime-only: Magpie's model facts fill the list, and it is never written
//! to `ai_profiles` or `magpie.json`.
const std = @import("std");

/// Longest level a session can hold (`Session.reasoning_effort_buf`).
pub const LEVEL_MAX = 16;
pub const MAX_LEVELS = 8;

pub const EffortLevels = struct {
    bufs: [MAX_LEVELS][LEVEL_MAX]u8 = undefined,
    lens: [MAX_LEVELS]usize = @splat(0),
    count: usize = 0,

    /// Add `level` once. Duplicates, empty levels, levels a session cannot
    /// hold, and levels past `MAX_LEVELS` are ignored.
    pub fn append(self: *EffortLevels, level: []const u8) void {
        if (level.len == 0 or level.len > LEVEL_MAX) return;
        if (self.count == MAX_LEVELS or self.contains(level)) return;
        @memcpy(self.bufs[self.count][0..level.len], level);
        self.lens[self.count] = level.len;
        self.count += 1;
    }

    pub fn at(self: *const EffortLevels, index: usize) []const u8 {
        return self.bufs[index][0..self.lens[index]];
    }

    pub fn contains(self: *const EffortLevels, level: []const u8) bool {
        for (0..self.count) |i| if (std.mem.eql(u8, self.at(i), level)) return true;
        return false;
    }

    /// The level after `current`, wrapping around; the first level when
    /// `current` is not listed. Null when there is nothing to choose.
    pub fn next(self: *const EffortLevels, current: []const u8) ?[]const u8 {
        if (self.count == 0) return null;
        for (0..self.count) |i| {
            if (std.mem.eql(u8, self.at(i), current)) return self.at((i + 1) % self.count);
        }
        return self.at(0);
    }

    /// "low, medium, high" for transcript messages.
    pub fn join(self: *const EffortLevels, buf: []u8) []const u8 {
        var len: usize = 0;
        for (0..self.count) |i| {
            const sep: []const u8 = if (i == 0) "" else ", ";
            const part = std.fmt.bufPrint(buf[len..], "{s}{s}", .{ sep, self.at(i) }) catch break;
            len += part.len;
        }
        return buf[0..len];
    }
};

test "effort levels keep model order and ignore duplicates or oversized levels" {
    var levels: EffortLevels = .{};
    for ([_][]const u8{ "low", "medium", "", "low", "high", "a-level-longer-than-16" }) |level| levels.append(level);
    try std.testing.expectEqual(@as(usize, 3), levels.count);
    try std.testing.expectEqualStrings("medium", levels.at(1));
    try std.testing.expect(levels.contains("high"));
    try std.testing.expect(!levels.contains("max"));
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("low, medium, high", levels.join(&buf));
}

test "effort levels cycle from the current level and restart from an unlisted one" {
    var levels: EffortLevels = .{};
    try std.testing.expect(levels.next("medium") == null);
    levels.append("low");
    levels.append("medium");
    levels.append("high");
    try std.testing.expectEqualStrings("high", levels.next("medium").?);
    try std.testing.expectEqualStrings("low", levels.next("high").?);
    try std.testing.expectEqualStrings("low", levels.next("auto").?);
}

test "effort levels stop at the fixed capacity" {
    var levels: EffortLevels = .{};
    for (0..MAX_LEVELS + 2) |i| {
        var name: [8]u8 = undefined;
        levels.append(std.fmt.bufPrint(&name, "l{d}", .{i}) catch unreachable);
    }
    try std.testing.expectEqual(@as(usize, MAX_LEVELS), levels.count);
}
