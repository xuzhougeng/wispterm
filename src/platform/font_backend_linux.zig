//! Linux font backend: re-exports the unsupported stubs.
//! Real fontconfig discovery is a later sub-project.
const u = @import("font_backend_unsupported.zig");

pub const FontWeight = u.FontWeight;
pub const FallbackFont = u.FallbackFont;
pub const FontDiscovery = u.FontDiscovery;
pub const FontFilePath = u.FontFilePath;
pub const LoadedFont = u.LoadedFont;
pub const TitlebarIconFont = u.TitlebarIconFont;

pub const titlebarIconFont = u.titlebarIconFont;
pub const titlebarIconGlyph = u.titlebarIconGlyph;
pub const fontWeightFromValue = u.fontWeightFromValue;
pub const fontFilePathAlloc = u.fontFilePathAlloc;
pub const fontDataAlloc = u.fontDataAlloc;
