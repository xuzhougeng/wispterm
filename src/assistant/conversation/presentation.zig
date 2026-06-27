//! Presentation mode for the same assistant conversation model.

const std = @import("std");

pub const Presentation = enum {
    chat_tab,
    copilot_sidebar,

    pub fn isSidebar(self: Presentation) bool {
        return self == .copilot_sidebar;
    }
};

test "assistant conversation presentation distinguishes chat tab and sidebar" {
    try std.testing.expect(!Presentation.chat_tab.isSidebar());
    try std.testing.expect(Presentation.copilot_sidebar.isSidebar());
}
