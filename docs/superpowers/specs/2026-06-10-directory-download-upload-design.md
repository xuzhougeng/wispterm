# Directory download/upload + cancelable downloads — Design

Date: 2026-06-10
Status: Approved (design)

## Goal

Extend the existing remote SSH file-transfer feature so it can also transfer
**directories** (recursive download and upload), and ensure **download tasks
remain cancelable** — including the new folder downloads.

This builds directly on the shipped single-file transfer system
(`2026-05-19-ssh-file-transfer-design.md`). It reuses the existing transfer-job
queue, worker thread, progress toast, and cancel-confirm overlay; directories
flow through the same machinery.

## Background — what exists today

- `src/scp.zig`
  - `transferWithControl(allocator, conn, src, dst, control)` runs
    `scp -q` → `scp -q -O` (legacy protocol) → `ssh cat` stream fallback.
  - `scp` already supports `-r` for recursion; it is simply never passed today.
  - The `ssh cat` stream fallback only handles single files.
  - `TransferControl` cancels by killing the registered child process.
- `src/file_explorer.zig`
  - Single active `TransferJob` + a queue; `transfer_fn: TransferFn` is stored
    per request, so the job system is agnostic to which transfer function runs.
  - `downloadSelected(local_dir)` downloads the selected remote file and
    **explicitly skips directories** (`if (entry.is_dir) return; // Only download files`).
  - `uploadFile(local_path)` uploads one local file to the current remote dir.
  - `cancelActiveTransfer()` cancels the active job **only when it is a download**;
    it returns `false` for uploads. It already kills the scp child via
    `TransferControl.cancel()`.
  - Progress for downloads is derived from the destination *file* size
    (`observedTransferBytes` → `localFileSize`).
- `src/input.zig`
  - `Ctrl/Cmd+S` → `downloadSelected(Downloads)`.
  - `U` → `openFileDialogAndUpload()` (single-**file** picker only).
  - Cancel UX: click the transfer toast → `transferCancelConfirmOpen()` →
    confirm → `cancelActiveTransfer()`.
- `src/platform/file_dialog*.zig`
  - `openFile` / `saveFile` per backend (Windows `GetOpenFileNameW`, macOS
    `NSOpenPanel` via ObjC bridge, Linux `zenity`). **No folder picker exists.**
- `TransferKind = enum { upload, download }` and the toast verbs already map
  both kinds across in_progress/success/failed/cancelled states.

## Decisions (confirmed with user)

1. **Folder transfer backend: `scp -r` only.** Add `-r` to the existing scp and
   scp `-O` attempts; skip the `cat`-stream fallback for directories (it cannot
   transfer dirs). No tar-over-ssh fallback.
2. **Folder upload trigger: `Shift+U`.** Keep `U` = upload file. `Shift+U` opens
   a folder picker and uploads the chosen directory recursively. Mirrors the
   existing `N` / `Shift+N` (new file / new dir) convention.
3. **Cancel cleanup: delete the partial.** When a download is cancelled, remove
   the partially-transferred destination (half file, or incomplete folder tree
   under `Downloads/<name>`). The dst is always a fresh path, so deletion is safe.

## Design

### 1. SCP backend — `src/scp.zig`

Refactor the body of `transferWithControl` into a shared internal
`transferImpl(allocator, conn, src, dst, control, recursive: bool)`:

- `runScpTransfer(..., recursive: bool)` inserts `-r` into argv immediately
  after `-q` when `recursive` is true.
- `recursive == false` → **unchanged** behavior: scp → scp `-O` → `ssh cat`
  stream fallback.
- `recursive == true` → scp → scp `-O`; if both fail, return the failure. **No**
  `cat` fallback (cat cannot transfer directories).

Public API:

- `transferWithControl(...)` stays as the file path (`recursive = false`), with
  its exact current signature and behavior — every existing caller (clipboard
  paste, agent file copy, single-file up/download) is untouched.
- New `transferDirWithControl(...)` = `transferImpl(..., recursive = true)`.

Both match the existing `TransferFn` signature, so they drop straight into the
file_explorer job system without any queue/struct changes.

To keep the `-r` placement unit-testable, extract a small pure helper that
builds the scp argv (or, minimally, a helper that reports whether `-r` is
included for a given `recursive` flag) so the fast suite can assert it.

### 2. Transfer jobs — `src/file_explorer.zig`

- **`downloadSelected`**: remove the `if (entry.is_dir) return;` guard. Select
  the transfer function by entry type:
  - `entry.is_dir` → `scp.transferDirWithControl`
  - file → `scp.transferWithControl`

  `dst = Downloads/<name>` for both. For a fresh download, `Downloads/<name>`
  does not exist, so `scp -r remote:dir Downloads/dir` creates the folder with
  the remote dir's contents.

- **New `uploadFolder(local_path)`**: mirrors `uploadFile` but passes
  `scp.transferDirWithControl`. dst = `scp.remoteSpec(current remote dir)`.
  `scp -r localdir user@host:/remotedir` nests the folder into the remote dir,
  matching file-upload behavior.

- **Cancel cleanup (downloads only)**: in `tickTransferJob`, the safe cleanup
  point is the post-join `.cancelled` branch of the `switch (job.result)` (the
  worker thread has been joined there, so no race with scp still writing). When
  the cancelled job is a download, delete the partial destination:
  - `removePartialDownload(dst)` calls `std.fs.deleteTreeAbsolute(dst)` (or the
    cwd-relative variant) — `deleteTree` removes a file or a directory tree, so
    it covers both. Best-effort: ignore errors.
  - The early `cancelRequested()` branch in `tickTransferJob` continues to set
    the `.cancelled` toast immediately for UX feedback but does **not** delete
    (worker may still be running); cleanup waits for the real completion.
  - Uploads remain non-cancelable (out of scope; dst is remote-side).

- **Folder download progress**: extend `observedTransferBytes` so that when the
  download dst is a directory, it returns the recursive byte size of that tree
  (best-effort walk; on error return null → toast shows "calculating…"). This
  keeps the speed readout meaningful for folder downloads. File downloads keep
  using `localFileSize` unchanged.

### 3. Folder picker — `src/platform/file_dialog*.zig`

Add `pickFolder(allocator, request: OpenRequest) ?[]u8` to the dispatcher and
all four backends (reuse the existing `OpenRequest`/`Owner` types):

- **Windows** (`file_dialog_windows.zig`): `SHBrowseForFolderW` (shell32) +
  `SHGetPathFromIDListW` → UTF-8 path. `GetOpenFileNameW` cannot pick folders;
  `SHBrowseForFolder` is a single shell call and fits the existing extern style.
- **macOS** (`file_dialog_macos.zig` + `services_macos_bridge.m`): new extern
  `wispterm_macos_pick_folder_dialog(title)` driving `NSOpenPanel` with
  `canChooseDirectories = YES`, `canChooseFiles = NO`.
- **Linux** (`file_dialog_linux.zig`): `zenity --file-selection --directory`.
- **unsupported** (`file_dialog_unsupported.zig`): returns null.

### 4. Input wiring — `src/input.zig`

- In the `0x55` ('U') handler:
  - bare `U` (no modifiers) → `openFileDialogAndUpload()` (unchanged).
  - `Shift+U` (remote mode) → new `openFolderDialogAndUpload()`:
    `pickFolder` → `file_explorer.uploadFolder(path)`.
- `Ctrl/Cmd+S` trigger unchanged; it now downloads a selected folder because
  `downloadSelected` handles directories.

### 5. Toast wording — `src/i18n.zig`

No new states. The existing download/upload toast verbs
(`tt_downloading`/`tt_uploaded`/`tt_*_interrupted`/…) cover folder transfers
generically; the folder's name flows through as the toast display string.

## Error handling

- `scp -r` failure → `.failed` → "Download/Upload failed: \<name\>" toast.
- Cancel → kills the scp child → `.cancelled` toast + partial destination
  deleted (downloads).
- Folder picker cancelled / unavailable → no-op (matches `openFile` behavior).
- Re-downloading an existing folder nests per `scp -r` semantics (same class of
  behavior as files being overwritten) — documented, not specially handled.

## Testing (TDD; fast suite where possible)

- **scp** (`src/scp.zig`): unit-test that the recursive argv includes `-r` and
  the non-recursive argv does not, via the extracted pure arg helper.
- **file_explorer** (`src/file_explorer.zig`):
  - a directory entry no longer early-returns from `downloadSelected` and starts
    a `.download` job using the dir transfer function;
  - `uploadFolder` starts an `.upload` job using the dir transfer function;
  - **cancel deletes the partial dst**: extend the existing
    `transferWaitForCancelForTest` flow — set a real temp file as dst, cancel,
    and assert the file is removed after the job completes.
- **file_dialog** (`src/platform/file_dialog.zig`): `pickFolder` signature test
  and backend-selection test, matching the existing dialog tests.

## Out of scope / YAGNI

- tar-over-ssh fallback for directories.
- Cancel support for uploads (remote-side cleanup).
- A unified file/folder picker prompt for `U`.
- Right-click context menu entries (transfers stay keybinding-driven).
- Special handling of folder-name collisions on re-download.
