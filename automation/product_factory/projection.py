"""Unified Portal projection for Product and Ratchet software factories."""

from __future__ import annotations

import json
import sqlite3
from datetime import datetime, timedelta, timezone
from typing import Any


PRODUCT_COLUMNS = [
    "intake",
    "triage",
    "design",
    "ready",
    "implementing",
    "review",
    "validation",
    "merge-ready",
    "post-merge-validation",
    "blocked",
    "regressed",
    "closed",
]
RATCHET_COLUMNS = ["offered", "pending", "ready", "failing", "conflicting", "blocked"]
RATCHET_BRANCH_PREFIXES = (
    "cron/metric-ratchet-",
    "cron/quality-ratchet-",
    "cron/quality-escalation-",
)
RATCHET_OFFER_MAX_AGE = timedelta(days=14)


def _parse_time(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _product_items(conn: sqlite3.Connection) -> list[dict[str, Any]]:
    rows = conn.execute(
        "SELECT * FROM cases ORDER BY first_seen_at, issue_number"
    ).fetchall()
    items: list[dict[str, Any]] = []
    for row in rows:
        labels = json.loads(row["labels_json"])
        priority = next(
            (label.removeprefix("priority:") for label in labels if label.startswith("priority:")),
            None,
        )
        validation = next(
            (label.removeprefix("validation:") for label in labels if label.startswith("validation:")),
            None,
        )
        items.append(
            {
                "case_id": row["case_id"],
                "title": row["title"],
                "issue_number": row["issue_number"],
                "issue_url": row["github_url"],
                "status": "closed" if row["github_state"] == "closed" else row["lifecycle_state"],
                "priority": priority,
                "validation": validation,
                "github_state": row["github_state"],
                "policy_valid": bool(row["policy_valid"]),
                "intent_changed": bool(row["intent_changed"]),
            }
        )
    return items


def _is_ratchet_pr(pr: dict[str, Any]) -> bool:
    branch = str(pr.get("head_branch") or "")
    labels = {str(label) for label in pr.get("labels", [])}
    return (
        branch.startswith(RATCHET_BRANCH_PREFIXES)
        or "factory:ratchet" in labels
        or "ratchet" in str(pr.get("title") or "").lower()
    )


def _ratchet_items(
    merge_queue: dict[str, Any] | None,
    ratchet_state: dict[str, Any] | None,
) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    active_targets: set[str] = set()
    for pr in (merge_queue or {}).get("open_prs", []):
        if not isinstance(pr, dict) or not _is_ratchet_pr(pr):
            continue
        branch = str(pr.get("head_branch") or "")
        target = str(pr.get("target") or "")
        if target:
            active_targets.add(target)
        items.append(
            {
                "work_id": f"pr:{pr.get('number')}",
                "title": str(pr.get("title") or f"PR #{pr.get('number')}"),
                "status": str(pr.get("status") or "pending"),
                "kind": "pull_request",
                "pr_number": pr.get("number"),
                "pr_url": pr.get("url"),
                "branch": branch,
                "head_sha": pr.get("head_oid"),
                "details": pr.get("status_details", []),
                "first_seen_at": pr.get("first_seen_at"),
            }
        )

    offers = (ratchet_state or {}).get("offers", {})
    reference_time = _parse_time((merge_queue or {}).get("checked_at"))
    if isinstance(offers, dict):
        for fingerprint, offer in sorted(offers.items()):
            if not isinstance(offer, dict):
                continue
            offered_at = _parse_time(offer.get("offered_at"))
            if (
                reference_time is not None
                and offered_at is not None
                and reference_time - offered_at > RATCHET_OFFER_MAX_AGE
            ):
                continue
            target = str(offer.get("target") or "")
            if target and target in active_targets:
                continue
            kind = str(offer.get("kind") or "candidate")
            items.append(
                {
                    "work_id": f"offer:{fingerprint}",
                    "title": f"{kind.replace('_', ' ')}: {target or fingerprint}",
                    "status": "offered",
                    "kind": kind,
                    "target": target,
                    "offered_at": offer.get("offered_at"),
                    "baseline_sha": offer.get("head"),
                }
            )
    return items


def _summary(items: list[dict[str, Any]], columns: list[str], empty: str) -> str:
    counts = {column: sum(item["status"] == column for item in items) for column in columns}
    return ", ".join(f"{count} {state}" for state, count in counts.items() if count) or empty


def build_model(
    conn: sqlite3.Connection,
    *,
    merge_queue: dict[str, Any] | None = None,
    ratchet_state: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Build the complete shared replace-whole model with two Kanban boards."""
    product_items = _product_items(conn)
    ratchet_items = _ratchet_items(merge_queue, ratchet_state)
    product_summary = _summary(product_items, PRODUCT_COLUMNS, "No mirrored product Cases.")
    ratchet_summary = _summary(ratchet_items, RATCHET_COLUMNS, "No ratchet work visible.")

    return {
        "id": "portal-software-factories",
        "title": "Portal Software Factories",
        "entities": {
            "product_cases": {"key": "case_id", "items": product_items},
            "ratchet_work": {"key": "work_id", "items": ratchet_items},
        },
        "relations": [],
        "views": [
            {
                "type": "markdown",
                "text": (
                    "## Factory control center\n\n"
                    "One shared view, two independently governed queues. "
                    "The Product Factory starts from GitHub Issues; the Ratchet Factory starts from "
                    "measured improvement candidates. Both converge on the shared merge engine."
                ),
            },
            {
                "type": "markdown",
                "text": f"## Product Factory\n\n{product_summary} GitHub owns intent; the Case ledger owns execution evidence.",
            },
            {
                "type": "kanban",
                "entities": ["product_cases"],
                "column": "status",
                "columns": PRODUCT_COLUMNS,
            },
            {
                "type": "table",
                "entities": ["product_cases"],
                "columns": [
                    "issue_number",
                    "title",
                    "priority",
                    "status",
                    "validation",
                    "policy_valid",
                    "github_state",
                ],
            },
            {
                "type": "markdown",
                "text": f"## Ratchet Improvement Factory\n\n{ratchet_summary} Candidates and active improvement PRs share one queue.",
            },
            {
                "type": "kanban",
                "entities": ["ratchet_work"],
                "column": "status",
                "columns": RATCHET_COLUMNS,
            },
            {
                "type": "table",
                "entities": ["ratchet_work"],
                "columns": ["title", "kind", "status", "pr_number", "target", "branch"],
            },
        ],
    }
