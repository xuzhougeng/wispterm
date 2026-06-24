const std = @import("std");

pub const UiEffect = struct {
    consumed: bool = false,
    needs_rebuild: bool = false,
    cells_invalid: bool = false,
    wake_backend: bool = false,

    pub const none: UiEffect = .{};
    pub const consumed_only: UiEffect = .{ .consumed = true };
    pub const repaint: UiEffect = .{
        .consumed = true,
        .needs_rebuild = true,
        .cells_invalid = true,
    };

    pub fn merge(self: UiEffect, other: UiEffect) UiEffect {
        return .{
            .consumed = self.consumed or other.consumed,
            .needs_rebuild = self.needs_rebuild or other.needs_rebuild,
            .cells_invalid = self.cells_invalid or other.cells_invalid,
            .wake_backend = self.wake_backend or other.wake_backend,
        };
    }
};

test "ui effect repaint requests consumed rebuild and cell invalidation" {
    const effect = UiEffect.repaint;
    try std.testing.expect(effect.consumed);
    try std.testing.expect(effect.needs_rebuild);
    try std.testing.expect(effect.cells_invalid);
    try std.testing.expect(!effect.wake_backend);
}

test "ui effect merge keeps every requested flag" {
    const merged = UiEffect.consumed_only.merge(.{
        .needs_rebuild = true,
        .wake_backend = true,
    });

    try std.testing.expect(merged.consumed);
    try std.testing.expect(merged.needs_rebuild);
    try std.testing.expect(!merged.cells_invalid);
    try std.testing.expect(merged.wake_backend);
}
