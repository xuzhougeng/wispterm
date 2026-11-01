//! Pure selection state for Settings choice lists (fonts and shells).
const std = @import("std");

pub const Kind = enum { font_family, shell };

pub const State = struct {
    kind: ?Kind = null,
    selected: usize = 0,

    pub fn open(self: *State, kind: Kind, choices: []const []const u8, current: []const u8) void {
        self.kind = kind;
        self.selected = 0;
        for (choices, 0..) |choice, index| {
            if (std.ascii.eqlIgnoreCase(choice, current)) {
                self.selected = index;
                break;
            }
        }
    }

    pub fn move(self: *State, delta: isize, count: usize) void {
        if (count == 0) return;
        const current: isize = @intCast(@min(self.selected, count - 1));
        self.selected = @intCast(@mod(current + delta, @as(isize, @intCast(count))));
    }

    pub fn selectedValue(self: *const State, choices: []const []const u8) ?[]const u8 {
        if (self.kind == null or self.selected >= choices.len) return null;
        return choices[self.selected];
    }

    pub fn close(self: *State) void {
        self.kind = null;
        self.selected = 0;
    }
};

/// Font picker list: the built-in default family first (it is bundled, so it is
/// usually not an installed system font and could not be picked back), then the
/// system families sorted case-insensitively without duplicates. DirectWrite
/// enumerates families in collection order, which only looks sorted (#647).
/// Takes ownership of `listed` (each string and the slice); the result is owned
/// the same way.
pub fn fontFamilyChoices(allocator: std.mem.Allocator, listed: [][]const u8, default_family: []const u8) ![][]const u8 {
    defer allocator.free(listed);
    std.sort.pdq([]const u8, listed, {}, lessThanIgnoreCase);

    var out = std.ArrayListUnmanaged([]const u8).initCapacity(allocator, listed.len + 1) catch |err| {
        for (listed) |name| allocator.free(name);
        return err;
    };
    errdefer {
        for (out.items) |name| allocator.free(name);
        out.deinit(allocator);
    }
    const default_copy = allocator.dupe(u8, default_family) catch |err| {
        for (listed) |name| allocator.free(name);
        return err;
    };
    out.appendAssumeCapacity(default_copy);
    for (listed) |name| {
        const last = out.items[out.items.len - 1];
        if (std.ascii.eqlIgnoreCase(name, default_family) or std.ascii.eqlIgnoreCase(name, last)) {
            allocator.free(name);
            continue;
        }
        out.appendAssumeCapacity(name);
    }
    return out.toOwnedSlice(allocator);
}

fn lessThanIgnoreCase(_: void, a: []const u8, b: []const u8) bool {
    return std.ascii.lessThanIgnoreCase(a, b);
}

test "fontFamilyChoices puts the default first, then sorts and dedupes system families" {
    const gpa = std.testing.allocator;
    const raw = [_][]const u8{ "Yu Gothic UI", "DengXian", "consolas", "FangSong", "JetBrains Mono", "Consolas", "Arial" };
    const listed = try gpa.alloc([]const u8, raw.len);
    for (raw, 0..) |name, i| listed[i] = try gpa.dupe(u8, name);

    const choices = try fontFamilyChoices(gpa, listed, "JetBrains Mono");
    defer {
        for (choices) |name| gpa.free(name);
        gpa.free(choices);
    }
    const expected = [_][]const u8{ "JetBrains Mono", "Arial", "consolas", "DengXian", "FangSong", "Yu Gothic UI" };
    try std.testing.expectEqual(expected.len, choices.len);
    for (expected, choices) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "settings picker opens on the current value and returns the selected choice" {
    const choices = [_][]const u8{ "bash", "zsh", "fish" };
    var picker = State{};

    picker.open(.shell, &choices, "zsh");
    try std.testing.expectEqual(@as(usize, 1), picker.selected);
    picker.move(1, choices.len);
    try std.testing.expectEqualStrings("fish", picker.selectedValue(&choices).?);
}

test "settings picker wraps and close clears the active choice list" {
    const choices = [_][]const u8{ "JetBrains Mono", "Menlo" };
    var picker = State{};

    picker.open(.font_family, &choices, "JetBrains Mono");
    picker.move(-1, choices.len);
    try std.testing.expectEqual(@as(usize, 1), picker.selected);
    picker.close();
    try std.testing.expect(picker.kind == null);
    try std.testing.expect(picker.selectedValue(&choices) == null);
}
