#!/usr/bin/env python3
"""Metric ratchet: fail a PR that regresses a tracked code-health metric.

This generalizes `check-baseline-growth.py` (the lint-baseline guard) into a
reusable ratchet over ANY measurable metric. Metrics live in a committed
`metrics-baseline.json`; each is compared against both the base branch's
baseline (floor: never regress globally) and the PR's own diff (patch: leave
touched code at least as clean as you found it).

Metrics wired today: `warnings` (compiler warning sites, from
collect-warnings.py) and `coverage` (testable-layer line coverage, from
collect-coverage.py). Adding another is a collector + a baseline entry + a
handler here — no new gate, no new workflow.

Each metric runs a FLOOR check (never regress vs base) and a PATCH check
(touched code must be clean). For `warnings`:

  FLOOR  — per-category site counts in the CURRENT build must not exceed the
           base branch's baseline counts. Per-category (not just the total) for
           the same reason the lint guard is: fixing one category while adding
           another nets flat but is exactly the regression to catch. A category
           absent from base is an initial freeze (expected), never a failure.

  PATCH  — no warning site may sit on a line this PR ADDED. Added lines come
           from `git diff --unified=0 BASE...HEAD` (right-side line numbers), so
           merely shifting a pre-existing warning down doesn't count — only a
           warning on code you actually wrote. This is the "must improve"
           half: new code carries zero new warnings even while old debt is paid
           down gradually under the floor.

For `coverage` (scoped to testable layers — Views are unreachable by
`swift test`, so they're excluded entirely):

  FLOOR  — aggregate testable-layer line coverage must not drop more than
           COVERAGE_FLOOR_TOLERANCE points vs base.
  PATCH  — of the executable lines this PR ADDED in testable-layer files, at
           least COVERAGE_PATCH_THRESHOLD must be covered (not 100% — defensive
           branches are legitimately hard to hit; a ratio matches industry
           patch-coverage gates). Skipped below COVERAGE_PATCH_MIN_LINES added
           executable lines, where the ratio is too noisy. Added Views,
           comments, and non-executable lines never count toward either side.

Usage:
    check-metrics-ratchet.py [--warnings SNAP] [--coverage SNAP] [--base REF]
    check-metrics-ratchet.py SNAP [BASE]      # back-compat: warnings only

Snapshots are the collector scripts' JSON for THIS build. BASE defaults to
origin/main; the base baseline is read via
`git show BASE:metrics-baseline.json`. If absent there (guard predates it),
each floor check is skipped with a note — same grace the lint guard gives.
"""
import json
import re
import subprocess
import sys
from pathlib import Path

BASELINE = "metrics-baseline.json"
# git diff hunk header: @@ -old,+new @@  → we want the +new added range.
HUNK_RE = re.compile(r"^@@ -\d+(?:,\d+)? \+(?P<start>\d+)(?:,(?P<count>\d+))? @@")


def git_show(ref: str, path: str) -> str | None:
    r = subprocess.run(["git", "show", f"{ref}:{path}"], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None


def added_lines(base_ref: str) -> dict[str, set[int]]:
    """Map file -> set of line numbers ADDED by this branch vs base_ref.

    --unified=0 so hunks carry no context lines; each hunk's +range is purely
    added/modified lines in the new file's numbering.
    """
    r = subprocess.run(
        ["git", "diff", "--unified=0", f"{base_ref}...HEAD"],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        # Diff unavailable (e.g. shallow checkout without base) — treat as no
        # added lines so the patch check is a no-op rather than a false pass
        # disguised as a failure. Floor still runs.
        print(f"  (could not diff against {base_ref}; patch check skipped)")
        return {}
    result: dict[str, set[int]] = {}
    current_file = None
    for line in r.stdout.splitlines():
        if line.startswith("+++ b/"):
            current_file = line[6:]
        elif line.startswith("@@") and current_file:
            m = HUNK_RE.match(line)
            if not m:
                continue
            start = int(m.group("start"))
            count = int(m.group("count") or "1")
            # count == 0 marks a pure deletion at this point — no added lines.
            for ln in range(start, start + count):
                result.setdefault(current_file, set()).add(ln)
    return result


def check_warnings_floor(current: dict, base_snapshot: dict | None) -> list[str]:
    """Return failure messages if any category's count grew vs base."""
    if base_snapshot is None:
        print("  Floor: no baseline on base ref; skipping (initial freeze).")
        return []
    base_counts = base_snapshot.get("counts", {})
    cur_counts = current.get("counts", {})
    grew = {
        cat: (base_counts[cat], n)
        for cat, n in cur_counts.items()
        if cat in base_counts and n > base_counts[cat]
    }
    new_cats = {cat: n for cat, n in cur_counts.items() if cat not in base_counts}
    base_total = sum(base_counts.values())
    cur_total = sum(cur_counts.values())
    if new_cats:
        print("  New warning categories (initial freeze, expected):")
        for cat, n in sorted(new_cats.items()):
            print(f"    {cat}: {n}")
    fails = []
    if grew:
        for cat, (was, now) in sorted(grew.items()):
            fails.append(f"  {cat}: {was} → {now}  (+{now - was})")
    verb = "shrank" if cur_total < base_total else ("unchanged" if cur_total == base_total else "GREW")
    print(f"  Floor: {base_total} → {cur_total} warning sites ({verb}).")
    return fails


def check_warnings_patch(current: dict, added: dict[str, set[int]]) -> list[str]:
    """Return failure messages for any warning site on a PR-added line."""
    fails = []
    for site in current.get("sites", []):
        f, ln = site["file"], site["line"]
        if ln in added.get(f, set()):
            fails.append(f"  {f}:{ln}  [{site['category']}]")
    return fails


# A PR may drop testable-layer coverage by at most this much (percentage
# points) before the floor fails. A small band absorbs measurement jitter and
# the arithmetic dilution of adding a large, well-tested file that still lands
# just under the current average — without letting real erosion through.
COVERAGE_FLOOR_TOLERANCE = 0.5


def check_coverage_floor(current: dict, base: dict | None) -> list[str]:
    """Fail if aggregate testable-layer coverage dropped past the tolerance."""
    if base is None:
        print("  Floor: no coverage baseline on base ref; skipping (initial freeze).")
        return []
    base_pct = base.get("testable_pct", 0.0)
    cur_pct = current.get("testable_pct", 0.0)
    delta = cur_pct - base_pct
    arrow = "→"
    print(f"  Floor: {base_pct}% {arrow} {cur_pct}% testable-layer coverage "
          f"({'+' if delta >= 0 else ''}{round(delta, 2)} pts).")
    if delta < -COVERAGE_FLOOR_TOLERANCE:
        return [f"  coverage dropped {round(-delta, 2)} pts "
                f"(> {COVERAGE_FLOOR_TOLERANCE} pt tolerance): {base_pct}% → {cur_pct}%"]
    return []


# A PR's ADDED executable lines in testable layers must be at least this
# fraction covered. Not 100%: defensive branches (catch blocks, nil-coalescing
# fallbacks) are legitimately hard to exercise, and a zero-tolerance rule taxes
# every feature PR. A threshold matches industry patch-coverage gates and still
# blocks a PR that ships a meaningful chunk of untested logic. Only enforced
# once the PR adds enough executable lines to measure meaningfully.
COVERAGE_PATCH_THRESHOLD = 0.80
COVERAGE_PATCH_MIN_LINES = 10


def check_coverage_patch(current: dict, added: dict[str, set[int]]) -> list[str]:
    """Fail if too small a fraction of PR-added testable-layer lines are covered.

    Denominator = added lines that are EXECUTABLE in a testable-layer file
    (the collector's `covered_lines` ∪ `uncovered`, intersected with the diff).
    Added comments, blanks, and non-executable declarations aren't in either
    set, so they're excluded. Views aren't tracked at all, so adding a View is
    always clean. Below COVERAGE_PATCH_MIN_LINES added executable lines the
    ratio is too noisy to judge, so the check is skipped.
    """
    uncovered = current.get("uncovered", {})
    covered = current.get("covered_lines", {})
    added_uncovered, added_covered = [], 0
    for f, add in added.items():
        miss = set(uncovered.get(f, [])) & add
        hit = set(covered.get(f, [])) & add
        added_covered += len(hit)
        for ln in sorted(miss):
            added_uncovered.append(f"{f}:{ln}")
    total = added_covered + len(added_uncovered)
    if total < COVERAGE_PATCH_MIN_LINES:
        print(f"  Patch: {total} added executable line(s) in testable layers "
              f"(< {COVERAGE_PATCH_MIN_LINES}; too few to judge, skipping).")
        return []
    ratio = added_covered / total
    print(f"  Patch: {added_covered}/{total} added executable lines covered "
          f"({round(100 * ratio, 1)}%; need {int(COVERAGE_PATCH_THRESHOLD * 100)}%).")
    if ratio < COVERAGE_PATCH_THRESHOLD:
        head = added_uncovered[:15]
        more = f"\n  … and {len(added_uncovered) - 15} more" if len(added_uncovered) > 15 else ""
        return [f"  patch coverage {round(100 * ratio, 1)}% < "
                f"{int(COVERAGE_PATCH_THRESHOLD * 100)}%; uncovered added lines:"]  \
               + [f"    {u}" for u in head] + ([more] if more else [])
    return []


def _report(kind: str, floor_fails: list[str], patch_fails: list[str],
            floor_hint: str, patch_hint: str) -> bool:
    ok = True
    if floor_fails:
        ok = False
        print(f"\n✗ {kind} FLOOR regressed:")
        print("\n".join(floor_fails))
        print(floor_hint)
    if patch_fails:
        ok = False
        print(f"\n✗ {kind} PATCH not clean — {len(patch_fails)} issue(s) on lines this PR added:")
        print("\n".join(patch_fails))
        print(patch_hint)
    return ok


def main() -> int:
    import argparse
    ap = argparse.ArgumentParser(description="Metric ratchet: floor + patch checks.")
    ap.add_argument("--warnings", help="collect-warnings.py snapshot for THIS build")
    ap.add_argument("--coverage", help="collect-coverage.py snapshot for THIS build")
    ap.add_argument("--base", default="origin/main", help="base ref (default origin/main)")
    # Back-compat: `check-metrics-ratchet.py SNAPSHOT [BASE]` still runs the
    # warnings check, so the existing Makefile/CI invocation keeps working.
    ap.add_argument("pos_snapshot", nargs="?", help=argparse.SUPPRESS)
    ap.add_argument("pos_base", nargs="?", help=argparse.SUPPRESS)
    args = ap.parse_args()

    warnings_path = args.warnings or args.pos_snapshot
    base_ref = args.base if args.base != "origin/main" else (args.pos_base or "origin/main")

    if not warnings_path and not args.coverage:
        ap.print_help()
        return 2

    base_raw = git_show(base_ref, BASELINE)
    base_doc = json.loads(base_raw) if base_raw else None
    added = added_lines(base_ref)

    ok = True

    if warnings_path:
        current = json.loads(Path(warnings_path).read_text())
        base_warnings = base_doc.get("warnings") if base_doc else None
        print("Warning ratchet:")
        floor = check_warnings_floor(current, base_warnings)
        patch = check_warnings_patch(current, added)
        ok &= _report(
            "Warning", floor, patch,
            "\n  The build must not gain warnings overall. Fix the new warning,\n"
            "  or if a category legitimately moved, pay another down so the\n"
            "  count holds. Regenerate the baseline only to record paydown.",
            "\n  New code must compile warning-free even while old debt lingers.\n"
            "  Resolve these before merging.",
        )

    if args.coverage:
        current = json.loads(Path(args.coverage).read_text())
        base_cov = base_doc.get("coverage") if base_doc else None
        print("Coverage ratchet:")
        floor = check_coverage_floor(current, base_cov)
        patch = check_coverage_patch(current, added)
        ok &= _report(
            "Coverage", floor, patch,
            "\n  Aggregate coverage of the testable layers (Models, Services,\n"
            "  ViewModels, Utilities) must not erode. Add tests, or regenerate\n"
            "  the baseline only to record a real gain.",
            "\n  Executable lines you ADDED in a testable layer must be covered\n"
            "  by a test. (Views are exempt — swift test can't reach them.)\n"
            "  Add a test that exercises these lines.",
        )

    if ok:
        print("\n✓ Metric ratchet passed.")
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
