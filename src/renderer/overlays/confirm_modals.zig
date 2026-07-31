const std = @import("std");
const input_key = @import("../../input/key.zig");
const close_confirm = @import("../../close_confirm.zig");
const overlay_keys = @import("../overlay_keys.zig");

pub const CloseConfirmVariant = enum { running_program, window_generic, terminal_split };

pub const CloseKeyAction = union(enum) {
    none,
    close_window,
    close_focused_split,
    close_tab: usize,
};

pub const RestoreDefaultsAction = enum { none, apply, cancel };

pub const State = struct {
    transfer_cancel_visible: bool = false,
    window_close_visible: bool = false,
    close_pending: close_confirm.PendingClose = .window,
    close_variant: CloseConfirmVariant = .window_generic,
    restore_defaults_visible: bool = false,

    pub fn openCloseConfirm(self: *State, action: close_confirm.PendingClose, variant: CloseConfirmVariant) void {
        self.window_close_visible = true;
        self.close_pending = action;
        self.close_variant = variant;
    }

    pub fn closeWindowConfirm(self: *State) void {
        self.window_close_visible = false;
    }

    pub fn handleWindowCloseKey(self: *State, ev: input_key.KeyEvent) CloseKeyAction {
        if (!self.window_close_visible) return .none;

        return switch (close_confirm.keyOutcome(ev)) {
            .none => .none,
            .confirm => self.confirmClose(),
            .cancel => {
                self.closeWindowConfirm();
                return .none;
            },
        };
    }

    pub fn confirmClose(self: *State) CloseKeyAction {
        self.closeWindowConfirm();
        return switch (self.close_pending) {
            .window => .close_window,
            .focused_split => .close_focused_split,
            .tab => |idx| .{ .close_tab = idx },
        };
    }

    pub fn openRestoreDefaults(self: *State) void {
        self.restore_defaults_visible = true;
    }

    pub fn closeRestoreDefaults(self: *State) void {
        self.restore_defaults_visible = false;
    }

    pub fn handleRestoreDefaultsKey(self: *State, ev: input_key.KeyEvent) RestoreDefaultsAction {
        if (!self.restore_defaults_visible) return .none;

        return switch (ev.key) {
            .enter => {
                self.closeRestoreDefaults();
                return .apply;
            },
            .escape => {
                self.closeRestoreDefaults();
                return .cancel;
            },
            else => .none,
        };
    }

    pub fn openTransferCancel(self: *State) void {
        self.transfer_cancel_visible = true;
    }

    pub fn closeTransferCancel(self: *State) void {
        self.transfer_cancel_visible = false;
    }

    pub fn handleTransferCancelKey(self: *State, ev: input_key.KeyEvent) overlay_keys.TransferCancelConfirmAction {
        if (!self.transfer_cancel_visible) return .none;

        const action = overlay_keys.transferCancelConfirmAction(ev);
        if (action != .none) self.closeTransferCancel();
        return action;
    }
};

test "confirm modal state maps enter to pending close action" {
    var state: State = .{};
    state.openCloseConfirm(.{ .tab = 2 }, .terminal_split);

    const action = state.handleWindowCloseKey(.{ .key = .enter });

    try std.testing.expectEqual(CloseKeyAction{ .close_tab = 2 }, action);
    try std.testing.expect(!state.window_close_visible);
}

test "restore defaults confirmation maps escape to cancel" {
    var state: State = .{};
    state.openRestoreDefaults();

    const action = state.handleRestoreDefaultsKey(.{ .key = .escape });

    try std.testing.expectEqual(RestoreDefaultsAction.cancel, action);
    try std.testing.expect(!state.restore_defaults_visible);
}

test "transfer cancel confirmation closes on interrupt" {
    var state: State = .{};
    state.openTransferCancel();

    const action = state.handleTransferCancelKey(.{ .key = .enter });

    try std.testing.expectEqual(overlay_keys.TransferCancelConfirmAction.interrupt, action);
    try std.testing.expect(!state.transfer_cancel_visible);
}

test "window close escape cancels without changing pending close action" {
    var state: State = .{};
    state.openCloseConfirm(.focused_split, .running_program);

    const action = state.handleWindowCloseKey(.{ .key = .escape });

    try std.testing.expectEqual(CloseKeyAction.none, action);
    try std.testing.expect(!state.window_close_visible);
    try std.testing.expectEqual(CloseConfirmVariant.running_program, state.close_variant);
    switch (state.close_pending) {
        .focused_split => {},
        else => return error.PendingCloseChanged,
    }
}

test "restore defaults unhandled key stays visible" {
    var state: State = .{};
    state.openRestoreDefaults();

    const action = state.handleRestoreDefaultsKey(.{ .key = .tab });

    try std.testing.expectEqual(RestoreDefaultsAction.none, action);
    try std.testing.expect(state.restore_defaults_visible);
}
