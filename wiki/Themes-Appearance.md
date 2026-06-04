# Themes & Appearance

*English · [中文](Themes-Appearance-zh)*

> Pick a theme, set your font and cursor, add a background image, and apply GLSL shaders.

## Themes

WispTerm bundles **453 Ghostty-compatible themes** (default: **Poimandres**).
Set one by name or absolute path:

```text
theme = Poimandres
```

List them with `wispterm --list-themes`, or browse the gallery at
<https://phantty.cc-remote.app/themes.html>. Theme files use the Ghostty theme
format, so any Ghostty theme file works.

## Fonts

```text
font-family = Cascadia Code
font-style = medium
font-size = 14
```

- `font-family` — any installed font; leave unset to use the embedded fallback.
- `font-style` — `thin`, `extra-light`, `light`, `regular`, `medium`,
  `semi-bold`, `bold`, `extra-bold`, `black`.
- `font-size` — points.

List available fonts with `wispterm --list-fonts`. WispTerm does **per-glyph
fallback**: characters missing from your chosen font (for example CJK glyphs)
are drawn from a fallback font automatically.

## Cursor

```text
cursor-style = bar          # block | bar | underline | block_hollow
cursor-style-blink = true
```

## Background image

Render a wallpaper behind the terminal. PNG, JPG, BMP, GIF, and TGA are
supported.

```text
background-image = C:\Users\me\Pictures\wallpaper.png
background-opacity = 0.85
background-image-mode = fill
```

`background-opacity` controls how strongly the theme background tints the
wallpaper:

| Value | Effect |
| --- | --- |
| `1.0` (default) | Theme background fully opaque; image hidden |
| `0.85` | Faint watermark (image ~15% through) |
| `0.5` | Equal blend |
| `0.15` | Image dominates with a light theme tint |
| `0.0` | Theme tint skipped; image at full strength |

The opacity also applies to per-cell backgrounds (selections, ANSI-colored
backgrounds), so the wallpaper shows through them at the same ratio.

`background-image-mode` selects how the image is sized to the window:

| Mode | Behavior |
| --- | --- |
| `fill` (default) | Cover the window, cropping the longer axis |
| `fit` | Letterbox so the whole image is visible |
| `center` | 1:1 pixel scale, centered |
| `tile` | Repeat at native size |

## Custom shaders

```text
custom-shader = path/to/shader.glsl
```

Apply a Ghostty-compatible GLSL post-processing shader. The wallpaper is drawn
inside the post-process framebuffer, so a custom shader distorts the background
image together with the terminal content.

---
*See also: [[Configuration]] · [[Inline-Images]]*
