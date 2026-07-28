#!/usr/bin/env python3
"""Parse a `swift build` log into a de-duplicated, categorized warning snapshot.

`swift build` re-emits the same warning once per module that recompiles, so a
raw `grep -c warning:` over-counts wildly (685 lines for 52 real sites in this
repo). The honest unit is a unique warning *site*: (repo-relative file, line,
column, category). This script collapses the log to that set and reports both a
per-category count (for the ratchet's floor check) and the full site list (for
the patch-level "no new warning on a changed line" check).

Category is the compiler's own diagnostic group tag when present
(`[#ActorIsolatedCall]`, `[#SendableClosureCaptures]`, …) — stable across
wording changes — falling back to a normalized message prefix (digits and
quoted identifiers stripped) so untagged warnings still bucket sensibly.

Usage:
    collect-warnings.py BUILD_LOG [--json OUT]

Reads BUILD_LOG (a captured `swift build 2>&1`), writes a JSON document to OUT
(default stdout):

    {
      "counts": { "ActorIsolatedCall": 30, "DeprecatedDeclaration": 8, ... },
      "total": 52,
      "sites": [ {"file": "...", "line": 12, "col": 5, "category": "..."}, ... ]
    }

Only the working-tree-relative path is stored so the snapshot is portable
across checkouts (CI runs under /Users/runner/work/..., local under /tmp/...) —
the same portability fix the lint baseline needed.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

# A diagnostic line: <path>:<line>:<col>: warning: <message>
WARNING_RE = re.compile(
    r"^(?P<file>.+?\.swift):(?P<line>\d+):(?P<col>\d+): warning: (?P<msg>.*)$"
)
# The compiler's diagnostic-group tag, e.g. "[#ActorIsolatedCall]".
TAG_RE = re.compile(r"\[#(?P<tag>[A-Za-z]+)\]")
# Noise stripped when deriving a category from an untagged message: quoted
# identifiers and bare numbers vary site to site but name the same rule.
QUOTED_RE = re.compile(r"'[^']*'")
NUMBER_RE = re.compile(r"\b\d+\b")


def categorize(msg: str) -> str:
    """Stable bucket for a warning: its diagnostic tag, else a scrubbed prefix."""
    tag = TAG_RE.search(msg)
    if tag:
        return tag.group("tag")
    # Untagged: normalize the leading clause into a slug. Drop everything from
    # the first tag bracket, strip quoted names and digits, take the first few
    # words so wording tails don't fragment the bucket.
    head = msg.split("[#", 1)[0]
    head = QUOTED_RE.sub("X", head)
    head = NUMBER_RE.sub("N", head)
    words = re.findall(r"[a-zA-Z]+", head)[:6]
    return "msg:" + "-".join(w.lower() for w in words) if words else "msg:unknown"


def relativize(path: str, root: str) -> str:
    """Repo-relative, forward-slash path so snapshots compare across checkouts.

    macOS is case-insensitive but case-preserving, and the Swift compiler
    normalizes paths to lowercase (e.g. ``projects`` vs ``Projects``), so a
    plain ``startswith`` leaves absolute paths in the snapshot. Compare
    case-insensitively when stripping.
    """
    p = path
    # Absolute paths under the build root → relative (case-insensitive:
    # compiler may lowercase the path while $(PWD) preserves the original case).
    if p.lower().startswith(root.lower().rstrip("/") + "/"):
        p = p[len(root.rstrip("/")):]
    p = p.lstrip("/")
    # A leading ./ from some emitters.
    if p.startswith("./"):
        p = p[2:]
    return p


def collect(log_text: str, root: str) -> dict:
    sites = {}  # (file, line, col, category) -> None, dedup key
    for line in log_text.splitlines():
        m = WARNING_RE.match(line.strip())
        if not m:
            continue
        # Skip warnings from dependencies / the build cache; only OUR sources.
        raw_file = m.group("file")
        rel = relativize(raw_file, root)
        if rel.startswith(".build/") or "/checkouts/" in rel or rel.startswith("/"):
            continue
        cat = categorize(m.group("msg"))
        key = (rel, int(m.group("line")), int(m.group("col")), cat)
        sites[key] = None

    site_list = [
        {"file": f, "line": ln, "col": c, "category": cat}
        for (f, ln, c, cat) in sorted(sites)
    ]
    counts = {}
    for s in site_list:
        counts[s["category"]] = counts.get(s["category"], 0) + 1
    return {
        "counts": dict(sorted(counts.items())),
        "total": len(site_list),
        "sites": site_list,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("build_log", help="captured `swift build 2>&1` output")
    ap.add_argument("--json", help="output path (default: stdout)")
    ap.add_argument(
        "--root",
        default=os.getcwd(),
        help="build root to strip from absolute paths (default: cwd)",
    )
    args = ap.parse_args()

    log_text = Path(args.build_log).read_text(errors="replace")
    snapshot = collect(log_text, args.root)
    out = json.dumps(snapshot, indent=2) + "\n"
    if args.json:
        Path(args.json).write_text(out)
        print(f"Wrote {snapshot['total']} unique warning sites to {args.json}")
    else:
        sys.stdout.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
