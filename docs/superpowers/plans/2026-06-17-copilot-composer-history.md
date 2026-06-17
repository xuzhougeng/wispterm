# Copilot Composer History Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Codex-style Up/Down prompt history recall to the shared AI composer used by Copilot and AI Chat.

**Architecture:** Implement the behavior in `src/ai_chat.zig` on `Session`, reusing existing visual cursor helpers and current-session user messages. Leave `src/input.zig` terminal routing untouched so Ghostty-style PTY arrow behavior remains unchanged.

**Tech Stack:** Zig, existing `Session` unit tests, `zig test src/ai_chat.zig`, `zig build test`.

---

### Task 1: Add Failing Session Tests

**Files:**
- Modify: `src/ai_chat.zig`

- [ ] **Step 1: Add tests near existing composer cursor tests**

Add tests that construct a `Session`, append `.user` messages, drive `handleKeyWithWrapCols()` with `.arrow_up` and `.arrow_down`, and assert composer text/cursor behavior.

- [ ] **Step 2: Verify RED**

Run: `zig test src/ai_chat.zig`

Expected: the new tests fail because Up at the first row currently returns without recalling history, and Down at the newest history entry does not restore the draft.

### Task 2: Implement Composer History State

**Files:**
- Modify: `src/ai_chat.zig`

- [ ] **Step 1: Add state to `Session`**

Add fields for whether prompt-history navigation is active, the selected user-message ordinal, and the saved draft buffer/length/cursor.

- [ ] **Step 2: Add locked helper functions**

Add helpers to count user prompts, map user-prompt ordinal to message index, save/clear history navigation state, recall selected prompt into the composer, and decide whether the cursor is on the first or last visual row.

- [ ] **Step 3: Route Up/Down through the helper**

In `handleKeyWithWrapCols()`, keep composer suggestions first. If no suggestion is active, Up/Down should try history navigation at visual boundaries before falling back to `moveInputCursorVertical()`.

- [ ] **Step 4: Clear history navigation on edits**

Clear navigation state from normal composer mutations: append/insert text, deletion, clear input, and explicit input replacement.

- [ ] **Step 5: Verify GREEN**

Run: `zig test src/ai_chat.zig`

Expected: the new tests and existing `ai_chat.zig` tests pass.

### Task 3: Run Project Verification

**Files:**
- Verify only.

- [ ] **Step 1: Run fast suite**

Run: `zig build test`

Expected: fast platform-independent tests pass.

- [ ] **Step 2: Run full app suite**

Run: `zig build test-full`

Expected: full app tests pass, including input/render-gate compiled paths.
