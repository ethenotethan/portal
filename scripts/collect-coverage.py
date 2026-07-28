#!/usr/bin/env python3
"""Turn `llvm-cov export` output into a coverage snapshot for the metric ratchet.

`swift test --enable-code-coverage` reaches the package-testable layers (Models,
Services, ViewModels, Utilities) but NOT SwiftUI Views — the app target isn't
launched, so View bodies never execute. Measured here that split is stark:
Models ~58%, ViewModels ~31%, Services ~25%, but Views ~3% across 63k lines.

So this metric is scoped to the TESTABLE layers. A global percentage would be
dominated by unreachable View code (and by dependency sources in the raw
export), making it both noisy and unactionable. The snapshot records:

    {
      "testable_pct": 34.12,               # aggregate over testable layers
      "layers": { "Models": {...}, ... },  # per-layer covered/count/pct
      "uncovered": { "Sources/Portal/Services/Foo.swift": [12, 13, 40], ... },
      "covered_lines": { "Sources/Portal/Services/Foo.swift": [10, 11], ... }
    }

`uncovered` and `covered_lines` list executable line numbers in testable-layer
files — uncovered (count == 0) and covered (count > 0) respectively. The patch
check intersects both with the PR's added lines: the added lines that are
executable form the denominator, the covered subset the numerator. Views are
excluded from every field, so adding a View never fails the gate.

Usage:
    collect-coverage.py LLVM_COV_EXPORT_JSON [--json OUT] [--root DIR]

LLVM_COV_EXPORT_JSON is the output of:
    xcrun llvm-cov export -instr-profile <profdata> <test-binary>
(no -summary-only — we need per-line segments for the patch check).
"""
import argparse
import json
import sys
from pathlib import Path
from typing import Dict, List, Optional

# Layers under Sources/Portal/ that `swift test` can actually exercise. Views
# are deliberately excluded — untestable without launching the app target.
TESTABLE_LAYERS = {"Models", "Services", "ViewModels", "Utilities"}
MARKER = "/Sources/Portal/"


def layer_of(path: str) -> Optional[str]:
    """The Sources/Portal/<layer> bucket for a path, or None if not ours."""
    if MARKER not in path:
        return None
    rest = path.split(MARKER, 1)[1]
    return rest.split("/", 1)[0] if "/" in rest else "root"


def relativize(path: str, root: str) -> str:
    if path.lower().startswith(root.lower().rstrip("/") + "/"):
        path = path[len(root.rstrip("/")):]
    return path.lstrip("/")


def collect(export: dict, root: str) -> dict:
    files = export["data"][0]["files"]
    layers: Dict[str, List[int]] = {}  # layer -> [covered, count]
    uncovered: Dict[str, List[int]] = {}
    covered_lines: Dict[str, List[int]] = {}

    for f in files:
        layer = layer_of(f["filename"])
        if layer not in TESTABLE_LAYERS:
            continue
        s = f["summary"]["lines"]
        agg = layers.setdefault(layer, [0, 0])
        agg[0] += s["covered"]
        agg[1] += s["count"]

        # Per-line: llvm-cov "segments" are [line, col, count, hasCount,
        # isRegionEntry, isGutter]. A segment with hasCount marks an executable
        # line; count == 0 is uncovered, count > 0 covered. A line can carry
        # several segments (nested regions) — treat it covered if ANY segment
        # ran, so partial coverage counts toward the patch numerator.
        rel = relativize(f["filename"], root)
        hit, miss = set(), set()
        for seg in f.get("segments", []):
            if len(seg) >= 4 and seg[3]:
                (hit if seg[2] > 0 else miss).add(seg[0])
        miss -= hit  # a line that ran anywhere is covered, not uncovered
        if miss:
            uncovered[rel] = sorted(miss)
        if hit:
            covered_lines[rel] = sorted(hit)

    layer_report = {
        name: {
            "covered": cov,
            "count": tot,
            "pct": round(100 * cov / tot, 2) if tot else 0.0,
        }
        for name, (cov, tot) in sorted(layers.items())
    }
    total_cov = sum(v["covered"] for v in layer_report.values())
    total_cnt = sum(v["count"] for v in layer_report.values())
    return {
        "testable_pct": round(100 * total_cov / total_cnt, 2) if total_cnt else 0.0,
        "testable_covered": total_cov,
        "testable_count": total_cnt,
        "layers": layer_report,
        "uncovered": dict(sorted(uncovered.items())),
        "covered_lines": dict(sorted(covered_lines.items())),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("export_json", help="llvm-cov export output (full, with segments)")
    ap.add_argument("--json", help="output path (default: stdout)")
    ap.add_argument("--root", default="", help="path prefix to strip (repo root)")
    args = ap.parse_args()

    export = json.loads(Path(args.export_json).read_text())
    snapshot = collect(export, args.root)
    out = json.dumps(snapshot, indent=2) + "\n"
    if args.json:
        Path(args.json).write_text(out)
        print(
            f"Testable-layer coverage: {snapshot['testable_pct']}% "
            f"({snapshot['testable_covered']}/{snapshot['testable_count']} lines) → {args.json}"
        )
    else:
        sys.stdout.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
