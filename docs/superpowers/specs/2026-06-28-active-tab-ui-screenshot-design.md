# Active-tab UI screenshot tool

**Date:** 2026-06-28
**Status:** Design - approved by user, pending spec review

## Problem

When a request comes from WeChat, the agent can inspect terminal text through
`terminal_snapshot`, but the user sometimes needs to see the actual WispTerm UI:
split layout, preview panes, Copilot/AI chat screens, overlays, and the visual
state of a panel. Text snapshots do not cover that.

The first version only needs to capture what the user can currently see in the
active window. Capturing non-active tabs would require hidden rendering or tab
switching and is intentionally out of scope.

## Ghostty reference

Ghostty has no comparable WeChat or AI tool surface, and the GitHub tree search
shows no terminal screenshot/capture tool. The relevant alignment is
architectural: Ghostty keeps VT terminal state separate from the host renderer.
WispTerm should do the same. Screenshot capture belongs at the UI/render host
boundary, not in `remote_snapshot.zig`, libghostty-vt state, or terminal text
serialization.

## Decision

Add a first-party agent tool named `ui_screenshot`.

The tool captures a PNG from the active WispTerm tab and returns the local file
path plus basic metadata. It does not send anything to WeChat itself; the agent
can call the existing `weixin_send_attachment(kind=image, path=...)` tool when
the current request came from WeChat.

Parameters:

```json
{
  "target": "focused_panel | active_tab",
  "surface_id": "optional"
}
```

Defaults:

- `target` defaults to `focused_panel`.
- `surface_id` is optional and only applies to terminal panels in the active tab.
- Aliases `focused`, `active`, and `current` resolve the same way terminal tools
  already resolve focused surfaces.

## Behavior

- Terminal active tab:
  - `focused_panel` captures the focused split panel.
  - `focused_panel + surface_id` captures that terminal panel if it is in the
    active tab.
  - `active_tab` captures the active tab's visible content area, including
    split panels, preview panes, the Copilot sidebar, and overlays that are
    currently drawn.
- Dedicated Copilot or AI chat tab:
  - `focused_panel` falls back to `active_tab`.
  - The PNG captures the visible AI chat page.
- Unsupported or unavailable state:
  - No window, minimized window, or zero framebuffer size returns a clear tool
    error.
  - A `surface_id` outside the active tab returns a clear "not in active tab"
    error and lists active-tab terminal surfaces when available.

## Architecture

The agent tool layer runs off the UI thread, but framebuffer access must happen
on the UI thread with the render context current. The tool therefore routes
through a new `ToolHost` callback:

```zig
uiScreenshot(ctx, allocator, target, surface_id) !UiScreenshotResult
```

The real AppWindow host implements the callback by marshaling a synchronous UI
thread request, mirroring the existing agent tab-control and WeChat control
bridges. The UI thread handler:

1. Ensures there is a freshly rendered frame for the active tab.
2. Computes the capture rectangle:
   - `active_tab`: visible tab/content area in framebuffer pixels.
   - `focused_panel`: the matching `split_layout.g_split_rects` rectangle.
3. Reads pixels from the current framebuffer.
4. Flips rows from GL bottom-left order into PNG top-left order.
5. Writes a PNG into the existing local agent/WispTerm files area.
6. Returns `{ path, width, height, target }`.

PNG encoding should use existing vendored/native capability, not a new
dependency. Prefer a tiny local encoder wrapper around the available platform or
vendored PNG path; add the minimum module needed only if no reusable writer
exists.

## Tool integration

- `src/tools/first_party.zig`: add `ui_screenshot` under `.terminal` or
  `.integration` (the tool is UI-level but mainly serves agent observation).
- `src/assistant/conversation/protocol.zig`: advertise the schema.
- `src/agent_tools/mod.zig`: parse arguments and call the `ToolHost` callback.
- `src/assistant/conversation/types.zig`: add result/callback types.
- AppWindow side: add the UI-thread request/handler and screenshot implementation
  in a feature-owned module where practical, with only the narrow bridge in
  `AppWindow.zig`.

## Non-goals

- No non-active tab screenshot.
- No hidden/offscreen re-render of arbitrary tabs.
- No automatic WeChat send inside `ui_screenshot`.
- No screenshot history browser or UI button.
- No OCR or image analysis. The model only receives a file path unless it asks
  to send or inspect the image through existing channels.

## Testing

- Unit test argument parsing and target defaults in the agent tool layer.
- Unit test active-tab surface matching: active-tab surface succeeds,
  non-active-tab surface is rejected.
- Unit test schema emission includes `ui_screenshot` and its parameters.
- Source-scan or small pure test for row-flip/rectangle clamping.
- Manual smoke on the real app:
  - terminal single panel: `focused_panel`;
  - terminal split: each active-tab panel by `surface_id`;
  - `active_tab` with Copilot sidebar open;
  - dedicated AI chat/Copilot tab falls back from `focused_panel` to
    `active_tab`;
  - WeChat flow: `ui_screenshot` then `weixin_send_attachment`.
