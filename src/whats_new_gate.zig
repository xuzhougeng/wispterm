//! Pure decision for whether to auto-show the "What's New" modal on launch.
//! No I/O, no rendering, std-only — unit-tested in the fast suite. Compares the
//! running build version against the persisted last-seen version using the same
//! semver comparison the update checker uses.
const std = @import("std");
const update_check = @import("update_check.zig");

pub const Decision = enum { show, suppress };

/// Decide whether to auto-show the changelog.
/// - empty `last_seen` (fresh install / pre-feature upgrade) → suppress
/// - no embedded notes → suppress
/// - `current` strictly newer than `last_seen` → show
/// - same / older / unparseable → suppress
pub fn whatsNewDecision(last_seen: []const u8, current: []const u8, notes_present: bool) Decision {
    if (last_seen.len == 0) return .suppress;
    if (!notes_present) return .suppress;
    return switch (update_check.compareVersions(last_seen, current)) {
        .newer => .show,
        .older, .equal, .unknown => .suppress,
    };
}

test "fresh install suppresses (no last-seen version)" {
    try std.testing.expectEqual(Decision.suppress, whatsNewDecision("", "1.9.0", true));
}

test "upgrade with notes shows" {
    try std.testing.expectEqual(Decision.show, whatsNewDecision("1.8.0", "1.9.0", true));
}

test "upgrade without notes suppresses" {
    try std.testing.expectEqual(Decision.suppress, whatsNewDecision("1.8.0", "1.9.0", false));
}

test "same version suppresses" {
    try std.testing.expectEqual(Decision.suppress, whatsNewDecision("1.9.0", "1.9.0", true));
}

test "downgrade suppresses" {
    try std.testing.expectEqual(Decision.suppress, whatsNewDecision("1.9.0", "1.8.0", true));
}

test "unparseable last-seen suppresses" {
    try std.testing.expectEqual(Decision.suppress, whatsNewDecision("nightly", "1.9.0", true));
}
