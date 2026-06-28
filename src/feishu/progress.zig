//! Feishu AI-reply progress driver (M2.9).
//!
//! Single worker thread polls the AI transcript after a message is routed,
//! detects completion via chatops/reply_progress.progress(), and sends the
//! final reply (plus one-shot approval/question prompts) back to the Feishu
//! chat via the controller's SendSink.
//!
//! Design: single worker + episode model. A new episode (beginEpisode) bumps
//! `generation`, which the running worker sees on its next poll step and uses
//! to self-cancel the old episode before starting the new one. This avoids
//! spawning per-episode threads and keeps stop/join simple: one thread, one
//! join in stop().
//!
//! Thread safety: episode fields are guarded by `mu`; stop_requested is
//! atomic. The worker thread only reads episode state under `mu`, and
//! beginEpisode/cancelEpisode only write under `mu`.
//!
//! Security: SendSink is called with chat_id only — no token/secret is logged
//! or stored here.

const std = @import("std");
const reply_progress = @import("../chatops/reply_progress.zig");
const controller = @import("controller.zig");

const log = std.log.scoped(.feishu_progress);

/// Poll step: 200ms — short enough that stop() and generation changes are
/// observed quickly. Steps accumulate to reach the 3s poll interval.
const STEP_MS: u64 = 200;
/// Number of steps between actual transcript polls (~3s).
const POLL_STEPS: u64 = 15; // 15 × 200ms = 3000ms
/// 30-minute episode deadline in ms.
const EPISODE_DEADLINE_MS: u64 = 30 * 60 * 1000;

// ---------------------------------------------------------------------------
// Pure decide — no threads, no I/O; fully unit-testable
// ---------------------------------------------------------------------------

pub const ActionTag = enum { send_final, send_approval_prompt, send_question_prompt, none };

pub const Action = union(ActionTag) {
    /// Final reply text (episode ends after sending).
    send_final: []const u8,
    /// Approval prompt text.
    send_approval_prompt: []const u8,
    /// Question prompt text.
    send_question_prompt: []const u8,
    /// Nothing to do this poll.
    none: void,
};

/// Tracks which once-per-episode announcements have been made.
pub const Announced = struct {
    approval: bool = false,
    question: bool = false,

    /// Reset when the signal clears, so a later approval/question re-announces.
    pub fn resetApproval(self: *Announced) void {
        self.approval = false;
    }
    pub fn resetQuestion(self: *Announced) void {
        self.question = false;
    }
};

/// Pure: given a Progress snapshot and mutable announce state, decide what
/// action to take this poll. Text slices borrow from `p` (borrows from
/// `current` transcript — caller must not free `current` while using the
/// returned text). Approval/question messages are composed by the worker
/// using its own allocator; this function just returns the raw text from `p`.
pub fn decide(p: reply_progress.Progress, announced: *Announced) Action {
    // approval: live-state signal, announce once while it persists.
    if (p.needs_approval) {
        if (!announced.approval) {
            announced.approval = true;
            // Build the prompt text from approval fields.
            // We return the raw fields; the worker allocPrint's the full prompt.
            // ponytail: return a tagged union so the worker knows what to format.
            return .{ .send_approval_prompt = p.approval_command };
        }
        return .none;
    } else {
        announced.resetApproval();
    }

    // question: same pattern.
    if (p.needs_question) {
        if (!announced.question) {
            announced.question = true;
            return .{ .send_question_prompt = p.question_text };
        }
        return .none;
    } else {
        announced.resetQuestion();
    }

    // done: send final reply.
    if (p.done) {
        return .{ .send_final = p.text };
    }

    return .none;
}

// ---------------------------------------------------------------------------
// Episode snapshot (held under mu)
// ---------------------------------------------------------------------------

const Episode = struct {
    chat_id: []u8 = &.{},
    baseline: []u8 = &.{},
    generation: u64 = 0,
    /// Monotonic ms timestamp (from std.time.milliTimestamp) at which this
    /// episode expires.
    deadline_ms: i64 = 0,
    active: bool = false,

    fn deinit(self: *Episode, allocator: std.mem.Allocator) void {
        if (self.chat_id.len != 0) allocator.free(self.chat_id);
        if (self.baseline.len != 0) allocator.free(self.baseline);
        self.* = .{};
    }
};

// ---------------------------------------------------------------------------
// ProgressWorker
// ---------------------------------------------------------------------------

pub const ProgressWorker = struct {
    allocator: std.mem.Allocator,
    control: @import("../chatops/control.zig").Control,
    send_sink: controller.SendSink,

    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    mu: std.Thread.Mutex = .{},
    episode: Episode = .{},
    // Transcript mutex mirrors weixin's transcript_mutex: protects
    // latestTranscript() against concurrent controller writes if any.
    // ponytail: latestTranscript is already safe on this vtable; kept for
    // symmetry with the weixin poller pattern.
    transcript_mu: std.Thread.Mutex = .{},

    /// Start the single worker thread. Safe to call once; idempotent if
    /// already running.
    pub fn start(self: *ProgressWorker) !void {
        if (self.thread != null) return;
        self.stop_requested.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, workerMain, .{self});
        log.info("progress worker started", .{});
    }

    /// Signal stop and join. Blocks until the worker exits.
    pub fn stop(self: *ProgressWorker) void {
        self.stop_requested.store(true, .release);
        // Bump generation so the worker's inner poll loop notices immediately.
        {
            self.mu.lock();
            self.episode.generation +%= 1;
            self.episode.active = false;
            self.mu.unlock();
        }
        if (self.thread) |th| {
            th.join();
            self.thread = null;
        }
        // Free any leftover episode state after the worker has exited.
        {
            self.mu.lock();
            defer self.mu.unlock();
            self.episode.deinit(self.allocator);
        }
        log.info("progress worker stopped", .{});
    }

    /// Called by the controller when a message is routed with
    /// expect_ai_progress=true. `baseline` is the transcript snapshot taken
    /// BEFORE routing (caller owns it and may free after this call returns).
    /// `chat_id` is also caller-owned.
    pub fn beginEpisode(self: *ProgressWorker, chat_id: []const u8, baseline: []const u8) !void {
        if (self.stop_requested.load(.acquire)) return;

        const chat_id_owned = try self.allocator.dupe(u8, chat_id);
        errdefer self.allocator.free(chat_id_owned);
        const baseline_owned = try self.allocator.dupe(u8, baseline);
        errdefer self.allocator.free(baseline_owned);

        const deadline = std.time.milliTimestamp() + @as(i64, EPISODE_DEADLINE_MS);

        self.mu.lock();
        defer self.mu.unlock();

        // Free old episode resources.
        self.episode.deinit(self.allocator);

        self.episode = .{
            .chat_id = chat_id_owned,
            .baseline = baseline_owned,
            .generation = self.episode.generation +% 1,
            .deadline_ms = deadline,
            .active = true,
        };

        log.debug("progress: beginEpisode chat_id_len={d} baseline_bytes={d} gen={d}", .{
            chat_id_owned.len, baseline_owned.len, self.episode.generation,
        });
    }

    /// Cancel the current episode (e.g. on /stop). The worker notices the
    /// generation change on its next step.
    pub fn cancelEpisode(self: *ProgressWorker) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.episode.generation +%= 1;
        self.episode.active = false;
        log.debug("progress: cancelEpisode", .{});
    }

    // ---------------------------------------------------------------------------
    // Worker thread
    // ---------------------------------------------------------------------------

    fn workerMain(self: *ProgressWorker) void {
        while (!self.stop_requested.load(.acquire)) {
            self.runEpisodeLoop();
        }
    }

    /// Runs one episode to completion (or stop/cancel). Returns when the
    /// episode finishes, is cancelled, or stop is requested.
    fn runEpisodeLoop(self: *ProgressWorker) void {
        // Wait until an episode becomes active.
        // Short sleep to avoid spinning.
        if (!self.hasActiveEpisode()) {
            std.Thread.sleep(STEP_MS * std.time.ns_per_ms);
            return;
        }

        // Snapshot the current episode under mu.
        const snap = self.snapshotEpisode() orelse return;
        const gen = snap.generation;

        var announced = Announced{};
        var steps_since_poll: u64 = 0;

        log.debug("progress: episode started gen={d} chat_id_len={d}", .{ gen, snap.chat_id.len });

        while (!self.stop_requested.load(.acquire)) {
            std.Thread.sleep(STEP_MS * std.time.ns_per_ms);
            steps_since_poll += 1;

            // Check for cancellation (new episode or stop_followup).
            const current_gen = self.currentGeneration();
            if (current_gen != gen) {
                log.debug("progress: episode cancelled gen_old={d} gen_new={d}", .{ gen, current_gen });
                self.allocator.free(snap.chat_id);
                self.allocator.free(snap.baseline);
                return;
            }

            // Check deadline.
            if (std.time.milliTimestamp() > snap.deadline_ms) {
                log.debug("progress: episode deadline gen={d}", .{gen});
                self.allocator.free(snap.chat_id);
                self.allocator.free(snap.baseline);
                self.deactivateEpisode(gen);
                return;
            }

            // Poll at ~3s intervals.
            if (steps_since_poll < POLL_STEPS) continue;
            steps_since_poll = 0;

            // Get transcript snapshot under transcript_mu.
            self.transcript_mu.lock();
            const current = self.control.latestTranscript();
            const p = reply_progress.progress(snap.baseline, current);
            self.transcript_mu.unlock();

            const action = decide(p, &announced);
            switch (action) {
                .send_approval_prompt => |cmd| {
                    self.sendApprovalPrompt(snap.chat_id, p.approval_tool, cmd) catch |err| {
                        log.warn("progress: send approval prompt failed: {s}", .{@errorName(err)});
                    };
                },
                .send_question_prompt => |q| {
                    self.sendQuestionPrompt(snap.chat_id, q) catch |err| {
                        log.warn("progress: send question prompt failed: {s}", .{@errorName(err)});
                    };
                },
                .send_final => |text| {
                    // Re-check generation before sending to avoid stale final reply.
                    if (self.currentGeneration() != gen) {
                        log.debug("progress: stale final reply discarded gen={d}", .{gen});
                        self.allocator.free(snap.chat_id);
                        self.allocator.free(snap.baseline);
                        return;
                    }
                    log.debug("progress: sending final reply gen={d} bytes={d}", .{ gen, text.len });
                    self.send_sink.send(self.send_sink.ctx, self.allocator, snap.chat_id, text) catch |err| {
                        log.warn("progress: send final failed: {s}", .{@errorName(err)});
                    };
                    self.allocator.free(snap.chat_id);
                    self.allocator.free(snap.baseline);
                    self.deactivateEpisode(gen);
                    return;
                },
                .none => {},
            }
        }

        self.allocator.free(snap.chat_id);
        self.allocator.free(snap.baseline);
    }

    // ---------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------

    fn hasActiveEpisode(self: *ProgressWorker) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return self.episode.active;
    }

    /// Returns a heap-owned copy of chat_id and baseline for the worker to use
    /// without holding the mutex across I/O. Returns null if no active episode.
    const EpisodeSnap = struct {
        chat_id: []u8,
        baseline: []u8,
        generation: u64,
        deadline_ms: i64,
    };

    fn snapshotEpisode(self: *ProgressWorker) ?EpisodeSnap {
        self.mu.lock();
        defer self.mu.unlock();
        if (!self.episode.active) return null;
        const chat_id = self.allocator.dupe(u8, self.episode.chat_id) catch return null;
        const baseline = self.allocator.dupe(u8, self.episode.baseline) catch {
            self.allocator.free(chat_id);
            return null;
        };
        return .{
            .chat_id = chat_id,
            .baseline = baseline,
            .generation = self.episode.generation,
            .deadline_ms = self.episode.deadline_ms,
        };
    }

    fn currentGeneration(self: *ProgressWorker) u64 {
        self.mu.lock();
        defer self.mu.unlock();
        return self.episode.generation;
    }

    fn deactivateEpisode(self: *ProgressWorker, gen: u64) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.episode.generation == gen) {
            self.episode.active = false;
        }
    }

    fn sendApprovalPrompt(self: *ProgressWorker, chat_id: []const u8, tool: []const u8, cmd: []const u8) !void {
        const subject = if (cmd.len != 0) cmd else tool;
        const clipped = clipUtf8(subject, 400);
        const text = try std.fmt.allocPrint(
            self.allocator,
            "⚠️ 副驾需要你确认是否执行：\n{s}\n\n回复 Y 同意 / N 拒绝。",
            .{clipped},
        );
        defer self.allocator.free(text);
        try self.send_sink.send(self.send_sink.ctx, self.allocator, chat_id, text);
    }

    fn sendQuestionPrompt(self: *ProgressWorker, chat_id: []const u8, question_text: []const u8) !void {
        const clipped = clipUtf8(question_text, 1200);
        const text = try std.fmt.allocPrint(
            self.allocator,
            "❓ 副驾想请你选择：\n{s}\n\n回复序号，或直接输入你的答案。",
            .{clipped},
        );
        defer self.allocator.free(text);
        try self.send_sink.send(self.send_sink.ctx, self.allocator, chat_id, text);
    }
};

/// Clips `s` to at most `max` bytes without splitting a UTF-8 codepoint.
fn clipUtf8(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and (s[end] & 0xC0) == 0x80) : (end -= 1) {}
    return s[0..end];
}

// ---------------------------------------------------------------------------
// Tests for the pure `decide` function
// ---------------------------------------------------------------------------

const t = std.testing;

test "decide: done returns send_final with reply text" {
    const p = reply_progress.Progress{
        .done = true,
        .text = "the answer",
    };
    var ann = Announced{};
    const action = decide(p, &ann);
    try t.expect(action == .send_final);
    try t.expectEqualStrings("the answer", action.send_final);
}

test "decide: needs_approval first call returns send_approval_prompt" {
    const p = reply_progress.Progress{
        .needs_approval = true,
        .approval_tool = "terminal_repl_exec",
        .approval_command = "rm -rf /tmp/x",
    };
    var ann = Announced{};
    const action = decide(p, &ann);
    try t.expect(action == .send_approval_prompt);
    try t.expect(ann.approval);
}

test "decide: needs_approval second call returns none (already announced)" {
    const p = reply_progress.Progress{
        .needs_approval = true,
        .approval_tool = "terminal_repl_exec",
        .approval_command = "rm -rf /tmp/x",
    };
    var ann = Announced{};
    _ = decide(p, &ann); // first: announces
    const action2 = decide(p, &ann); // second: already announced
    try t.expect(action2 == .none);
}

test "decide: approval clears when signal gone, re-announces on next" {
    var ann = Announced{};
    // approval appears
    _ = decide(.{ .needs_approval = true, .approval_tool = "t", .approval_command = "c" }, &ann);
    try t.expect(ann.approval);
    // approval clears (no needs_approval)
    _ = decide(.{}, &ann);
    try t.expect(!ann.approval);
    // approval appears again → should re-announce
    const action = decide(.{ .needs_approval = true, .approval_tool = "t2", .approval_command = "c2" }, &ann);
    try t.expect(action == .send_approval_prompt);
}

test "decide: needs_question first call returns send_question_prompt" {
    const p = reply_progress.Progress{
        .needs_question = true,
        .question_text = "Which db?\n1. Postgres\n2. SQLite",
    };
    var ann = Announced{};
    const action = decide(p, &ann);
    try t.expect(action == .send_question_prompt);
    try t.expect(ann.question);
}

test "decide: needs_question second call returns none" {
    const p = reply_progress.Progress{
        .needs_question = true,
        .question_text = "Which db?",
    };
    var ann = Announced{};
    _ = decide(p, &ann);
    const action2 = decide(p, &ann);
    try t.expect(action2 == .none);
}

test "decide: in-progress (not done, no approval, no question) returns none" {
    const p = reply_progress.Progress{
        .done = false,
        .text = "还在处理中，等待 AI 回复。",
    };
    var ann = Announced{};
    const action = decide(p, &ann);
    try t.expect(action == .none);
}
