//! Backend-owned D3D11 present health policy.
//!
//! The OpenGL+DXGI presenter has its own host-side `dxgi_core.PresentPolicy`
//! because it can fall back to GDI on the next launch. The native D3D11 backend
//! needs a separate state machine: a failed D3D device cannot be safely ignored,
//! but automatic recreation/fallback is a later Phase V slice. For now this
//! module latches the failure state and makes the next required action explicit.

const std = @import("std");
const core = @import("../../../platform/dxgi_core.zig");

pub const Operation = enum {
    present,
    resize,
    resize_target,

    pub fn name(self: Operation) []const u8 {
        return switch (self) {
            .present => "present",
            .resize => "resize",
            .resize_target => "resize_target",
        };
    }
};

pub const State = enum {
    healthy,
    needs_recreate,
    fallback_candidate,

    pub fn name(self: State) []const u8 {
        return switch (self) {
            .healthy => "healthy",
            .needs_recreate => "needs_recreate",
            .fallback_candidate => "fallback_candidate",
        };
    }
};

pub const Action = enum {
    skip,
    present,
    resize_then_present,
    wait_for_recreate,
    fallback_candidate,
};

pub const RecoveryAction = enum {
    recreate_device,
    flag_fallback_candidate,

    pub fn name(self: RecoveryAction) []const u8 {
        return switch (self) {
            .recreate_device => "recreate_device",
            .flag_fallback_candidate => "flag_fallback_candidate",
        };
    }
};

pub const FallbackReason = enum {
    none,
    device_lost,
    invalid_call,
    present_failed,
    resize_failed,
    render_target_failed,

    pub fn name(self: FallbackReason) []const u8 {
        return switch (self) {
            .none => "none",
            .device_lost => "device_lost",
            .invalid_call => "invalid_call",
            .present_failed => "present_failed",
            .resize_failed => "resize_failed",
            .render_target_failed => "render_target_failed",
        };
    }
};

pub const Status = struct {
    state: State = .healthy,
    operation: ?Operation = null,
    reason: FallbackReason = .none,
    dxgi_kind: core.DxgiFailureKind = .ok,
    requires_device_recreate: bool = false,

    pub fn healthy() Status {
        return .{};
    }

    pub fn stateName(self: Status) []const u8 {
        return self.state.name();
    }

    pub fn reasonName(self: Status) []const u8 {
        return self.reason.name();
    }

    pub fn dxgiKindName(self: Status) []const u8 {
        return self.dxgi_kind.name();
    }

    pub fn operationName(self: Status) []const u8 {
        return if (self.operation) |op| op.name() else "none";
    }

    pub fn fallbackCandidate(self: Status) bool {
        return self.state != .healthy and self.reason != .none;
    }
};

pub const RecoveryRequest = struct {
    status: Status,
    action: RecoveryAction,

    pub fn actionName(self: RecoveryRequest) []const u8 {
        return self.action.name();
    }
};

pub const Policy = struct {
    width: i32,
    height: i32,
    status_value: Status = .{},
    recovery_pending: bool = false,

    pub fn init(width: i32, height: i32) Policy {
        return .{ .width = width, .height = height };
    }

    pub fn status(self: *const Policy) Status {
        return self.status_value;
    }

    pub fn frameAction(self: *const Policy, width: i32, height: i32) Action {
        return switch (self.status_value.state) {
            .needs_recreate => .wait_for_recreate,
            .fallback_candidate => .fallback_candidate,
            .healthy => blk: {
                if (width <= 0 or height <= 0) break :blk .skip;
                if (width != self.width or height != self.height) break :blk .resize_then_present;
                break :blk .present;
            },
        };
    }

    pub fn noteResizeSucceeded(self: *Policy, width: i32, height: i32) void {
        self.width = width;
        self.height = height;
    }

    pub fn noteDxgiFailure(self: *Policy, operation: Operation, hr: core.HRESULT) Status {
        const kind = core.dxgiFailureKind(hr);
        const requires_recreate = kind.requiresDeviceRecreate();
        return self.latchFailure(
            operation,
            fallbackReason(operation, kind),
            kind,
            requires_recreate,
        );
    }

    pub fn noteBackendFailure(
        self: *Policy,
        operation: Operation,
        reason: FallbackReason,
        requires_recreate: bool,
    ) Status {
        return self.latchFailure(operation, reason, .other, requires_recreate);
    }

    fn latchFailure(
        self: *Policy,
        operation: Operation,
        reason: FallbackReason,
        kind: core.DxgiFailureKind,
        requires_recreate: bool,
    ) Status {
        const next_state: State = if (requires_recreate) .needs_recreate else .fallback_candidate;

        // The first fallback candidate is useful evidence, but a later
        // device-lost signal is more severe and must upgrade the state.
        if (self.status_value.state == .healthy or
            (next_state == .needs_recreate and self.status_value.state != .needs_recreate))
        {
            self.status_value = .{
                .state = next_state,
                .operation = operation,
                .reason = reason,
                .dxgi_kind = kind,
                .requires_device_recreate = requires_recreate,
            };
            self.recovery_pending = true;
        }

        return self.status_value;
    }

    pub fn takeRecoveryRequest(self: *Policy) ?RecoveryRequest {
        if (!self.recovery_pending or self.status_value.state == .healthy) return null;
        self.recovery_pending = false;
        return .{
            .status = self.status_value,
            .action = if (self.status_value.requires_device_recreate)
                .recreate_device
            else
                .flag_fallback_candidate,
        };
    }
};

fn fallbackReason(operation: Operation, kind: core.DxgiFailureKind) FallbackReason {
    if (kind.requiresDeviceRecreate()) return .device_lost;
    if (kind == .invalid_call) return .invalid_call;
    return switch (operation) {
        .present => .present_failed,
        .resize => .resize_failed,
        .resize_target => .render_target_failed,
    };
}

test "D3D11 present policy presents and resizes while healthy" {
    var policy = Policy.init(800, 600);

    try std.testing.expectEqual(Action.present, policy.frameAction(800, 600));
    try std.testing.expectEqual(Action.resize_then_present, policy.frameAction(1024, 768));
    try std.testing.expectEqual(Action.skip, policy.frameAction(0, 768));

    policy.noteResizeSucceeded(1024, 768);
    try std.testing.expectEqual(Action.present, policy.frameAction(1024, 768));
    try std.testing.expectEqual(State.healthy, policy.status().state);
}

test "D3D11 present policy latches device loss as recreate state" {
    var policy = Policy.init(800, 600);
    const status = policy.noteDxgiFailure(.present, core.DXGI_ERROR_DEVICE_REMOVED);

    try std.testing.expectEqual(State.needs_recreate, status.state);
    try std.testing.expectEqual(Operation.present, status.operation.?);
    try std.testing.expectEqual(FallbackReason.device_lost, status.reason);
    try std.testing.expectEqual(core.DxgiFailureKind.device_removed, status.dxgi_kind);
    try std.testing.expect(status.requires_device_recreate);
    try std.testing.expect(status.fallbackCandidate());
    try std.testing.expectEqual(Action.wait_for_recreate, policy.frameAction(800, 600));

    const request = policy.takeRecoveryRequest() orelse return error.MissingRecoveryRequest;
    try std.testing.expectEqual(RecoveryAction.recreate_device, request.action);
    try std.testing.expectEqual(State.needs_recreate, request.status.state);
    try std.testing.expectEqualStrings("recreate_device", request.actionName());
    try std.testing.expect(policy.takeRecoveryRequest() == null);

    policy.noteResizeSucceeded(1024, 768);
    try std.testing.expectEqual(Action.wait_for_recreate, policy.frameAction(1024, 768));
}

test "D3D11 present policy records non-device-loss fallback candidates" {
    var policy = Policy.init(800, 600);
    const status = policy.noteDxgiFailure(.present, core.DXGI_ERROR_INVALID_CALL);

    try std.testing.expectEqual(State.fallback_candidate, status.state);
    try std.testing.expectEqual(FallbackReason.invalid_call, status.reason);
    try std.testing.expectEqual(core.DxgiFailureKind.invalid_call, status.dxgi_kind);
    try std.testing.expect(!status.requires_device_recreate);
    try std.testing.expect(status.fallbackCandidate());
    try std.testing.expectEqual(Action.fallback_candidate, policy.frameAction(800, 600));

    const request = policy.takeRecoveryRequest() orelse return error.MissingRecoveryRequest;
    try std.testing.expectEqual(RecoveryAction.flag_fallback_candidate, request.action);
    try std.testing.expectEqual(FallbackReason.invalid_call, request.status.reason);
    try std.testing.expect(policy.takeRecoveryRequest() == null);
}

test "D3D11 present policy upgrades a fallback candidate to device recreate" {
    var policy = Policy.init(800, 600);
    _ = policy.noteDxgiFailure(.resize, core.DXGI_ERROR_INVALID_CALL);
    _ = policy.takeRecoveryRequest() orelse return error.MissingRecoveryRequest;

    const status = policy.noteDxgiFailure(.present, core.DXGI_ERROR_DEVICE_RESET);

    try std.testing.expectEqual(State.needs_recreate, status.state);
    try std.testing.expectEqual(Operation.present, status.operation.?);
    try std.testing.expectEqual(FallbackReason.device_lost, status.reason);
    try std.testing.expectEqual(core.DxgiFailureKind.device_reset, status.dxgi_kind);

    const request = policy.takeRecoveryRequest() orelse return error.MissingRecoveryRequest;
    try std.testing.expectEqual(RecoveryAction.recreate_device, request.action);
    try std.testing.expectEqual(core.DxgiFailureKind.device_reset, request.status.dxgi_kind);
}

test "D3D11 present policy records render-target creation failures" {
    var policy = Policy.init(800, 600);
    const status = policy.noteBackendFailure(.resize_target, .render_target_failed, false);

    try std.testing.expectEqual(State.fallback_candidate, status.state);
    try std.testing.expectEqual(Operation.resize_target, status.operation.?);
    try std.testing.expectEqual(FallbackReason.render_target_failed, status.reason);
    try std.testing.expectEqual(Action.fallback_candidate, policy.frameAction(800, 600));
    try std.testing.expectEqualStrings("fallback_candidate", status.stateName());
    try std.testing.expectEqualStrings("render_target_failed", status.reasonName());
    try std.testing.expectEqualStrings("resize_target", status.operationName());
}
