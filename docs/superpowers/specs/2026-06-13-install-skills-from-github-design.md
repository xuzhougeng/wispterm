# Install Skills from a GitHub URL — Design

**Date:** 2026-06-13
**Status:** Approved design, pending implementation plan
**Branch:** `worktree-feat-install-skills`

## Goal

Let the user acquire skills from the internet by pasting a GitHub URL. Given a
URL such as:

```
https://github.com/fei0810/bear-research-skills/tree/main/skills
```

WispTerm enumerates every skill under that path, lets the user pick which ones
to install, downloads them, and adds them to the local **Skill Center
library** (`<config>/skills`). From there the user deploys to local Claude
Code / Codex or any remote server using the **existing** Skill Center deploy
flow.

This closes the one gap in Skill Center v2: the library could previously only
be populated by *importing* from a machine you already reach. There was no way
to pull a skill from a public repository. "Install from GitHub" becomes a new
**source** for the library, alongside import.

## Decisions (from brainstorming)

1. **Install target** — download into the wispterm library (`<config>/skills`)
   as a new source. Deployment to `~/.claude/skills` etc. reuses the existing
   deploy picker. *No* new auto-deploy path in v1.
2. **Entry point** — a new action **in the Skill Center panel**: press `g`
   ("get from GitHub"), paste a URL, pick skills, install.
3. **Selection** — when a URL points at a folder containing many skills, show a
   **checklist** (multi-select, with select-all) so the user installs a subset.

## Context

### Existing infrastructure this builds on (all already in `main`)

- **`src/skill_update.zig`** — the near-exact template. It already does:
  GitHub Git Trees API (`?recursive=1`) → filter blobs by a path prefix →
  download each via `raw.githubusercontent.com` using
  `update_install.downloadAsset` → stage in a temp dir → per-skill atomic
  replace. It is hardcoded to wispterm's own repo + `plugins/skills/` prefix +
  `<config>/plugins/skills` destination. The new feature generalizes the
  *source* (arbitrary owner/repo/ref/subpath) and changes the *destination*
  (the `<config>/skills` library). Its pure helpers
  (`parseSkillPaths`, `rawUrlForPath`, `installSubpath`, `skillNamesFromPaths`)
  and impure `downloadAndInstall` are the model for the new module.
- **`src/skill_center.zig`** — the Skill Center v2 model: a `PanelModel` with a
  `library: []LibrarySkill`, an `Overlay` union, and a concurrency-safe
  `Session` with background-op machinery: `startOp(OpWork, wake, busy_msg)`,
  `takePendingOp() ?OpResult`, `OpResult` union, join-on-deinit, `closing`
  atomic. The install flow adds two `OpResult` variants and two overlay states
  and reuses everything else.
- **`src/platform/dirs.zig`** — `skillsDir()` → `<config>/skills` (the library
  root); `pluginSkillsDir()` → `<config>/plugins/skills` (NOT us).
- **`src/update_install.zig`** — `downloadAsset(allocator, url, dest)` HTTP-GETs
  a URL to a file path. Reused verbatim for blob downloads.
- **`src/AppWindow.zig`** — Skill Center integration: `renderSkillCenterFrame`,
  the op-orchestration helpers (`skillCenterOpenImportList`,
  `skillCenterRunTransfer`, `skillCenterArmConfirm`), the job structs
  (`SkillImportScanJob`, `SkillTransferJob`, `SkillPreviewJob`) that implement
  `OpWork`, `pollSkillCenterOp` that consumes `takePendingOp`, and the panel
  key handling. The install flow adds sibling jobs + a key + a poll branch.
- **`src/renderer/skill_center_renderer.zig`** — draws the matrix/list and the
  current overlays. Extended to draw the URL-input overlay and the checkbox
  pick-list.
- **`src/i18n.zig`** — Skill Center strings live under the "Skill Center v2"
  block; new strings (en + zh) added there.

### Grounding: the example repo's real layout

`fei0810/bear-research-skills` at `main`, under `skills/`, contains **8** skill
directories, each shaped like:

```
skills/bear-map/SKILL.md
skills/bear-map/references/output-system.md
skills/bear-map/references/sci-cli.md
skills/bear-counter/SKILL.md
skills/bear-counter/references/...
... (8 total)
```

So the feature must (a) discover multiple skills under one path, and (b) bundle
**all** files in a skill's directory tree — not just `SKILL.md` — including
nested subfolders like `references/`.

## Approach

**GitHub Git Trees API + raw downloads** (generalizing `skill_update.zig`).
Rejected alternative: `git clone --depth 1` / tarball — it needs `git`/`tar` on
every platform (Windows), downloads the *whole* repo for a small subpath, can't
show the pick-list without fetching everything first, and is far less testable.
The API approach is one API call to enumerate (enabling enumerate-then-pick),
then raw downloads of only the selected files, and keeps a clean pure/impure
split.

## Architecture

### New pure module: `src/skill_install.zig`

Network-free, fully unit-tested. Mirrors `skill_update.zig`'s pure-helper style.

```
pub const RepoRef = struct {
    owner: []const u8,
    repo: []const u8,
    ref: ?[]const u8,     // null → resolve default branch
    subpath: []const u8,  // "" → repo root; e.g. "skills" or "skills/bear-map"
};

pub const SkillEntry = struct {
    name: []u8,           // skill dir basename, e.g. "bear-map"
    root_path: []u8,      // repo-relative dir, e.g. "skills/bear-map"
    files: [][]u8,        // repo-relative blob paths under root_path
    // deinit frees name, root_path, and each files[] + the slice
};
```

- `parseGithubUrl(allocator, url) !RepoRef` — accepts:
  - `https://github.com/<owner>/<repo>/tree/<ref>/<subpath...>`
  - `https://github.com/<owner>/<repo>/tree/<ref>`
  - `https://github.com/<owner>/<repo>/blob/<ref>/<path>/SKILL.md`
    (subpath = the dir containing SKILL.md)
  - `https://github.com/<owner>/<repo>` (ref = null, subpath = "")
  - tolerates a trailing `/`, a trailing `.git` on `<repo>`, and a `www.`/`http`
    scheme variant.
  - **v1 assumption:** `<ref>` is a **single path segment** (a branch with no
    slash, a tag, or a commit SHA). Branch names containing `/` are not
    disambiguated. Documented limitation; returns the first segment as ref and
    the remainder as subpath.
- `treeApiUrl(allocator, owner, repo, ref) ![]u8` →
  `https://api.github.com/repos/<owner>/<repo>/git/trees/<ref>?recursive=1`
- `repoApiUrl(allocator, owner, repo) ![]u8` →
  `https://api.github.com/repos/<owner>/<repo>` (for `default_branch`)
- `rawUrl(allocator, owner, repo, ref, path) ![]u8` →
  `https://raw.githubusercontent.com/<owner>/<repo>/<ref>/<path>`
- `parseDefaultBranch(json) ![]const u8` — pulls `default_branch` from the repo
  API response.
- `findSkills(allocator, tree_json, subpath) ![]SkillEntry` — the core
  enumerator:
  1. Parse the Trees response. (If `truncated == true`, still parse what's
     present but the caller surfaces a "repo too large — tree truncated"
     warning.)
  2. A **skill** is any directory that directly contains a `SKILL.md` blob and
     whose path is either `subpath` itself or nested under `subpath` (any
     directory, if `subpath == ""`). The skill's `root_path` is that directory;
     `name` is its basename. (So a URL pointing straight at one skill dir —
     `subpath == "skills/bear-map"` — yields exactly that one skill.)
  3. For each skill, collect **every blob** whose path starts with
     `root_path + "/"` into `files` (so nested `references/` come along).
  4. Sort entries by name; dedup by `root_path`.
  - Handles all three shapes uniformly: subpath = container of many skills,
    subpath = a single skill dir (contains SKILL.md directly), subpath = repo
    root.

### Impure orchestration (in `AppWindow.zig`, as `OpWork` jobs)

Two background jobs, structured exactly like the existing `SkillImportScanJob`
(own a ctx, run off the UI thread, return an `OpResult`, free ctx in `destroy`):

1. **`SkillInstallEnumerateJob`** — input: the pasted URL.
   - `parseGithubUrl`; if `ref == null`, resolve the ref by GET `repoApiUrl` →
     `parseDefaultBranch`; only if that API call itself fails, fall back to
     trying `main` then `master`.
   - GET `treeApiUrl`; `findSkills(subpath)`.
   - Returns `OpResult.install_enumerate{ repo: RepoRef (owned), entries, truncated }`,
     or `.failed` on parse/network error.
2. **`SkillInstallDownloadJob`** — input: the resolved `RepoRef` + the selected
   `SkillEntry` list.
   - Stage into `<config>/skills/.install-tmp/` (cleared first; always removed).
   - For each selected entry, for each file: `rawUrl(...)` →
     `update_install.downloadAsset(url, tmp/<root_path relative>/...)`.
   - Per-skill atomic replace into `<config>/skills/<name>/` (deleteTree +
     rename), mirroring `skill_update.downloadAndInstall`. A skill whose
     download fails is skipped (counted as failed); others still install.
   - Returns `OpResult.install_done{ installed, overwritten, failed }`.

### Model additions: `src/skill_center.zig`

New `OpResult` variants (with `deinit` arms that free owned data — covered by
the existing leak-safety test pattern):

```
install_enumerate: struct { repo: skill_install.RepoRef, entries: []skill_install.SkillEntry, truncated: bool },
install_done:      struct { installed: usize, overwritten: usize, failed: usize },
```

New `Overlay` variants:

```
url_input: UrlInputState,    // single-line editable buffer + caret
install_pick: InstallPickState, // entries + parallel `checked: []bool` + sel + the owned RepoRef
```

- `UrlInputState` — an owned `std.ArrayListUnmanaged(u8)` buffer with
  insert/backspace/clear and a paste-append helper. Modeled on the
  port-forwarding form's text field. Pure; unit-tested.
- `InstallPickState` — owns the `[]SkillEntry`, a parallel `[]bool` checked
  flags, a `sel` cursor, and the resolved `RepoRef` to pass to the download
  job. Helpers: `toggle(sel)`, `selectAll`/`selectNone`, `selectedEntries()`.

### UI wiring: `AppWindow.zig` + renderer + i18n

- **Key `g`** in the Skill Center panel (when overlay is `.none`) →
  `session.model.setOverlay(.{ .url_input = ... })`, prefilled from the
  clipboard if it looks like a GitHub URL.
- **URL input overlay** key handling: printable chars + backspace edit the
  buffer; `Ctrl/Cmd+V` pastes; `Enter` submits → start `SkillInstallEnumerateJob`
  (busy "Fetching…"); `Esc` cancels.
- **`pollSkillCenterOp`** new branches:
  - `install_enumerate` → if `entries.len == 0`, toast "No skills found at that
    URL"; else open `install_pick` overlay (and toast a truncation warning if
    `truncated`).
  - `install_done` → toast "Installed N skills (M updated, K failed)" and
    trigger the existing library rescan so new skills appear.
- **Pick-list overlay** key handling: ↑/↓ move `sel`, `Space` toggles, `a`
  select-all/none, `Enter` confirms → start `SkillInstallDownloadJob` (busy
  "Installing…"), `Esc` cancels.
- **`skill_center_renderer.zig`** — render the URL-input overlay (prompt + the
  editable line + caret) and the checkbox list (reuses the list renderer with a
  `[x]`/`[ ]` prefix per row).
- **`i18n.zig`** (en + zh) — `g` legend entry, URL prompt, pick-list legend,
  busy strings ("Fetching…", "Installing…"), and result/zero/truncated toasts.

## Data flow

```
[g] → url_input overlay
  ↳ Enter → SkillInstallEnumerateJob (off UI thread)
        parseGithubUrl → (resolve default branch if needed) → GET tree → findSkills
        → OpResult.install_enumerate
  ↳ poll → install_pick overlay (checklist; all checked by default)
        ↳ Enter → SkillInstallDownloadJob (off UI thread)
              per file: rawUrl → downloadAsset → stage; per skill: atomic replace into <config>/skills/<name>
              → OpResult.install_done
        ↳ poll → toast + library rescan → new skills visible in the panel
                 → user presses existing deploy key → deploys to local/remote target
```

## Error handling

- **Bad/non-GitHub URL** → `parseGithubUrl` returns an error → enumerate job
  yields `.failed` → toast "Couldn't parse that GitHub URL".
- **Network / API error / non-200** → `.failed` → toast "Couldn't reach GitHub"
  (covers the 60/hr anonymous rate limit too).
- **Zero skills found** under the subpath → `install_enumerate` with empty
  `entries` → informational toast, no overlay.
- **Truncated tree** (huge repo) → still show what was found, plus a warning
  toast that the listing may be incomplete.
- **Partial download** — staging-then-atomic-move means a failure before the
  replace pass leaves the library untouched; a per-skill failure during the
  pass is counted in `failed` and skipped, leaving other skills installed.
- **Same-name overwrite** — overwrites the library skill; counted in
  `overwritten` and reported in the toast. (Per-skill overwrite confirmation is
  a sanctioned follow-up, not v1.)
- **Concurrency** — install jobs go through the existing `startOp` guard, so a
  second op while one is in flight is rejected (panel already shows "Syncing…").

## Testing

- **`skill_install.zig` unit tests** (pure, run in the fast + full suites):
  - `parseGithubUrl` across every accepted form: `tree/<ref>/<subpath>`,
    `tree/<ref>`, `blob/.../SKILL.md`, bare repo (ref = null), trailing slash,
    `.git` suffix.
  - `treeApiUrl` / `repoApiUrl` / `rawUrl` exact-string assertions.
  - `parseDefaultBranch` on a sample repo JSON.
  - `findSkills` on a **captured `bear-research-skills` tree fixture**
    (`tests/eval/…` or inline): expects 8 skills, each bundling its
    `references/` files; plus the single-skill-dir case (subpath points at one
    skill), the repo-root case, and empty/truncated inputs.
- **`skill_center.zig`**: reuse the existing overlay/`OpResult` leak-safety test
  pattern for the two new `OpResult` variants and the two new overlays
  (`url_input`, `install_pick`), incl. `UrlInputState` edit helpers and
  `InstallPickState` toggle/select-all/selectedEntries.
- **Network + disk orchestration** (`SkillInstall*Job`, `downloadAndInstall`
  equivalent) — validated manually, consistent with how `skill_update.zig`'s
  `downloadAndInstall` is treated (its impure path is not unit-tested).
- **Build gates**: native build + `windows-gnu` cross-compile + `test` (fast) +
  `test-full` all green (modulo the known pre-existing `web_read_cache.zig`
  windows-target failure noted in prior Skill Center work).

## Scope & YAGNI (v1 deferrals)

- **GitHub only** — no GitLab/Bitbucket/arbitrary git host.
- **Public repos only** — no token/auth, no private repos.
- **Single-segment ref** — branch names containing `/` are not disambiguated.
- **Install to library only** — deployment uses the existing flow; no new
  auto-deploy-to-local-Claude path.
- **No per-skill overwrite confirm** — same-name skills are overwritten and the
  count is reported; a confirm dialog is a possible follow-up.
- **Codex/Claude parity** — the library is software-neutral SKILL.md dirs (as
  today); which software a skill deploys to is the deploy step's concern, not
  the install step's.

## Files touched

- **New:** `src/skill_install.zig` (pure module + tests).
- **Edit:** `src/skill_center.zig` (2 `OpResult` variants, 2 overlay states +
  their state structs/tests), `src/AppWindow.zig` (2 jobs, `g` key, URL-input +
  pick-list overlay handling, 2 `pollSkillCenterOp` branches),
  `src/renderer/skill_center_renderer.zig` (2 overlay renderers),
  `src/i18n.zig` (en + zh strings), `src/test_main.zig` / `src/test_fast.zig`
  if the new module needs registering in a suite.
