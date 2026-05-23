# Phantty docs site

This folder is the source for the Phantty GitHub Pages site.

## Files

- `index.html` — landing page (hero, features, install, config, shortcuts).
- `ai.html` / `ai.zh.html` — DeepSeek-first AI Agent workflow pages.
- `use-cases.html` / `use-cases.zh.html` — practical AI Agent use cases such as SSH profile setup.
- `themes.html` — built-in theme gallery.
- `configuration.md` — desktop app config reference.
- `file-explorer.md` — File Explorer, preview panel, browser panel, and SSH cwd notes.
- `ai-agent.md` — desktop AI Chat and Agent skill workflow notes.
- `media.md` — background images, shaders, and Kitty Graphics helper scripts.
- `development.md` — build, architecture, packaging, and GitHub release notes.
- `faq.md` — desktop and remote FAQ entries that are too detailed for the root README.
- `style.css` — Poimandres-inspired dark styling.
- `assets/phantty.png` — logo (mirrored from repo `assets/phantty.png`).
- `assets/favicon.ico` — favicon (mirrored from repo `assets/phantty.ico`).
- `.nojekyll` — disables Jekyll so the raw HTML/CSS is served as-is.

## Enable GitHub Pages

The site is deployed by `.github/workflows/pages.yml` — a static-file workflow
using `actions/upload-pages-artifact` + `actions/deploy-pages` that bypasses
Jekyll entirely.

In the GitHub repo settings:

1. **Settings → Pages → Build and deployment**
2. **Source:** *GitHub Actions* (not "Deploy from a branch" — that route runs
   Jekyll and breaks on the Primer theme's missing `assets/css/style.scss`.)
3. Push to `main`; the workflow runs whenever `docs/**` changes.

The site publishes at `https://<user>.github.io/phantty/`.

For a custom domain, add a `CNAME` file to this folder containing the domain
and configure DNS at the registrar.

## Local preview

Any static server works:

```bash
cd docs
python3 -m http.server 8000
# open http://localhost:8000
```
