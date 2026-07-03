# Windows Native D3D11 Default Migration Gate

This document is the Phase V closeout gate for making the Windows native D3D11
renderer eligible for a later Phase VI default migration. It is deliberately not
a release announcement and not a default change. Windows `auto` remains OpenGL
until a separate, small, easily revertible Phase VI PR changes that behavior.

## Current Boundary

- Explicit `d3d11` is the only way to run the native D3D11 backend today.
- Windows `auto` still resolves to OpenGL.
- The OpenGL + DXGI present path remains the compatibility fallback.
- D3D11 fallback is next-launch/future-auto policy; there is no same-process
  D3D11-to-OpenGL renderer switch.
- A matching `d3d11-fallback` marker may influence future-auto dry-run
  decisions, but it must not silently override explicit `d3d11`.

## Ghostty Comparison

Ghostty keeps renderer backend selection as a small backend enum and default
selector: WebAssembly uses WebGL, Darwin uses Metal, and other native targets
use OpenGL. Ghostty does not have a D3D11 backend, DXGI device-loss recovery, or
a Windows fallback marker model to copy.

WispTerm should keep Ghostty's thin backend boundary shape while treating
Windows D3D11 reliability, fallback markers, Win32 window state, and environment
classification as WispTerm-specific Phase V hardening work.

## Required Evidence

Before Phase VI can start, keep evidence for each item below. A skipped or
unavailable environment is missing evidence, not a passing result.

| Gate | Required evidence |
|---|---|
| D3D11 normal session | `debug/test-d3d11-normal-session.ps1` passes after `zig build -Dgpu-backend=d3d11`. |
| Device recreate success | `-RecreateSmoke` records exactly one successful recreate/restore path. |
| Device recreate failure | `-RecreateFailureSmoke` escalates exactly once to a fallback candidate and writes a marker. |
| Fallback marker policy | `-FallbackMarkerSmoke` proves explicit D3D11 still wins, current auto stays OpenGL, and future-auto would select OpenGL from a matching marker. |
| Future-auto dry-run | `-AutoDryRunSmoke` proves current auto, future eligible D3D11, matching-marker OpenGL, explicit D3D11, explicit OpenGL, and stale-marker selector outcomes. |
| OpenGL fallback | `zig build` plus `-Backend opengl` proves the compatibility renderer still runs the normal-session UI subset. |
| Rapid resize | `-RapidResizeSmoke` proves nonblank frames, resize diagnostics, and no resize/present failures. |
| Window state | `-WindowStateSmoke` proves maximize, restore, minimize, and restore-from-minimize. |
| Fullscreen startup | `-FullscreenStartupSmoke` proves config startup fullscreen, Alt+Enter exit, and restored baseline size. |
| Long-run soak | `-SoakMinutes 20` records periodic nonblank screenshots, process liveness, resize diagnostics, and no failure lines. |
| Environment package | `debug/test-d3d11-environment-smoke.ps1` emits `environment.json`, normal-session JSON, screenshots, adapter facts, Win32 session facts, and policy fields. |
| Test gates | `zig build check-sizes`, `zig build test`, `zig build test-full --summary all`, `zig build`, and PR CI pass. |

## Environment Matrix

The matrix evidence should cover at least these classes before default
migration. Use the environment collector for each run and keep the generated
artifact directory with the PR or issue that records the result.

| Environment class | Evidence expectation |
|---|---|
| Local physical Windows machine | D3D11 normal, resize/window/fullscreen, and soak evidence. |
| RDP session | Environment facts classify the remote session and the app does not black-window or loop recovery. |
| Virtual machine | Adapter/session facts are recorded; failures are classified rather than silent. |
| Hybrid GPU laptop | Adapter identity is stable enough for marker scoping. |
| Weak integrated GPU | Feature level and memory facts are recorded; failure mode is classified if unhealthy. |
| Single monitor | Baseline smoke evidence. |
| Multi-monitor same DPI | Resize/window evidence remains nonblank after monitor moves when available. |
| Multi-monitor mixed DPI | DPI facts are recorded; failures are classified and documented. |

## Phase VI Entry Conditions

Phase VI may start only when all of these are true:

1. The required evidence table is complete.
2. Matrix gaps are either closed or explicitly accepted in `KNOWN_ISSUES.md`.
3. No healthy-path D3D11 smoke records present failure, resize sync failure,
   shader compile failure, backbuffer probe failure, unexpected recovery, or
   fallback marker writes.
4. OpenGL fallback still passes its normal-session smoke on the same branch.
5. The future-auto dry-run explains each selector outcome: D3D11 eligible,
   OpenGL from marker, OpenGL from explicit selection, and stale marker ignored.
6. The Phase VI default migration is a separate PR that only changes selector
   policy and documentation needed for that policy.
7. Reverting the Phase VI PR restores Windows `auto` to OpenGL without reverting
   the native renderer implementation.

## Phase VI PR Rules

The Phase VI PR must be small. It may update selector policy, tests, user docs,
release notes, and troubleshooting text. It must not combine the default change
with renderer rewrites, fallback architecture changes, or unrelated features.

The PR body must include:

- exact commit or branch where Phase V evidence was collected
- environment matrix summary
- fallback marker behavior
- how to force OpenGL
- how to force D3D11
- how to clear or inspect a fallback marker
- rollback command or revert plan

## Operator Commands

```powershell
zig build -Dgpu-backend=d3d11
powershell -NoProfile -ExecutionPolicy Bypass -File .\debug\test-d3d11-normal-session.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\debug\test-d3d11-normal-session.ps1 -RecreateSmoke
powershell -NoProfile -ExecutionPolicy Bypass -File .\debug\test-d3d11-normal-session.ps1 -RecreateFailureSmoke
powershell -NoProfile -ExecutionPolicy Bypass -File .\debug\test-d3d11-normal-session.ps1 -FallbackMarkerSmoke
powershell -NoProfile -ExecutionPolicy Bypass -File .\debug\test-d3d11-normal-session.ps1 -AutoDryRunSmoke
powershell -NoProfile -ExecutionPolicy Bypass -File .\debug\test-d3d11-normal-session.ps1 -RapidResizeSmoke
powershell -NoProfile -ExecutionPolicy Bypass -File .\debug\test-d3d11-normal-session.ps1 -WindowStateSmoke
powershell -NoProfile -ExecutionPolicy Bypass -File .\debug\test-d3d11-normal-session.ps1 -FullscreenStartupSmoke
powershell -NoProfile -ExecutionPolicy Bypass -File .\debug\test-d3d11-normal-session.ps1 -SoakMinutes 20
powershell -NoProfile -ExecutionPolicy Bypass -File .\debug\test-d3d11-environment-smoke.ps1

zig build
powershell -NoProfile -ExecutionPolicy Bypass -File .\debug\test-d3d11-normal-session.ps1 -Backend opengl

zig build check-sizes
zig build test
zig build test-full --summary all
```

## Rollback Rule

If D3D11 becomes the Windows `auto` default and a post-merge regression appears,
the first rollback should revert only the Phase VI selector/default PR. Do not
revert the Phase I-V renderer implementation unless the bug is proven to live
outside the selector/default policy.
