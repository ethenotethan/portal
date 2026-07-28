#!/usr/bin/env python3
"""Metric ratchet: fail a PR that regresses a tracked code-health metric.

This generalizes `check-baseline-growth.py` (the lint-baseline guard) into a
reusable ratchet over ANY measurable metric. Metrics live in a committed
`metrics-baseline.json`; each is compared against both the base branch's
baseline (floor: never regress globally) and the PR's own diff (patch: leave
touched code at least as clean as you found it).

The only metric wired today is `warnings` (compiler warning sites, produced by
collect-warnings.py). Adding another metric is a collector + a baseline entry +
a handler here — no new gate, no new workflow.

Two independent checks run for `warnings`:

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

Usage:
    check-metrics-ratchet.py CURRENT_SNAPSHOT [BASE_REF]

CURRENT_SNAPSHOT is collect-warnings.py's JSON for THIS build. BASE_REF
defaults to origin/main; the base baseline is read via
`git show BASE_REF:metrics-baseline.json`. If absent there (guard predates it),
the floor check is skipped with a note — same grace the lint guard gives.
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


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    snapshot_path = sys.argv[1]
    base_ref = sys.argv[2] if len(sys.argv) > 2 else "origin/main"

    current = json.loads(Path(snapshot_path).read_text())
    base_raw = git_show(base_ref, BASELINE)
    base_doc = json.loads(base_raw) if base_raw else None
    base_warnings = base_doc.get("warnings") if base_doc else None

    print("Warning ratchet:")
    floor_fails = check_warnings_floor(current, base_warnings)

    added = added_lines(base_ref)
    patch_fails = check_warnings_patch(current, added)

    ok = True
    if floor_fails:
        ok = False
        print("\n✗ FLOOR regressed — a warning category grew vs base:")
        print("\n".join(floor_fails))
        print(
            "\n  The build must not gain warnings overall. Fix the new warning,\n"
            "  or if a category legitimately moved, pay another down so the\n"
            "  count holds. Regenerate the baseline only to record paydown."
        )
    if patch_fails:
        ok = False
        print(f"\n✗ PATCH not clean — {len(patch_fails)} warning(s) on lines this PR added:")
        print("\n".join(patch_fails))
        print(
            "\n  New code must compile warning-free even while old debt lingers.\n"
            "  Resolve these before merging."
        )

    if ok:
        print("\n✓ Warning ratchet passed: no category grew, no warning on added lines.")
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
