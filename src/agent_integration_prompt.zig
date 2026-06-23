const std = @import("std");

pub const prompt_text =
    \\You are adding an optional WispTerm integration for the agent you are running.
    \\
    \\Goal:
    \\- Generate or update this agent's own hook/config so it can report state to WispTerm.
    \\- Preserve every existing user hook/config entry.
    \\- Make the change idempotent: running this prompt twice must not duplicate hooks.
    \\- Never fail the user's agent command because of WispTerm reporting.
    \\- Do not disable WispTerm's built-in terminal-output and foreground-command detection; this hook is only an optional authoritative signal.
    \\
    \\WispTerm protocol:
    \\- Emit OSC 7748 with this payload shape:
    \\  wispterm-agent;state=<state>;app=<app>
    \\- Known states: running, waiting_approval, needs_input, halted, failed, done.
    \\- Known app labels: app=codex for Codex, app=claude_code for Claude Code.
    \\- If this is another agent and WispTerm has no app label for it yet, do not invent a label. Ask the user whether they want WispTerm updated for that agent.
    \\
    \\POSIX hook command template:
    \\printf '\033]7748;wispterm-agent;state=running;app=codex\007' > /dev/tty 2>/dev/null || true
    \\
    \\Windows PowerShell hook command template:
    \\$bytes = [Text.Encoding]::ASCII.GetBytes("`e]7748;wispterm-agent;state=running;app=codex`a")
    \\$con = [IO.File]::OpenWrite("CONOUT$")
    \\try { $con.Write($bytes, 0, $bytes.Length) } finally { $con.Dispose() }
    \\
    \\State mapping guidance:
    \\- Before starting model/tool work, report state=running.
    \\- When waiting for explicit user approval, report state=waiting_approval.
    \\- When waiting for normal user input at an agent prompt, report state=needs_input.
    \\- When interrupted/cancelled, report state=halted.
    \\- When the agent operation fails, report state=failed.
    \\- When the agent is finished and idle, report state=done.
    \\
    \\Implementation requirements:
    \\- Write markers to the controlling terminal, not to captured stdout logs.
    \\- Use /dev/tty on POSIX and CONOUT$ on Windows when available.
    \\- Keep all commands best-effort, quiet, and non-blocking.
    \\- Use app=codex only for Codex hooks and app=claude_code only for Claude Code hooks.
    \\- Explain exactly which file(s) you changed and how the user can remove the integration.
;

pub fn promptText() []const u8 {
    return prompt_text;
}

test "integration prompt describes WispTerm OSC contract for external agents" {
    const prompt = promptText();
    try std.testing.expect(std.mem.indexOf(u8, prompt, "OSC 7748") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "wispterm-agent") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "state=running") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "waiting_approval") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "app=codex") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "app=claude_code") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "/dev/tty") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "CONOUT$") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Do not disable WispTerm") != null);
}
