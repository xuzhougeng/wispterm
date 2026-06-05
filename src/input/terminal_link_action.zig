//! Pure decision logic for terminal-text link/preview interaction: which
//! modifier opens links, what a click on terminal text should do, and how to
//! classify hovered tokens for interactive underlines. Extracted from input.zig
//! so these rules are unit-tested in the fast suite without the AppWindow /
//! Surface graph. input.zig keeps the adapter layer that feeds real events in.
const std = @import("std");
const builtin = @import("builtin");
const platform_pty_command = @import("../platform/pty_command.zig");
const preview_path = @import("preview_path.zig");
const html_server_model = @import("../html_server_model.zig");

const looksLikePreviewPath = preview_path.looksLikePreviewPath;

pub const LayoutResizeUrgency = enum { coalesced, immediate };
pub const TerminalPathClickAction = enum { pass_through, open_url_or_preview, download_ssh_file };
pub const InteractiveUnderlineTokenKind = enum { none, url, html_path, preview_path };

pub fn panelToggleResizeUrgency() LayoutResizeUrgency {
    return .coalesced;
}

/// The modifier that opens URLs / previews files / downloads SSH paths when
/// clicking or hovering terminal text. macOS uses Cmd (super) — Ctrl+click is
/// the system secondary-click — while other platforms use Ctrl.
pub fn primaryOpenMod(ctrl: bool, super: bool) bool {
    return if (builtin.target.os.tag == .macos) super else ctrl;
}

pub fn terminalPathClickAction(launch_kind: platform_pty_command.LaunchKind, has_ssh_conn: bool, mod: bool, shift: bool, alt: bool) TerminalPathClickAction {
    if (mod and shift and !alt and launch_kind == .ssh and has_ssh_conn) return .download_ssh_file;
    if (mod and !shift and !alt) return .open_url_or_preview;
    return .pass_through;
}

/// Ctrl+right-click (Cmd on macOS) opens the file under the cursor in the OS
/// default app, but only for local terminals — a local app cannot open an SSH
/// or WSL path. `mod` is the primaryOpenMod result. Plain right-click and
/// remote terminals fall through to the configured right-click action.
pub fn rightClickOpensInEditor(launch_kind: platform_pty_command.LaunchKind, mod: bool, shift: bool, alt: bool) bool {
    return launch_kind == .local and mod and !shift and !alt;
}

pub fn interactiveUnderlineTokenKind(action: TerminalPathClickAction, text: []const u8) InteractiveUnderlineTokenKind {
    return switch (action) {
        .pass_through => .none,
        .download_ssh_file => if (looksLikeDownloadPath(text)) .preview_path else .none,
        .open_url_or_preview => if (looksLikeUrl(text))
            .url
        else if (html_server_model.isHtmlPath(text))
            .html_path
        else if (looksLikePreviewPath(text))
            .preview_path
        else
            .none,
    };
}

pub fn looksLikeDownloadPath(text: []const u8) bool {
    if (text.len == 0 or looksLikeUrl(text)) return false;
    if (looksLikePreviewPath(text)) return true;

    const dot_idx = std.mem.lastIndexOfScalar(u8, text, '.') orelse return false;
    return dot_idx > 0 and dot_idx + 1 < text.len;
}

pub fn looksLikeUrl(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "http://") or
        std.mem.startsWith(u8, text, "https://") or
        std.mem.startsWith(u8, text, "www.");
}

test "panel toggles request coalesced layout resize" {
    try std.testing.expectEqual(LayoutResizeUrgency.coalesced, panelToggleResizeUrgency());
}

test "primary open modifier is Cmd on macOS, Ctrl elsewhere" {
    if (builtin.target.os.tag == .macos) {
        try std.testing.expect(primaryOpenMod(false, true)); // Cmd-click opens
        try std.testing.expect(!primaryOpenMod(true, false)); // Ctrl-click does not
    } else {
        try std.testing.expect(primaryOpenMod(true, false)); // Ctrl-click opens
        try std.testing.expect(!primaryOpenMod(false, true)); // Win/Super does not
    }
}

test "terminal path click action maps ctrl shift ssh to download" {
    try std.testing.expectEqual(
        TerminalPathClickAction.download_ssh_file,
        terminalPathClickAction(.ssh, true, true, true, false),
    );
    try std.testing.expectEqual(
        TerminalPathClickAction.pass_through,
        terminalPathClickAction(.ssh, false, true, true, false),
    );
    try std.testing.expectEqual(
        TerminalPathClickAction.pass_through,
        terminalPathClickAction(.wsl, false, true, true, false),
    );
    try std.testing.expectEqual(
        TerminalPathClickAction.open_url_or_preview,
        terminalPathClickAction(.ssh, true, true, false, false),
    );
}

test "interactive underline includes preview paths for ctrl hover" {
    try std.testing.expectEqual(
        InteractiveUnderlineTokenKind.preview_path,
        interactiveUnderlineTokenKind(.open_url_or_preview, "README.md"),
    );
    try std.testing.expectEqual(
        InteractiveUnderlineTokenKind.url,
        interactiveUnderlineTokenKind(.open_url_or_preview, "https://example.com/README.md"),
    );
    try std.testing.expectEqual(
        InteractiveUnderlineTokenKind.none,
        interactiveUnderlineTokenKind(.pass_through, "README.md"),
    );
}

test "interactive underline classifies html before generic preview" {
    try std.testing.expectEqual(
        InteractiveUnderlineTokenKind.html_path,
        interactiveUnderlineTokenKind(.open_url_or_preview, "index.html"),
    );
    try std.testing.expectEqual(
        InteractiveUnderlineTokenKind.html_path,
        interactiveUnderlineTokenKind(.open_url_or_preview, "dist/report.htm"),
    );
}

test "interactive underline includes plain filenames for ssh download hover" {
    try std.testing.expectEqual(
        InteractiveUnderlineTokenKind.preview_path,
        interactiveUnderlineTokenKind(.download_ssh_file, "xx.h5ad"),
    );
}

test "right-click opens local files in editor only with primary modifier" {
    // Local terminal + primary modifier (Ctrl/Cmd), no shift/alt → open.
    try std.testing.expect(rightClickOpensInEditor(.local, true, false, false));
    // Remote terminals never open a local editor.
    try std.testing.expect(!rightClickOpensInEditor(.ssh, true, false, false));
    try std.testing.expect(!rightClickOpensInEditor(.wsl, true, false, false));
    // Plain right-click (no modifier) falls through to the configured action.
    try std.testing.expect(!rightClickOpensInEditor(.local, false, false, false));
    // Shift/Alt are reserved for other gestures.
    try std.testing.expect(!rightClickOpensInEditor(.local, true, true, false));
    try std.testing.expect(!rightClickOpensInEditor(.local, true, false, true));
}
