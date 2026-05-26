const std = @import("std");
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
    system_libraries: []const []const u8,
    opengl_system_library: ?[]const u8,

    fn forOs(os_tag: std.Target.Os.Tag) PlatformFeatures {
        const uses_windows_backend = os_tag == .windows;
        const embedded_browser_backend: EmbeddedBrowserBackend = if (uses_windows_backend) .webview2 else .none;
        return .{
            .supports_desktop_exe = uses_windows_backend,
            .supports_embedded_browser = embedded_browser_backend.isSupported(),
            .embedded_browser_backend = embedded_browser_backend,
            .supports_resource_manifest = uses_windows_backend,
            .supports_gui_subsystem = uses_windows_backend,
            .supports_remote_transport = uses_windows_backend,
            .system_libraries = if (uses_windows_backend) &windows_system_libraries else &.{},
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

test "platform feature gates only enable windows artifacts on windows" {
    const windows = PlatformFeatures.forOs(.windows);
    try std.testing.expect(windows.supports_desktop_exe);
    try std.testing.expect(windows.supports_embedded_browser);
    try std.testing.expectEqual(EmbeddedBrowserBackend.webview2, windows.embedded_browser_backend);
    try std.testing.expect(windows.supports_resource_manifest);
    try std.testing.expect(windows.supports_gui_subsystem);
    try std.testing.expect(windows.supports_remote_transport);
    try std.testing.expectEqualStrings("opengl32", windows.opengl_system_library.?);

    const linux = PlatformFeatures.forOs(.linux);
    try std.testing.expect(!linux.supports_desktop_exe);
    try std.testing.expect(!linux.supports_embedded_browser);
    try std.testing.expectEqual(EmbeddedBrowserBackend.none, linux.embedded_browser_backend);
    try std.testing.expect(!linux.supports_resource_manifest);
    try std.testing.expect(!linux.supports_gui_subsystem);
    try std.testing.expect(!linux.supports_remote_transport);
    try std.testing.expect(linux.opengl_system_library == null);

    const macos = PlatformFeatures.forOs(.macos);
    try std.testing.expect(!macos.supports_embedded_browser);
    try std.testing.expectEqual(EmbeddedBrowserBackend.none, macos.embedded_browser_backend);
    try std.testing.expect(!macos.supports_resource_manifest);
    try std.testing.expect(!macos.supports_remote_transport);
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
    try std.testing.expect(!defaultEmitDesktopExe(PlatformFeatures.forOs(.macos)));
}

test "shared compile checks default to platforms without desktop backends" {
    try std.testing.expect(!defaultEmitSharedCompileChecks(PlatformFeatures.forOs(.windows)));
    try std.testing.expect(defaultEmitSharedCompileChecks(PlatformFeatures.forOs(.linux)));
    try std.testing.expect(defaultEmitSharedCompileChecks(PlatformFeatures.forOs(.macos)));
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
        const exe_mod = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        const app_options = b.addOptions();
        app_options.addOption(bool, "webview", webview);
        app_options.addOption([]const u8, "app_version", app_version);
        exe_mod.addOptions("build_options", app_options);

        // Add ghostty-vt dependency with SIMD disabled for cross-compilation
        if (b.lazyDependency("ghostty", .{
            .target = target,
            .optimize = optimize,
            .simd = false,
        })) |dep| {
            exe_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
            exe_mod.addIncludePath(dep.path("src/stb"));
            exe_mod.addCSourceFile(.{
                .file = dep.path("src/stb/stb.c"),
                .flags = &.{},
            });
        }

        // Add libxev dependency (xev event loop for IO thread)
        if (b.lazyDependency("libxev", .{
            .target = target,
            .optimize = optimize,
        })) |dep| {
            exe_mod.addImport("xev", dep.module("xev"));
        }

        for (systemLibrariesFor(platform)) |library| {
            exe_mod.linkSystemLibrary(library, .{});
        }

        // Add FreeType dependency (shared between main and harfbuzz)
        const freetype_dep = b.lazyDependency("freetype", .{
            .target = target,
            .optimize = optimize,
        });
        if (freetype_dep) |dep| {
            exe_mod.addImport("freetype", dep.module("freetype"));
            exe_mod.linkLibrary(dep.artifact("freetype"));
        }

        // Add z2d dependency for sprite rendering
        if (b.lazyDependency("z2d", .{
            .target = target,
            .optimize = optimize,
        })) |dep| {
            exe_mod.addImport("z2d", dep.module("z2d"));
        }

        // Add HarfBuzz — build C library and create Zig module sharing our freetype
        if (b.lazyDependency("harfbuzz", .{})) |hb_dep| {
            if (freetype_dep) |ft_dep| {
                // Build the HarfBuzz C static library from source
                const hb_lib = buildHarfbuzzLib(b, target, optimize, hb_dep, ft_dep);

                // Create Zig wrapper module sharing our freetype module
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

                // Add HarfBuzz C headers to the Zig module
                if (hb_dep.builder.lazyDependency("harfbuzz", .{})) |upstream| {
                    hb_mod.addIncludePath(upstream.path("src"));
                }
                // Add FreeType C headers so hb-ft.h can find ft2build.h
                hb_mod.addIncludePath(b.path("pkg/freetype"));
                if (ft_dep.builder.lazyDependency("freetype", .{})) |ft_upstream| {
                    hb_mod.addIncludePath(ft_upstream.path("include"));
                }

                exe_mod.addImport("harfbuzz", hb_mod);
                exe_mod.linkLibrary(hb_lib);
            }
        }

        // Add OpenGL/glad headers and source
        exe_mod.addIncludePath(b.path("vendor/glad/include"));
        exe_mod.addCSourceFile(.{
            .file = b.path("vendor/glad/src/gl.c"),
            .flags = &.{},
        });
        if (webview) {
            exe_mod.addCSourceFile(.{
                .file = b.path(webviewBridgeSourcePath(platform).?),
                .flags = &.{},
            });
        }

        if (platform.opengl_system_library) |library| {
            exe_mod.linkSystemLibrary(library, .{});
        }

        if (platform.supports_resource_manifest) {
            exe_mod.addWin32ResourceFile(.{
                .file = b.path("assets/phantty.rc"),
                .include_paths = &.{b.path("assets")},
            });
        }

        const exe = b.addExecutable(.{
            .name = "phantty",
            .root_module = exe_mod,
        });

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

    if (platform.supports_desktop_exe) {
        const test_mod = b.createModule(.{
            .root_source_file = b.path("src/test_main.zig"),
            .target = target,
            .optimize = optimize,
        });
        const test_options = b.addOptions();
        test_options.addOption(bool, "webview", webview);
        test_options.addOption([]const u8, "app_version", app_version);
        test_mod.addOptions("build_options", test_options);

        if (b.lazyDependency("ghostty", .{
            .target = target,
            .optimize = optimize,
            .simd = false,
        })) |dep| {
            test_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
        }

        if (b.lazyDependency("libxev", .{
            .target = target,
            .optimize = optimize,
        })) |dep| {
            test_mod.addImport("xev", dep.module("xev"));
        }

        const tests = b.addTest(.{
            .root_module = test_mod,
        });

        const run_tests = b.addRunArtifact(tests);
        run_tests.skip_foreign_checks = shouldSkipForeignTestRun(
            b.graph.host.result.os.tag,
            target.result.os.tag,
            run_foreign_tests,
        );
        test_full_step.dependOn(&run_tests.step);
    }
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
