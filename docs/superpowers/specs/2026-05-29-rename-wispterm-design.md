# Rename Phantty → WispTerm — Design

**Date:** 2026-05-29
**Status:** Approved (design), pending implementation plan

## Goal

Rename the project from **Phantty** to **WispTerm** comprehensively: source
identifiers, config directory, binary, package name, assets, packaging, website,
docs, and the bundled skills. Replace the app icon with the user-supplied
`wispterm.png`. Update the README intro. Historical records are preserved.

## Naming scheme

| Context | Old | New |
|---|---|---|
| Display name / titles / prose | `Phantty` | `WispTerm` |
| All-caps | `PHANTTY` | `WISPTERM` |
| Lowercase identifier / binary / config dir | `phantty` | `wispterm` |
| Zig package name (`build.zig.zon`) | `.name = .phantty` | `.name = .wispterm` |
| Config dir | `~/.config/phantty`, `%APPDATA%\phantty`, `~/Library/Application Support/phantty` | `…/wispterm` |
| Portable config file | `phantty.conf` | `wispterm.conf` |
| Binary | `phantty` / `phantty.exe` | `wispterm` / `wispterm.exe` |
| macOS bundle id | `com.phantty.terminal` | `com.wispterm.terminal` |
| macOS app / icon | `Phantty.app` / `Phantty.icns` | `WispTerm.app` / `WispTerm.icns` |
| Own GitHub repo URLs | `xuzhougeng/phantty` | `xuzhougeng/wispterm` |

## Behavior-critical changes (must be exact)

These affect runtime behavior, not just text:

- `src/app_metadata.zig`: display `name`, plus the build metadata `executable_name`
  and `bundle_identifier` (in `build.zig`).
- `src/platform/dirs.zig`: `app_dir_name = "phantty"` → `"wispterm"`,
  `portable_config_basename = "phantty.conf"` → `"wispterm.conf"`, and every test
  assertion that hardcodes these (including the `/tmp/phantty-test-config` override
  constant and path-suffix expectations).
- `src/update_check.zig`, `src/skill_update.zig`, `src/renderer/overlays.zig`: all
  `xuzhougeng/phantty` → `xuzhougeng/wispterm` (auto-update API/page URLs, skill
  download tree/raw URLs, SSH help URL), and the test fixtures asserting those URLs.
- `build.zig.zon`: `.name = .phantty` → `.name = .wispterm`. If Zig rejects the
  existing `.fingerprint` after the name change, regenerate it using the value Zig
  prints (the build will tell us).
- `build.zig`: executable name(s), `bundle_identifier`, icon paths
  (`assets/phantty.icns`, `Phantty.app/...`), test-step names (`phantty-*-test` →
  `wispterm-*-test`, `phantty-clean-macos-app` → `wispterm-clean-macos-app`), and
  the `@embedFile` anonymous-import names `phantty_doc_*` → `wispterm_doc_*` (kept in
  sync with `src/wispterm_docs.zig`).

## Config migration: none

Per decision, the config dir is renamed with **no migration**. Existing users'
`~/.config/phantty` (etc.) is simply not read; WispTerm starts with fresh defaults.
No migration code is added.

## File renames (`git mv`)

- `src/phantty_docs.zig` → `src/wispterm_docs.zig` (update all imports/references).
- `assets/phantty.{rc,png,ico,icns}` → `assets/wispterm.*` (regenerated from the new
  icon — see Icon section; the `.rc`/build references updated).
- `assets/phantty.aseprite`: **removed from the icon pipeline** (it is the editable
  source for the old icon and does not correspond to the new artwork). Not carried
  forward as a wispterm asset.
- `docs/assets/phantty.png` → `docs/assets/wispterm.png` (regenerated).
- `packaging/windows/Install-Phantty.ps1` → `Install-WispTerm.ps1`.
- `packaging/macos/Phantty.entitlements` → `WispTerm.entitlements`.
- `plugins/skills/phantty-diagnostics/` → `plugins/skills/wispterm-diagnostics/`,
  including `collect_phantty_diagnostics.ps1` → `collect_wispterm_diagnostics.ps1`
  and the skill's content.

## Icon generation (from user-supplied `wispterm.png`)

Source: `wispterm.png`, 1448×1086, RGB, no alpha — a centered rounded-square icon on
a near-black canvas. A single Pillow script (Pillow 11.1 is installed; no
ImageMagick required) produces the assets, matching the existing icon size specs:

1. Center-crop to a square (1086×1086, cropping the wider horizontal axis), convert
   to RGBA. Keep the artwork's opaque dark background (no rounded-corner alpha mask).
2. Generate and stage:
   - `assets/wispterm.png` — 256×256 RGBA
   - `docs/assets/wispterm.png` — 256×256 RGBA
   - `assets/wispterm.ico` — sizes `[16,32,48,64,128,256]`
   - `assets/wispterm.icns` — sizes `[16,32,128,256]`
3. The generated icons are committed binaries (the build references them directly,
   as it does today). The source `wispterm.png` is kept at the repo root as the
   icon source of truth.

The crop result is reviewed visually before finalizing; framing adjusted if the
center-crop clips the subject.

## README intro (verbatim)

The README's opening description becomes:

> **WispTerm**, formerly Phantty, is a cross-platform terminal workspace for remote
> development and AI agent workflows. It is written in Zig and powered by
> libghostty-vt for terminal emulation.

The existing fork-attribution note is preserved; see the exclusion below.

## Scope boundary

**Renamed (full):** all of `src/`, `tests/`, `build.zig`, `build.zig.zon`,
`packaging/`, `.github/` (CI/release workflows + issue templates), `tools/`,
`debug/`, the in-house comment in `pkg/opengl/build.zig`, asset file names,
`README.md`, `AGENTS.md`, `CONTRIBUTING.md`, `TODO.md`, `Makefile`, `docs/` (user
docs + website), `remote/` (website/app), `plugins/skills/`.

The `.github/workflows/` release jobs emit asset names (`phantty-windows-portable-*`,
`phantty-macos-*`) that the renamed asset matcher in `src/platform/update_package.zig`
must agree with — both move to `wispterm-*` together.

**Preserved (historical records, left as-is):** `plans/`, `release-notes/`, the
existing `docs/superpowers/specs/` and `docs/superpowers/plans/` files (this rename's
own new spec/plan excepted), and `.superpowers/` brainstorm state.

## Critical exclusions (must NOT be renamed)

The scripted replace must not touch:

- **External repo references**: `arya-s/phantty` (the upstream fork source — a real
  external repo). Only `xuzhougeng/phantty` (our own repo) is rewritten.
  `ghostty-org/ghostty` contains no "phantty" and is unaffected.
- **The kept domain**: `phantty.cc-remote.app` (the website's custom domain stays —
  see Out of scope). The literal must survive everywhere it appears (`docs/CNAME`
  and any docs/website link), so it is protected from replacement like
  `arya-s/phantty`.
- **Build artifacts / vendored / VCS**: `.git/`, `.zig-cache/`, `zig-out*/`,
  `node_modules/`, `vendor/`, `.worktrees/`, `.superpowers/`, `*.pyc`. (`pkg/` is
  third-party except the single in-house comment in `pkg/opengl/build.zig`.)
- The preserved historical records listed above.

## Execution approach

Case-aware scripted replacement plus hand-fixed special cases, decomposed into
reviewable tasks. For in-scope text files (excluding the lists above), apply three
substitutions: `phantty→wispterm`, `Phantty→WispTerm`, `PHANTTY→WISPTERM`, with the
`arya-s/phantty` exclusion applied first/guarded. `git mv` the named files. Then
hand-handle the parts a blind replace cannot: `build.zig.zon` package-name validity
and fingerprint, behavior-critical assertions, icon binaries (generated, not
replaced), and the verbatim README intro.

Tasks (each independently buildable/testable):
1. Behavior-critical code + tests (metadata, dirs, URLs, build.zig.zon/build.zig).
2. Icon generation (Pillow script → png/ico/icns) + asset file renames + `.rc`/build refs.
3. Remaining `src/` identifiers + `src/phantty_docs.zig` rename + embed-import names.
4. Packaging + `remote/` website/app.
5. Docs + website (`README.md` intro, `docs/`, top-level `*.md`), honoring exclusions.
6. Bundled skills (`plugins/skills/`).

## Testing / verification

- Native: `zig build test` green after each task.
- Cross-compile baseline: `zig build test-full -Dtarget=x86_64-windows-gnu` →
  known-green 497/499 (1 known Windows-API failure, 1 skip) preserved.
- Grep audit at the end: no stray in-scope `phantty`/`Phantty`/`PHANTTY` remain
  outside the documented exclusions; `arya-s/phantty` still intact; `xuzhougeng/`
  references all point at `wispterm`.
- Icon assets visually reviewed; binary still launches and shows the new icon
  (manual smoke check on the available platform).

## Out of scope

- DNS/domain changes: `docs/CNAME` stays `phantty.cc-remote.app` (changing it without
  DNS would break the site). Revisit separately if a new domain is provisioned.
- Config migration from the old directory.
- Re-creating an editable `.aseprite` icon source for the new artwork.
- Renaming the actual GitHub repository (the user does that out-of-band; this change
  only updates the in-repo URLs to match).
