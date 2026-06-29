# WispTerm docs site

This folder is the source for the WispTerm GitHub Pages site.

## Files

- `index.html` — landing page (hero, features, install, config, shortcuts).
- `ai.html` / `ai.zh.html` — DeepSeek-first Copilot workflow pages.
- `use-cases.html` / `use-cases.zh.html` — practical Copilot use cases such as SSH profile setup.
- `themes.html` — built-in theme gallery.
- `configuration.md` — desktop app config reference.
- `file-explorer.md` — File Explorer, preview panel, browser panel, and SSH cwd notes.
- `ai-agent.md` — desktop Copilot, Agent skills, and Markdown export workflow notes.
- `media.md` — background images, shaders, and Kitty Graphics helper scripts.
- `development.md` — build, architecture, packaging, and GitHub release notes.
- `faq.md` — desktop and remote FAQ entries that are too detailed for the root README.
- `../ROADMAP.md` — future desktop/platform work.
- `../KNOWN_ISSUES.md` — current defects and platform limitations.
- `style.css` — Poimandres-inspired dark styling.
- `assets/wispterm.png` — logo (mirrored from repo `assets/wispterm.png`).
- `assets/favicon.ico` — favicon (mirrored from repo `assets/wispterm.ico`).
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

The site publishes at `https://<user>.github.io/wispterm/`. Do not add a
`CNAME` here when `wispterm.cc-remote.app` is served by the Cloudflare Worker
version below.

## Local preview

Any static server works:

```bash
cd docs
python3 -m http.server 8000
# open http://localhost:8000
```

## Cloudflare version with visitor stats

The GitHub Pages version is intentionally plain static HTML and does not load
visitor stats. To deploy the fuller Cloudflare version, copy the example config
and deploy from this folder:

```bash
cp wrangler.toml.example wrangler.toml
npm run deploy
```

The deploy script copies the public static docs into `dist-cloudflare/`, then
Wrangler uploads that directory. The Cloudflare Worker injects the footer stats
only for Cloudflare HTML responses and stores site-wide totals in one Durable
Object. The browser keeps a random visitor ID in `localStorage`; no IP address
is stored by the app. The committed Worker custom domain is
`wispterm.cc-remote.app`; remove any existing DNS record for that hostname before
deploying so Wrangler can create and bind the Worker custom domain.

Latest release downloads are served from the same Worker at
`/downloads/latest/*` and backed by the `wispterm-downloads` R2 bucket. The
weekly `.github/workflows/docs-downloads-r2-sync.yml` workflow mirrors only the
latest GitHub release into stable R2 object names; older versions remain on
GitHub Releases. Configure `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`
repository secrets, and create the `wispterm-downloads` R2 bucket, before
running that workflow.
