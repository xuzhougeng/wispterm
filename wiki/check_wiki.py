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
    "Configuration", "Themes-Appearance", "Keyboard-Shortcuts", "Command-Snippets",
    "File-Explorer",
    "SSH-Remote-Development", "Port-Forwarding", "AI-Copilot",
    "Agent-Terminal-Control", "Browser-Jupyter-Panel", "Inline-Images",
    "Remote-Access", "FAQ",
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
