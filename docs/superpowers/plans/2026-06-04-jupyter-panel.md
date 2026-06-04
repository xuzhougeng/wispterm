# Jupyter Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let WispTerm render a (remote) Jupyter server inside the existing embedded web panel on macOS, by adding a WKWebView backend to `platform/webview.zig` plus a thin "Open Jupyter" entry point.

**Architecture:** The embedded browser panel (`browser_panel.zig`) already does "paste a `localhost` URL → SSH-tunnel to the owning remote surface → render in an embedded webview." On Windows this works today via WebView2. The webview backend is Windows-only, so the substantive work is a macOS WKWebView backend that satisfies the same `platform/webview.zig` contract. The WKWebView is added as a subview of the AppKit window's content view, overlaying the Metal-backed terminal surface — the structural analogue of the Windows child-`HWND` approach. Jupyter itself is one command that opens the panel and focuses the URL bar for pasting.

**Tech Stack:** Zig 0.15.2, Objective-C (manual retain/release — the repo does **not** use ARC), WebKit.framework / AppKit, the vendored `apple-sdk` for macOS cross-compilation.

---

## Background facts (verified against the code)

- **Contract** (`src/platform/webview.zig`): a backend must expose `NativeWindowHandle`, `Browser` (opaque), `max_url_units`, `UrlBuffer`, `Url`, and `loaderAvailable`, `urlFromUtf8`, `create`, `setBounds`, `setVisible`, `focus`, `navigate`, `isReady`, `lastError`, `destroy`. The Windows backend uses UTF-16 URLs; macOS will use UTF-8 (`Url = [:0]const u8`), identical to `webview_unsupported.zig`.
- **Native handle** (`src/platform/window.zig`, `window_backend.zig`): on macOS `NativeHandle = *anyopaque`, and it is a pointer to the private `WispTermMacWindowState` struct (`{ NSWindow *window; WispTermMacContentView *view; ... }`) defined in `window_macos_bridge.m`. `browser_panel` passes this handle straight through as the webview `parent`.
- **Build wiring** (`build.zig`): `webviewBridgeSourcePath(features)` maps the `embedded_browser_backend` enum to a bridge source file; `appFrameworksFor` links `macos_app_frameworks`; a source ending in `.m` is compiled as Objective-C automatically.
- **Tunnel path** (confirmed): `browser_panel.submitUrlBar → openForSurface → externalUrlForSurface(surface) → ssh_tunnel.externalUrlForSurface`. `sshLoopbackUrl` (`ssh_tunnel.zig:116`) requires `surface.launch_kind == .ssh` and `surface.ssh_connection != null` and a loopback host. No new connection logic is needed.
- **Cross-compile gate**: `zig build macos-app -Dtarget=aarch64-macos` builds the macOS app bundle from Linux using the vendored `apple-sdk`. This is the automated integration check for the native bridge (the bridge cannot be unit-tested on a Linux host because the macOS arm of the facade's `impl` switch is never analyzed on Linux).

## File Structure

- **Create** `src/platform/webview_macos.zig` — Zig side of the macOS backend: contract types + `extern` decls + thin wrappers. One responsibility: satisfy the `platform/webview.zig` contract by forwarding to the ObjC bridge.
- **Create** `src/platform/webview_macos_bridge.m` — Objective-C: owns the `WKWebView` lifecycle, coordinate conversion, and navigation. One responsibility: AppKit/WebKit glue.
- **Modify** `src/platform/window_macos_bridge.m` — add one accessor, `wispterm_macos_window_ns_window`, exposing the `NSWindow` for a handle (the webview bridge cannot see the private state struct).
- **Modify** `src/platform/webview.zig` — add the `.macos` backend arm + update the three contract tests.
- **Modify** `build.zig` — add the `webkit` backend, map it to the bridge source, link `WebKit.framework`, add the ATS Info.plist key, and update the build unit tests.
- **Modify** `src/browser_panel.zig` — add `openJupyterForSurface` (open blank + focus URL bar for pasting).
- **Modify** `src/input.zig` — add `openJupyterPanel` (mirror of `toggleBrowserPanel`).
- **Modify** `src/command_center_state.zig` — add the `open_jupyter_panel` action + command entry + a `findCommandAction` test.
- **Modify** `src/renderer/overlays.zig` — dispatch arm for the new action.
- **Modify** `src/i18n.zig` — zh-CN title + detail arms for the new action.

---

## Task 1: build.zig — add the `webkit` backend, framework, ATS, and tests

**Files:**
- Modify: `build.zig` (enum `EmbeddedBrowserBackend`, `webviewBridgeSourcePath`, `PlatformFeatures.forOs`, `macos_app_frameworks`, `macosInfoPlist`, and three test blocks)

- [ ] **Step 1: Update the failing build tests first**

In `build.zig`, change the macOS expectations (currently `build.zig:277-278`):

```zig
    const macos = PlatformFeatures.forOs(.macos);
    try std.testing.expect(macos.supports_desktop_exe);
    try std.testing.expect(macos.supports_embedded_browser);
    try std.testing.expectEqual(EmbeddedBrowserBackend.webkit, macos.embedded_browser_backend);
```

Change the framework test (`build.zig:300-302`) to expect 10 frameworks and assert WebKit:

```zig
test "macOS platform advertises required app frameworks" {
    const frameworks = appFrameworksFor(PlatformFeatures.forOs(.macos));
    try std.testing.expectEqual(@as(usize, 10), frameworks.len);
    try expectContainsString(frameworks, "WebKit");
    try expectContainsString(frameworks, "Metal");
```

Change the bridge-source test (`build.zig:323`):

```zig
    try std.testing.expectEqualStrings(
        "src/platform/webview_macos_bridge.m",
        webviewBridgeSourcePath(PlatformFeatures.forOs(.macos)).?,
    );
```

- [ ] **Step 2: Run the build tests to verify they fail**

Run: `zig test build.zig`
Expected: FAIL — `EmbeddedBrowserBackend` has no `webkit` member, framework count is 9, and `webviewBridgeSourcePath(.macos)` is `null`.

- [ ] **Step 3: Add the `webkit` enum value**

In `build.zig`, extend the enum (`build.zig:60`):

```zig
const EmbeddedBrowserBackend = enum {
    none,
    webview2,
    webkit,

    fn isSupported(self: EmbeddedBrowserBackend) bool {
        return self != .none;
    }
};
```

- [ ] **Step 4: Select `webkit` for macOS and map it to the bridge source**

In `PlatformFeatures.forOs` (`build.zig:84`), replace the backend selection:

```zig
        const embedded_browser_backend: EmbeddedBrowserBackend = if (uses_windows_backend)
            .webview2
        else if (uses_macos_backend)
            .webkit
        else
            .none;
```

In `webviewBridgeSourcePath` (`build.zig:222`), add the `webkit` arm:

```zig
fn webviewBridgeSourcePath(features: PlatformFeatures) ?[]const u8 {
    return switch (features.embedded_browser_backend) {
        .webview2 => "src/platform/webview2_bridge.c",
        .webkit => "src/platform/webview_macos_bridge.m",
        .none => null,
    };
}
```

- [ ] **Step 5: Link WebKit.framework**

In the `macos_app_frameworks` array (`build.zig:31`), add `"WebKit"` (place it first so the count is obvious):

```zig
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
};
```

- [ ] **Step 6: Allow cleartext HTTP to localhost (ATS)**

In `macosInfoPlist` (`build.zig:197`), add the ATS dict immediately before the closing `</dict>` (after the `NSHighResolutionCapable` entry):

```zig
        \\    <key>NSHighResolutionCapable</key>
        \\    <true/>
        \\    <key>NSAppTransportSecurity</key>
        \\    <dict>
        \\        <key>NSAllowsLocalNetworking</key>
        \\        <true/>
        \\    </dict>
        \\</dict>
```

- [ ] **Step 7: Run the build tests to verify they pass**

Run: `zig test build.zig`
Expected: PASS (all build unit tests green).

- [ ] **Step 8: Commit**

```bash
git add build.zig
git commit -m "build: add macOS webkit embedded-browser backend wiring + ATS"
```

---

## Task 2: Create the Zig macOS webview backend

**Files:**
- Create: `src/platform/webview_macos.zig`

> No standalone automated test: on a Linux host the facade never analyzes this file (the `.macos` arm of its `impl` switch is not taken), so it is compiled only when targeting macOS. It is compile-checked by the cross-compile build in Task 4 and exercised at runtime in Task 6.

- [ ] **Step 1: Write the backend file**

Create `src/platform/webview_macos.zig` with exactly:

```zig
const std = @import("std");

pub const NativeWindowHandle = *anyopaque;
pub const Browser = opaque {};
pub const max_url_units = 2048;
pub const UrlBuffer = [max_url_units]u8;
pub const Url = [:0]const u8;

extern fn wispterm_webview_macos_loader_available() callconv(.c) c_int;
extern fn wispterm_webview_macos_create(
    parent: NativeWindowHandle,
    left: c_int,
    top: c_int,
    right: c_int,
    bottom: c_int,
    initial_url: [*:0]const u8,
) callconv(.c) ?*Browser;
extern fn wispterm_webview_macos_set_bounds(browser: *Browser, left: c_int, top: c_int, right: c_int, bottom: c_int) callconv(.c) void;
extern fn wispterm_webview_macos_set_visible(browser: *Browser, visible: c_int) callconv(.c) void;
extern fn wispterm_webview_macos_focus(browser: *Browser) callconv(.c) void;
extern fn wispterm_webview_macos_navigate(browser: *Browser, url: [*:0]const u8) callconv(.c) void;
extern fn wispterm_webview_macos_is_ready(browser: *Browser) callconv(.c) c_int;
extern fn wispterm_webview_macos_last_error(browser: *Browser) callconv(.c) i32;
extern fn wispterm_webview_macos_destroy(browser: *Browser) callconv(.c) void;

pub fn loaderAvailable() bool {
    return wispterm_webview_macos_loader_available() != 0;
}

pub fn urlFromUtf8(url: []const u8, out: *UrlBuffer) ?Url {
    if (url.len >= out.len) return null;
    @memcpy(out[0..url.len], url);
    out[url.len] = 0;
    return out[0..url.len :0];
}

pub fn create(parent: NativeWindowHandle, bounds: anytype, initial_url: Url) ?*Browser {
    return wispterm_webview_macos_create(parent, bounds.left, bounds.top, bounds.right, bounds.bottom, initial_url.ptr);
}

pub fn setBounds(browser: *Browser, bounds: anytype) void {
    wispterm_webview_macos_set_bounds(browser, bounds.left, bounds.top, bounds.right, bounds.bottom);
}

pub fn setVisible(browser: *Browser, visible: bool) void {
    wispterm_webview_macos_set_visible(browser, if (visible) 1 else 0);
}

pub fn focus(browser: *Browser) void {
    wispterm_webview_macos_focus(browser);
}

pub fn navigate(browser: *Browser, url: Url) void {
    wispterm_webview_macos_navigate(browser, url.ptr);
}

pub fn isReady(browser: *Browser) bool {
    return wispterm_webview_macos_is_ready(browser) != 0;
}

pub fn lastError(browser: *Browser) i32 {
    return wispterm_webview_macos_last_error(browser);
}

pub fn destroy(browser: *Browser) void {
    wispterm_webview_macos_destroy(browser);
}
```

- [ ] **Step 2: Sanity-parse the file**

Run: `zig fmt --check src/platform/webview_macos.zig`
Expected: no output (well-formed; exits 0).

- [ ] **Step 3: Commit**

```bash
git add src/platform/webview_macos.zig
git commit -m "feat(webview): Zig macOS WKWebView backend (contract + externs)"
```

---

## Task 3: Create the Objective-C WKWebView bridge

**Files:**
- Create: `src/platform/webview_macos_bridge.m`
- Modify: `src/platform/window_macos_bridge.m` (add `wispterm_macos_window_ns_window`)

> Manual retain/release (no ARC). Compile-checked in Task 4, runtime-verified in Task 6.

- [ ] **Step 1: Expose the NSWindow accessor**

In `src/platform/window_macos_bridge.m`, add this non-static function next to the other public `wispterm_macos_window_*` functions (e.g. right after `wispterm_macos_window_destroy`):

```objc
void *wispterm_macos_window_ns_window(void *handle) {
    WispTermMacWindowState *state = wispterm_macos_state(handle);
    if (state == NULL) return NULL;
    return (void *)state->window;
}
```

- [ ] **Step 2: Write the bridge**

Create `src/platform/webview_macos_bridge.m` with exactly:

```objc
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include <stdint.h>
#include <stdlib.h>

// Defined in window_macos_bridge.m — resolves a NativeHandle to its NSWindow.
extern void *wispterm_macos_window_ns_window(void *handle);

typedef struct WispTermMacWebView {
    WKWebView *webview;
    int32_t last_error;
} WispTermMacWebView;

// AppKit is main-thread only. The browser panel drives create/sync from the
// main UI loop, but guard so a background caller cannot crash AppKit.
static void wispterm_webview_run_on_main(dispatch_block_t block) {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
}

// Convert top-left device-pixel bounds into a bottom-left point-space NSRect in
// the content view's coordinates. NOTE: coord flip + backing scale are the
// device-verify items in the design spec.
static NSRect wispterm_webview_frame(NSView *content, int left, int top, int right, int bottom) {
    CGFloat scale = content.window.backingScaleFactor;
    if (scale <= 0.0) scale = 1.0;
    CGFloat content_h = content.bounds.size.height; // points
    CGFloat x = (CGFloat)left / scale;
    CGFloat w = (CGFloat)(right - left) / scale;
    CGFloat h = (CGFloat)(bottom - top) / scale;
    CGFloat y = content_h - ((CGFloat)bottom / scale);
    return NSMakeRect(x, y, w, h);
}

int wispterm_webview_macos_loader_available(void) {
    return (NSClassFromString(@"WKWebView") != nil) ? 1 : 0;
}

void *wispterm_webview_macos_create(void *parent, int left, int top, int right, int bottom, const char *initial_url) {
    __block WispTermMacWebView *state = NULL;
    wispterm_webview_run_on_main(^{
        NSWindow *window = (NSWindow *)wispterm_macos_window_ns_window(parent);
        if (window == nil) return;
        NSView *content = [window contentView];
        if (content == nil) return;

        WispTermMacWebView *st = (WispTermMacWebView *)calloc(1, sizeof(WispTermMacWebView));
        if (st == NULL) return;

        NSRect frame = wispterm_webview_frame(content, left, top, right, bottom);
        WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
        WKWebView *web = [[WKWebView alloc] initWithFrame:frame configuration:config];
        [config release];
        web.autoresizingMask = NSViewNotSizable;
        [content addSubview:web positioned:NSWindowAbove relativeTo:nil];

        st->webview = web; // owned (alloc); released in destroy
        st->last_error = 0;
        state = st;

        if (initial_url != NULL && initial_url[0] != '\0') {
            NSString *s = [NSString stringWithUTF8String:initial_url];
            NSURL *u = [NSURL URLWithString:s];
            if (u != nil) [web loadRequest:[NSURLRequest requestWithURL:u]];
        }
    });
    return (void *)state;
}

void wispterm_webview_macos_set_bounds(void *browser, int left, int top, int right, int bottom) {
    WispTermMacWebView *st = (WispTermMacWebView *)browser;
    if (st == NULL || st->webview == nil) return;
    wispterm_webview_run_on_main(^{
        NSView *content = st->webview.superview;
        if (content == nil) return;
        st->webview.frame = wispterm_webview_frame(content, left, top, right, bottom);
    });
}

void wispterm_webview_macos_set_visible(void *browser, int visible) {
    WispTermMacWebView *st = (WispTermMacWebView *)browser;
    if (st == NULL || st->webview == nil) return;
    wispterm_webview_run_on_main(^{
        st->webview.hidden = (visible == 0);
    });
}

void wispterm_webview_macos_focus(void *browser) {
    WispTermMacWebView *st = (WispTermMacWebView *)browser;
    if (st == NULL || st->webview == nil) return;
    wispterm_webview_run_on_main(^{
        [st->webview.window makeFirstResponder:st->webview];
    });
}

void wispterm_webview_macos_navigate(void *browser, const char *url) {
    WispTermMacWebView *st = (WispTermMacWebView *)browser;
    if (st == NULL || st->webview == nil || url == NULL) return;
    wispterm_webview_run_on_main(^{
        NSString *s = [NSString stringWithUTF8String:url];
        NSURL *u = [NSURL URLWithString:s];
        if (u != nil) [st->webview loadRequest:[NSURLRequest requestWithURL:u]];
    });
}

int wispterm_webview_macos_is_ready(void *browser) {
    WispTermMacWebView *st = (WispTermMacWebView *)browser;
    return (st != NULL && st->webview != nil) ? 1 : 0;
}

int32_t wispterm_webview_macos_last_error(void *browser) {
    WispTermMacWebView *st = (WispTermMacWebView *)browser;
    return (st != NULL) ? st->last_error : 0;
}

void wispterm_webview_macos_destroy(void *browser) {
    WispTermMacWebView *st = (WispTermMacWebView *)browser;
    if (st == NULL) return;
    wispterm_webview_run_on_main(^{
        if (st->webview != nil) {
            [st->webview removeFromSuperview];
            [st->webview release];
            st->webview = nil;
        }
        free(st);
    });
}
```

- [ ] **Step 3: Commit**

```bash
git add src/platform/webview_macos_bridge.m src/platform/window_macos_bridge.m
git commit -m "feat(webview): Objective-C WKWebView bridge + NSWindow accessor"
```

---

## Task 4: Wire the facade backend selection + cross-compile integration gate

**Files:**
- Modify: `src/platform/webview.zig` (backend enum + `backendForOs` + `impl` switch + 2 tests)

- [ ] **Step 1: Update the failing facade tests first**

In `src/platform/webview.zig`, change the OS-selection test (the `backendForOs(.macos)` line) to expect `.macos`:

```zig
test "platform webview selects backend by target OS" {
    try std.testing.expectEqual(Backend.windows, backendForOs(.windows));
    try std.testing.expectEqual(Backend.unsupported, backendForOs(.linux));
    try std.testing.expectEqual(Backend.macos, backendForOs(.macos));
}
```

And change the unavailable-backend test to also skip on macOS (where the backend is now available):

```zig
test "platform webview reports unavailable when backend is unsupported" {
    if (builtin.os.tag == .windows or builtin.os.tag == .macos) return error.SkipZigTest;
    try std.testing.expect(!loaderAvailable());
}
```

- [ ] **Step 2: Run the fast suite to verify failure**

Run: `zig build test`
Expected: FAIL — `Backend` has no `macos` member, so `backendForOs(.macos)` cannot equal `Backend.macos`.

- [ ] **Step 3: Add the `.macos` backend arm**

In `src/platform/webview.zig`, extend the enum and both switches:

```zig
pub const Backend = enum {
    windows,
    macos,
    unsupported,
};

pub fn backendForOs(os_tag: std.Target.Os.Tag) Backend {
    return switch (os_tag) {
        .windows => .windows,
        .macos => .macos,
        else => .unsupported,
    };
}

const impl = switch (backendForOs(builtin.os.tag)) {
    .windows => @import("webview_windows.zig"),
    .macos => @import("webview_macos.zig"),
    .unsupported => @import("webview_unsupported.zig"),
};
```

- [ ] **Step 4: Run the fast suite to verify it passes**

Run: `zig build test`
Expected: PASS (the macOS arm is not analyzed on Linux; the enum/selection logic is now correct).

- [ ] **Step 5: Cross-compile the macOS app (native integration gate)**

Run: `zig build macos-app -Dtarget=aarch64-macos`
Expected: builds successfully — this compiles `webview_macos.zig`, `webview_macos_bridge.m`, and the `window_macos_bridge.m` accessor, and links `WebKit.framework` via the vendored `apple-sdk`.
If WebKit stubs are missing from the vendored SDK, this is the single step that needs a real macOS toolchain; note it and continue.

- [ ] **Step 6: Commit**

```bash
git add src/platform/webview.zig
git commit -m "feat(webview): select macOS WKWebView backend in the facade"
```

---

## Task 5: Jupyter entry point (open panel + focus URL bar for pasting)

**Files:**
- Modify: `src/command_center_state.zig` (action enum + entry + test)
- Modify: `src/browser_panel.zig` (`openJupyterForSurface`)
- Modify: `src/input.zig` (`openJupyterPanel`)
- Modify: `src/renderer/overlays.zig` (dispatch arm)
- Modify: `src/i18n.zig` (zh-CN title + detail arms)

- [ ] **Step 1: Write the failing command-resolution test**

In `src/command_center_state.zig`, add this test next to the other `findCommandAction` tests:

```zig
test "findCommandAction resolves Open Jupyter" {
    try std.testing.expectEqual(CommandAction.open_jupyter_panel, findCommandAction("Open Jupyter"));
}
```

- [ ] **Step 2: Run the fast suite to verify failure**

Run: `zig build test`
Expected: FAIL — `CommandAction` has no `open_jupyter_panel` member.

- [ ] **Step 3: Add the action + command entry**

In `src/command_center_state.zig`, add `open_jupyter_panel` to the `CommandAction` enum (after `toggle_browser_panel`):

```zig
    toggle_browser_panel,
    open_jupyter_panel,
```

And add a command entry to `command_entries` (right after the `Toggle Browser` row at `command_center_state.zig:66`):

```zig
    .{ .title = "Open Jupyter", .detail = "Open the panel and paste a running Jupyter URL (local or SSH)", .shortcut = "", .action = .open_jupyter_panel },
```

- [ ] **Step 4: Add the panel-open helper**

In `src/browser_panel.zig`, add after `toggleForSurface` (`browser_panel.zig:180`):

```zig
pub fn openJupyterForSurface(allocator: std.mem.Allocator, parent: ?window_backend.NativeHandle, surface: ?*const Surface) bool {
    if (isVisibleForActiveTab()) {
        focusUrlBar();
        return true;
    }
    // Open blank, then focus the URL bar so the user pastes their Jupyter URL.
    if (!openForSurface(allocator, parent, "", surface)) return false;
    focusUrlBar();
    return true;
}
```

- [ ] **Step 5: Add the input handler**

In `src/input.zig`, add after `toggleBrowserPanel` (`input.zig:465`):

```zig
pub fn openJupyterPanel() void {
    const allocator = AppWindow.g_allocator orelse return;
    const parent = AppWindow.currentNativeHandle();
    const surface = AppWindow.activeSurface();
    if (!browser_panel.isVisibleForActiveTab()) AppWindow.hideAiCopilot();
    if (!browser_panel.openJupyterForSurface(allocator, parent, surface)) return;
    if (AppWindow.g_window) |win| {
        syncPanelGridFromWindow(win);
    }
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
}
```

- [ ] **Step 6: Add the dispatch arm**

In `src/renderer/overlays.zig`, next to the `toggle_browser_panel` arm (`overlays.zig:533`):

```zig
        .toggle_browser_panel => AppWindow.input.toggleBrowserPanel(),
        .open_jupyter_panel => AppWindow.input.openJupyterPanel(),
```

- [ ] **Step 7: Add the zh-CN i18n arms**

In `src/i18n.zig`, the title switch over `CommandAction` (next to `.toggle_browser_panel => "切换浏览器"` at `i18n.zig:550`):

```zig
        .toggle_browser_panel => "切换浏览器",
        .open_jupyter_panel => "打开 Jupyter",
```

And the detail switch (next to `i18n.zig:595`):

```zig
        .toggle_browser_panel => "为本地或 SSH 网址打开已配置的浏览器",
        .open_jupyter_panel => "打开面板并粘贴正在运行的 Jupyter 网址（本地或 SSH）",
```

> If the compiler reports any other non-exhaustive `switch` over `CommandAction`, add an arm there too. Known sites: `overlays.zig` dispatch, `i18n.zig` title, `i18n.zig` detail.

- [ ] **Step 8: Run the fast suite to verify it passes**

Run: `zig build test`
Expected: PASS — `findCommandAction("Open Jupyter")` resolves, and all `CommandAction` switches are exhaustive.

- [ ] **Step 9: Run the full suite + macOS cross-compile**

Run: `zig build test-full`
Expected: PASS (no regressions; `ai_chat`/app-graph tests included).
Run: `zig build macos-app -Dtarget=aarch64-macos`
Expected: builds successfully.

- [ ] **Step 10: Commit**

```bash
git add src/command_center_state.zig src/browser_panel.zig src/input.zig src/renderer/overlays.zig src/i18n.zig
git commit -m "feat(jupyter): Open Jupyter command opens panel + focuses URL bar"
```

---

## Task 6: macOS GUI verification (manual)

**Files:** none (manual verification on a real macOS GUI build).

> This is the runtime verification the native bridge cannot get from automated tests. Do not claim the feature works until these pass on device.

- [ ] **Step 1: Build & launch on macOS**

Run: `zig build macos-app -Dtarget=aarch64-macos` (or the native arch), launch the app bundle.

- [ ] **Step 2: Empty panel opens**

Open Command Center (Ctrl+Shift+P) → run **Open Jupyter**. Verify: the right-side panel appears, overlaying the terminal at the correct position/size (coordinate flip + backing scale correct), with the URL bar focused and empty.

- [ ] **Step 3: Local Jupyter renders**

Start `jupyter lab` locally, paste its `http://localhost:8888/lab?token=...` into the URL bar, press Enter. Verify: JupyterLab renders inside the panel (ATS does not block cleartext loopback HTTP).

- [ ] **Step 4: Remote Jupyter renders via tunnel**

From an SSH terminal surface (so `surface.launch_kind == .ssh`), start `jupyter lab` on the remote, paste its `http://localhost:8888/lab?token=...` into the panel owned by that surface, press Enter. Verify: the SSH tunnel is built and JupyterLab renders.

- [ ] **Step 5: Resize / focus / close**

Resize the window and the panel divider — the WKWebView tracks the panel bounds. Click into the webview (it takes focus) and back into the terminal (terminal regains input). Close the panel — the WKWebView is removed cleanly (no leak/crash; `destroy` runs).

- [ ] **Step 6: Record the result**

Note the outcome in the PR description / memory (GUI verified or list of issues). Update `docs/superpowers/specs/2026-06-04-jupyter-panel-design.md` "Status" if the verification changes any decisions.

---

## Self-Review

**Spec coverage:**
- macOS WKWebView backend rendering → Tasks 1–4. ✓
- Thin Jupyter entry point (paste URL, reuse tunnel) → Task 5. ✓
- Connect-only, no lifecycle management → no server-launch code anywhere. ✓
- Windows baseline unchanged → no edits to `webview_windows.zig`/`webview2_bridge.c`; `webview2` arm untouched. ✓
- ATS / coord-flip / scale / focus risks → ATS in Task 1 Step 6; coord/scale in Task 3 `wispterm_webview_frame`; focus in Task 3 `wispterm_webview_macos_focus` + verified in Task 6. ✓
- Linux excluded → no Linux webview code; `.none` backend unchanged. ✓
- Tests: pure logic via `zig build test` / `zig test build.zig`; rendering via Task 6 GUI. ✓

**Placeholder scan:** No TBD/TODO; every code step contains complete code. The only "fill-in-as-needed" note (Task 5 Step 7) lists the exact known switch sites and a deterministic rule (compiler-driven). ✓

**Type consistency:** Bridge symbol names match between `webview_macos.zig` externs and `webview_macos_bridge.m` definitions (`wispterm_webview_macos_*`). Accessor name `wispterm_macos_window_ns_window` matches between the two `.m` files. `Url = [:0]const u8` / `UrlBuffer = [max_url_units]u8` consistent with the unsupported backend the facade test exercises. `CommandAction.open_jupyter_panel`, `findCommandAction("Open Jupyter")`, command entry title `"Open Jupyter"`, dispatch arm, and both i18n arms all use the same identifier/title. ✓
