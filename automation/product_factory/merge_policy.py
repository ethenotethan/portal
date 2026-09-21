"""Evidence-only acceptance policies for shared merge and closure engines."""

from __future__ import annotations

from typing import Any, NamedTuple


class PolicyResult(NamedTuple):
    accepted: bool
    missing: tuple[str, ...]


def _exact_pass(record: Any, sha: str) -> bool:
    return (
        isinstance(record, dict)
        and record.get("outcome") == "pass"
        and bool(sha)
        and record.get("sha") == sha
    )


def _evaluate_product(evidence: dict[str, Any]) -> PolicyResult:
    missing: list[str] = []
    head_sha = str(evidence.get("head_sha") or "")
    implementation_generation = evidence.get("implementation_generation")
    review = evidence.get("review") or {}
    validation = evidence.get("validation") or {}

    if not evidence.get("linked_issue"):
        missing.append("linked Issue")
    if not evidence.get("accepted_intent_digest"):
        missing.append("accepted-intent digest")
    if not (
        _exact_pass(review, head_sha)
        and review.get("generation")
        and review.get("generation") != implementation_generation
    ):
        missing.append("independent review")

    mode = validation.get("mode")
    if mode == "interactive":
        valid = (
            _exact_pass(validation, head_sha)
            and validation.get("runner") == "cua-driver"
            and validation.get("generation")
            and validation.get("generation") != implementation_generation
        )
        if not valid:
            missing.append("exact-sha validation")
    elif mode == "noninteractive":
        exemption = (
            _exact_pass(validation, head_sha)
            and validation.get("policy_confirmed") is True
            and validation.get("interactive_files_touched") is False
            and validation.get("generation")
            and validation.get("generation") != implementation_generation
        )
        if not exemption:
            missing.append("valid noninteractive exemption")
    else:
        missing.append("validation classification")

    if not _exact_pass(evidence.get("ci"), head_sha):
        missing.append("exact-sha green CI")
    return PolicyResult(not missing, tuple(missing))


def _evaluate_ratchet(evidence: dict[str, Any]) -> PolicyResult:
    missing: list[str] = []
    head_sha = str(evidence.get("head_sha") or "")
    metric = evidence.get("metric") or {}
    if not (
        metric.get("committed") is True
        and isinstance(metric.get("delta"), (int, float))
        and metric["delta"] > 0
        and metric.get("sha") == head_sha
    ):
        missing.append("committed positive metric delta")
    if not _exact_pass(evidence.get("ci"), head_sha):
        missing.append("exact-sha green CI")
    return PolicyResult(not missing, tuple(missing))


def evaluate(profile: str, evidence: dict[str, Any]) -> PolicyResult:
    """Evaluate immutable evidence against one merge-policy profile."""
    if profile == "product":
        return _evaluate_product(evidence)
    if profile == "ratchet":
        return _evaluate_ratchet(evidence)
    raise ValueError(f"unknown merge policy profile: {profile}")


def evaluate_closure(evidence: dict[str, Any]) -> PolicyResult:
    """Gate Issue closure on post-merge validation of accepted main."""
    accepted_main_sha = str(evidence.get("accepted_main_sha") or "")
    post_merge = evidence.get("post_merge_validation") or {}
    missing: list[str] = []
    if not accepted_main_sha:
        missing.append("accepted main SHA")
    if not (
        _exact_pass(post_merge, accepted_main_sha)
        and post_merge.get("generation")
    ):
        missing.append("post-merge validation on accepted main")
    return PolicyResult(not missing, tuple(missing))
