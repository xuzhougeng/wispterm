//! Phase IV D3D11 parity coverage guard.
//!
//! This does not prove full visual parity. It freezes the explicit Phase IV
//! coverage slices that have already been extracted into pure layout/policy
//! modules so future work cannot silently drop them from the fast suite or
//! reintroduce backend-specific GPU vocabulary into those shared surfaces.

const std = @import("std");
const scan = @import("scan.zig");

const GuardedSource = struct {
    name: []const u8,
    source: []const u8,
};

const RequiredImport = struct {
    label: []const u8,
    import_text: []const u8,
};

const explicit_phase4_sources = [_]GuardedSource{
    .{ .name = "renderer/titlebar_layout.zig", .source = @embedFile("../renderer/titlebar_layout.zig") },
    .{ .name = "renderer/overlays/startup_shortcuts_layout.zig", .source = @embedFile("../renderer/overlays/startup_shortcuts_layout.zig") },
    .{ .name = "renderer/file_explorer_layout.zig", .source = @embedFile("../renderer/file_explorer_layout.zig") },
    .{ .name = "renderer/overlays/settings_page_layout.zig", .source = @embedFile("../renderer/overlays/settings_page_layout.zig") },
    .{ .name = "renderer/background_image_layout.zig", .source = @embedFile("../renderer/background_image_layout.zig") },
    .{ .name = "preview/image_layout.zig", .source = @embedFile("../preview/image_layout.zig") },
    .{ .name = "renderer/qr_panel_layout.zig", .source = @embedFile("../renderer/qr_panel_layout.zig") },
    .{ .name = "assistant/conversation/layout.zig", .source = @embedFile("../assistant/conversation/layout.zig") },
    .{ .name = "renderer/overlays/command_palette_layout.zig", .source = @embedFile("../renderer/overlays/command_palette_layout.zig") },
    .{ .name = "renderer/skill_center_renderer.zig", .source = @embedFile("../renderer/skill_center_renderer.zig") },
    .{ .name = "preview/markdown_layout.zig", .source = @embedFile("../preview/markdown_layout.zig") },
    .{ .name = "renderer/post_process_policy.zig", .source = @embedFile("../renderer/post_process_policy.zig") },
};

const supplemental_user_visible_sources = [_]GuardedSource{
    .{ .name = "renderer/port_forwarding_renderer.zig", .source = @embedFile("../renderer/port_forwarding_renderer.zig") },
};

const forbidden_backend_vocab = [_][]const u8{
    "gpu.c",
    "gl_init",
    "GL_",
    "ID3D11",
    "HLSL",
    "MTL",
};

const required_fast_imports = [_]RequiredImport{
    .{ .label = "titlebar layout", .import_text = "@import(\"renderer/titlebar_layout.zig\")" },
    .{ .label = "startup overlay layout", .import_text = "@import(\"renderer/overlays/startup_shortcuts_layout.zig\")" },
    .{ .label = "file explorer layout", .import_text = "@import(\"renderer/file_explorer_layout.zig\")" },
    .{ .label = "settings page layout", .import_text = "@import(\"renderer/overlays/settings_page_layout.zig\")" },
    .{ .label = "background image layout", .import_text = "@import(\"renderer/background_image_layout.zig\")" },
    .{ .label = "image preview layout", .import_text = "@import(\"preview/image_layout.zig\")" },
    .{ .label = "QR panel layout", .import_text = "@import(\"renderer/qr_panel_layout.zig\")" },
    .{ .label = "assistant conversation layout", .import_text = "@import(\"assistant/conversation/layout.zig\")" },
    .{ .label = "command palette layout", .import_text = "@import(\"renderer/overlays/command_palette_layout.zig\")" },
    .{ .label = "skill center renderer layout", .import_text = "@import(\"renderer/skill_center_renderer.zig\")" },
    .{ .label = "markdown preview layout", .import_text = "@import(\"preview/markdown_layout.zig\")" },
    .{ .label = "post-process backend policy", .import_text = "@import(\"renderer/post_process_policy.zig\")" },
    .{ .label = "supplemental port forwarding renderer", .import_text = "@import(\"renderer/port_forwarding_renderer.zig\")" },
};

fn countForbidden(source: []const u8) usize {
    var total: usize = 0;
    for (forbidden_backend_vocab) |needle| {
        total += scan.countOccurrences(source, needle);
    }
    return total;
}

fn expectBackendNeutral(sources: []const GuardedSource) !void {
    var failed = false;
    for (sources) |source_file| {
        const count = countForbidden(source_file.source);
        if (count == 0) continue;

        std.debug.print(
            "d3d11_phase4_guard: {s} contains {d} backend-specific token(s); keep Phase IV feature layout/policy shared and route GPU work through backend-owned code.\n",
            .{ source_file.name, count },
        );
        failed = true;
    }

    try std.testing.expect(!failed);
}

test "D3D11 Phase IV explicit parity surfaces stay backend-neutral" {
    try expectBackendNeutral(&explicit_phase4_sources);
}

test "D3D11 Phase IV supplemental user-visible surfaces stay backend-neutral" {
    try expectBackendNeutral(&supplemental_user_visible_sources);
}

test "D3D11 Phase IV coverage remains in the fast suite" {
    const fast_suite = @embedFile("../test_fast.zig");

    var missing = false;
    for (required_fast_imports) |required| {
        if (std.mem.indexOf(u8, fast_suite, required.import_text) != null) continue;

        std.debug.print(
            "d3d11_phase4_guard: missing fast-suite import for {s}: {s}\n",
            .{ required.label, required.import_text },
        );
        missing = true;
    }

    try std.testing.expect(!missing);
}
