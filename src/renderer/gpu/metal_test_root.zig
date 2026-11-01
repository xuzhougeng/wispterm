//! `zig build test-metal` entry. Rooted at `gpu/` rather than `gpu/metal/` so
//! the Metal backend's shared `../types.zig` import stays inside the module
//! path; the tests themselves live in `metal/test.zig`.
test {
    _ = @import("metal/test.zig");
}
