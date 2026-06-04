# Rename "AI Agent" → Copilot and "AI History" → Sessions — design

## Problem

Two distinct user-facing features both lead with a vague "AI" label, which is
too broad and makes them read like a pair when they are unrelated:

- **The built-in AI** WispTerm launches and you converse with (chat tab +
  `Ctrl+Shift+A` sidebar). Labeled "AI Agent" / "AI 智能体" in the session
  launcher; its own saved conversations are listed under "Agent History" /
  "智能体历史" in the command palette.
- **A read-only browser** of sessions logged by *external* CLI agents (Codex,
  Claude Code, Reasonix). Labeled "AI History" — and inconsistently "Agent
  History" in one place — even though it has nothing to do with the built-in AI.

## Decision

**Direction: Copilot + Sessions.** The built-in AI becomes **Copilot / 副驾**
(an interactive, present-tense assistant — and the right-side sidebar is already
called Copilot, so this unifies). The external log browser becomes **Sessions /
会话** (a past-tense archive of other tools' runs). Neither keeps a bare "AI"
prefix, and they no longer share the "Agent" word, so "Sessions" can never be
mistaken for "Copilot's history".

### Mapping

**① Built-in AI → Copilot / 副驾**

| Surface | Before (en / zh) | After (en / zh) |
| --- | --- | --- |
| Session-launcher entry (`sl_ai_agent`) | AI Agent / AI 智能体 | Copilot / 副驾 |
| Its conversation history (`cmd_palette_history_title`) | Agent History / 智能体历史 | Copilot History / 副驾历史 |
| `cmd_palette_recent_sessions` | Recent agent sessions / 最近的智能体会话 | Recent Copilot sessions / 最近的副驾会话 |
| `cmd_palette_no_sessions(_yet)` | …agent sessions / …智能体会话 | …Copilot sessions / …副驾会话 |
| Command-palette action titles (`command_center_state`) | New Agent; Select Agent History | New Copilot; Select Copilot History |
| Chat tab fallback title | AI Chat | Copilot (`sl_ai_agent`) |
| Chat input placeholder (plain mode) | Ask AI Chat | Ask Copilot |
| Export command titles | Export AI Chat Markdown[ Clean] | Export Copilot Markdown[ Clean] |
| Export Markdown header / save-dialog / empty toast | …AI Chat… | …Copilot… |
| WeChat bridge messages | AI Agent / AI Chat | 副驾 |

**② External CLI browser → Sessions / 会话**

A new i18n key `sl_sessions` = "Sessions" / "会话" plus `sl_sessions_detail`
= "Browse Codex / Claude Code sessions" / "浏览 Codex / Claude Code 会话".
All live "AI History" chrome routes through it: workbench tab title + header,
session-launcher row + detail subtitle, SSH-profile picker header, width calcs,
remote-layout snapshot placeholder, and the resume-failure toasts/error
("AI History resume failed" → "Sessions resume failed").

### Out of scope (kept as-is)

- **Internal identifiers**: enum values (`new_agent`, `select_agent_history`,
  `.ai_history` tab kind), globals (`g_ai_history_*`), config keys
  (`--ai-agent-enabled`), profile storage (`ai_profiles/`). Renaming these would
  touch persistence/config with no user-visible benefit.
- The **Agent/Chat capability mode** label inside the chat (it denotes tool-use,
  not the feature name).
- Code comments, `log.warn` developer messages, debug prints, and the
  agent-facing tool result strings.
- Historical design docs under `docs/superpowers/plans|specs` (the `ai-agent`
  `wispterm_docs` topic key also stays).

### Notes

- `pty_command.sessionLauncherDetailForOs` is a comptime constant, so it cannot
  use runtime i18n; its words change to Copilot/Sessions but stay English-only
  (matching today's behavior).
- `ai_history_session.zig`, `ai_history_renderer.zig`, and `appwindow/tab.zig`
  gain an `i18n` import so their previously-hardcoded "AI History" strings
  localize.

## Verification

`zig build test` (fast) + `zig build test-full` both green; existing
string-assertion tests (`command_center_state`, `pty_command`,
`ai_history_resume` PowerShell) updated to the new copy. GUI verification on
macOS/Windows deferred (no Linux GUI backend), consistent with prior UI work.
