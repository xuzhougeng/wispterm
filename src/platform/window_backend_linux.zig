//! Linux window-backend re-export: maps the shared `window_backend.zig` facade
//! to the SDL3 window implementation.
const sdl = @import("../apprt/sdl.zig");

pub const Window = sdl.Window;
pub const FileDropHandler = sdl.FileDropHandler;
pub const setGlobalWindow = sdl.setGlobalWindow;
pub const glGetProcAddress = sdl.glGetProcAddress;
