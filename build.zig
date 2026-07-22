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

const linux_system_libraries = [_][]const u8{ "SDL3", "fontconfig" };

fn fastTestsNeedLibc(os_tag: std.Target.Os.Tag) bool {
    return switch (os_tag) {
        .linux, .macos => true,
        else => false,
    };
}

const windows_system_libraries = [_][]const u8{
    "user32",
    "advapi32", // registry access for WSL availability detection
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
    "WebKit",
    "Metal",
    "QuartzCore",
    "AppKit",
    "CoreText",
    "CoreGraphics",
    "Foundation",
    "UserNotifications",
    "CoreFoundation",
    "Carbon",
    "ImageIO", // PDF preview page rasters are PNG-encoded with ImageIO
};

const macos_objective_c_sources = [_][]const u8{
    "src/renderer/gpu/metal/bridge.m",
    "src/platform/window_macos_bridge.m",
    "src/platform/font_macos_bridge.m",
    "src/platform/services_macos_bridge.m",
    "src/platform/text_macos_bridge.m",
    "src/platform/menu_macos_bridge.m",
    "src/platform/http_client_macos_bridge.m",
    "src/platform/pdf_render_macos_bridge.m",
    "src/platform/remote_transport_macos_bridge.m",
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
    webkit,

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
        const uses_linux_backend = os_tag == .linux;
        const has_desktop_backend = uses_windows_backend or uses_macos_backend or uses_linux_backend;
        const has_app_bundle = os_tag == .macos;
        const embedded_browser_backend: EmbeddedBrowserBackend = if (uses_windows_backend)
            .webview2
        else if (uses_macos_backend)
            .webkit
        else
            .none; // linux: webview disabled (SP5)
        return .{
            .supports_desktop_exe = has_desktop_backend,
            .supports_embedded_browser = embedded_browser_backend.isSupported(),
            .embedded_browser_backend = embedded_browser_backend,
            .supports_resource_manifest = uses_windows_backend,
            .supports_gui_subsystem = uses_windows_backend,
            .supports_remote_transport = uses_windows_backend or uses_macos_backend,
            .supports_app_bundle = has_app_bundle,
            .system_libraries = if (uses_windows_backend) &windows_system_libraries else if (uses_linux_backend) &linux_system_libraries else &.{},
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

/// Resolve a pkg-config variable (e.g. "libdir", "includedir") for a system
/// library at configure time, so build paths are not hardcoded per distro.
/// Returns null when pkg-config or the variable is unavailable.
fn pkgConfigVariable(b: *std.Build, lib: []const u8, variable: []const u8) ?[]const u8 {
    const result = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{ "pkg-config", b.fmt("--variable={s}", .{variable}), lib },
    }) catch return null;
    if (result.term != .Exited or result.term.Exited != 0) return null;
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    return if (trimmed.len == 0) null else b.dupe(trimmed);
}

fn macosBundleMetadata() MacosBundleMetadata {
    return .{
        .bundle_dir = "WispTerm.app",
        .executable_name = "WispTerm",
        .display_name = "WispTerm",
        .bundle_identifier = "com.wispterm.terminal",
        .minimum_system_version = "13.0",
    };
}

fn macosBundleInfoPlistPath() []const u8 {
    return "WispTerm.app/Contents/Info.plist";
}

fn macosBundleExecutablePath() []const u8 {
    return "WispTerm.app/Contents/MacOS/WispTerm";
}

fn macosBundleResourcesKeepPath() []const u8 {
    return "WispTerm.app/Contents/Resources/.keep";
}

fn macosBundleIconSourcePath() []const u8 {
    return "assets/wispterm.icns";
}

fn macosBundleIconBundlePath() []const u8 {
    return "WispTerm.app/Contents/Resources/WispTerm.icns";
}

fn macosBundlePluginsSourcePath() []const u8 {
    return "plugins";
}

fn macosBundlePluginsBundlePath() []const u8 {
    return "WispTerm.app/Contents/Resources/plugins";
}

fn macosBundleIconNameInPlist() []const u8 {
    // CFBundleIconFile is stored without the .icns extension.
    return "WispTerm";
}

fn macosPackageScriptPath() []const u8 {
    return "packaging/macos/package.sh";
}

fn macosEntitlementsPath() []const u8 {
    return "packaging/macos/WispTerm.entitlements";
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
        \\    <key>CFBundleIconFile</key>
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
        \\    <key>NSAppTransportSecurity</key>
        \\    <dict>
        \\        <key>NSAllowsLocalNetworking</key>
        \\        <true/>
        \\    </dict>
        \\</dict>
        \\</plist>
        \\
    , .{
        metadata.display_name,
        metadata.executable_name,
        macosBundleIconNameInPlist(),
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
        .webkit => "src/platform/webview_macos_bridge.m",
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

fn resolveGpuBackendBuildOption(raw: ?[]const u8, os_tag: std.Target.Os.Tag) []const u8 {
    const value = raw orelse "auto";
    if (std.mem.eql(u8, value, "auto") or
        std.mem.eql(u8, value, "opengl") or
        std.mem.eql(u8, value, "metal"))
    {
        return value;
    }
    if (std.mem.eql(u8, value, "d3d11")) {
        if (os_tag != .windows) @panic("-Dgpu-backend=d3d11 requires a Windows target");
        return value;
    }
    @panic("-Dgpu-backend must be one of: auto, opengl, metal, d3d11");
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
    try std.testing.expect(linux.supports_desktop_exe);
    try std.testing.expect(!linux.supports_embedded_browser);
    try std.testing.expectEqual(EmbeddedBrowserBackend.none, linux.embedded_browser_backend);
    try std.testing.expect(!linux.supports_resource_manifest);
    try std.testing.expect(!linux.supports_gui_subsystem);
    try std.testing.expect(!linux.supports_remote_transport);
    try std.testing.expect(!linux.supports_app_bundle);
    try std.testing.expect(linux.opengl_system_library == null);

    const macos = PlatformFeatures.forOs(.macos);
    try std.testing.expect(macos.supports_desktop_exe);
    try std.testing.expect(macos.supports_embedded_browser);
    try std.testing.expectEqual(EmbeddedBrowserBackend.webkit, macos.embedded_browser_backend);
    try std.testing.expect(!macos.supports_resource_manifest);
    try std.testing.expect(!macos.supports_gui_subsystem);
    try std.testing.expect(macos.supports_remote_transport);
    try std.testing.expect(macos.supports_app_bundle);
    try std.testing.expect(macos.opengl_system_library == null);
}

test "windows system libraries are gated by platform" {
    const windows = PlatformFeatures.forOs(.windows);
    try std.testing.expectEqual(@as(usize, windows_system_libraries.len), systemLibrariesFor(windows).len);
    try std.testing.expectEqualStrings("user32", systemLibrariesFor(windows)[0]);
    try expectContainsString(systemLibrariesFor(windows), "winhttp");
    try expectContainsString(systemLibrariesFor(windows), "ole32");
    try expectContainsString(systemLibrariesFor(windows), "psapi");
    try expectContainsString(systemLibrariesFor(windows), "shcore");

    const linux = PlatformFeatures.forOs(.linux);
    try std.testing.expectEqual(@as(usize, 2), systemLibrariesFor(linux).len);
    try std.testing.expectEqualStrings("SDL3", systemLibrariesFor(linux)[0]);
    try std.testing.expectEqualStrings("fontconfig", systemLibrariesFor(linux)[1]);

    const macos = PlatformFeatures.forOs(.macos);
    try std.testing.expectEqual(@as(usize, 0), systemLibrariesFor(macos).len);
}

test "fast tests link libc on hosts whose platform adapters import C headers" {
    try std.testing.expect(fastTestsNeedLibc(.linux));
    try std.testing.expect(fastTestsNeedLibc(.macos));
    try std.testing.expect(!fastTestsNeedLibc(.windows));
}

test "macOS platform advertises required app frameworks" {
    const frameworks = appFrameworksFor(PlatformFeatures.forOs(.macos));
    try std.testing.expectEqual(@as(usize, 11), frameworks.len);
    try expectContainsString(frameworks, "WebKit");
    try expectContainsString(frameworks, "Metal");
    try expectContainsString(frameworks, "QuartzCore");
    try expectContainsString(frameworks, "AppKit");
    try expectContainsString(frameworks, "CoreText");
    try expectContainsString(frameworks, "CoreGraphics");
    try expectContainsString(frameworks, "Foundation");
    try expectContainsString(frameworks, "CoreFoundation");
    try expectContainsString(frameworks, "Carbon");
    try expectContainsString(frameworks, "UserNotifications");
    try expectContainsString(frameworks, "ImageIO");

    try std.testing.expectEqual(@as(usize, 0), appFrameworksFor(PlatformFeatures.forOs(.windows)).len);
    try std.testing.expectEqual(@as(usize, 0), appFrameworksFor(PlatformFeatures.forOs(.linux)).len);
}

test "webview bridge source is selected only for the webview platform backend" {
    try std.testing.expectEqualStrings(
        "src/platform/webview2_bridge.c",
        webviewBridgeSourcePath(PlatformFeatures.forOs(.windows)).?,
    );
    try std.testing.expect(webviewBridgeSourcePath(PlatformFeatures.forOs(.linux)) == null);
    try std.testing.expectEqualStrings(
        "src/platform/webview_macos_bridge.m",
        webviewBridgeSourcePath(PlatformFeatures.forOs(.macos)).?,
    );
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
    try std.testing.expect(defaultEmitDesktopExe(PlatformFeatures.forOs(.linux)));
    try std.testing.expect(defaultEmitDesktopExe(PlatformFeatures.forOs(.macos)));
}

test "standalone filetool build contract is declared" {
    const source = @embedFile("build.zig");
    try expectSourceContains(source, ".name = \"wispterm-filetool\"");
    try expectSourceContains(source, "src/wispterm_filetool.zig");
    try expectSourceContains(source, "b.step(\"wispterm-filetool\"");
}

test "standalone benchmark CLI build contract is declared" {
    const source = @embedFile("build.zig");
    try expectSourceContains(source, ".name = \"wispterm-bench\"");
    try expectSourceContains(source, "src/wispterm_bench.zig");
    try expectSourceContains(source, "b.step(\"bench\"");
    try expectSourceContains(source, "-Demit-bench");
}

test "shared compile checks default to platforms without desktop backends" {
    try std.testing.expect(!defaultEmitSharedCompileChecks(PlatformFeatures.forOs(.windows)));
    try std.testing.expect(!defaultEmitSharedCompileChecks(PlatformFeatures.forOs(.linux)));
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
    try expectSourceContains(source, "wispterm-clean-macos-app");
    try std.testing.expect(std.mem.indexOf(u8, source, stub_path) == null);
    try std.testing.expect(std.mem.indexOf(u8, source, skeleton_text) == null);
    try std.testing.expectEqualStrings("WispTerm.app/Contents/Info.plist", macosBundleInfoPlistPath());
    try std.testing.expectEqualStrings("WispTerm.app/Contents/MacOS/WispTerm", macosBundleExecutablePath());
    try std.testing.expectEqualStrings("WispTerm.app/Contents/Resources/.keep", macosBundleResourcesKeepPath());
}

test "macOS distribution packaging contract is declared" {
    const source = @embedFile("build.zig");

    try expectSourceContains(source, "b.step(\"macos-dist\"");
    try expectSourceContains(source, "packaging/macos/package.sh");
    try std.testing.expectEqualStrings("packaging/macos/package.sh", macosPackageScriptPath());
    try std.testing.expectEqualStrings("packaging/macos/WispTerm.entitlements", macosEntitlementsPath());
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

test "macOS UI smoke test step is declared" {
    const source = @embedFile("build.zig");

    try expectSourceContains(source, "b.step(\"test-macos-ui\"");
    try expectSourceContains(source, "src/test_macos_ui.zig");
}

test "macOS NSMenu smoke test step is declared" {
    const source = @embedFile("build.zig");

    try expectSourceContains(source, "b.step(\"test-macos-menu\"");
    try expectSourceContains(source, "src/test_macos_menu.zig");
    try expectSourceContains(source, "src/platform/menu_macos_bridge.m");
}

test "macOS Info.plist renders app bundle metadata and package type" {
    const metadata = macosBundleMetadata();
    try std.testing.expectEqualStrings("WispTerm.app", metadata.bundle_dir);
    try std.testing.expectEqualStrings("WispTerm", metadata.executable_name);
    try std.testing.expectEqualStrings("com.wispterm.terminal", metadata.bundle_identifier);

    const plist = macosInfoPlist(std.testing.allocator, "1.2.3");
    defer std.testing.allocator.free(plist);

    try expectSourceContains(plist, "CFBundlePackageType");
    try expectSourceContains(plist, "<string>APPL</string>");
    try expectSourceContains(plist, "<key>CFBundleExecutable</key>");
    try expectSourceContains(plist, "<string>WispTerm</string>");
    try expectSourceContains(plist, "<key>CFBundleIdentifier</key>");
    try expectSourceContains(plist, "<string>com.wispterm.terminal</string>");
    try expectSourceContains(plist, "<key>CFBundleShortVersionString</key>");
    try expectSourceContains(plist, "<string>1.2.3</string>");
    try expectSourceContains(plist, "<key>CFBundleIconFile</key>");
    try expectSourceContains(plist, "<string>WispTerm</string>");
    try expectSourceContains(plist, "NSAppTransportSecurity");
    try expectSourceContains(plist, "NSAllowsLocalNetworking");
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
    const debug_console = b.option(
        bool,
        "debug-console",
        "Force a console subsystem and enable on-disk debug logging + crash capture (diagnostic builds).",
    ) orelse false;
    const gpu_backend = resolveGpuBackendBuildOption(
        b.option([]const u8, "gpu-backend", "Select the renderer GPU backend: auto, opengl, metal, or d3d11."),
        target.result.os.tag,
    );
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
    // Standalone CPU-side benchmark CLI (Ghostty-aligned `wispterm-bench`). Off
    // by default: it links ghostty-vt and is meant for branch-to-branch
    // performance comparisons, not for app packaging or the pre-merge gate.
    const emit_bench = b.option(
        bool,
        "emit-bench",
        "Build the standalone wispterm-bench CPU benchmark CLI (links ghostty-vt).",
    ) orelse false;
    const app_version = packageVersion(b);

    if (emit_desktop_exe) {
        const exe_mod = createAppModule(b, target, optimize, app_version, platform, webview, debug_console, gpu_backend);

        const exe = b.addExecutable(.{
            .name = "wispterm",
            .root_module = exe_mod,
        });
        if (target.result.os.tag == .linux) {
            // libSDL3.so / libfontconfig reference glibc symbols (pthread_*,
            // dlsym, stat) at versions above Zig's default glibc stubs for
            // x86_64-linux-gnu; they are resolved at runtime by the system
            // glibc. Let the linker leave those system-shared-library undefined
            // symbols unresolved — ReleaseFast enforces
            // --no-allow-shlib-undefined (Debug does not), so a release build
            // would otherwise fail to link.
            exe.linker_allow_shlib_undefined = true;
        }
        if (platform.supports_app_bundle) {
            apple_sdk.addPaths(b, exe) catch @panic("failed to locate native Apple SDK for macOS app executable");
        }

        if (platform.supports_gui_subsystem) {
            // Debug builds and diagnostic (-Ddebug-console) builds use the Console
            // subsystem so std.debug.print / std.log are visible; normal release
            // uses the Windows GUI subsystem to avoid a background console window.
            exe.subsystem = if (optimize == .Debug or debug_console) .Console else .Windows;
        }

        b.installArtifact(exe);

        if (target.result.os.tag == .windows) {
            const askpass_mod = b.createModule(.{
                .root_source_file = b.path("src/ssh/askpass.zig"),
                .target = target,
                .optimize = optimize,
            });
            const askpass_exe = b.addExecutable(.{
                .name = "wispterm-ssh-askpass",
                .root_module = askpass_mod,
            });
            askpass_exe.subsystem = .Windows;
            b.installArtifact(askpass_exe);
        }

        // Standalone CLI client for the agent terminal control API. Lean: it
        // imports only ctl/* + platform/dirs.zig (std/builtin), so it links
        // without any GUI/SDL dependencies on every desktop target.
        //
        // Deliberately NOT part of the default install / app packaging:
        // wisptermctl ships as a separate artifact for third-party agents
        // (Claude Code / Codex / scripts). The release workflows run a plain
        // `zig build` and copy named files, so the client never lands in the
        // app bundle. Build it on its own with `zig build wisptermctl`.
        const ctl_mod = b.createModule(.{
            .root_source_file = b.path("src/wisptermctl.zig"),
            .target = target,
            .optimize = optimize,
        });
        const ctl_exe = b.addExecutable(.{
            .name = "wisptermctl",
            .root_module = ctl_mod,
        });
        if (platform.supports_gui_subsystem) ctl_exe.subsystem = .Console; // it is a CLI
        const wisptermctl_step = b.step("wisptermctl", "Build the standalone wisptermctl CLI client (separate artifact; not bundled with the app)");
        wisptermctl_step.dependOn(&b.addInstallArtifact(ctl_exe, .{}).step);
    }

    const filetool_mod = b.createModule(.{
        .root_source_file = b.path("src/wispterm_filetool.zig"),
        .target = target,
        .optimize = optimize,
    });
    const filetool_exe = b.addExecutable(.{
        .name = "wispterm-filetool",
        .root_module = filetool_mod,
    });
    if (platform.supports_gui_subsystem) filetool_exe.subsystem = .Console;
    const filetool_step = b.step("wispterm-filetool", "Build the standalone remote-side file edit helper");
    filetool_step.dependOn(&b.addInstallArtifact(filetool_exe, .{}).step);

    // ponytail: root_source_file is a thin forwarder at the src/ module
    // boundary — memory_digest/scan_main.zig itself reaches into
    // ../platform and ../terminal_agents (via run.zig), so it can't be the
    // module root directly (Zig 0.15 forbids imports outside the root's
    // directory). See src/wispterm_memory_digest_main.zig.
    const memory_digest_mod = b.createModule(.{
        .root_source_file = b.path("src/wispterm_memory_digest_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const memory_digest_exe = b.addExecutable(.{
        .name = "wispterm-memory-digest",
        .root_module = memory_digest_mod,
    });
    if (platform.supports_gui_subsystem) memory_digest_exe.subsystem = .Console;
    const memory_digest_step = b.step("memory-digest", "Build the dev memory-digest scanner CLI (not bundled with the app)");
    memory_digest_step.dependOn(&b.addInstallArtifact(memory_digest_exe, .{}).step);

    // Standalone CPU benchmark CLI. Mirrors Ghostty's `zig build -Demit-bench`:
    // a separate artifact that links ghostty-vt for the TerminalStream case.
    // Built only on explicit request (`-Demit-bench` or `zig build bench`).
    const bench_step = b.step("bench", "Build the standalone wispterm-bench CPU benchmark CLI (separate artifact; not bundled with the app)");
    if (emit_bench) {
        const bench_mod = createBenchModule(b, target, optimize);
        const bench_exe = b.addExecutable(.{
            .name = "wispterm-bench",
            .root_module = bench_mod,
        });
        if (platform.supports_gui_subsystem) bench_exe.subsystem = .Console;
        const install_bench = b.addInstallArtifact(bench_exe, .{});
        bench_step.dependOn(&install_bench.step);
        // Include in the default install too, so `zig build -Demit-bench`
        // actually produces the binary (the named `bench` step alone is not
        // run by a bare `zig build`).
        b.getInstallStep().dependOn(&install_bench.step);
    } else {
        bench_step.dependOn(&b.addFail("bench requires -Demit-bench").step);
    }

    // `test-bench`: runs the bench modules' own tests (TerminalStream + cli),
    // which link ghostty-vt and so cannot live in the lean fast suite. Kept
    // separate from test-full so it does not slow the pre-merge gate; run it
    // explicitly when touching the benchmark code.
    const bench_test_mod = createBenchModule(b, target, optimize);
    const bench_tests = b.addTest(.{
        .name = "wispterm-bench-test",
        .root_module = bench_test_mod,
    });
    const test_bench_step = b.step("test-bench", "Run the wispterm-bench module tests (links ghostty-vt)");
    test_bench_step.dependOn(&b.addRunArtifact(bench_tests).step);

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
    const test_macos_ui_step = b.step("test-macos-ui", "Run native macOS UI smoke tests");
    const test_macos_menu_step = b.step("test-macos-menu", "Run native macOS NSMenu smoke tests");
    const macos_app_step = b.step("macos-app", "Build and install the native macOS .app bundle");
    const macos_dist_step = b.step("macos-dist", "Build, sign, and package the native macOS .app into a DMG");

    if (platform.supports_app_bundle) {
        if (!supportsMacosAppTarget(target.result.os.tag, target.result.cpu.arch)) {
            macos_app_step.dependOn(&b.addFail("macos-app supports only aarch64-macos and x86_64-macos targets").step);
            macos_dist_step.dependOn(&b.addFail("macos-dist supports only aarch64-macos and x86_64-macos targets").step);
        } else {
            const macos_app_install = addMacosAppBundle(b, target, optimize, app_version, platform, debug_console, gpu_backend);
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
    fast_test_options.addOption([]const u8, "release_notes", "");
    fast_test_options.addOption([]const u8, "gpu_backend", "auto");
    fast_test_mod.addOptions("build_options", fast_test_options);
    // Mirror the app's doc embeds: a fast-test module (ai_chat_protocol) pulls in
    // wispterm_docs, whose @embedFile names must resolve here too.
    fast_test_mod.addAnonymousImport("wispterm_doc_faq", .{ .root_source_file = b.path("docs/faq.md") });
    fast_test_mod.addAnonymousImport("wispterm_doc_configuration", .{ .root_source_file = b.path("docs/configuration.md") });
    fast_test_mod.addAnonymousImport("wispterm_doc_ai_agent", .{ .root_source_file = b.path("docs/ai-agent.md") });
    fast_test_mod.addAnonymousImport("wispterm_doc_file_explorer", .{ .root_source_file = b.path("docs/file-explorer.md") });
    fast_test_mod.addAnonymousImport("wispterm_doc_media", .{ .root_source_file = b.path("docs/media.md") });
    fast_test_mod.addAnonymousImport("wispterm_doc_tabs_panels", .{ .root_source_file = b.path("docs/tabs-panels.md") });
    const fast_tests = b.addTest(.{
        .name = "wispterm-fast-test",
        .root_module = fast_test_mod,
    });
    fast_test_mod.link_libc = fastTestsNeedLibc(b.graph.host.result.os.tag);
    switch (b.graph.host.result.os.tag) {
        .windows => fast_test_mod.linkSystemLibrary("winhttp", .{}),
        .macos => {
            fast_test_mod.addCSourceFile(.{
                .file = b.path("src/platform/http_client_macos_bridge.m"),
                .flags = &.{},
                .language = .objective_c,
            });
            // The fast suite's graph also reaches platform/text.zig →
            // text_macos.zig, whose caseInsensitiveCompare bridge lives in the
            // Foundation-only text_macos_bridge.m. Link it so the symbol
            // resolves on macOS hosts.
            fast_test_mod.addCSourceFile(.{
                .file = b.path("src/platform/text_macos_bridge.m"),
                .flags = &.{},
                .language = .objective_c,
            });
            fast_test_mod.linkFramework("Foundation", .{});
            fast_test_mod.linkFramework("CoreFoundation", .{});
            fast_test_mod.linkSystemLibrary("objc", .{});
            apple_sdk.addPaths(b, fast_tests) catch @panic("failed to locate native Apple SDK for fast tests");
        },
        else => {},
    }
    test_step.dependOn(&b.addRunArtifact(fast_tests).step);

    // The fast suite carries the architecture guards (src/source_guards/* plus
    // the existing input/overlay guards), so make the pre-merge gate a superset
    // of the fast loop instead of silently skipping them. Previously test-full
    // did not run the fast tests at all.
    test_full_step.dependOn(test_step);

    // Standalone file-size backstop: `zig build check-sizes`. The fast suite
    // also exercises it; this is the quick, dependency-free command. Runs from
    // the repo root so the test can walk src/.
    const check_sizes_mod = b.createModule(.{
        .root_source_file = b.path("src/source_guards/file_size_guard.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = optimize,
    });
    const check_sizes_tests = b.addTest(.{
        .name = "wispterm-check-sizes",
        .root_module = check_sizes_mod,
    });
    const run_check_sizes = b.addRunArtifact(check_sizes_tests);
    run_check_sizes.setCwd(b.path("."));
    const check_sizes_step = b.step("check-sizes", "Fail if any src/*.zig crosses the file-size backstop");
    check_sizes_step.dependOn(&run_check_sizes.step);

    // Posix-native libc-linked tests: file I/O, libc (localtime), fork, plus the
    // socketpair virtual-PTY and tmux pane I/O bridge tests. Runs on any
    // non-Windows host. Added to test-full so the store tests (ai_loop_store)
    // execute on the Linux CI host where test_main.zig is skipped (no desktop
    // backend → supports_desktop_exe = false), and so the tmux posix tests run on
    // a posix host (they are guarded out of the windows app test binary).
    if (b.graph.host.result.os.tag != .windows) {
        const posix_test_mod = b.createModule(.{
            .root_source_file = b.path("src/test_posix.zig"),
            .target = b.resolveTargetQuery(.{}),
            .optimize = optimize,
            .link_libc = true,
        });
        const posix_test_options = b.addOptions();
        posix_test_options.addOption([]const u8, "app_version", app_version);
        posix_test_options.addOption([]const u8, "release_notes", "");
        posix_test_options.addOption([]const u8, "gpu_backend", "auto");
        posix_test_mod.addOptions("build_options", posix_test_options);
        const posix_tests = b.addTest(.{
            .name = "wispterm-posix-test",
            .root_module = posix_test_mod,
        });
        test_full_step.dependOn(&b.addRunArtifact(posix_tests).step);
    }

    // `test-ctl`: the agent-control loopback socket round-trip, runnable on EVERY
    // host including Windows. This is the regression guard the v1.30.0 "malformed
    // response" bug slipped through — the round-trip only ran on non-Windows hosts
    // (posix_tests above), and the broken Stream.read it replaced misbehaves only
    // on Windows overlapped sockets. Lean (pure std + sockets), so it links
    // without the app graph; libc only where the socket syscalls need it (Windows
    // uses ws2_32 directly via ctl/transport.zig, so no libc there).
    const ctl_socket_test_mod = b.createModule(.{
        .root_source_file = b.path("src/ctl/socket_test.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = optimize,
        .link_libc = b.graph.host.result.os.tag != .windows,
    });
    const ctl_socket_tests = b.addTest(.{
        .name = "wispterm-ctl-socket-test",
        .root_module = ctl_socket_test_mod,
    });
    const test_ctl_step = b.step("test-ctl", "Run the agent-control loopback socket round-trip (all hosts, incl. Windows)");
    test_ctl_step.dependOn(&b.addRunArtifact(ctl_socket_tests).step);

    const shared_test_mod = b.createModule(.{
        .root_source_file = b.path("src/shared_compile_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const shared_test_options = b.addOptions();
    shared_test_options.addOption([]const u8, "app_version", app_version);
    shared_test_options.addOption([]const u8, "release_notes", "");
    shared_test_options.addOption([]const u8, "gpu_backend", gpu_backend);
    shared_test_mod.addOptions("build_options", shared_test_options);

    const shared_tests = b.addTest(.{
        .name = "wispterm-shared-compile-test",
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
            .name = "wispterm-metal-test",
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
            .name = "wispterm-macos-window-test",
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
            .name = "wispterm-macos-font-test",
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
        macos_services_test_mod.addCSourceFile(.{
            .file = b.path("src/platform/text_macos_bridge.m"),
            .flags = &.{},
            .language = .objective_c,
        });
        macos_services_test_mod.addCSourceFile(.{
            .file = b.path("src/platform/remote_transport_macos_bridge.m"),
            .flags = &.{},
            .language = .objective_c,
        });
        macos_services_test_mod.linkFramework("AppKit", .{});
        macos_services_test_mod.linkFramework("Carbon", .{});
        macos_services_test_mod.linkFramework("CoreFoundation", .{});
        macos_services_test_mod.linkFramework("Foundation", .{});
        // services_macos_bridge.m uses UNUserNotificationCenter; the app bundle
        // links UserNotifications (macos_app_frameworks) but this test module
        // previously did not, so the smoke test failed to link on macOS.
        macos_services_test_mod.linkFramework("UserNotifications", .{});
        macos_services_test_mod.linkSystemLibrary("objc", .{});
        const macos_services_tests = b.addTest(.{
            .name = "wispterm-macos-services-test",
            .root_module = macos_services_test_mod,
        });
        apple_sdk.addPaths(b, macos_services_tests) catch @panic("failed to locate native Apple SDK for macOS service tests");
        test_macos_services_step.dependOn(&b.addRunArtifact(macos_services_tests).step);

        const macos_ui_test_mod = createAppModuleWithRoot(
            b,
            "src/test_macos_ui.zig",
            b.resolveTargetQuery(.{}),
            optimize,
            app_version,
            PlatformFeatures.forOs(.macos),
            false,
            false,
            "auto",
        );
        const macos_ui_tests = b.addTest(.{
            .name = "wispterm-macos-ui-test",
            .root_module = macos_ui_test_mod,
        });
        apple_sdk.addPaths(b, macos_ui_tests) catch @panic("failed to locate native Apple SDK for macOS UI tests");
        test_macos_ui_step.dependOn(&b.addRunArtifact(macos_ui_tests).step);

        const macos_menu_test_mod = createAppModuleWithRoot(
            b,
            "src/test_macos_menu.zig",
            b.resolveTargetQuery(.{}),
            optimize,
            app_version,
            PlatformFeatures.forOs(.macos),
            false,
            false,
            "auto",
        );
        const macos_menu_tests = b.addTest(.{
            .name = "wispterm-macos-menu-test",
            .root_module = macos_menu_test_mod,
        });
        apple_sdk.addPaths(b, macos_menu_tests) catch @panic("failed to locate native Apple SDK for macOS menu tests");
        test_macos_menu_step.dependOn(&b.addRunArtifact(macos_menu_tests).step);
    } else {
        test_metal_step.dependOn(&b.addFail("test-metal requires a macOS host with Metal").step);
        test_macos_window_step.dependOn(&b.addFail("test-macos-window requires a macOS host with AppKit").step);
        test_macos_font_step.dependOn(&b.addFail("test-macos-font requires a macOS host with CoreText").step);
        test_macos_services_step.dependOn(&b.addFail("test-macos-services requires a macOS host with AppKit").step);
        test_macos_ui_step.dependOn(&b.addFail("test-macos-ui requires a macOS host with AppKit").step);
        test_macos_menu_step.dependOn(&b.addFail("test-macos-menu requires a macOS host with AppKit").step);
    }

    if (platform.supports_desktop_exe) {
        const app_test_shards = [_][]const u8{
            "guards",
            "assistant",
            "app",
            "platform",
            "input_renderer",
            "integrations",
            "behavior",
        };
        for (app_test_shards) |app_test_shard| {
            const test_mod = if (std.mem.eql(u8, app_test_shard, "guards"))
                createAppGuardTestModule(b, target, optimize)
            else
                createAppModuleWithRootAndTestShard(
                    b,
                    "src/test_main.zig",
                    target,
                    optimize,
                    app_version,
                    platform,
                    webview,
                    false,
                    gpu_backend,
                    app_test_shard,
                );

            const tests = b.addTest(.{
                .name = b.fmt("wispterm-app-test-{s}", .{app_test_shard}),
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
}

fn createAppGuardTestModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/test_main_guards.zig"),
        .target = target,
        .optimize = optimize,
    });

    const app_options = b.addOptions();
    app_options.addOption([]const u8, "app_test_shard", "guards");
    app_mod.addOptions("build_options", app_options);
    return app_mod;
}

fn createAppModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    app_version: []const u8,
    platform: PlatformFeatures,
    webview: bool,
    debug_console: bool,
    gpu_backend: []const u8,
) *std.Build.Module {
    return createAppModuleWithRoot(b, "src/main.zig", target, optimize, app_version, platform, webview, debug_console, gpu_backend);
}

fn createAppModuleWithRoot(
    b: *std.Build,
    root_source_path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    app_version: []const u8,
    platform: PlatformFeatures,
    webview: bool,
    debug_console: bool,
    gpu_backend: []const u8,
) *std.Build.Module {
    return createAppModuleWithRootAndTestShard(
        b,
        root_source_path,
        target,
        optimize,
        app_version,
        platform,
        webview,
        debug_console,
        gpu_backend,
        "all",
    );
}

fn createAppModuleWithRootAndTestShard(
    b: *std.Build,
    root_source_path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    app_version: []const u8,
    platform: PlatformFeatures,
    webview: bool,
    debug_console: bool,
    gpu_backend: []const u8,
    app_test_shard: []const u8,
) *std.Build.Module {
    const app_mod = b.createModule(.{
        .root_source_file = b.path(root_source_path),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const app_options = b.addOptions();
    app_options.addOption(bool, "webview", webview);
    app_options.addOption(bool, "debug_console", debug_console);
    app_options.addOption([]const u8, "gpu_backend", gpu_backend);
    app_options.addOption([]const u8, "app_test_shard", app_test_shard);
    app_options.addOption([]const u8, "app_version", app_version);
    app_options.addOption([]const u8, "release_notes", readReleaseNotes(b, app_version));
    app_mod.addOptions("build_options", app_options);

    // Embed user-facing docs so the wispterm_docs agent tool can read them at
    // runtime. @embedFile cannot escape src/, so docs/ files are wired in here
    // as named embed imports consumed by src/wispterm_docs.zig.
    app_mod.addAnonymousImport("wispterm_doc_faq", .{ .root_source_file = b.path("docs/faq.md") });
    app_mod.addAnonymousImport("wispterm_doc_configuration", .{ .root_source_file = b.path("docs/configuration.md") });
    app_mod.addAnonymousImport("wispterm_doc_ai_agent", .{ .root_source_file = b.path("docs/ai-agent.md") });
    app_mod.addAnonymousImport("wispterm_doc_file_explorer", .{ .root_source_file = b.path("docs/file-explorer.md") });
    app_mod.addAnonymousImport("wispterm_doc_media", .{ .root_source_file = b.path("docs/media.md") });
    app_mod.addAnonymousImport("wispterm_doc_tabs_panels", .{ .root_source_file = b.path("docs/tabs-panels.md") });

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
        // Apple Color Emoji and most modern color-emoji fonts store sbix /
        // CBDT strikes as PNG; without libpng FreeType reads the strike
        // metadata but renderGlyph fails to decode the bitmap, leaving
        // emoji cells blank.
        .@"enable-libpng" = true,
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

    // System WinRT PDF rasterizer bridge (preview pane PDF support); loads its
    // combase/shlwapi/shcore entry points dynamically, so no extra libraries.
    if (target.result.os.tag == .windows) {
        app_mod.addCSourceFile(.{
            .file = b.path("src/platform/pdf_render_windows_bridge.c"),
            .flags = &.{},
        });
    }

    // OpenGL backend (Windows + Linux): the glad loader needs its include path
    // and C source compiled in. macOS uses Metal and skips this; the native
    // D3D11 flavor never touches GL, so it skips glad and opengl32 entirely.
    const links_opengl = !std.mem.eql(u8, gpu_backend, "d3d11");
    if (links_opengl and (target.result.os.tag == .windows or target.result.os.tag == .linux)) {
        app_mod.addIncludePath(b.path("vendor/glad/include"));
        app_mod.addCSourceFile(.{
            .file = b.path("vendor/glad/src/gl.c"),
            .flags = &.{},
        });
    }

    // Windows links the system OpenGL (opengl32); Linux gets its GL context and
    // function loader from SDL3 (linked via systemLibrariesFor above), so it
    // needs no separate GL system library.
    if (links_opengl) {
        if (platform.opengl_system_library) |library| {
            app_mod.linkSystemLibrary(library, .{});
        }
    }

    if (target.result.os.tag == .linux) {
        if (b.lazyDependency("sdl", .{ .target = target })) |dep| {
            app_mod.addImport("sdl", dep.module("sdl"));
        }
        if (b.lazyDependency("fontconfig", .{ .target = target })) |dep| {
            app_mod.addImport("fontconfig", dep.module("fontconfig"));
        }
        // libfontconfig lives in the system libdir; pkg-config does not emit it
        // as a -L (it is a default search path for the system compiler, but Zig
        // does not assume host paths). Discover it via pkg-config so we avoid a
        // hardcoded, distro-specific multiarch path.
        if (pkgConfigVariable(b, "fontconfig", "libdir")) |libdir| {
            app_mod.addLibraryPath(.{ .cwd_relative = libdir });
        }
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
        const bridge_source = webviewBridgeSourcePath(platform).?;
        app_mod.addCSourceFile(.{
            .file = b.path(bridge_source),
            .flags = &.{},
            .language = if (std.mem.endsWith(u8, bridge_source, ".m")) .objective_c else .c,
        });
    }

    if (platform.supports_resource_manifest) {
        app_mod.addWin32ResourceFile(.{
            .file = b.path("assets/wispterm.rc"),
            .include_paths = &.{b.path("assets")},
        });
    }

    if (platform.supports_app_bundle) {
        app_mod.linkSystemLibrary("objc", .{});
    }
    return app_mod;
}

fn createBenchModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/wispterm_bench.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // env.zig reads app_version + gpu_backend from build_options. The bench
    // CLI links no GPU backend, so gpu_backend is reported as "n/a".
    const bench_options = b.addOptions();
    bench_options.addOption([]const u8, "app_version", packageVersion(b));
    bench_options.addOption([]const u8, "gpu_backend", "n/a");
    bench_mod.addOptions("build_options", bench_options);
    // The TerminalStream case drives ghostty-vt; wire the same dep + stb the
    // app uses so the VT parser is the exact shipped code path.
    if (b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .simd = false,
    })) |dep| {
        bench_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
        bench_mod.addIncludePath(dep.path("src/stb"));
        bench_mod.addCSourceFile(.{
            .file = dep.path("src/stb/stb.c"),
            .flags = &.{},
        });
    }
    return bench_mod;
}

fn addMacosAppBundle(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    app_version: []const u8,
    platform: PlatformFeatures,
    debug_console: bool,
    gpu_backend: []const u8,
) *std.Build.Step.InstallDir {
    const metadata = macosBundleMetadata();
    const macos_mod = createAppModule(b, target, optimize, app_version, platform, platform.supports_embedded_browser, debug_console, gpu_backend);

    const exe = b.addExecutable(.{
        .name = metadata.executable_name,
        .root_module = macos_mod,
    });
    apple_sdk.addPaths(b, exe) catch @panic("failed to locate native Apple SDK for macOS app executable");

    const bundle = b.addWriteFiles();
    _ = bundle.add(macosBundleInfoPlistPath(), macosInfoPlist(b.allocator, app_version));
    _ = bundle.add("WispTerm.app/Contents/PkgInfo", "APPL????");
    _ = bundle.add(macosBundleResourcesKeepPath(), "");
    _ = bundle.addCopyFile(exe.getEmittedBin(), macosBundleExecutablePath());
    _ = bundle.addCopyFile(b.path(macosBundleIconSourcePath()), macosBundleIconBundlePath());
    // Ship the bundled default skills/commands so a packaged .app has them even
    // before the user populates ~/Library/Application Support. The runtime looks
    // for these under <exe_dir>/../Resources (see defaultSkillRootPaths).
    _ = bundle.addCopyDirectory(b.path(macosBundlePluginsSourcePath()), macosBundlePluginsBundlePath(), .{});

    const install_bundle = b.addInstallDirectory(.{
        .source_dir = bundle.getDirectory(),
        .install_dir = .bin,
        .install_subdir = "",
    });
    const clean_existing_bundle = b.addSystemCommand(&.{
        "bash",
        "-c",
        "rm -rf \"$1\"",
        "wispterm-clean-macos-app",
        b.getInstallPath(.bin, metadata.bundle_dir),
    });
    install_bundle.step.dependOn(&clean_existing_bundle.step);
    return install_bundle;
}

/// Read the release notes for `app_version` (`release-notes/vX.Y.Z.md`) at
/// configure time so they can be embedded as a build option. Returns "" when the
/// file is missing or unreadable — a missing notes file must never fail the build.
fn readReleaseNotes(b: *std.Build, app_version: []const u8) []const u8 {
    const path = std.fmt.allocPrint(b.allocator, "release-notes/v{s}.md", .{app_version}) catch return "";
    return b.build_root.handle.readFileAllocOptions(
        b.allocator,
        path,
        256 * 1024,
        null,
        .of(u8),
        null,
    ) catch "";
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
