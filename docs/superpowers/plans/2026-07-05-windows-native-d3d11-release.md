# Windows Native D3D11 Release Channel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merge the Windows native D3D11 renderer to `main` as an opt-in release channel while keeping Windows OpenGL as the default package and retiring the no-WebView package.

**Architecture:** Keep Ghostty's thin comptime backend-selector shape: Windows `auto` remains OpenGL, and D3D11 is selected only by explicit `-Dgpu-backend=d3d11` builds. Packaging produces separate OpenGL default, OpenGL compat, and D3D11 native feedback zips; updater and docs stop selecting or advertising the no-WebView artifact.

**Tech Stack:** Zig 0.15.2, PowerShell packaging, GitHub Actions, Windows D3D11/DXGI backend, docs Cloudflare Worker tests.

**Spec:** `docs/superpowers/specs/2026-07-05-windows-native-d3d11-release-design.md`

---

## Scope Check

This plan covers one release-channel change with several connected surfaces:
renderer branch merge, Windows packaging, release workflow, update package
selection, docs download redirects, and release notes. These must change
together so published assets, updater selection, and docs agree.

The plan does not implement Phase VI default migration. If any step changes
Windows `auto` to D3D11, revert that local edit before continuing.

## File Map

- `src/renderer/gpu/backend.zig` — backend selector tests; Windows `auto` must remain OpenGL.
- `packaging/windows/package.ps1` — local packaging matrix; remove no-WebView staging and add native D3D11 staging.
- `.github/workflows/windows-release.yml` — release validation, zipping, upload, and GitHub release asset list.
- `src/release_package.zig` — platform-neutral release package flavors; remove no-WebView flavor.
- `src/platform/update_package.zig` — package scenario helpers and tests.
- `src/platform/update_package_windows.zig` — Windows asset names and runtime package detection.
- `src/update_check.zig` — asset-selection tests using the package helpers.
- `docs/src/worker.js` and `docs/test/worker.test.js` — latest-download allowlist and tests.
- `.github/workflows/docs-downloads-r2-sync.yml` — latest release asset sync list.
- `docs/development.md` — packaging and release artifact documentation.
- `docs/faq.md` — native/D3D11 feedback guidance.
- `docs/index.html` and `docs/zh.html` — public package labels for default/compat packages.
- `release-notes/v1.32.0.md` — release note entry for native D3D11 feedback package and no-WebView retirement.

## Task 1: Merge Native Renderer Branch and Lock Default Selector

**Files:**
- Modify/merge: all files from `origin/windows-native-render`
- Verify: `src/renderer/gpu/backend.zig`
- Verify: `docs/windows-native-d3d11-default-gate.md`

- [ ] **Step 1: Start from a clean implementation branch**

Run:

```bash
git status --short --branch
git switch -c feat/windows-native-d3d11-release
git fetch origin
```

Expected: only unrelated local files such as `.claude/` may be untracked. Do
not add unrelated files.

- [ ] **Step 2: Merge without committing immediately**

Run:

```bash
git merge --no-ff --no-commit origin/windows-native-render
```

Expected: merge applies or reports conflicts. If conflicts appear, resolve only
by preserving both current `main` changes and the branch's D3D11 implementation;
do not change backend default policy during conflict resolution.

- [ ] **Step 3: Verify Windows default selector is still OpenGL**

Open `src/renderer/gpu/backend.zig` and ensure the tests contain this intent.
If the test is missing or weaker, replace the two backend tests with:

```zig
test "Backend.default maps Darwin to metal, others to opengl while d3d11 is opt-in" {
    try std.testing.expectEqual(Backend.metal, Backend.default(.macos));
    try std.testing.expectEqual(Backend.metal, Backend.default(.ios));
    try std.testing.expectEqual(Backend.opengl, Backend.default(.windows));
    try std.testing.expectEqual(Backend.opengl, Backend.default(.linux));
}

test "Backend.resolve honors explicit d3d11 without changing auto defaults" {
    try std.testing.expectEqual(Backend.opengl, Backend.resolve(.windows, "auto"));
    try std.testing.expectEqual(Backend.metal, Backend.resolve(.macos, "auto"));
    try std.testing.expectEqual(Backend.d3d11, Backend.resolve(.windows, "d3d11"));
    try std.testing.expectEqual(Backend.opengl, Backend.resolve(.windows, "opengl"));
}
```

- [ ] **Step 4: Run fast selector and source-guard tests**

Run:

```bash
zig build test
```

Expected: PASS. If a merge conflict changed source-guard counts, lower ratchets
only when the count shrank; do not raise guard ceilings.

- [ ] **Step 5: Commit the merge**

Run:

```bash
git add .
git commit -m "merge windows native d3d11 renderer"
```

Expected: one merge/implementation commit. Do not include `.claude/`.

## Task 2: Package Script Matrix

**Files:**
- Modify: `packaging/windows/package.ps1`

- [ ] **Step 1: Remove the no-WebView package parameter and add a native skip switch**

In the parameter block, remove:

```powershell
[switch]$SkipNoWebViewBundle,
```

Add this beside the other skip switches:

```powershell
[switch]$SkipNativeD3D11Bundle,
```

- [ ] **Step 2: Replace no-WebView install dir with native install dir**

Replace:

```powershell
$noWebViewInstallDir = Join-Path $repoRoot 'zig-out-no-webview'
```

with:

```powershell
$nativeD3D11InstallDir = Join-Path $repoRoot 'zig-out-native-d3d11'
```

- [ ] **Step 3: Build explicit OpenGL default and optional native D3D11 bundle**

In the non-debug build block, replace the default/no-WebView build body with:

```powershell
& zig build -Doptimize=ReleaseFast -Dgpu-backend=opengl
if ($LASTEXITCODE -ne 0) {
    throw 'zig build -Doptimize=ReleaseFast -Dgpu-backend=opengl failed.'
}
if (-not $SkipNativeD3D11Bundle) {
    Remove-Item -Path $nativeD3D11InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    & zig build -Doptimize=ReleaseFast -Dgpu-backend=d3d11 -p $nativeD3D11InstallDir
    if ($LASTEXITCODE -ne 0) {
        throw 'zig build -Doptimize=ReleaseFast -Dgpu-backend=d3d11 failed.'
    }
}
```

- [ ] **Step 4: Verify native binary path instead of no-WebView binary path**

Replace the no-WebView binary checks with:

```powershell
$nativeD3D11BinaryPath = Join-Path $nativeD3D11InstallDir 'bin\wispterm.exe'
if (-not $SkipNativeD3D11Bundle -and -not (Test-Path $nativeD3D11BinaryPath)) {
    throw "Expected native D3D11 release binary was not found: $nativeD3D11BinaryPath"
}
```

- [ ] **Step 5: Stage native D3D11 dir and remove no-WebView dir**

Replace:

```powershell
$portableNoWebViewDir = Join-Path $resolvedOutputDir 'portable-no-webview'
```

with:

```powershell
$portableNativeD3D11Dir = Join-Path $resolvedOutputDir 'portable-native-d3d11'
```

Update the cleanup call to:

```powershell
Remove-Item -Path $portableDir, $portableCompatDir, $portableNativeD3D11Dir, $installerDir -Recurse -Force -ErrorAction SilentlyContinue
```

Replace the no-WebView copy block with:

```powershell
if (-not $SkipNativeD3D11Bundle) {
    Copy-PortablePayload -BinaryPath $nativeD3D11BinaryPath -TargetDir $portableNativeD3D11Dir -ReleaseVersion $releaseVersion
}
```

- [ ] **Step 6: Update status output**

Replace every no-WebView status print block with:

```powershell
if (-not $SkipNativeD3D11Bundle) {
    Write-Host "Portable native D3D11 build: $(Join-Path $portableNativeD3D11Dir 'wispterm.exe')"
}
```

- [ ] **Step 7: Check the script for stale no-WebView packaging references**

Run:

```bash
rg -n "SkipNoWebView|no-webview|NoWebView|webview=false|portable-no-webview" packaging/windows/package.ps1
```

Expected: no matches.

- [ ] **Step 8: Commit package script change**

Run:

```bash
git add packaging/windows/package.ps1
git commit -m "feat(packaging): add windows native d3d11 bundle"
```

## Task 3: Windows Release Workflow Assets

**Files:**
- Modify: `.github/workflows/windows-release.yml`

- [ ] **Step 1: Replace no-WebView validation variables with native D3D11 variables**

In `Validate packaged outputs`, remove the three `$portableNoWebView...`
variables and add:

```powershell
$portableNativeD3D11Exe = "zig-out\dist\portable-native-d3d11\wispterm.exe"
$portableNativeD3D11Version = "zig-out\dist\portable-native-d3d11\version.txt"
$portableNativeD3D11PluginSkills = "zig-out\dist\portable-native-d3d11\plugins\skills"
```

- [ ] **Step 2: Replace no-WebView validation checks**

Replace the no-WebView checks with:

```powershell
if (!(Test-Path $portableNativeD3D11Exe)) {
  throw "Portable native D3D11 executable not found: $portableNativeD3D11Exe"
}

if (!(Test-Path $portableNativeD3D11Version)) {
  throw "Portable native D3D11 version file not found: $portableNativeD3D11Version"
}

if (!(Test-Path $portableNativeD3D11PluginSkills -PathType Container)) {
  throw "Portable native D3D11 plugin skills directory not found: $portableNativeD3D11PluginSkills"
}
```

Replace the dist-dir loop with:

```powershell
foreach ($distDir in @("zig-out\dist\portable", "zig-out\dist\portable-compat", "zig-out\dist\portable-native-d3d11")) {
```

- [ ] **Step 3: Replace no-WebView asset creation with native D3D11 asset**

In `Create release assets`, replace:

```powershell
$portableNoWebViewAsset = "wispterm-windows-portable-no-webview-$tag.zip"
```

with:

```powershell
$portableNativeD3D11Asset = "wispterm-windows-portable-native-d3d11-$tag.zip"
```

Replace `Remove-Item`, `Compress-Archive`, and later variable references so
they target `$portableNativeD3D11Asset` and:

```powershell
Compress-Archive -Path zig-out\dist\portable-native-d3d11\* -DestinationPath $portableNativeD3D11Asset -Force
```

- [ ] **Step 4: Replace the uploaded artifact**

Replace the no-WebView upload step with:

```yaml
      - name: Upload portable native D3D11 artifact
        uses: actions/upload-artifact@v4
        with:
          name: wispterm-windows-portable-native-d3d11-${{ github.ref_name }}
          path: wispterm-windows-portable-native-d3d11-${{ github.ref_name }}.zip
          if-no-files-found: error
```

- [ ] **Step 5: Publish the native asset and remove no-WebView from release notes**

In `Publish GitHub release`, use:

```powershell
$portableNativeD3D11Asset = "wispterm-windows-portable-native-d3d11-$tag.zip"
```

Validate it with:

```powershell
if (!(Test-Path $portableNativeD3D11Asset)) {
  throw "Portable native D3D11 release asset not found: $portableNativeD3D11Asset"
}
```

Upload/create releases with:

```powershell
gh release upload $tag $portableAsset $portableCompatAsset $portableNativeD3D11Asset $debugAsset --repo $env:GITHUB_REPOSITORY --clobber
```

and:

```powershell
gh release create $tag $portableAsset $portableCompatAsset $portableNativeD3D11Asset $debugAsset `
```

Replace the Windows asset notes with:

```powershell
$assetNotes = @(
  "Windows assets included in this release:",
  "",
  "- Portable: default OpenGL zip archive containing wispterm.exe",
  "- Portable compat: OpenGL zip archive for older Windows 10 machines - bundles WebView2Loader.dll for the embedded browser plus a modern ConPTY (conpty.dll + OpenConsole.exe) so TUI apps like Codex and Claude Code get mouse scrolling and scrollbars",
  "- Portable native D3D11: feedback zip archive using the Windows native D3D11 renderer; use the default Portable asset if you hit rendering issues",
  "- Diagnostic (debug): console build with on-disk logging + crash reports for troubleshooting (ReleaseSafe). See docs/windows-debug-build.md.",
  "",
  "The unsigned IExpress setup executable is not published because Windows Defender can quarantine it as a false positive. Use one of the portable zip assets for now."
) -join "`n"
```

- [ ] **Step 6: Check for stale workflow no-WebView references**

Run:

```bash
rg -n "no-WebView|NoWebView|no-webview|portable-no-webview" .github/workflows/windows-release.yml
```

Expected: no matches.

- [ ] **Step 7: Commit workflow change**

Run:

```bash
git add .github/workflows/windows-release.yml
git commit -m "ci: publish windows native d3d11 artifact"
```

## Task 4: Updater Package Selection

**Files:**
- Modify: `src/release_package.zig`
- Modify: `src/platform/update_package.zig`
- Modify: `src/platform/update_package_windows.zig`
- Modify: `src/update_check.zig`

- [ ] **Step 1: Write the failing package-model tests**

In `src/platform/update_package.zig`, replace the flavor logic test with:

```zig
test "platform update package maps Windows runtime payloads after no-WebView retirement" {
    try std.testing.expectEqual(release_package.Flavor.baseline, runtimeFlavor(false, false));
    try std.testing.expectEqual(release_package.Flavor.compat, runtimeFlavor(false, true));
    try std.testing.expectEqual(release_package.Flavor.compat, runtimeFlavor(true, true));
    try std.testing.expectEqual(release_package.Flavor.baseline, runtimeFlavor(true, false));
    try std.testing.expect(release_package.Package.init(.windows, .compat).requiresEmbeddedBrowserPayload());
}
```

In the asset-name test, remove the no-WebView assertion so only baseline and
compat are expected:

```zig
test "platform update package builds Windows portable asset names" {
    var buf: [128]u8 = undefined;
    const normal = try assetNameForScenario("v0.28.0", .baseline, &buf);
    try std.testing.expectEqualStrings("wispterm-windows-portable-v0.28.0.zip", normal);

    const compat = try assetNameForScenario("v0.28.0", .compat, &buf);
    try std.testing.expectEqualStrings("wispterm-windows-portable-compat-v0.28.0.zip", compat);
}
```

- [ ] **Step 2: Run tests and confirm the old model fails**

Run:

```bash
zig build test
```

Expected: FAIL because `.without_embedded_browser_payload` still exists and
`runtimeFlavor(false, false)` does not return `.baseline` yet.

- [ ] **Step 3: Remove the no-WebView flavor**

In `src/release_package.zig`, replace the flavor enum with:

```zig
pub const Flavor = enum {
    baseline,
    /// Full-featured package for older Windows machines: ships the embedded
    /// browser loader plus a modern bundled console host.
    compat,
};
```

Keep `requiresEmbeddedBrowserPayload()` unchanged:

```zig
pub fn requiresEmbeddedBrowserPayload(self: Package) bool {
    return self.flavor == .compat;
}
```

- [ ] **Step 4: Update Windows runtime package logic**

In both `src/platform/update_package.zig` and
`src/platform/update_package_windows.zig`, replace `runtimeFlavor` with:

```zig
fn runtimeFlavor(webview_enabled: bool, has_compat_payload: bool) release_package.Flavor {
    _ = webview_enabled;
    if (has_compat_payload) return .compat;
    return .baseline;
}
```

In `src/platform/update_package_windows.zig`, remove the
`.without_embedded_browser_payload` arm from `assetNameParts`.

- [ ] **Step 5: Update update_check asset-selection test**

In `src/update_check.zig`, replace `test "update_check: selects portable asset for runtime flavor"` with:

```zig
test "update_check: selects supported Windows portable assets" {
    const tag_name = "v0.28.0";
    var portable_name_buf: [asset_name_buffer_len]u8 = undefined;
    var compat_name_buf: [asset_name_buffer_len]u8 = undefined;
    const portable_package = platform_update_package.packageForScenario(.baseline);
    const compat_package = platform_update_package.packageForScenario(.compat);
    const portable_name = try platform_update_package.assetName(tag_name, portable_package, &portable_name_buf);
    const compat_name = try platform_update_package.assetName(tag_name, compat_package, &compat_name_buf);

    const json = try std.fmt.allocPrint(std.testing.allocator,
        \\{{
        \\  "tag_name":"{s}",
        \\  "html_url":"https://github.com/xuzhougeng/wispterm/releases/tag/{s}",
        \\  "draft":false,
        \\  "prerelease":false,
        \\  "assets":[
        \\    {{"name":"{s}","browser_download_url":"https://example.test/portable.zip","size":11}},
        \\    {{"name":"{s}","browser_download_url":"https://example.test/compat.zip","size":22}}
        \\  ]
        \\}}
    , .{
        tag_name,
        tag_name,
        portable_name,
        compat_name,
    });
    defer std.testing.allocator.free(json);

    const release = try parseLatestRelease(std.testing.allocator, json);
    defer release.deinit(std.testing.allocator);

    const normal = selectReleaseAsset(release, portable_package) orelse return error.ExpectedAsset;
    try std.testing.expectEqualStrings(portable_name, normal.name);
    try std.testing.expectEqualStrings("https://example.test/portable.zip", normal.download_url);
    try std.testing.expectEqual(@as(u64, 11), normal.size);

    const compat = selectReleaseAsset(release, compat_package) orelse return error.ExpectedAsset;
    try std.testing.expectEqualStrings(compat_name, compat.name);
    try std.testing.expectEqualStrings("https://example.test/compat.zip", compat.download_url);
    try std.testing.expectEqual(@as(u64, 22), compat.size);
}
```

- [ ] **Step 6: Check for stale flavor references**

Run:

```bash
rg -n "without_embedded_browser_payload|portable-no-webview|no-webview" src/release_package.zig src/platform/update_package.zig src/platform/update_package_windows.zig src/update_check.zig
```

Expected: no matches.

- [ ] **Step 7: Run update tests**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 8: Commit updater change**

Run:

```bash
git add src/release_package.zig src/platform/update_package.zig src/platform/update_package_windows.zig src/update_check.zig
git commit -m "refactor(update): retire no-webview release flavor"
```

## Task 5: Docs Download Redirects and R2 Sync

**Files:**
- Modify: `docs/src/worker.js`
- Modify: `docs/test/worker.test.js`
- Modify: `.github/workflows/docs-downloads-r2-sync.yml`

- [ ] **Step 1: Remove no-WebView from latest-download allowlist**

In `docs/src/worker.js`, remove:

```js
"wispterm-windows-portable-no-webview.zip",
```

Do not add the native D3D11 package to the public latest-download allowlist yet;
the spec keeps it release-notes-first while collecting feedback.

- [ ] **Step 2: Add a rejection test for retired no-WebView latest URL**

In `docs/test/worker.test.js`, extend the reject test:

```js
test("latestDownloadKey rejects unknown, retired, or nested download paths", () => {
  assert.equal(latestDownloadKey("/downloads/latest/private.zip"), null);
  assert.equal(latestDownloadKey("/downloads/latest/nested/file.zip"), null);
  assert.equal(latestDownloadKey("/downloads/old/wispterm-windows-portable.zip"), null);
  assert.equal(latestDownloadKey("/downloads/latest/wispterm-windows-portable-no-webview.zip"), null);
});
```

- [ ] **Step 3: Remove no-WebView from R2 sync**

In `.github/workflows/docs-downloads-r2-sync.yml`, remove:

```bash
upload_first 'wispterm-windows-portable-no-webview-[0-9v]*.zip' 'wispterm-windows-portable-no-webview.zip' 'application/zip'
```

- [ ] **Step 4: Run docs worker tests**

Run:

```bash
cd docs && node --test test/worker.test.js
```

Expected: PASS.

- [ ] **Step 5: Commit docs download change**

Run:

```bash
git add docs/src/worker.js docs/test/worker.test.js .github/workflows/docs-downloads-r2-sync.yml
git commit -m "docs(downloads): retire no-webview latest asset"
```

## Task 6: User-Facing Docs and Release Notes

**Files:**
- Modify: `docs/development.md`
- Modify: `docs/faq.md`
- Modify: `docs/index.html`
- Modify: `docs/zh.html`
- Modify: `release-notes/v1.32.0.md`

- [ ] **Step 1: Update Windows packaging docs**

In `docs/development.md`, replace the Windows package list with:

```markdown
WispTerm supports three portable Windows packages plus the local installer build:

- `portable` - default OpenGL portable build, run directly without installation
- `portable-compat` - OpenGL portable build for older Windows 10 machines: `WebView2Loader.dll` for the embedded browser plus a bundled modern ConPTY (`conpty.dll` + `OpenConsole.exe`) so TUI apps like Codex get mouse scrolling and scrollbars on old inbox conhosts
- `portable-native-d3d11` - Windows native D3D11 feedback build; use the default `portable` package if it shows rendering issues
- `wispterm-setup.exe` - installer build, installs to the current user's profile and creates a Start menu shortcut
```

Replace the key-output block's no-WebView entries with:

```text
zig-out\dist\portable-native-d3d11\wispterm.exe
zig-out\dist\portable-native-d3d11\version.txt
zig-out\dist\portable-native-d3d11\plugins\...
```

Replace the Windows asset list with:

```markdown
- `wispterm-windows-portable-vX.Y.Z.zip`
- `wispterm-windows-portable-compat-vX.Y.Z.zip`
- `wispterm-windows-portable-native-d3d11-vX.Y.Z.zip`
- `wispterm-windows-debug-vX.Y.Z.zip`
```

Replace the final Windows package recommendation paragraph with:

```markdown
The unsigned IExpress installer is not published for now because Windows
Defender can quarantine it as a false positive. Use the default portable zip
release asset; the `portable-compat` zip when using the embedded browser panel
or on older Windows 10 machines (its bundled ConPTY restores TUI mouse support);
or the `portable-native-d3d11` zip when intentionally testing the Windows native
D3D11 renderer. If the native D3D11 package shows a black window, crash, missing
UI, resize failure, RDP issue, or multi-monitor/DPI issue, switch back to the
default portable package and include diagnostics in the bug report. The bundled
ConPTY is preferred automatically when its files sit next to `wispterm.exe`; set
`windows-conpty = system` in the config to force the OS inbox ConPTY.
```

- [ ] **Step 2: Add FAQ guidance**

In `docs/faq.md`, after the black-window FAQ, add:

```markdown
## Which Windows Package Should I Download?

Use `wispterm-windows-portable-*.zip` by default. It uses the OpenGL renderer
and is the recommended Windows package.

Use `wispterm-windows-portable-compat-*.zip` on older Windows 10 machines or
when you want the embedded browser loader and bundled modern ConPTY next to the
exe.

Use `wispterm-windows-portable-native-d3d11-*.zip` only when you want to test
the Windows native D3D11 renderer and send feedback. If it opens a black window,
crashes, misses UI, fails resize, or behaves badly over RDP, VM, hybrid GPU, or
mixed-DPI monitor setups, switch back to the default OpenGL package. Include a
diagnostic report plus GPU/driver, Windows version, RDP/VM status, hybrid-GPU
status, and monitor/DPI topology when reporting the issue.
```

- [ ] **Step 3: Update public package labels**

In `docs/index.html`, change the compat card badge/title/body to:

```html
<span class="badge">Windows · Compatibility</span>
<h3>Portable compat</h3>
<p>OpenGL build with <code>WebView2Loader.dll</code> and a bundled modern ConPTY for older Windows 10 machines.</p>
```

In `docs/zh.html`, change the same card to:

```html
<span class="badge">Windows · 兼容包</span>
<h3>便携兼容版</h3>
<p>OpenGL 构建，额外捆绑 <code>WebView2Loader.dll</code> 和现代 ConPTY，面向旧版 Windows 10。</p>
```

- [ ] **Step 4: Update release notes**

In `release-notes/v1.32.0.md`, add under English `## Added`:

```markdown
- **Windows native D3D11 feedback package.** Windows releases now include
  `wispterm-windows-portable-native-d3d11-*.zip` for users who want to test the
  native renderer while the default Windows package remains OpenGL.
```

Add under English `## Changed`:

```markdown
- **Windows no-WebView package retired.** Releases no longer publish a separate
  no-WebView zip; use the default OpenGL package unless you need the compat or
  native D3D11 feedback package.
```

Add under Chinese `## 新增`:

```markdown
- **Windows native D3D11 反馈包。** Windows release 现在包含
  `wispterm-windows-portable-native-d3d11-*.zip`，用于测试 native renderer；
  默认 Windows 包仍然使用 OpenGL。
```

Add under Chinese `## 调整`:

```markdown
- **Windows no-WebView 包退役。** Release 不再发布单独的 no-WebView zip；除非需要
  compat 或 native D3D11 反馈包，否则使用默认 OpenGL 包。
```

- [ ] **Step 5: Check docs for stale no-WebView release guidance**

Run:

```bash
rg -n "portable-no-webview|no-WebView|no-webview" docs/development.md docs/faq.md docs/index.html docs/zh.html release-notes/v1.32.0.md
```

Expected: no matches.

- [ ] **Step 6: Commit docs change**

Run:

```bash
git add docs/development.md docs/faq.md docs/index.html docs/zh.html release-notes/v1.32.0.md
git commit -m "docs: document windows native d3d11 release channel"
```

## Task 7: Verification and Release Gate

**Files:**
- Verify: repository tests and packaging outputs

- [ ] **Step 1: Run fast and full Zig gates**

Run:

```bash
zig build check-sizes
zig build test
zig build test-full --summary all
```

Expected: PASS.

- [ ] **Step 2: Run docs worker tests**

Run:

```bash
cd docs && node --test test/worker.test.js
```

Expected: PASS.

- [ ] **Step 3: Run Windows package build on Windows PowerShell**

Run on Windows:

```powershell
powershell -ExecutionPolicy Bypass -File .\packaging\windows\package.ps1 -Version v1.32.0 -SkipInstaller
```

Expected outputs:

```text
zig-out\dist\portable\wispterm.exe
zig-out\dist\portable-compat\wispterm.exe
zig-out\dist\portable-native-d3d11\wispterm.exe
```

Expected absent:

```text
zig-out\dist\portable-no-webview\wispterm.exe
```

- [ ] **Step 4: Run Windows renderer smokes**

Run on Windows:

```powershell
zig build -Dgpu-backend=d3d11
powershell -NoProfile -ExecutionPolicy Bypass -File .\debug\test-d3d11-normal-session.ps1
zig build -Dgpu-backend=opengl
powershell -NoProfile -ExecutionPolicy Bypass -File .\debug\test-d3d11-normal-session.ps1 -Backend opengl
```

Expected: D3D11 smoke passes for the native feedback path, and OpenGL smoke
passes for the default/fallback path.

- [ ] **Step 5: Run Windows checkout-safety checks**

Run the PowerShell snippet from `docs/development.md#Windows Checkout Safety`.
Expected:

```text
windows_name_violations=0
casefold_collisions=0
```

Also run:

```powershell
git ls-files -s | Select-String '^120000'
```

Expected: no output.

- [ ] **Step 6: Final stale-reference scans**

Run:

```bash
rg -n "portable-no-webview|wispterm-windows-portable-no-webview|SkipNoWebView|NoWebView" .github packaging src docs release-notes
```

Expected: only historical notes in old release notes or old plans/specs may
remain. There must be no matches in active code, workflows, packaging scripts,
current docs, or `release-notes/v1.32.0.md`.

Run:

```bash
rg -n "Backend.default\\(.windows\\).*d3d11|expectEqual\\(Backend.d3d11, Backend.default\\(.windows\\)" src/renderer/gpu/backend.zig
```

Expected: no matches.

- [ ] **Step 7: Commit verification notes if docs changed during verification**

If verification required documentation updates, commit them:

```bash
git add docs release-notes
git commit -m "docs: finalize windows release packaging notes"
```

If no files changed, do not create an empty commit.

## Self-Review

- **Spec coverage:** merge boundary is Task 1; Windows package matrix is Tasks
  2-3; no-WebView retirement is Tasks 2-6; user guidance is Task 6; rollback
  remains operational because Task 1 keeps Windows `auto` on OpenGL; validation
  is Task 7.
- **Placeholder scan:** no TBD/TODO/fill-in placeholders are used. Versioned
  release note target is `release-notes/v1.32.0.md`, matching the requested
  release tag.
- **Type consistency:** package flavor names are `.baseline` and `.compat`
  after Task 4; native D3D11 is a packaging artifact, not a
  `release_package.Flavor`, so the updater will not auto-select it.
