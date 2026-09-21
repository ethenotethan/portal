"""Deterministic default admission for newly filed Product Factory issues."""

from __future__ import annotations

import os
import subprocess
from collections.abc import Callable
from typing import Any


INTERACTIVE_TERMS = {
    "ui",
    "ux",
    "view",
    "window",
    "button",
    "toolbar",
    "timeline",
    "screen",
    "animation",
    "layout",
    "render",
    "click",
    "tap",
    "keyboard",
    "mouse",
    "ios",
    "macos",
}
HIGH_RISK_TERMS = {
    "auth",
    "authentication",
    "authorization",
    "credential",
    "secret",
    "permission",
    "security",
    "payment",
    "billing",
    "migration",
    "database schema",
    "delete data",
    "destructive",
    "release",
    "deployment",
}


def _words(issue: dict[str, Any]) -> str:
    return f"{issue.get('title') or ''}\n{issue.get('body') or ''}".lower()


def default_labels(issue: dict[str, Any]) -> set[str]:
    """Return the complete control-label defaults for an unmanaged open Issue.

    Ordinary issues are admitted immediately. Security/destructive/deployment work
    is routed to Design and remains human-gated rather than silently executing.
    """
    existing = {str(label) for label in issue.get("labels", [])}
    if any(label.startswith("factory:") for label in existing):
        return set()

    text = _words(issue)
    interactive = any(term in text for term in INTERACTIVE_TERMS)
    high_risk = any(term in text for term in HIGH_RISK_TERMS)

    labels = {
        "factory:product",
        "priority:P2",
        "validation:interactive" if interactive else "validation:noninteractive",
    }
    if high_risk:
        labels.update({"risk:human-approval", "state:design"})
    else:
        labels.update({"risk:bounded", "factory:ready", "state:ready"})
    return labels


def replace_state_label(
    repo: str,
    issue_number: int,
    *,
    current_labels: set[str],
    new_state: str,
    run: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> None:
    """Atomically replace exclusive lifecycle labels on one GitHub Issue."""
    if not new_state.startswith("state:"):
        raise ValueError("new_state must be a state:* label")
    old_states = sorted(
        label for label in current_labels if label.startswith("state:") and label != new_state
    )
    env = os.environ.copy()
    env.pop("GH_TOKEN", None)
    env.pop("GITHUB_TOKEN", None)
    command = ["gh", "issue", "edit", str(issue_number), "--repo", repo]
    if old_states:
        command.extend(["--remove-label", ",".join(old_states)])
    command.extend(["--add-label", new_state])
    result = run(command, env=env, text=True, capture_output=True, timeout=90, check=False)
    if result.returncode != 0:
        raise RuntimeError((result.stderr or result.stdout or "gh issue edit failed").strip())


def ensure_labels(
    repo: str,
    entries: list[dict[str, str]],
    *,
    run: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> None:
    """Idempotently create/update the Product Factory label manifest."""
    env = os.environ.copy()
    env.pop("GH_TOKEN", None)
    env.pop("GITHUB_TOKEN", None)
    for entry in entries:
        command = [
            "gh", "label", "create", entry["name"],
            "--repo", repo,
            "--color", entry["color"],
            "--description", entry["description"],
            "--force",
        ]
        result = run(command, env=env, text=True, capture_output=True, timeout=90, check=False)
        if result.returncode != 0:
            raise RuntimeError((result.stderr or result.stdout or "gh label create failed").strip())


def apply_labels(
    repo: str,
    issue_number: int,
    labels: set[str],
    *,
    run: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> None:
    """Apply one complete default label set through the authenticated gh identity."""
    if not labels:
        return
    env = os.environ.copy()
    env.pop("GH_TOKEN", None)
    env.pop("GITHUB_TOKEN", None)
    command = [
        "gh",
        "issue",
        "edit",
        str(issue_number),
        "--repo",
        repo,
        "--add-label",
        ",".join(sorted(labels)),
    ]
    result = run(command, env=env, text=True, capture_output=True, timeout=90, check=False)
    if result.returncode != 0:
        raise RuntimeError((result.stderr or result.stdout or "gh issue edit failed").strip())
