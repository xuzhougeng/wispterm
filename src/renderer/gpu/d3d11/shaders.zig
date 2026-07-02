//! Minimal HLSL used by the Phase II backend skeleton.

pub const phase2_vertex: [:0]const u8 =
    \\struct VSOut {
    \\    float4 position : SV_Position;
    \\    float4 color : COLOR0;
    \\};
    \\
    \\VSOut vs_main(uint id : SV_VertexID) {
    \\    float2 positions[6] = {
    \\        float2(-0.70, -0.62),
    \\        float2(-0.10,  0.58),
    \\        float2( 0.70, -0.62),
    \\        float2( 0.70, -0.62),
    \\        float2(-0.10,  0.58),
    \\        float2( 0.38,  0.18),
    \\    };
    \\    VSOut outp;
    \\    outp.position = float4(positions[id], 0.0, 1.0);
    \\    outp.color = float4(0.12, 0.68, 0.95, 1.0);
    \\    return outp;
    \\}
;

pub const phase2_pixel: [:0]const u8 =
    \\float4 ps_main(float4 position : SV_Position, float4 color : COLOR0) : SV_Target {
    \\    return color;
    \\}
;

const placeholder_glsl: [*c]const u8 =
    \\// D3D11 Phase II placeholder. Real terminal HLSL starts in Phase III.
;

pub const vertex_shader_source = placeholder_glsl;
pub const fragment_shader_source = placeholder_glsl;
pub const bg_vertex_source = placeholder_glsl;
pub const bg_fragment_source = placeholder_glsl;
pub const fg_vertex_source = placeholder_glsl;
pub const fg_fragment_source = placeholder_glsl;
pub const color_fg_fragment_source = placeholder_glsl;
pub const ui_batch_vertex_source = placeholder_glsl;
pub const ui_batch_fragment_source = placeholder_glsl;
pub const simple_color_fragment_source = placeholder_glsl;
pub const overlay_fragment_source = placeholder_glsl;
