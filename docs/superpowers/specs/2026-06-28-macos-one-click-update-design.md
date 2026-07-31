# macOS One-Click Update Design

## Context

Phantty already has the full *check + download* half of the macOS update
story; only the *install* step is missing.

- `src/update_check.zig` polls GitHub Releases on startup (gated by
  `auto-update-check`), compares semantic versions, and drives a state machine:
  `idle → checking → up_to_date | update_available | downloading → downloaded |
  download_failed | failed`.
- `src/update_install.zig` downloads the release asset to `~/Downloads` using a
  `.part`-then-rename atomic write. It stops there.
- `src/platform/update_package_macos.zig` names the macOS asset
  `wispterm-macos-<tag>.dmg`. CI (`.github/workflows/macos-release*.yml`)
  produces signed + notarized DMGs per arch and uploads them to GitHub Releases.
- The app bundle is `WispTerm.app` (`com.wispterm.terminal`), built by
  `zig build macos-app`, signed/notarized by `packaging/macos/package.sh`.

Today, after `downloaded`, the user must mount the DMG, drag `WispTerm.app`
into Applications, replace, and relaunch by hand. This feature automates that
last mile with **one click**.

`ROADMAP.md` and `packaging/macos/README.md` reserve a full Sparkle-style
unattended updater for later. This design deliberately does **not** introduce
Sparkle, a new build artifact, or a background resident updater.

## Goals

- After a macOS DMG is downloaded, offer a single **"立即更新"** action that
  swaps the running `WispTerm.app` with the new one and relaunches it.
- Reuse the existing check/download flow and state machine; add only the
  install step.
- Verify the downloaded app's code signature before swapping (download
  integrity at a trust boundary — not optional).
- Fall back cleanly to today's manual behavior when an automatic swap is not
  safe or possible.

## Non-Goals

- No Sparkle, no appcast, no EdDSA feed.
- No unattended/silent background install; the user still clicks once.
- No rollback subsystem (a known ceiling — see Error Handling).
- No new build target or helper binary; the helper is a generated shell script.
- Windows is unchanged and out of scope.

## User Experience

When the state reaches `downloaded` on macOS, the existing prompt (toast +
command-center entry) gains an action: **"立即更新"**.

On click:

1. Brief status: `正在安装更新…`
2. The app quits and is replaced; the new version relaunches automatically.

If the swap cannot proceed safely (see Eligibility), the action instead falls
back to today's behavior — reveal the downloaded DMG in Finder with a message
like `请手动安装：已在「下载」中打开 DMG`. The user is never left worse off
than the current flow.

No new config option: the trigger is an explicit user click, so
`auto-update-check` already governs whether the prompt appears at all.

## Eligibility (when one-click is offered)

The "立即更新" action performs the swap only when **all** hold; otherwise it
falls back to reveal-in-Finder:

- `builtin.os.tag == .macos`.
- The running executable resolves up to a `*.app` bundle (not a bare binary /
  dev build run from `zig-out/bin`).
- That `.app` directory is writable by the current user.
- The downloaded DMG exists at the known Downloads path and mounts.
- The mounted DMG contains `WispTerm.app` and `codesign --verify --deep
  --strict` on it succeeds.

Determining the running bundle: resolve the executable path
(`std.fs.selfExePathAlloc`), then walk up parents until a component ends in
`.app`; the bundle is `<…>.app` (the parent of `Contents/MacOS/WispTerm`).

## Architecture

Add `src/platform/update_apply_macos.zig` — pure-ish orchestration over a few
shell/process steps. It exposes one entry point called from the existing
`downloaded`-state handler when the user clicks "立即更新":

```
applyMacosUpdate(allocator, dmg_path, running_bundle_path) !Outcome
```

Steps:

1. **Mount** — `hdiutil attach -nobrowse -readonly <dmg>`; parse the mount
   point from its output.
2. **Locate** — find `WispTerm.app` at the mount point.
3. **Verify** — `codesign --verify --deep --strict <mounted>/WispTerm.app`.
   On failure: detach, return `.verify_failed` → caller falls back.
4. **Stage helper** — write a small shell script to a temp dir
   (`std.fs.path` + Downloads/tmp). The script is the only thing that outlives
   the app, so the swap happens after the app exits.
5. **Launch helper detached** — spawn via `/bin/sh <script>` with
   stdin/stdout/stderr detached so it survives the parent exiting (set up so
   it is not reaped when the app quits).
6. **Quit** — the app initiates its normal shutdown; the helper waits for the
   PID to disappear, then swaps.

The generated helper script (parameters substituted in by Zig):

```sh
#!/bin/sh
# wait for the old app to fully exit
while kill -0 "$APP_PID" 2>/dev/null; do sleep 0.2; done
# atomic-ish replace, preserving xattrs / signature / quarantine state
ditto "$NEW_APP" "$DST_APP.new" && \
  rm -rf "$DST_APP" && \
  mv "$DST_APP.new" "$DST_APP"
hdiutil detach "$MOUNT_POINT" -quiet || true
open "$DST_APP"
```

Notes:
- `ditto` preserves extended attributes; because the new app is notarized,
  Gatekeeper still trusts it after the swap (consistent with the user's point
  that the app is already macOS-approved).
- `rm -rf` + `mv` keeps the destination valid for the largest window possible;
  staging the copy as `.new` first means a failed `ditto` never deletes the
  working app.

Wiring: the existing UI layer that renders the `downloaded` prompt adds the
"立即更新" entry; its handler calls `applyMacosUpdate`. The macOS quit path is
reused (no new shutdown logic). On non-macOS the entry is absent.

## Error Handling

- Any step before the app quits that fails (mount, locate, verify, helper
  staging/launch) → detach if mounted, surface the reveal-in-Finder fallback,
  app keeps running. No partial state.
- After the app quits, the helper owns correctness. If `ditto` fails, it leaves
  the original app untouched (the swap only `rm`s the old app *after* a
  successful staged copy) and still runs `open "$DST_APP"`, so the user is
  relaunched into the existing (old) version rather than a broken one.
- ponytail: no rollback ledger / no crash reporting from the helper. The
  staged-copy-then-swap ordering is the ceiling; add a real updater binary
  (planned method B / Sparkle) if unattended install or rollback is ever
  required.

## Testing

Network/process/`hdiutil` steps are not unit-testable in CI, matching the
existing `update_install.zig` convention. Cover the pure logic with unit tests:

- bundle resolution: an executable path inside `…/WispTerm.app/Contents/MacOS/`
  resolves to the `.app`; a bare-binary path resolves to `null` (→ fallback).
- eligibility gating returns fallback when not run from a `.app`.
- helper-script generation substitutes the four params correctly and is valid
  `sh` (assert on the rendered string).

Manual verification (the real check): install a signed build, publish a newer
tagged release, let the app download it, click "立即更新", confirm the app
swaps and relaunches into the new version. Also verify the fallback path by
running from `zig-out/bin` (no `.app`).

Build verification: `zig build test` and
`zig build test-full -Dtarget=aarch64-macos`.

## Open Decisions

None. Scope is one-click swap + auto-relaunch via a detached shell helper, with
reveal-in-Finder fallback; no Sparkle, no rollback, no new binary.
