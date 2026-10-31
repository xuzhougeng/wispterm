# Screen-detection manifests

These TOML files describe how to read a terminal agent's live screen and
decide whether it is **idle**, **working**, or **blocked** (waiting for an
approval, answer, or permission). They drive the tab badges and attention
notifications for agents that have no WispTerm hook installed.

## Provenance

The files are copied **verbatim** from herdr's
[`src/detect/manifests/`](https://github.com/herdrdev/herdr/tree/master/src/detect/manifests)
and are licensed under the Apache License 2.0 (see [`LICENSE`](LICENSE) in
this directory). Keep them byte-identical to upstream so they can be
refreshed by copying; WispTerm-specific adjustments belong in
`screen_manifest.zig`, not in these files.

| Upstream commit | Date       | Engine version |
|-----------------|------------|----------------|
| `ee5bfb5041bb`  | 2026-10-29 | 3              |

## Refreshing

1. Copy the current `*.toml` files from herdr's `src/detect/manifests/`.
2. Run `zig build test`. The fast suite parses every bundled manifest with
   the embedded engine (`screen_manifest.zig`) and fails on any construct the
   engine does not support, so drift is caught before it ships.
3. If herdr bumped `min_engine_version` past `screen_manifest.engine_version`,
   port the new region or matcher semantics first (herdr's
   `src/detect/manifest.rs` is the reference), then raise the constant.
4. Update the table above.

The file name → agent mapping lives in `screen_manifest.bundled`; a new
upstream manifest needs an `App` value in `detector.zig` and a row there.

## Format

```toml
id = "codex"                 # agent label; aliases = [...] are accepted too
version = "2026.10.11.1"
min_engine_version = 3

[[rules]]
id = "live_strong_blocker"   # unique within the file
state = "blocked"            # idle | working | blocked | unknown
priority = 900               # highest matching rule wins; ties keep file order
region = "after_last_prompt_marker"
visible_blocker = true       # the rule saw live UI chrome, not scrollback text
contains = ["press enter to confirm"]   # case-insensitive, all must hit
regex = ['\s+\z']            # all must match the region
line_regex = ['^\s*❯']       # each must match some line
any = [ { contains = ["yes"] }, { contains = ["❯"] } ]   # at least one gate
all = [ ... ]                # every gate
not = [ ... ]                # no gate may match
```

Regions: `whole_recent`, `bottom_lines(N)`, `bottom_non_empty_lines(N)`,
`top_non_empty_lines(N)`, `after_last_prompt_marker`,
`before_current_prompt_marker`, `whole_recent_without_current_prompt_marker`,
`current_prompt_block_marker`, `after_current_prompt_block_marker`,
`prompt_box_body`, `above_prompt_box`, `last_non_empty_above_prompt_box`,
`after_last_horizontal_rule`, `osc_title`, `osc_progress`.
