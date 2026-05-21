# Media, Background Images, and Inline Remote Images

## Background Image

Set `background-image` in the config (or pass `--background-image`) to render a
wallpaper behind the terminal. PNG, JPG, BMP, GIF, and TGA are supported.

`background-opacity` controls how strongly the theme background tints the
wallpaper:

| Value           | Effect                                                                                  |
| --------------- | --------------------------------------------------------------------------------------- |
| `1.0` (default) | Theme background is fully opaque; image is hidden, terminal looks the same without one  |
| `0.85`          | Faint watermark (image shows through about 15%)                                         |
| `0.5`           | Equal blend                                                                             |
| `0.15`          | Image dominates with a light theme tint                                                 |
| `0.0`           | Theme tint is skipped; image at full strength                                           |

The opacity also applies to per-cell backgrounds (selections, ANSI-colored
backgrounds), so the wallpaper shows through them at the same ratio.

`background-image-mode` selects how the image is sized to the window:

| Mode             | Behavior                                                    |
| ---------------- | ----------------------------------------------------------- |
| `fill` (default) | Cover the window, cropping the longer axis                  |
| `fit`            | Letterbox so the whole image is visible (edges may stretch) |
| `center`         | 1:1 pixel scale, centered                                   |
| `tile`           | Repeat at native size with `GL_REPEAT`                      |

The wallpaper is drawn inside the post-process framebuffer, so a custom shader
set with `--custom-shader` distorts it together with the terminal content.

```text
background-image = C:\Users\me\Pictures\wallpaper.png
background-opacity = 0.85
background-image-mode = fill
```

Save the config (or hot-reload via `Ctrl+,`) to apply changes without
restarting. Clearing the value removes the wallpaper.

## Remote Image Viewing

Phantty accepts Kitty Graphics protocol image output, so remote shells can
display inline images if they emit `imgcat`/`pdfcat` style escape sequences.

This repository includes two helper scripts for server-side use:

- `tools/imgcat.py` - send an image file to the terminal
- `tools/pdfcat.py` - rasterize one or more PDF pages and send them to the terminal

Examples:

```bash
python3 tools/imgcat.py screenshot.png
python3 tools/imgcat.py diagram.jpg --cols 100
python3 tools/pdfcat.py paper.pdf --page 1
python3 tools/pdfcat.py slides.pdf --page 2 --page 3 --cols 120
```

Notes:

- `imgcat.py` sends PNG directly. Non-PNG inputs require Pillow or ImageMagick.
- `pdfcat.py` requires one of `pdftoppm`, `mutool`, or ImageMagick on the server.
- The scripts are meant to run on the remote machine inside Phantty, not on Windows host side.
