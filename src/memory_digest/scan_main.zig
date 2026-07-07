//! Dev CLI: run one local memory-digest scan against the real machine.
//! Build: zig build memory-digest -Dtarget=aarch64-macos
//! Run:   ./zig-out/bin/wispterm-memory-digest
//! ponytail: macOS/HOME-based dev tool; the app's scheduler (M2) is the
//! real cross-platform entry point.
const std = @import("std");
const dirs = @import("../platform/dirs.zig");
const run_mod = @import("run.zig");

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const home = try std.process.getEnvVarOwned(gpa, "HOME");
    defer gpa.free(home);

    const claude_dir = try std.fs.path.join(gpa, &.{ home, ".claude", "projects" });
    defer gpa.free(claude_dir);
    const codex_dir = try std.fs.path.join(gpa, &.{ home, ".codex", "sessions" });
    defer gpa.free(codex_dir);
    const agent_history_dir = try dirs.agentHistoryDir(gpa);
    defer gpa.free(agent_history_dir);
    const wispterm_dir = try std.fs.path.join(gpa, &.{ agent_history_dir, "sessions" });
    defer gpa.free(wispterm_dir);
    const memory_root = try dirs.memoryDir(gpa);
    defer gpa.free(memory_root);

    const summary = try run_mod.runOnce(gpa, .{
        .roots = .{
            .claude_projects_dir = claude_dir,
            .codex_sessions_dir = codex_dir,
            .wispterm_sessions_dir = wispterm_dir,
        },
        .memory_root = memory_root,
        .now_ms = std.time.milliTimestamp(),
        // ponytail: dev CLI hardcodes UTC+8; the app injects the real
        // offset when the M2 scheduler lands.
        .tz_offset_seconds = 8 * 3600,
    });
    std.debug.print(
        "memory-digest: {d} sessions with new messages, {d} daily files written under {s}\n",
        .{ summary.sessions_collected, summary.days_written, memory_root },
    );
}
