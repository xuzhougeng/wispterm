# Copilot Composer History Design

## Goal

Make the AI composer feel like Codex/shell history: when the Copilot sidebar or AI Chat tab composer is focused, Up/Down can recall previously submitted user prompts without breaking normal multiline editing.

## Behavior

- Up recalls the previous user prompt only when the input cursor is on the first visual row.
- Down recalls the next user prompt only when the input cursor is on the last visual row.
- Up/Down inside the middle of a multiline draft keep moving the cursor vertically.
- Starting history navigation saves the current draft. Moving past the newest history entry restores that draft.
- Any normal edit to the composer exits history navigation so future history movement starts from the current draft.
- History source is the current `Session.messages` list, filtered to `role == .user`.
- Existing `/rewind` remains unchanged: it is a destructive rollback workflow, not prompt recall.

## Architecture

The behavior belongs in `src/ai_chat.zig` on `Session`, because both dedicated AI Chat tabs and terminal-tab Copilot sidebars already route composer keys through `Session.handleKeyWithWrapCols()`. `src/input.zig` already marks the UI dirty after forwarding Copilot/AI Chat keys, so no extra render-gate handling is needed for this change.

The terminal surface path remains unchanged. Ghostty keeps terminal keyboard behavior in its input key encoder: application and normal cursor-key modes produce PTY escape sequences for programs. WispTerm should keep matching that model for terminal surfaces and only apply prompt-history behavior to its own AI composer UI.

## Testing

Add `src/ai_chat.zig` unit tests for:

- Up at the first visual row recalls newest then older user prompts.
- Down walks forward and restores the saved draft after the newest prompt.
- Up/Down in the middle of multiline input still moves the cursor vertically.
- Editing after a recall exits the history navigation state.
