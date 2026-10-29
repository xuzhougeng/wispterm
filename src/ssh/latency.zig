//! Window-owned monitor for the active SSH host. Workers own copied targets;
//! they never access a Surface, renderer, or AppWindow state.
const std = @import("std");
const connection = @import("connection.zig");
const ping = @import("../platform/ping.zig");
const process_runner = @import("../process_runner.zig");
const threading = @import("../platform/threading.zig");
const UiEffect = @import("../appwindow/ui_effect.zig").UiEffect;

pub const INTERVAL_MS: i64 = 5000;
pub const Target = struct {
    session: usize,
    host_buf: [128]u8,
    host_len: usize,
    via_jump: bool,

    pub fn fromConnection(session: usize, conn: *const connection.SshConnection) Target {
        var result = Target{ .session = session, .host_buf = undefined, .host_len = conn.host().len, .via_jump = conn.proxyJump().len != 0 or conn.network_proxy.kind != .none };
        @memcpy(result.host_buf[0..result.host_len], conn.host());
        return result;
    }

    fn host(self: *const Target) []const u8 {
        const value = self.host_buf[0..self.host_len];
        return if (value.len >= 2 and value[0] == '[' and value[value.len - 1] == ']') value[1 .. value.len - 1] else value;
    }

    fn same(a: ?Target, b: ?Target) bool {
        if (a == null or b == null) return a == null and b == null;
        return a.?.session == b.?.session and a.?.via_jump == b.?.via_jump and std.mem.eql(u8, a.?.host(), b.?.host());
    }
};

pub const Reading = union(enum) { hidden, measuring, value: ping.Sample, no_reply, unavailable };
const ProbeFn = *const fn (std.mem.Allocator, []const u8, *const process_runner.CancelToken) ping.Result;

const Job = struct {
    allocator: std.mem.Allocator,
    target: Target,
    generation: u64,
    cancel: process_runner.CancelToken = .{},
    done: std.atomic.Value(bool) = .init(false),
    result: ping.Result = .unavailable,
    thread: ?std.Thread = null,
    probe_fn: ProbeFn,
    wake: *const fn () void,

    fn run(self: *Job) void {
        self.result = self.probe_fn(self.allocator, self.target.host(), &self.cancel);
        self.done.store(true, .release);
        self.wake();
    }
};

pub const Monitor = struct {
    allocator: std.mem.Allocator = std.heap.page_allocator,
    enabled: bool = false,
    target: ?Target = null,
    reading: Reading = .hidden,
    generation: u64 = 0,
    next_probe_ms: i64 = 0,
    job: ?*Job = null,
    probe_fn: ProbeFn = ping.probe,

    pub fn deinit(self: *Monitor) void {
        if (self.job) |job| {
            job.cancel.cancel();
            if (job.thread) |thread| thread.join();
            self.allocator.destroy(job);
        }
        self.* = .{};
    }

    pub fn toggle(self: *Monitor) UiEffect {
        self.enabled = !self.enabled;
        if (!self.enabled) {
            self.generation +%= 1;
            self.target = null;
            self.reading = .hidden;
            if (self.job) |job| job.cancel.cancel();
        }
        return .repaint;
    }

    pub fn tick(self: *Monitor, current: ?Target, now_ms: i64, wake: *const fn () void) UiEffect {
        var effect = UiEffect.none;
        const wanted = if (self.enabled) current else null;
        if (!Target.same(self.target, wanted)) {
            self.generation +%= 1;
            self.target = wanted;
            self.reading = if (wanted) |target| (if (target.via_jump) .unavailable else .measuring) else .hidden;
            self.next_probe_ms = now_ms;
            if (self.job) |job| job.cancel.cancel();
            effect = .repaint;
        }
        if (self.job) |job| {
            if (!job.done.load(.acquire)) return effect;
            if (job.thread) |thread| thread.join();
            if (job.generation == self.generation and wanted != null) {
                const reading: Reading = switch (job.result) {
                    .value => |sample| .{ .value = sample },
                    .no_reply => .no_reply,
                    .unavailable, .cancelled => .unavailable,
                };
                if (!std.meta.eql(self.reading, reading)) effect = .repaint;
                self.reading = reading;
            }
            self.allocator.destroy(job);
            self.job = null;
        }
        const target = wanted orelse return effect;
        // Direct-host ICMP only; jump routes need SSH transport telemetry.
        if (target.via_jump or now_ms < self.next_probe_ms) return effect;
        self.next_probe_ms = now_ms + INTERVAL_MS;
        const job = self.allocator.create(Job) catch {
            self.reading = .unavailable;
            return .repaint;
        };
        job.* = .{ .allocator = self.allocator, .target = target, .generation = self.generation, .probe_fn = self.probe_fn, .wake = wake };
        job.thread = std.Thread.spawn(threading.surface_thread_spawn_config, Job.run, .{job}) catch {
            self.allocator.destroy(job);
            self.reading = .unavailable;
            return .repaint;
        };
        self.job = job;
        return effect;
    }

    pub fn label(self: *const Monitor, buf: []u8) []const u8 {
        return switch (self.reading) {
            .hidden => "",
            .measuring => "RTT …",
            .no_reply, .unavailable => "RTT —",
            .value => |sample| if (sample.less_than)
                std.fmt.bufPrint(buf, "RTT <{d:.0} ms", .{sample.milliseconds}) catch "RTT —"
            else
                std.fmt.bufPrint(buf, "RTT {d:.1} ms", .{sample.milliseconds}) catch "RTT —",
        };
    }
};

fn noWake() void {}

test "latency monitor hides inactive targets, throttles probes, and stops on toggle" {
    const Fake = struct {
        fn probe(_: std.mem.Allocator, _: []const u8, _: *const process_runner.CancelToken) ping.Result {
            return .{ .value = .{ .milliseconds = 12.5 } };
        }
    };
    var monitor = Monitor{ .allocator = std.testing.allocator, .probe_fn = Fake.probe };
    defer monitor.deinit();
    const conn = connection.SshConnection.fromParts(.{ .user = "test", .host = "example.org" });
    const target = Target.fromConnection(1, &conn);
    try std.testing.expect(!monitor.tick(target, 100, noWake).needs_rebuild);
    try std.testing.expect(monitor.job == null);
    try std.testing.expect(monitor.toggle().needs_rebuild);
    try std.testing.expect(monitor.tick(target, 100, noWake).needs_rebuild);
    try finishJob(&monitor, target, 100);
    var text: [64]u8 = undefined;
    try std.testing.expectEqualStrings("RTT 12.5 ms", monitor.label(&text));
    _ = monitor.tick(target, 100 + INTERVAL_MS - 1, noWake);
    try std.testing.expect(monitor.job == null);
    _ = monitor.tick(target, 100 + INTERVAL_MS, noWake);
    try std.testing.expect(monitor.job != null);
    try std.testing.expect(monitor.toggle().needs_rebuild);
    try std.testing.expectEqualStrings("", monitor.label(&text));
    try std.testing.expect(monitor.job.?.cancel.isCancelled());
}

test "latency monitor discards old-session results and does not probe jump routes" {
    var monitor = Monitor{ .allocator = std.testing.allocator };
    defer monitor.deinit();
    _ = monitor.toggle();
    const direct = connection.SshConnection.fromParts(.{ .user = "test", .host = "old.example" });
    const jumped = connection.SshConnection.fromParts(.{ .user = "test", .host = "new.example", .proxy_jump = "bastion" });
    monitor.target = Target.fromConnection(1, &direct);
    const job = try monitor.allocator.create(Job);
    job.* = .{ .allocator = monitor.allocator, .target = monitor.target.?, .generation = monitor.generation, .probe_fn = ping.probe, .wake = noWake, .result = .{ .value = .{ .milliseconds = 99 } } };
    job.done.store(true, .release);
    monitor.job = job;
    try std.testing.expect(monitor.tick(Target.fromConnection(2, &jumped), 100, noWake).needs_rebuild);
    try std.testing.expectEqual(Reading.unavailable, monitor.reading);
    try std.testing.expect(monitor.job == null);
    try std.testing.expect(monitor.tick(null, 101, noWake).needs_rebuild);
    try std.testing.expectEqual(Reading.hidden, monitor.reading);
}

test "latency monitor keeps its cadence across slow replies and recovers after no reply" {
    const Fake = struct {
        fn probe(_: std.mem.Allocator, _: []const u8, _: *const process_runner.CancelToken) ping.Result {
            return .{ .value = .{ .milliseconds = 1, .less_than = true } };
        }
    };
    var monitor = Monitor{ .allocator = std.testing.allocator, .probe_fn = Fake.probe };
    defer monitor.deinit();
    const conn = connection.SshConnection.fromParts(.{ .user = "test", .host = "[::1]" });
    const target = Target.fromConnection(1, &conn);
    try std.testing.expectEqualStrings("::1", target.host());
    _ = monitor.toggle();
    monitor.target = target;
    monitor.reading = .measuring;
    monitor.next_probe_ms = INTERVAL_MS;
    const job = try monitor.allocator.create(Job);
    job.* = .{ .allocator = monitor.allocator, .target = target, .generation = monitor.generation, .probe_fn = Fake.probe, .wake = noWake, .result = .no_reply };
    job.done.store(true, .release);
    monitor.job = job;
    try std.testing.expect(monitor.tick(target, 2000, noWake).needs_rebuild);
    var text: [64]u8 = undefined;
    try std.testing.expectEqualStrings("RTT —", monitor.label(&text));
    _ = monitor.tick(target, INTERVAL_MS, noWake);
    try std.testing.expect(monitor.job != null);
    try finishJob(&monitor, target, INTERVAL_MS);
    try std.testing.expectEqualStrings("RTT <1 ms", monitor.label(&text));
}

test "latency monitor cancels an in-flight probe on session switch and shutdown" {
    const Fake = struct {
        fn probe(_: std.mem.Allocator, _: []const u8, cancel: *const process_runner.CancelToken) ping.Result {
            while (!cancel.isCancelled()) std.Thread.sleep(std.time.ns_per_ms);
            // Even a late successful result must be discarded after a switch.
            return .{ .value = .{ .milliseconds = 99 } };
        }
    };
    var monitor = Monitor{ .allocator = std.testing.allocator, .probe_fn = Fake.probe };
    defer monitor.deinit();
    const conn = connection.SshConnection.fromParts(.{ .user = "test", .host = "example.org" });
    const first = Target.fromConnection(1, &conn);
    const second = Target.fromConnection(2, &conn);
    _ = monitor.toggle();
    _ = monitor.tick(first, 0, noWake);
    try std.testing.expect(monitor.job != null);
    try std.testing.expect(monitor.tick(second, 1, noWake).needs_rebuild);
    const deadline = std.time.milliTimestamp() + 2000;
    while (monitor.job.?.target.session == first.session and std.time.milliTimestamp() < deadline) {
        _ = monitor.tick(second, 1, noWake);
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try std.testing.expectEqual(second.session, monitor.job.?.target.session);
    try std.testing.expectEqual(Reading.measuring, monitor.reading);
    // deinit must cancel and join the second worker without leaking its job.
}

fn finishJob(monitor: *Monitor, target: Target, now_ms: i64) !void {
    const deadline = std.time.milliTimestamp() + 2000;
    while (monitor.job != null and std.time.milliTimestamp() < deadline) {
        _ = monitor.tick(target, now_ms, noWake);
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(monitor.job == null);
}

test "network proxy route is not measured using a misleading direct ping" {
    const route = connection.network_proxy.Config.forHelper(.socks5, "127.0.0.1", "7897", "helper").?;
    const conn = connection.SshConnection.fromParts(.{ .user = "alice", .host = "host.test", .network_proxy = route });
    try std.testing.expect(Target.fromConnection(1, &conn).via_jump);
}
