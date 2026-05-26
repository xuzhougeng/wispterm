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

// Intentionally empty until the Metal backend (D1) is implemented.
