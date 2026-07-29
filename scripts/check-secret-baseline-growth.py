#!/usr/bin/env python3
"""Fail if .gitleaksignore gained accepted-finding fingerprints versus base.

The secret-scan gate runs `gitleaks dir --baseline-path`/`--gitleaks-ignore-path`
so anything fingerprinted in .gitleaksignore is excluded and only NEW findings
fail. That makes .gitleaksignore a tempting escape hatch: paste the fingerprint
of a real leaked credential and the scan goes green while the secret stays in
the tree. The file's header says "only accepted false-positives, only with a
PR reason," but that's honor-system.

This turns the policy into an enforced invariant — the secret-scan analog of
scripts/check-baseline-growth.py for swiftlint. It compares the count of
fingerprint lines in the PR's .gitleaksignore against the base branch and fails
if it grew. Removing fingerprints (a finding was actually fixed, or was never
real) always passes.

A grown ignore-list is not always wrong — a genuine false-positive sometimes
must be accepted — but it must never happen SILENTLY. When the count grows,
this check fails and the PR author has to justify each added fingerprint in the
PR description, exactly like baselining a new lint violation.

Usage:
    check-secret-baseline-growth.py [BASE_REF]

BASE_REF defaults to origin/main. The base file is read via
`git show <BASE_REF>:.gitleaksignore`; if it doesn't exist there (guard predates
it, or brand-new repo), the check passes with a note.
"""
import subprocess
import sys
from pathlib import Path

IGNORE_FILE = ".gitleaksignore"


def fingerprints(raw: str) -> set[str]:
    """Non-comment, non-blank lines — each is one accepted-finding fingerprint.

    A trailing `# why it's safe` comment is stripped so annotating a
    fingerprint never changes its identity.
    """
    out: set[str] = set()
    for line in raw.splitlines():
        code = line.split("#", 1)[0].strip()
        if code:
            out.add(code)
    return out


def base_ignore(base_ref: str) -> str | None:
    """The ignore file as it exists on the base branch, or None if absent."""
    result = subprocess.run(
        ["git", "show", f"{base_ref}:{IGNORE_FILE}"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return None
    return result.stdout


def main() -> int:
    base_ref = sys.argv[1] if len(sys.argv) > 1 else "origin/main"

    current_path = Path(IGNORE_FILE)
    if not current_path.exists():
        print(f"No {IGNORE_FILE} in the working tree; nothing to check.")
        return 0

    base_raw = base_ignore(base_ref)
    if base_raw is None:
        print(
            f"No {IGNORE_FILE} on {base_ref} (guard predates it or new branch); "
            "skipping growth check."
        )
        return 0

    base = fingerprints(base_raw)
    current = fingerprints(current_path.read_text())

    added = current - base
    removed = base - current

    if removed:
        print(f"  Removed {len(removed)} accepted fingerprint(s) — finding fixed or retired (good).")

    if added:
        print(f"✗ {IGNORE_FILE} GREW — new gitleaks findings were accepted instead of removed.")
        print(f"  Base ({base_ref}): {len(base)} → PR: {len(current)} accepted fingerprints\n")
        for fp in sorted(added):
            print(f"  + {fp}")
        print(
            f"\n{IGNORE_FILE} records ACCEPTED false-positives only. A new fingerprint here\n"
            "means a finding was waved through. Remove the secret from the tree instead.\n"
            "If the finding is a genuine false-positive (rare), justify each added line\n"
            "explicitly in the PR description — this check exists so it can never happen\n"
            "silently. See docs/architecture-rules.md § The secret-scan ratchet."
        )
        return 1

    verb = "shrank" if removed else "unchanged"
    print(f"✓ {IGNORE_FILE} {verb}: {len(base)} → {len(current)} accepted fingerprints. None added.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
