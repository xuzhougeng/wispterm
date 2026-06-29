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
cp -R wiki/assets /tmp/wt-wiki/   # copies image assets used by pages
rm -f /tmp/wt-wiki/README.md      # README.md is staging-only, not a wiki page
cd /tmp/wt-wiki && git add -A && git commit -m "docs: publish user wiki" && git push
```

`check_wiki.py` is not copied (the `*.md` glob skips it).
