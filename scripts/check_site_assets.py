#!/usr/bin/env python3
"""Check the product site's local asset references and its quoted repo stats.

The site is hand-written static HTML with no build step, so a renamed
screenshot or stylesheet produces a page that still deploys and still looks
fine in review — the image just silently 404s for every visitor. This is the
cheapest thing that catches that before it ships.

It also checks the file and line counts in the hero against
`architecture/model/model.json`, which the architecture compiler regenerates
from source. Those numbers are the first thing a reader compares against the
observatory's own header, and nothing else would notice them going stale.

Exits non-zero listing every problem. Run from anywhere:

    python3 scripts/check_site_assets.py
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SITE = ROOT / "site"
MODEL = ROOT / "architecture/model/model.json"

# `src="..."` and `href="..."` values. Skipping anything that is absolute, a
# fragment, or another scheme — only same-tree files are ours to verify.
REFERENCE = re.compile(r'(?:src|href)\s*=\s*"([^"]+)"')
EXTERNAL = ("http://", "https://", "//", "#", "mailto:", "data:")


def unresolved(html_path: Path) -> list[str]:
    """Every local reference in `html_path` that does not resolve to a file."""
    missing = []
    for reference in REFERENCE.findall(html_path.read_text(encoding="utf-8")):
        if reference.startswith(EXTERNAL):
            continue
        # Directory links (`architecture/`) resolve through the deploy-time
        # assembly, not this tree, so they can't be checked here.
        if reference.endswith("/"):
            continue
        target = (html_path.parent / reference.split("#")[0].split("?")[0]).resolve()
        if not target.is_file():
            missing.append(f"{html_path.relative_to(ROOT)} → {reference}")
    return missing


def stale_stats(index: Path) -> list[str]:
    """Hero stats in `index` that disagree with the generated architecture model.

    Matched loosely — any `<strong>` holding the expected number counts, so the
    markup can be rearranged freely; only the value has to stay true.
    """
    inventory = json.loads(MODEL.read_text(encoding="utf-8"))["inventory"]
    html = index.read_text(encoding="utf-8")
    quoted = re.findall(r"<strong>([\d,]+)</strong>", html)
    values = {value.replace(",", "") for value in quoted}

    problems = []
    for label, expected in (
        ("swift_files", inventory["swift_files"]),
        ("swift_lines", inventory["swift_lines"]),
    ):
        if str(expected) not in values:
            problems.append(
                f"{index.relative_to(ROOT)}: model reports {label}={expected:,}, "
                f"but no hero stat quotes it (found {', '.join(sorted(quoted)) or 'none'})"
            )
    return problems


def main() -> int:
    pages = sorted(SITE.rglob("*.html"))
    if not pages:
        print(f"error: no HTML found under {SITE.relative_to(ROOT)}", file=sys.stderr)
        return 1

    missing = [entry for page in pages for entry in unresolved(page)]
    if missing:
        print("error: the product site references files that do not exist:", file=sys.stderr)
        for entry in missing:
            print(f"  {entry}", file=sys.stderr)
        return 1

    stale = stale_stats(SITE / "index.html")
    if stale:
        print("error: the product site quotes stale repository stats:", file=sys.stderr)
        for entry in stale:
            print(f"  {entry}", file=sys.stderr)
        print(
            "  run `make architecture` first; if the model moved, update the "
            "hero stats in site/index.html to match.",
            file=sys.stderr,
        )
        return 1

    print(f"ok: {len(pages)} page(s) under site/, references resolve and stats match the model")
    return 0


if __name__ == "__main__":
    sys.exit(main())
