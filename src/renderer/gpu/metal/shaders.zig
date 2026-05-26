//! Reserved slot for the Metal (MSL) shader set — the symmetric counterpart to
//! `gpu/opengl/shaders.zig`. Phase A / A5: the directory + slot exist so the
//! Metal backend (Phase D / D1, `gpu/metal/`) has a defined home for its shader
//! sources without restructuring. NOT YET IMPLEMENTED — no Metal backend is
//! built today (`backend.zig`'s `default()` only resolves to `.metal` on Darwin,
//! and `gpu.zig` wires `impl = opengl` for all currently-built targets).
//!
//! When the Metal backend lands, this file provides the MSL translations of the
//! GLSL sources in `gpu/opengl/shaders.zig`, keeping the same logical set so the
//! pipeline-builder code (`ui_pipeline`, `cell_pipeline`) can stay backend-neutral:
//!
//!   - `vertex_shader_source`        — textured quad (pos.xy, uv.zw) + mat4 projection
//!   - `fragment_shader_source`      — grayscale glyph (atlas .r as alpha × textColor)
//!   - `bg_vertex_source` / `bg_fragment_source`     — instanced cell backgrounds
//!   - `fg_vertex_source` / `fg_fragment_source`     — instanced cell foreground glyphs
//!   - `color_fg_fragment_source`    — color (emoji) cell glyphs
//!   - `simple_color_fragment_source`— textured RGBA quad with opacity
//!   - `overlay_fragment_source`     — flat-color tint (overlayColor)
//!
//! Shader *language* selection is a backend concern; the GraphicsAPI interface
//! in `gpu.zig` resolves `shaders` from the active backend's directory, so a
//! future `gpu.zig` Metal branch points `shaders` here. See `gpu/opengl/shaders.zig`
//! for the authoritative source/uniform contracts each entry must reproduce.

// D-prep STUB: the source strings below are PLACEHOLDER MSL so the
// backend-neutral pipeline builders (`ui_pipeline`, `cell_pipeline`) — which
// pass these to `Pipeline.init(...)` — type-check against the same public
// symbol set as `gpu/opengl/shaders.zig`. They are NOT real MSL translations;
// a Mac dev replaces each body with the MSL equivalent of the GLSL contract
// documented above (and `Pipeline.init` actually compiles them in D1). Until
// then `Pipeline.init` panics before the source is ever consumed, so the
// placeholder text is never compiled by Metal.

const TODO_MSL: [*c]const u8 =
    \\// metal: TODO D1 — translate the matching GLSL source from
    \\// gpu/opengl/shaders.zig into MSL (see the per-entry contract in the
    \\// module doc comment above). Placeholder until the Metal backend lands.
;

/// Textured quad (pos.xy, uv.zw) + mat4 projection.
pub const vertex_shader_source: [*c]const u8 = TODO_MSL;
/// Grayscale glyph (atlas .r as alpha × textColor).
pub const fragment_shader_source: [*c]const u8 = TODO_MSL;
/// Instanced cell backgrounds.
pub const bg_vertex_source: [*c]const u8 = TODO_MSL;
pub const bg_fragment_source: [*c]const u8 = TODO_MSL;
/// Instanced cell foreground glyphs.
pub const fg_vertex_source: [*c]const u8 = TODO_MSL;
pub const fg_fragment_source: [*c]const u8 = TODO_MSL;
/// Color (emoji) cell glyphs.
pub const color_fg_fragment_source: [*c]const u8 = TODO_MSL;
/// Textured RGBA quad with opacity.
pub const simple_color_fragment_source: [*c]const u8 = TODO_MSL;
/// Flat-color tint (overlayColor).
pub const overlay_fragment_source: [*c]const u8 = TODO_MSL;
