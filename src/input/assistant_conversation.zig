//! Shared input target lookup for assistant conversations.

const AppWindow = @import("../AppWindow.zig");
const presentation = @import("../assistant/conversation/presentation.zig");

pub const Target = struct {
    session: *AppWindow.ai_chat.Session,
    presentation: presentation.Presentation,

    pub fn isSidebar(self: Target) bool {
        return self.presentation.isSidebar();
    }
};

pub fn current(copilot_focused: bool) ?Target {
    if (AppWindow.activeAiChat()) |session| {
        return .{
            .session = session,
            .presentation = .chat_tab,
        };
    }
    if (!copilot_focused) return null;
    const session = AppWindow.activeCopilotSessionForInput() orelse return null;
    return .{
        .session = session,
        .presentation = .copilot_sidebar,
    };
}
