const std = @import("std");

pub const AiHistorySourceChoice = enum { local, wsl, ssh };

/// Launcher-level transient picker state that is neither form data
/// (see `ssh_profiles` / `ai_profiles`) nor visibility (`command_center_state`).
/// `switch_model_target` is the live `ai_chat.Session` bound to a `.switch_model`
/// picker, stored opaque so this module stays compilable in the fast test suite
/// without importing the heavy `ai_chat.zig` graph; `overlays.zig` casts it.
pub const State = struct {
    ai_history_source_selected: usize = 0,
    switch_model_target: ?*anyopaque = null,

    pub fn historySourceNext(self: *State, row_count: usize) void {
        if (row_count == 0) return;
        self.ai_history_source_selected = (self.ai_history_source_selected + 1) % row_count;
    }

    pub fn historySourcePrev(self: *State, row_count: usize) void {
        if (row_count == 0) return;
        self.ai_history_source_selected = if (self.ai_history_source_selected == 0)
            row_count - 1
        else
            self.ai_history_source_selected - 1;
    }

    pub fn clearSwitchTarget(self: *State) void {
        self.switch_model_target = null;
    }
};

test "history source navigation wraps over a dynamic row count" {
    var state = State{ .ai_history_source_selected = 0 };

    state.historySourcePrev(3);
    try std.testing.expectEqual(@as(usize, 2), state.ai_history_source_selected);

    state.historySourceNext(3);
    try std.testing.expectEqual(@as(usize, 0), state.ai_history_source_selected);

    state.historySourceNext(3);
    try std.testing.expectEqual(@as(usize, 1), state.ai_history_source_selected);
}

test "history source navigation is a no-op on an empty list" {
    var state = State{ .ai_history_source_selected = 0 };

    state.historySourceNext(0);
    state.historySourcePrev(0);

    try std.testing.expectEqual(@as(usize, 0), state.ai_history_source_selected);
}

test "switch model target stores and clears an opaque pointer" {
    var state = State{};
    var dummy: u32 = 7;

    state.switch_model_target = @ptrCast(&dummy);
    try std.testing.expect(state.switch_model_target != null);

    state.clearSwitchTarget();
    try std.testing.expect(state.switch_model_target == null);
}
