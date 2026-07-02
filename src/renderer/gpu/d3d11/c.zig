//! D3D11 backend "GL-flavored" constants/types shim.
//!
//! Transitional mirror for renderer code that has not yet moved off `gpu.c.*`.
//! These are plain Zig declarations, not OpenGL imports.

pub const GLuint = u32;
pub const GLint = i32;
pub const GLenum = u32;
pub const GLsizei = i32;
pub const GLfloat = f32;
pub const GLboolean = u8;
pub const GLbitfield = u32;
pub const GLchar = u8;
pub const GLubyte = u8;
pub const GLsizeiptr = isize;
pub const GLintptr = isize;
pub const GLvoid = anyopaque;
pub const GLADloadfunc = ?*const fn ([*c]const u8) callconv(.c) ?*const fn () callconv(.c) void;

pub const GL_FALSE: GLboolean = 0;
pub const GL_TRUE: GLboolean = 1;

pub const GL_TRIANGLES: GLenum = 0x0004;
pub const GL_TRIANGLE_STRIP: GLenum = 0x0005;

pub const GL_RED: GLenum = 0x1903;
pub const GL_RGB: GLenum = 0x1907;
pub const GL_RGBA: GLenum = 0x1908;
pub const GL_RGBA8: GLenum = 0x8058;
pub const GL_BGRA: GLenum = 0x80E1;

pub const GL_ARRAY_BUFFER: GLenum = 0x8892;
pub const GL_ELEMENT_ARRAY_BUFFER: GLenum = 0x8893;
pub const GL_STATIC_DRAW: GLenum = 0x88E4;
pub const GL_DYNAMIC_DRAW: GLenum = 0x88E8;
pub const GL_STREAM_DRAW: GLenum = 0x88E0;

pub const GL_UNSIGNED_BYTE: GLenum = 0x1401;
pub const GL_BYTE: GLenum = 0x1400;
pub const GL_UNSIGNED_INT: GLenum = 0x1405;
pub const GL_INT: GLenum = 0x1404;
pub const GL_FLOAT: GLenum = 0x1406;

pub const GL_TEXTURE_2D: GLenum = 0x0DE1;
pub const GL_TEXTURE0: GLenum = 0x84C0;
pub const GL_TEXTURE_MIN_FILTER: GLenum = 0x2801;
pub const GL_TEXTURE_MAG_FILTER: GLenum = 0x2800;
pub const GL_TEXTURE_WRAP_S: GLenum = 0x2802;
pub const GL_TEXTURE_WRAP_T: GLenum = 0x2803;
pub const GL_TEXTURE_WIDTH: GLenum = 0x1000;
pub const GL_NEAREST: GLint = 0x2600;
pub const GL_LINEAR: GLint = 0x2601;
pub const GL_CLAMP_TO_EDGE: GLint = 0x812F;
pub const GL_REPEAT: GLint = 0x2901;
pub const GL_UNPACK_ALIGNMENT: GLenum = 0x0CF5;

pub const GL_VERTEX_SHADER: GLenum = 0x8B31;
pub const GL_FRAGMENT_SHADER: GLenum = 0x8B30;
pub const GL_COMPILE_STATUS: GLenum = 0x8B81;
pub const GL_LINK_STATUS: GLenum = 0x8B82;

pub const GL_FRAMEBUFFER: GLenum = 0x8D40;
pub const GL_COLOR_ATTACHMENT0: GLenum = 0x8CE0;
pub const GL_FRAMEBUFFER_COMPLETE: GLenum = 0x8CD5;

pub const GL_COLOR_BUFFER_BIT: GLbitfield = 0x00004000;
pub const GL_DEPTH_BUFFER_BIT: GLbitfield = 0x00000100;
pub const GL_SCISSOR_TEST: GLenum = 0x0C11;
pub const GL_SCISSOR_BOX: GLenum = 0x0C10;
pub const GL_VIEWPORT: GLenum = 0x0BA2;
pub const GL_BLEND: GLenum = 0x0BE2;

pub const GL_SRC_ALPHA: GLenum = 0x0302;
pub const GL_ONE_MINUS_SRC_ALPHA: GLenum = 0x0303;
pub const GL_ONE: GLenum = 1;
pub const GL_ZERO: GLenum = 0;

pub const GL_BLEND_SRC_RGB: GLenum = 0x80C9;
pub const GL_BLEND_DST_RGB: GLenum = 0x80C8;
pub const GL_BLEND_SRC_ALPHA: GLenum = 0x80CB;
pub const GL_BLEND_DST_ALPHA: GLenum = 0x80CA;

pub const GL_VENDOR: GLenum = 0x1F00;
pub const GL_RENDERER: GLenum = 0x1F01;
pub const GL_VERSION: GLenum = 0x1F02;
pub const GL_SHADING_LANGUAGE_VERSION: GLenum = 0x8B8C;
