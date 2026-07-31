//! ponytail: thin root-level forwarder. Zig 0.15 module boundaries are
//! per-directory, and memory_digest/scan_main.zig reaches into ../platform
//! and ../terminal_agents (via run.zig), so the compiled module's root
//! must be src/ like every other single-file CLI here (filetool, bench,
//! ctl). This file only exists to sit at that root; real logic stays in
//! memory_digest/scan_main.zig per the task brief.
pub const main = @import("memory_digest/scan_main.zig").main;
