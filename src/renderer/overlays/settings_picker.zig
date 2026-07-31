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
