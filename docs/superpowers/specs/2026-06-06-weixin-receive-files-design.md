# Weixin Receive Files Design

**Date:** 2026-06-06
**Status:** Approved design, pending implementation plan

## Goal

Add inbound attachment handling to the WispTerm desktop direct WeChat bridge
(`src/weixin/`). When the bound user sends a **file** or **image** from WeChat,
WispTerm downloads it from the Weixin CDN, AES-decrypts it, saves it under the
conversation working directory, replies a receipt naming the file(s), and hands
the saved path(s) to the copilot so the AI can act on them.

This is the receive-side counterpart to the existing
`weixin_send_attachment` outbound tool. Scope is the Zig desktop direct bridge
only; the `remote/` Node bridge stays out of scope, matching the prior
attachments design.

## Context

The outbound path already exists end to end:

- Agent tool `weixin_send_attachment` → `AttachmentSender` (`types.zig`) →
  `Client.sendAttachment` (`ilink_client.zig`): `getuploadurl` →
  AES-128-ECB/PKCS#7 encrypt (`media.zig`) → CDN upload → `sendmessage` with a
  `file_item` / `image_item`.

The inbound path does **not** exist anywhere — not in the Zig bridge and not in
the `remote/` TypeScript reference bridge. Today:

- `getupdates` returns `msgs[].item_list[]`, but `ilink_codec.parseGetUpdates`
  only maps `text_item` (type 1) and `voice_item` (type 3). `image_item`
  (type 2) and `file_item` (type 4) are dropped.
- `binding.extractText` returns text from type 1/3 only.
- `poller.processUpdates` **skips any message whose `extractText` is empty**
  (`reason=no_text_item`). A pure file/image message carries no text item, so
  today it is silently discarded.

### Protocol reference

The authoritative inbound protocol comes from the user's Go projects (read-only
reference): `cc-connect/platform/weixin/{cdn.go,media_inbound.go,types.go}` and
`paper_image_db/internal/weixin/cdn.go`. Confirmed facts:

- **Download URL:** `GET <cdn-base>/download?encrypted_query_param=<url-escaped>`
  where the default base is `https://novac2c.cdn.weixin.qq.com/c2c`. No auth
  header, no `filekey` (unlike upload).
- **Decrypt:** AES-128-ECB then PKCS#7 unpad. The key is `media.aes_key`:
  base64-decode it, then if 16 bytes use it raw, else if 32 ASCII-hex bytes
  hex-decode to 16 bytes. (WispTerm's outbound `encodeIlinkAesKey` produces the
  base64-of-hex variant, so inbound keys will be the hex-32 form.)
- **Inbound item shapes** (`type` → nested object, each with `media` carrying
  `encrypt_query_param` + `aes_key`):
  - `image_item` (2): `media`, plus legacy `aeskey` (hex) / `url`; **may have
    no key** → download the bytes as-is (plain). No filename.
  - `file_item` (4): `media`, `file_name`, `md5`, `len` (string).
- **Image MIME** is sniffed from magic bytes (jpeg `FF D8 FF`, png
  `89 50 4E 47 0D 0A 1A 0A`, gif `GIF87a`/`GIF89a`, riff/webp), defaulting to
  jpeg.
- Duplicate `encrypt_query_param` values within one message are deduplicated
  (retries / mixed items).

WispTerm already owns the crypto building blocks in `media.zig`:
`aes128EcbPkcs7Encrypt` and a working decrypt implementation currently named
`aes128EcbPkcs7DecryptForTest`.

## Ghostty Comparison

Ghostty has no WeChat bridge and no AI agent tool layer; the closest analog is
its host-layer automation (App Intents / AppleScript calling surface APIs).
Match that boundary here: CDN download, AES decryption, bot tokens, working-dir
resolution, and WeChat reply context stay in `src/weixin/`, `src/App.zig`, and
`src/AppWindow.zig`. VT parsing, PTY state, the renderer, and normal input do
not learn about WeChat attachments.

## User-Approved Decisions

- **Behavior:** save to disk **and** auto-inform the copilot (not save-only).
- **Media kinds in v1:** `file` and `image` only. Voice keeps the existing ASR
  `text` path; video and raw-voice `.silk` download are out of scope for v1.
- **Save location:** `<working-dir>/weixin_inbound/`, where `<working-dir>` is
  the effective agent working directory (per-conversation override → global
  `ai-agent-working-dir` config → OS Downloads fallback when both are unset).
- **Receipt:** send an explicit WeChat reply naming the file(s), merged with the
  start-of-processing ack into a single message (no duplicate generic ack).
- **Copilot hand-off:** a synthetic text prompt that lists the **absolute**
  saved path(s); the copilot reads them with its own file tools.
- **Download timing:** inline in the poll thread for v1 (accepting that the next
  long-poll waits for the download).

## Architecture

The inbound path mirrors the outbound one and stays inside `src/weixin/` plus a
single new `Control` seam method implemented in `AppWindow.zig`.

### `media.zig` (pure, + tests)

- `parseAesKey(allocator, aes_key_base64) -> AesKey` — base64-decode; 16 bytes →
  raw key; 32 bytes that are all ASCII hex → hex-decode to 16 bytes; otherwise
  `error.WeixinInvalidAesKey`.
- Promote the existing decrypt to a public `aes128EcbPkcs7Decrypt`
  (the current `aes128EcbPkcs7DecryptForTest` body is correct; rename/expose it
  and keep a test alias if needed). Errors: `error.InvalidCiphertext`,
  `error.InvalidPadding`.
- `cdnDownloadUrl(allocator, encrypt_query_param) -> []u8` →
  `<DEFAULT_CDN_*_BASE>/download?encrypted_query_param=<percent-escaped>`,
  reusing the existing query-escape helper. (The default base constant is shared
  with upload.)

### `types.zig` (pure, + tests)

Extend `MessageItem` (keeps the existing `type`, `text`, `voice_text`) with
inbound media:

```zig
pub const InboundMedia = struct {
    encrypt_query_param: []const u8 = "",
    aes_key: []const u8 = "",
};

pub const MessageItem = struct {
    type: i64 = 0,
    text: []const u8 = "",
    voice_text: []const u8 = "",
    media: ?InboundMedia = null, // set for image(2) / file(4)
    file_name: []const u8 = "",  // file_item only
};
```

`AttachmentKind` already covers `file` and `image`.

### `ilink_codec.zig` (pure, + tests)

- `WireItem` gains optional `image_item` and `file_item`, each with a nested
  `media { encrypt_query_param, aes_key, encrypt_type }`; `image_item` also has
  optional legacy `aeskey` (hex) and `url`; `file_item` has `file_name`.
- `parseGetUpdates` maps these into `MessageItem.media` / `MessageItem.file_name`
  (alongside the existing text/voice mapping). Image legacy `aeskey` hex is
  normalized into `InboundMedia.aes_key` only if `media.aes_key` is empty.

### NEW `media_inbound.zig` (pure, + tests)

Pure planning + naming + message text, no I/O:

- `DownloadPlan { kind: AttachmentKind, encrypt_query_param, aes_key, file_name,
  allow_plain: bool }`.
- `planDownloads(allocator, items) -> []DownloadPlan` — iterate `item_list`,
  select image(2)/file(4) with a non-empty `encrypt_query_param`, deduplicate by
  `encrypt_query_param`. `file` requires a non-empty `aes_key`; `image` sets
  `allow_plain = true` when `aes_key` is empty.
- `detectImageMimeExt(bytes) -> []const u8` — magic-byte sniff → `"jpg"` /
  `"png"` / `"gif"` / `"webp"` (default `"jpg"`).
- `chooseFileName(plan, bytes, index) -> []const u8` (caller-owned buffer or
  allocator): file → `sanitizeFileName(file_name)` or `attachment.bin`; image →
  `image_<index>.<ext>` using `detectImageMimeExt`.
- `sanitizeFileName(name) -> []const u8` — strip any path separators / `..`
  components, collapse to a base name; empty → fallback.
- `dedupeFileName(dir-knowledge via callback or a seen-set)` — the poller passes
  a "does this name already exist" check; on collision append ` (n)` before the
  extension. (Pure helper takes the existence predicate.)
- `buildReceiptText(allocator, saved_names) -> []u8` →
  `已收到文件：a.pdf、b.png，正在交给副驾处理。\n发送 /stop 可停止本次处理。`
  Used as the combined receipt+ack when media is present.
- `buildCopilotPrompt(allocator, saved_abs_paths, caption) -> []u8` →
  `用户通过微信发送了文件：\n- <abs>\n- <abs>\n<caption>` (caption line omitted
  when empty). Always terminates without a trailing carriage return; the poller
  adds the `\r` exactly as the text path does.

### `ilink_client.zig` (network, behind `ClientApi`)

- `downloadAttachment(allocator, encrypt_query_param, aes_key, allow_plain)
  -> []u8` — build the CDN download URL, `GET` it (fresh `std.http.Client`, no
  auth header, like the existing CDN upload), enforce a `MAX_INBOUND_BYTES`
  (100 MiB) cap, then: if `aes_key` non-empty, `parseAesKey` + decrypt; else
  (image plain) return the raw bytes. Network errors → `error.Weixin*` (logged
  via the existing redaction helpers).
- Add `download_attachment` to `ClientApi.VTable` and the `Client.api()` adapter,
  so the poller can be tested with a fake. The HTTP `GET` goes through the same
  injectable transport seam used by upload (`fetch_impl` / a sibling download
  impl) so the build-URL/cap/decrypt logic stays testable with a fake transport;
  the live network `GET` is not unit-tested on the dev host (no live endpoint),
  same as the existing upload.

### `control.zig` + `AppWindow.zig` (seam)

- New `Control.inboundFileDir(ctx, buf: []u8) -> []const u8` — returns the
  effective working directory into the caller's buffer (per-conversation working
  dir if set, else the global `ai-agent-working-dir`, else the OS Downloads
  dir). Empty result means "no usable directory"; the poller then falls back to
  the process cwd. Implemented in `AppWindow.zig` alongside the existing
  `wxTranscript` / `wxSendInput`, backed by the same process-global app state.
- Tests supply a fake returning a `tmpDir` path.

### `poller.zig` (orchestration)

Add an inbound-media branch that runs **before** the `no_text_item` skip, for
accepted (owner-bound) non-bootstrap messages:

1. `plans = media_inbound.planDownloads(items)`. If empty, fall through to the
   existing text routing unchanged.
2. Resolve the save directory: `control.inboundFileDir` + `weixin_inbound/`,
   `mkdir -p`. (Directory creation failure → WeChat error reply, skip media.)
3. For each plan: `client.downloadAttachment(...)`; on success choose a
   sanitized, collision-deduped file name and write the bytes; collect the
   absolute path and display name. On per-item failure: log, accumulate the name
   into a failure list, continue.
4. If any file saved:
   - Send **one** combined receipt/ack to WeChat via the text send path
     (`buildReceiptText(saved_names)`), appending a `文件接收失败：…` line when
     some items failed.
   - Build `buildCopilotPrompt(saved_abs_paths, caption)` where `caption` is the
     message's text item (if any), route it to the copilot through the existing
     `routeAdapter` → `agent.sendAi` flow with the message's `reply_context`,
     and start AI-reply progress streaming (`expect_ai_progress`). The generic
     `AI_ACK` is suppressed for this path so the receipt is the only ack.
5. If all items failed (none saved): send only the `文件接收失败：…` reply; do
   not route to the copilot.

A message with a caption **and** a file: the receipt names the file and the
caption becomes the copilot instruction inside the prompt. A pure-text message:
the existing path is unchanged (no `planDownloads` matches).

Downloads run inline on the poll thread (v1). A `MAX_INBOUND_BYTES` cap bounds
memory; the next `getUpdates` resumes after the saves complete.

## Data Flow

```
getUpdates
  → parseGetUpdates (text/voice + image/file media)
  → shouldHandle (owner gate; group/stranger/bootstrap skipped)
  → planDownloads
      ├─ empty → existing text routing
      └─ non-empty:
           downloadAttachment → decrypt → save <wd>/weixin_inbound/<name>
           → receipt/ack to WeChat
           → synthetic prompt (abs paths + caption) to copilot
           → AI-reply progress streaming (existing)
```

## Error Handling

- Per-item download/decrypt/write failure → log (redacted), add to the failure
  list, continue with remaining items. The poll loop never breaks on media.
- Directory unavailable / mkdir failure → WeChat error reply, media skipped.
- Item exceeds `MAX_INBOUND_BYTES` → skip that item, count as a failure.
- Working dir unset → OS Downloads, then process cwd, as fallbacks.
- Bootstrap / historical media skipped exactly like historical text
  (the branch lives after the existing `bootstrap_skip` early return).
- Group and non-owner messages are skipped by the unchanged `shouldHandle` gate.

## Testing

**Pure / unit:**

- `media.zig`: `parseAesKey` for raw-16, hex-32-wrapped, and invalid inputs;
  `cdnDownloadUrl` escaping; a decrypt round-trip against the existing
  `aes128EcbPkcs7Encrypt`.
- `ilink_codec.zig`: `parseGetUpdates` maps a `file_item` (media + file_name)
  and an `image_item` (media, and the legacy-`aeskey`/no-key variants).
- `media_inbound.zig`: `planDownloads` selection + dedup + image-plain flag;
  `detectImageMimeExt`; `sanitizeFileName` (path traversal stripped); name
  collision deduping; `buildReceiptText`; `buildCopilotPrompt` (with and without
  caption).

**Poller integration:**

- Fake `ClientApi.download_attachment` returns canned bytes; fake `Control`
  returns a `tmpDir` save dir and captures sent text + routed prompt. Assert:
  the file is written under `weixin_inbound/`, the combined receipt is sent, the
  synthetic prompt (absolute path, plus caption when present) is routed, and
  progress streaming starts.
- Offline / no copilot: the file is still saved and the receipt naming the path
  is still sent; no crash.
- All-items-fail: only the failure reply is sent; nothing routed.

The live CDN `GET` is not unit-tested on the dev host (no live endpoint),
isolated behind `ClientApi`, consistent with the existing upload path. New
modules are registered for the suites via `test_main.zig` (full app graph).

## Non-Goals (v1)

- Video and raw-voice `.silk` inbound download.
- Injecting inbound images as Vision multimodal blocks (text path hand-off
  only).
- A dedicated download worker thread / parallel downloads.
- The `remote/` Node bridge inbound path.
- Any new local-path access restriction beyond writing into `weixin_inbound/`.
