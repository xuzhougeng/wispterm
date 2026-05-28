//! MSL shader sources for the Metal backend. These mirror the logical shader
//! set in `gpu/opengl/shaders.zig` while using fixed `vertex_main` and
//! `fragment_main` entrypoints for the Metal pipeline bridge.

/// Textured quad (pos.xy, uv.zw) + mat4 projection.
pub const vertex_shader_source: [*c]const u8 =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct Uniforms {
    \\    float4x4 projection;
    \\    float4 textColor;
    \\    float4 overlayColor;
    \\    float4 cellSizeGridOffset;
    \\    float4 scalars;
    \\};
    \\
    \\struct QuadVertex {
    \\    packed_float4 value;
    \\};
    \\
    \\struct QuadOut {
    \\    float4 position [[position]];
    \\    float2 texCoord;
    \\};
    \\
    \\vertex QuadOut vertex_main(const device QuadVertex *vertices [[buffer(0)]],
    \\                           constant Uniforms& uniforms [[buffer(1)]],
    \\                           uint vertex_id [[vertex_id]]) {
    \\    float4 v = float4(vertices[vertex_id].value);
    \\    QuadOut out;
    \\    out.position = uniforms.projection * float4(v.xy, 0.0, 1.0);
    \\    out.texCoord = v.zw;
    \\    return out;
    \\}
;

/// Grayscale glyph (atlas .r as alpha x textColor).
pub const fragment_shader_source: [*c]const u8 =
    \\fragment float4 fragment_main(QuadOut in [[stage_in]],
    \\                              texture2d<float> text [[texture(0)]],
    \\                              sampler s [[sampler(0)]],
    \\                              constant Uniforms& uniforms [[buffer(1)]]) {
    \\    float alpha = text.sample(s, in.texCoord).r;
    \\    return float4(uniforms.textColor.rgb, 1.0) * float4(1.0, 1.0, 1.0, alpha);
    \\}
;

/// Instanced cell backgrounds.
pub const bg_vertex_source: [*c]const u8 =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct Uniforms {
    \\    float4x4 projection;
    \\    float4 textColor;
    \\    float4 overlayColor;
    \\    float4 cellSizeGridOffset;
    \\    float4 scalars;
    \\};
    \\
    \\struct BgQuad {
    \\    packed_float2 pos;
    \\};
    \\
    \\struct BgInstance {
    \\    packed_float2 gridPos;
    \\    packed_float3 color;
    \\    float alpha;
    \\};
    \\
    \\struct BgOut {
    \\    float4 position [[position]];
    \\    float3 color;
    \\    float alpha;
    \\};
    \\
    \\vertex BgOut vertex_main(const device BgQuad *quad [[buffer(0)]],
    \\                         const device BgInstance *instances [[buffer(1)]],
    \\                         constant Uniforms& uniforms [[buffer(2)]],
    \\                         uint vertex_id [[vertex_id]],
    \\                         uint instance_id [[instance_id]]) {
    \\    float2 q = float2(quad[vertex_id].pos);
    \\    BgInstance inst = instances[instance_id];
    \\    float2 grid = float2(inst.gridPos);
    \\    float2 cellSize = uniforms.cellSizeGridOffset.xy;
    \\    float2 gridOffset = uniforms.cellSizeGridOffset.zw;
    \\    float windowHeight = uniforms.scalars.x;
    \\    float cx = gridOffset.x + grid.x * cellSize.x;
    \\    float cy = windowHeight - gridOffset.y - (grid.y + 1.0) * cellSize.y;
    \\    float2 pos = float2(cx, cy) + q * cellSize;
    \\
    \\    BgOut out;
    \\    out.position = uniforms.projection * float4(pos, 0.0, 1.0);
    \\    out.color = float3(inst.color);
    \\    out.alpha = inst.alpha;
    \\    return out;
    \\}
;

pub const bg_fragment_source: [*c]const u8 =
    \\fragment float4 fragment_main(BgOut in [[stage_in]]) {
    \\    return float4(in.color, in.alpha);
    \\}
;

/// Instanced cell foreground glyphs.
pub const fg_vertex_source: [*c]const u8 =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct Uniforms {
    \\    float4x4 projection;
    \\    float4 textColor;
    \\    float4 overlayColor;
    \\    float4 cellSizeGridOffset;
    \\    float4 scalars;
    \\};
    \\
    \\struct FgQuad {
    \\    packed_float2 pos;
    \\};
    \\
    \\struct FgInstance {
    \\    packed_float2 gridPos;
    \\    packed_float4 glyphRect;
    \\    packed_float4 uv;
    \\    packed_float3 color;
    \\};
    \\
    \\struct FgOut {
    \\    float4 position [[position]];
    \\    float2 texCoord;
    \\    float3 color;
    \\};
    \\
    \\vertex FgOut vertex_main(const device FgQuad *quad [[buffer(0)]],
    \\                         const device FgInstance *instances [[buffer(1)]],
    \\                         constant Uniforms& uniforms [[buffer(2)]],
    \\                         uint vertex_id [[vertex_id]],
    \\                         uint instance_id [[instance_id]]) {
    \\    float2 q = float2(quad[vertex_id].pos);
    \\    FgInstance inst = instances[instance_id];
    \\    float2 grid = float2(inst.gridPos);
    \\    float4 glyph = float4(inst.glyphRect);
    \\    float4 uv = float4(inst.uv);
    \\
    \\    float2 cellSize = uniforms.cellSizeGridOffset.xy;
    \\    float2 gridOffset = uniforms.cellSizeGridOffset.zw;
    \\    float windowHeight = uniforms.scalars.x;
    \\    float cx = gridOffset.x + grid.x * cellSize.x;
    \\    float cy = windowHeight - gridOffset.y - (grid.y + 1.0) * cellSize.y;
    \\    float2 pos = float2(cx + glyph.x, cy + glyph.y) + q * glyph.zw;
    \\
    \\    FgOut out;
    \\    out.position = uniforms.projection * float4(pos, 0.0, 1.0);
    \\    out.texCoord = float2(uv.x + (uv.z - uv.x) * q.x, uv.w + (uv.y - uv.w) * q.y);
    \\    out.color = float3(inst.color);
    \\    return out;
    \\}
;

pub const fg_fragment_source: [*c]const u8 =
    \\fragment float4 fragment_main(FgOut in [[stage_in]],
    \\                              texture2d<float> atlas [[texture(0)]],
    \\                              sampler s [[sampler(0)]]) {
    \\    float alpha = atlas.sample(s, in.texCoord).r;
    \\    return float4(in.color, 1.0) * float4(1.0, 1.0, 1.0, alpha);
    \\}
;

/// Color (emoji) cell glyphs.
pub const color_fg_fragment_source: [*c]const u8 =
    \\fragment float4 fragment_main(FgOut in [[stage_in]],
    \\                              texture2d<float> atlas [[texture(0)]],
    \\                              sampler s [[sampler(0)]]) {
    \\    return atlas.sample(s, in.texCoord);
    \\}
;

/// Textured RGBA quad with opacity.
pub const simple_color_fragment_source: [*c]const u8 =
    \\fragment float4 fragment_main(QuadOut in [[stage_in]],
    \\                              texture2d<float> text [[texture(0)]],
    \\                              sampler s [[sampler(0)]],
    \\                              constant Uniforms& uniforms [[buffer(1)]]) {
    \\    return text.sample(s, in.texCoord) * uniforms.scalars.y;
    \\}
;

/// Flat-color tint (overlayColor).
pub const overlay_fragment_source: [*c]const u8 =
    \\fragment float4 fragment_main(QuadOut in [[stage_in]],
    \\                              constant Uniforms& uniforms [[buffer(1)]]) {
    \\    return uniforms.overlayColor;
    \\}
;
