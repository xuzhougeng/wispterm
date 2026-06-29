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
// Pure planPoll — no threads, no I/O; fully unit-testable
// ---------------------------------------------------------------------------

/// Per-poll operations decided by planPoll. All slices borrow from caller args.
pub const PollOps = struct {
    /// Content to stream to the card (null = no update this poll).
    stream: ?[]const u8 = null,
    /// True when the episode is done: caller should close card via defer and return.
    finalize: bool = false,
    /// Text to send via send_sink as an independent message (approval/question prompt).
    prompt_text: ?[]const u8 = null,
};

/// Pure: given the current poll's action tag, action text, rendered md, and the
/// last-pushed md, decide which operations to perform. Slices borrow from arguments.
fn planPoll(action_tag: ActionTag, action_text: []const u8, md: []const u8, last_md: []const u8) PollOps {
    const md_changed = !std.mem.eql(u8, md, last_md);
    switch (action_tag) {
        .send_final => return .{
            .stream = md,
            .finalize = true,
        },
        .send_approval_prompt, .send_question_prompt => return .{
            .prompt_text = action_text,
            .stream = if (md_changed) md else null,
        },
        .none => return .{
            .stream = if (md_changed) md else null,
        },
    }
}

// ---------------------------------------------------------------------------
// ProgressWorker
// ---------------------------------------------------------------------------

pub const ProgressWorker = struct {
    allocator: std.mem.Allocator,
    control: @import("../chatops/control.zig").Control,
    send_sink: controller.SendSink,
    card_sink: controller.CardSink,

    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    mu: std.Thread.Mutex = .{},
    episode: Episode = .{},
    // Serializes ALL latestTranscript() callers in this channel. latestTranscript
    // returns a single process-global buffer (chatops_bridge
    // g_chatops_transcript_owned) that the next caller frees + overwrites, so the
    // returned slice is only valid until the next call. Every caller must hold
    // this mutex from latestTranscript() until it has DUPED what it needs out of
    // the returned slice. The controller's baseline capture (onEvent) locks this
    // SAME mutex — otherwise a route-path latestTranscript on the longconn thread
    // would free the buffer the worker is reading. (Mirrors weixin transcript_mutex,
    // which wraps both its baseline and followup-poll call sites.)
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
            // TODO(M4): if stop() is called on the UI thread while the worker is
            // blocked in a synchronous latestTranscript()→sendMessage round-trip,
            // this join can stall. Shared with the weixin poller's followup
            // thread; needs a cancel-synchronous-io path (see poller.zig
            // stopForProcessExit). Acceptable for M2.
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

        // Create streaming card at episode start; fall back to text if it fails.
        const card_id: ?[]u8 = self.card_sink.create(self.card_sink.ctx, self.allocator, "处理中…") catch |err| blk: {
            log.warn("progress: card create failed: {s}; falling back to text", .{@errorName(err)});
            break :blk null;
        };
        // Send card to chat; capture message_id for finalize-patch (close+PATCH to button-less card).
        // message_id=null if send fails or card_id=null (text fallback); skip patch in that case.
        const message_id: ?[]u8 = if (card_id) |cid| blk: {
            break :blk self.card_sink.send(self.card_sink.ctx, self.allocator, snap.chat_id, cid) catch |err| {
                log.warn("progress: card send failed: {s}", .{@errorName(err)});
                break :blk null;
            };
        } else null;
        var seq: i64 = 1;
        var last_md: []u8 = &.{};
        // finalized=true when explicit finalize/cancel already called close+patch; defer skips close.
        var finalized: bool = false;
        defer if (last_md.len != 0) self.allocator.free(last_md);
        defer if (message_id) |mid| self.allocator.free(mid);
        // Unified cleanup: explicit finalize/cancel set finalized=true (close done there already).
        // Fallback paths (deadline/stop-loop/stale) enter with finalized=false → close here.
        // free(card_id) and free(message_id) always run via their own defers above.
        // Invariants: close exactly once, free exactly once per pointer, seq monotonic.
        defer if (card_id) |cid| {
            if (!finalized) {
                self.card_sink.close(self.card_sink.ctx, self.allocator, cid, seq) catch {};
            }
            self.allocator.free(cid);
        };

        while (!self.stop_requested.load(.acquire)) {
            std.Thread.sleep(STEP_MS * std.time.ns_per_ms);
            steps_since_poll += 1;

            // Check for cancellation (new episode or stop_followup).
            const current_gen = self.currentGeneration();
            if (current_gen != gen) {
                log.debug("progress: episode cancelled gen_old={d} gen_new={d}", .{ gen, current_gen });
                // cancel path: close streaming first, then patch to button-less resolved card.
                // Spike-confirmed order: close → patch. Set finalized=true so defer skips close.
                if (card_id) |cid| {
                    self.card_sink.close(self.card_sink.ctx, self.allocator, cid, seq) catch |err| {
                        log.warn("progress: cancel close failed: {s}", .{@errorName(err)});
                    };
                    finalized = true;
                    if (message_id) |mid| {
                        var arena = std.heap.ArenaAllocator.init(self.allocator);
                        defer arena.deinit();
                        const card_json = @import("card.zig").buildResolvedCard(arena.allocator(), "⏹ 已停止") catch null;
                        if (card_json) |cj| {
                            self.card_sink.updateMessage(self.card_sink.ctx, self.allocator, mid, cj) catch |err| {
                                log.warn("progress: cancel updateMessage failed: {s}", .{@errorName(err)});
                            };
                        }
                    }
                }
                self.allocator.free(snap.chat_id);
                self.allocator.free(snap.baseline);
                return; // defer: free card_id + free message_id + free last_md (no close: finalized)
            }

            // Check deadline.
            if (std.time.milliTimestamp() > snap.deadline_ms) {
                log.debug("progress: episode deadline gen={d}", .{gen});
                self.allocator.free(snap.chat_id);
                self.allocator.free(snap.baseline);
                self.deactivateEpisode(gen);
                return; // defer: close card + free card_id + free last_md
            }

            // Poll at ~3s intervals.
            if (steps_since_poll < POLL_STEPS) continue;
            steps_since_poll = 0;

            // Poll the transcript and decide, then materialize an OWNED copy of
            // any text the action needs — all WHILE holding transcript_mu. The
            // detector's text fields borrow from `current`, which is a single
            // process-global buffer (chatops_bridge g_chatops_transcript_owned)
            // that the NEXT latestTranscript() caller frees and overwrites. So
            // nothing borrowed from `current`/`p` may survive the unlock; we
            // dupe before unlocking and free after sending. (Mirrors weixin's
            // allocProgressText.) The approval/question prompt is also built
            // here so its formatted text owns its bytes.
            // renderProgress is also called under transcript_mu (reads global transcript buffer).
            var owned = OwnedAction{ .tag = .none };
            var md: []u8 = &.{};
            {
                self.transcript_mu.lock();
                defer self.transcript_mu.unlock();
                const current = self.control.latestTranscript();
                const p = reply_progress.progress(snap.baseline, current);
                owned = self.materialize(decide(p, &announced), p) catch OwnedAction{ .tag = .none };
                // renderProgress returns owned; read it under the same lock (it reads `current`).
                md = reply_progress.renderProgress(self.allocator, snap.baseline, current) catch &.{};
            }
            defer if (owned.text.len != 0) self.allocator.free(owned.text);
            // md is freed at end of this poll iteration unless it becomes the new last_md.

            if (card_id == null) {
                // Card creation failed: fall back to existing text behavior for all paths.
                switch (owned.tag) {
                    .send_approval_prompt, .send_question_prompt => {
                        if (owned.text.len != 0) {
                            self.send_sink.send(self.send_sink.ctx, self.allocator, snap.chat_id, owned.text) catch |err| {
                                log.warn("progress: send prompt failed: {s}", .{@errorName(err)});
                            };
                        }
                    },
                    .send_final => {
                        // Re-check generation before sending to avoid stale final reply.
                        if (self.currentGeneration() != gen) {
                            log.debug("progress: stale final reply discarded gen={d}", .{gen});
                            if (md.len != 0) self.allocator.free(md);
                            self.allocator.free(snap.chat_id);
                            self.allocator.free(snap.baseline);
                            return;
                        }
                        if (owned.text.len != 0) {
                            log.debug("progress: sending final reply gen={d} bytes={d}", .{ gen, owned.text.len });
                            self.send_sink.send(self.send_sink.ctx, self.allocator, snap.chat_id, owned.text) catch |err| {
                                log.warn("progress: send final failed: {s}", .{@errorName(err)});
                            };
                        }
                        if (md.len != 0) self.allocator.free(md);
                        self.allocator.free(snap.chat_id);
                        self.allocator.free(snap.baseline);
                        self.deactivateEpisode(gen);
                        return;
                    },
                    .none => {},
                }
                if (md.len != 0) self.allocator.free(md);
            } else {
                // Card path: use planPoll to decide ops.
                const ops = planPoll(owned.tag, owned.text, md, last_md);

                // Send approval/question prompt as independent text message.
                if (ops.prompt_text) |txt| {
                    if (txt.len != 0) {
                        self.send_sink.send(self.send_sink.ctx, self.allocator, snap.chat_id, txt) catch |err| {
                            log.warn("progress: send prompt (card path) failed: {s}", .{@errorName(err)});
                        };
                    }
                }

                // Stream card update if content changed.
                if (ops.stream) |s| {
                    self.card_sink.stream(self.card_sink.ctx, self.allocator, card_id.?, s, seq) catch |err| {
                        log.warn("progress: card stream failed seq={d}: {s}", .{ seq, @errorName(err) });
                    };
                    seq += 1;
                    // Update last_md: dupe the streamed content.
                    if (last_md.len != 0) self.allocator.free(last_md);
                    last_md = self.allocator.dupe(u8, s) catch &.{};
                }

                // Free md unless it was stored as last_md (dupe was taken above).
                if (md.len != 0) self.allocator.free(md);

                if (ops.finalize) {
                    // Re-check generation before finalizing to avoid stale close.
                    if (self.currentGeneration() != gen) {
                        log.debug("progress: stale final (card) discarded gen={d}", .{gen});
                        self.allocator.free(snap.chat_id);
                        self.allocator.free(snap.baseline);
                        return; // defer closes card (finalized=false, fallback path)
                    }
                    log.debug("progress: finalizing card episode gen={d}", .{gen});
                    // Finalize: close streaming first (spike-confirmed order), then patch to resolved card.
                    // owned.text is the clean answer, valid in this poll before its defer-free.
                    if (card_id) |cid| {
                        self.card_sink.close(self.card_sink.ctx, self.allocator, cid, seq) catch |err| {
                            log.warn("progress: finalize close failed: {s}", .{@errorName(err)});
                        };
                        finalized = true;
                        if (message_id) |mid| {
                            var arena = std.heap.ArenaAllocator.init(self.allocator);
                            defer arena.deinit();
                            const answer = if (owned.text.len != 0) owned.text else "处理完成";
                            const card_json = @import("card.zig").buildResolvedCard(arena.allocator(), answer) catch null;
                            if (card_json) |cj| {
                                self.card_sink.updateMessage(self.card_sink.ctx, self.allocator, mid, cj) catch |err| {
                                    log.warn("progress: finalize updateMessage failed: {s}", .{@errorName(err)});
                                };
                            }
                        }
                    }
                    self.allocator.free(snap.chat_id);
                    self.allocator.free(snap.baseline);
                    self.deactivateEpisode(gen);
                    return; // defer: free card_id + message_id + last_md (no close: finalized=true)
                }
            }
        }

        // stop_requested: exit normally, defer handles card close.
        self.allocator.free(snap.chat_id);
        self.allocator.free(snap.baseline);
        // defer: close card + free card_id + free last_md
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

    /// Converts a `decide` Action (whose text borrows from the transient
    /// `current` transcript) into an OwnedAction whose `text` is heap-owned by
    /// self.allocator. MUST be called while transcript_mu is held (the borrowed
    /// `p`/Action slices are only valid then); allocPrint/dupe copy the bytes so
    /// the result outlives the unlock. Caller frees `text` after sending.
    fn materialize(self: *ProgressWorker, action: Action, p: reply_progress.Progress) !OwnedAction {
        switch (action) {
            .send_approval_prompt => {
                const subject = if (p.approval_command.len != 0) p.approval_command else p.approval_tool;
                const clipped = clipUtf8(subject, 400);
                const text = try std.fmt.allocPrint(
                    self.allocator,
                    "⚠️ 副驾需要你确认是否执行：\n{s}\n\n回复 Y 同意 / N 拒绝。",
                    .{clipped},
                );
                return .{ .tag = .send_approval_prompt, .text = text };
            },
            .send_question_prompt => |q| {
                const clipped = clipUtf8(q, 1200);
                const text = try std.fmt.allocPrint(
                    self.allocator,
                    "❓ 副驾想请你选择：\n{s}\n\n回复序号，或直接输入你的答案。",
                    .{clipped},
                );
                return .{ .tag = .send_question_prompt, .text = text };
            },
            .send_final => |final| {
                if (final.len == 0) return .{ .tag = .none };
                return .{ .tag = .send_final, .text = try self.allocator.dupe(u8, final) };
            },
            .none => return .{ .tag = .none },
        }
    }
};

/// An action with heap-owned `text` (copied out of the transient transcript
/// buffer under transcript_mu). `text` is empty for `.none`.
const OwnedAction = struct {
    tag: ActionTag,
    text: []u8 = &.{},
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

// ---------------------------------------------------------------------------
// Tests for the pure `planPoll` function
// ---------------------------------------------------------------------------

test "planPoll: done → stream=md + finalize=true" {
    const ops = planPoll(.send_final, "final text", "answer md", "");
    try t.expect(ops.finalize);
    try t.expect(ops.stream != null);
    try t.expectEqualStrings("answer md", ops.stream.?);
    try t.expect(ops.prompt_text == null);
}

test "planPoll: done → stream uses md even when md==last_md (finalize always streams)" {
    // For send_final we always stream regardless of md==last_md (final frame must go).
    const ops = planPoll(.send_final, "final text", "same md", "same md");
    try t.expect(ops.finalize);
    try t.expect(ops.stream != null);
}

test "planPoll: approval → prompt_text set + stream when md changed" {
    const ops = planPoll(.send_approval_prompt, "approve msg", "new md", "old md");
    try t.expect(ops.prompt_text != null);
    try t.expectEqualStrings("approve msg", ops.prompt_text.?);
    try t.expect(ops.stream != null);
    try t.expectEqualStrings("new md", ops.stream.?);
    try t.expect(!ops.finalize);
}

test "planPoll: approval → no stream when md unchanged" {
    const ops = planPoll(.send_approval_prompt, "approve msg", "same md", "same md");
    try t.expect(ops.prompt_text != null);
    try t.expect(ops.stream == null);
}

test "planPoll: question → prompt_text set + stream when md changed" {
    const ops = planPoll(.send_question_prompt, "question msg", "progress", "");
    try t.expect(ops.prompt_text != null);
    try t.expectEqualStrings("question msg", ops.prompt_text.?);
    try t.expect(ops.stream != null);
}

test "planPoll: none + md changed → only stream, no finalize, no prompt" {
    const ops = planPoll(.none, "", "new content", "old content");
    try t.expect(ops.stream != null);
    try t.expectEqualStrings("new content", ops.stream.?);
    try t.expect(!ops.finalize);
    try t.expect(ops.prompt_text == null);
}

test "planPoll: none + md unchanged → all null (skip API call)" {
    const ops = planPoll(.none, "", "same content", "same content");
    try t.expect(ops.stream == null);
    try t.expect(!ops.finalize);
    try t.expect(ops.prompt_text == null);
}

// ---------------------------------------------------------------------------
// Fake CardSink for unit testing PollOps execution
// ---------------------------------------------------------------------------

/// Records card_sink calls for test assertions.
const FakeCard = struct {
    alloc: std.mem.Allocator,
    created: usize = 0,
    sends: usize = 0,
    streams: usize = 0,
    closes: usize = 0,
    update_messages: usize = 0,
    last_seq: i64 = 0,
    last_stream_content: std.ArrayListUnmanaged(u8) = .empty,
    last_update_content: std.ArrayListUnmanaged(u8) = .empty,
    // ponytail: simple counter/content capture; enough to verify seq monotonicity + finalize

    fn deinit(self: *FakeCard) void {
        self.last_stream_content.deinit(self.alloc);
        self.last_update_content.deinit(self.alloc);
    }

    fn create(ctx: *anyopaque, alloc: std.mem.Allocator, _: []const u8) anyerror![]u8 {
        const self: *FakeCard = @ptrCast(@alignCast(ctx));
        self.created += 1;
        return alloc.dupe(u8, "fake-card-id");
    }
    fn send(ctx: *anyopaque, alloc: std.mem.Allocator, _: []const u8, _: []const u8) anyerror![]u8 {
        const self: *FakeCard = @ptrCast(@alignCast(ctx));
        self.sends += 1;
        return alloc.dupe(u8, "fake-message-id");
    }
    fn stream(ctx: *anyopaque, _: std.mem.Allocator, _: []const u8, content: []const u8, sequence: i64) anyerror!void {
        const self: *FakeCard = @ptrCast(@alignCast(ctx));
        self.streams += 1;
        self.last_seq = sequence;
        self.last_stream_content.clearRetainingCapacity();
        self.last_stream_content.appendSlice(self.alloc, content) catch {};
    }
    fn close(ctx: *anyopaque, _: std.mem.Allocator, _: []const u8, sequence: i64) anyerror!void {
        const self: *FakeCard = @ptrCast(@alignCast(ctx));
        self.closes += 1;
        self.last_seq = sequence;
    }
    fn updateMessage(ctx: *anyopaque, _: std.mem.Allocator, _: []const u8, card_json: []const u8) anyerror!void {
        const self: *FakeCard = @ptrCast(@alignCast(ctx));
        self.update_messages += 1;
        self.last_update_content.clearRetainingCapacity();
        self.last_update_content.appendSlice(self.alloc, card_json) catch {};
    }
    fn sink(self: *FakeCard) controller.CardSink {
        return .{ .ctx = self, .create = create, .send = send, .stream = stream, .close = close, .updateMessage = updateMessage };
    }
};

/// Execute a single PollOps against a real allocator + fake card sink.
/// Tests that seq increments and last_md tracking works with no leaks.
fn executePollOps(
    alloc: std.mem.Allocator,
    card: *FakeCard,
    card_id: []const u8,
    ops: PollOps,
    seq: *i64,
    last_md: *[]u8,
) !void {
    if (ops.stream) |s| {
        try card.sink().stream(card.sink().ctx, alloc, card_id, s, seq.*);
        seq.* += 1;
        if (last_md.len != 0) alloc.free(last_md.*);
        last_md.* = try alloc.dupe(u8, s);
    }
    if (ops.finalize) {
        try card.sink().close(card.sink().ctx, alloc, card_id, seq.*);
    }
}

test "FakeCard: done ops → stream then close, seq monotonic, no leak" {
    var card = FakeCard{ .alloc = t.allocator };
    defer card.deinit();

    const card_id = try t.allocator.dupe(u8, "fake-card-id");
    defer t.allocator.free(card_id);

    var seq: i64 = 1;
    var last_md: []u8 = &.{};
    defer if (last_md.len != 0) t.allocator.free(last_md);

    const ops = planPoll(.send_final, "", "final answer", "");
    try executePollOps(t.allocator, &card, card_id, ops, &seq, &last_md);

    try t.expectEqual(@as(usize, 1), card.streams);
    try t.expectEqual(@as(usize, 1), card.closes);
    try t.expectEqualStrings("final answer", last_md);
    // seq: after stream=1 → seq becomes 2; close uses seq=2.
    try t.expectEqual(@as(i64, 2), card.last_seq);
}

test "FakeCard: two none-polls with changing md → two streams, seq 1 then 2" {
    var card = FakeCard{ .alloc = t.allocator };
    defer card.deinit();

    const card_id = try t.allocator.dupe(u8, "fake-card-id");
    defer t.allocator.free(card_id);

    var seq: i64 = 1;
    var last_md: []u8 = &.{};
    defer if (last_md.len != 0) t.allocator.free(last_md);

    const ops1 = planPoll(.none, "", "step 1", "");
    try executePollOps(t.allocator, &card, card_id, ops1, &seq, &last_md);
    try t.expectEqual(@as(usize, 1), card.streams);
    try t.expectEqual(@as(i64, 1), card.last_seq);

    const ops2 = planPoll(.none, "", "step 2", last_md);
    try executePollOps(t.allocator, &card, card_id, ops2, &seq, &last_md);
    try t.expectEqual(@as(usize, 2), card.streams);
    try t.expectEqual(@as(i64, 2), card.last_seq);

    try t.expectEqual(@as(usize, 0), card.closes);
}

test "FakeCard: none-poll with same md → no stream (skip API call)" {
    var card = FakeCard{ .alloc = t.allocator };
    defer card.deinit();

    const card_id = try t.allocator.dupe(u8, "fake-card-id");
    defer t.allocator.free(card_id);

    var seq: i64 = 1;
    var last_md = try t.allocator.dupe(u8, "unchanged");
    defer t.allocator.free(last_md);

    const ops = planPoll(.none, "", "unchanged", last_md);
    try executePollOps(t.allocator, &card, card_id, ops, &seq, &last_md);

    try t.expectEqual(@as(usize, 0), card.streams);
    try t.expectEqual(@as(usize, 0), card.closes);
}

test "FakeCard: send returns owned message_id, no leak" {
    var card = FakeCard{ .alloc = t.allocator };
    defer card.deinit();
    // send must return an owned []u8; caller frees.
    const s = card.sink();
    const mid = try s.send(s.ctx, t.allocator, "oc_chat", "fake-card-id");
    defer t.allocator.free(mid);
    try t.expectEqualStrings("fake-message-id", mid);
    try t.expectEqual(@as(usize, 1), card.sends);
}

test "FakeCard: updateMessage records card_json" {
    var card = FakeCard{ .alloc = t.allocator };
    defer card.deinit();
    const s = card.sink();
    try s.updateMessage(s.ctx, t.allocator, "om_test", "{\"schema\":\"2.0\"}");
    try t.expectEqual(@as(usize, 1), card.update_messages);
    try t.expectEqualStrings("{\"schema\":\"2.0\"}", card.last_update_content.items);
}

// Simulates finalize path: close→updateMessage, finalized=true, defer skips close.
// Verifies: close exactly once, updateMessage exactly once (with answer), card_id freed, no leak.
test "finalize path: close+updateMessage, close exactly once, no leak" {
    var card = FakeCard{ .alloc = t.allocator };
    defer card.deinit();
    const s = card.sink();

    const card_id: ?[]u8 = try t.allocator.dupe(u8, "fake-card-id");
    const message_id: ?[]u8 = try t.allocator.dupe(u8, "fake-message-id");
    const seq: i64 = 1;
    var finalized: bool = false;

    defer if (message_id) |mid| t.allocator.free(mid);
    defer if (card_id) |cid| {
        if (!finalized) {
            s.close(s.ctx, t.allocator, cid, seq) catch {};
        }
        t.allocator.free(cid);
    };

    // Simulate finalize (done path)
    if (card_id) |cid| {
        try s.close(s.ctx, t.allocator, cid, seq);
        finalized = true;
        if (message_id) |mid| {
            var arena = std.heap.ArenaAllocator.init(t.allocator);
            defer arena.deinit();
            const card_json = try @import("card.zig").buildResolvedCard(arena.allocator(), "the answer");
            try s.updateMessage(s.ctx, t.allocator, mid, card_json);
        }
    }

    try t.expect(finalized);
    try t.expectEqual(@as(usize, 1), card.closes); // exactly once
    try t.expectEqual(@as(usize, 1), card.update_messages);
    try t.expect(std.mem.indexOf(u8, card.last_update_content.items, "the answer") != null);
    // defer runs after this: card_id freed, message_id freed; finalized=true → no extra close.
}

// Simulates cancel path: close→updateMessage("⏹ 已停止"), finalized=true.
test "cancel path: close+updateMessage(已停止), close exactly once, no leak" {
    var card = FakeCard{ .alloc = t.allocator };
    defer card.deinit();
    const s = card.sink();

    const card_id: ?[]u8 = try t.allocator.dupe(u8, "fake-card-id");
    const message_id: ?[]u8 = try t.allocator.dupe(u8, "fake-message-id");
    const seq: i64 = 1;
    var finalized: bool = false;

    defer if (message_id) |mid| t.allocator.free(mid);
    defer if (card_id) |cid| {
        if (!finalized) {
            s.close(s.ctx, t.allocator, cid, seq) catch {};
        }
        t.allocator.free(cid);
    };

    // Simulate cancel path
    if (card_id) |cid| {
        try s.close(s.ctx, t.allocator, cid, seq);
        finalized = true;
        if (message_id) |mid| {
            var arena = std.heap.ArenaAllocator.init(t.allocator);
            defer arena.deinit();
            const card_json = try @import("card.zig").buildResolvedCard(arena.allocator(), "⏹ 已停止");
            try s.updateMessage(s.ctx, t.allocator, mid, card_json);
        }
    }

    try t.expect(finalized);
    try t.expectEqual(@as(usize, 1), card.closes);
    try t.expectEqual(@as(usize, 1), card.update_messages);
    try t.expect(std.mem.indexOf(u8, card.last_update_content.items, "已停止") != null);
}

// Simulates deadline/stop-loop path: finalized=false → defer closes exactly once.
test "fallback path (deadline): defer closes, no updateMessage, no leak" {
    var card = FakeCard{ .alloc = t.allocator };
    defer card.deinit();
    const s = card.sink();

    const card_id: ?[]u8 = try t.allocator.dupe(u8, "fake-card-id");
    const message_id: ?[]u8 = try t.allocator.dupe(u8, "fake-message-id");
    const seq: i64 = 1;
    const finalized: bool = false;

    defer if (message_id) |mid| t.allocator.free(mid);
    defer if (card_id) |cid| {
        if (!finalized) {
            s.close(s.ctx, t.allocator, cid, seq) catch {};
        }
        t.allocator.free(cid);
    };

    // No explicit finalize — fallback path (defer fires).
    // After this block defers run: close once (finalized=false), free card_id, free message_id.
    try t.expect(!finalized);
    // closes=0 before defer; testing.allocator will catch any leaks.
    try t.expectEqual(@as(usize, 0), card.update_messages);
}
