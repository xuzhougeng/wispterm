const std = @import("std");

pub const DraftInput = struct {
    tool_name: []const u8,
    filename: []const u8,
    sha256: []const u8,
    file_size: u64,
    platform: []const u8,
    version_output: []const u8 = "",
    user_note: []const u8 = "",
};

pub fn buildDraftPrompt(allocator: std.mem.Allocator, input: DraftInput) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\Draft a WispTerm SKILL.md for a local executable tool.
        \\
        \\Rules:
        \\- Return only markdown.
        \\- Include YAML frontmatter with name and description.
        \\- Explain that calls use an args array and the executable name is not included in args.
        \\- do not invent unsupported commands or flags.
        \\- When evidence is weak, explicitly name uncertainty.
        \\- Keep the draft concise enough to be used as a model tool description.
        \\
        \\Evidence:
        \\- tool name: {s}
        \\- filename: {s}
        \\- sha256: {s}
        \\- file size: {d}
        \\- platform: {s}
        \\- version output: {s}
        \\- user note: {s}
        \\
    , .{ input.tool_name, input.filename, input.sha256, input.file_size, input.platform, input.version_output, input.user_note });
}

test "tool_skill_draft: prompt tells model not to invent commands" {
    const a = std.testing.allocator;
    const prompt = try buildDraftPrompt(a, .{
        .tool_name = "mystery",
        .filename = "mystery.exe",
        .sha256 = "abc123",
        .file_size = 12345,
        .platform = "windows",
        .version_output = "mystery 0.1.0",
        .user_note = "This may convert DOCX files.",
    });
    defer a.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "do not invent unsupported commands") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "mystery.exe") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "This may convert DOCX files.") != null);
}
