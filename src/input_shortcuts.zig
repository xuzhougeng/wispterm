const std = @import("std");

const input_key = @import("input/key.zig");

pub fn terminalArrowSequence(ev: input_key.KeyEvent, cursor_keys: bool) ?[]const u8 {
    const modifier: u8 = 1 +
        @as(u8, if (ev.shift) 1 else 0) +
        @as(u8, if (ev.alt) 2 else 0) +
        @as(u8, if (ev.ctrl) 4 else 0);

    inline for (terminal_arrow_sequences) |entry| {
        if (ev.key == entry.key) {
            return if (modifier == 1) cursorModeSequence(entry, cursor_keys) else entry.modified[modifier - 2];
        }
    }
    return null;
}

fn cursorModeSequence(entry: TerminalArrowSequence, cursor_keys: bool) []const u8 {
    return if (cursor_keys) entry.application else entry.normal;
}

const TerminalArrowSequence = struct {
    key: input_key.Key,
    normal: []const u8,
    application: []const u8,
    modified: [7][]const u8,
};

const terminal_arrow_sequences = [_]TerminalArrowSequence{
    .{ .key = .arrow_up, .normal = "\x1b[A", .application = "\x1bOA", .modified = .{ "\x1b[1;2A", "\x1b[1;3A", "\x1b[1;4A", "\x1b[1;5A", "\x1b[1;6A", "\x1b[1;7A", "\x1b[1;8A" } },
    .{ .key = .arrow_down, .normal = "\x1b[B", .application = "\x1bOB", .modified = .{ "\x1b[1;2B", "\x1b[1;3B", "\x1b[1;4B", "\x1b[1;5B", "\x1b[1;6B", "\x1b[1;7B", "\x1b[1;8B" } },
    .{ .key = .arrow_right, .normal = "\x1b[C", .application = "\x1bOC", .modified = .{ "\x1b[1;2C", "\x1b[1;3C", "\x1b[1;4C", "\x1b[1;5C", "\x1b[1;6C", "\x1b[1;7C", "\x1b[1;8C" } },
    .{ .key = .arrow_left, .normal = "\x1b[D", .application = "\x1bOD", .modified = .{ "\x1b[1;2D", "\x1b[1;3D", "\x1b[1;4D", "\x1b[1;5D", "\x1b[1;6D", "\x1b[1;7D", "\x1b[1;8D" } },
};

test "terminal arrow sequence handles modifiers" {
    try std.testing.expectEqualStrings(
        "\x1b[A",
        terminalArrowSequence(.{ .key = input_key.Key.arrow_up }, false).?,
    );
    try std.testing.expectEqualStrings(
        "\x1bOA",
        terminalArrowSequence(.{ .key = input_key.Key.arrow_up }, true).?,
    );
    try std.testing.expectEqualStrings(
        "\x1bOD",
        terminalArrowSequence(.{ .key = input_key.Key.arrow_left }, true).?,
    );
    try std.testing.expectEqualStrings(
        "\x1b[1;3D",
        terminalArrowSequence(.{ .key = input_key.Key.arrow_left, .alt = true }, true).?,
    );
    try std.testing.expectEqualStrings(
        "\x1b[1;5C",
        terminalArrowSequence(.{ .key = input_key.Key.arrow_right, .ctrl = true }, false).?,
    );
    try std.testing.expect(terminalArrowSequence(.{ .key = input_key.Key.key_a, .alt = true }, false) == null);
}
