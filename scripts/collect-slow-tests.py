#!/usr/bin/env python3
"""Count tests that take longer than a threshold, from a `swift test` log.

The unit suite is the inner loop of every PR, and its wall time is the sum of
its slowest members. A test that sleeps its way to a timeout, or drives a real
clock instead of an injected one, quietly costs every future CI run; two such
tests recently took ~100 s each in a suite whose other 2,000 tests finish in
under 20 s. This metric makes that visible and, as a floor, blocking.

The gate is on a COUNT over a generous threshold (default 5 s), not on total
time: individual durations wobble with runner load, but a test either is or
isn't an order of magnitude slower than its peers, so the count is stable
enough to ratchet. Tests between 1 s and the threshold are reported in the
snapshot for information only (`watchlist`) and never counted.

Both test-framework log formats are parsed:

    ✔ Test "name" passed after 12.345 seconds.        (swift-testing)
    ✘ Test name() failed after 12.345 seconds.
    Test Case '-[Suite test]' passed (12.345 seconds).  (XCTest)

Suite summary lines ("Suite … passed after", "Test run with …") are ignored.

Usage:
    collect-slow-tests.py TEST_LOG [--threshold SECONDS] [--json OUT]

Output (same shape as the other metric collectors; `file` carries the test
name so the shared checker's site listing reads naturally):
    {
      "threshold_seconds": 5.0,
      "counts": { "over_threshold": 0 },
      "total": 0,
      "sites": [ {"file": "Suite/test", "seconds": 12.3, "kind": "over_threshold"} ],
      "watchlist": [ {"file": "...", "seconds": 1.7} ]
    }
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

SWIFT_TESTING = re.compile(
    r"Test\s+(?P<name>\"[^\"]+\"|[A-Za-z_][A-Za-z0-9_]*\([^)]*\))\s+"
    r"(?:passed|failed)\s+after\s+(?P<secs>\d+(?:\.\d+)?)\s+seconds"
)
XCTEST = re.compile(
    r"Test Case '-\[(?P<suite>\S+)\s+(?P<name>[^\]]+)\]'\s+(?:passed|failed)\s+"
    r"\((?P<secs>\d+(?:\.\d+)?)\s+seconds\)"
)
WATCH_SECONDS = 1.0


def parse(log: str) -> dict[str, float]:
    """Map test name → duration. A test seen twice (re-run) keeps its max."""
    durations: dict[str, float] = {}
    for line in log.splitlines():
        if "Suite " in line and " Test " not in line:
            continue
        m = SWIFT_TESTING.search(line)
        if m:
            name = m.group("name").strip('"')
            durations[name] = max(durations.get(name, 0.0), float(m.group("secs")))
            continue
        m = XCTEST.search(line)
        if m:
            name = f"{m.group('suite')}/{m.group('name')}"
            durations[name] = max(durations.get(name, 0.0), float(m.group("secs")))
    return durations


def collect(log: str, threshold: float) -> dict:
    durations = parse(log)
    slow = sorted(
        ((name, secs) for name, secs in durations.items() if secs > threshold),
        key=lambda item: -item[1],
    )
    watch = sorted(
        ((name, secs) for name, secs in durations.items() if WATCH_SECONDS < secs <= threshold),
        key=lambda item: -item[1],
    )
    sites = [{"file": name, "seconds": round(secs, 3), "kind": "over_threshold"} for name, secs in slow]
    return {
        "threshold_seconds": threshold,
        "tests_parsed": len(durations),
        "counts": {"over_threshold": len(sites)},
        "total": len(sites),
        "sites": sites,
        "watchlist": [{"file": name, "seconds": round(secs, 3)} for name, secs in watch],
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("test_log", help="captured `swift test 2>&1` output")
    ap.add_argument("--threshold", type=float, default=5.0, help="seconds (default 5)")
    ap.add_argument("--json", help="output path (default: stdout)")
    args = ap.parse_args()

    snapshot = collect(Path(args.test_log).read_text(errors="replace"), args.threshold)
    out = json.dumps(snapshot, indent=2) + "\n"
    if args.json:
        Path(args.json).write_text(out)
        print(
            f"Parsed {snapshot['tests_parsed']} test durations; "
            f"{snapshot['total']} over {args.threshold:g}s → {args.json}"
        )
    else:
        sys.stdout.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
