# WeChat-direct conversation list & switch

**Date:** 2026-06-17
**Status:** Implemented (Linux suites green; Windows GUI verification pending)
**Branch:** `weixin-list-switch-conversations`

## Problem

When WispTerm is connected directly to WeChat, a remote user can only ever drive
**one** AI conversation. The WeChat bridge resolves its target fresh on every
inbound message via `weixinActiveAiTabIndex()` (`AppWindow.zig:5710`):

> the focused tab if it is an AI-chat tab, else the **first** AI-chat tab.

There is no persistent notion of "which conversation WeChat is driving," so a
remote user (away from the machine, unable to click a tab) is stuck on whatever
is focused/first. If they have several AI conversations open, the other ones are
unreachable from WeChat.

The original TypeScript bridge (`agent.ts`) had `/sessions` and `/use` commands
for exactly this; they were deliberately dropped in the Zig port
(`weixin/agent.zig:1` — "minus /sessions and /use (one local app)"). This feature
brings that capability back, adapted to WispTerm's tab/session model.

## Goal

Add WeChat slash commands so a remote user can:

1. `/list` — see all open AI conversations (dedicated AI-chat tabs **and**
   terminal-tab Copilot sidebars), with a marker for the one WeChat currently
   targets.
2. `/switch <n>` — pin WeChat to the Nth conversation. On a successful switch,
   the bridge replies with a **lightweight digest** of the newly-pinned
   conversation so the remote user knows what environment they just entered.

The digest is **pushed to WeChat only** — it is *not* injected into the AI
conversation as context. It is purely an orientation aid for the user.

## Decisions (locked with the user)

| Question | Decision |
|---|---|
| How does `/switch` relate to the GUI's focused tab? | **Independent pin.** WeChat keeps its own pinned conversation, separate from the on-screen active tab. `/switch` never changes the focused tab. |
| What is in the auto-sent 会话汇总? | **Lightweight local digest:** title, model, working dir, busy/idle, and a short transcript tail. No extra LLM call. |
| Are Copilot sidebars included? | **Yes.** A terminal tab with a `copilot_session` is a listable/switchable conversation, alongside dedicated AI-chat tabs. |
| Command surface | `/list` (aliases `/sessions`, `/ls`) and `/switch <n>` (alias `/use <n>`). |
| Does `/switch` force the Copilot sidebar visible locally? | **No.** Consistent with the independent-pin philosophy — the remote drives it whether or not it is shown on screen. |
| Does unpinned (default) targeting change? | **No.** With nothing pinned, WeChat resolves to the active/first **dedicated** AI-chat tab and opens one if none exists, exactly as today. Copilot conversations are reachable specifically via `/list` + `/switch`. |

### Explicit non-goals (YAGNI)

- No persistent pin across app restarts — the pin lives only for the running
  session (process-global, UI-thread-owned). On restart, WeChat falls back to the
  default resolver.
- No proactive "your pinned conversation was closed" push. When the pinned
  conversation disappears, the pin auto-clears and the next `/list` / `/status`
  shows the real current target; messages silently fall back to the default.
- No LLM-generated summary on switch (the digest is local-only).
- No change to the web-remote (`applyRemoteInput`) or `wisptermctl` paths.

## Key architectural facts (verified against current code)

- **Single resolver chokepoint.** Every WeChat→AI op funnels through
  `weixinActiveAiTabIndex()`: `find_ai` (→ `send_input`'s target id),
  `latest_transcript`, `ai_approval_pending`, `resolve_ai_approval`,
  `inbound_file_dir`. Teaching this one resolver about a pin makes the pin take
  effect everywhere.
- **Tab indices are not stable.** `closeTab` compacts the array
  (`tab.zig:667` shifts `g_tabs[i] = g_tabs[i+1]`) and `reorderTab` moves
  entries. A raw index is therefore unusable as a pin identity.
- **`*ai_chat.Session` pointers are stable** for the conversation's lifetime and
  survive index compaction (the array stores `*TabState`/`*Session` pointers, not
  values). Both `TabState.ai_chat_session` and `TabState.copilot_session` are
  `?*ai_chat.Session`.
- **One conversation per tab.** A tab's AI conversation is
  `ai_chat_session orelse copilot_session` — a dedicated AI-chat tab populates the
  former, a terminal tab with an opened sidebar the latter, never both relevant at
  once. So a tab index still uniquely identifies a conversation, and the resolved
  session is unambiguous.
- **All needed methods live on `Session`** and work identically for a
  `copilot_session`: `applyWeixinInput`/`applyRemoteInput` (input),
  `approvalView`/`resolveApprovalExternal` (approval), `allocRemoteSnapshot`
  (transcript), `workingDirOverride` (cwd), `request_inflight` (busy), `model`,
  `title`.

## Architecture

Three layers, mirroring the existing WeChat bridge structure.

### 1. Pure routing & formatting (`weixin/agent.zig`)

New commands handled in `route`:

- `/list` / `/sessions` / `/ls` — no argument. Calls
  `ctrl.listAiConversations(allocator)`, formats the result, replies.
- `/switch <n>` / `/use <n>` — requires a 1-based integer argument. Calls
  `ctrl.pinAiConversationByIndex(n-1)`; on success formats and replies with the
  digest; on out-of-range/non-numeric replies with guidance to run `/list`.

Plumbing updates in `route`:

- Add the new commands to the known-command whitelist (`agent.zig:73`) so they
  are not rejected as "未知命令".
- Add `/list` (and aliases) to the no-argument-allowed set (currently only
  `/stop` is exempt at `agent.zig:78`); `/switch` legitimately requires an arg.
- `/help` text gains the two commands.
- `/status` reports the current target (pinned title, or "默认（活动/首个）").

Formatting is done by **pure, unit-tested helpers** (in `agent.zig` or a small
sibling `weixin/session_list.zig`):

- `formatConversationList([]Conversation) -> text`
- `formatSwitchDigest(Conversation, transcript_tail) -> text`

### 2. Control vtable extension (`weixin/control.zig`)

Add to `Control.VTable` (and matching wrapper methods):

```zig
pub const Conversation = struct {
    title: []const u8,   // dedicated: chat title; copilot: "<host tab title> · 副驾"
    model: []const u8,
    cwd: []const u8,     // workingDirOverride() or "" 
    busy: bool,          // request_inflight
    is_copilot: bool,
    is_current: bool,    // == the conversation the resolver currently targets
};

// Enumerate all AI conversations (dedicated + copilot), in tab order.
// Strings + slice allocated in `allocator`; caller frees (page-allocator copy
// pattern, same as latest_transcript / inbound_file_dir).
list_ai_conversations: *const fn (ctx, allocator) anyerror![]Conversation,

// Pin the Nth conversation (0-based, tab order). Stores its stable *Session
// handle in the UI-thread-owned pin global. Returns the chosen conversation's
// data, or null if out of range. Enumeration happens atomically on the UI
// thread so index→handle mapping is consistent.
pin_ai_conversation_by_index: *const fn (ctx, idx0: usize) anyerror!?Conversation,
```

The digest's transcript tail is obtained by calling the existing
`latestTranscript()` **after** a successful pin (it now resolves to the pinned
conversation) and taking a UTF-8-safe tail (`clipUtf8`, last few lines). No new
transcript vtable method is needed.

### 3. GUI marshaling (`AppWindow.zig`)

- New `g_weixin_pinned_session: ?*ai_chat.Session` (UI-thread-only; no lock
  needed — read/written only inside `handleWeixinControlRequest`).
- `weixinActiveAiTabIndex()` becomes **pin-aware**:
  1. If `g_weixin_pinned_session` is set, scan all tabs for one whose
     `ai_chat_session == pinned` or `copilot_session == pinned` (pointer identity
     comparison only — never deref a possibly-stale pointer). If found, return its
     index.
  2. If the pinned session is not found (conversation closed), **clear the pin**
     and fall through.
  3. Fall back to the existing default (active AI-chat tab, else first AI-chat
     tab).
- Every consumer that reads the resolved tab's session changes
  `tab_state.ai_chat_session orelse return` → `tab_state.ai_chat_session orelse
  tab_state.copilot_session orelse return` (covers `send_input`,
  `latest_transcript`, `ai_approval_pending`, `resolve_ai_approval`,
  `inbound_file_dir`). The transient `aichat{index}` surface id keeps encoding
  the tab index.
- Two new `WeixinRequest` ops + handlers:
  - `list_conversations` — walks `g_tabs`, emits a `Conversation` per tab whose
    resolved session is non-null, marking `is_current` against the resolver,
    `is_copilot` for terminal-tab sources. Copilot title = host tab `getTitle()`.
  - `pin_by_index` — enumerates the same way, picks the Nth, stores its `*Session`
    in `g_weixin_pinned_session`, returns its `Conversation`.
- New vtable wrappers `wxListAiConversations` / `wxPinAiConversationByIndex`
  marshal these to the UI thread (`weixinDispatch`) and copy results out via the
  page-allocator pattern already used by `wxTranscript` / `wxInboundFileDir`.

## Data flow

```
/list:
  poller → agent.route → ctrl.listAiConversations(alloc)
        → weixinDispatch(list_conversations) [UI thread enumerates g_tabs]
        → []Conversation → formatConversationList → reply text → WeChat

/switch 2:
  poller → agent.route(parse n=2) → ctrl.pinAiConversationByIndex(1)
        → weixinDispatch(pin_by_index) [UI thread: enumerate, store handle]
        → ?Conversation
        → (on success) ctrl.latestTranscript() [now pin-resolved] → tail
        → formatSwitchDigest(conv, tail) → reply text → WeChat
  subsequent messages: agent.route default → find_ai → resolver returns the
        pinned tab → send_input targets the pinned conversation.
```

## Reply formats (illustrative)

`/list`:

```
副驾会话（共 3 个）：
1. ➤ Claude  [glm-5.2]  闲
2.    Codex 调试  [gpt-5]  忙
3.    zsh ~/proj · 副驾  [claude-opus-4-8]  闲
发送 /switch <编号> 切换；微信将固定到所选会话。
```

`➤` marks the current target. With nothing pinned and no dedicated AI-chat tab
open, no row is marked and a note explains a message will open a new session.

`/switch 3`:

```
已切换到会话 3：zsh ~/proj · 副驾
模型：claude-opus-4-8
目录：/home/xzg/proj
状态：闲
最近：
<最后几行转写>
（已固定，后续消息将发送到此会话。本摘要仅供参考，未作为对话上下文。）
```

## Error handling & edge cases

- **Offline** (no UI window published): existing `if (!ctrl.isConnected())` gate
  returns the offline message before command dispatch.
- **No conversations:** `/list` → "当前没有副驾会话，发送任意消息可自动打开。";
  `/switch` → guidance to run `/list`.
- **Out-of-range / non-numeric `/switch` arg:** "无效的会话编号，请先 /list 查看。"
- **Pinned conversation closed:** resolver clears the pin and falls back silently;
  `/list`/`/status` reflect the real current target.
- **/switch to the already-current conversation:** still succeeds and re-sends the
  digest (harmless, and useful as a "where am I" probe).
- **List/switch race** (a tab closes between `/list` and `/switch`): `/switch n`
  resolves against a *fresh* enumeration and stores a stable handle, so the pin is
  always correct for whatever it actually selected; positions may differ from the
  last `/list` (inherent to any positional scheme, acceptable).

## Testing (TDD)

- Extend `agent.zig`'s `FakeControl` with `list_ai_conversations` /
  `pin_ai_conversation_by_index` backed by a static fixture list.
- Route tests: `/list` formatting (incl. `➤` marker, copilot `· 副驾` tag, busy
  flags); `/switch` in-range (digest content + pin call), out-of-range,
  non-numeric, no-conversations; aliases (`/sessions`, `/ls`, `/use`); `/help`
  and unknown-command gating still correct.
- Direct unit tests for the pure `formatConversationList` /
  `formatSwitchDigest` helpers (including UTF-8-safe tail clipping for CJK).
- `zig build test` + `zig build test-full` + windows-gnu cross-compile must stay
  green. GUI smoke (WeChat bridge is Windows-only at runtime) verified separately
  on Windows.

## Files touched (anticipated)

- `src/weixin/agent.zig` — new commands, routing/whitelist/help, pure formatters
  (or a new `src/weixin/session_list.zig` for the formatters + tests).
- `src/weixin/control.zig` — `Conversation` struct, two new vtable entries +
  wrappers, fake updates in its own test.
- `src/AppWindow.zig` — pin global, pin-aware resolver, copilot fallthrough in
  consumers, two new `WeixinRequest` ops + handlers + vtable wrappers.
- `src/weixin/controller.zig` (test fakes: `NoopControl` gains the two methods).
- Possibly a small `pub fn isBusy()` accessor on `ai_chat.Session` (or read the
  `request_inflight` field directly).
