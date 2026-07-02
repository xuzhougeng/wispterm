//! HLSL shader sources for the D3D11 backend.

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

const uniforms =
    \\cbuffer Uniforms : register(b0) {
    \\    column_major float4x4 projection;
    \\    float4 textColor;
    \\    float4 overlayColor;
    \\    float4 cellSizeGridOffset;
    \\    float4 scalars;
    \\};
    \\
;

pub const vertex_shader_source: [:0]const u8 = uniforms ++
    \\struct VSIn {
    \\    float4 vertex : ATTR0;
    \\};
    \\
    \\struct VSOut {
    \\    float4 position : SV_Position;
    \\    float2 texCoord : TEXCOORD0;
    \\};
    \\
    \\VSOut vs_main(VSIn input) {
    \\    VSOut outp;
    \\    outp.position = mul(projection, float4(input.vertex.xy, 0.0, 1.0));
    \\    outp.texCoord = input.vertex.zw;
    \\    return outp;
    \\}
;

pub const fragment_shader_source: [:0]const u8 = uniforms ++
    \\Texture2D textTex : register(t0);
    \\SamplerState textSampler : register(s0);
    \\
    \\struct PSIn {
    \\    float4 position : SV_Position;
    \\    float2 texCoord : TEXCOORD0;
    \\};
    \\
    \\float4 ps_main(PSIn input) : SV_Target {
    \\    float a = textTex.Sample(textSampler, input.texCoord).r;
    \\    return float4(textColor.rgb, 1.0) * float4(1.0, 1.0, 1.0, a);
    \\}
;

pub const bg_vertex_source: [:0]const u8 = uniforms ++
    \\struct VSIn {
    \\    float2 aQuad : ATTR0;
    \\    float2 aGridPos : ATTR1;
    \\    float3 aColor : ATTR2;
    \\    float aAlpha : ATTR3;
    \\};
    \\
    \\struct VSOut {
    \\    float4 position : SV_Position;
    \\    float3 color : COLOR0;
    \\    float alpha : COLOR1;
    \\};
    \\
    \\VSOut vs_main(VSIn input) {
    \\    float2 cellSize = cellSizeGridOffset.xy;
    \\    float2 gridOffset = cellSizeGridOffset.zw;
    \\    float windowHeight = scalars.x;
    \\    float cx = gridOffset.x + input.aGridPos.x * cellSize.x;
    \\    float cy = windowHeight - gridOffset.y - (input.aGridPos.y + 1.0) * cellSize.y;
    \\    float2 pos = float2(cx, cy) + input.aQuad * cellSize;
    \\    VSOut outp;
    \\    outp.position = mul(projection, float4(pos, 0.0, 1.0));
    \\    outp.color = input.aColor;
    \\    outp.alpha = input.aAlpha;
    \\    return outp;
    \\}
;

pub const bg_fragment_source: [:0]const u8 =
    \\struct PSIn {
    \\    float4 position : SV_Position;
    \\    float3 color : COLOR0;
    \\    float alpha : COLOR1;
    \\};
    \\
    \\float4 ps_main(PSIn input) : SV_Target {
    \\    return float4(input.color, input.alpha);
    \\}
;

pub const fg_vertex_source: [:0]const u8 = uniforms ++
    \\struct VSIn {
    \\    float2 aQuad : ATTR0;
    \\    float2 aGridPos : ATTR1;
    \\    float4 aGlyphRect : ATTR2;
    \\    float4 aUV : ATTR3;
    \\    float3 aColor : ATTR4;
    \\};
    \\
    \\struct VSOut {
    \\    float4 position : SV_Position;
    \\    float2 texCoord : TEXCOORD0;
    \\    float3 color : COLOR0;
    \\};
    \\
    \\VSOut vs_main(VSIn input) {
    \\    float2 cellSize = cellSizeGridOffset.xy;
    \\    float2 gridOffset = cellSizeGridOffset.zw;
    \\    float windowHeight = scalars.x;
    \\    float cx = gridOffset.x + input.aGridPos.x * cellSize.x;
    \\    float cy = windowHeight - gridOffset.y - (input.aGridPos.y + 1.0) * cellSize.y;
    \\    float2 pos = float2(cx + input.aGlyphRect.x, cy + input.aGlyphRect.y) + input.aQuad * input.aGlyphRect.zw;
    \\    VSOut outp;
    \\    outp.position = mul(projection, float4(pos, 0.0, 1.0));
    \\    outp.texCoord = float2(lerp(input.aUV.x, input.aUV.z, input.aQuad.x), lerp(input.aUV.w, input.aUV.y, input.aQuad.y));
    \\    outp.color = input.aColor;
    \\    return outp;
    \\}
;

pub const fg_fragment_source: [:0]const u8 =
    \\Texture2D atlasTex : register(t0);
    \\SamplerState atlasSampler : register(s0);
    \\
    \\struct PSIn {
    \\    float4 position : SV_Position;
    \\    float2 texCoord : TEXCOORD0;
    \\    float3 color : COLOR0;
    \\};
    \\
    \\float4 ps_main(PSIn input) : SV_Target {
    \\    float a = atlasTex.Sample(atlasSampler, input.texCoord).r;
    \\    return float4(input.color, 1.0) * float4(1.0, 1.0, 1.0, a);
    \\}
;

pub const color_fg_fragment_source: [:0]const u8 =
    \\Texture2D atlasTex : register(t0);
    \\SamplerState atlasSampler : register(s0);
    \\
    \\struct PSIn {
    \\    float4 position : SV_Position;
    \\    float2 texCoord : TEXCOORD0;
    \\    float3 color : COLOR0;
    \\};
    \\
    \\float4 ps_main(PSIn input) : SV_Target {
    \\    return atlasTex.Sample(atlasSampler, input.texCoord);
    \\}
;

pub const ui_batch_vertex_source: [:0]const u8 = uniforms ++
    \\struct VSIn {
    \\    float2 aQuad : ATTR0;
    \\    float4 aRect : ATTR1;
    \\    float4 aUV : ATTR2;
    \\    float3 aColor : ATTR3;
    \\};
    \\
    \\struct VSOut {
    \\    float4 position : SV_Position;
    \\    float2 texCoord : TEXCOORD0;
    \\    float3 color : COLOR0;
    \\};
    \\
    \\VSOut vs_main(VSIn input) {
    \\    float2 pos = input.aRect.xy + input.aQuad * input.aRect.zw;
    \\    VSOut outp;
    \\    outp.position = mul(projection, float4(pos, 0.0, 1.0));
    \\    outp.texCoord = float2(lerp(input.aUV.x, input.aUV.z, input.aQuad.x), lerp(input.aUV.w, input.aUV.y, input.aQuad.y));
    \\    outp.color = input.aColor;
    \\    return outp;
    \\}
;

pub const ui_batch_fragment_source: [:0]const u8 =
    \\Texture2D textTex : register(t0);
    \\SamplerState textSampler : register(s0);
    \\
    \\struct PSIn {
    \\    float4 position : SV_Position;
    \\    float2 texCoord : TEXCOORD0;
    \\    float3 color : COLOR0;
    \\};
    \\
    \\float4 ps_main(PSIn input) : SV_Target {
    \\    float a = textTex.Sample(textSampler, input.texCoord).r;
    \\    return float4(input.color, 1.0) * float4(1.0, 1.0, 1.0, a);
    \\}
;

pub const simple_color_fragment_source: [:0]const u8 = uniforms ++
    \\Texture2D textTex : register(t0);
    \\SamplerState textSampler : register(s0);
    \\
    \\struct PSIn {
    \\    float4 position : SV_Position;
    \\    float2 texCoord : TEXCOORD0;
    \\};
    \\
    \\float4 ps_main(PSIn input) : SV_Target {
    \\    return textTex.Sample(textSampler, input.texCoord) * scalars.y;
    \\}
;

pub const overlay_fragment_source: [:0]const u8 = uniforms ++
    \\struct PSIn {
    \\    float4 position : SV_Position;
    \\    float2 texCoord : TEXCOORD0;
    \\};
    \\
    \\float4 ps_main(PSIn input) : SV_Target {
    \\    return overlayColor;
    \\}
;
