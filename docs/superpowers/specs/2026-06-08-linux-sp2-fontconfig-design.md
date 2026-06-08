# SP2 — Linux font discovery + CJK fallback (fontconfig)

Sub-project 2 of the Linux port roadmap
([2026-06-08-linux-port-design.md](2026-06-08-linux-port-design.md)). Builds on
SP1 (the SDL3 host, PR #176), which renders with the **embedded** font only.

## Goal

Resolve the user-configured font (`font = …`) and per-codepoint **CJK / symbol
fallback** to real installed font files via **fontconfig**, so WispTerm on Linux
shows system fonts and CJK text instead of the embedded JetBrains Mono only.
FreeType (already cross-platform) loads the resolved paths; HarfBuzz (vendored)
shapes. This sub-project only fills the **discovery** seam.

## Current state

`font_backend_linux.zig` re-exports `font_backend_unsupported.zig`, whose
`FontDiscovery.init()` returns `error.UnsupportedFontBackend`. So
`font/manager.zig`'s `g_font_discovery` stays null and the app falls back to the
embedded font for everything (the SP1 smoke logged exactly this). The consumer
contract `font/manager.zig` needs from a discovery is:

- `FontDiscovery.init() !FontDiscovery` / `deinit()`
- `findFont(family, weight, style) !?*FallbackFont` (manager.zig:403/417/1282)
- `findFontFilePath(alloc, family, weight, style) !?FontFilePath` (manager.zig:1173/1628) — primary font
- `findFallbackFont(codepoint) !?*FallbackFont` (manager.zig:1321) — **CJK / symbol fallback**
- `FallbackFont.hasCharacter(codepoint)` + `release()`
- `fontFilePathAlloc(alloc, font) ?FontFilePath`
- module: `FontWeight`, `FontFilePath`, `LoadedFont`, `fontWeightFromValue`, `fontDataAlloc`, titlebar-icon decls

`LoadedFont` is consumed only by `test_macos_font.zig` (macOS) — a minimal Linux
impl suffices.

## Approach (chosen): fontconfig, mirroring the macOS font-discovery structure

The macOS backend is `font_backend_macos.zig` (thin re-export) + a real
`font_discovery_macos.zig` (CoreText). Linux mirrors that shape:

- **New `pkg/fontconfig/`** — mirrors `pkg/sdl`: `fontconfig.zig`
  (`pub const c = @cImport(@cInclude("fontconfig/fontconfig.h"));`) +
  `build.zig` (`b.addModule` + `linkSystemLibrary("fontconfig")`, pkg-config
  discovery — no hardcoded prefix). fontconfig 2.13.1 is pkg-config-visible.
- **New `src/platform/font_discovery_linux.zig`** — the fontconfig impl of the
  `FontDiscovery` API above. `const fc = @import("fontconfig").c;`.
- **Rewrite `src/platform/font_backend_linux.zig`** — re-export the new
  `font_discovery_linux.zig` (exactly mirroring `font_backend_macos.zig`), with
  Linux titlebar-icon stubs (placeholder path → app uses the quad-drawn caption
  icons it already falls back to, verified working in SP1).
- **`build.zig`** — add `fontconfig` to `linux_system_libraries` (linked on
  `app_mod` via the existing loop, which also gives `app_mod` the pkg-config
  include path) and wire the `pkg/fontconfig` module import for the linux target
  (mirror the `sdl` block).

**Rejected:** a hand-rolled directory scan of `~/.fonts` / `/usr/share/fonts`
(re-implements fontconfig badly, no lang-aware CJK fallback); requiring the
vendored ghostty fontconfig (system libfontconfig is universally present and
matches the SDL3 system-link approach).

## fontconfig mapping

- `init()` → `FcInit()` (returns bool); store nothing else (uses the default
  `FcConfig`). `deinit()` → no-op (or `FcFini()` — avoid; leave the global
  config, matching fontconfig norms).
- `findFont(family, weight, style)`:
  1. `pat = FcPatternCreate()`; `FcPatternAddString(pat, FC_FAMILY, family_z)`;
     `FcPatternAddInteger(pat, FC_WEIGHT, fcWeight(weight))` where
     `fcWeight = FcWeightFromOpenType(@intFromEnum(weight))` (maps OS weight
     100–900 → fontconfig scale); `FcPatternAddBool(pat, FC_SCALABLE, FcTrue)`.
  2. `FcConfigSubstitute(null, pat, FcMatchPattern)`; `FcDefaultSubstitute(pat)`.
  3. `match = FcFontMatch(null, pat, &result)`; `FcPatternDestroy(pat)`.
  4. Wrap `match` (an `FcPattern*`) as `FallbackFont.handle`. Returns null if no
     match.
- `findFallbackFont(codepoint)`: same, but add an `FcCharSet` containing the
  codepoint — `cs = FcCharSetCreate(); FcCharSetAddChar(cs, codepoint);
  FcPatternAddCharSet(pat, FC_CHARSET, cs)` — so `FcFontMatch` returns the best
  installed font **covering that codepoint** (fontconfig's lang/coverage logic =
  CJK fallback). Destroy `cs` after.
- `FallbackFont.hasCharacter(codepoint)`: `FcPatternGetCharSet(handle,
  FC_CHARSET, 0, &cs)` then `FcCharSetHasChar(cs, codepoint)`.
- `FallbackFont.release()`: `FcPatternDestroy(handle)` + free the wrapper.
- `fontFilePathAlloc(font)`: `FcPatternGetString(handle, FC_FILE, 0, &file)` →
  dupeZ; `FcPatternGetInteger(handle, FC_INDEX, 0, &idx)` → `face_index`.
- `fontDataAlloc(font)`: return `null` (Linux always has a real file path; only
  macOS reconstructs sfnt bytes).
- `LoadedFont`: minimal — `init(font)` clones the `FcPattern`/charset;
  `hasGlyph(cp)` via `FcCharSetHasChar`; `getGlyphIndex` returns
  `if hasGlyph 1 else 0` (real glyph indices come from FreeType, not fontconfig;
  this type is macOS-test-only).
- `fontWeightFromValue(u16)` → `FontWeight` (same table as macOS).

## Testing

- **Pure, fast-suite test:** `fcWeight`/`fontWeightFromValue` mapping in a
  std-only test (no fontconfig) — e.g. extract a pure `osWeightToFcWeight(u16)
  c_int` and lock the 100/400/700/900 mappings. Registered in `test_fast.zig`.
- **Native fontconfig integration test (optional, in `test_posix.zig`):** since
  fontconfig + system fonts exist on the dev/CI host, init the discovery and
  assert `findFontFilePath("monospace", .NORMAL, .NORMAL)` returns a non-empty
  path and `findFallbackFont(0x4E2D /* 中 */)` returns a font — runs natively
  via libc. (Include if the build wiring for test_posix + fontconfig is clean;
  otherwise rely on the smoke.)
- **GUI smoke (user):** launch on X11/WSLg, confirm the configured font renders
  (not embedded) and a CJK string (e.g. `echo 中文测试`) shows real glyphs, not
  tofu.

## Acceptance

1. `zig build -Dtarget=x86_64-linux-gnu` builds + links fontconfig.
2. `zig build test` / `test-full` green (pure weight test added; no regressions;
   windows/macos unaffected — `.linux` arm is comptime-gated).
3. App on Linux resolves the configured font via fontconfig and renders CJK via
   per-codepoint fallback (user-confirmed smoke).

## Out of scope

- HarfBuzz shaping changes (already vendored + cross-platform).
- Font-family listing UI, font config hot-reload specifics (existing logic
  reused as-is).
- Emoji/color-font specifics beyond what fontconfig fallback returns.

## Open items for the plan

- Whether to add the native `test_posix.zig` fontconfig integration test
  (depends on cleanly wiring fontconfig into the test_posix build step).
- Confirm `FcWeightFromOpenType` is exposed by the installed fontconfig headers
  (2.13.1 has it; fall back to a manual weight table if translate-c misses it).
