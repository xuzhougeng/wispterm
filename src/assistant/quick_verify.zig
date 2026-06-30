//! Async DeepSeek API-key verification for the Quick Configure AI overlay.
//! The worker thread does ONLY the network call + records into the
//! non-threadlocal channel below + calls the injected wake callback. It never
//! touches overlay state (that is threadlocal to the UI thread). The main loop
//! drains the result with `take()`.
const std = @import("std");

pub const Outcome = enum { ok, invalid_key, network_error };

pub fn classify(status: u16) Outcome {
    return switch (status) {
        200 => .ok,
        401, 403 => .invalid_key,
        else => .network_error,
    };
}

// --- Non-threadlocal worker<->main channel (the ONLY shared cross-thread state) ---
var g_mutex: std.Thread.Mutex = .{};
var g_inflight: bool = false;
var g_done: bool = false;
var g_outcome: Outcome = .network_error;

fn beginInflight() bool {
    g_mutex.lock();
    defer g_mutex.unlock();
    if (g_inflight) return false;
    g_inflight = true;
    g_done = false;
    return true;
}

fn record(outcome: Outcome) void {
    g_mutex.lock();
    defer g_mutex.unlock();
    g_outcome = outcome;
    g_done = true;
    g_inflight = false;
}

/// Main thread: consume a finished result exactly once; null if none/still running.
pub fn take() ?Outcome {
    g_mutex.lock();
    defer g_mutex.unlock();
    if (!g_done) return null;
    g_done = false;
    return g_outcome;
}

pub const WakeFn = *const fn () void;

const Ctx = struct {
    base_url: []const u8, // static caller constant — not freed
    key: []u8, // heap copy owned by the worker
    wake: WakeFn,
};

fn verify(base_url: []const u8, api_key: []const u8) Outcome {
    const a = std.heap.page_allocator; // ponytail: page_allocator (no libc dep needed for fast-test suite); c_allocator works in full app
    const endpoint = std.fmt.allocPrint(a, "{s}/models", .{base_url}) catch return .network_error;
    defer a.free(endpoint);
    const bearer = std.fmt.allocPrint(a, "Bearer {s}", .{api_key}) catch return .network_error;
    defer a.free(bearer);

    var client: std.http.Client = .{ .allocator = a, .write_buffer_size = 16384 };
    defer client.deinit();
    var sink: std.Io.Writer.Allocating = .init(a);
    defer sink.deinit();

    const result = client.fetch(.{
        .location = .{ .url = endpoint },
        .method = .GET,
        .headers = .{ .authorization = .{ .override = bearer } },
        .response_writer = &sink.writer,
    }) catch return .network_error;

    const code: u16 = @intFromEnum(result.status);
    return classify(code);
}

fn worker(ctx: *Ctx) void {
    defer {
        std.heap.page_allocator.free(ctx.key);
        std.heap.page_allocator.destroy(ctx);
    }
    record(verify(ctx.base_url, ctx.key));
    ctx.wake();
}

/// Main thread: start a background verification. `base_url` must be a static
/// constant (not freed); `api_key` is copied. Returns false if already running.
pub fn start(base_url: []const u8, api_key: []const u8, wake: WakeFn) bool {
    if (!beginInflight()) return false;
    const a = std.heap.page_allocator;
    const key_copy = a.dupe(u8, api_key) catch {
        record(.network_error);
        return true;
    };
    const ctx = a.create(Ctx) catch {
        a.free(key_copy);
        record(.network_error);
        return true;
    };
    ctx.* = .{ .base_url = base_url, .key = key_copy, .wake = wake };
    const thread = std.Thread.spawn(.{}, worker, .{ctx}) catch {
        a.free(key_copy);
        a.destroy(ctx);
        record(.network_error);
        return true;
    };
    thread.detach();
    return true;
}

test "classify maps status codes to outcomes" {
    try std.testing.expectEqual(Outcome.ok, classify(200));
    try std.testing.expectEqual(Outcome.invalid_key, classify(401));
    try std.testing.expectEqual(Outcome.invalid_key, classify(403));
    try std.testing.expectEqual(Outcome.network_error, classify(500));
    try std.testing.expectEqual(Outcome.network_error, classify(0));
}

test "channel: take returns a recorded outcome exactly once, inflight guards" {
    g_mutex.lock();
    g_inflight = false;
    g_done = false;
    g_mutex.unlock();

    try std.testing.expect(take() == null);
    try std.testing.expect(beginInflight());
    try std.testing.expect(!beginInflight()); // already in flight
    record(.ok);
    try std.testing.expectEqual(Outcome.ok, take().?);
    try std.testing.expect(take() == null); // consumed
}
