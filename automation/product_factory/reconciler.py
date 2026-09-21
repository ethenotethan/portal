"""Durable, idempotent reconciliation from GitHub Issues into Cases."""

from __future__ import annotations

import hashlib
import json
import sqlite3
from dataclasses import dataclass
from typing import Any

from automation.product_factory.policy import (
    evaluate_admission,
    intent_digest,
    validate_transition,
)


SCHEMA = """
CREATE TABLE IF NOT EXISTS cases (
    case_id TEXT PRIMARY KEY,
    repo TEXT NOT NULL,
    issue_number INTEGER NOT NULL,
    node_id TEXT NOT NULL,
    title TEXT NOT NULL,
    body TEXT NOT NULL,
    author TEXT NOT NULL,
    labels_json TEXT NOT NULL,
    github_state TEXT NOT NULL,
    github_url TEXT NOT NULL,
    github_updated_at TEXT NOT NULL,
    parent_issue INTEGER,
    lifecycle_state TEXT NOT NULL,
    policy_valid INTEGER NOT NULL,
    policy_reason TEXT,
    accepted_intent_digest TEXT,
    intent_changed INTEGER NOT NULL DEFAULT 0,
    snapshot_fingerprint TEXT NOT NULL,
    first_seen_at INTEGER NOT NULL,
    last_seen_at INTEGER NOT NULL,
    UNIQUE(repo, issue_number)
);
CREATE TABLE IF NOT EXISTS case_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    case_id TEXT NOT NULL,
    source_key TEXT NOT NULL UNIQUE,
    kind TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    observed_at INTEGER NOT NULL
);
"""


@dataclass(frozen=True)
class ReconcileOutcome:
    case_id: str
    changed: bool
    intent_changed: bool
    proposed_actions: tuple[dict[str, Any], ...]


def initialize(conn: sqlite3.Connection) -> None:
    conn.executescript(SCHEMA)
    conn.commit()


def _case_id(issue: dict[str, Any]) -> str:
    return f"github:{issue['repo']}#{int(issue['number'])}"


def _lifecycle(labels: set[str]) -> str:
    states = sorted(label.removeprefix("state:") for label in labels if label.startswith("state:"))
    return states[0] if len(states) == 1 else "intake"


def _snapshot(issue: dict[str, Any], labels: list[str]) -> dict[str, Any]:
    return {
        "node_id": str(issue["node_id"]),
        "title": str(issue.get("title") or ""),
        "body": str(issue.get("body") or ""),
        "author": str(issue.get("author") or "unknown"),
        "labels": labels,
        "state": str(issue.get("state") or "open"),
        "url": str(issue.get("url") or ""),
        "updated_at": str(issue.get("updated_at") or ""),
        "parent_issue": issue.get("parent_issue"),
    }


def _fingerprint(snapshot: dict[str, Any]) -> str:
    encoded = json.dumps(snapshot, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _repair_actions(
    reason: str,
    labels: set[str],
    *,
    safe_state: str = "triage",
) -> tuple[dict[str, Any], ...]:
    restored = sorted(
        {label for label in labels if not label.startswith("state:")}
        | {f"state:{safe_state}"}
    )
    return (
        {
            "type": "comment",
            "body": f"Product-factory transition rejected: {reason}. Restoring the last safe lifecycle state.",
        },
        {"type": "restore_labels", "labels": restored},
    )


def reconcile_issue(
    conn: sqlite3.Connection,
    issue: dict[str, Any],
    *,
    observed_at: int,
) -> ReconcileOutcome:
    """Upsert one Issue snapshot and return deterministic, unapplied actions."""
    labels_list = sorted(set(str(label) for label in issue.get("labels", [])))
    labels = set(labels_list)
    snapshot = _snapshot(issue, labels_list)
    fingerprint = _fingerprint(snapshot)
    case_id = _case_id(issue)
    existing = conn.execute("SELECT * FROM cases WHERE case_id = ?", (case_id,)).fetchone()
    if existing is not None and snapshot["updated_at"] < existing["github_updated_at"]:
        return ReconcileOutcome(case_id, False, bool(existing["intent_changed"]), ())
    if existing is not None and existing["snapshot_fingerprint"] == fingerprint:
        conn.execute("UPDATE cases SET last_seen_at = ? WHERE case_id = ?", (observed_at, case_id))
        conn.commit()
        return ReconcileOutcome(case_id, False, bool(existing["intent_changed"]), ())

    admission = evaluate_admission(labels)
    requested_lifecycle = _lifecycle(labels)
    lifecycle = requested_lifecycle if admission.accepted else (
        existing["lifecycle_state"] if existing is not None else "intake"
    )
    policy_valid = admission.accepted
    policy_reason = admission.reason
    digest: str | None = None
    changed_intent = False
    actions: tuple[dict[str, Any], ...] = ()

    if admission.accepted and existing is not None:
        transition = validate_transition(existing["lifecycle_state"], requested_lifecycle)
        if not transition.accepted:
            lifecycle = existing["lifecycle_state"]
            policy_valid = False
            policy_reason = transition.reason
            actions = _repair_actions(
                transition.reason or "invalid lifecycle transition",
                labels,
                safe_state=lifecycle,
            )

    if existing is not None and existing["intent_changed"]:
        changed_intent = True
        lifecycle = "triage"
        policy_valid = False
        policy_reason = "accepted intent changed; explicit reapproval required"
        actions = _repair_actions(policy_reason, labels)
    elif not admission.accepted:
        actions = _repair_actions(
            admission.reason or "invalid control labels",
            labels,
            safe_state=lifecycle,
        )
    elif existing is not None and existing["accepted_intent_digest"]:
        current_digest = intent_digest(
            snapshot["body"],
            labels,
            parent_issue=snapshot["parent_issue"],
        )
        if current_digest != existing["accepted_intent_digest"]:
            changed_intent = True
            lifecycle = "triage"
            policy_valid = False
            policy_reason = "accepted intent changed after Ready"
            actions = _repair_actions(policy_reason, labels)
        else:
            digest = existing["accepted_intent_digest"]
    elif admission.accepted and "factory:ready" in labels:
        digest = intent_digest(
            snapshot["body"],
            labels,
            parent_issue=snapshot["parent_issue"],
        )
        if requested_lifecycle == "ready":
            actions = ({"type": "dispatch", "stage": "implementation"},)

    payload = (
        case_id,
        issue["repo"],
        int(issue["number"]),
        snapshot["node_id"],
        snapshot["title"],
        snapshot["body"],
        snapshot["author"],
        json.dumps(labels_list, separators=(",", ":")),
        snapshot["state"],
        snapshot["url"],
        snapshot["updated_at"],
        snapshot["parent_issue"],
        lifecycle,
        1 if policy_valid else 0,
        policy_reason,
        digest,
        1 if changed_intent else 0,
        fingerprint,
        observed_at,
        observed_at,
    )
    conn.execute(
        """
        INSERT INTO cases (
            case_id, repo, issue_number, node_id, title, body, author,
            labels_json, github_state, github_url, github_updated_at,
            parent_issue, lifecycle_state, policy_valid, policy_reason,
            accepted_intent_digest, intent_changed, snapshot_fingerprint,
            first_seen_at, last_seen_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(case_id) DO UPDATE SET
            node_id=excluded.node_id,
            title=excluded.title,
            body=excluded.body,
            author=excluded.author,
            labels_json=excluded.labels_json,
            github_state=excluded.github_state,
            github_url=excluded.github_url,
            github_updated_at=excluded.github_updated_at,
            parent_issue=excluded.parent_issue,
            lifecycle_state=excluded.lifecycle_state,
            policy_valid=excluded.policy_valid,
            policy_reason=excluded.policy_reason,
            accepted_intent_digest=excluded.accepted_intent_digest,
            intent_changed=excluded.intent_changed,
            snapshot_fingerprint=excluded.snapshot_fingerprint,
            last_seen_at=excluded.last_seen_at
        """,
        payload,
    )
    event_payload = {
        "fingerprint": fingerprint,
        "lifecycle_state": lifecycle,
        "policy_valid": policy_valid,
        "policy_reason": policy_reason,
        "intent_changed": changed_intent,
        "proposed_actions": actions,
    }
    conn.execute(
        "INSERT OR IGNORE INTO case_events (case_id, source_key, kind, payload_json, observed_at) "
        "VALUES (?, ?, 'reconciled', ?, ?)",
        (case_id, f"github-snapshot:{case_id}:{fingerprint}", json.dumps(event_payload, sort_keys=True), observed_at),
    )
    conn.commit()
    return ReconcileOutcome(case_id, True, changed_intent, actions)
