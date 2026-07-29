#!/usr/bin/env python3
"""Performance ratchet: fail a PR that makes a hot pure path do MORE work.

The metric is an algorithmic operation COUNT, not wall-clock time. The harness
(Tests/PortalTests/PerfCountHarnessTests.swift), built with -DPERF_COUNTERS,
drives fixed-size fixtures through the instrumented layout paths and records how
many operations each performs into a snapshot (perf-counts.json). Because the
inputs are fixed and the counts are integer tallies, the snapshot is identical
on any machine — no timing flake, and a complexity regression (O(n) → O(n²))
changes a count by orders of magnitude. It does NOT catch constant-factor
slowdowns; that's the hang gate's job. See docs/architecture-rules.md.

FLOOR (the only check — op counts aren't attributable to added lines, so there
is no patch half): every counter in the CURRENT snapshot must be ≤ the value in
the BASE branch's committed perf-baseline.json. The ceiling is read from base
via `git show`, NOT from the PR's own working-tree file — so bumping
perf-baseline.json in the same PR can't wave a regression through; the floor
still compares against what's on main.

Improvements are welcome: a smaller count passes, and `make perf-baseline`
records it so the gain becomes the new ceiling for later PRs. A counter absent
from the base baseline is an initial freeze (a newly instrumented path),
expected and never a failure. A base counter missing from the current snapshot
is noted, not failed (the path may have been removed).

Usage:
    check-perf-ratchet.py SNAPSHOT [--base REF]

SNAPSHOT is the harness's perf-counts.json for THIS build. BASE defaults to
origin/main; its baseline is read via `git show BASE:perf-baseline.json`. If
absent there (guard predates the file), the floor is skipped with a note —
the same grace the other ratchets give.
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

BASELINE = "perf-baseline.json"


def git_show(ref: str, path: str) -> str | None:
    r = subprocess.run(["git", "show", f"{ref}:{path}"], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None


def main() -> int:
    import argparse
    ap = argparse.ArgumentParser(description="Performance ratchet: op-count floor.")
    ap.add_argument("snapshot", help="harness perf-counts.json for THIS build")
    ap.add_argument("--base", default="origin/main", help="base ref (default origin/main)")
    args = ap.parse_args()

    current = json.loads(Path(args.snapshot).read_text()).get("counts", {})
    if not current:
        print("✗ Perf snapshot has no counts — the instrumented harness didn't "
              "run (build with -Xswiftc -DPERF_COUNTERS).")
        return 1

    base_raw = git_show(args.base, BASELINE)
    if base_raw is None:
        print(f"  Floor: no {BASELINE} on {args.base}; skipping (initial freeze).")
        print("\n✓ Performance ratchet passed.")
        return 0
    base_counts = json.loads(base_raw).get("counts", {})

    print("Performance ratchet (algorithmic op counts):")
    grew: list[str] = []
    for key in sorted(current):
        cur = current[key]
        if key not in base_counts:
            print(f"  {key}: {cur}  (new path, initial freeze)")
            continue
        base = base_counts[key]
        if cur > base:
            grew.append(f"  {key}: {base} → {cur}  (+{cur - base}, "
                        f"+{round(100 * (cur - base) / base)}%)")
        else:
            verb = "unchanged" if cur == base else f"−{base - cur}"
            print(f"  {key}: {base} → {cur}  ({verb}).")

    # A base counter the snapshot no longer reports — noted, not failed.
    for key in sorted(set(base_counts) - set(current)):
        print(f"  {key}: {base_counts[key]} → (absent; path removed or fixture "
              f"no longer hits it).")

    if grew:
        print("\n✗ Performance FLOOR regressed — a hot path does more work than base:")
        print("\n".join(grew))
        print("\n  A counter grew, which usually means an algorithm got more\n"
              "  expensive (often O(n)→O(n²)). Profile the path and restore the\n"
              "  complexity. If the extra work is deliberate and justified,\n"
              "  regenerate the ceiling with `make perf-baseline` and explain\n"
              "  why in the PR — the diff should make the tradeoff reviewable.")
        return 1

    print("\n✓ Performance ratchet passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
