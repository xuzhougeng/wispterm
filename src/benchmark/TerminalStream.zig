//! TerminalStream benchmark case: feed a synthetic VT byte stream through
//! ghostty-vt's `Stream.nextSlice` and measure parser+screen throughput in
//! MB/s. This is the WispTerm counterpart to Ghostty's
//! `src/benchmark/TerminalStream.zig` — same idea (synthetic bytes through the
//! VT state machine), adapted to our `ghostty_vt` import name.
//!
//! Setup pre-generates a deterministic payload (printable lines + CRLF, with a
//! sprinkling of SGR/CSI so the parser's escape path is exercised); each step
//! runs one full payload through `nextSlice`. Setup/teardown are excluded from
//! the timed window by `Benchmark.run`.

const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const Benchmark = @import("Benchmark.zig");

const Handler = @typeInfo(@TypeOf(ghostty_vt.Terminal.vtHandler)).@"fn".return_type.?;
const Stream = ghostty_vt.Stream(Handler);

pub const Spec = struct {
    cols: usize = 120,
    rows: usize = 40,
    /// Bytes of synthetic VT generated in setup and fed per step.
    payload_bytes: usize = 64 * 1024,
};

pub const TerminalStream = @This();

allocator: std.mem.Allocator,
terminal: ghostty_vt.Terminal,
handler: Handler,
stream: Stream,
payload: []u8,
spec: Spec,

/// Heap-allocate the case so `&self.terminal` is stable for the handler.
pub fn create(allocator: std.mem.Allocator, spec: Spec) !*TerminalStream {
    const self = try allocator.create(TerminalStream);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .terminal = undefined,
        .handler = undefined,
        .stream = undefined,
        .payload = &.{},
        .spec = spec,
    };
    self.terminal = try ghostty_vt.Terminal.init(allocator, .{
        .cols = @intCast(spec.cols),
        .rows = @intCast(spec.rows),
    });
    errdefer self.terminal.deinit(allocator);

    self.handler = self.terminal.vtHandler();
    self.stream = Stream.initAlloc(self.terminal.screens.active.alloc, self.handler);
    return self;
}

pub fn destroy(self: *TerminalStream) void {
    self.stream.deinit();
    self.handler.deinit();
    self.terminal.deinit(self.allocator);
    if (self.payload.len > 0) self.allocator.free(self.payload);
    self.allocator.destroy(self);
}

pub fn benchmark(self: *TerminalStream) Benchmark {
    return .init(self, .{
        .stepFn = step,
        .setupFn = setup,
        .teardownFn = teardown,
    });
}

/// Bytes processed per step — used by the CLI to convert iterations → MB/s.
pub fn bytesPerStep(self: *const TerminalStream) usize {
    return self.spec.payload_bytes;
}

fn setup(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalStream = @ptrCast(@alignCast(ptr));
    self.payload = generatePayload(self.allocator, self.spec) catch return error.BenchmarkFailed;
}

fn teardown(ptr: *anyopaque) void {
    const self: *TerminalStream = @ptrCast(@alignCast(ptr));
    if (self.payload.len > 0) {
        self.allocator.free(self.payload);
        self.payload = &.{};
    }
}

fn step(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalStream = @ptrCast(@alignCast(ptr));
    // nextSlice returns void on this ghostty snapshot (see AGENTS.md): no try.
    self.stream.nextSlice(self.payload);
}

/// Build a deterministic payload: mostly printable lines of width `cols` + CRLF,
/// with one SGR sequence per line so the escape-sequence parser path is hit.
/// Delegates to the shared `payload.zig` generator so the CPU CLI and the
/// in-app GPU benchmark feed identical scroll-flood content.
fn generatePayload(allocator: std.mem.Allocator, spec: Spec) ![]u8 {
    return @import("payload.zig").generateScrollFlood(allocator, spec.cols, spec.payload_bytes);
}

test "TerminalStream: generatePayload produces requested order of bytes" {
    const allocator = std.testing.allocator;
    const spec: Spec = .{ .cols = 10, .rows = 4, .payload_bytes = 256 };
    const payload = try generatePayload(allocator, spec);
    defer allocator.free(payload);
    // Roughly payload_bytes (± a line); never wildly over.
    try std.testing.expect(payload.len >= 128 and payload.len <= 512);
    // Contains a CRLF and an SGR escape.
    try std.testing.expect(std.mem.indexOf(u8, payload, "\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\x1b[3") != null);
}

test "TerminalStream: create/destroy round-trips without leaking" {
    const allocator = std.testing.allocator;
    const self = try TerminalStream.create(allocator, .{ .cols = 20, .rows = 4, .payload_bytes = 512 });
    // Run setup so the payload is allocated, then teardown+destroy frees it.
    const bench = self.benchmark();
    _ = try bench.run(.once);
    self.destroy();
}
