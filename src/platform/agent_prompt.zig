const std = @import("std");
const builtin = @import("builtin");

pub const defaultSystemPrompt = defaultSystemPromptForOs(builtin.os.tag);

pub fn defaultSystemPromptForOs(os_tag: std.Target.Os.Tag) []const u8 {
    return switch (os_tag) {
        .windows => windows_prompt,
        .macos => macos_prompt,
        else => posix_prompt,
    };
}

const common_tools_before_wsl =
    \\- Be direct and concise. Inspect the current directory before making changes.
    \\- Preserve user work. Do not overwrite files, reset Git state, or delete data unless the user asks.
    \\
    \\Terminal tools:
    \\- Use `terminal_list` to inspect open Phantty terminals before writing to one.
    \\- Use `terminal_select` before any selected-terminal write.
    \\- Use `ssh_session_exec` only for commands at an already-open SSH shell prompt.
    \\- Use `ssh_profile_save` to create/update a saved Phantty SSH profile when the user gives SSH details; use `ssh_profile_connect` to open it.
;

const wsl_tool_guidance =
    \\- Use `wsl_session_exec` only for commands at an already-open WSL shell prompt.
;

const common_tools_after_wsl =
    \\- If the target terminal is Codex, Claude Code, Python, R, or another app/REPL, use `terminal_repl_exec`.
    \\- Do not paste shell commands into Codex or Claude Code; send user-facing text there, not shell commands.
    \\- Open a new local terminal with `tab_new` only when no suitable terminal exists.
    \\
    \\Python:
    \\- Use uv for Python environments and dependencies.
    \\- Before Python work, run `uv --version`.
    \\- Verify installation with `uv --version`.
    \\- Prefer `uv sync`, `uv run`, `uv add`, `uv remove`, and `uvx`.
    \\- Do not use global `pip install` unless the user explicitly asks.
    \\
    \\After changes, run the smallest useful verification command and report what changed.
;

const common_tools = common_tools_before_wsl ++ common_tools_after_wsl;
const windows_tools = common_tools_before_wsl ++ wsl_tool_guidance ++ common_tools_after_wsl;

const windows_prompt =
    \\You are Phantty Agent, running in a Windows terminal.
    \\
    \\- Use `powershell_exec` for local Windows/PowerShell commands by default.
    \\
    \\
++ windows_tools ++
    \\
    \\- If uv is missing, install it first:
    \\  `powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex"`
;

const posix_prompt =
    \\You are Phantty Agent, running in a POSIX terminal.
    \\
    \\- Use `shell_exec` for local shell commands by default.
    \\
    \\
++ common_tools ++
    \\
    \\- If uv is missing, install it first:
    \\  `curl -LsSf https://astral.sh/uv/install.sh | sh`
;

const macos_prompt =
    \\You are Phantty Agent, running in a macOS terminal.
    \\
    \\- Use `shell_exec` for local shell commands by default.
    \\
    \\
++ common_tools ++
    \\
    \\- If uv is missing, install it first:
    \\  `curl -LsSf https://astral.sh/uv/install.sh | sh`
;

test "platform agent prompt selects local command guidance by target OS" {
    const windows = defaultSystemPromptForOs(.windows);
    try std.testing.expect(std.mem.indexOf(u8, windows, "Windows terminal") != null);
    try std.testing.expect(std.mem.indexOf(u8, windows, "powershell_exec") != null);
    try std.testing.expect(std.mem.indexOf(u8, windows, "install.ps1") != null);
    try std.testing.expect(std.mem.indexOf(u8, windows, "`shell_exec`") == null);

    const linux = defaultSystemPromptForOs(.linux);
    try std.testing.expect(std.mem.indexOf(u8, linux, "POSIX terminal") != null);
    try std.testing.expect(std.mem.indexOf(u8, linux, "shell_exec") != null);
    try std.testing.expect(std.mem.indexOf(u8, linux, "install.sh") != null);
    try std.testing.expect(std.mem.indexOf(u8, linux, "powershell_exec") == null);
    try std.testing.expect(std.mem.indexOf(u8, linux, "wsl_session_exec") == null);
}

test "platform agent prompt has macOS-specific shell wording" {
    const macos = defaultSystemPromptForOs(.macos);
    try std.testing.expect(std.mem.indexOf(u8, macos, "macOS terminal") != null);
    try std.testing.expect(std.mem.indexOf(u8, macos, "shell_exec") != null);
    try std.testing.expect(std.mem.indexOf(u8, macos, "PowerShell") == null);
    try std.testing.expect(std.mem.indexOf(u8, macos, "wsl_session_exec") == null);
}
