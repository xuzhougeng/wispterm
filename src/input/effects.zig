const std = @import("std");
const ui_effect = @import("../appwindow/ui_effect.zig");

pub const UiEffect = ui_effect.UiEffect;

pub const rebuild_only: UiEffect = .{
    .consumed = true,
    .needs_rebuild = true,
    .cells_invalid = false,
};

pub inline fn repaint() UiEffect {
    return UiEffect.repaint;
}

pub inline fn rebuildOnly() UiEffect {
    return rebuild_only;
}

pub inline fn consumedOnly() UiEffect {
    return UiEffect.consumed_only;
}

pub inline fn repaintIf(changed: bool) UiEffect {
    return if (changed) repaint() else UiEffect.none;
}

pub inline fn rebuildIf(changed: bool) UiEffect {
    return if (changed) rebuildOnly() else UiEffect.none;
}

pub inline fn mergeRepaint(effect: UiEffect, changed: bool) UiEffect {
    return if (changed) effect.merge(repaint()) else effect;
}

pub inline fn mergeRebuild(effect: UiEffect, changed: bool) UiEffect {
    return if (changed) effect.merge(rebuildOnly()) else effect;
}

pub inline fn fromDirtyFlags(force_rebuild: bool, cells_valid: bool) UiEffect {
    return .{
        .consumed = true,
        .needs_rebuild = force_rebuild,
        .cells_invalid = !cells_valid,
    };
}

test "input effects expose repaint and rebuild-only semantics" {
    const repaint_effect = repaint();
    try std.testing.expect(repaint_effect.consumed);
    try std.testing.expect(repaint_effect.needs_rebuild);
    try std.testing.expect(repaint_effect.cells_invalid);

    const rebuild_effect = rebuildOnly();
    try std.testing.expect(rebuild_effect.consumed);
    try std.testing.expect(rebuild_effect.needs_rebuild);
    try std.testing.expect(!rebuild_effect.cells_invalid);
}

test "input effects conditional helpers preserve none when unchanged" {
    try std.testing.expectEqual(UiEffect.none, repaintIf(false));
    try std.testing.expectEqual(UiEffect.none, rebuildIf(false));
    try std.testing.expect(repaintIf(true).cells_invalid);
    try std.testing.expect(!rebuildIf(true).cells_invalid);
}

test "input effects merge helpers add only requested invalidation" {
    const base = UiEffect.consumed_only;
    const repaint_effect = mergeRepaint(base, true);
    try std.testing.expect(repaint_effect.consumed);
    try std.testing.expect(repaint_effect.needs_rebuild);
    try std.testing.expect(repaint_effect.cells_invalid);

    const rebuild_effect = mergeRebuild(base, true);
    try std.testing.expect(rebuild_effect.consumed);
    try std.testing.expect(rebuild_effect.needs_rebuild);
    try std.testing.expect(!rebuild_effect.cells_invalid);
}

test "input effects map dirty flag pairs into effect requests" {
    const repaint_effect = fromDirtyFlags(true, false);
    try std.testing.expect(repaint_effect.consumed);
    try std.testing.expect(repaint_effect.needs_rebuild);
    try std.testing.expect(repaint_effect.cells_invalid);

    const rebuild_only_effect = fromDirtyFlags(true, true);
    try std.testing.expect(rebuild_only_effect.consumed);
    try std.testing.expect(rebuild_only_effect.needs_rebuild);
    try std.testing.expect(!rebuild_only_effect.cells_invalid);
}
