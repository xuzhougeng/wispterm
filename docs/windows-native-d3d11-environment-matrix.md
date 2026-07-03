# Windows Native D3D11 Environment Matrix

This is the Phase V evidence ledger for Windows native D3D11 environment
coverage. It records evidence requirements and the JSON fields emitted by
`debug/test-d3d11-environment-smoke.ps1`; it is not a default migration plan.
Windows `auto` remains OpenGL until the separate Phase VI gate is satisfied.

## Boundary

- The collector records facts only. It does not block environments, write
  fallback markers, or change renderer selection.
- A skipped or unavailable environment is missing evidence, not a pass.
- Keep generated artifacts outside the repository unless a PR or issue asks for
  a small redacted sample. The durable record should point to the artifact
  directory or uploaded artifact, and should include the generated
  `matrix-summary.md` when possible.
- `-RequireMatrixClass` is optional and should be used only when the class can
  be proven from collected facts.

## Ghostty Comparison

Ghostty's renderer backend selector remains a thin `Backend` enum with OpenGL,
Metal, and WebGL defaults. It has no D3D11 backend, DXGI device-loss policy, or
Windows environment matrix to mirror. WispTerm keeps the Ghostty-style thin
backend boundary while treating RDP, VM, hybrid-GPU, weak-iGPU, monitor, and DPI
evidence as Windows-specific Phase V hardening.

## Matrix Classes

Use `-MatrixClass` to label the environment being recorded:

| Matrix class | Match source | Evidence expectation |
|---|---|---|
| `local-physical` | Remote session is false and no VM adapter candidate is detected. | Baseline physical Windows evidence. |
| `rdp` | Win32 remote-session diagnostic is true. | No black window, recovery loop, or unexpected fallback activity. |
| `virtual-machine` | Adapter description/flags suggest a virtual or software adapter. | Adapter/session facts are recorded; failures are classified in the issue/PR. |
| `hybrid-gpu` | Operator-declared; single-adapter diagnostics cannot prove topology. | Adapter identity is stable enough for fallback-marker scoping. |
| `weak-integrated-gpu` | Integrated adapter candidate with <= 1 GiB dedicated video memory. | Feature level and memory facts are recorded; unhealthy modes are classified. |
| `single-monitor` | Monitor count is 1. | Baseline smoke evidence. |
| `multi-monitor-same-dpi` | Monitor count > 1 and mixed DPI is false. | Resize/window evidence remains nonblank after monitor moves when available. |
| `multi-monitor-mixed-dpi` | Monitor count > 1 and mixed DPI is true. | DPI facts are recorded; failures are classified and documented. |

`hybrid-gpu` deliberately reports `class_match = null` because a single DXGI
adapter line cannot prove the machine has both integrated and discrete GPUs.

## Collector Commands

```powershell
zig build -Dgpu-backend=d3d11
powershell -NoProfile -ExecutionPolicy Bypass -File .\debug\test-d3d11-environment-smoke.ps1 -MatrixClass local-physical
```

For automatically provable classes, add `-RequireMatrixClass` when you want the
collector to fail if the requested class does not match the detected facts:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\debug\test-d3d11-environment-smoke.ps1 -MatrixClass rdp -RequireMatrixClass
```

## JSON Contract

Each collector run writes both `environment.json` and a redacted
`matrix-summary.md` review artifact. `environment.json` contains:

| Field | Meaning |
|---|---|
| `matrix.requested_class` | The operator-supplied `-MatrixClass`. |
| `matrix.class_match` | `true`, `false`, or `null` when the class cannot be proven automatically. |
| `matrix.require_class_match` | Whether mismatch was configured to fail the run. |
| `matrix.detection.remote_session` | Win32 remote-session fact. |
| `matrix.detection.monitor_count` / `mixed_dpi` | Monitor topology facts used for monitor classes. |
| `matrix.detection.virtual_machine_candidate` | Heuristic adapter/software-adapter classification. |
| `matrix.detection.integrated_gpu_candidate` | Heuristic integrated-GPU adapter classification. |
| `matrix.detection.weak_integrated_gpu_candidate` | Integrated adapter with low dedicated video memory. |
| `policy.environment_classification` | Always `record-only` during Phase V. |
| `policy.environment_blocking` | Always `false` during Phase V. |

`matrix-summary.md` is derived from the same JSON and is intended for PR or
issue comments. It includes branch/commit, requested matrix class, class-match
state, adapter facts, monitor/DPI facts, smoke health, and record-only policy
fields, without copying raw diagnostic log lines.

## Ledger

| Environment class | Status | Evidence |
|---|---|---|
| Local physical Windows machine | Missing | Collect with `-MatrixClass local-physical`. |
| RDP session | Missing | Collect with `-MatrixClass rdp -RequireMatrixClass`. |
| Virtual machine | Missing | Collect with `-MatrixClass virtual-machine`; attach adapter facts. |
| Hybrid GPU laptop | Missing | Collect with `-MatrixClass hybrid-gpu`; record operator-observed topology. |
| Weak integrated GPU | Missing | Collect with `-MatrixClass weak-integrated-gpu`; attach memory/feature-level facts. |
| Single monitor | Missing | Collect with `-MatrixClass single-monitor -RequireMatrixClass`. |
| Multi-monitor same DPI | Missing | Collect with `-MatrixClass multi-monitor-same-dpi -RequireMatrixClass`. |
| Multi-monitor mixed DPI | Missing | Collect with `-MatrixClass multi-monitor-mixed-dpi -RequireMatrixClass`. |

Phase VI must not start until this ledger is backed by current artifacts or the
remaining gaps are explicitly accepted in `KNOWN_ISSUES.md`.
