# Linux SP2 — fontconfig Discovery + CJK Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On Linux, resolve the configured font (`font = …`) and per-codepoint CJK/symbol fallback to real installed font files via fontconfig, replacing the embedded-font-only stub from SP1.

**Architecture:** New `pkg/fontconfig` (system libfontconfig via pkg-config) + `src/platform/font_discovery_linux.zig` (fontconfig `FcFontMatch` / `FcCharSet`) re-exported by a rewritten `font_backend_linux.zig` (mirrors `font_backend_macos.zig`). FreeType (already cross-platform) loads the resolved paths. The only pure, fast-suite-testable piece is the OS→fontconfig weight mapping; the fontconfig impl is build- + GUI-smoke-verified (it can't be unit-tested without fonts, same as every platform backend in this repo).

**Tech Stack:** Zig 0.15.2, fontconfig 2.13.1 (C via `@cImport` + pkg-config), FreeType (vendored).

**Spec:** [2026-06-08-linux-sp2-fontconfig-design.md](../specs/2026-06-08-linux-sp2-fontconfig-design.md).

**Conventions:** Work in the worktree `/home/xzg/project/phantty/.claude/worktrees/feat-linux-version` (branch `worktree-feat-linux-version`); verify with `git rev-parse --show-toplevel`. Fast tests: `zig build test`. Full: `zig build test-full`. Linux build: `zig build -Dtarget=x86_64-linux-gnu`. Commit after each task.

---

### Task 1: Pure OS-weight → fontconfig-weight mapping

**Files:**
- Create: `src/platform/font_weight_fc.zig`
- Modify: `src/test_fast.zig`

- [ ] **Step 1: Write the failing test**

Create `src/platform/font_weight_fc.zig` with tests first:

```zig
//! Pure mapping from an OS/2 font weight (100..900, as used by the neutral
//! FontWeight enum) to a fontconfig FC_WEIGHT_* value. No fontconfig dependency
//! so it runs in the fast suite; font_discovery_linux.zig calls fcWeight() with
//! @intFromEnum(weight). FC_WEIGHT_* values are fontconfig's stable scale
//! (THIN=0, REGULAR=80, BOLD=200, BLACK=210).
const std = @import("std");

test "OS weights map to fontconfig weights" {
    try std.testing.expectEqual(@as(c_int, 0), fcWeight(100)); // THIN
    try std.testing.expectEqual(@as(c_int, 80), fcWeight(400)); // REGULAR
    try std.testing.expectEqual(@as(c_int, 200), fcWeight(700)); // BOLD
    try std.testing.expectEqual(@as(c_int, 210), fcWeight(900)); // BLACK
    try std.testing.expectEqual(@as(c_int, 80), fcWeight(450)); // unknown → REGULAR
}
```

- [ ] **Step 2: Run, verify FAIL**

Run: `zig test src/platform/font_weight_fc.zig`
Expected: FAIL (`fcWeight` undefined).

- [ ] **Step 3: Implement** (above the test)

```zig
/// FC_WEIGHT_* constants (fontconfig stable scale).
pub const FC_WEIGHT_THIN: c_int = 0;
pub const FC_WEIGHT_REGULAR: c_int = 80;
pub const FC_WEIGHT_BOLD: c_int = 200;
pub const FC_WEIGHT_BLACK: c_int = 210;

pub fn fcWeight(os_weight: u16) c_int {
    return switch (os_weight) {
        100 => FC_WEIGHT_THIN,
        700 => FC_WEIGHT_BOLD,
        900 => FC_WEIGHT_BLACK,
        else => FC_WEIGHT_REGULAR,
    };
}
```

- [ ] **Step 4: Run, verify PASS**

Run: `zig test src/platform/font_weight_fc.zig` → both pass.

- [ ] **Step 5: Register + fast suite**

Add to the `test { … }` block in `src/test_fast.zig`:
```zig
    _ = @import("platform/font_weight_fc.zig");
```
Run: `zig build test` → green.

- [ ] **Step 6: Commit**

```bash
git add src/platform/font_weight_fc.zig src/test_fast.zig
git commit -m "feat(linux/font): pure OS→fontconfig weight mapping"
```

---

### Task 2: `pkg/fontconfig` + build wiring

**Files:**
- Create: `pkg/fontconfig/fontconfig.zig`, `pkg/fontconfig/build.zig`
- Modify: `build.zig.zon`, `build.zig`

- [ ] **Step 1: Create the package** (mirror `pkg/sdl`, which already exists — read it first)

`pkg/fontconfig/fontconfig.zig`:
```zig
pub const c = @cImport({
    @cInclude("fontconfig/fontconfig.h");
});
```

`pkg/fontconfig/build.zig`:
```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const module = b.addModule("fontconfig", .{
        .root_source_file = b.path("fontconfig.zig"),
        .target = target,
    });
    // pkg-config supplies fontconfig's include dirs + link flags.
    module.linkSystemLibrary("fontconfig", .{});
}
```

- [ ] **Step 2: Wire the dependency in `build.zig.zon`**

Add alongside `.sdl`:
```zig
        .fontconfig = .{ .path = "pkg/fontconfig" },
```

- [ ] **Step 3: Wire into `build.zig`**

Add `"fontconfig"` to `linux_system_libraries` (so `app_mod` links it via the `systemLibrariesFor` loop, which also gives `app_mod` the pkg-config include path for `font_discovery_linux.zig`'s `@cImport`):
```zig
const linux_system_libraries = [_][]const u8{ "SDL3", "fontconfig" };
```
In the `if (target.result.os.tag == .linux)` block (next to the `sdl` import), add the module import:
```zig
        if (b.lazyDependency("fontconfig", .{ .target = target })) |dep| {
            app_mod.addImport("fontconfig", dep.module("fontconfig"));
        }
```

- [ ] **Step 4: Verify the header parses + suite green**

```bash
printf 'const c = @cImport({ @cInclude("fontconfig/fontconfig.h"); });\ncomptime { _ = c.FcInit; _ = c.FC_FAMILY; }\n' > /tmp/fcprobe.zig
zig build-obj /tmp/fcprobe.zig -lc -lfontconfig -femit-bin=/tmp/fcprobe.o; echo "probe exit=$?"
zig build test; echo "test exit=$?"
```
Expected: probe exit 0 (header parses, `FcInit`/`FC_FAMILY` resolve), `zig build test` green (default windows target unaffected — the import is linux-gated).

- [ ] **Step 5: Commit**

```bash
git add pkg/fontconfig build.zig.zon build.zig
git commit -m "build(linux/font): pkg/fontconfig + link wiring"
```

---

### Task 3: `font_discovery_linux.zig` (fontconfig impl) + re-export

**Files:**
- Create: `src/platform/font_discovery_linux.zig`
- Rewrite: `src/platform/font_backend_linux.zig`

**Read first:** `src/platform/font_discovery_macos.zig` (the API contract to mirror — `FontWeight`/`FontFilePath`/`FallbackFont`/`FontDiscovery`/`LoadedFont` + `fontWeightFromValue`/`fontFilePathAlloc`/`fontDataAlloc`), `src/platform/font_backend_macos.zig` (the thin re-export to mirror), and `src/font/manager.zig` around lines 403/1173/1282/1321/1628 (the consumers: `findFont`, `findFontFilePath`, `findFallbackFont`).

- [ ] **Step 1: Implement `font_discovery_linux.zig`**

`const fc = @import("fontconfig").c;` and `const fcw = @import("font_weight_fc.zig");`. Mirror the macOS module's public surface, backed by fontconfig:

- `FontWeight` enum (THIN=100, NORMAL=400, BOLD=700, BLACK=900) and `FontStyle`/`FontFilePath` exactly as macOS.
- `FallbackFont = struct { handle: *fc.FcPattern }` with:
  - `release(self)` → `fc.FcPatternDestroy(self.handle)` + `std.heap.c_allocator.destroy(self)`.
  - `hasCharacter(self, cp) bool` → `var cs: ?*fc.FcCharSet = null; if (fc.FcPatternGetCharSet(self.handle, fc.FC_CHARSET, 0, &cs) == fc.FcResultMatch and cs != null) return fc.FcCharSetHasChar(cs, cp) == fc.FcTrue; return false;`
  - `wrap(handle) !*FallbackFont` helper (c_allocator.create).
- `FontDiscovery = struct {}` with:
  - `init() !FontDiscovery` → `if (fc.FcInit() != fc.FcTrue) return error.FontconfigInitFailed; return .{};`
  - `deinit(self)` → no-op.
  - `findFont(self, family, weight, style) !?*FallbackFont`:
    ```
    pat = FcPatternCreate()
    family_z = c_allocator.dupeZ(u8, family)
    FcPatternAddString(pat, FC_FAMILY, family_z.ptr)
    FcPatternAddInteger(pat, FC_WEIGHT, fcw.fcWeight(@intFromEnum(weight)))
    FcConfigSubstitute(null, pat, FcMatchPattern)
    FcDefaultSubstitute(pat)
    var res: FcResult = undefined
    match = FcFontMatch(null, pat, &res)   // *FcPattern owned by caller
    FcPatternDestroy(pat)
    if (match == null) return null
    return FallbackFont.wrap(match)
    ```
  - `findFallbackFont(self, cp) !?*FallbackFont`: same as findFont but build the pattern with a charset and NO family:
    ```
    cs = FcCharSetCreate(); FcCharSetAddChar(cs, cp)
    pat = FcPatternCreate()
    FcPatternAddCharSet(pat, FC_CHARSET, cs)
    FcPatternAddBool(pat, FC_SCALABLE, FcTrue)
    FcConfigSubstitute(null, pat, FcMatchPattern); FcDefaultSubstitute(pat)
    match = FcFontMatch(null, pat, &res)
    FcCharSetDestroy(cs); FcPatternDestroy(pat)
    wrap(match)
    ```
  - `findPreferredFallbackFont(self, cp, families)` → loop `findFont(f,.NORMAL,.NORMAL)`, return first whose `hasCharacter(cp)`; release the rest (copy the macOS impl verbatim).
  - `findFontFilePath(self, alloc, family, weight, style) !?FontFilePath` → `findFont(...)` then `fontFilePathAlloc(alloc, font)` then `font.release()` (copy the macOS impl).
  - `listFontFamilies` → return an empty slice (`alloc.alloc([]const u8, 0)`) for now (only used by macOS UI; not required on Linux). Note as a stub.
- `LoadedFont = struct { handle: *fc.FcPattern }` minimal: `init(font)` clones via `fc.FcPatternDuplicate(font.handle)`; `deinit` destroys; `getGlyphIndex(cp)` returns `if hasGlyph(cp) 1 else 0`; `hasGlyph(cp)` via the same FcCharSet check as `FallbackFont.hasCharacter`. (Real glyph indices come from FreeType; this type is consumed only by a macOS test.)
- `fontWeightFromValue(u16) FontWeight` → copy the macOS table.
- `fontFilePathAlloc(alloc, font) ?FontFilePath`:
  ```
  var file: [*c]fc.FcChar8 = undefined
  if (FcPatternGetString(font.handle, FC_FILE, 0, &file) != FcResultMatch) return null
  var idx: c_int = 0
  _ = FcPatternGetInteger(font.handle, FC_INDEX, 0, &idx)
  path = alloc.dupeZ(u8, std.mem.span(@as([*:0]const u8, @ptrCast(file)))) catch return null
  return .{ .path = path, .face_index = @intCast(@max(0, idx)), .allocator = alloc }
  ```
- `fontDataAlloc(alloc, font) ?[]u8` → `return null;` (Linux always has a real file path).

Confirm every `Fc*` / `FC_*` / `FcResultMatch` / `FcTrue` symbol against `/usr/include/fontconfig/fontconfig.h` (grep it). If `FcResultMatch`/`FcTrue` are enum values translate-c maps oddly, compare via the right integer.

- [ ] **Step 2: Rewrite `font_backend_linux.zig`** (mirror `font_backend_macos.zig`)

```zig
const std = @import("std");
const font_discovery = @import("font_discovery_linux.zig");

pub const FontWeight = font_discovery.FontWeight;
pub const FallbackFont = font_discovery.FallbackFont;
pub const FontDiscovery = font_discovery.FontDiscovery;
pub const LoadedFont = font_discovery.LoadedFont;
pub const FontFilePath = font_discovery.FontFilePath;

pub const TitlebarIconFont = struct {
    display_name: []const u8,
    path: [:0]const u8,
    face_index: u32 = 0,
};

pub fn titlebarIconFont() TitlebarIconFont {
    // Placeholder path → the app falls back to quad-drawn caption icons
    // (confirmed working in SP1).
    return .{ .display_name = "system titlebar icons", .path = "system-titlebar-icons" };
}

pub fn titlebarIconGlyph(icon: anytype) u32 {
    return switch (icon) {
        .add => '+', .close => 'x', .maximize => 0x25A1, .minimize => '-', .restore => 0x25A3,
    };
}

pub fn fontWeightFromValue(value: u16) FontWeight {
    return font_discovery.fontWeightFromValue(value);
}
pub fn fontFilePathAlloc(allocator: std.mem.Allocator, font: *FallbackFont) ?FontFilePath {
    return font_discovery.fontFilePathAlloc(allocator, font);
}
pub fn fontDataAlloc(allocator: std.mem.Allocator, font: *FallbackFont) ?[]u8 {
    return font_discovery.fontDataAlloc(allocator, font);
}
```

(Check `font_backend_unsupported.zig` for the exact `TitlebarIcon`/`titlebarIconGlyph` enum the facade expects, and match it — the facade `font_backend.zig` defines `TitlebarIcon`; `titlebarIconGlyph` takes it.)

- [ ] **Step 3: Build for Linux**

Run: `zig build -Dtarget=x86_64-linux-gnu` → links (fontconfig resolved). Fix any `Fc*` signature mismatches against the header; report if a cascade appears.

- [ ] **Step 4: Commit**

```bash
git add src/platform/font_discovery_linux.zig src/platform/font_backend_linux.zig
git commit -m "feat(linux/font): fontconfig discovery + CJK fallback"
```

---

### Task 4: Verify — suites + CJK smoke

- [ ] **Step 1: Suites**

```bash
zig build test; echo "fast=$?"
zig build test-full; echo "full=$?"
```
Expected: fast green; test-full green except the known pre-existing Windows-process-spawn failures (`child_output`, `preview_path`) documented in PR #176 — confirm no NEW failures.

- [ ] **Step 2: Build + launch**

```bash
zig build -Dtarget=x86_64-linux-gnu
DISPLAY=:0 ./zig-out/bin/wispterm >/tmp/wt_sp2.log 2>&1   # via background launch
```
Confirm the log no longer prints `Failed to initialize system font backend` / `UnsupportedFontBackend`, and instead resolves the configured font through fontconfig.

- [ ] **Step 3: CJK smoke (controller + user)**

In the running window, run `echo 中文测试 ABC`. Confirm: Latin renders in the configured/system font and the CJK characters render as **real glyphs (not tofu)** via the fontconfig per-codepoint fallback. (Pixels need the user's eyes — WSLg can't screenshot GL.)

- [ ] **Step 4: Record acceptance** in the SP2 spec and finish.

---

## Self-review (completed while writing)

- **Spec coverage:** pkg/fontconfig (Task 2), font_discovery_linux fontconfig impl incl. findFont/findFontFilePath/findFallbackFont(charset)/hasCharacter/fontFilePathAlloc(FC_FILE+FC_INDEX)/fontDataAlloc=null/LoadedFont-minimal (Task 3), font_backend_linux re-export + titlebar stub (Task 3), weight mapping pure+tested (Task 1), build wiring + system lib (Task 2), CJK smoke (Task 4) — all mapped.
- **Placeholders:** none; Task 1 has full test+impl; Tasks 2–3 give exact files + fontconfig call sequences + build commands + smoke steps (the only honest verification for C-interop discovery).
- **Type consistency:** `FontWeight`/`FallbackFont`/`FontDiscovery`/`LoadedFont`/`FontFilePath` names match the macOS contract and `font_backend.zig` facade; `fcWeight` signature consistent between Task 1 and Task 3.

## Execution note

Tasks 1–2 land green in the existing suites without fontconfig affecting the default build. The fontconfig impl (Task 3) only compiles under the linux target. Needs the worktree + fontconfig dev headers (present here, 2.13.1) + WSLg for the Task 4 CJK smoke.
