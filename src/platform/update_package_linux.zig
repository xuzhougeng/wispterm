const std = @import("std");
const builtin = @import("builtin");
const release_package = @import("../release_package.zig");

fn architectureLabel(arch: std.Target.Cpu.Arch) ?[]const u8 {
    return switch (arch) {
        .x86_64 => "x86_64",
        else => null,
    };
}

fn versionFromTag(tag_name: []const u8) []const u8 {
    if (std.mem.startsWith(u8, tag_name, "v")) return tag_name[1..];
    return tag_name;
}

pub fn currentPackage(
    allocator: std.mem.Allocator,
    webview_enabled: bool,
    gpu_backend: []const u8,
) !release_package.Package {
    _ = allocator;
    _ = webview_enabled;
    _ = gpu_backend;
    if (architectureLabel(builtin.cpu.arch) == null) return error.UnsupportedLinuxArchitecture;
    return .{ .platform = .linux };
}

pub fn assetName(tag_name: []const u8, package: release_package.Package, buf: []u8) ![]const u8 {
    return assetNameForArch(tag_name, package, builtin.cpu.arch, buf);
}

pub fn matchesAssetName(name: []const u8, tag_name: []const u8, package: release_package.Package) bool {
    return matchesAssetNameForArch(name, tag_name, package, builtin.cpu.arch);
}

fn assetNameForArch(
    tag_name: []const u8,
    package: release_package.Package,
    arch: std.Target.Cpu.Arch,
    buf: []u8,
) ![]const u8 {
    if (package.platform != .linux) return error.UnsupportedReleasePackage;
    const arch_label = architectureLabel(arch) orelse return error.UnsupportedLinuxArchitecture;
    return std.fmt.bufPrint(buf, "WispTerm-{s}-{s}.AppImage", .{ versionFromTag(tag_name), arch_label });
}

fn matchesAssetNameForArch(
    name: []const u8,
    tag_name: []const u8,
    package: release_package.Package,
    arch: std.Target.Cpu.Arch,
) bool {
    var expected_buf: [128]u8 = undefined;
    const expected = assetNameForArch(tag_name, package, arch, &expected_buf) catch return false;
    return std.mem.eql(u8, name, expected);
}

test "Linux update package builds the published x86_64 AppImage name" {
    const package = release_package.Package{ .platform = .linux };
    var buf: [128]u8 = undefined;
    const name = try assetNameForArch("v1.33.1", package, .x86_64, &buf);
    try std.testing.expectEqualStrings("WispTerm-1.33.1-x86_64.AppImage", name);
}

test "Linux update package matches only the exact published asset" {
    const package = release_package.Package{ .platform = .linux };
    try std.testing.expect(matchesAssetNameForArch(
        "WispTerm-1.33.1-x86_64.AppImage",
        "v1.33.1",
        package,
        .x86_64,
    ));
    try std.testing.expect(!matchesAssetNameForArch(
        "WispTerm-v1.33.1-x86_64.AppImage",
        "v1.33.1",
        package,
        .x86_64,
    ));
    try std.testing.expect(!matchesAssetNameForArch(
        "wispterm-1.33.1-x86_64.AppImage",
        "v1.33.1",
        package,
        .x86_64,
    ));
    try std.testing.expect(!matchesAssetNameForArch(
        "WispTerm-1.33.1-x86_64.tar.gz",
        "v1.33.1",
        package,
        .x86_64,
    ));
}

test "Linux update package rejects architectures without published assets" {
    const package = release_package.Package{ .platform = .linux };
    var buf: [128]u8 = undefined;
    try std.testing.expectError(
        error.UnsupportedLinuxArchitecture,
        assetNameForArch("v1.33.1", package, .aarch64, &buf),
    );
    try std.testing.expect(!matchesAssetNameForArch(
        "WispTerm-1.33.1-aarch64.AppImage",
        "v1.33.1",
        package,
        .aarch64,
    ));
}
