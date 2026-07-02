//! GraphicsAPI spine. Resolves the active GPU backend at comptime (Ghostty
//! style, no runtime vtable) and re-exports its types. See
//! docs/decoupling-guide.md §2 and the spec for the abstraction hierarchy.
const builtin = @import("builtin");
const build_options = @import("build_options");

pub const Backend = @import("backend.zig").Backend;
pub const types = @import("types.zig");
pub const PrimitiveTopology = types.PrimitiveTopology;
pub const BufferUsage = types.BufferUsage;
pub const TextureFormat = types.TextureFormat;
pub const TextureUsage = types.TextureUsage;
pub const BlendMode = types.BlendMode;
pub const BlendFactor = types.BlendFactor;
pub const ProgramHandle = types.ProgramHandle;
pub const VertexArrayHandle = types.VertexArrayHandle;
pub const SamplerMode = types.SamplerMode;
pub const Viewport = types.Viewport;
pub const Scissor = types.Scissor;
pub const ClearColor = types.ClearColor;
pub const DriverInfo = types.DriverInfo;
pub const BlendSnapshot = types.BlendSnapshot;
pub const SwapDiagnostics = types.SwapDiagnostics;
pub const active: Backend = Backend.resolve(builtin.os.tag, build_options.gpu_backend);

/// Backend-neutral per-frame renderer diagnostics/state.
/// Transition note: `gpu.gl_init` still mirrors old names for compatibility,
/// but renderer feature code should use these WispTerm-owned fields.
pub threadlocal var draw_call_count: u32 = 0;
pub threadlocal var background_opacity: f32 = 1.0;

// Resolve the active backend lazily inside each branch so a non-selected
// backend's C imports (e.g. the OpenGL backend's `@cInclude("glad/gl.h")`) are
// never analyzed on a target that doesn't ship them (macOS → Metal).
const impl = switch (active) {
    .opengl => @import("opengl/api.zig"),
    .metal => @import("metal/api.zig"),
    .d3d11 => @import("d3d11/api.zig"),
};

// The active backend's surface. The GL table lives in the backend (moved out
// of AppWindow in A2); the app reaches it through the decls below.
pub const Context = impl.Context; // context lifecycle (owns the GL table)
pub const c = impl.c; // GL constants/types (transition: removed from app code by A6)
pub const gl_init = impl.gl_init; // GL helpers + buffers (GLSL in shaders.zig)
pub const shaders = impl.shaders; // backend GLSL sources (for cell pipelines)

/// Pointer to the active backend's GL function table. Transition handle used by
/// renderer files until they route through the primitives (A3); removed in A6.
pub inline fn glTable() *impl.GlTable {
    return &Context.gl;
}

// Reserved Ghostty-shaped primitive slots (bodies land in A3/A4):
pub const Texture = impl.Texture;
pub const Buffer = impl.Buffer;
pub const Pipeline = impl.Pipeline;
pub const Framebuffer = impl.Framebuffer;
pub const readback = impl.readback;
pub const state = impl.render_state;
pub const vertex = impl.vertex;
