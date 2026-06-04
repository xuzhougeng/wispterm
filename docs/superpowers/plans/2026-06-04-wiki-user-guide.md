# WispTerm Bilingual GitHub Wiki — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Author a comprehensive, bilingual (English + 简体中文) end-user usage wiki for WispTerm under a staged `wiki/` directory, ready to publish to `wispterm.wiki.git`.

**Architecture:** Flat staging directory `wiki/` whose filenames are exactly the GitHub Wiki page slugs. Approach A bilingual: each topic is two independent single-language pages (`<Slug>.md` / `<Slug>-zh.md`) that cross-link via an `English · 中文` switch line; one `_Sidebar.md` lists both language sets in two groups. A committed `wiki/check_wiki.py` validates link integrity and EN/zh parity after every task.

**Tech Stack:** Markdown (GitHub Wiki flavor, `[[slug]]` wiki-links), Python 3 (verification script only), git.

**Spec:** `docs/superpowers/specs/2026-06-04-github-wiki-user-guide-design.md`

---

## File Structure

All paths are under repo root `/home/xzg/project/phantty/`. The branch is `feat/wiki-user-guide` (already created; the spec is already committed there).

```
wiki/
  README.md                      # staging note + publish/verify instructions (NOT a wiki page)
  check_wiki.py                  # verification script (NOT a wiki page; excluded by *.md publish glob)
  _Sidebar.md                    # bilingual nav, two groups
  _Footer.md                     # one-line footer on every page
  Home.md / Home-zh.md
  Installation.md / Installation-zh.md
  Getting-Started.md / Getting-Started-zh.md
  Tabs-Splits-Panels.md / Tabs-Splits-Panels-zh.md
  Configuration.md / Configuration-zh.md
  Themes-Appearance.md / Themes-Appearance-zh.md
  Keyboard-Shortcuts.md / Keyboard-Shortcuts-zh.md
  File-Explorer.md / File-Explorer-zh.md
  SSH-Remote-Development.md / SSH-Remote-Development-zh.md
  AI-Copilot.md / AI-Copilot-zh.md
  Browser-Jupyter-Panel.md / Browser-Jupyter-Panel-zh.md
  Inline-Images.md / Inline-Images-zh.md
  Remote-Access.md / Remote-Access-zh.md
  FAQ.md / FAQ-zh.md
```

**Responsibility per file:** one topic = one EN page + one zh page. Each page is self-contained (a user can land on it from search and understand it), cross-linking related pages via a `See also` footer. The 14 topics are the spec's 14-page list, 1:1.

### Canonical slug set (used by checker and links)

```
Home, Installation, Getting-Started, Tabs-Splits-Panels, Configuration,
Themes-Appearance, Keyboard-Shortcuts, File-Explorer, SSH-Remote-Development,
AI-Copilot, Browser-Jupyter-Panel, Inline-Images, Remote-Access, FAQ
```
…each also valid with a `-zh` suffix. `_Sidebar` and `_Footer` are special pages, never link targets.

---

## Conventions (apply to EVERY content page)

**English page skeleton** (`<Slug>.md`):

```markdown
# <Human Title>

*English · [中文](<Slug>-zh)*

> One-sentence summary of what this page covers.

## <Section>

<body>

---
*See also: [[<RelatedSlug>]] · [[<RelatedSlug>]]*
```

**Chinese page skeleton** (`<Slug>-zh.md`):

```markdown
# <中文标题>

*[English](<Slug>) · 中文*

> 一句话说明本页内容。

## <小节>

<正文>

---
*另见：[[中文显示名|<RelatedSlug>-zh]] · [[中文显示名|<RelatedSlug>-zh]]*
```

Rules:
- **Slugs are ASCII-hyphenated**, no spaces/unicode. Chinese title lives only in the `# H1`.
- **Internal links** use `[[Slug]]` or `[[Display|Slug]]`. The switch line is a plain markdown link `[中文](<Slug>-zh)` / `[English](<Slug>)`.
- **EN/zh parity is structural:** the two pages of a topic have the **same number of `##`/`###` headings** and the **same code/config blocks verbatim** (commands, keybinds, config keys, paths are identical across languages — only prose is translated).
- **Platform notation:** show both keys inline, e.g. `Ctrl+,` (`Cmd+,` on macOS). Mark Windows-only features (embedded WebView2 browser panel) explicitly.
- **Facts are lifted from source**, never invented. Primary sources: `docs/configuration.md`, `docs/ai-agent.md`, `docs/file-explorer.md`, `docs/media.md`, `docs/faq.md`, `README.md`, `src/keybind.zig`.
- Chinese pages mirror the existing `README.zh-CN.md` tone (idiomatic, not machine-literal).

---

### Task 1: Scaffolding — directory, checker, sidebar, footer

**Files:**
- Create: `wiki/README.md`
- Create: `wiki/check_wiki.py`
- Create: `wiki/_Sidebar.md`
- Create: `wiki/_Footer.md`

- [ ] **Step 1: Create the verification script** `wiki/check_wiki.py`

```python
#!/usr/bin/env python3
"""Validate the WispTerm wiki staging directory.

Checks, over all wiki/*.md pages except README.md:
  1. every [[wiki-link]] target is a canonical slug;
  2. every present <Slug>.md has its <Slug>-zh.md counterpart and vice versa;
  3. each EN/zh pair has the same number of ## / ### headings (structural parity).
Exit non-zero on any failure. Pages not yet authored are simply skipped, so the
script can run after every task during incremental authoring.
"""
import re
import sys
from pathlib import Path

WIKI = Path(__file__).resolve().parent
BASE_SLUGS = [
    "Home", "Installation", "Getting-Started", "Tabs-Splits-Panels",
    "Configuration", "Themes-Appearance", "Keyboard-Shortcuts", "File-Explorer",
    "SSH-Remote-Development", "AI-Copilot", "Browser-Jupyter-Panel",
    "Inline-Images", "Remote-Access", "FAQ",
]
CANONICAL = set(BASE_SLUGS) | {s + "-zh" for s in BASE_SLUGS}
SPECIAL = {"_Sidebar", "_Footer", "README"}

LINK_RE = re.compile(r"\[\[([^\]]+)\]\]")
HEADING_RE = re.compile(r"^#{2,3}\s", re.MULTILINE)

def link_target(raw: str) -> str:
    # "[[Display|Slug]]" -> "Slug"; "[[Slug]]" -> "Slug"
    return raw.split("|", 1)[1].strip() if "|" in raw else raw.strip()

def main() -> int:
    errors = []
    pages = sorted(p for p in WIKI.glob("*.md") if p.stem not in SPECIAL)
    present = {p.stem for p in WIKI.glob("*.md")}

    for page in list(WIKI.glob("*.md")):
        text = page.read_text(encoding="utf-8")
        for m in LINK_RE.finditer(text):
            tgt = link_target(m.group(1))
            if tgt not in CANONICAL:
                errors.append(f"{page.name}: link [[{m.group(1)}]] -> unknown slug '{tgt}'")

    for page in pages:
        slug = page.stem
        counterpart = slug[:-3] if slug.endswith("-zh") else slug + "-zh"
        if counterpart not in present:
            errors.append(f"{page.name}: missing counterpart {counterpart}.md")

    for slug in BASE_SLUGS:
        en, zh = WIKI / f"{slug}.md", WIKI / f"{slug}-zh.md"
        if en.exists() and zh.exists():
            ne = len(HEADING_RE.findall(en.read_text(encoding="utf-8")))
            nz = len(HEADING_RE.findall(zh.read_text(encoding="utf-8")))
            if ne != nz:
                errors.append(f"{slug}: heading parity {ne} (EN) != {nz} (zh)")

    if errors:
        print("WIKI CHECK FAILED:")
        for e in errors:
            print("  -", e)
        return 1
    print(f"wiki check OK: {len(pages)} content pages, links + parity valid")
    return 0

if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: Run the checker on the empty set to verify it passes**

Run: `python3 wiki/check_wiki.py`
Expected: `wiki check OK: 0 content pages, links + parity valid` (exit 0)

- [ ] **Step 3: Create `wiki/README.md`** (staging note — not published)

```markdown
# WispTerm Wiki — staging source

This directory is the maintained source of truth for the WispTerm **GitHub Wiki**
(the separate `wispterm.wiki.git` repo). Edit pages here, open a PR, then publish.

## Layout

Flat: each `*.md` filename is exactly its wiki page slug. Each topic has an
English page (`<Slug>.md`) and a Chinese page (`<Slug>-zh.md`). `_Sidebar.md`
and `_Footer.md` are GitHub Wiki special pages.

## Verify

```bash
python3 wiki/check_wiki.py   # link integrity + EN/zh parity
```

## Publish to the wiki

The Wiki must be enabled first (repo **Settings → Features → Wikis**, then create
any one page once so `wispterm.wiki.git` exists). Then:

```bash
git clone https://github.com/xuzhougeng/wispterm.wiki.git /tmp/wt-wiki
cp wiki/*.md /tmp/wt-wiki/        # copies pages + _Sidebar + _Footer
rm -f /tmp/wt-wiki/README.md      # README.md is staging-only, not a wiki page
cd /tmp/wt-wiki && git add -A && git commit -m "docs: publish user wiki" && git push
```

`check_wiki.py` is not copied (the `*.md` glob skips it).
```

- [ ] **Step 4: Create `wiki/_Footer.md`**

```markdown
---
[WispTerm](https://github.com/xuzhougeng/wispterm) · [Docs site](https://phantty.cc-remote.app) · Wiki
```

- [ ] **Step 5: Create `wiki/_Sidebar.md`**

```markdown
### English
- [[Home]]
- [[Installation]]
- [[Getting Started|Getting-Started]]
- [[Tabs, Splits & Panels|Tabs-Splits-Panels]]
- [[Configuration]]
- [[Themes & Appearance|Themes-Appearance]]
- [[Keyboard Shortcuts|Keyboard-Shortcuts]]
- [[File Explorer & Previews|File-Explorer]]
- [[SSH & Remote Development|SSH-Remote-Development]]
- [[AI Copilot & Agent|AI-Copilot]]
- [[Browser & Jupyter Panel|Browser-Jupyter-Panel]]
- [[Inline Images|Inline-Images]]
- [[Remote Access|Remote-Access]]
- [[FAQ]]

### 中文
- [[首页|Home-zh]]
- [[安装|Installation-zh]]
- [[快速上手|Getting-Started-zh]]
- [[标签、分屏与面板|Tabs-Splits-Panels-zh]]
- [[配置|Configuration-zh]]
- [[主题与外观|Themes-Appearance-zh]]
- [[键盘快捷键|Keyboard-Shortcuts-zh]]
- [[文件浏览器与预览|File-Explorer-zh]]
- [[SSH 与远程开发|SSH-Remote-Development-zh]]
- [[AI 副驾与智能体|AI-Copilot-zh]]
- [[浏览器与 Jupyter 面板|Browser-Jupyter-Panel-zh]]
- [[内联图片|Inline-Images-zh]]
- [[远程访问|Remote-Access-zh]]
- [[常见问题|FAQ-zh]]
```

- [ ] **Step 6: Run the checker (sidebar links must all be canonical)**

Run: `python3 wiki/check_wiki.py`
Expected: `wiki check OK: 0 content pages, links + parity valid` (exit 0; `_Sidebar`/`_Footer` are not content pages, but their `[[links]]` are validated against CANONICAL)

- [ ] **Step 7: Commit**

```bash
git add wiki/README.md wiki/check_wiki.py wiki/_Sidebar.md wiki/_Footer.md
git commit -m "docs(wiki): scaffold staging dir, sidebar, footer, checker"
```

---

### Task 2: Home (EN + zh)

**Files:**
- Create: `wiki/Home.md`, `wiki/Home-zh.md`

Content (sections, identical structure both languages):
- Intro paragraph: WispTerm (formerly Phantty) is a cross-platform terminal workspace for remote development and AI agent workflows, written in Zig, terminal emulation by libghostty-vt. *Source:* `README.md` lines 3-5.
- `## Platforms` — Windows + macOS (Apple Silicon & Intel) shipped; Linux port in progress. *Source:* `README.md` NOTE block.
- `## Features at a glance` — bulleted list mirroring `README.md` Features (terminal emulation, themes 450+, splits/tabs, file explorer + previews, browser panel, AI Copilot, AI history, Kitty graphics, opt-in remote). Keep it short; each bullet links the relevant wiki page, e.g. `- **AI Copilot** — see [[AI-Copilot]]`.
- `## Start here` — ordered path: [[Installation]] → [[Getting-Started]] → [[Configuration]]. Mention [[FAQ]] for troubleshooting.
- See-also footer: `[[Installation]] · [[Getting-Started]]`.

- [ ] **Step 1: Write `wiki/Home.md`** following the EN skeleton + the sections above. Switch line `*English · [中文](Home-zh)*`.
- [ ] **Step 2: Write `wiki/Home-zh.md`** — faithful Chinese translation, same headings, same links, switch line `*[English](Home) · 中文*`.
- [ ] **Step 3: Verify** — `python3 wiki/check_wiki.py` → `wiki check OK: 2 content pages…` (exit 0).
- [ ] **Step 4: Commit** — `git add wiki/Home.md wiki/Home-zh.md && git commit -m "docs(wiki): add Home page (EN + zh)"`

---

### Task 3: Installation + Getting Started (EN + zh)

**Files:**
- Create: `wiki/Installation.md`, `wiki/Installation-zh.md`
- Create: `wiki/Getting-Started.md`, `wiki/Getting-Started-zh.md`

**Installation** sections:
- `## Windows` — download a release, run `wispterm.exe`. Portable note: a `wispterm.conf` next to the exe acts as a portable config (Windows only). *Source:* `README.md` Usage, `docs/configuration.md` line 6.
- `## macOS` — requires macOS 13+. Run `WispTerm.app/Contents/MacOS/wispterm` or launch `WispTerm.app`; **passing CLI flags requires the binary path**. Apple Silicon vs Intel builds. *Source:* `README.md` Usage + Building (macOS).
- `## Build from source` — brief: Windows `zig build -Doptimize=ReleaseFast`; macOS `zig build macos-app -Dtarget=aarch64-macos` (use `x86_64-macos` on Intel). Link `docs/development.md` for full detail (external repo link to the docs site or repo path). *Source:* `README.md` Building.
- `## Verify the install` — `wispterm --version`, `wispterm --show-config-path`. *Source:* `README.md` options.
- See-also: `[[Getting-Started]] · [[Configuration]]`.

**Getting Started** sections:
- `## First launch` — on first run, if no AI profile exists, the AI setup form appears (configure provider/model/key/agent mode). Persisted so it only prompts once. *Source:* `docs/ai-agent.md` lines 3-6, memory (ai-setup-prompted).
- `## The command center` — `Ctrl+Shift+P` (default) opens the command palette; run actions like `Toggle Browser`, `Copy Remote Key`, `Export Copilot Markdown`. *Source:* `docs/file-explorer.md` line 22, `docs/configuration.md`.
- `## Sessions & tabs` — `Ctrl+Shift+T` opens the session launcher (new shell, Copilot, Sessions/history). New tab/new window keybinds. *Source:* `docs/ai-agent.md` lines 3, 51.
- `## Discovery flags` — `--list-fonts`, `--list-themes`, `--show-config-path`, `--help`. *Source:* `README.md` options.
- `## Next steps` — links to [[Tabs-Splits-Panels]], [[Configuration]], [[AI-Copilot]].
- See-also: `[[Installation]] · [[Tabs-Splits-Panels]] · [[AI-Copilot]]`.

- [ ] **Step 1: Write `wiki/Installation.md`** (EN skeleton + sections above).
- [ ] **Step 2: Write `wiki/Installation-zh.md`** (translation, parity).
- [ ] **Step 3: Write `wiki/Getting-Started.md`** (EN skeleton + sections above).
- [ ] **Step 4: Write `wiki/Getting-Started-zh.md`** (translation, parity).
- [ ] **Step 5: Verify** — `python3 wiki/check_wiki.py` → `wiki check OK: 6 content pages…` (exit 0).
- [ ] **Step 6: Commit** — `git add wiki/Installation*.md wiki/Getting-Started*.md && git commit -m "docs(wiki): add Installation + Getting Started (EN + zh)"`

---

### Task 4: Tabs/Splits/Panels + Keyboard Shortcuts (EN + zh)

**Files:**
- Create: `wiki/Tabs-Splits-Panels.md`, `wiki/Tabs-Splits-Panels-zh.md`
- Create: `wiki/Keyboard-Shortcuts.md`, `wiki/Keyboard-Shortcuts-zh.md`

> Before writing, **verify the Quake default** against current source/release: spec + memory note that quake-mode defaulted to OFF in a recent change, while `docs/configuration.md` still lists default `true`. Use whatever `src/main.zig`/config default and `docs/configuration.md` currently say; if they disagree, trust the code default and note it.

**Tabs-Splits-Panels** sections:
- `## Tabs vs splits` — tabs in the strip; splits divide one tab. *Source:* `README.md` Features.
- `## Creating & focusing splits` — `split_right`, focus left/right/up/down, `focus_previous`/`focus_next`, `equalize_splits`. *Source:* `docs/configuration.md` actions list (lines 109-115).
- `## Focus a panel by number` — `Cmd/Ctrl+1-9` focuses the Nth split (row-major, top-left→bottom-right); falls through to terminal if no panel there. *Source:* memory `wispterm-panel-focus-by-number`.
- `## Swap panels` — Alt+left-drag swaps two panels' contents (topology unchanged); drop-target highlight. *Source:* memory `wispterm-panel-swap-alt-drag`.
- `## Focus follows mouse` — note from `README.md` Features.
- `## Quake drop-down mode` — `toggle_quake` (default global `Ctrl+backquote`) hides/shows the same window preserving state; remembers size/position. State the current default (verify). *Source:* `docs/configuration.md` line 66, memory quake notes.
- `## Closing tabs & splits` — `close_panel_or_tab`; confirm prompt when a full-screen TUI is running (if shipped — verify). *Source:* `docs/configuration.md`, memory `close-confirm-running-program` (gate on shipped).
- See-also: `[[Keyboard-Shortcuts]] · [[Getting-Started]]`.

**Keyboard-Shortcuts** sections:
- `## How keybinds work` — Ghostty-style `keybind = [global:]modifier+key=action`; `global:` registers a system-wide hotkey; `keybind = clear` removes defaults before custom ones. Modifiers `ctrl/shift/alt/win`(Win)/`cmd`(macOS). *Source:* `docs/configuration.md` lines 92-107.
- `## Common default shortcuts` — a table: command palette (`Ctrl+Shift+P`/configurable), new session (`Ctrl+Shift+T`), Copilot sidebar (`Ctrl+Shift+A`/`Cmd+Shift+A`), file explorer (`Ctrl+Shift+Alt+E`), open config (`Ctrl+,`/`Cmd+,`), font size +/-, copy/paste/paste image, focus 1-9, next/previous tab, toggle quake. *Source:* `docs/configuration.md` actions + `docs/file-explorer.md` + `docs/ai-agent.md`. Cross-check trigger defaults in `src/keybind.zig` before finalizing.
- `## The full action list` — list every action from `docs/configuration.md` lines 109-115 (`toggle_command_palette`, `toggle_quake`, `new_session`, `new_window`, `split_right`, `toggle_file_explorer`, `toggle_sidebar`, `close_panel_or_tab`, `toggle_maximize`, `font_size_increase/decrease`, `copy`, `paste`, `paste_image`, `focus_left/right/up/down`, `focus_previous/next`, `equalize_splits`, `next_tab`, `previous_tab`, `switch_tab_1`..`switch_tab_9`, `open_config`).
- `## Remapping examples` — the three `keybind = …` examples from `docs/configuration.md` lines 99-103.
- `## Overlay-local keys` — note that command center / session launcher / AI chat input handle some keys first (not remappable via `keybind`). *Source:* `README.md` keyboard section.
- See-also: `[[Configuration]] · [[Tabs-Splits-Panels]]`.

- [ ] **Step 1: Verify Quake default + a few keybind triggers** — `grep -n "quake" src/main.zig src/config*.zig 2>/dev/null` and skim `src/keybind.zig` for default triggers. Record the real defaults to use.
- [ ] **Step 2: Write `wiki/Tabs-Splits-Panels.md`**.
- [ ] **Step 3: Write `wiki/Tabs-Splits-Panels-zh.md`**.
- [ ] **Step 4: Write `wiki/Keyboard-Shortcuts.md`**.
- [ ] **Step 5: Write `wiki/Keyboard-Shortcuts-zh.md`**.
- [ ] **Step 6: Verify** — `python3 wiki/check_wiki.py` → `… 10 content pages…` (exit 0).
- [ ] **Step 7: Commit** — `git add wiki/Tabs-Splits-Panels*.md wiki/Keyboard-Shortcuts*.md && git commit -m "docs(wiki): add Tabs/Splits/Panels + Keyboard Shortcuts (EN + zh)"`

---

### Task 5: Configuration + Themes & Appearance (EN + zh)

**Files:**
- Create: `wiki/Configuration.md`, `wiki/Configuration-zh.md`
- Create: `wiki/Themes-Appearance.md`, `wiki/Themes-Appearance-zh.md`

**Configuration** sections (lift facts from `docs/configuration.md`):
- `## Where the config lives` — resolution order: `--config`/`--config-path`; `wispterm.conf` next to exe (Windows portable); platform dir — Windows `%APPDATA%\wispterm\config`, macOS `~/Library/Application Support/wispterm/config`, Linux `$XDG_CONFIG_HOME/wispterm/config`. `open_config` (`Ctrl+,`/`Cmd+,`) or `wispterm --show-config-path`. *Source:* lines 3-15.
- `## CLI vs file` — CLI flags override file (last wins); `config-file =` / `--config-file` include extra files (prefix `?` optional). *Source:* lines 17-19, 72.
- `## Example config` — the example block from lines 23-48 (kept verbatim).
- `## Key reference` — the full key table from lines 52-77 (kept verbatim; identical in both languages — translate only the Description column, keep keys/defaults).
- `## Hot reload` — saving the config (or `Ctrl+,`) applies many changes without restart. *Source:* `docs/media.md` line 40.
- See-also: `[[Themes-Appearance]] · [[Keyboard-Shortcuts]] · [[Remote-Access]]`.

**Themes-Appearance** sections:
- `## Themes` — 453 built-in Ghostty themes (default Poimandres); set `theme = <name>` or absolute path; `--list-themes`; theme gallery on the docs site (link `https://phantty.cc-remote.app/themes.html`). *Source:* `docs/configuration.md` line 59, `README.md`.
- `## Fonts` — `font-family`, `font-style` (weights list), `font-size`; `--list-fonts`; per-glyph fallback for missing chars / CJK. *Source:* `docs/configuration.md` lines 54-56, `README.md` Features.
- `## Cursor` — `cursor-style` (block/bar/underline/block_hollow), `cursor-style-blink`. *Source:* lines 57-58.
- `## Background image` — `background-image` (PNG/JPG/BMP/GIF/TGA), the `background-opacity` table and `background-image-mode` table from `docs/media.md` lines 11-29 (kept verbatim), example block lines 34-38. *Source:* `docs/media.md`.
- `## Custom shaders` — `custom-shader = path.glsl`, Ghostty-compatible GLSL post-processing; wallpaper is distorted together with terminal content. *Source:* `docs/media.md` lines 31-32, `docs/configuration.md` line 60.
- See-also: `[[Configuration]] · [[Inline-Images]]`.

- [ ] **Step 1: Write `wiki/Configuration.md`**.
- [ ] **Step 2: Write `wiki/Configuration-zh.md`**.
- [ ] **Step 3: Write `wiki/Themes-Appearance.md`**.
- [ ] **Step 4: Write `wiki/Themes-Appearance-zh.md`**.
- [ ] **Step 5: Verify** — `python3 wiki/check_wiki.py` → `… 14 content pages…` (exit 0).
- [ ] **Step 6: Commit** — `git add wiki/Configuration*.md wiki/Themes-Appearance*.md && git commit -m "docs(wiki): add Configuration + Themes & Appearance (EN + zh)"`

---

### Task 6: File Explorer + SSH & Remote Development (EN + zh)

**Files:**
- Create: `wiki/File-Explorer.md`, `wiki/File-Explorer-zh.md`
- Create: `wiki/SSH-Remote-Development.md`, `wiki/SSH-Remote-Development-zh.md`

**File-Explorer** sections (lift from `docs/file-explorer.md`):
- `## Opening the explorer` — `Ctrl+Shift+Alt+E`; environment-aware (local Windows / WSL via `wsl.exe` / SSH profile via OpenSSH). *Source:* lines 1-8.
- `## Previewing files` — `Ctrl`/`Cmd`+click a `.md/.txt/.csv/.tsv`/image in terminal output, or double-click in the explorer → right-side preview; what each type renders (Markdown elements, plain text, CSV/TSV grid, image decode PNG/JPEG/GIF/BMP/WebP). *Source:* lines 10-16.
- `## Resizing, scrolling, zooming` — drag inner edges; wheel scroll for md/text/csv; CSV hover popup; image wheel-zoom + drag-pan; `Ctrl+Shift+W` closes preview before split. *Source:* lines 41-46.
- `## Remote file download` — in SSH profile sessions, `Ctrl+Shift`(`Cmd+Shift`)-click a path → download to `%USERPROFILE%\Downloads` (background). *Source:* lines 18-20.
- `## SSH metadata requirement` — only built-in SSH-launcher sessions get remote preview; typing `ssh user@host` in a local shell does not. *Source:* lines 48-51.
- See-also: `[[SSH-Remote-Development]] · [[Browser-Jupyter-Panel]]`.

**SSH-Remote-Development** sections:
- `## Launching an SSH session` — use the built-in SSH launcher (session launcher) so profile metadata unlocks preview/download/cwd. *Source:* `docs/file-explorer.md` lines 48-51.
- `## Reporting the working directory (OSC 7)` — drag-drop uploads use the remote cwd when the shell emits OSC 7; otherwise falls back to `pwd` (login dir). Add the bash/zsh/fish snippets from `docs/file-explorer.md` lines 66-93 (verbatim). *Source:* lines 53-93.
- `## Legacy SSH servers` — `ssh-legacy-algorithms = true` for old bastions (ssh-rsa/ssh-dss/old KEX/CBC). *Source:* lines 95-98.
- `## Web apps over SSH (port forwarding)` — loopback URLs (`http://127.0.0.1:…`, `http://localhost:…`) opened through automatic local SSH tunnels, shared by the embedded panel and system browser; `url-open-mode = system-browser` opens them in the normal browser; each remote port keeps its own forward. *Source:* `docs/file-explorer.md` lines 22-39, `docs/configuration.md` line 69. Link [[Browser-Jupyter-Panel]].
- See-also: `[[File-Explorer]] · [[Browser-Jupyter-Panel]] · [[Configuration]]`.

- [ ] **Step 1: Write `wiki/File-Explorer.md`**.
- [ ] **Step 2: Write `wiki/File-Explorer-zh.md`**.
- [ ] **Step 3: Write `wiki/SSH-Remote-Development.md`**.
- [ ] **Step 4: Write `wiki/SSH-Remote-Development-zh.md`**.
- [ ] **Step 5: Verify** — `python3 wiki/check_wiki.py` → `… 18 content pages…` (exit 0).
- [ ] **Step 6: Commit** — `git add wiki/File-Explorer*.md wiki/SSH-Remote-Development*.md && git commit -m "docs(wiki): add File Explorer + SSH & Remote Development (EN + zh)"`

---

### Task 7: AI Copilot & Agent (EN + zh) — the big page

**Files:**
- Create: `wiki/AI-Copilot.md`, `wiki/AI-Copilot-zh.md`

Sections (lift from `docs/ai-agent.md`; cross-check working-dir + permission against memory notes #150 and the 3-level permission change):
- `## Opening Copilot` — `Ctrl+Shift+T` → `Copilot` opens the default AI profile in Agent mode; first-time → AI settings form. *Source:* lines 3-6.
- `## Configuring profiles` — managed in Settings; stored under `ai_profiles/` (Windows `%APPDATA%\wispterm\ai_profiles`, macOS `~/Library/Application Support/wispterm/ai_profiles`), hex-encoded. *Source:* lines 8-11.
- `## Providers & protocols` — Protocol field `chat_completions` (default) / `responses` / `anthropic`; the base-URL + auth rules per protocol; Anthropic uses `<base>/v1/messages` + `x-api-key` + `anthropic-version`, needs `Max Tokens` (default 8192), streaming not yet supported. *Source:* lines 13-24.
- `## Defaults & API keys` — DeepSeek defaults (base `https://api.deepseek.com`, model `deepseek-v4-pro`, thinking + `reasoning_effort=high`, non-streaming); `DEEPSEEK_API_KEY` env fallback; reasoning block display; elapsed time + token usage. *Source:* lines 26-47.
- `## The Copilot sidebar` — `Ctrl+Shift+A` (`Cmd+Shift+A`) on a terminal tab; per-tab conversation; auto terminal snapshot (cwd + recent output); shares default profile; exclusive right slot (hides browser/preview); `Esc` stops then hides; drag to resize. *Source:* lines 61-83.
- `## Working directory` — per-conversation `/cwd` overrides the global `ai-agent-working-dir`; default cwd for local exec. *Source:* memory `wispterm-agent-working-directory`. Verify the slash command name and config key against `docs/ai-agent.md` / source.
- `## Tool permissions` — `/permission ask|auto|full` (`confirm` alias of `ask`): `ask` prompts for normal tool use, `auto` runs ordinary tools but confirms protected-path/dangerous, `full` skips guard prompts. *Source:* lines 120-125, memory `wispterm-agent-file-access-guard`.
- `## Sessions browser & resume` — `Ctrl+Shift+T` → `Sessions` browses Codex/Claude Code/Reasonix transcripts on Local/WSL/SSH (`$HOME/.codex`, `.claude`, `.reasonix`); `Resume` reopens a terminal in the original project dir (stops if missing). *Source:* lines 49-59.
- `## Slash commands` — list the built-in ones (`/skills`, `/commands`, `/reload-skills`, `/reload-commands`, `/clear`, `/resume`, `/permission`, `/export`, `/distill`·`/沉淀`). *Source:* lines 112-129.
- `## Custom slash commands` — `commands/*.md` with `name:`/`description:` frontmatter; prompt-template vs `action:` mapping; `/reload-commands`. Include the example block from lines 174-180. *Source:* lines 166-186.
- `## Agent skills` — `skills/<name>/SKILL.md` discovery locations; `$skill-name your request`; replayable tool-result storage. *Source:* lines 101-110.
- `## Skill distillation` — `/distill [topic]` · `/沉淀 [主题]`, preview → `/distill confirm`/`cancel`; saved only under `<config>/skills/<slug>/SKILL.md`; secret scanning blocks unredacted writes. *Source:* lines 131-164.
- `## Exporting transcripts` — `Export Copilot Markdown` (full) vs `Export Copilot Markdown Clean` (prompts + final answer only); also `/export` / `/export full`. *Source:* lines 86-96, 126-127.
- `## Clipboard behavior (optional)` — `copy-on-select`, `right-click-action = paste|copy-or-paste`. *Source:* lines 192-200.
- `## Ask WispTerm about itself` — `wispterm_docs` tool answers natural questions from embedded docs (`faq`, `configuration`, `ai-agent`, `file-explorer`, `media`). *Source:* lines 202-213.
- See-also: `[[Getting-Started]] · [[SSH-Remote-Development]] · [[Configuration]]`.

- [ ] **Step 1: Verify `/cwd` + `ai-agent-working-dir` names** — `grep -rn "ai-agent-working-dir\|\"/cwd\"\|cwd" docs/ai-agent.md src/ai_chat*.zig 2>/dev/null | head`. Use confirmed names.
- [ ] **Step 2: Write `wiki/AI-Copilot.md`** (all sections above).
- [ ] **Step 3: Write `wiki/AI-Copilot-zh.md`** (translation, parity; keep slash commands and code blocks identical).
- [ ] **Step 4: Verify** — `python3 wiki/check_wiki.py` → `… 20 content pages…` (exit 0).
- [ ] **Step 5: Commit** — `git add wiki/AI-Copilot*.md && git commit -m "docs(wiki): add AI Copilot & Agent page (EN + zh)"`

---

### Task 8: Browser & Jupyter + Inline Images + Remote Access (EN + zh)

**Files:**
- Create: `wiki/Browser-Jupyter-Panel.md`, `wiki/Browser-Jupyter-Panel-zh.md`
- Create: `wiki/Inline-Images.md`, `wiki/Inline-Images-zh.md`
- Create: `wiki/Remote-Access.md`, `wiki/Remote-Access-zh.md`

> Before writing the Jupyter section, **verify shipped status**: `git log --oneline main | grep -i jupyter` and check whether PR #151 / WKWebView landed on `main`. If Jupyter is NOT in a released build, document only the browser panel and add a brief "Jupyter support is in progress" line instead of full instructions. macOS browser panel: note WebView2 embedded panel is **Windows-only** today.

**Browser-Jupyter-Panel** sections:
- `## Embedded browser panel (Windows)` — `Toggle Browser` from command center; `Ctrl`/`Cmd`+click `http(s)` URLs open in the right WebView2 panel when available; URL bar + Enter; drag to resize. Builds without WebView2 fall back to system browser. *Source:* `docs/file-explorer.md` lines 22-39.
- `## Where URLs open` — `url-open-mode = embedded` (default) vs `system-browser`; SSH loopback tunnels shared by both. *Source:* `docs/configuration.md` line 69. Link [[SSH-Remote-Development]].
- `## Jupyter` — (gated) connect to a remote Jupyter by pasting URL + token; side/full modes; auto-detect from focused terminal. Only include if shipped; else a one-line "in progress" note. *Source:* Jupyter memory note.
- See-also: `[[SSH-Remote-Development]] · [[File-Explorer]]`.

**Inline-Images** sections (lift from `docs/media.md` Remote Image Viewing):
- `## What it does` — WispTerm accepts Kitty Graphics protocol output, so remote shells can show inline images/PDF pages. *Source:* lines 44-46.
- `## imgcat.py / pdfcat.py` — the two helper scripts; the example block lines 55-60 (verbatim). *Source:* lines 48-60.
- `## Requirements & notes` — Pillow/ImageMagick for non-PNG; `pdftoppm`/`mutool`/ImageMagick for PDF; **run on the remote machine, not the Windows host**. *Source:* lines 62-66.
- See-also: `[[SSH-Remote-Development]] · [[Themes-Appearance]]`.

**Remote-Access** sections (lift from `docs/configuration.md` remote section + `docs/faq.md`):
- `## What it is` — opt-in sharing of a session over a Cloudflare-hosted relay; **disabled by default**. *Source:* `README.md` Features, `docs/configuration.md` lines 79-90.
- `## Enabling it` — `remote-enabled = true` + `remote-server-url`, optional `remote-server-fingerprint`, `remote-device-name`. *Source:* `docs/configuration.md` key table lines 73-77.
- `## Session keys` — random per process by default; `remote-session-key = mypass` for predictable keys, later instances get `_1`/`_2`…; click the status pill or `Copy Remote Key` to copy. Separate from relay admin login. *Source:* lines 79-90.
- `## Phone mirroring` — remote mirrors the local terminal size because the desktop is source of truth; mobile UI refocuses panels but does not reflow to phone width. *Source:* `docs/faq.md` lines 23-36.
- See-also: `[[Configuration]] · [[FAQ]]`.

- [ ] **Step 1: Verify Jupyter shipped status** — `git log --oneline -50 | grep -i jupyter; git branch --contains 463e95c 2>/dev/null`. Decide full-doc vs in-progress note.
- [ ] **Step 2: Write `wiki/Browser-Jupyter-Panel.md`**.
- [ ] **Step 3: Write `wiki/Browser-Jupyter-Panel-zh.md`**.
- [ ] **Step 4: Write `wiki/Inline-Images.md`**.
- [ ] **Step 5: Write `wiki/Inline-Images-zh.md`**.
- [ ] **Step 6: Write `wiki/Remote-Access.md`**.
- [ ] **Step 7: Write `wiki/Remote-Access-zh.md`**.
- [ ] **Step 8: Verify** — `python3 wiki/check_wiki.py` → `… 26 content pages…` (exit 0).
- [ ] **Step 9: Commit** — `git add wiki/Browser-Jupyter-Panel*.md wiki/Inline-Images*.md wiki/Remote-Access*.md && git commit -m "docs(wiki): add Browser/Jupyter + Inline Images + Remote Access (EN + zh)"`

---

### Task 9: FAQ (EN + zh) + final verification

**Files:**
- Create: `wiki/FAQ.md`, `wiki/FAQ-zh.md`

**FAQ** sections (lift from `docs/faq.md`, add cross-cutting entries):
- `## Why isn't my shell running as Administrator?` — shells inherit `wispterm.exe`'s token; normal launch = standard token (UAC split). *Source:* `docs/faq.md` lines 3-8.
- `## How do I run an elevated shell?` — run WispTerm elevated (Run as administrator), or `Start-Process pwsh -Verb RunAs` for a separate elevated window. *Source:* lines 10-21.
- `## Why does remote mirror the local terminal size on phones?` — desktop is source of truth. *Source:* lines 23-36. (Or link [[Remote-Access]] and keep it short.)
- `## Where is my config / how do I hot-reload?` — pointer to [[Configuration]] (`--show-config-path`, `Ctrl+,`).
- `## Is there a Linux build?` — Windows + macOS shipped; Linux port in progress (`TODO.md`). *Source:* `README.md` NOTE.
- See-also: `[[Configuration]] · [[Remote-Access]] · [[Home]]`.

- [ ] **Step 1: Write `wiki/FAQ.md`**.
- [ ] **Step 2: Write `wiki/FAQ-zh.md`**.
- [ ] **Step 3: Full verification** — `python3 wiki/check_wiki.py` → `wiki check OK: 28 content pages, links + parity valid` (exit 0).
- [ ] **Step 4: Manual spot-check** — open 2-3 pages in any Markdown renderer; confirm the key reference table (Configuration), the bash/zsh/fish snippets (SSH), and the opacity/mode tables (Themes) render correctly and the `English · 中文` switch links point at the right slug.
- [ ] **Step 5: Cross-check facts** — re-read `wiki/Configuration.md` key table against `docs/configuration.md` lines 52-77; confirm no invented keys/defaults.
- [ ] **Step 6: Commit** — `git add wiki/FAQ*.md && git commit -m "docs(wiki): add FAQ page (EN + zh); complete bilingual wiki"`

---

## Publishing (separate, user-gated — NOT part of task execution)

Publishing pushes to `wispterm.wiki.git` and is an outward-facing action requiring user go-ahead and an enabled Wiki. Follow `wiki/README.md`:
1. Confirm Wiki is enabled (repo Settings → Features → Wikis; create one page so the repo exists).
2. Clone `wispterm.wiki.git`, copy `wiki/*.md` (skip `README.md`), commit, push.

Do not publish without explicit user instruction.

---

## Self-Review

**Spec coverage:** all 14 spec topics → Tasks 2-9 (Home; Installation+Getting Started; Tabs/Splits+Keyboard; Configuration+Themes; File Explorer+SSH; AI Copilot; Browser/Jupyter+Inline Images+Remote Access; FAQ). Bilingual Approach A, sidebar split, footer, staging dir kept, checker, publish-gating, shipped-feature gating (Jupyter/Quake/working-dir verified in-task) — all covered. No gaps.

**Placeholder scan:** No "TBD/TODO/handle edge cases". Deterministic files (`_Sidebar`, `_Footer`, `README`, `check_wiki.py`) given in full. Content pages specify exact sections + source line ranges + verbatim blocks to lift, which is the correct altitude for a docs plan (the prose is the deliverable, produced from cited sources, not invented in the plan).

**Type/name consistency:** slug set is identical in the File Structure, the checker's `BASE_SLUGS`, the sidebar links, and every `See also`. The checker function names (`link_target`, `main`) and the expected page counts (2→6→10→14→18→20→26→28) are consistent across tasks.
