//! D3D11 has no GL function table. This zero-sized placeholder preserves the
//! transitional `gpu.glTable()` surface while renderer code finishes migrating.

pub const GlTable = struct {};
