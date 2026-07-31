# Windows native D3D11 release channel

**Date:** 2026-07-05
**Status:** Approved

## Problem

The `windows-native-render` integration branch contains a real Windows native
D3D11 renderer path plus Phase V smoke, environment, fallback-marker, and audit
tools. The next release should let Windows users try that native path and send
field feedback, but it should not change the default Windows renderer yet.

The current Windows release matrix also still includes a `portable-no-webview`
package. That package is no longer worth carrying as a separate release flavor:
it increases release, updater, docs, and download-surface complexity while the
normal package is the path users should take.

## Goals

- Merge the Windows native GPU work to `main` without changing the Windows
  `auto` renderer default.
- Keep OpenGL as the default Windows release package.
- Add a separate Windows native/D3D11 feedback package.
- Keep the existing compat package for older Windows and bundled runtime
  compatibility.
- Stop building and publishing the no-WebView Windows package.
- Make user-facing docs and release notes explain which package to choose and
  how to report D3D11 feedback.

## Non-goals

- Do not make D3D11 the Windows `auto` default in this change.
- Do not add runtime renderer switching inside one binary.
- Do not add same-process D3D11-to-OpenGL fallback.
- Do not change macOS or Linux release packaging.
- Do not change `remote/` version surfaces.

## Decisions

1. Windows `auto` continues to resolve to OpenGL.
2. D3D11 is built explicitly with `-Dgpu-backend=d3d11`.
3. The default Windows portable zip remains the recommended OpenGL download.
4. The compat zip remains OpenGL and keeps WebView2/ConPTY bundled payloads.
5. A new native zip is published for D3D11 feedback.
6. The no-WebView zip is retired from packaging, workflows, docs, download
   redirects, and update package selection.

## Ghostty comparison

Ghostty keeps renderer selection thin: `renderer/backend.zig` exposes a
`Backend` enum and a small default selector. WebAssembly selects WebGL, Darwin
selects Metal, and other native targets select OpenGL. Ghostty does not have a
D3D11 renderer, DXGI device-loss policy, Windows fallback markers, or a Windows
environment matrix to copy.

WispTerm should keep that Ghostty-style boundary: a comptime backend selector
and parallel backend implementations. The Windows D3D11 renderer, package
channel, fallback-marker evidence, and environment-matrix evidence are
WispTerm-specific release hardening around that boundary, not a reason to grow
the generic renderer selector into runtime policy.

## Current state

On `main`, the build already accepts `-Dgpu-backend=auto|opengl|metal|d3d11`,
and `src/renderer/gpu/backend.zig` still resolves Windows `auto` to OpenGL.
The release packaging script currently builds the normal package and a
`-Dwebview=false` no-WebView package, then stages `portable`,
`portable-compat`, and `portable-no-webview`.

On `origin/windows-native-render`, the native renderer branch adds D3D11
runtime hardening, smoke scripts, environment matrix collection, default-gate
audit docs, and checked-in Phase V evidence scaffolding. Its own gate document
states that Windows `auto` remains OpenGL until a later small Phase VI default
migration PR.

## Design

### 1. Merge boundary

Merge the native renderer implementation and its diagnostics/gate assets, but
keep the default selector unchanged:

```zig
Backend.default(.windows) == .opengl
Backend.resolve(.windows, "d3d11") == .d3d11
```

The Phase VI default switch remains a future, small, revertible change after
the D3D11 evidence gate is satisfied. The implementation merge can be large;
the default-policy change must stay out of it.

### 2. Windows release artifacts

Windows releases publish these portable artifacts:

| Artifact | Build | Purpose |
|---|---|---|
| `wispterm-windows-portable-<tag>.zip` | `zig build -Doptimize=ReleaseFast -Dgpu-backend=opengl` | Default recommended Windows package. |
| `wispterm-windows-portable-compat-<tag>.zip` | OpenGL build plus bundled WebView2/ConPTY payloads | Older Windows / compatibility package. |
| `wispterm-windows-portable-native-d3d11-<tag>.zip` | `zig build -Doptimize=ReleaseFast -Dgpu-backend=d3d11` | Native GPU feedback package. |

The installer continues to stage the default OpenGL binary unless a later
release decision says otherwise.

### 3. Retire no-WebView packaging

Remove `portable-no-webview` from the active release path:

- `packaging/windows/package.ps1` no longer builds `-Dwebview=false` by
  default and no longer stages `portable-no-webview`.
- `.github/workflows/windows-release.yml` stops validating, zipping, uploading,
  and publishing `wispterm-windows-portable-no-webview-<tag>.zip`.
- `docs/development.md`, `docs/src/worker.js`, `docs/test/worker.test.js`,
  and the R2 download sync workflow stop advertising or syncing the no-WebView
  asset.
- `src/platform/update_package_windows.zig` and related tests stop selecting a
  no-WebView release asset for future releases.

The compile-time `-Dwebview=false` option may remain as a developer/test build
escape hatch. Retiring the package does not need to delete the build option.

### 4. Native package naming and runtime identity

Use `native-d3d11` in the asset name rather than overloading the default
portable package. The name should make the risk and purpose obvious in release
notes and download links.

Inside the app, existing version surfaces continue to report the desktop app
version from `build.zig.zon`. The backend identity is already available through
`build_options.gpu_backend` and benchmark/diagnostic reporting; do not create a
second version number for the native package.

### 5. User-facing guidance

Release notes and FAQ should say:

- OpenGL is still the default Windows renderer.
- The native/D3D11 package is a feedback build for Windows GPU coverage.
- If native/D3D11 shows a black window, crash, missing UI, resize failure, RDP
  failure, or multi-monitor/DPI issue, switch back to the OpenGL package.
- Bug reports should include the diagnostic report, GPU/driver, Windows
  version, RDP/VM status, hybrid-GPU status, and monitor/DPI topology.

The public docs download cards should continue to emphasize the default and
compat packages. The native package can be linked from release notes first; a
homepage callout can wait until feedback is healthy.

### 6. Rollback

Rollback is operational first:

- Stop recommending or publishing the native/D3D11 package if field feedback is
  bad.
- Keep the default OpenGL and compat packages available.
- Do not revert the D3D11 implementation unless a regression affects the
  OpenGL path or shared renderer behavior.

Because Windows `auto` remains OpenGL, package rollback does not require a
selector revert.

## Testing

- Build gates: `zig build check-sizes`, `zig build test`,
  `zig build test-full --summary all`, and the Windows release workflow.
- Renderer gates before publishing the native package:
  - `zig build -Dgpu-backend=d3d11`
  - `debug/test-d3d11-normal-session.ps1`
  - relevant Phase V smoke modes already documented in
    `docs/windows-native-d3d11-default-gate.md`
- OpenGL fallback proof on the same branch:
  - `zig build -Dgpu-backend=opengl`
  - normal Windows UI smoke with `-Backend opengl`
- Packaging proof:
  - default portable zip contains the OpenGL binary and normal payload.
  - compat zip contains the OpenGL binary plus WebView2/ConPTY payloads.
  - native zip contains the D3D11 binary and normal payload.
  - no-WebView zip is not produced, uploaded, synced, or selected by updater
    logic.

## Risks

- The native branch has broad UI/layout and diagnostics changes. Keep default
  policy and release packaging changes reviewable so regressions can be
  isolated.
- Users may assume "native" is the recommended build. Mitigate with asset name,
  release notes, and docs that call it a feedback package.
- Removing no-WebView affects users who depended on that artifact. Keep
  `-Dwebview=false` buildability for developers, but stop carrying it as a
  release flavor unless there is concrete demand.

