"""Canonical control-label projection for Product and Ratchet pull requests."""

from __future__ import annotations

from .policy import EXCLUSIVE_DIMENSIONS


PR_INHERITED_DIMENSIONS = ("factory", "validation", "risk", "work", "priority")


def for_product_pr(issue_labels: set[str], *, lifecycle: str) -> set[str]:
    """Project Issue policy dimensions onto its PR, replacing lifecycle state."""
    labels: set[str] = set()
    for dimension in PR_INHERITED_DIMENSIONS:
        labels.update(issue_labels.intersection(EXCLUSIVE_DIMENSIONS[dimension]))
    labels.discard("factory:ratchet")
    labels.add("factory:product")
    labels.add(f"state:{lifecycle}")
    return labels


def for_ratchet_pr(*, lifecycle: str) -> set[str]:
    return {"factory:ratchet", f"state:{lifecycle}"}
