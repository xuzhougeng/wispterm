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

/// Whether the startup AI-agent setup form should auto-open. True only when no AI
/// profile exists AND the form has not been shown on a previous launch. Pure so it
/// is unit-testable without the GUI.
pub fn shouldAutoShowAgentForm(has_ai_profile: bool, already_prompted: bool) bool {
    return !has_ai_profile and !already_prompted;
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

test "startup AI form auto-shows only when no profile and not yet prompted" {
    try std.testing.expect(shouldAutoShowAgentForm(false, false));
    try std.testing.expect(!shouldAutoShowAgentForm(true, false));
    try std.testing.expect(!shouldAutoShowAgentForm(false, true));
    try std.testing.expect(!shouldAutoShowAgentForm(true, true));
}
