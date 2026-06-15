//! Pure decision for Windows-Terminal-style "Ctrl+C copies the selection".
//!
//! On Windows the dominant terminal (Windows Terminal) treats Ctrl+C as COPY
//! when a selection is active, and only as SIGINT (0x03) when there is no
//! selection. WispTerm historically always sent 0x03. That bit users whose
//! "copy on select" trackpad/clipboard tools synthesize a Ctrl+C right after a
//! mouse selection: in a terminal that Ctrl+C interrupted the running program
//! instead of copying.
//!
//! This module is the pure gate; the caller performs the copy + clears the
//! selection and suppresses the 0x03 when it returns true.

const std = @import("std");

/// True when an unmodified Ctrl+C should copy the active selection instead of
/// sending SIGINT. `key_code` is the platform virtual-key code; 0x43 == 'C'.
pub fn ctrlCCopiesSelection(
    key_code: usize,
    ctrl: bool,
    shift: bool,
    enabled: bool,
    selection_active: bool,
) bool {
    return enabled and ctrl and !shift and selection_active and key_code == 0x43;
}

const testing = std.testing;

test "Ctrl+C with active selection copies when enabled" {
    try testing.expect(ctrlCCopiesSelection(0x43, true, false, true, true));
}

test "no selection -> still sends SIGINT" {
    try testing.expect(!ctrlCCopiesSelection(0x43, true, false, true, false));
}

test "disabled -> never copies (legacy SIGINT behavior)" {
    try testing.expect(!ctrlCCopiesSelection(0x43, true, false, false, true));
}

test "Shift+Ctrl+C is a separate chord, not this gate" {
    try testing.expect(!ctrlCCopiesSelection(0x43, true, true, true, true));
}

test "other Ctrl+letters are unaffected" {
    // Ctrl+D (0x44), Ctrl+Z (0x5A), Ctrl+A (0x41) must keep sending their byte.
    try testing.expect(!ctrlCCopiesSelection(0x44, true, false, true, true));
    try testing.expect(!ctrlCCopiesSelection(0x5A, true, false, true, true));
    try testing.expect(!ctrlCCopiesSelection(0x41, true, false, true, true));
}

test "plain C (no ctrl) is just typing the letter" {
    try testing.expect(!ctrlCCopiesSelection(0x43, false, false, true, true));
}
