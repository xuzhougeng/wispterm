//! Type re-export for the preview source kind.
//!
//! The old right-side preview *dock* (a singleton with its own width, visibility
//! and tab ownership) has been removed: previews are now split-tree leaves
//! (`PreviewPane`) created via Ctrl+click / "Split Preview" / SKILL.md and
//! rendered with `markdown_preview_renderer.renderInto`. The only thing callers
//! still reach for through this module is the `PreviewSourceKind` type, so that
//! is all that remains here.

const PreviewPane = @import("preview_pane.zig");

pub const PreviewSourceKind = PreviewPane.PreviewSourceKind;
