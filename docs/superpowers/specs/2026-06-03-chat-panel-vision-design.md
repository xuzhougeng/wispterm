# Chat Panel Vision (image) support — design

Date: 2026-06-03
Branch: `worktree-feat-chat-panel-visual`

## Goal

Let users send pasted images to vision-capable AI models from the chat panel.

1. Add a per-profile **Vision** toggle (default OFF) to the AI Agent config form.
2. In the chat composer (chat tab and copilot sidebar), **Ctrl+Shift+V** pastes an
   image from the clipboard.
3. If the model's profile has Vision ON, the pasted image is attached to the next
   message and sent to the model. If Vision is OFF, the image is dropped, a debug
   log line is written, and a brief toast tells the user why.

## Core decision (approved: A)

Images attach to the user `Message` and are **re-sent on every request turn for the
life of the in-memory session** (true multi-turn vision). Image bytes are **not**
written to the on-disk history JSON in this version; after a resume, only message
text survives. (Approach B — send images only on the paste turn — was rejected
because the model would "forget" the image on follow-up questions.)

## Components

### 1. Profile "Vision" field (default off)

- `src/renderer/overlays/profile_codec.zig`
  - `AiField` gains `vision = 11`; `AI_FIELD_COUNT` 11 → 12.
  - `decodeAiProfileLine` defaults `vision` to `"off"` when the field is absent or
    empty, exactly like the existing `max_tokens` legacy handling, so profiles
    written by older builds still load.
- `src/ai_chat_protocol.zig`: add `pub const DEFAULT_VISION = "off";`.
- AI profile form (`src/renderer/overlays.zig`): add a **Vision** row near
  *Thinking* that toggles `enabled`/`disabled` (display) the same way Thinking and
  Stream do. Persisted by the existing profile Save path (writes all fields).

### 2. Session vision flag

- `Session` (`src/ai_chat.zig`) gains `vision_enabled: bool = false`, parsed from the
  profile `vision` string (`on` / `true` / `enabled` → true). Threaded through
  `init` / `initWithProtocol` alongside the existing thinking/stream/agent strings.
- `agent_history.SessionRecord` gains `vision_enabled: bool = false` (std.json
  default value; missing field in older records parses to false, identical to the
  `max_tokens` pattern), so resume preserves the flag.

### 3. Ctrl+Shift+V into the chat panel (vision-aware)

`Ctrl+Shift+V` is already bound to `paste_image` (`keybind.zig:417`) and currently
calls `pasteImageFromClipboard()` (pastes a temp PNG path into the terminal). Branch
it the way `.paste` already branches on chat focus (`input.zig:1023`):

- If `AppWindow.activeAiChat()` or the focused copilot session is non-null →
  `pasteImageIntoAiChat(chat)`.
- Otherwise → existing terminal behavior, unchanged.

`pasteImageIntoAiChat(chat)` (new, in `src/input/clipboard.zig`):

1. Read clipboard image to a temp PNG via the existing
   `platform_clipboard.readImageAsPngTemp`.
2. Read the file bytes, base64-encode, then delete the temp file.
3. Size guard: if the PNG exceeds a cap (8 MB), skip with a debug log + toast.
4. If `chat.vision_enabled`: `chat.addPendingImage(base64, name)`, show a toast
   ("Image attached"), set the rebuild flags, and `std.debug.print` a log line.
5. Else: `std.debug.print("Vision disabled for this model — image ignored\n", ...)`
   plus a brief toast. (Temp file already deleted in step 2.)

### 4. Pending attachments + composer chip (text chip, multiple images)

- `Session` gains `pending_images: std.ArrayListUnmanaged(PendingImage)` where
  `PendingImage = struct { data_b64: []u8, media_type: []const u8 = "image/png", name: []u8 }`.
- Methods: `addPendingImage`, `clearPendingImages`, `pendingImageCount`, with deinit
  freeing all pending images.
- Renderer: draw one chip line above the input listing the count, e.g.
  `🖼 2 images attached`. (No thumbnail in this version.)
- Cleared when: the message is submitted (ownership moves into the `Message`), and on
  `/clear`.

### 5. Request carries images

- `ai_chat_protocol.RequestMessage` gains `images: ?[]ImageBlock = null`.
- `ai_chat.Message` gains `images: ?[]ImageBlock = null`.
  `ImageBlock = struct { data_b64: []u8, media_type: []const u8 }`.
- `submit()`: move `pending_images` into the new user `Message.images`; clear pending.
- `buildRequestMessages` (around `ai_chat.zig:2107`): pass `msg.images` through
  `requestMessageWithClonedFields` (clone the image blocks; extend that helper).
- `ai_chat_protocol` serialization: **only a user message that has images** switches
  to a multimodal content array; every other message keeps its current string
  `content` (zero behavior change for the no-image path):
  - chat_completions:
    `"content":[{"type":"text","text":"…"},{"type":"image_url","image_url":{"url":"data:image/png;base64,…"}}]`
  - anthropic:
    `"content":[{"type":"text","text":"…"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"…"}}]`
  - responses:
    `[{"type":"input_text","text":"…"},{"type":"input_image","image_url":"data:image/png;base64,…"}]`

## Scope boundaries (YAGNI)

Not in this version: inline thumbnail rendering; persisting image bytes to the
history JSON; non-PNG media types (the clipboard temp file is always PNG).

## Testing (TDD)

- `profile_codec`: vision field round-trips; legacy 11-field line defaults vision to
  off (fast suite).
- `ai_chat_protocol`: a user message with images serializes the expected JSON blocks
  for chat_completions and anthropic; a message without images is byte-identical to
  today.
- base64 / data-URI helper unit test.
- `Session`: `addPendingImage` then `submit` moves images into the user `Message` and
  clears `pending_images`.

## Files touched

- `src/renderer/overlays/profile_codec.zig` — vision field + legacy default
- `src/renderer/overlays.zig` — Vision form row
- `src/ai_chat_protocol.zig` — DEFAULT_VISION, ImageBlock, RequestMessage.images, serialization
- `src/ai_chat.zig` — Session.vision_enabled, pending_images, Message.images, submit, buildRequestMessages
- `src/ai_chat_request.zig` — clone images in requestMessageWithClonedFields
- `src/input/clipboard.zig` — pasteImageIntoAiChat
- `src/input.zig` — route paste_image on chat focus
- `src/agent_history.zig` — SessionRecord.vision_enabled
- chat composer renderer — attachment chip line
