//! Background subscription sign-in for the AI profile form.
//! The worker thread only talks to `client.zig` and the two callbacks
//! (open the verification page, wake the UI). It does not touch overlay state.
const std = @import("std");
const client = @import("client.zig");
const codec = @import("codec.zig");
const store = @import("store.zig");

pub const Phase = enum { idle, waiting, done, failed };

pub const Row = struct {
    phase: Phase = .idle,
    code: [48]u8 = undefined,
    code_len: usize = 0,
    detail: [96]u8 = undefined,
    detail_len: usize = 0,
    has_credential: bool = false,
};

const Job = struct {
    provider: codec.Provider,
    generation: u64,
    wake: *const fn () void,
    open: *const fn ([]const u8) void,
};

var g_lock: std.Thread.Mutex = .{};
var g_inflight: bool = false;
var g_generation: u64 = 0;
var g_cancel: bool = false;
var g_provider: codec.Provider = .codex;
var g_phase: Phase = .idle;
var g_code: [48]u8 = undefined;
var g_code_len: usize = 0;
var g_detail: [96]u8 = undefined;
var g_detail_len: usize = 0;

pub fn row(provider: codec.Provider) Row {
    g_lock.lock();
    defer g_lock.unlock();
    var out = Row{ .has_credential = false };
    out.has_credential = store.has(provider);
    if (g_provider != provider) {
        out.phase = if (out.has_credential) .done else .idle;
        return out;
    }
    out.phase = g_phase;
    out.code_len = @min(g_code_len, out.code.len);
    @memcpy(out.code[0..out.code_len], g_code[0..out.code_len]);
    out.detail_len = @min(g_detail_len, out.detail.len);
    @memcpy(out.detail[0..out.detail_len], g_detail[0..out.detail_len]);
    if (out.phase == .done) out.has_credential = true;
    return out;
}

pub fn start(provider: codec.Provider, wake: *const fn () void, open: *const fn ([]const u8) void) bool {
    g_lock.lock();
    if (g_inflight) {
        g_lock.unlock();
        return false;
    }
    g_inflight = true;
    g_cancel = false;
    g_generation += 1;
    g_provider = provider;
    g_phase = .waiting;
    g_code_len = 0;
    g_detail_len = 0;
    const generation = g_generation;
    g_lock.unlock();

    const job = std.heap.page_allocator.create(Job) catch {
        finish(.failed, provider, generation);
        wake();
        return true;
    };
    job.* = .{ .provider = provider, .generation = generation, .wake = wake, .open = open };
    const thread = std.Thread.spawn(.{}, worker, .{job}) catch {
        std.heap.page_allocator.destroy(job);
        finish(.failed, provider, generation);
        wake();
        return true;
    };
    thread.detach();
    return true;
}

pub fn cancel() void {
    g_lock.lock();
    defer g_lock.unlock();
    g_cancel = true;
}

fn worker(job: *Job) void {
    defer std.heap.page_allocator.destroy(job);
    const prompt = client.Prompt{
        .ctx = job,
        .show = show,
        .cancelled = cancelled,
        .note = note,
    };
    const cred = client.login(std.heap.page_allocator, job.provider, prompt) catch |err| {
        if (err == error.Canceled or cancelled(job)) {
            finish(.idle, job.provider, job.generation);
        } else {
            finish(.failed, job.provider, job.generation);
        }
        job.wake();
        return;
    };
    defer cred.deinit(std.heap.page_allocator);
    store.put(job.provider, cred.access, cred.refresh, cred.expires_ms) catch {
        finish(.failed, job.provider, job.generation);
        job.wake();
        return;
    };
    finish(.done, job.provider, job.generation);
    job.wake();
}

fn show(ctx: *anyopaque, url: []const u8, user_code: []const u8) void {
    const job: *Job = @ptrCast(@alignCast(ctx));
    g_lock.lock();
    if (job.generation == g_generation) {
        g_phase = .waiting;
        g_code_len = @min(user_code.len, g_code.len);
        @memcpy(g_code[0..g_code_len], user_code[0..g_code_len]);
    }
    g_lock.unlock();
    job.open(url);
    job.wake();
}

fn note(ctx: *anyopaque, message: []const u8) void {
    const job: *Job = @ptrCast(@alignCast(ctx));
    g_lock.lock();
    defer g_lock.unlock();
    if (job.generation != g_generation) return;
    g_detail_len = @min(message.len, g_detail.len);
    @memcpy(g_detail[0..g_detail_len], message[0..g_detail_len]);
}

fn cancelled(ctx: *anyopaque) bool {
    const job: *Job = @ptrCast(@alignCast(ctx));
    g_lock.lock();
    defer g_lock.unlock();
    return g_cancel or job.generation != g_generation;
}

fn finish(phase: Phase, provider: codec.Provider, generation: u64) void {
    g_lock.lock();
    defer g_lock.unlock();
    if (generation != g_generation) return;
    g_inflight = false;
    g_provider = provider;
    g_phase = phase;
    if (phase != .waiting) g_code_len = 0;
    if (phase != .failed) g_detail_len = 0;
}
