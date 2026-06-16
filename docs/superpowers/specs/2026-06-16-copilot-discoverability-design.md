# Copilot Discoverability — "Edge Summon" + Platform-Native Homes

**Date:** 2026-06-16
**Status:** Design — pending review
**Related:** `2026-05-30-ai-copilot-sidebar-design.md` (the Copilot sidebar itself), `2026-06-04-whats-new-panel-design.md` (one-time version gate pattern)

---

## 概述（中文摘要）

问题：Copilot（`Ctrl/Cmd+Shift+A`，从当前终端**右边缘**滑出的侧栏）几乎没有可见入口，用户只能从直播里偶然得知。

核心思路：**把入口放回 Copilot 真正所在的地方 —— 终端右边缘**，而不是标题栏。终端内容区是 GPU 自绘的，三端像素级一致，这样就**绕开了 macOS/Windows 标题栏不对称**这个老大难。

- **主角（三端统一）：右边缘的「召唤握柄」** —— 平时近乎隐形，鼠标靠近右边缘才淡入一个小握柄，hover 弹出 `Copilot ⌃⇧A` 提示；点击 = 开/关侧栏。Copilot 打开后，这条边缘无缝变成现有的 resize 拖拽边。
- **首启一次性微闪（shimmer）** —— 新用户第一次进入终端时握柄轻闪一下（按版本/标志位 gate，复用 What's New 那套），之后永不再扰。
- **平台原生加成**：Windows/Linux **保留**标题栏 Copilot 图标（用户要求）；macOS 走原生菜单 `View ▸ Toggle Copilot`。
- **参考面（免费补全）**：快捷键浮层、命令中心补上 `Toggle Copilot ⌃⇧A`。

---

## Goals

1. A first-time user discovers Copilot **without watching a livestream or reading docs** — within the first session, passively.
2. The `Ctrl/Cmd+Shift+A` shortcut is **taught at the moment of intent**, not buried in a settings page.
3. **Zero permanent visual clutter** in the default resting state. Nothing new is permanently painted over the terminal.
4. **No forced cross-platform widget.** Each OS keeps its own idiom; macOS does not grow a fake titlebar icon.
5. Reuse existing infrastructure (the Copilot resize edge, the What's-New version gate, the onboarding-flag persistence, the titlebar button cluster) rather than inventing parallel systems.

## Non-Goals

- Changing what Copilot *is* or how it renders (the sidebar itself is unchanged).
- Adding a Copilot entry to the `+` session launcher dropdown. (Considered and rejected — see Alternatives. The launcher is a "new session" list; the toggle is a per-terminal action that does not belong there.)
- A persistent coachmark / nag popup.
- Onboarding a *new-tab* Copilot. This spec is about the **per-terminal sidebar toggle** (`toggle_ai_copilot`), which is the undiscovered feature. The "New Copilot tab" path already exists in the launcher and command center and is left as-is.

---

## The Core Insight

The macOS/Windows asymmetry the team worried about only exists because the obvious place to put an affordance *seemed* to be the titlebar — and the titlebar button cluster is compiled to zero width on macOS:

```zig
// src/renderer/titlebar.zig
pub const TITLEBAR_CONFIG_W: f32 = if (builtin.os.tag == .macos) 0 else 46;
pub const TITLEBAR_HELP_W:   f32 = if (builtin.os.tag == .macos) 0 else 46;
```

But Copilot does not live in the titlebar. It slides out from the **right edge of the terminal content area**, which is rendered identically on every platform. Putting the affordance there:

- **Dissolves the asymmetry** — it is GPU content-area chrome, pixel-identical on macOS / Windows / Linux.
- **Is spatially honest** — it sits exactly where the panel appears, teaching the mental model "Copilot comes from the right."
- **Unifies with an element that already exists** — when Copilot is open there is already a drag-to-resize divider on its left edge (`hitTestAiCopilotResizeHandle`, `g_ai_copilot_resize_hover`). The summon handle is the closed-state form of that same "Copilot edge."

The titlebar icon is kept **only as a free bonus where it is natural** (Windows/Linux), not as the backbone.

---

## Architecture Overview

Four cooperating pieces, plus three cheap "reference surface" additions.

| Piece | Platform | Role | New / Existing |
| --- | --- | --- | --- |
| **Edge summon handle** | all | Primary affordance: reveal-on-proximity handle at the terminal right edge; click → toggle | NEW renderer + hit-test |
| **One-time shimmer** | all | First-session glint of the handle, gated once | NEW (reuses gate pattern) |
| **Titlebar Copilot icon** | Win/Linux | Bonus persistent button in the right cluster | NEW (extends existing cluster) |
| **macOS View-menu item** | macOS | Native discoverability home | NEW (one line) |
| Shortcuts overlay entry | all | Reference | extend `startup_shortcuts.zig` |
| Command-center entry | all | Reference | extend `command_center_state.zig` |
| Minimal tooltip primitive | all | Hover hint for the handle (and reusable later) | NEW small renderer |

### Module boundaries (new + touched)

- **`src/copilot_hint_gate.zig`** *(NEW, pure, fast-suite)* — std-only decisions, no I/O, no GL:
  - `shimmerDecision(hint_shown: bool, active_tab_is_terminal: bool, copilot_open: bool, feature_enabled: bool) -> enum { shimmer, skip }` (mirrors `whats_new_gate.zig`).
  - `handleRevealTarget(mouse_x, mouse_y, window_w, titlebar_h, content_present: bool) -> f32` — returns target alpha [0,1] for the handle given cursor proximity to the right edge. Pure math → unit-testable without a window.
- **`src/ai_sidebar.zig`** *(TOUCHED)* — single source of truth for handle geometry:
  - `closedHandleRect(window_w, window_h, titlebar_h) -> Rect` — x/y/w/h of the closed-state handle (right edge, vertically centered). Keeps geometry out of the renderer and hit-test so they can never drift.
- **`src/renderer/overlays/copilot_edge_handle.zig`** *(NEW)* — owns the handle visuals + shimmer animation, structured like `startup_shortcuts.zig` (threadlocal state, time-based animation, an `opacity()`/`render…()` pair). Draws via `primitives.renderRoundedQuadAlpha` and the titlebar glyph text renderer.
- **`src/renderer/overlays/hint_tooltip.zig`** *(NEW, small)* — `renderHintTooltip(text, anchor_x, anchor_y, side)` — a rounded quad + titlebar text. The only tooltip primitive in the app today; scoped to the handle now, reusable by the titlebar icon later.
- **`src/input.zig`** *(TOUCHED)* — `hitTestCopilotEdgeHandle(x,y)` for the closed state; mouse-move updates the reveal-alpha target and tooltip-hover dwell; click dispatch → `AppWindow.toggleAiCopilot()`. `handleTopbarPress` gains a `hitTestCopilotButton` branch (Win/Linux only).
- **`src/renderer/titlebar.zig`** *(TOUCHED)* — `TITLEBAR_COPILOT_W = if (.macos) 0 else 46`; render block left of help; `renderFallbackCopilotIcon` vector fallback.
- **`src/platform/menu_macos.zig`** *(TOUCHED)* — `View ▸ Toggle Copilot` item + `id()`/`actionFromId` mapping for `toggle_ai_copilot`.
- **`src/platform/window_state.zig`** + its codec *(TOUCHED)* — persist `copilot_hint_shown` (mirror `aiSetupPrompted` / `recordSeenVersion` read-modify-write).
- **`src/renderer/overlays/startup_shortcuts.zig`**, **`src/command_center_state.zig`** + `src/input/command_dispatch.zig` *(TOUCHED)* — reference entries.
- **`src/config.zig`** + **`src/i18n.zig`** *(TOUCHED)* — optional `copilot-hint` key; tooltip / menu strings.

---

## Component 1 — The Edge Summon Handle (the hero)

### Geometry

`ai_sidebar.closedHandleRect` defines, in framebuffer pixels:

- **x:** flush to the window's right content edge. Copilot docks with `right_offset = 0`, so the closed-state edge is the framebuffer right edge. The handle pill is `HANDLE_W` wide ending at `window_w` (i.e. `x = window_w - HANDLE_W`).
- **y / height:** vertically centered in the content area (below the titlebar), `HANDLE_H` tall.
- Proposed constants (tunable in GUI review): `HANDLE_W = 6`, `HANDLE_H = 56`, corner radius `3`. Reveal proximity zone `REVEAL_ZONE_W = 28` measured from the right edge. Hit zone for the click is widened to `max(HANDLE_W, 12)` so it is comfortable to click without being visually heavy.

### States & visual

Resting alpha is driven by `handleRevealTarget` and animated (delta-time eased) toward the target each frame:

1. **Dormant** (cursor far from right edge): target alpha `0`. The handle is invisible. *Nothing is painted over the terminal in the common case.*
2. **Revealed** (cursor within `REVEAL_ZONE_W` of the right edge, in terminal content, active tab is a terminal): target alpha `~0.5`. A faint rounded pill fades in with a small left-pointing chevron `‹`.
3. **Hovered** (cursor over the hit rect): target alpha `~0.95` + accent tint (`mixColor(bg, cursor_color, …)`, matching the resize-edge color language already used for sidebar/explorer/browser edges). After a short dwell (`TOOLTIP_DWELL_MS = 350`), `hint_tooltip` shows `Copilot  <shortcut>` to the **left** of the handle, vertically centered on it.
4. **Open** (Copilot visible): the closed handle is not drawn; the existing resize divider at `bounds.left` takes over (1px, 2px on hover — the established pattern). The chevron flips conceptually to "drag to resize."

The shortcut string is derived live from the keybind via `keybind.formatTrigger` (as `startup_shortcuts.zig` does), so it renders `⌃⇧A` / `Ctrl+Shift+A` correctly per platform **and stays correct if the user rebinds it**. If the action is unbound, the tooltip shows just `Copilot` (no stale keys).

### Interaction

- **Click** on the hit rect → `AppWindow.toggleAiCopilot()`. Because `toggleAiCopilot()` is terminal-only and closes other right-docked panels first, no extra guarding is needed; the handle is simply not shown when the active tab is not a terminal (see Gating).
- **Cursor:** stays `.arrow` (it's a click target, not a resize edge) in the closed state; the open state keeps `.size_we` via the existing resize path.
- **Coexistence with the terminal scrollbar:** the scrollbar can occupy the far-right column. The handle is (a) reveal-on-proximity, (b) short and centered, (c) drawn as an overlay on top, and (d) its hit-test takes priority within its small rect when closed. The pill may be inset by the scrollbar width when a scrollbar is visible (read from the active surface) so they don't visually collide. Final inset tuned in GUI review.

### Gating (when the handle exists at all)

The handle is eligible only when **all** hold:
- `config.copilot_hint` is enabled (default on).
- The active tab is a terminal (`isActiveTabTerminal()`), i.e. Copilot has a valid target.
- Copilot is currently closed for that terminal.
- **No other right-docked panel occupies the edge.** Copilot shares the exclusive right slot with the browser / Jupyter / preview panel (`toggleAiCopilot()` closes the browser first). If any of those is currently visible, suppress the handle — otherwise it would paint over their content and clicking would yank the slot away unexpectedly. (The shortcut/menu/icon still work; only the edge handle defers.)
- The window is wide enough that opening Copilot is possible (`window_w - leftPanelsWidth() >= MIN_WIDTH + MIN_CONTENT_WIDTH`); otherwise suppress (no point summoning a panel that can't fit).

---

## Component 2 — One-Time Shimmer

A single, gentle, self-terminating animation that plants the seed "something lives at this edge." Precedent: the original iPhone "slide to unlock" shimmer.

- **Trigger:** first frame where the handle is *eligible* (all gating true) **and** `copilot_hint_shown == false` **and** Copilot has not been opened yet this run. Decided by `copilot_hint_gate.shimmerDecision`.
- **Animation:** a one-shot ~`SHIMMER_MS = 700` sequence on the handle — the pill peeks out to ~`0.85` alpha and a brightness glint sweeps vertically once, then eases back to dormant (`0`). Time-based via `std.time.milliTimestamp()` (same approach as the startup-shortcuts overlay and the close-button fade).
- **Record once:** immediately on trigger, call `window_state.recordCopilotHintShown(allocator)` (read-modify-write preserving geometry + other onboarding flags). Even if the app is killed mid-animation it never replays.
- **Respect "seen by use":** if a user opens Copilot (any path: shortcut, titlebar icon, menu) before the shimmer ever fires, set the flag too — they already discovered it; don't shimmer later.

This is the *only* moment the app proactively draws attention. It happens at most once per install (per the persisted flag), and never again.

---

## Component 3 — Titlebar Copilot Icon (Windows / Linux — kept by request)

A persistent button in the existing right-side cluster, **left of help**:

```
window right edge →   [Copilot] [ ? ] [ ⚙ ] [ – ] [ □ ] [ × ]
                         NEW    help  cfg    native caption buttons
```

- `TITLEBAR_COPILOT_W: f32 = if (builtin.os.tag == .macos) 0 else 46;` — naturally absent on macOS, exactly like config/help. **This is the entirety of the platform-asymmetry handling: the constant is 0 on macOS.**
- Position: `copilot_x = help_x - TITLEBAR_COPILOT_W` (help today is `config_x - TITLEBAR_HELP_W`). The title text's right clamp moves from `help_x` to `copilot_x`.
- Icon: a vector `renderFallbackCopilotIcon` (a small chat-bubble-with-spark, mirroring `renderFallbackHelpIcon` / `renderFallbackGearIcon`) is the spec'd, font-independent path. If a suitable glyph exists in the loaded icon font it may be used via `font.loadIconGlyph` with the fallback as backstop — but the vector fallback is the contract, so there is no dependency on a specific codepoint.
- Hover: same `hover_bg` quad as help/config.
- **State styling (nice touch):** the icon reflects Copilot state — tinted/active when Copilot is open for the active tab, dimmed when the active tab is not a terminal (no target). It doubles as a status indicator.
- Hit-test: `handleTopbarPress` gains `if (hitTestCopilotButton(xpos, …)) { AppWindow.toggleAiCopilot(); return; }`, placed alongside the existing help/config branches. On a non-terminal tab the click is a no-op (mirrors `toggleAiCopilot`'s own guard) and the icon is shown dimmed.

---

## Component 4 — macOS Native Menu Item

In `menu_macos.zig`, View submenu, beside the existing `Toggle Tab Sidebar`:

```zig
wispterm_macos_menu_add_item("Toggle Copilot", id(.toggle_ai_copilot), "a", ModCtrl | ModShift);
```

Plus the `id()` / `actionFromId` round-trip mapping for `toggle_ai_copilot`. This is the *correct, easy* macOS home — proving "hard on macOS" was only true for a titlebar icon, not for discoverability in general.

---

## Component 5 — Reference Surfaces (cheap, universal)

So keyboard-first users who never mouse to the edge still learn it:

1. **Startup shortcuts overlay** (`startup_shortcuts.zig`): add
   `.{ .kind = .action, .first = .toggle_ai_copilot, .action = "Toggle Copilot", .action_zh = "开 / 关 Copilot" }`.
   Keys auto-derive from the live binding (`.action` entries already do this).
2. **Command center** (`command_center_state.zig`): add a `Toggle Copilot` entry → new `CommandAction.toggle_ai_copilot`, dispatched in `command_dispatch.zig`/`input.zig` to `AppWindow.toggleAiCopilot()`. (Distinct from the existing "New Copilot" = new-tab entry.)

---

## Configuration

- `copilot-hint` (bool, default **true**) in `config.zig` — master switch for the edge handle + shimmer. Power users who want a perfectly bare terminal can disable it. The titlebar icon and menu item are not gated by this (they're standard chrome). Mirrors the `whats-new-on-update` toggle pattern.

## i18n

New keys (English source + zh-CN): tooltip label `Copilot` (likely reuse existing), menu label "Toggle Copilot" / "开/关 Copilot", overlay action label, command-center title/detail. Follow the existing `i18n.zig` + `startup_shortcuts` `action_zh` conventions.

---

## Platform Matrix

| Surface | macOS | Windows | Linux |
| --- | --- | --- | --- |
| Edge summon handle + shimmer | ✅ | ✅ | ✅ |
| Hover tooltip (shortcut) | ✅ | ✅ | ✅ |
| Titlebar Copilot icon | ✖ (cluster is 0-width) | ✅ | ✅ |
| Native menu item | ✅ (View) | ✖ (no native menu bar) | ✖ |
| Shortcuts overlay + command center | ✅ | ✅ | ✅ |

Every platform has **at least** the universal edge handle + reference surfaces, plus its own native bonus. No platform gets a foreign-looking widget.

---

## Data Flow

1. **Mouse move** → `input.zig` computes proximity → updates `copilot_edge_handle` target alpha (via `handleRevealTarget`) and tooltip-hover dwell timer. Requests a repaint when the target changes.
2. **Render frame** → if Copilot closed and eligible, `copilot_edge_handle.render(...)` eases alpha, draws pill/chevron, runs/queues shimmer, draws tooltip if dwell elapsed. If Copilot open, the existing resize-edge render path runs instead.
3. **Click on handle** → `toggleAiCopilot()` → panel opens; handle render path yields to resize-edge path next frame.
4. **First eligibility** → `shimmerDecision` → if `shimmer`, start one-shot + `recordCopilotHintShown`.

## Error / Edge Handling

- **No window / no active surface:** geometry helpers return null/empty; nothing renders (guards mirror `hitTestAiCopilotResizeHandle`).
- **Active tab not a terminal:** handle suppressed; titlebar icon dimmed; menu item still issues the action (no-op if no terminal — matches today).
- **Very narrow window:** handle suppressed (can't fit a panel).
- **Rebound / unbound shortcut:** tooltip/overlay/menu reflect the live binding; unbound → label without keys.
- **State file unwritable:** `recordCopilotHintShown` is best-effort (like other onboarding writes); worst case the shimmer may replay on next launch — acceptable, never crashes.

---

## Testing Strategy

**Fast suite (pure, no GL/window):**
- `copilot_hint_gate`: `shimmerDecision` truth table (flag set/unset × terminal/non-terminal × open/closed × enabled/disabled); `handleRevealTarget` proximity math (far → 0, near → reveal, hovered handled by caller).
- `ai_sidebar.closedHandleRect`: x at right edge, centered y, suppressed when window too narrow.
- `startup_shortcuts`: the new entry formats its keys from a known binding.
- `command_center_state`: the `Toggle Copilot` entry exists and maps to the action.

**test-full / native:**
- `hitTestCopilotEdgeHandle` and `hitTestCopilotButton` rect math.
- Persistence round-trip for `copilot_hint_shown` (posix test, alongside existing window-state tests) — set, reload, assert; and that geometry + other onboarding flags survive the read-modify-write.
- `menu_macos` `actionFromId` round-trips `toggle_ai_copilot` (macOS-only; skips elsewhere).

**GUI (manual, all three OSes):** shimmer timing/feel, reveal easing, tooltip dwell + placement, scrollbar coexistence, titlebar icon active/dim states, macOS menu item, and that the resting state is truly invisible.

---

## Rollout

Single PR is fine (the pieces are small and cohesive), but the natural commit order for review is:
1. Pure core: `copilot_hint_gate` + `ai_sidebar.closedHandleRect` (+ fast tests).
2. Handle renderer + tooltip + input wiring (universal hero).
3. Shimmer + persistence flag.
4. Titlebar icon (Win/Linux).
5. macOS menu item.
6. Reference surfaces + config + i18n.

Ship behind the `copilot-hint` default-on config so it can be disabled if field feedback finds it noisy.

---

## Alternatives Considered

- **Forced symmetric titlebar icon (all platforms).** Rejected: impossible on macOS without faking chrome the platform deliberately omits; this was the original asymmetry trap.
- **A row in the `+` session launcher dropdown.** Rejected as the *backbone*: the launcher is a "new session" list; a per-terminal toggle is a category error there, and a row that opens a new tab while the shortcut toggles a sidebar would be a behavior/label mismatch a careful user would notice. (The new-tab Copilot already lives in the command center.)
- **Persistent coachmark / nag toast.** Rejected: permanent or repeated attention-grabbing is exactly the "突兀" we're avoiding. The one-time shimmer teaches once and disappears.
- **Settings-only discoverability.** Rejected: users don't read settings to discover features.

---

## Open Questions (for GUI review, not blocking)

1. Exact handle dimensions, reveal-zone width, and shimmer duration/curve — tune live.
2. Whether the titlebar icon should also carry the one-time shimmer on Win/Linux, or whether the edge handle alone is enough there.
3. Scrollbar inset amount when a terminal scrollbar is visible.
