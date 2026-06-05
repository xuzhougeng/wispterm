# WeChat-side approval for copilot confirmations — design

Date: 2026-06-05
Branch: `worktree-feat-wexin-remote-enhance`

## Problem

When the copilot (副驾) needs approval to run a tool (e.g. `terminal_repl_exec`),
it blocks and shows an approval card ("Approve …? Enter/Y to run, Esc/N to
deny"). A WeChat-remote user cannot answer it:

1. **The remote "Y" never resolves the approval.** WeChat input flows
   `applyWeixinInput → applyRemoteInput` (ai_chat.zig:1108), which has no notion
   of a pending approval. It types "Y" into the composer and calls `submit()`;
   because `request_inflight` is true (the request is parked inside
   `requestApproval`, ai_chat.zig:1469), `submit()` early-returns
   (ai_chat.zig:1564) and does nothing. The worker thread stays blocked forever.
2. **WeChat is never told an approval is pending.** The followup progress
   detector (`reply_progress.zig`) only reports the generic
   "还在处理中，工具调用仍在执行" — the user has no idea a decision is required.

Local approval works because a keypress is intercepted by `handleApprovalKey →
resolveApproval` (ai_chat.zig:1451), a path the remote input never touches.

## Goals

- A WeChat reply of Y/N (and Chinese equivalents) resolves the pending approval.
- WeChat is told, immediately, that an approval is pending and how to answer.
- A non-decision reply while an approval is pending is acknowledged with a
  reminder and does **not** approve, deny, or get submitted as a new prompt.

## Non-goals

- The generic web-remote mirror's approval path (also via `applyRemoteInput`)
  is **out of scope**; noted as a follow-up.
- No change to local (GUI) approval behavior.

## Decisions (from brainstorming)

- **Vocabulary** (whole-message, case-insensitive, whitespace-trimmed):
  - approve: `y`, `yes`, `ok`, `同意`, `确认`, `好`, `好的`, `可以`
  - deny: `n`, `no`, `拒绝`, `取消`, `不`, `不要`
  - anything else → unrecognized.
- **Unrecognized while pending** → reminder reply, no action ("remind, don't act").
- **Notification timing** → immediately when the copilot blocks on approval
  (carried by the already-running followup loop, ~1s poll latency).
- **Interception point** → the WeChat routing layer (`agent.sendAi`) via the
  `Control` boundary, so tailored WeChat replies stay in the `weixin/` domain.
  (`applyRemoteInput` is left untouched, so there is no second, conflicting
  resolution path.)

## Architecture

### Part A — inbound Y/N resolves the approval

New pure module **`src/weixin/approval_reply.zig`**:

```zig
pub const Decision = enum { approve, deny, unrecognized };
pub fn classify(text: []const u8) Decision; // trim + ASCII-lower whole-message match
```

**`src/weixin/control.zig`** — two new VTable methods + wrappers:

```zig
ai_approval_pending: *const fn (ctx: *anyopaque) bool,
resolve_ai_approval: *const fn (ctx: *anyopaque, approve: bool) bool,
```

`aiApprovalPending()` returns whether the active AI surface is blocked on an
approval. `resolveAiApproval(approve)` resolves it (returns true if one was
pending). Both are synchronous (marshaled to the UI thread and back).

**`src/weixin/agent.zig`** — `sendAi` gains an early branch:

```
if ctrl.aiApprovalPending():
    switch approval_reply.classify(text):
        .approve => { _ = ctrl.resolveAiApproval(true);  out.set("已确认，继续执行。"); out.expect_ai_progress = true; }
        .deny    => { _ = ctrl.resolveAiApproval(false); out.set("已拒绝该操作。");   out.expect_ai_progress = true; }
        .unrecognized => out.set("当前有待确认操作，请先回复 Y 同意 / N 拒绝。"); // no resolve, no progress
    return;
// ... existing normal send path unchanged ...
```

The query runs only when `route()` has already confirmed `ctrl.isConnected()`.
In the common (no-approval) case it is one cheap marshaled call returning false,
then the existing path runs verbatim.

Rationale for `expect_ai_progress` on both decisions: approve → the copilot runs
the tool and produces output; deny → the tool call returns "denied" and the
copilot continues with a (usually short) response. Both should stream back. A
denial is **not** an abort — `/stop` (ESC) remains the way to abort a whole run.

**`src/ai_chat.zig`** — expose resolution for the remote path:

```zig
pub fn resolveApprovalExternal(self: *Session, approve: bool) bool {
    return self.resolveApproval(approve);
}
```

`approvalView()` (already `pub`) supplies the pending query.

**`src/AppWindow.zig`** — wire the two ops through the existing
`WeixinRequest` marshaling:

- add `WeixinRequest.op` variants `ai_approval_pending`, `resolve_ai_approval`
  and an `approve: bool` input field;
- handlers run on the UI thread, resolve the active AI session via the existing
  `weixinActiveAiTabIndex()`, and call `session.approvalView() != null` /
  `session.resolveApprovalExternal(approve)`;
- add `wxAiApprovalPending` / `wxResolveAiApproval` and register them in
  `weixin_vtable`.

### Part B — WeChat is told an approval is pending, immediately

**`src/ai_chat.zig` `allocRemoteSnapshot`** — when an approval is pending, emit a
dedicated section so the remote layer can see it through the existing transcript
channel:

```
Approval:
<tool>
<command — truncated to the snapshot budget>
```

The approval fields are captured under `approval_mutex` **before** `self.mutex`
is taken (sequential locks, never nested — there is no reverse ordering
elsewhere), then appended via `appendLimitedSection` so the section is always
present (not subject to the recent-section byte budget).

**`src/weixin/reply_progress.zig`** — add a `.approval` role to the section
parser (label `Approval:`) and extend `Progress`:

```zig
pub const Progress = struct {
    done: bool = false,
    text: []const u8 = "",
    needs_approval: bool = false,
    approval_tool: []const u8 = "",     // borrows from `current`
    approval_command: []const u8 = "",  // borrows from `current`
};
```

`progress()` checks for an `Approval` section **first**, before the
`last_assistant`/done and tool-running branches, returning
`{ needs_approval = true, done = false, approval_tool, approval_command }`. This
also closes a latent bug: during approval the status looks idle, so the existing
`if (last_assistant) if (!isActiveStatus(status)) return done=true` could
mis-report the pre-tool assistant text as the final answer.

**`src/weixin/poller.zig`** — the followup loop already polls the transcript
every `AI_REPLY_POLL_MS` (1s):

- `allocProgressText` returns `needs_approval` too and, when set, allocates the
  formatted WeChat prompt:
  `"⚠️ 副驾需要你确认是否执行：\n<command or tool>\n\n回复 Y 同意 / N 拒绝。"`
  (command truncated for WeChat).
- A small pure helper tracks announce-once state:

  ```zig
  const ApprovalAnnouncer = struct {
      announced: bool = false,
      /// true ⇒ send the prompt now (first tick of a new pending approval).
      fn due(self: *ApprovalAnnouncer, needs_approval: bool) bool {
          if (!needs_approval) { self.announced = false; return false; }
          if (self.announced) return false;
          self.announced = true;
          return true;
      }
  };
  ```

- In `followupThreadMain`: each tick, if `progress.needs_approval` and
  `announcer.due(true)` → send the prompt immediately (skip the checkpoint
  schedule and the done check for that tick); when not pending, `due(false)`
  resets so a later approval re-announces.

Because `resolveAiApproval` is synchronous, by the time the replacement followup
(started by the "Y" message) first polls, `approvalView()` is already null and
the snapshot carries no `Approval:` section — so it does not re-announce.

## Data flow (Y to approve)

```
WeChat "Y"
  → poller routeAdapter (captures baseline first)
  → agent.route → sendAi
      → ctrl.aiApprovalPending()  → true
      → classify("Y") = approve
      → ctrl.resolveAiApproval(true)  (UI thread signals the parked worker)
      → reply "已确认，继续执行。", expect_ai_progress = true
  → poller sends the ack
  → poller starts a fresh followup (old one cancelled); copilot runs the tool;
    followup streams progress then the final answer.
```

## Testing (TDD)

Pure / unit-testable:

- `approval_reply.classify`: each approve/deny token, case-insensitivity,
  trimming, and unrecognized (incl. `我不确定` must not match `不`, i.e.
  whole-message match).
- `reply_progress`: `Approval:` section → `needs_approval` + tool/command;
  priority over the done and tool-running branches.
- `ai_chat` `allocRemoteSnapshot`: emits the `Approval:` section with tool +
  command when pending; omits it otherwise (drive via `requestApproval` state).
- `ApprovalAnnouncer.due`: fires once per pending episode, resets on clear.
- `agent.sendAi`: the three reply branches + `resolveAiApproval` invocation,
  via a `FakeControl` extended with `approval_pending` + a resolve capture.

Not unit-tested (consistent with existing GUI glue): the `AppWindow` vtable
handlers — covered by a `windows-gnu` cross-compile and manual GUI verification.

Suites: `zig build test` and `zig build test-full` green; windows-gnu
cross-compile clean.

## Risk / edge cases

- **Re-announce after Y** — avoided by the synchronous resolve (see above).
- **Lock ordering** — approval fields captured before `self.mutex`; no nested
  acquisition, no reverse order anywhere.
- **Slow approval (>30 min)** — the followup hits `AI_REPLY_DEADLINE_MS` and
  sends the existing window-expired resend notice; acceptable.
- **Approval triggered by a locally-initiated turn** — no followup is running,
  so WeChat is not notified; expected (WeChat only tracks WeChat-initiated
  turns).
