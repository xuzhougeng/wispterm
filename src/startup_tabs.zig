const std = @import("std");

pub const InitialTabPlan = enum {
    restored_session,
    single_terminal,
    agent_and_local_shell,
};

pub const InitialTabPlanInput = struct {
    restored_session: bool,
    initial_cwd_present: bool,
    first_plain_window: bool,
};

pub fn initialTabPlan(input: InitialTabPlanInput) InitialTabPlan {
    if (input.restored_session) return .restored_session;
    if (input.initial_cwd_present) return .single_terminal;
    if (input.first_plain_window) return .agent_and_local_shell;
    return .single_terminal;
}

test "startup tabs open the default pair only for a plain launch" {
    try std.testing.expectEqual(InitialTabPlan.restored_session, initialTabPlan(.{
        .restored_session = true,
        .initial_cwd_present = false,
        .first_plain_window = true,
    }));
    try std.testing.expectEqual(InitialTabPlan.single_terminal, initialTabPlan(.{
        .restored_session = false,
        .initial_cwd_present = true,
        .first_plain_window = true,
    }));
    try std.testing.expectEqual(InitialTabPlan.agent_and_local_shell, initialTabPlan(.{
        .restored_session = false,
        .initial_cwd_present = false,
        .first_plain_window = true,
    }));
    try std.testing.expectEqual(InitialTabPlan.single_terminal, initialTabPlan(.{
        .restored_session = false,
        .initial_cwd_present = false,
        .first_plain_window = false,
    }));
}
