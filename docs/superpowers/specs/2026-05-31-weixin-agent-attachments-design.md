# Weixin Agent Attachments Design

**Date:** 2026-05-31
**Status:** Approved design, pending implementation plan

## Goal

Add typed attachment sending to the desktop direct Weixin path in `src/weixin/`.
The AI Agent should be able to send local files back to the active Weixin
conversation by calling a tool, rather than relying on a manual `/file` command.
Outbound audio/voice paths are sent as ordinary file attachments in v1, not as
Weixin `voice_item` messages.

This design applies only to the Zig desktop direct bridge. The `remote/` Node
bridge remains out of scope for this change.

## Context

WispTerm currently has two Weixin paths:

- `remote/src/server/bridge/weixin/`: Node Remote bridge.
- `src/weixin/`: embedded desktop direct iLink client and poller.

Both paths currently send text replies. Both already extract text from inbound
voice messages by reading the iLink `voice_item.text` transcription:

- TypeScript Remote bridge: `extractWeixinText()` in
  `remote/src/server/bridge/weixin/poller.ts`.
- Zig direct bridge: `binding.extractText()` in `src/weixin/binding.zig`.

The missing capability is outbound media. CiteBox provides a working reference:

- `internal/weixin/types.go`: iLink media item types and upload request shapes.
- `internal/weixin/media.go`: upload URL, AES-ECB encryption, CDN upload,
  and typed `sendmessage` payloads.
- `internal/weixin/cdn.go`: CDN download/decrypt helpers.
- `internal/service/weixin_im_bridge.go`: higher-level bridge behavior around
  text, image, file, and voice sends.

## Ghostty Comparison

Ghostty has no Weixin bridge or AI Agent tool system. The closest relevant
reference is its host-level automation on macOS:

- App Intents expose terminal input and terminal details through host-layer
  APIs such as `InputTextIntent` and `GetTerminalDetailsIntent`.
- AppleScript commands also live in the app/host layer and ultimately call
  surface APIs such as `surface.sendText`.

The same boundary should hold here: iLink upload, CDN encryption, bot tokens,
and Weixin reply context stay in `src/weixin/` and the app/Agent host layer.
Terminal emulation, VT parsing, PTY state, and rendering do not know about
Weixin attachments.

## User-Approved Decisions

- Scope is `src/weixin/` desktop direct only.
- Expose attachment sending as an Agent tool.
- Tool name: `weixin_send_attachment`.
- Support typed attachment inputs in v1: `file`, `image`, and `voice`.
- Treat outbound `kind=voice` as a file attachment alias. Do not probe audio
  metadata or send iLink `voice_item` messages in v1.
- Do not add extra local path restrictions. The tool may send any readable
  local file path.
- Do not add a separate manual `/file` command in v1.
- Inbound voice transcription is not a tool; it remains ordinary message text
  extraction from `voice_item.text`.

## Tool Contract

`weixin_send_attachment` accepts:

```json
{
  "kind": "file | image | voice",
  "path": "C:\\path\\to\\artifact",
  "display_name": "optional-name.ext"
}
```

Semantics:

- `kind=file` sends a generic iLink `file_item`.
- `kind=image` sends an iLink `image_item`.
- `kind=voice` sends the bytes as a generic iLink `file_item`, same as
  `kind=file`.
- `display_name` is optional. If omitted, the basename of `path` is used where
  the iLink item supports a filename.
- The tool is usable only while handling a Weixin-triggered Agent request. A
  normal local AI Chat request has no Weixin reply context and returns a clear
  tool error.

## Protocol Flow

For all attachment kinds:

1. Read the local file.
2. Compute raw size and MD5.
3. Generate a random file key and random AES-128 key.
4. Request `/ilink/bot/getuploadurl`.
5. AES-ECB encrypt the file with PKCS7 padding.
6. Upload encrypted bytes to the Weixin CDN upload URL.
7. Read the CDN response `x-encrypted-param`.
8. Send `/ilink/bot/sendmessage` with the matching typed item.

Mapping:

| Tool kind | iLink media_type | sendmessage item |
| --- | ---: | --- |
| `image` | `1` | `image_item` |
| `file` | `3` | `file_item` |
| `voice` | `3` | `file_item` |

The media metadata follows the CiteBox wire shape:

- `media.encrypt_query_param`: CDN download token from `x-encrypted-param`.
- `media.aes_key`: base64 encoding of the hex-encoded AES key.
- `media.encrypt_type`: bundle encryption type `1`.
- `file_item.file_name`: display name or path basename.
- `file_item.len`: raw file size as a decimal string.
- `image_item.mid_size`: encrypted file size.
No outbound voice metadata is required in v1 because audio/voice paths are sent
as files.

## Architecture

### `src/weixin/media.zig`

New media helper module.

Responsibilities:

- Build CDN upload URLs.
- AES-ECB encrypt with PKCS7 padding.
- Encode AES keys in the iLink-compatible form.
- Keep upload crypto and URL helpers pure; JSON request/response shapes stay in
  `ilink_codec.zig`.

### `src/weixin/types.zig`

Extend the in-memory iLink model with:

- `AttachmentKind = enum { file, image, voice }`
- upload URL request/response structs
- CDN media struct
- typed uploaded media structs for file/image; voice input is sent with the file
  attachment path.

### `src/weixin/ilink_codec.zig`

Extend JSON builders/parsers:

- `buildGetUploadUrlBody(...)`
- `buildSendUploadedFileBody(...)`
- `buildSendUploadedImageBody(...)`
- keep existing `voice_item.text` parsing for inbound messages and add direct
  tests for it.
- do not add outbound `voice_item` builders in v1; `kind=voice` is sent with
  the file payload path.

### `src/weixin/ilink_client.zig`

Extend `ClientApi` so Agent code can use a fake in tests:

```zig
send_attachment(
    ctx: *anyopaque,
    kind: types.AttachmentKind,
    path: []const u8,
    display_name: []const u8,
    to_user_id: []const u8,
    context_token: []const u8,
) anyerror!void
```

The real `Client` implements:

- `getUploadUrl`
- `uploadBufferToCDN`
- `sendUploadedFileAttachment`
- `sendUploadedImage`
- `sendAttachment`

`sendAttachment` is the high-level entry point used by the Agent tool.
It maps `AttachmentKind.voice` to the same generic file attachment flow as
`AttachmentKind.file`.

### `src/ai_chat.zig`

Add optional Weixin reply context to `ChatRequest`.

The context carries only what the tool needs:

- `to_user_id`
- `context_token`
- a `send_attachment` callback or `weixin.ClientApi`

Add tool dispatch:

- Parse `kind`, `path`, and optional `display_name`.
- Return `Invalid tool arguments`, `Missing kind`, or `Missing path` for invalid
  calls.
- Return a clear no-context message for normal AI Chat requests.
- Call the Weixin attachment sender for Weixin-triggered requests.
- Return a concise success message to the transcript, for example
  `Sent image to Weixin: chart.png`.

### `src/ai_chat_protocol.zig`

Add `weixin_send_attachment` to the single tool schema list.

Properties:

- `kind`: string, described as `file`, `image`, or `voice`.
- `path`: string, local file path.
- `display_name`: string, optional filename shown in Weixin for file-like
  attachments.

### `src/platform/agent_prompt.zig`

Add guidance to the Agent prompt:

- If the request came from Weixin and the user asks for a generated or local
  artifact, call `weixin_send_attachment`.
- Use `kind=image` for image previews and `kind=file` for ordinary attachments,
  including audio/voice files. `kind=voice` is accepted as an alias that still
  sends a file attachment.

### `src/weixin/poller.zig`

When routing a Weixin message into AI:

- Carry the current message sender as `to_user_id`.
- Carry the current message `context_token`.
- Carry an attachment-sending capability tied to the same iLink client used for
  text replies.

This is the only place where a normal Agent request becomes a
Weixin-triggered request.

## Error Handling

- Missing file, non-regular file, or read failure: return a clear tool error.
- `getuploadurl` failure: return `ret`, `errcode`, and message when available.
- CDN upload failure: return HTTP status and a short response body excerpt.
- Missing `x-encrypted-param`: return a specific CDN protocol error.
- `sendmessage` failure: return `ret`, `errcode`, and message when available.
- No Weixin reply context: return `No active Weixin reply context; cannot send attachment.`
- Oversized files are not pre-blocked in v1. If iLink rejects the file, surface
  that API error.

Never log bot tokens, `context_token`, AES keys, or raw file contents.

## Testing

Use TDD for implementation. Add tests before production code.

Pure tests:

- `media.zig`
  - AES-ECB/PKCS7 encrypted size and round-trip decrypt helper in test code.
  - CDN upload URL construction.
  - AES key iLink encoding.
- `ilink_codec.zig`
  - build `getuploadurl` JSON.
  - build `file_item` and `image_item` sendmessage JSON.
  - parse inbound `voice_item.text` into `MessageItem.voice_text`.
- `binding.zig`
  - keep/extend voice transcript extraction test.
- `ai_chat_protocol.zig`
  - tool schema includes `weixin_send_attachment`.
- `ai_chat.zig`
  - no Weixin context returns the no-context tool result.
  - valid context calls the fake attachment sender with kind, path,
    display_name, to_user_id, and context_token.
- `poller.zig`
  - Weixin-triggered AI routing carries the reply context into the request.
  - voice transcript messages route the same way as text messages.

Integration-style compile/build checks:

- `zig test src/weixin/media.zig`
- `zig test src/weixin/ilink_codec.zig`
- `zig test src/weixin/binding.zig`
- `zig test src/ai_chat_protocol.zig`
- `zig build test`

Before merging a completed implementation, run `zig build test-full` on Windows
per the repository development rules.

## Implementation Order

1. Add media types, pure codec/media tests, and pure implementation.
2. Extend `ClientApi` and real iLink client upload/send implementation.
3. Add Agent tool schema and prompt guidance.
4. Add `ChatRequest` Weixin reply context and tool dispatch.
5. Wire `poller.zig` so Weixin-triggered Agent requests carry reply context.
6. Verify with focused Zig tests and `zig build test`.

## Non-Goals

- No `remote/` bridge changes.
- No manual `/file` command.
- No inbound file download/import.
- No file path allowlist or extra permission prompt.
- No UI for selecting files.
- No changes to keyboard shortcuts or desktop version surfaces.
