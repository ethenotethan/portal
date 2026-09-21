"""Advance completed implementation generations into independent validation."""

from __future__ import annotations

import hashlib
import re
import sqlite3
from dataclasses import dataclass
from typing import Any


PR_URL_RE = re.compile(r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/\d+")


@dataclass(frozen=True)
class ValidationCandidate:
    case_id: str
    repo: str
    issue_number: int
    pr_url: str
    implementation_task_id: str
    generation_id: str


def extract_pr_url(text: str | None) -> str | None:
    match = PR_URL_RE.search(text or "")
    return match.group(0) if match else None


def _generation_id(case_id: str, pr_url: str) -> str:
    return hashlib.sha256(f"{case_id}:validation:{pr_url}".encode("utf-8")).hexdigest()[:24]


def plan_validation_dispatches(
    conn: sqlite3.Connection,
    *,
    task_states: dict[str, dict[str, Any]],
) -> list[ValidationCandidate]:
    """Find completed implementation tasks that published a PR but lack validation."""
    rows = conn.execute(
        """
        SELECT c.case_id, c.repo, c.issue_number, d.task_id
        FROM cases c
        JOIN case_dispatches d ON d.case_id = c.case_id
        WHERE d.stage = 'implementation'
          AND d.status IN ('queued', 'running')
          AND c.github_state = 'open'
          AND NOT EXISTS (
              SELECT 1 FROM case_dispatches v
              WHERE v.case_id = c.case_id AND v.stage = 'validation'
          )
        ORDER BY c.issue_number
        """
    ).fetchall()
    candidates: list[ValidationCandidate] = []
    for row in rows:
        task = task_states.get(str(row["task_id"])) or {}
        if task.get("status") != "done":
            continue
        pr_url = extract_pr_url(str(task.get("result") or ""))
        if not pr_url:
            continue
        case_id = str(row["case_id"])
        candidates.append(
            ValidationCandidate(
                case_id=case_id,
                repo=str(row["repo"]),
                issue_number=int(row["issue_number"]),
                pr_url=pr_url,
                implementation_task_id=str(row["task_id"]),
                generation_id=_generation_id(case_id, pr_url),
            )
        )
    return candidates


def record_validation_dispatch(
    conn: sqlite3.Connection,
    candidate: ValidationCandidate,
    *,
    task_id: str,
) -> None:
    """Record one idempotent validation generation and advance the Case."""
    row = conn.execute(
        "SELECT last_seen_at FROM cases WHERE case_id = ?",
        (candidate.case_id,),
    ).fetchone()
    if row is None:
        raise ValueError(f"unknown Case: {candidate.case_id}")
    conn.execute(
        "UPDATE case_dispatches SET status = 'done' WHERE task_id = ?",
        (candidate.implementation_task_id,),
    )
    conn.execute(
        """
        INSERT OR IGNORE INTO case_dispatches
            (case_id, stage, generation_id, task_id, status, regression, created_at)
        VALUES (?, 'validation', ?, ?, 'queued', 0, ?)
        """,
        (
            candidate.case_id,
            candidate.generation_id,
            task_id,
            int(row["last_seen_at"]),
        ),
    )
    conn.execute(
        "UPDATE cases SET lifecycle_state = 'review' WHERE case_id = ?",
        (candidate.case_id,),
    )
    conn.commit()
