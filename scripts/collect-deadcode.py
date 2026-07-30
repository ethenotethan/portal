#!/usr/bin/env python3
"""Reduce a Periphery scan into a dead-code snapshot for the metric ratchet.

Periphery reports declarations nothing references: unused vars/functions/types,
assign-only properties, redundant public ACL / protocol conformances. In a
SwiftUI app the raw count is large and partly noise — Periphery can't see
KeyPath / reflection / SwiftUI-runtime uses, so it flags `body`-adjacent members
and Codable fields that ARE used. That's fine for a ratchet: we don't fix the
backlog, we FREEZE it and only fail when the count RISES. A false positive lives
harmlessly in the baseline; a genuinely new unused declaration is the signal.

The metric is the total finding count, with a per-hint breakdown for the diff.
Locations are made repo-relative (Periphery emits absolute paths) so the
snapshot compares across checkouts, like every other collector here.

Usage:
    collect-deadcode.py PERIPHERY_JSON [--json OUT] [--root DIR]

PERIPHERY_JSON is the output of `periphery scan --format json`.

Output:
    {
      "counts": { "unused": 986, "assignOnlyProperty": 117, ... },
      "total": 1114,
      "sites": [ {"file": "...", "line": 4, "kind": "var.global",
                  "name": "log", "hint": "unused"}, ... ]
    }
"""
import argparse
import json
import os
import re
import sys
from pathlib import Path

LOC_RE = re.compile(r"^(?P<file>.+?):(?P<line>\d+):(?P<col>\d+)$")


def relativize(path: str, root: str) -> str:
    p = path
    if root and p.startswith(root):
        p = p[len(root):]
    return p.lstrip("/")


def collect(records: list, root: str) -> dict:
    # One finding per (file, line, name, hint): a record may carry several
    # hints (e.g. unused + redundantPublicAccessibility), each a distinct piece
    # of debt, but the same hint on the same decl is one site.
    seen = set()
    sites = []
    for r in records:
        loc = r.get("location", "")
        m = LOC_RE.match(loc)
        if not m:
            continue
        rel = relativize(m.group("file"), root)
        line = int(m.group("line"))
        name = r.get("name")
        kind = r.get("kind")
        for hint in (r.get("hints") or ["unused"]):
            key = (rel, line, name, hint)
            if key in seen:
                continue
            seen.add(key)
            sites.append({"file": rel, "line": line, "kind": kind,
                          "name": name, "hint": hint})
    # Stable order so the committed baseline diff is readable.
    sites.sort(key=lambda s: (s["file"], s["line"], s["name"] or "", s["hint"]))
    counts: dict[str, int] = {}
    for s in sites:
        counts[s["hint"]] = counts.get(s["hint"], 0) + 1
    return {
        "counts": dict(sorted(counts.items())),
        "total": len(sites),
        "sites": sites,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("periphery_json", help="`periphery scan --format json` output")
    ap.add_argument("--json", help="output path (default: stdout)")
    ap.add_argument("--root", default=os.getcwd(), help="prefix to strip (repo root)")
    args = ap.parse_args()

    records = json.loads(Path(args.periphery_json).read_text())
    snapshot = collect(records, args.root)
    out = json.dumps(snapshot, indent=2) + "\n"
    if args.json:
        Path(args.json).write_text(out)
        print(f"Found {snapshot['total']} dead-code finding(s) → {args.json}")
    else:
        sys.stdout.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
