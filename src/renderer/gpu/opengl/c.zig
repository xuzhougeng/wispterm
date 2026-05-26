//! The glad/gl.h cImport for the OpenGL backend.
//! Goal: by Phase A6 this is the only place in the tree that includes
//! glad/gl.h (renderer files still have their own cImports until then).
pub const c = @cImport({
    @cInclude("glad/gl.h");
});
