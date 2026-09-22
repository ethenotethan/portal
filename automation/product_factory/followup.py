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


@dataclass(frozen=True)
class RemediationCandidate:
    case_id: str
    repo: str
    issue_number: int
    pr_url: str
    validation_task_id: str
    blocker: str
    generation_id: str


def extract_pr_url(text: str | None) -> str | None:
    match = PR_URL_RE.search(text or "")
    return match.group(0) if match else None


def _generation_id(case_id: str, pr_url: str, producer_dispatch_id: int) -> str:
    return hashlib.sha256(
        f"{case_id}:validation:{producer_dispatch_id}:{pr_url}".encode("utf-8")
    ).hexdigest()[:24]


def load_task_states(conn: sqlite3.Connection) -> dict[str, dict[str, Any]]:
    """Read Kanban state, falling back to the latest completed run summary.

    Goal-mode workers can complete with ``tasks.result`` unset while persisting the
    useful completion text in ``task_runs.summary``. Treat that summary as the
    canonical result fallback so follow-up stages are not silently dropped.
    """
    rows = conn.execute(
        """
        SELECT
            t.id,
            t.status,
            t.body,
            COALESCE(
                NULLIF(t.result, ''),
                (
                    SELECT NULLIF(r.summary, '')
                    FROM task_runs r
                    WHERE r.task_id = t.id
                      AND r.outcome = 'completed'
                    ORDER BY r.id DESC
                    LIMIT 1
                ),
                ''
            ) AS result
        FROM tasks t
        """
    ).fetchall()
    return {
        str(row["id"]): {
            "status": str(row["status"]),
            "result": str(row["result"] or ""),
            "body": str(row["body"] or ""),
        }
        for row in rows
    }


def plan_validation_dispatches(
    conn: sqlite3.Connection,
    *,
    task_states: dict[str, dict[str, Any]],
) -> list[ValidationCandidate]:
    """Find completed implementation tasks that published a PR but lack validation."""
    rows = conn.execute(
        """
        SELECT c.case_id, c.repo, c.issue_number, d.id AS producer_dispatch_id, d.task_id
        FROM cases c
        JOIN case_dispatches d ON d.case_id = c.case_id
        WHERE d.stage IN ('implementation', 'remediation')
          AND d.status IN ('queued', 'running')
          AND c.github_state = 'open'
          AND NOT EXISTS (
              SELECT 1 FROM case_dispatches v
              WHERE v.case_id = c.case_id
                AND v.stage = 'validation'
                AND v.id > d.id
          )
        ORDER BY c.issue_number, d.id
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
                generation_id=_generation_id(
                    case_id,
                    pr_url,
                    int(row["producer_dispatch_id"]),
                ),
            )
        )
    return candidates


def plan_remediation_dispatches(
    conn: sqlite3.Connection,
    *,
    task_states: dict[str, dict[str, Any]],
) -> list[RemediationCandidate]:
    """Find blocked completed validations that still need an in-place PR repair."""
    rows = conn.execute(
        """
        SELECT c.case_id, c.repo, c.issue_number, d.id, d.task_id
        FROM cases c
        JOIN case_dispatches d ON d.case_id = c.case_id
        WHERE d.stage = 'validation'
          AND d.status IN ('queued', 'running')
          AND c.github_state = 'open'
          AND c.lifecycle_state = 'blocked'
          AND NOT EXISTS (
              SELECT 1 FROM case_dispatches r
              WHERE r.case_id = c.case_id
                AND r.stage = 'remediation'
                AND r.id > d.id
          )
        ORDER BY c.issue_number, d.id
        """
    ).fetchall()
    candidates: list[RemediationCandidate] = []
    for row in rows:
        task = task_states.get(str(row["task_id"])) or {}
        if task.get("status") != "done":
            continue
        result = str(task.get("result") or "")
        pr_url = extract_pr_url(str(task.get("body") or "")) or extract_pr_url(result)
        if not pr_url:
            continue
        case_id = str(row["case_id"])
        generation_id = hashlib.sha256(
            f"{case_id}:remediation:{int(row['id'])}:{pr_url}".encode("utf-8")
        ).hexdigest()[:24]
        candidates.append(
            RemediationCandidate(
                case_id=case_id,
                repo=str(row["repo"]),
                issue_number=int(row["issue_number"]),
                pr_url=pr_url,
                validation_task_id=str(row["task_id"]),
                blocker=result,
                generation_id=generation_id,
            )
        )
    return candidates


def record_remediation_dispatch(
    conn: sqlite3.Connection,
    candidate: RemediationCandidate,
    *,
    task_id: str,
) -> None:
    """Close the blocked validation generation and queue one in-place repair."""
    row = conn.execute(
        "SELECT last_seen_at FROM cases WHERE case_id = ?",
        (candidate.case_id,),
    ).fetchone()
    if row is None:
        raise ValueError(f"unknown Case: {candidate.case_id}")
    conn.execute(
        "UPDATE case_dispatches SET status = 'done' WHERE task_id = ?",
        (candidate.validation_task_id,),
    )
    conn.execute(
        """
        INSERT OR IGNORE INTO case_dispatches
            (case_id, stage, generation_id, task_id, status, regression, created_at)
        VALUES (?, 'remediation', ?, ?, 'queued', 0, ?)
        """,
        (
            candidate.case_id,
            candidate.generation_id,
            task_id,
            int(row["last_seen_at"]),
        ),
    )
    conn.execute(
        "UPDATE cases SET lifecycle_state = 'implementing' WHERE case_id = ?",
        (candidate.case_id,),
    )
    conn.commit()


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
