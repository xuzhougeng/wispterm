//! GLSL shader sources for the OpenGL backend. The Metal backend (Phase D)
//! provides the symmetric MSL set under gpu/metal/shaders.zig.

pub const vertex_shader_source: [*c]const u8 =
    \\#version 330 core
    \\layout (location = 0) in vec4 vertex;
    \\out vec2 TexCoords;
    \\uniform mat4 projection;
    \\void main() {
    \\    gl_Position = projection * vec4(vertex.xy, 0.0, 1.0);
    \\    TexCoords = vertex.zw;
    \\}
;

pub const fragment_shader_source: [*c]const u8 =
    \\#version 330 core
    \\in vec2 TexCoords;
    \\out vec4 color;
    \\uniform sampler2D text;
    \\uniform vec3 textColor;
    \\void main() {
    \\    vec4 sampled = vec4(1.0, 1.0, 1.0, texture(text, TexCoords).r);
    \\    color = vec4(textColor, 1.0) * sampled;
    \\}
;

pub const bg_vertex_source: [*c]const u8 =
    \\#version 330 core
    \\// Unit quad (0,0)-(1,1)
    \\layout (location = 0) in vec2 aQuad;
    \\// Per-instance
    \\layout (location = 1) in vec2 aGridPos;
    \\layout (location = 2) in vec3 aColor;
    \\uniform mat4 projection;
    \\uniform vec2 cellSize;
    \\uniform vec2 gridOffset;
    \\uniform float windowHeight;
    \\layout (location = 3) in float aAlpha;
    \\flat out vec3 vColor;
    \\flat out float vAlpha;
    \\void main() {
    \\    // Cell top-left in screen coords
    \\    float cx = gridOffset.x + aGridPos.x * cellSize.x;
    \\    float cy = windowHeight - gridOffset.y - (aGridPos.y + 1.0) * cellSize.y;
    \\    vec2 pos = vec2(cx, cy) + aQuad * cellSize;
    \\    gl_Position = projection * vec4(pos, 0.0, 1.0);
    \\    vColor = aColor;
    \\    vAlpha = aAlpha;
    \\}
;

pub const bg_fragment_source: [*c]const u8 =
    \\#version 330 core
    \\flat in vec3 vColor;
    \\flat in float vAlpha;
    \\out vec4 fragColor;
    \\void main() {
    \\    // The pipeline blend func is (GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA),
    \\    // so per-cell alpha controls whether wallpaper shows through.
    \\    fragColor = vec4(vColor, vAlpha);
    \\}
;

pub const fg_vertex_source: [*c]const u8 =
    \\#version 330 core
    \\layout (location = 0) in vec2 aQuad;
    \\// Per-instance
    \\layout (location = 1) in vec2 aGridPos;
    \\layout (location = 2) in vec4 aGlyphRect;  // x, y, w, h in pixels
    \\layout (location = 3) in vec4 aUV;          // left, top, right, bottom
    \\layout (location = 4) in vec3 aColor;
    \\uniform mat4 projection;
    \\uniform vec2 cellSize;
    \\uniform vec2 gridOffset;
    \\uniform float windowHeight;
    \\out vec2 vTexCoord;
    \\flat out vec3 vColor;
    \\void main() {
    \\    float cx = gridOffset.x + aGridPos.x * cellSize.x;
    \\    float cy = windowHeight - gridOffset.y - (aGridPos.y + 1.0) * cellSize.y;
    \\    // Glyph quad within cell
    \\    vec2 pos = vec2(cx + aGlyphRect.x, cy + aGlyphRect.y) + aQuad * aGlyphRect.zw;
    \\    gl_Position = projection * vec4(pos, 0.0, 1.0);
    \\    // UV interpolation — V is flipped because atlas Y=0 is top but GL quad Y=0 is bottom
    \\    vTexCoord = vec2(mix(aUV.x, aUV.z, aQuad.x), mix(aUV.w, aUV.y, aQuad.y));
    \\    vColor = aColor;
    \\}
;

pub const fg_fragment_source: [*c]const u8 =
    \\#version 330 core
    \\in vec2 vTexCoord;
    \\flat in vec3 vColor;
    \\uniform sampler2D atlas;
    \\out vec4 fragColor;
    \\void main() {
    \\    float a = texture(atlas, vTexCoord).r;
    \\    fragColor = vec4(vColor, 1.0) * vec4(1.0, 1.0, 1.0, a);
    \\}
;

// Color emoji fragment shader — samples RGBA directly from the color atlas.
// FreeType's color emoji bitmaps (CBDT/CBLC) use premultiplied alpha,
// so we output them directly and use premultiplied blend mode (GL_ONE, GL_ONE_MINUS_SRC_ALPHA).
pub const color_fg_fragment_source: [*c]const u8 =
    \\#version 330 core
    \\in vec2 vTexCoord;
    \\flat in vec3 vColor;
    \\uniform sampler2D atlas;
    \\out vec4 fragColor;
    \\void main() {
    \\    fragColor = texture(atlas, vTexCoord);
    \\}
;

// Simple (non-instanced) color emoji fragment shader for titlebar/overlay use.
// Uses the same vertex layout as the text shader (vec4: xy=pos, zw=texcoord).
pub const simple_color_fragment_source: [*c]const u8 =
    \\#version 330 core
    \\in vec2 TexCoords;
    \\out vec4 color;
    \\uniform sampler2D text;
    \\uniform float opacity;
    \\void main() {
    \\    vec4 texColor = texture(text, TexCoords);
    \\    color = texColor * opacity;
    \\}
;

// Solid color overlay shader - outputs a solid color with alpha for true blending.
pub const overlay_fragment_source: [*c]const u8 =
    \\#version 330 core
    \\out vec4 color;
    \\uniform vec4 overlayColor;
    \\void main() {
    \\    color = overlayColor;
    \\}
;
