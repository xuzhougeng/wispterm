const std = @import("std");
const builtin = @import("builtin");
const release_package = @import("../release_package.zig");

fn architectureLabel(arch: std.Target.Cpu.Arch) ?[]const u8 {
    return switch (arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        else => null,
    };
}

pub fn currentPackage(
    allocator: std.mem.Allocator,
    webview_enabled: bool,
    gpu_backend: []const u8,
) !release_package.Package {
    _ = allocator;
    _ = webview_enabled;
    _ = gpu_backend;
    if (architectureLabel(builtin.cpu.arch) == null) return error.UnsupportedMacosArchitecture;
    return .{ .platform = .macos };
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
    if (package.platform != .macos) return error.UnsupportedReleasePackage;
    const arch_label = architectureLabel(arch) orelse return error.UnsupportedMacosArchitecture;
    return std.fmt.bufPrint(buf, "wispterm-macos-{s}-{s}.dmg", .{ arch_label, tag_name });
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

test "macOS update package reports the native platform package" {
    try std.testing.expectEqual(
        release_package.Platform.macos,
        (try currentPackage(std.testing.allocator, false, "metal")).platform,
    );
}

test "macOS update package builds architecture-qualified asset names" {
    const package = release_package.Package{ .platform = .macos };
    var buf: [128]u8 = undefined;

    const arm = try assetNameForArch("v1.33.1", package, .aarch64, &buf);
    try std.testing.expectEqualStrings("wispterm-macos-aarch64-v1.33.1.dmg", arm);

    const intel = try assetNameForArch("v1.33.1", package, .x86_64, &buf);
    try std.testing.expectEqualStrings("wispterm-macos-x86_64-v1.33.1.dmg", intel);
}

test "macOS update package matches only the requested architecture" {
    const package = release_package.Package{ .platform = .macos };

    try std.testing.expect(matchesAssetNameForArch(
        "wispterm-macos-aarch64-v1.33.1.dmg",
        "v1.33.1",
        package,
        .aarch64,
    ));
    try std.testing.expect(!matchesAssetNameForArch(
        "wispterm-macos-x86_64-v1.33.1.dmg",
        "v1.33.1",
        package,
        .aarch64,
    ));
    try std.testing.expect(!matchesAssetNameForArch(
        "wispterm-macos-v1.33.1.dmg",
        "v1.33.1",
        package,
        .aarch64,
    ));
    try std.testing.expect(!matchesAssetNameForArch(
        "wispterm-macos-aarch64-v1.33.1.zip",
        "v1.33.1",
        package,
        .aarch64,
    ));
}

test "macOS update package rejects unsupported release architectures" {
    const package = release_package.Package{ .platform = .macos };
    var buf: [128]u8 = undefined;
    try std.testing.expectError(
        error.UnsupportedMacosArchitecture,
        assetNameForArch("v1.33.1", package, .riscv64, &buf),
    );
    try std.testing.expect(!matchesAssetNameForArch(
        "wispterm-macos-riscv64-v1.33.1.dmg",
        "v1.33.1",
        package,
        .riscv64,
    ));
}
