# AI Chat transcript selection fix + Ctrl+X cut

Date: 2026-05-25

## Problem

Two issues in the AI Chat page:

1. **Selection is misaligned.** Dragging to select text in an assistant
   message and copying it yields a shifted substring. Reported case: the user
   selected what is displayed as `生成的完整 Markdown` but the clipboard
   received `成的完整 Markdow` (leading `生` and trailing `n` dropped).

2. **No cut shortcut.** The composer has no Ctrl+X.

## Root cause (issue 1)

The transcript renders **cleaned** text: `prepareMarkdownLine` →
`cleanInline` strips `*`, `_`, `` ` ``, `<…>` tags and collapses
`[label](url)` to `label`. But three of the four code paths operate on the
**raw** source instead of the cleaned text the user sees:

- `renderWrappedSelection` (the highlight box) walks the raw `info.line`.
- `byteOffsetForMarkdownPoint` / `byteOffsetForWrappedPoint` /
  `byteOffsetForLineX` (click → byte offset) walk the raw `info.line`.
- `allocTranscriptSelectionTextLocked` slices raw `msg.content[start..end]`.

Only `renderWrappedText` draws the cleaned glyphs. So for any line containing
inline markup, every offset is shifted by the byte width of the stripped
markup. `生成的完整 Markdown` was almost certainly emphasized/code-spanned in
source (e.g. `**生成的完整 \`Markdown\`**`); the stripped markers shifted the
hit-test and produced the wrong range.

## Decisions (confirmed with user)

- **Copy result = visible (cleaned) text.** Selecting and copying yields
  exactly what is shown — no `*`, backticks, or link URLs.
- **Ctrl+X scope = cut the editable input composer when selected.** The
  transcript is read-only, so Ctrl+X cannot delete from it. The composer
  currently supports select-all only (no partial range); Ctrl+X cuts the
  whole input when `input_select_all` is set and the input is non-empty.
  Partial composer selection is out of scope.

## Core idea

Make **one cleaned "display text" per message the single source of truth** for
selection. Selection offsets index into the display text. Hit-test, highlight,
and copy all derive from the same iterator, so they cannot drift. Because copy
returns the visible text, copy is just a substring of the display text.

"Display text" = each source line contributes its cleaned text followed by
`"\n"`; table rows contribute their cleaned cell text. Wrapping is purely
visual and does **not** affect offsets — offsets index the cleaned *source*
text (with source newlines).

## Approach (selected: shared module)

Extract the pure cleaning + source-line/table iteration with running
display-offset accounting into a new module imported by **both** `ai_chat.zig`
and the renderer. This avoids the existing import direction problem
(`ai_chat_renderer.zig` imports `ai_chat.zig`, not the reverse) and guarantees
the renderer geometry and the copy path share identical offset accounting.

Rejected alternatives:

- *Renderer-owns-it, route copy through the renderer from `clipboard.zig`.*
  Less code moved, but leaves two representations and pushes copy-priority
  logic into `clipboard.zig`; the model's selection-text path drifts from the
  view.
- *Keep copy = raw markdown, only realign geometry.* Rejected by the
  copy-result decision.

## Components / changes

### New: `src/markdown_text.zig`

Pure text module (no rendering, no `AppWindow`). Contents:

- `cleanInline(buf, text) []const u8` and `cleanPlain(buf, text) []const u8`
  (moved from `ai_chat_renderer.zig`).
- `nextSourceLine(text, start) SourceLine`, link parsing (`parseMarkdownLink`),
  and table helpers (`isMarkdownTableStart`, `tableBlockEnd`,
  `isTableSeparatorLine`) as needed for iteration (moved/shared).
- A `DisplayLine` iterator that yields, per source line/block:
  `{ cleaned_text: []const u8, display_offset: usize, kind, indent,
  heading_level }`. `kind` distinguishes text / blank / fence / rule / table
  so the renderer can pick line height and color without re-classifying.
- `allocDisplayText(allocator, content) ![]u8` built on the iterator.

The iterator is the **single** definition of display-offset accounting.

### `src/renderer/ai_chat_renderer.zig`

- `prepareMarkdownLine` keeps producing view metrics (line_h, color,
  background, indent) but takes the cleaned text + classification from the
  shared iterator rather than re-cleaning.
- `byteOffsetForMarkdownPoint` / `byteOffsetForWrappedPoint` /
  `byteOffsetForLineX` walk the **cleaned** text and return **display-space**
  offsets from the iterator's `display_offset` base.
- `renderWrappedSelection` walks the cleaned text and uses display-space base
  offsets, so the highlight box lines up with the glyphs drawn by
  `renderWrappedText`.
- Pixel/wrap/draw math is otherwise unchanged. Table click mapping stays at
  row-start granularity (same as today).

### `src/ai_chat.zig`

- `allocTranscriptSelectionTextLocked` builds the message's display text via
  `markdown_text.allocDisplayText` and slices `[start..end]`, clamped to UTF-8
  boundaries. The stored `transcript_selection` offsets are now display-space
  (opaque to the Session — no other logic changes).
- Add a composer cut helper, e.g. `cutInputSelection(allocator) ?[]u8`:
  if `input_select_all` and `input_len > 0`, dupe the input text, clear the
  input, and return the duped text for the caller to place on the clipboard;
  otherwise return `null`. (Exact split between Session and `clipboard.zig`
  finalized during implementation; the Session owns the input mutation.)

### `src/input.zig`

- Add a Ctrl+X handler beside the existing Ctrl+C handler (`activeAiChat()`
  block, key code `0x58`). On Ctrl+X: call the cut path; if it returns text,
  copy to clipboard and trigger a rebuild; otherwise treat as a no-op for the
  AI chat (do not fall through to the terminal). No effect on a read-only
  transcript selection.

### `src/input/clipboard.zig`

- Add `copyAiChatCutToClipboard(chat)` mirroring `copyAiChatToClipboard`:
  obtain the cut text from the Session, copy via `copyTextToClipboard`, show
  the copy toast, and rebuild. No-op when there is nothing to cut.

## Data flow (after change)

```
msg.content (raw markdown)
        │  markdown_text iterator (clean + offset accounting)
        ▼
display text  ──────────────┬──────────────┬───────────────┐
   (cleaned, source \n)     │               │               │
                            ▼               ▼               ▼
                    hit-test (click)   highlight box     copy substring
                   → display offset   (display offset)  display[start..end]
                            └───────────────┴───────────────┘
                              all three share one offset space
```

## Testing

- Keep the two existing plain-text selection tests in `ai_chat.zig`
  (`alpha beta gamma`, `你好吗`) — plain text has raw == cleaned, so display
  offsets equal the old raw offsets and these still pass.
- Add a markdown-markup selection test: assistant content like
  `**生成的完整 \`Markdown\`**`, select the display range covering
  `生成的完整 Markdown`, assert the copied text equals the cleaned string
  (no `*`/backticks) — reproduces and pins the reported bug.
- Add a `markdown_text.allocDisplayText` test covering inline emphasis, code
  span, and a link, asserting the cleaned output and that offsets are
  contiguous.
- Add a Ctrl+X cut test: set input + `input_select_all`, run the cut helper,
  assert returned text equals the input and the input is now empty; assert the
  helper returns `null` when nothing is selected.

## Risk

The display-offset accounting must match across iterator / hit-test /
highlight. Mitigated by routing all three through the single iterator in
`markdown_text.zig` plus the markdown selection test. Table selection remains
coarse (row-start), unchanged from current behavior.

## Out of scope

- Partial (range) selection in the composer / shift+arrow editing.
- Changing what the per-message copy button or whole-transcript copy produces
  (`allocMessageClipboardText`, `allocTranscriptClipboardTextLocked`).
- Table cell-level click precision.
