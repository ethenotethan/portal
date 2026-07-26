#!/usr/bin/env python3
"""Fail if .swiftlint-baseline gained frozen violations versus the base branch.

The baseline is a record of *pre-existing* lint debt: CI runs
`swiftlint --baseline`, so anything already in it is excluded and only NEW
violations fail. That makes `make lint-baseline` a tempting escape hatch —
regenerate the baseline and a brand-new violation gets frozen instead of fixed,
silently defeating every rule we enforce. `docs/architecture-rules.md` says
"only ever regenerate to pay debt down," but that's honor-system.

This script turns the policy into an enforced invariant. It compares the
per-rule entry counts in the PR's baseline against the base branch's baseline
and fails if ANY rule's count grew. Per-rule (not just the total) is deliberate:
paying down 5 explicit_acl while freezing 5 new force_unwraps leaves the total
flat but is exactly the regression we want to catch.

Shrinking counts (real debt paydown) always pass. Adding a genuinely intended
baseline entry (e.g. a new discouraged_optional_boolean that's truly tri-state)
is a deliberate act: it must be called out in review, and this check makes it
impossible to do silently — the diff turns red and the PR has to justify it.

Usage:
    check-baseline-growth.py [BASE_REF]

BASE_REF defaults to origin/main. The base baseline is read via
`git show <BASE_REF>:.swiftlint-baseline`; if the file doesn't exist there
(baseline predates this guard, or brand-new repo), the check passes with a note.
"""
import json
import subprocess
import sys
from collections import Counter
from pathlib import Path

BASELINE = ".swiftlint-baseline"


def rule_counts(raw: str) -> Counter:
    """Map ruleIdentifier -> number of frozen entries in a baseline document."""
    entries = json.loads(raw)
    return Counter(e["violation"]["ruleIdentifier"] for e in entries)


def base_baseline(base_ref: str) -> str | None:
    """The baseline as it exists on the base branch, or None if absent there."""
    result = subprocess.run(
        ["git", "show", f"{base_ref}:{BASELINE}"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return None
    return result.stdout


def main() -> int:
    base_ref = sys.argv[1] if len(sys.argv) > 1 else "origin/main"

    current_path = Path(BASELINE)
    if not current_path.exists():
        # No baseline in the working tree — nothing to freeze, nothing to grow.
        print(f"No {BASELINE} in the working tree; nothing to check.")
        return 0

    base_raw = base_baseline(base_ref)
    if base_raw is None:
        print(
            f"No {BASELINE} on {base_ref} (guard predates it or new branch); "
            "skipping growth check."
        )
        return 0

    base = rule_counts(base_raw)
    current = rule_counts(current_path.read_text())

    grew = {
        rule: (base.get(rule, 0), count)
        for rule, count in current.items()
        if count > base.get(rule, 0)
    }

    base_total, current_total = sum(base.values()), sum(current.values())

    if grew:
        print("✗ Baseline GREW — new violations were frozen instead of fixed.")
        print(f"  Base ({base_ref}): {base_total} entries → PR: {current_total} entries\n")
        for rule, (was, now) in sorted(grew.items()):
            print(f"  {rule}: {was} → {now}  (+{now - was})")
        print(
            "\nThe baseline records OLD debt only. A rule's count must never grow.\n"
            "Fix the new violation instead of baselining it. If the entry is\n"
            "genuinely intended (rare), say so explicitly in the PR description —\n"
            "this check is here so that can never happen silently.\n"
            "See docs/architecture-rules.md § The lint baseline (frozen debt)."
        )
        return 1

    shrank = current_total < base_total
    verb = "shrank" if shrank else "unchanged"
    print(f"✓ Baseline {verb}: {base_total} → {current_total} entries. No rule grew.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
