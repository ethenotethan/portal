#!/usr/bin/env python3
"""Count disabled / skipped / known-issue tests in the test suite.

A skipped test is a test that has been switched off or handed an escape hatch,
so it no longer defends the behavior it names. Under a swarm optimizing against
the suite, disabling a failing test is the laziest way to "pass" — this metric
makes that move visible and, gated at a zero floor, blocking.

The suite is swift-testing (`@Test` / `#expect`), so the idioms that turn a
test off are:

    @Test(.disabled("flaky"))              # trait: unconditionally off
    @Suite(.disabled())                    # whole suite off
    @Test(.enabled(if: cond))              # conditionally off (env-gated)
    withKnownIssue { ... }                 # body may fail without failing run

XCTest idioms are counted too (`XCTSkip`, `XCTSkipIf`, `XCTSkipUnless`) so the
gate keeps working if a file ever uses the older framework. Each match is one
skip *site* — file + line + kind — reported alongside the per-kind counts.

Usage:
    collect-skipped-tests.py TESTS_DIR [--json OUT] [--root DIR]

Output:
    {
      "counts": { "disabled": 0, "known_issue": 0, "xctest_skip": 0 },
      "total": 0,
      "sites": [ {"file": "...", "line": 12, "kind": "disabled"}, ... ]
    }

The path is repo-relative (via --root) so the snapshot compares across
checkouts, exactly like the warning and coverage collectors.
"""
import argparse
import json
import os
import re
import sys
from pathlib import Path

# Each pattern maps a regex to the kind of skip it marks. `.disabled(` and
# `.enabled(if:` are swift-testing traits; withKnownIssue is a swift-testing
# escape hatch; the XCT* forms are the XCTest equivalents. Kept deliberately
# textual: a lint-style scan is enough to catch the idioms and needs no build.
PATTERNS = [
    (re.compile(r"\.disabled\s*\("), "disabled"),
    (re.compile(r"\.enabled\s*\(\s*if:"), "disabled"),
    (re.compile(r"\bwithKnownIssue\b"), "known_issue"),
    (re.compile(r"\bXCTSkip(?:If|Unless)?\b"), "xctest_skip"),
]


def relativize(path: str, root: str) -> str:
    p = path
    if root and p.startswith(root):
        p = p[len(root):]
    return p.lstrip("/")


def collect(tests_dir: str, root: str) -> dict:
    sites = []
    for swift in sorted(Path(tests_dir).rglob("*.swift")):
        rel = relativize(str(swift), root)
        for i, line in enumerate(swift.read_text(errors="replace").splitlines(), 1):
            # A line-comment before any code is not a real skip (e.g. a doc
            # comment mentioning `.disabled`). Strip a trailing `//` comment and
            # ignore fully-commented lines so prose can't inflate the count.
            code = line.split("//", 1)[0]
            if not code.strip():
                continue
            for pat, kind in PATTERNS:
                if pat.search(code):
                    sites.append({"file": rel, "line": i, "kind": kind})
                    break  # one skip per line — don't double-count
    counts: dict[str, int] = {}
    for s in sites:
        counts[s["kind"]] = counts.get(s["kind"], 0) + 1
    return {
        "counts": dict(sorted(counts.items())),
        "total": len(sites),
        "sites": sites,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("tests_dir", help="path to the Tests/ tree")
    ap.add_argument("--json", help="output path (default: stdout)")
    ap.add_argument("--root", default=os.getcwd(), help="prefix to strip (repo root)")
    args = ap.parse_args()

    snapshot = collect(args.tests_dir, args.root)
    out = json.dumps(snapshot, indent=2) + "\n"
    if args.json:
        Path(args.json).write_text(out)
        print(f"Found {snapshot['total']} skipped/disabled test site(s) → {args.json}")
    else:
        sys.stdout.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
