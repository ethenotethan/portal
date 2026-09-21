"""Pure product-factory label and transition policy."""

from __future__ import annotations

import hashlib
import json
from typing import Iterable, NamedTuple


class ValidationResult(NamedTuple):
    accepted: bool
    reason: str | None = None


EXCLUSIVE_DIMENSIONS = {
    "factory": frozenset({"factory:product", "factory:ratchet"}),
    "state": frozenset(
        {
            "state:intake",
            "state:triage",
            "state:design",
            "state:ready",
            "state:implementing",
            "state:review",
            "state:validation",
            "state:merge-ready",
            "state:post-merge-validation",
            "state:blocked",
            "state:regressed",
        }
    ),
    "validation": frozenset({"validation:interactive", "validation:noninteractive"}),
    "risk": frozenset({"risk:bounded", "risk:human-approval"}),
    "work": frozenset({"work:parent", "work:child"}),
    "priority": frozenset({"priority:P0", "priority:P1", "priority:P2", "priority:P3"}),
}


def validate_labels(labels: set[str]) -> ValidationResult:
    """Validate mutually exclusive control-label dimensions."""
    for dimension, allowed in EXCLUSIVE_DIMENSIONS.items():
        matches = sorted(labels.intersection(allowed))
        if len(matches) > 1:
            return ValidationResult(False, f"conflicting {dimension} labels: {', '.join(matches)}")
    return ValidationResult(True)


def evaluate_admission(labels: set[str]) -> ValidationResult:
    """Validate an Issue's request to enter executable product work."""
    valid = validate_labels(labels)
    if not valid.accepted or "factory:ready" not in labels:
        return valid
    if "factory:product" not in labels:
        return ValidationResult(False, "factory:ready requires factory:product")
    required_dimensions = ("priority", "validation", "risk")
    if any(len(labels.intersection(EXCLUSIVE_DIMENSIONS[name])) != 1 for name in required_dimensions):
        return ValidationResult(
            False,
            "ready admission requires exactly one priority, validation, and risk label",
        )
    if "risk:human-approval" in labels and "factory:design-approved" not in labels:
        return ValidationResult(False, "risk:human-approval requires factory:design-approved")
    if len(labels.intersection(EXCLUSIVE_DIMENSIONS["state"])) != 1:
        return ValidationResult(False, "factory:ready requires exactly one lifecycle state label")
    return ValidationResult(True)


def intent_digest(body: str, labels: Iterable[str], *, parent_issue: int | None) -> str:
    """Return a stable digest of the accepted, material GitHub intent."""
    material_labels = set().union(
        EXCLUSIVE_DIMENSIONS["factory"],
        EXCLUSIVE_DIMENSIONS["validation"],
        EXCLUSIVE_DIMENSIONS["risk"],
        EXCLUSIVE_DIMENSIONS["work"],
        EXCLUSIVE_DIMENSIONS["priority"],
        {"factory:ready", "factory:design-approved"},
    )
    payload = {
        "body": body.replace("\r\n", "\n").strip(),
        "control_labels": sorted(set(labels).intersection(material_labels)),
        "parent_issue": parent_issue,
    }
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


ALLOWED_TRANSITIONS = {
    "intake": frozenset({"triage"}),
    "triage": frozenset({"design", "ready", "blocked"}),
    "design": frozenset({"triage", "ready", "blocked"}),
    "ready": frozenset({"triage", "implementing", "blocked"}),
    "implementing": frozenset({"triage", "review", "blocked"}),
    "review": frozenset({"implementing", "validation", "blocked"}),
    "validation": frozenset({"implementing", "merge-ready", "blocked"}),
    "merge-ready": frozenset({"post-merge-validation", "blocked"}),
    "post-merge-validation": frozenset({"regressed"}),
    "blocked": frozenset({"triage"}),
    "regressed": frozenset({"implementing", "blocked"}),
}


def validate_transition(current: str, requested: str) -> ValidationResult:
    """Validate a requested lifecycle edge, allowing idempotent repeats."""
    if current == requested or requested in ALLOWED_TRANSITIONS.get(current, frozenset()):
        return ValidationResult(True)
    return ValidationResult(False, f"invalid lifecycle transition: {current} -> {requested}")


def validate_label_actor(
    *,
    actor: str,
    added: set[str],
    maintainers: set[str],
    factory_bot: str,
) -> ValidationResult:
    """Authorize a label event without letting automation grant human approval."""
    if "factory:design-approved" in added and actor not in maintainers:
        return ValidationResult(False, "factory:design-approved requires a maintainer actor")
    control_labels = set().union(*EXCLUSIVE_DIMENSIONS.values()) | {
        "factory:ready",
        "factory:design-approved",
    }
    if added.intersection(control_labels) and actor not in maintainers | {factory_bot}:
        return ValidationResult(False, f"untrusted control-label actor: {actor}")
    return ValidationResult(True)
