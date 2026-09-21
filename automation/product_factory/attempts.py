"""Bounded substantive retry policy."""

from __future__ import annotations

from typing import NamedTuple


class AttemptDecision(NamedTuple):
    action: str
    substantive_failures: int


def after_failure(
    substantive_failures: int,
    *,
    transient: bool,
    max_corrective: int,
) -> AttemptDecision:
    """Classify a failed cycle without charging infrastructure failures."""
    if transient:
        return AttemptDecision("retry", substantive_failures)
    updated = substantive_failures + 1
    return AttemptDecision("retry" if updated <= max_corrective else "block", updated)
