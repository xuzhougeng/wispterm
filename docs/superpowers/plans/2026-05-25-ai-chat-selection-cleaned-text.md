# AI Chat selection fix + Ctrl+X cut — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make AI-chat transcript selection copy exactly the visible (cleaned) text instead of a markup-shifted substring, and add Ctrl+X to cut the input composer.

**Architecture:** Introduce one pure module, `src/markdown_text.zig`, that owns markdown text-cleaning, source-line/table iteration, and a canonical "display text" (cleaned text the user sees) with a single byte-offset space. The renderer's selection highlight and click→offset hit-test, and the model's copy path, all derive offsets from this one representation, so they cannot drift. Ctrl+X cuts the whole input when the composer is selected.

**Tech Stack:** Zig 0.15.2. Build: `zig build`. Tests: `zig build test`. The renderer (`ai_chat_renderer.zig`) is **not** in the test harness; the new module and `ai_chat.zig` are. Use `rtk proxy <cmd>` is not required — plain `zig` commands are fine.

**Spec:** `docs/superpowers/specs/2026-05-25-ai-chat-selection-cleaned-text-design.md`

---

## Background facts (read before starting)

Root cause: the transcript draws **cleaned** text (`prepareMarkdownLine` → `cleanInline` strips `*` `_` `` ` `` `<…>` and collapses `[label](url)` to `label`), but the selection highlight (`renderWrappedSelection`) and the click→byte-offset hit-test (`byteOffsetForMarkdownPoint`/`…WrappedPoint`/`…LineX`) walk the **raw** source line, and copy slices raw `msg.content[start..end]`. For any line with inline markup, every offset is shifted by the byte width of the stripped markup. We move all selection geometry and copy to operate in **display-text (cleaned) offset space**.

"Display text" rule (must be identical everywhere): walk the message exactly like `renderMarkdownContent` does (line-by-line via `nextSourceLine`, table blocks via `isMarkdownTableStart`/`tableBlockEnd`). Each non-table source line contributes `cleanedLine(...).text` followed by one `'\n'`. Each table block contributes, per non-separator row, `cleanInline(raw_row)` followed by one `'\n'`.

Decisions (already approved): copy = visible/cleaned text; Ctrl+X cuts the input composer when `input_select_all` is set and the input is non-empty (no-op on read-only transcript; no partial composer selection).

Functions currently in `src/renderer/ai_chat_renderer.zig` that this plan relocates to `src/markdown_text.zig` (all pure, std-only):
`cleanInline` (2088), `cleanPlain` (2077), `appendSlice` (2135), `parseMarkdownLink` (2123), `Link` (2006), `nextSourceLine` (1520), `SourceLine` (1515), `isFence` (2030), `fenceLanguage` (2034), `isHorizontalRule` (2039), `headingBody` (2011), `htmlHeadingBody` (2018), `listBody` (2052), `isSpace` (2073), `Heading` (1996), `List` (2001), `looksLikeTableRow` (1689), `isTableSeparatorLine` (1694), `parseTableRowCells` (1673), `isMarkdownTableStart` (1530), `tableBlockEnd` (1538), and the constant `TABLE_MAX_COLS` (42).

The renderer keeps all pixel/draw/measure code (`measureText`, `renderTableBlock`, `measureTableColumns`, `tableUsedWidth`, `tableBlockHeight`, line-height helpers, `nextCodepoint`, etc.).

---

## Task 1: Create `src/markdown_text.zig` (pure cleaning + display text)

**Files:**
- Create: `src/markdown_text.zig`
- Modify: `src/renderer/ai_chat_renderer.zig` (delete relocated definitions; add alias consts)
- Modify: `src/test_main.zig:619` (register the new module so its tests run)

### Step 1.1: Create the module with relocated pure helpers

Create `src/markdown_text.zig`. Move the bodies of the functions/structs/const listed in "Background facts" **verbatim** from `ai_chat_renderer.zig` into this file, marking each `pub`. They only depend on `std` and each other. Header:

```zig
//! Pure markdown text helpers shared by the AI-chat renderer and model.
//! Owns the canonical "display text" (the cleaned text the user sees) and its
//! single byte-offset space, so selection highlight, click hit-testing, and
//! copy all agree. No rendering, no AppWindow, std-only.
const std = @import("std");

pub const TABLE_MAX_COLS: usize = 8;
```

Make these `pub`: `TABLE_MAX_COLS`, `SourceLine`, `Heading`, `List`, `Link`, `nextSourceLine`, `cleanInline`, `cleanPlain`, `appendSlice`, `parseMarkdownLink`, `isFence`, `fenceLanguage`, `isHorizontalRule`, `headingBody`, `htmlHeadingBody`, `listBody`, `isSpace`, `looksLikeTableRow`, `isTableSeparatorLine`, `parseTableRowCells`, `isMarkdownTableStart`, `tableBlockEnd`. (Their internal cross-calls resolve within this module.)

### Step 1.2: Add the cleaned-line classifier (single authority for cleaned text + style)

Append to `src/markdown_text.zig`. This is the palette-free core of `prepareMarkdownLine`; the renderer will consume it for both text and styling.

```zig
pub const LineStyle = enum { blank, fence, rule, normal, heading, code, quote, list };

pub const CleanedLine = struct {
    style: LineStyle,
    text: []const u8 = "",
    heading_level: u8 = 0,
    fence_label: []const u8 = "",
};

/// Cleaned display text + style for one source line. `buf` holds the cleaned
/// bytes; the returned `text` is a slice into `buf`. Mirrors the renderer's
/// prepareMarkdownLine text logic exactly.
pub fn cleanedLine(buf: *[1024]u8, raw_line: []const u8, in_code: bool) CleanedLine {
    const trimmed = std.mem.trimLeft(u8, raw_line, " \t");
    if (trimmed.len == 0) return .{ .style = .blank };
    if (isFence(trimmed)) return .{ .style = .fence, .fence_label = fenceLanguage(trimmed) };
    if (isHorizontalRule(trimmed)) return .{ .style = .rule };
    if (in_code) return .{ .style = .code, .text = cleanPlain(buf, raw_line) };
    if (headingBody(trimmed)) |heading| {
        return .{ .style = .heading, .text = cleanInline(buf, heading.body), .heading_level = @intCast(heading.level) };
    }
    if (htmlHeadingBody(trimmed)) |heading| {
        return .{ .style = .heading, .text = cleanInline(buf, heading.body), .heading_level = @intCast(heading.level) };
    }
    if (std.mem.startsWith(u8, trimmed, ">")) {
        return .{ .style = .quote, .text = cleanInline(buf, std.mem.trimLeft(u8, trimmed[1..], " \t")) };
    }
    if (listBody(trimmed)) |list| {
        const body = cleanInline(buf, list.body);
        if (body.len + list.marker.len <= buf.len) {
            std.mem.copyBackwards(u8, buf[list.marker.len .. list.marker.len + body.len], body);
            @memcpy(buf[0..list.marker.len], list.marker);
            return .{ .style = .list, .text = buf[0 .. list.marker.len + body.len] };
        }
        return .{ .style = .list, .text = body };
    }
    return .{ .style = .normal, .text = cleanInline(buf, trimmed) };
}
```

### Step 1.3: Add table display helpers (consistent offset accounting for tables)

Append to `src/markdown_text.zig`:

```zig
/// Append a table block's display text: each non-separator row's cleaned cell
/// text joined by " | ", followed by '\n'. Returns nothing; see tableBlockDisplayLen.
pub fn appendTableBlockDisplay(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    text: []const u8,
    start: usize,
    end: usize,
) !void {
    var cursor = start;
    while (cursor < end) {
        const info = nextSourceLine(text, cursor);
        cursor = info.next;
        if (isTableSeparatorLine(info.line)) continue;
        var cells: [TABLE_MAX_COLS][]const u8 = .{""} ** TABLE_MAX_COLS;
        const count = parseTableRowCells(info.line, &cells);
        for (0..count) |i| {
            if (i > 0) try out.appendSlice(allocator, " | ");
            var clean_buf: [256]u8 = undefined;
            try out.appendSlice(allocator, cleanInline(&clean_buf, cells[i]));
        }
        try out.append(allocator, '\n');
    }
}

/// Byte length appendTableBlockDisplay would append. Used to advance the
/// display cursor in the renderer without building the text.
pub fn tableBlockDisplayLen(text: []const u8, start: usize, end: usize) usize {
    var total: usize = 0;
    var cursor = start;
    while (cursor < end) {
        const info = nextSourceLine(text, cursor);
        cursor = info.next;
        if (isTableSeparatorLine(info.line)) continue;
        total += tableRowDisplayLen(info.line) + 1; // +1 for '\n'
    }
    return total;
}

/// Display offset (within a table block) of the row at `row_index` (counting
/// only non-separator rows). Used by the hit-test to map a table click.
pub fn tableRowDisplayOffsetWithin(text: []const u8, start: usize, end: usize, row_index: usize) usize {
    var offset: usize = 0;
    var row: usize = 0;
    var cursor = start;
    while (cursor < end) {
        const info = nextSourceLine(text, cursor);
        cursor = info.next;
        if (isTableSeparatorLine(info.line)) continue;
        if (row == row_index) return offset;
        offset += tableRowDisplayLen(info.line) + 1;
        row += 1;
    }
    return offset;
}

fn tableRowDisplayLen(line: []const u8) usize {
    var cells: [TABLE_MAX_COLS][]const u8 = .{""} ** TABLE_MAX_COLS;
    const count = parseTableRowCells(line, &cells);
    var total: usize = 0;
    for (0..count) |i| {
        if (i > 0) total += 3; // " | "
        var clean_buf: [256]u8 = undefined;
        total += cleanInline(&clean_buf, cells[i]).len;
    }
    return total;
}
```

### Step 1.4: Add `allocDisplayText` (the canonical display text)

Append to `src/markdown_text.zig`:

```zig
/// Build the message's cleaned display text — the exact text the transcript
/// renders, in one contiguous buffer. Selection offsets index into this.
pub fn allocDisplayText(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    if (std.mem.trim(u8, content, " \t\r\n").len == 0) return out.toOwnedSlice(allocator);

    var cursor: usize = 0;
    var in_code = false;
    var buf: [1024]u8 = undefined;
    while (cursor < content.len) {
        if (!in_code and isMarkdownTableStart(content, cursor)) {
            const end = tableBlockEnd(content, cursor);
            try appendTableBlockDisplay(allocator, &out, content, cursor, end);
            cursor = end;
            continue;
        }
        const info = nextSourceLine(content, cursor);
        cursor = info.next;
        const cl = cleanedLine(&buf, info.line, in_code);
        if (cl.style == .fence) in_code = !in_code;
        try out.appendSlice(allocator, cl.text);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}
```

### Step 1.5: Write failing tests for the module

Append to `src/markdown_text.zig`:

```zig
const testing = std.testing;

test "allocDisplayText strips inline emphasis and code spans" {
    const out = try allocDisplayText(testing.allocator, "**生成的完整 `Markdown`**");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("生成的完整 Markdown\n", out);
}

test "allocDisplayText collapses links to label" {
    const out = try allocDisplayText(testing.allocator, "see [docs](https://x.y) now");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("see docs now\n", out);
}

test "allocDisplayText keeps heading and list text without markers" {
    const out = try allocDisplayText(testing.allocator, "# Title\n- item one\n- item two");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Title\n- item one\n- item two\n", out);
}

test "allocDisplayText plain text is unchanged except trailing newline" {
    const out = try allocDisplayText(testing.allocator, "alpha beta gamma");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("alpha beta gamma\n", out);
}
```

### Step 1.6: Register the module in the test harness

In `src/test_main.zig`, add after line 619 (`_ = @import("markdown_preview.zig");`):

```zig
    _ = @import("markdown_text.zig");
```

### Step 1.7: Replace relocated definitions in the renderer with alias consts

In `src/renderer/ai_chat_renderer.zig`: **delete** the definitions of every function/struct/const listed in "Background facts" (they now live in `markdown_text.zig`). Near the top imports (after line 6, `const composer_layout = @import("../ai_chat_composer_layout.zig");`), add:

```zig
const md = @import("../markdown_text.zig");

const TABLE_MAX_COLS = md.TABLE_MAX_COLS;
const SourceLine = md.SourceLine;
const Heading = md.Heading;
const List = md.List;
const Link = md.Link;
const nextSourceLine = md.nextSourceLine;
const cleanInline = md.cleanInline;
const cleanPlain = md.cleanPlain;
const appendSlice = md.appendSlice;
const parseMarkdownLink = md.parseMarkdownLink;
const isFence = md.isFence;
const fenceLanguage = md.fenceLanguage;
const isHorizontalRule = md.isHorizontalRule;
const headingBody = md.headingBody;
const htmlHeadingBody = md.htmlHeadingBody;
const listBody = md.listBody;
const isSpace = md.isSpace;
const looksLikeTableRow = md.looksLikeTableRow;
const isTableSeparatorLine = md.isTableSeparatorLine;
const parseTableRowCells = md.parseTableRowCells;
const isMarkdownTableStart = md.isMarkdownTableStart;
const tableBlockEnd = md.tableBlockEnd;
```

Existing call sites (e.g. `cleanInline(&buf, x)`, `nextSourceLine(text, i)`) keep compiling against the aliases — do not change them.

### Step 1.8: Build and run tests

- [ ] Run: `zig build test`
  Expected: PASS, including the four new `markdown_text` tests.
- [ ] Run: `zig build`
  Expected: compiles (renderer still builds against the alias consts).

### Step 1.9: Commit

```bash
git add src/markdown_text.zig src/renderer/ai_chat_renderer.zig src/test_main.zig
git commit -m "Extract pure markdown text + display-text helpers into markdown_text.zig"
```

---

## Task 2: Make `prepareMarkdownLine` delegate cleaning to `markdown_text`

This removes the duplicate cleaning logic so the renderer and `allocDisplayText` share one implementation (drift is now impossible). Behavior of the rendered transcript must be unchanged.

**Files:**
- Modify: `src/renderer/ai_chat_renderer.zig:1183-1282` (`prepareMarkdownLine` body)

### Step 2.1: Rewrite `prepareMarkdownLine` to map `CleanedLine` → view metrics

Replace the body of `prepareMarkdownLine` (keep its signature `fn prepareMarkdownLine(buf: *[1024]u8, raw_line: []const u8, in_code: bool, palette: MarkdownPalette) MarkdownPreparedLine`) with:

```zig
    const base_h = lineHeight();
    const cl = md.cleanedLine(buf, raw_line, in_code);
    return switch (cl.style) {
        .blank => .{ .kind = .blank, .line_h = blankLineHeight(), .color = palette.muted },
        .fence => .{ .kind = .fence, .line_h = fenceLineHeight(), .color = palette.muted, .fence_label = cl.fence_label },
        .rule => .{ .kind = .rule, .line_h = @round(base_h * 0.78), .color = palette.muted },
        .code => .{
            .kind = .text,
            .text = cl.text,
            .color = palette.accent,
            .line_h = base_h,
            .background = palette.code_bg,
            .left_rule = palette.accent,
        },
        .heading => .{
            .kind = .text,
            .text = cl.text,
            .color = if (cl.heading_level <= 2) palette.strong else palette.normal,
            .line_h = switch (cl.heading_level) {
                1 => @round(base_h * 1.72),
                2 => @round(base_h * 1.45),
                3 => @round(base_h * 1.24),
                else => @round(base_h * 1.10),
            },
            .background = if (cl.heading_level <= 2) palette.heading_bg else null,
            .left_rule = if (cl.heading_level <= 2) palette.accent else null,
            .underline = cl.heading_level <= 2,
        },
        .quote => .{
            .kind = .text,
            .text = cl.text,
            .color = palette.muted,
            .indent = 16,
            .line_h = base_h,
            .background = palette.quote_bg,
            .left_rule = palette.accent,
        },
        .list => .{ .kind = .text, .text = cl.text, .color = palette.normal, .indent = 12, .line_h = base_h },
        .normal => .{ .kind = .text, .text = cl.text, .color = palette.normal, .line_h = base_h },
    };
```

(This reproduces the exact colors/heights/backgrounds/indents of the original switch. `MarkdownPreparedLine` and its `kind` enum are unchanged.)

### Step 2.2: Build and run tests

- [ ] Run: `zig build`
  Expected: compiles.
- [ ] Run: `zig build test`
  Expected: PASS.

### Step 2.3: Manual render check

- [ ] Run: `zig build` then launch the app, open an AI chat with an assistant message containing a heading, a bullet list, **bold**, `code`, a `[link](url)`, and a table. Confirm the transcript renders the same as before (headings styled, list markers shown, markup hidden, table boxed).

### Step 2.4: Commit

```bash
git add src/renderer/ai_chat_renderer.zig
git commit -m "Render markdown via shared markdown_text.cleanedLine (no behavior change)"
```

---

## Task 3: Hit-test returns display-text offsets

Change the click→offset functions so they walk the **cleaned** text and return offsets into the display text. They already iterate the same way `allocDisplayText` does; we add a `display_cursor` that advances by the identical rule.

**Files:**
- Modify: `src/renderer/ai_chat_renderer.zig` — `byteOffsetForMarkdownPoint` (1366), `byteOffsetForWrappedPoint` (1455), `byteOffsetForLineX` (1494), `byteOffsetForTablePoint` (1438)

### Step 3.1: Rewrite `byteOffsetForMarkdownPoint`

Replace its body (signature unchanged: `fn byteOffsetForMarkdownPoint(text: []const u8, x: f32, top_px: f32, max_w: f32, px: f32, py: f32) usize`) with:

```zig
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return 0;
    if (py <= top_px) return 0;

    const palette = markdownPalette(AppWindow.g_theme.background, AppWindow.g_theme.foreground, AppWindow.g_theme.cursor_color);
    var cursor: usize = 0;
    var display_cursor: usize = 0;
    var current_top = top_px;
    var in_code = false;

    while (cursor < text.len) {
        if (!in_code and isMarkdownTableStart(text, cursor)) {
            const start = cursor;
            const end = tableBlockEnd(text, cursor);
            const block_h = tableBlockHeight(text, cursor, end);
            if (py < current_top + block_h) {
                const row_h = tableRowHeight();
                const row_index: usize = @intFromFloat(@max(0.0, @floor((py - current_top) / row_h)));
                return display_cursor + md.tableRowDisplayOffsetWithin(text, start, end, row_index);
            }
            current_top += block_h;
            display_cursor += md.tableBlockDisplayLen(text, start, end);
            cursor = end;
            continue;
        }

        const info = nextSourceLine(text, cursor);
        cursor = info.next;

        var clean_buf: [1024]u8 = undefined;
        const prepared = prepareMarkdownLine(&clean_buf, info.line, in_code, palette);
        switch (prepared.kind) {
            .blank => {
                if (py < current_top + prepared.line_h) return display_cursor;
                current_top += prepared.line_h;
            },
            .fence => {
                if (py < current_top + prepared.line_h) return display_cursor;
                current_top += prepared.line_h;
                in_code = !in_code;
            },
            .rule => {
                if (py < current_top + prepared.line_h) return display_cursor;
                current_top += prepared.line_h;
            },
            .text => {
                const line_w = @max(1.0, max_w - prepared.indent);
                const body_h = plainContentHeight(prepared.text, line_w, prepared.line_h);
                if (py < current_top + body_h) {
                    return byteOffsetForWrappedPoint(
                        prepared.text,
                        display_cursor,
                        x + prepared.indent,
                        current_top,
                        line_w,
                        prepared.line_h,
                        px,
                        py,
                    );
                }
                current_top += body_h;
            },
        }
        display_cursor += prepared.text.len + 1;
    }

    return display_cursor;
```

Key changes vs the original: it passes `prepared.text` (cleaned) instead of `info.line` (raw) to `byteOffsetForWrappedPoint`; the base offset is `display_cursor` (cleaned space); every line advances `display_cursor += prepared.text.len + 1`; tables advance via `md.tableBlockDisplayLen` and map clicks via `md.tableRowDisplayOffsetWithin`. Note the fence/rule/blank branches now `return display_cursor` (start of that line in display space) and the `display_cursor += prepared.text.len + 1` runs for every non-table line. `byteOffsetForTablePoint` is no longer called — delete it (Step 3.3).

### Step 3.2: Confirm `byteOffsetForWrappedPoint` / `byteOffsetForLineX` need no change

These already take a `text` slice + `base_offset` and walk `text` with `nextCodepoint`, returning `base_offset + i`. Because Task 3.1 now passes the cleaned `prepared.text` and a display-space `base_offset`, they return display offsets unchanged. **No edit needed** — but verify by reading them after Step 3.1.

### Step 3.3: Delete `byteOffsetForTablePoint`

Remove the now-unused `fn byteOffsetForTablePoint(...)` (was lines 1438-1453). (If the build warns about it being unused before deletion, that confirms it's dead.)

### Step 3.4: Build

- [ ] Run: `zig build`
  Expected: compiles, no unused-function error.
- [ ] Run: `zig build test`
  Expected: PASS (no renderer tests, but nothing else broke).

### Step 3.5: Commit

```bash
git add src/renderer/ai_chat_renderer.zig
git commit -m "Hit-test transcript clicks in cleaned display-text offset space"
```

---

## Task 4: Selection highlight uses cleaned text + display offsets

The highlight box must cover the cleaned glyphs that are actually drawn. Change `renderMarkdownContent` to track `display_cursor` and pass cleaned text + display base to `renderWrappedSelection`.

**Files:**
- Modify: `src/renderer/ai_chat_renderer.zig` — `renderMarkdownContent` (1284-1364)

### Step 4.1: Track `display_cursor` in `renderMarkdownContent`

In `renderMarkdownContent`, add `var display_cursor: usize = 0;` next to `var cursor: usize = 0;`. Then update the table branch to advance it. The current table branch is:

```zig
        if (!in_code and isMarkdownTableStart(text, cursor)) {
            const end = tableBlockEnd(text, cursor);
            current_top += renderTableBlock(text, cursor, end, x, current_top, max_w, window_height, palette);
            cursor = end;
            continue;
        }
```

Replace with:

```zig
        if (!in_code and isMarkdownTableStart(text, cursor)) {
            const table_start = cursor;
            const end = tableBlockEnd(text, cursor);
            current_top += renderTableBlock(text, cursor, end, x, current_top, max_w, window_height, palette);
            display_cursor += md.tableBlockDisplayLen(text, table_start, end);
            cursor = end;
            continue;
        }
```

### Step 4.2: Pass cleaned text + display base to the highlight, then advance

In the `.text` branch of `renderMarkdownContent`, the current `renderWrappedSelection` call passes `info.line` and `line_start`. Change it to pass `prepared.text` and `display_cursor`:

```zig
                renderWrappedSelection(
                    prepared.text,
                    display_cursor,
                    x + prepared.indent,
                    current_top,
                    @max(1.0, max_w - prepared.indent),
                    prepared.line_h,
                    selection_range,
                    window_height,
                    clip_bottom_top_px,
                );
```

At the **end of the `while` loop body** (after the `switch`), advance the cursor for every non-table line:

```zig
        display_cursor += prepared.text.len + 1;
```

Make sure this runs for `.blank`, `.fence`, `.rule`, and `.text` lines (place it after the `switch (prepared.kind) { … }` block, before the loop's closing brace), matching `allocDisplayText`.

### Step 4.3: `renderWrappedSelection` needs no signature change

It already takes `text` + `base_offset` and walks with `nextCodepoint` + `measureText`. With cleaned text + display base it now highlights the drawn glyphs. Verify by reading it; **no edit needed**.

### Step 4.4: Build and manual check

- [ ] Run: `zig build`
  Expected: compiles.
- [ ] Run: `zig build test`
  Expected: PASS.
- [ ] Manual: launch app, open an AI chat, drag-select across a **bold** / `code` / link span. The highlight box must sit exactly under the visible characters (not shifted), and dragging from just left of the first glyph to just right of the last selects the whole visible run.

### Step 4.5: Commit

```bash
git add src/renderer/ai_chat_renderer.zig
git commit -m "Highlight transcript selection over cleaned glyphs in display-text space"
```

---

## Task 5: Copy returns the cleaned display substring

**Files:**
- Modify: `src/ai_chat.zig` — `allocTranscriptSelectionTextLocked` (2060-2070), imports
- Test: `src/ai_chat.zig` (add a markdown selection test near the existing ones at ~6060-6112)

### Step 5.1: Write the failing test

Add to `src/ai_chat.zig` after the existing "clamps to utf8 boundaries" test (after line 6112):

```zig
test "ai chat transcript selection copies cleaned markdown text" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }

    try session.messages.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "**生成的完整 `Markdown`**"),
    });

    // Display text is "生成的完整 Markdown\n"; select the whole visible run.
    session.beginTranscriptSelection(0, 0);
    session.updateTranscriptSelection(0, "生成的完整 Markdown".len);

    const copied = try session.allocClipboardText(allocator);
    defer allocator.free(copied);
    try std.testing.expectEqualStrings("生成的完整 Markdown", copied);
}
```

### Step 5.2: Run the test to verify it fails

- [ ] Run: `zig build test`
  Expected: FAIL — the current code slices raw `msg.content`, so `copied` would contain `**生成的完整 \`Markdow` (markup + shifted), not `生成的完整 Markdown`.

### Step 5.3: Add the import

Near the top imports of `src/ai_chat.zig`, add:

```zig
const markdown_text = @import("markdown_text.zig");
```

### Step 5.4: Rewrite `allocTranscriptSelectionTextLocked` to slice display text

Replace its body (signature unchanged):

```zig
    fn allocTranscriptSelectionTextLocked(self: *Session, allocator: std.mem.Allocator) (error{NoSelection} || std.mem.Allocator.Error)![]u8 {
        const selection = self.transcript_selection orelse return error.NoSelection;
        const range = selection.range() orelse return error.NoSelection;
        if (selection.message_index >= self.messages.items.len) return error.NoSelection;
        const msg = self.messages.items[selection.message_index];
        if (msg.role != .assistant) return error.NoSelection;
        const display = try markdown_text.allocDisplayText(allocator, msg.content);
        defer allocator.free(display);
        const start = clampUtf8Boundary(display, @min(range.start, display.len));
        const end = clampUtf8Boundary(display, @min(range.end, display.len));
        if (start >= end) return error.NoSelection;
        return allocator.dupe(u8, display[start..end]);
    }
```

### Step 5.5: Run tests

- [ ] Run: `zig build test`
  Expected: PASS — the new markdown test passes; the two existing plain-text selection tests still pass (plain content: display == raw + "\n", so offsets 6..10 → "beta" and 1..8 → "你好" are unchanged).

### Step 5.6: Commit

```bash
git add src/ai_chat.zig
git commit -m "Copy transcript selection as cleaned display text"
```

---

## Task 6: Ctrl+X cuts the input composer

**Files:**
- Modify: `src/ai_chat.zig` — add `cutInputSelection` (near `appendInputText`, ~1174)
- Modify: `src/input/clipboard.zig` — add `copyAiChatCutToClipboard` (near `copyAiChatToClipboard`, ~359)
- Modify: `src/input.zig` — add Ctrl+X handler (in the `activeAiChat()` block, ~1042) and import the new clipboard fn (~46)
- Test: `src/ai_chat.zig` (cut helper behavior)

### Step 6.1: Write the failing test for the cut helper

Add to `src/ai_chat.zig` near the other AI-chat tests (e.g. after the test added in Step 5.1):

```zig
test "ai chat cut input returns text and clears when selected" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }

    session.appendInputText("hello world");
    session.selectAll(); // sets input_select_all when input is non-empty

    const cut = try session.cutInputSelection(allocator);
    defer if (cut) |c| allocator.free(c);
    try std.testing.expect(cut != null);
    try std.testing.expectEqualStrings("hello world", cut.?);
    try std.testing.expectEqual(@as(usize, 0), session.input_len);

    const cut_again = try session.cutInputSelection(allocator);
    try std.testing.expect(cut_again == null);
}
```

### Step 6.2: Run to verify it fails

- [ ] Run: `zig build test`
  Expected: FAIL — `cutInputSelection` does not exist (compile error).

### Step 6.3: Implement `cutInputSelection`

Add to `src/ai_chat.zig` immediately after `appendInputText` (after line 1189):

```zig
    /// If the composer is selected (select-all) and non-empty, return a copy of
    /// the input text and clear the composer. Returns null otherwise (e.g. when
    /// only a read-only transcript selection is active).
    pub fn cutInputSelection(self: *Session, allocator: std.mem.Allocator) !?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.input_select_all or self.input_len == 0) return null;
        const text = try allocator.dupe(u8, self.input_buf[0..self.input_len]);
        self.input_len = 0;
        self.input_cursor = 0;
        self.input_scroll_row = 0;
        self.input_scroll_follow_cursor = true;
        self.input_select_all = false;
        self.suggestion_selected = 0;
        self.ensureSkillSuggestionsForInputLocked();
        return text;
    }
```

### Step 6.4: Run to verify the test passes

- [ ] Run: `zig build test`
  Expected: PASS.

### Step 6.5: Add `copyAiChatCutToClipboard`

Add to `src/input/clipboard.zig` immediately after `copyAiChatToClipboard` (after line 370):

```zig
pub fn copyAiChatCutToClipboard(chat: *AppWindow.ai_chat.Session) void {
    const allocator = AppWindow.g_allocator orelse return;
    const maybe_text = chat.cutInputSelection(allocator) catch return;
    const text = maybe_text orelse return;
    defer allocator.free(text);
    if (text.len == 0) return;
    if (copyTextToClipboard(text)) {
        overlays.showCopyToast(text.len);
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
        std.debug.print("Cut {} AI chat input bytes to clipboard\n", .{text.len});
    }
}
```

### Step 6.6: Re-export the new clipboard fn in `input.zig`

In `src/input.zig`, after line 46 (`const copyAiChatToClipboard = clipboard.copyAiChatToClipboard;`), add:

```zig
const copyAiChatCutToClipboard = clipboard.copyAiChatCutToClipboard;
```

### Step 6.7: Add the Ctrl+X handler

In `src/input.zig`, inside the `if (AppWindow.activeAiChat()) |chat| { … }` block at lines 1035-1046, add after the Ctrl+C handler (after line 1045):

```zig
        if (ev.ctrl and !ev.alt and ev.key_code == 0x58) { // Ctrl+X (cut input)
            copyAiChatCutToClipboard(chat);
            return;
        }
```

This consumes Ctrl+X for the AI chat (no fall-through to the terminal). When nothing is selected, `copyAiChatCutToClipboard` is a no-op and we still return — matching Ctrl+C, which also handles the AI chat exclusively.

### Step 6.8: Build and run tests

- [ ] Run: `zig build`
  Expected: compiles.
- [ ] Run: `zig build test`
  Expected: PASS.

### Step 6.9: Manual check

- [ ] Launch app, open an AI chat, type text in the composer, press Ctrl+A then Ctrl+X. Expected: input clears, clipboard holds the text (paste with Ctrl+V to confirm), a copy toast appears.

### Step 6.10: Commit

```bash
git add src/ai_chat.zig src/input/clipboard.zig src/input.zig
git commit -m "Add Ctrl+X to cut the AI chat input composer"
```

---

## Final verification

- [ ] Run: `zig build test` — all tests pass.
- [ ] Run: `zig build` — release/debug build succeeds.
- [ ] Manual end-to-end: in an AI chat with an assistant message containing `**生成的完整 \`Markdown\`**` (or similar inline markup), drag-select the visible `生成的完整 Markdown`; the highlight aligns with the glyphs and the copied text is exactly `生成的完整 Markdown` (no `*`/backticks, nothing dropped). Ctrl+A + Ctrl+X in the composer cuts the input.

---

## Self-review notes (author)

- **Spec coverage:** display-text single-source-of-truth (Tasks 1, 3, 4, 5); shared module imported by both renderer and model (Task 1.7, 5.3); copy = cleaned text (Task 5); Ctrl+X cut input only (Task 6); tests for `allocDisplayText`, markdown selection copy, and cut (Tasks 1.5, 5.1, 6.1). All covered.
- **Offset-accounting consistency:** the rule "non-table line ⇒ `text.len + 1`; table block ⇒ `tableBlockDisplayLen`" is applied identically in `allocDisplayText` (1.4), hit-test (3.1), and highlight (4.1-4.2). Table click mapping uses `tableRowDisplayOffsetWithin` (3.1). This is the single highest-risk area; the `allocDisplayText` tests plus the markdown selection test pin the model side, and Task 4.4 manually verifies highlight alignment.
- **Type consistency:** `CleanedLine`/`LineStyle` (1.2) consumed only by `prepareMarkdownLine` (2.1); `cutInputSelection` returns `!?[]u8` and is consumed by `copyAiChatCutToClipboard` (6.3, 6.5). `tableBlockDisplayLen`/`tableRowDisplayOffsetWithin`/`appendTableBlockDisplay` signatures match their call sites in 3.1/4.1/1.4.
- **Known limitation:** the renderer is not in the test harness, so hit-test (3.1) and highlight (4.1) correctness rely on manual checks (3.x/4.4) plus the shared, tested `markdown_text` accounting. `input.zig`'s Ctrl+X wiring is likewise verified manually (6.9); the cut logic itself is unit-tested in `ai_chat.zig` (6.1).
