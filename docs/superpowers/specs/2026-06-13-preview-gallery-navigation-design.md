# Preview Gallery Navigation Design

## Goal

Image and PDF preview panes should behave like a lightweight gallery. When a raster preview pane is focused, the user can press the left or right arrow key to switch to the previous or next supported media file in the same directory as the current preview path.

Supported gallery members are the existing preview raster kinds:

- Images supported by `markdown_preview.detectKind`
- PDFs supported by `markdown_preview.detectKind`

This applies to previews opened from the File Explorer and from terminal path clicks, across local, WSL, and SSH sources when the source can be listed.

## Ghostty Comparison

Ghostty has image rendering paths for terminal image protocols and related renderer support, but it does not have WispTerm's split-tree file preview pane or file-gallery browsing feature. The relevant Ghostty-aligned constraint is input isolation: arrow keys must keep reaching the PTY unless a non-terminal preview leaf has focus and explicitly consumes them.

## Interaction

When a focused preview pane is showing an image or PDF:

- `Left` opens the previous supported image/PDF in the same directory.
- `Right` opens the next supported image/PDF in the same directory.
- `Up` and `Down` keep the existing pan behavior for raster previews.
- `PageUp` and `PageDown` keep the existing PDF page flip behavior.
- Modified arrow keys (`Ctrl`, `Alt`, `Super`) remain available to app keybinds or terminal input.

At the first or last media file, the corresponding direction is a no-op. The pane remains focused and no terminal input is sent.

## Architecture

Add a small pure gallery helper at `src/preview_gallery.zig`, responsible for path and ordering logic:

- Determine the parent directory and basename of the current path.
- List sibling entries through the existing `file_backend` abstraction.
- Filter out directories and unsupported preview kinds.
- Treat images and PDFs as one gallery sequence.
- Sort using the existing `file_backend` order.
- Return the target title/path/kind for previous or next.

`PreviewPane` should store the `PreviewSourceKind` used for the current load, so navigation does not depend on the File Explorer's global state after the pane is open. `beginAsyncLoad` should update this stored source kind. Terminal-click previews already resolve the path before opening, so the gallery should operate on the resolved path.

The input layer should call a narrow navigation helper only from the existing focused preview branch in `src/input.zig`. Successful navigation reuses the current preview pane and starts `beginAsyncLoad` for the target file. It must mark the UI dirty with `AppWindow.g_force_rebuild = true` and `AppWindow.g_cells_valid = false`.

## Data Flow

1. User opens an image or PDF preview.
2. The pane stores `kind`, `path`, `title`, and `source_kind`.
3. User focuses that pane and presses `Left` or `Right`.
4. Input asks the gallery helper for a sibling target.
5. If a target exists, the same pane begins an async load for that target.
6. The existing preview async tick path applies the loaded content and triggers repaint.

## Error Handling

If directory listing fails, no target is found, or the target path cannot fit the existing preview path buffers, navigation is a no-op and the current preview remains visible.

If target loading starts but fails, the existing preview failure state is shown in the same pane. This matches current preview-open behavior.

## Testing

Add unit tests for the pure gallery helper:

- Finds previous and next media files in sorted sibling entries.
- Filters unsupported files and directories.
- Handles first/last file boundaries.
- Handles mixed image/PDF sequences.
- Handles Unix-style `/` paths and Windows-style `\` paths in pure path-splitting tests.

Add a focused `PreviewPane` test proving `beginAsyncLoad` preserves the current `source_kind`. Because `input.zig` only compiles in the full app test binary, route-level input coverage belongs in `zig build test-full`; pure helper coverage should run in `zig build test`.

## Documentation

Update:

- `README.md` keyboard shortcut table
- `docs/file-explorer.md` preview controls

The docs should mention that gallery navigation applies when an image or PDF preview pane is focused.
