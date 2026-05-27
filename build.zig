const std = @import("std");
const apple_sdk = @import("apple-sdk");
const build_guards = @import("src/build_guards.zig");

comptime {
    @setEvalBranchQuota(200_000);
    // Forbid leaking target-OS booleans / Windows-specific names into the build
    // script's app-facing options. The patterns and messages live in
    // src/build_guards.zig so the same logic is unit-tested by test_main.zig.
    if (build_guards.firstLeak(@embedFile("build.zig"))) |message| {
        @compileError(message);
    }
}

const windows_system_libraries = [_][]const u8{
    "user32",
    "gdi32",
    "gdiplus",
    "dwmapi",
    "ws2_32",
    "mswsock",
    "comdlg32",
    "shell32",
    "imm32",
    "winhttp",
    "ole32",
    "psapi",
    "shcore", // GetDpiForMonitor for render diagnostics (per-monitor DPI)
};

const macos_app_frameworks = [_][]const u8{
    "Metal",
    "QuartzCore",
    "AppKit",
    "CoreText",
    "CoreGraphics",
    "Foundation",
    "CoreFoundation",
    "Carbon",
};

const macos_objective_c_sources = [_][]const u8{
    "src/renderer/gpu/metal/bridge.m",
    "src/platform/window_macos_bridge.m",
    "src/platform/font_macos_bridge.m",
    "src/platform/services_macos_bridge.m",
};

const MacosBundleMetadata = struct {
    bundle_dir: []const u8,
    executable_name: []const u8,
    display_name: []const u8,
    bundle_identifier: []const u8,
    minimum_system_version: []const u8,
};

const EmbeddedBrowserBackend = enum {
    none,
    webview2,

    fn isSupported(self: EmbeddedBrowserBackend) bool {
        return self != .none;
    }
};

const PlatformFeatures = struct {
    supports_desktop_exe: bool,
    supports_embedded_browser: bool,
    embedded_browser_backend: EmbeddedBrowserBackend,
    supports_resource_manifest: bool,
    supports_gui_subsystem: bool,
    supports_remote_transport: bool,
    supports_app_bundle: bool,
    system_libraries: []const []const u8,
    app_frameworks: []const []const u8,
    opengl_system_library: ?[]const u8,

    fn forOs(os_tag: std.Target.Os.Tag) PlatformFeatures {
        const uses_windows_backend = os_tag == .windows;
        const uses_macos_backend = os_tag == .macos;
        const has_desktop_backend = uses_windows_backend or uses_macos_backend;
        const has_app_bundle = os_tag == .macos;
        const embedded_browser_backend: EmbeddedBrowserBackend = if (uses_windows_backend) .webview2 else .none;
        return .{
            .supports_desktop_exe = has_desktop_backend,
            .supports_embedded_browser = embedded_browser_backend.isSupported(),
            .embedded_browser_backend = embedded_browser_backend,
            .supports_resource_manifest = uses_windows_backend,
            .supports_gui_subsystem = uses_windows_backend,
            .supports_remote_transport = uses_windows_backend,
            .supports_app_bundle = has_app_bundle,
            .system_libraries = if (uses_windows_backend) &windows_system_libraries else &.{},
            .app_frameworks = if (has_app_bundle) &macos_app_frameworks else &.{},
            .opengl_system_library = if (uses_windows_backend) "opengl32" else null,
        };
    }
};

fn defaultDevelopmentTarget() std.Target.Query {
    return .{
        .cpu_arch = .x86_64,
        .os_tag = .windows,
        .abi = .gnu,
    };
}

fn systemLibrariesFor(features: PlatformFeatures) []const []const u8 {
    return features.system_libraries;
}

fn appFrameworksFor(features: PlatformFeatures) []const []const u8 {
    return features.app_frameworks;
}

fn macosBundleMetadata() MacosBundleMetadata {
    return .{
        .bundle_dir = "Phantty.app",
        .executable_name = "Phantty",
        .display_name = "Phantty",
        .bundle_identifier = "com.phantty.terminal",
        .minimum_system_version = "13.0",
    };
}

fn macosBundleInfoPlistPath() []const u8 {
    return "Phantty.app/Contents/Info.plist";
}

fn macosBundleExecutablePath() []const u8 {
    return "Phantty.app/Contents/MacOS/Phantty";
}

fn macosBundleResourcesKeepPath() []const u8 {
    return "Phantty.app/Contents/Resources/.keep";
}

fn macosPackageScriptPath() []const u8 {
    return "packaging/macos/package.sh";
}

fn macosEntitlementsPath() []const u8 {
    return "packaging/macos/Phantty.entitlements";
}

fn macosInfoPlist(allocator: std.mem.Allocator, app_version: []const u8) []const u8 {
    const metadata = macosBundleMetadata();
    return std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>CFBundleDevelopmentRegion</key>
        \\    <string>en</string>
        \\    <key>CFBundleDisplayName</key>
        \\    <string>{s}</string>
        \\    <key>CFBundleExecutable</key>
        \\    <string>{s}</string>
        \\    <key>CFBundleIdentifier</key>
        \\    <string>{s}</string>
        \\    <key>CFBundleInfoDictionaryVersion</key>
        \\    <string>6.0</string>
        \\    <key>CFBundleName</key>
        \\    <string>{s}</string>
        \\    <key>CFBundlePackageType</key>
        \\    <string>APPL</string>
        \\    <key>CFBundleShortVersionString</key>
        \\    <string>{s}</string>
        \\    <key>CFBundleVersion</key>
        \\    <string>{s}</string>
        \\    <key>LSMinimumSystemVersion</key>
        \\    <string>{s}</string>
        \\    <key>NSHighResolutionCapable</key>
        \\    <true/>
        \\</dict>
        \\</plist>
        \\
    , .{
        metadata.display_name,
        metadata.executable_name,
        metadata.bundle_identifier,
        metadata.display_name,
        app_version,
        app_version,
        metadata.minimum_system_version,
    }) catch @panic("OOM");
}

fn supportsMacosAppTarget(os_tag: std.Target.Os.Tag, cpu_arch: std.Target.Cpu.Arch) bool {
    if (os_tag != .macos) return false;
    return switch (cpu_arch) {
        .aarch64, .x86_64 => true,
        else => false,
    };
}

fn webviewBridgeSourcePath(features: PlatformFeatures) ?[]const u8 {
    return switch (features.embedded_browser_backend) {
        .webview2 => "src/platform/webview2_bridge.c",
        .none => null,
    };
}

fn shouldSkipForeignTestRun(
    host_os_tag: std.Target.Os.Tag,
    target_os_tag: std.Target.Os.Tag,
    run_foreign_tests: bool,
) bool {
    if (run_foreign_tests) return false;
    return host_os_tag != target_os_tag;
}

fn defaultEmitDesktopExe(features: PlatformFeatures) bool {
    return features.supports_desktop_exe;
}

fn defaultEmitSharedCompileChecks(features: PlatformFeatures) bool {
    return !features.supports_desktop_exe;
}

test "default development target remains x86_64 windows gnu" {
    const query = defaultDevelopmentTarget();

    try std.testing.expectEqual(std.Target.Cpu.Arch.x86_64, query.cpu_arch.?);
    try std.testing.expectEqual(std.Target.Os.Tag.windows, query.os_tag.?);
    try std.testing.expectEqual(std.Target.Abi.gnu, query.abi.?);
}

test "platform feature gates enable implemented desktop artifacts" {
    const windows = PlatformFeatures.forOs(.windows);
    try std.testing.expect(windows.supports_desktop_exe);
    try std.testing.expect(windows.supports_embedded_browser);
    try std.testing.expectEqual(EmbeddedBrowserBackend.webview2, windows.embedded_browser_backend);
    try std.testing.expect(windows.supports_resource_manifest);
    try std.testing.expect(windows.supports_gui_subsystem);
    try std.testing.expect(windows.supports_remote_transport);
    try std.testing.expect(!windows.supports_app_bundle);
    try std.testing.expectEqualStrings("opengl32", windows.opengl_system_library.?);

    const linux = PlatformFeatures.forOs(.linux);
    try std.testing.expect(!linux.supports_desktop_exe);
    try std.testing.expect(!linux.supports_embedded_browser);
    try std.testing.expectEqual(EmbeddedBrowserBackend.none, linux.embedded_browser_backend);
    try std.testing.expect(!linux.supports_resource_manifest);
    try std.testing.expect(!linux.supports_gui_subsystem);
    try std.testing.expect(!linux.supports_remote_transport);
    try std.testing.expect(!linux.supports_app_bundle);
    try std.testing.expect(linux.opengl_system_library == null);

    const macos = PlatformFeatures.forOs(.macos);
    try std.testing.expect(macos.supports_desktop_exe);
    try std.testing.expect(!macos.supports_embedded_browser);
    try std.testing.expectEqual(EmbeddedBrowserBackend.none, macos.embedded_browser_backend);
    try std.testing.expect(!macos.supports_resource_manifest);
    try std.testing.expect(!macos.supports_gui_subsystem);
    try std.testing.expect(!macos.supports_remote_transport);
    try std.testing.expect(macos.supports_app_bundle);
    try std.testing.expect(macos.opengl_system_library == null);
}

test "windows system libraries are gated by platform" {
    const windows = PlatformFeatures.forOs(.windows);
    try std.testing.expectEqual(@as(usize, 13), systemLibrariesFor(windows).len);
    try std.testing.expectEqualStrings("user32", systemLibrariesFor(windows)[0]);
    try std.testing.expectEqualStrings("psapi", systemLibrariesFor(windows)[11]);
    try std.testing.expectEqualStrings("shcore", systemLibrariesFor(windows)[12]);

    const linux = PlatformFeatures.forOs(.linux);
    try std.testing.expectEqual(@as(usize, 0), systemLibrariesFor(linux).len);

    const macos = PlatformFeatures.forOs(.macos);
    try std.testing.expectEqual(@as(usize, 0), systemLibrariesFor(macos).len);
}

test "macOS platform advertises required app frameworks" {
    const frameworks = appFrameworksFor(PlatformFeatures.forOs(.macos));
    try std.testing.expectEqual(@as(usize, 8), frameworks.len);
    try expectContainsString(frameworks, "Metal");
    try expectContainsString(frameworks, "QuartzCore");
    try expectContainsString(frameworks, "AppKit");
    try expectContainsString(frameworks, "CoreText");
    try expectContainsString(frameworks, "CoreGraphics");
    try expectContainsString(frameworks, "Foundation");
    try expectContainsString(frameworks, "CoreFoundation");
    try expectContainsString(frameworks, "Carbon");

    try std.testing.expectEqual(@as(usize, 0), appFrameworksFor(PlatformFeatures.forOs(.windows)).len);
    try std.testing.expectEqual(@as(usize, 0), appFrameworksFor(PlatformFeatures.forOs(.linux)).len);
}

test "webview bridge source is selected only for the webview platform backend" {
    try std.testing.expectEqualStrings(
        "src/platform/webview2_bridge.c",
        webviewBridgeSourcePath(PlatformFeatures.forOs(.windows)).?,
    );
    try std.testing.expect(webviewBridgeSourcePath(PlatformFeatures.forOs(.linux)) == null);
    try std.testing.expect(webviewBridgeSourcePath(PlatformFeatures.forOs(.macos)) == null);
}

test "browser build option text does not expose concrete backend names" {
    const source = @embedFile("build.zig");
    const concrete_backend = "Web" ++ "View2";

    try std.testing.expect(std.mem.indexOf(u8, source, "Enable the " ++ concrete_backend ++ " browser panel") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "platform backend with " ++ concrete_backend ++ " support") == null);
}

test "remote transport build options do not expose concrete backend names" {
    const source = @embedFile("build.zig");
    const concrete_backend = "win" ++ "http";

    try std.testing.expect(std.mem.indexOf(u8, source, "supports_" ++ concrete_backend ++ "_remote_transport") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "platform_supports_" ++ concrete_backend ++ "_remote_transport") == null);
}

test "foreign target tests are compile-only by default" {
    try std.testing.expect(shouldSkipForeignTestRun(.linux, .windows, false));
    try std.testing.expect(shouldSkipForeignTestRun(.macos, .windows, false));
    try std.testing.expect(!shouldSkipForeignTestRun(.windows, .windows, false));
    try std.testing.expect(!shouldSkipForeignTestRun(.linux, .windows, true));
}

test "desktop executable emission defaults to implemented platform backends" {
    try std.testing.expect(defaultEmitDesktopExe(PlatformFeatures.forOs(.windows)));
    try std.testing.expect(!defaultEmitDesktopExe(PlatformFeatures.forOs(.linux)));
    try std.testing.expect(defaultEmitDesktopExe(PlatformFeatures.forOs(.macos)));
}

test "shared compile checks default to platforms without desktop backends" {
    try std.testing.expect(!defaultEmitSharedCompileChecks(PlatformFeatures.forOs(.windows)));
    try std.testing.expect(defaultEmitSharedCompileChecks(PlatformFeatures.forOs(.linux)));
    try std.testing.expect(!defaultEmitSharedCompileChecks(PlatformFeatures.forOs(.macos)));
}

test "macOS app target path accepts Apple Silicon and Intel Macs" {
    try std.testing.expect(supportsMacosAppTarget(.macos, .aarch64));
    try std.testing.expect(supportsMacosAppTarget(.macos, .x86_64));
    try std.testing.expect(!supportsMacosAppTarget(.macos, .riscv64));
    try std.testing.expect(!supportsMacosAppTarget(.windows, .x86_64));
    try std.testing.expect(!supportsMacosAppTarget(.linux, .x86_64));
}

test "macOS app bundle build contract is declared" {
    const source = @embedFile("build.zig");
    const stub_path = "src/" ++ "macos_app_stub.zig";
    const skeleton_text = "bundle " ++ "skeleton";

    try expectSourceContains(source, "b.step(\"macos-app\"");
    try expectSourceContains(source, "Build and install the native macOS .app bundle");
    try expectSourceContains(source, "src/main.zig");
    try expectSourceContains(source, "phantty-clean-macos-app");
    try std.testing.expect(std.mem.indexOf(u8, source, stub_path) == null);
    try std.testing.expect(std.mem.indexOf(u8, source, skeleton_text) == null);
    try std.testing.expectEqualStrings("Phantty.app/Contents/Info.plist", macosBundleInfoPlistPath());
    try std.testing.expectEqualStrings("Phantty.app/Contents/MacOS/Phantty", macosBundleExecutablePath());
    try std.testing.expectEqualStrings("Phantty.app/Contents/Resources/.keep", macosBundleResourcesKeepPath());
}

test "macOS distribution packaging contract is declared" {
    const source = @embedFile("build.zig");

    try expectSourceContains(source, "b.step(\"macos-dist\"");
    try expectSourceContains(source, "packaging/macos/package.sh");
    try std.testing.expectEqualStrings("packaging/macos/package.sh", macosPackageScriptPath());
    try std.testing.expectEqualStrings("packaging/macos/Phantty.entitlements", macosEntitlementsPath());
}

test "macOS window backend smoke test step is declared" {
    const source = @embedFile("build.zig");

    try expectSourceContains(source, "b.step(\"test-macos-window\"");
    try expectSourceContains(source, "src/test_macos_window.zig");
    try expectSourceContains(source, "src/platform/window_macos_bridge.m");
}

test "macOS CoreText font backend smoke test step is declared" {
    const source = @embedFile("build.zig");

    try expectSourceContains(source, "b.step(\"test-macos-font\"");
    try expectSourceContains(source, "src/test_macos_font.zig");
    try expectSourceContains(source, "src/platform/font_macos_bridge.m");
}

test "macOS platform services smoke test step is declared" {
    const source = @embedFile("build.zig");

    try expectSourceContains(source, "b.step(\"test-macos-services\"");
    try expectSourceContains(source, "src/test_macos_services.zig");
    try expectSourceContains(source, "src/platform/services_macos_bridge.m");
}

test "macOS Info.plist renders app bundle metadata and package type" {
    const metadata = macosBundleMetadata();
    try std.testing.expectEqualStrings("Phantty.app", metadata.bundle_dir);
    try std.testing.expectEqualStrings("Phantty", metadata.executable_name);
    try std.testing.expectEqualStrings("com.phantty.terminal", metadata.bundle_identifier);

    const plist = macosInfoPlist(std.testing.allocator, "1.2.3");
    defer std.testing.allocator.free(plist);

    try expectSourceContains(plist, "CFBundlePackageType");
    try expectSourceContains(plist, "<string>APPL</string>");
    try expectSourceContains(plist, "<key>CFBundleExecutable</key>");
    try expectSourceContains(plist, "<string>Phantty</string>");
    try expectSourceContains(plist, "<key>CFBundleIdentifier</key>");
    try expectSourceContains(plist, "<string>com.phantty.terminal</string>");
    try expectSourceContains(plist, "<key>CFBundleShortVersionString</key>");
    try expectSourceContains(plist, "<string>1.2.3</string>");
}

test "macOS app bundle links required native frameworks" {
    const frameworks = appFrameworksFor(PlatformFeatures.forOs(.macos));

    try expectContainsString(frameworks, "Metal");
    try expectContainsString(frameworks, "QuartzCore");
    try expectContainsString(frameworks, "AppKit");
    try expectContainsString(frameworks, "CoreText");
    try expectContainsString(frameworks, "CoreGraphics");
    try expectContainsString(frameworks, "Foundation");
    try expectContainsString(frameworks, "CoreFoundation");
    try expectContainsString(frameworks, "Carbon");
}

fn expectSourceContains(source: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, source, needle) == null) {
        std.debug.print("expected build.zig to contain: {s}\n", .{needle});
        return error.MissingBuildContractText;
    }
}

fn expectContainsString(haystack: []const []const u8, needle: []const u8) !void {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return;
    }
    std.debug.print("expected list to contain: {s}\n", .{needle});
    return error.MissingBuildContractText;
}

pub fn build(b: *std.Build) void {
    // Windows remains the default development target while non-Windows ports
    // are introduced behind explicit platform feature gates.
    const target = b.standardTargetOptions(.{
        .default_target = defaultDevelopmentTarget(),
    });
    const platform = PlatformFeatures.forOs(target.result.os.tag);
    const optimize = b.standardOptimizeOption(.{});
    const webview = b.option(bool, "webview", "Enable the embedded browser panel") orelse platform.supports_embedded_browser;
    if (webview and !platform.supports_embedded_browser) {
        @panic("-Dwebview requires a platform backend with embedded browser support");
    }
    const run_foreign_tests = b.option(
        bool,
        "run-foreign-tests",
        "Attempt to run target test binaries even when the target OS differs from the host.",
    ) orelse b.enable_wine;
    const emit_desktop_exe = b.option(
        bool,
        "emit-desktop-exe",
        "Build and install desktop executables for targets with implemented platform host backends.",
    ) orelse defaultEmitDesktopExe(platform);
    if (emit_desktop_exe and !platform.supports_desktop_exe) {
        @panic("-Demit-desktop-exe requires an implemented platform host backend");
    }
    const emit_shared_compile_checks = b.option(
        bool,
        "emit-shared-compile-checks",
        "Compile shared modules without running them on targets that do not have desktop host backends yet.",
    ) orelse defaultEmitSharedCompileChecks(platform);
    const app_version = packageVersion(b);

    if (emit_desktop_exe) {
        const exe_mod = createAppModule(b, target, optimize, app_version, platform, webview);

        const exe = b.addExecutable(.{
            .name = "phantty",
            .root_module = exe_mod,
        });
        if (platform.supports_app_bundle) {
            apple_sdk.addPaths(b, exe) catch @panic("failed to locate native Apple SDK for macOS app executable");
        }

        if (platform.supports_gui_subsystem) {
            // Debug builds use Console subsystem so std.debug.print output is visible.
            // Release builds use Windows GUI subsystem to avoid a background console window.
            exe.subsystem = if (optimize == .Debug) .Console else .Windows;
        }

        b.installArtifact(exe);
    }

    b.installDirectory(.{
        .source_dir = b.path("plugins"),
        .install_dir = .bin,
        .install_subdir = "plugins",
    });

    const test_step = b.step("test", "Run fast native logic unit tests");
    const test_full_step = b.step("test-full", "Run the complete suite (shared compile checks + app test binary)");
    const test_shared_step = b.step("test-shared", "Compile shared modules for the selected target");
    const test_metal_step = b.step("test-metal", "Run native macOS Metal backend interface tests");
    const test_macos_window_step = b.step("test-macos-window", "Run native macOS AppKit window backend smoke tests");
    const test_macos_font_step = b.step("test-macos-font", "Run native macOS CoreText font backend smoke tests");
    const test_macos_services_step = b.step("test-macos-services", "Run native macOS platform service smoke tests");
    const macos_app_step = b.step("macos-app", "Build and install the native macOS .app bundle");
    const macos_dist_step = b.step("macos-dist", "Build, sign, and package the native macOS .app into a DMG");

    if (platform.supports_app_bundle) {
        if (!supportsMacosAppTarget(target.result.os.tag, target.result.cpu.arch)) {
            macos_app_step.dependOn(&b.addFail("macos-app supports only aarch64-macos and x86_64-macos targets").step);
            macos_dist_step.dependOn(&b.addFail("macos-dist supports only aarch64-macos and x86_64-macos targets").step);
        } else {
            const macos_app_install = addMacosAppBundle(b, target, optimize, app_version, platform);
            macos_app_step.dependOn(&macos_app_install.step);
            const macos_package = b.addSystemCommand(&.{ "bash", macosPackageScriptPath() });
            macos_package.step.dependOn(&macos_app_install.step);
            macos_dist_step.dependOn(&macos_package.step);
        }
    } else {
        macos_app_step.dependOn(&b.addFail("macos-app requires -Dtarget=aarch64-macos or -Dtarget=x86_64-macos").step);
        macos_dist_step.dependOn(&b.addFail("macos-dist requires -Dtarget=aarch64-macos or -Dtarget=x86_64-macos").step);
    }

    // Fast inner loop: build and RUN platform-independent logic tests against
    // the native host, independent of the heavy app/ghostty/xev binary.
    const fast_test_mod = b.createModule(.{
        .root_source_file = b.path("src/test_fast.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = optimize,
    });
    const fast_test_options = b.addOptions();
    fast_test_options.addOption([]const u8, "app_version", app_version);
    fast_test_mod.addOptions("build_options", fast_test_options);
    const fast_tests = b.addTest(.{
        .name = "phantty-fast-test",
        .root_module = fast_test_mod,
    });
    test_step.dependOn(&b.addRunArtifact(fast_tests).step);

    const shared_test_mod = b.createModule(.{
        .root_source_file = b.path("src/shared_compile_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const shared_test_options = b.addOptions();
    shared_test_options.addOption([]const u8, "app_version", app_version);
    shared_test_mod.addOptions("build_options", shared_test_options);

    const shared_tests = b.addTest(.{
        .name = "phantty-shared-compile-test",
        .root_module = shared_test_mod,
    });
    test_shared_step.dependOn(&shared_tests.step);
    if (emit_shared_compile_checks) {
        test_full_step.dependOn(&shared_tests.step);
    }

    if (b.graph.host.result.os.tag == .macos) {
        const metal_test_mod = b.createModule(.{
            .root_source_file = b.path("src/renderer/gpu/metal/test.zig"),
            .target = b.resolveTargetQuery(.{}),
            .optimize = optimize,
            .link_libc = true,
        });
        metal_test_mod.addCSourceFile(.{
            .file = b.path("src/renderer/gpu/metal/bridge.m"),
            .flags = &.{},
            .language = .objective_c,
        });
        metal_test_mod.linkFramework("Foundation", .{});
        metal_test_mod.linkFramework("Metal", .{});
        metal_test_mod.linkFramework("QuartzCore", .{});
        metal_test_mod.linkSystemLibrary("objc", .{});
        const metal_tests = b.addTest(.{
            .name = "phantty-metal-test",
            .root_module = metal_test_mod,
        });
        apple_sdk.addPaths(b, metal_tests) catch @panic("failed to locate native Apple SDK for Metal tests");
        test_metal_step.dependOn(&b.addRunArtifact(metal_tests).step);

        const macos_window_test_mod = b.createModule(.{
            .root_source_file = b.path("src/test_macos_window.zig"),
            .target = b.resolveTargetQuery(.{}),
            .optimize = optimize,
            .link_libc = true,
        });
        macos_window_test_mod.addCSourceFile(.{
            .file = b.path("src/platform/window_macos_bridge.m"),
            .flags = &.{},
            .language = .objective_c,
        });
        macos_window_test_mod.linkFramework("AppKit", .{});
        macos_window_test_mod.linkFramework("Foundation", .{});
        macos_window_test_mod.linkFramework("Metal", .{});
        macos_window_test_mod.linkFramework("QuartzCore", .{});
        macos_window_test_mod.linkSystemLibrary("objc", .{});
        const macos_window_tests = b.addTest(.{
            .name = "phantty-macos-window-test",
            .root_module = macos_window_test_mod,
        });
        apple_sdk.addPaths(b, macos_window_tests) catch @panic("failed to locate native Apple SDK for macOS window tests");
        test_macos_window_step.dependOn(&b.addRunArtifact(macos_window_tests).step);

        const macos_font_test_mod = b.createModule(.{
            .root_source_file = b.path("src/test_macos_font.zig"),
            .target = b.resolveTargetQuery(.{}),
            .optimize = optimize,
            .link_libc = true,
        });
        macos_font_test_mod.addCSourceFile(.{
            .file = b.path("src/platform/font_macos_bridge.m"),
            .flags = &.{},
            .language = .objective_c,
        });
        macos_font_test_mod.linkFramework("CoreFoundation", .{});
        macos_font_test_mod.linkFramework("CoreGraphics", .{});
        macos_font_test_mod.linkFramework("CoreText", .{});
        macos_font_test_mod.linkFramework("Foundation", .{});
        const macos_font_tests = b.addTest(.{
            .name = "phantty-macos-font-test",
            .root_module = macos_font_test_mod,
        });
        apple_sdk.addPaths(b, macos_font_tests) catch @panic("failed to locate native Apple SDK for macOS font tests");
        test_macos_font_step.dependOn(&b.addRunArtifact(macos_font_tests).step);

        const macos_services_test_mod = b.createModule(.{
            .root_source_file = b.path("src/test_macos_services.zig"),
            .target = b.resolveTargetQuery(.{}),
            .optimize = optimize,
            .link_libc = true,
        });
        macos_services_test_mod.addCSourceFile(.{
            .file = b.path("src/platform/services_macos_bridge.m"),
            .flags = &.{},
            .language = .objective_c,
        });
        macos_services_test_mod.linkFramework("AppKit", .{});
        macos_services_test_mod.linkFramework("Carbon", .{});
        macos_services_test_mod.linkFramework("CoreFoundation", .{});
        macos_services_test_mod.linkFramework("Foundation", .{});
        macos_services_test_mod.linkSystemLibrary("objc", .{});
        const macos_services_tests = b.addTest(.{
            .name = "phantty-macos-services-test",
            .root_module = macos_services_test_mod,
        });
        apple_sdk.addPaths(b, macos_services_tests) catch @panic("failed to locate native Apple SDK for macOS service tests");
        test_macos_services_step.dependOn(&b.addRunArtifact(macos_services_tests).step);
    } else {
        test_metal_step.dependOn(&b.addFail("test-metal requires a macOS host with Metal").step);
        test_macos_window_step.dependOn(&b.addFail("test-macos-window requires a macOS host with AppKit").step);
        test_macos_font_step.dependOn(&b.addFail("test-macos-font requires a macOS host with CoreText").step);
        test_macos_services_step.dependOn(&b.addFail("test-macos-services requires a macOS host with AppKit").step);
    }

    if (platform.supports_desktop_exe) {
        const test_mod = createAppModuleWithRoot(
            b,
            "src/test_main.zig",
            target,
            optimize,
            app_version,
            platform,
            webview,
        );

        const tests = b.addTest(.{
            .root_module = test_mod,
        });
        if (platform.supports_app_bundle) {
            apple_sdk.addPaths(b, tests) catch @panic("failed to locate native Apple SDK for app tests");
        }

        const run_tests = b.addRunArtifact(tests);
        run_tests.skip_foreign_checks = shouldSkipForeignTestRun(
            b.graph.host.result.os.tag,
            target.result.os.tag,
            run_foreign_tests,
        );
        test_full_step.dependOn(&run_tests.step);
    }
}

fn createAppModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    app_version: []const u8,
    platform: PlatformFeatures,
    webview: bool,
) *std.Build.Module {
    return createAppModuleWithRoot(b, "src/main.zig", target, optimize, app_version, platform, webview);
}

fn createAppModuleWithRoot(
    b: *std.Build,
    root_source_path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    app_version: []const u8,
    platform: PlatformFeatures,
    webview: bool,
) *std.Build.Module {
    const app_mod = b.createModule(.{
        .root_source_file = b.path(root_source_path),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const app_options = b.addOptions();
    app_options.addOption(bool, "webview", webview);
    app_options.addOption([]const u8, "app_version", app_version);
    app_mod.addOptions("build_options", app_options);

    // Add ghostty-vt dependency with SIMD disabled for cross-compilation.
    if (b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .simd = false,
    })) |dep| {
        app_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
        app_mod.addIncludePath(dep.path("src/stb"));
        app_mod.addCSourceFile(.{
            .file = dep.path("src/stb/stb.c"),
            .flags = &.{},
        });
    }

    if (b.lazyDependency("libxev", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        app_mod.addImport("xev", dep.module("xev"));
    }

    for (systemLibrariesFor(platform)) |library| {
        app_mod.linkSystemLibrary(library, .{});
    }
    for (appFrameworksFor(platform)) |framework| {
        app_mod.linkFramework(framework, .{});
    }

    const freetype_dep = b.lazyDependency("freetype", .{
        .target = target,
        .optimize = optimize,
    });
    if (freetype_dep) |dep| {
        app_mod.addImport("freetype", dep.module("freetype"));
        app_mod.linkLibrary(dep.artifact("freetype"));
    }

    if (b.lazyDependency("z2d", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        app_mod.addImport("z2d", dep.module("z2d"));
    }

    if (b.lazyDependency("harfbuzz", .{})) |hb_dep| {
        if (freetype_dep) |ft_dep| {
            const hb_lib = buildHarfbuzzLib(b, target, optimize, hb_dep, ft_dep);
            const hb_mod = b.addModule("harfbuzz", .{
                .root_source_file = b.path("pkg/harfbuzz/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "freetype", .module = ft_dep.module("freetype") },
                },
            });

            const options = b.addOptions();
            options.addOption(bool, "coretext", false);
            options.addOption(bool, "freetype", true);
            hb_mod.addOptions("build_options", options);

            if (hb_dep.builder.lazyDependency("harfbuzz", .{})) |upstream| {
                hb_mod.addIncludePath(upstream.path("src"));
            }
            hb_mod.addIncludePath(b.path("pkg/freetype"));
            if (ft_dep.builder.lazyDependency("freetype", .{})) |ft_upstream| {
                hb_mod.addIncludePath(ft_upstream.path("include"));
            }

            app_mod.addImport("harfbuzz", hb_mod);
            app_mod.linkLibrary(hb_lib);
        }
    }

    if (platform.opengl_system_library) |library| {
        app_mod.addIncludePath(b.path("vendor/glad/include"));
        app_mod.addCSourceFile(.{
            .file = b.path("vendor/glad/src/gl.c"),
            .flags = &.{},
        });
        app_mod.linkSystemLibrary(library, .{});
    }

    if (platform.supports_app_bundle) {
        for (macos_objective_c_sources) |source| {
            app_mod.addCSourceFile(.{
                .file = b.path(source),
                .flags = &.{},
                .language = .objective_c,
            });
        }
    }

    if (webview) {
        app_mod.addCSourceFile(.{
            .file = b.path(webviewBridgeSourcePath(platform).?),
            .flags = &.{},
        });
    }

    if (platform.supports_resource_manifest) {
        app_mod.addWin32ResourceFile(.{
            .file = b.path("assets/phantty.rc"),
            .include_paths = &.{b.path("assets")},
        });
    }

    if (platform.supports_app_bundle) {
        app_mod.linkSystemLibrary("objc", .{});
    }
    return app_mod;
}

fn addMacosAppBundle(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    app_version: []const u8,
    platform: PlatformFeatures,
) *std.Build.Step.InstallDir {
    const metadata = macosBundleMetadata();
    const macos_mod = createAppModule(b, target, optimize, app_version, platform, false);

    const exe = b.addExecutable(.{
        .name = metadata.executable_name,
        .root_module = macos_mod,
    });
    apple_sdk.addPaths(b, exe) catch @panic("failed to locate native Apple SDK for macOS app executable");

    const bundle = b.addWriteFiles();
    _ = bundle.add(macosBundleInfoPlistPath(), macosInfoPlist(b.allocator, app_version));
    _ = bundle.add("Phantty.app/Contents/PkgInfo", "APPL????");
    _ = bundle.add(macosBundleResourcesKeepPath(), "");
    _ = bundle.addCopyFile(exe.getEmittedBin(), macosBundleExecutablePath());

    const install_bundle = b.addInstallDirectory(.{
        .source_dir = bundle.getDirectory(),
        .install_dir = .bin,
        .install_subdir = "",
    });
    const clean_existing_bundle = b.addSystemCommand(&.{
        "bash",
        "-c",
        "rm -rf \"$1\"",
        "phantty-clean-macos-app",
        b.getInstallPath(.bin, metadata.bundle_dir),
    });
    install_bundle.step.dependOn(&clean_existing_bundle.step);
    return install_bundle;
}

fn packageVersion(b: *std.Build) []const u8 {
    const Manifest = struct {
        version: []const u8,
    };

    const source = b.build_root.handle.readFileAllocOptions(
        b.allocator,
        "build.zig.zon",
        64 * 1024,
        null,
        .of(u8),
        0,
    ) catch @panic("failed to read build.zig.zon");

    const manifest = std.zon.parse.fromSlice(
        Manifest,
        b.allocator,
        source,
        null,
        .{ .ignore_unknown_fields = true },
    ) catch @panic("failed to parse package version from build.zig.zon");

    return manifest.version;
}

/// Build HarfBuzz as a static C library, linking against our shared FreeType.
fn buildHarfbuzzLib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    hb_dep: *std.Build.Dependency,
    ft_dep: *std.Build.Dependency,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "harfbuzz",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });
    lib.linkLibC();
    lib.linkLibCpp();

    var flags: std.ArrayList([]const u8) = .empty;
    defer flags.deinit(b.allocator);
    flags.appendSlice(b.allocator, &.{
        "-DHAVE_STDBOOL_H",
        "-DHAVE_FREETYPE=1",
        "-DHAVE_FT_GET_VAR_BLEND_COORDINATES=1",
        "-DHAVE_FT_SET_VAR_BLEND_COORDINATES=1",
        "-DHAVE_FT_DONE_MM_VAR=1",
        "-DHAVE_FT_GET_TRANSFORM=1",
    }) catch @panic("OOM");

    if (target.result.os.tag != .windows) {
        flags.appendSlice(b.allocator, &.{
            "-DHAVE_UNISTD_H",
            "-DHAVE_SYS_MMAN_H",
            "-DHAVE_PTHREAD=1",
        }) catch @panic("OOM");
    }

    // Link our shared FreeType
    lib.linkLibrary(ft_dep.artifact("freetype"));

    // Compile HarfBuzz C++ source
    if (hb_dep.builder.lazyDependency("harfbuzz", .{})) |upstream| {
        lib.addIncludePath(upstream.path("src"));
        lib.addCSourceFile(.{
            .file = upstream.path("src/harfbuzz.cc"),
            .flags = flags.items,
        });
    }

    return lib;
}
