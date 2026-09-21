"""Deterministic capacity planner for Product Factory dispatches."""

from __future__ import annotations

import hashlib
import json
import sqlite3
from dataclasses import dataclass


DISPATCH_SCHEMA = """
CREATE TABLE IF NOT EXISTS case_dispatches (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    case_id TEXT NOT NULL,
    stage TEXT NOT NULL,
    generation_id TEXT NOT NULL UNIQUE,
    task_id TEXT,
    status TEXT NOT NULL,
    regression INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    UNIQUE(case_id, stage, generation_id)
);
"""

ACTIVE_STATES = {"implementing", "review", "validation", "merge-ready", "post-merge-validation"}
PRIORITY_ORDER = {"priority:P0": 0, "priority:P1": 1, "priority:P2": 2, "priority:P3": 3}


@dataclass(frozen=True)
class DispatchSpec:
    case_id: str
    repo: str
    issue_number: int
    issue_url: str
    title: str
    intent_digest: str
    stage: str
    generation_id: str
    regression: bool


def _initialize(conn: sqlite3.Connection) -> None:
    conn.executescript(DISPATCH_SCHEMA)
    conn.commit()


def _priority(labels_json: str) -> int:
    labels = set(json.loads(labels_json))
    return min((rank for label, rank in PRIORITY_ORDER.items() if label in labels), default=99)


def _generation_id(case_id: str, stage: str, ordinal: int) -> str:
    seed = f"{case_id}:{stage}:{ordinal}".encode("utf-8")
    return hashlib.sha256(seed).hexdigest()[:24]


def _spec(conn: sqlite3.Connection, row: sqlite3.Row, *, regression: bool) -> DispatchSpec:
    count = conn.execute(
        "SELECT COUNT(*) FROM case_dispatches WHERE case_id = ? AND stage = 'implementation'",
        (row["case_id"],),
    ).fetchone()[0]
    return DispatchSpec(
        case_id=row["case_id"],
        repo=row["repo"],
        issue_number=row["issue_number"],
        issue_url=row["github_url"],
        title=row["title"],
        intent_digest=row["accepted_intent_digest"] or "",
        stage="implementation",
        generation_id=_generation_id(row["case_id"], "implementation", count + 1),
        regression=regression,
    )


def plan_dispatches(
    conn: sqlite3.Connection,
    *,
    ordinary_limit: int,
    reserved_regression: int,
) -> list[DispatchSpec]:
    """Select bounded Ready and regressed Cases without mutating the ledger."""
    _initialize(conn)
    active_placeholders = ",".join("?" for _ in ACTIVE_STATES)
    active_ordinary = conn.execute(
        f"SELECT COUNT(*) FROM cases WHERE lifecycle_state IN ({active_placeholders}) "
        "AND case_id NOT IN ("
        "SELECT case_id FROM case_dispatches WHERE regression = 1 AND status IN ('queued', 'running')"
        ")",
        tuple(sorted(ACTIVE_STATES)),
    ).fetchone()[0]
    active_regression = conn.execute(
        "SELECT COUNT(*) FROM case_dispatches WHERE regression = 1 AND status IN ('queued', 'running')"
    ).fetchone()[0]
    ordinary_slots = max(0, ordinary_limit - active_ordinary)
    regression_slots = max(0, reserved_regression - active_regression)

    ordinary_undispatched = """
        NOT EXISTS (
            SELECT 1 FROM case_dispatches d
            WHERE d.case_id = cases.case_id
              AND d.stage = 'implementation'
              AND d.status IN ('queued', 'running', 'done')
        )
    """
    regression_undispatched = """
        NOT EXISTS (
            SELECT 1 FROM case_dispatches d
            WHERE d.case_id = cases.case_id
              AND d.stage = 'implementation'
              AND d.regression = 1
              AND d.status IN ('queued', 'running')
        )
    """
    regression_rows = conn.execute(
        f"SELECT * FROM cases WHERE github_state = 'open' AND lifecycle_state = 'regressed' "
        f"AND policy_valid = 1 AND {regression_undispatched}",
    ).fetchall()
    ordinary_rows = conn.execute(
        f"SELECT * FROM cases WHERE github_state = 'open' AND lifecycle_state = 'ready' "
        f"AND policy_valid = 1 AND accepted_intent_digest IS NOT NULL AND {ordinary_undispatched}",
    ).fetchall()
    regression_rows = sorted(
        regression_rows,
        key=lambda row: (_priority(row["labels_json"]), row["first_seen_at"], row["issue_number"]),
    )[:regression_slots]
    ordinary_rows = sorted(
        ordinary_rows,
        key=lambda row: (_priority(row["labels_json"]), row["first_seen_at"], row["issue_number"]),
    )[:ordinary_slots]
    return [
        *(_spec(conn, row, regression=True) for row in regression_rows),
        *(_spec(conn, row, regression=False) for row in ordinary_rows),
    ]


def record_dispatch(conn: sqlite3.Connection, spec: DispatchSpec, *, task_id: str) -> None:
    """Record the externally-created task exactly once."""
    _initialize(conn)
    row = conn.execute("SELECT last_seen_at FROM cases WHERE case_id = ?", (spec.case_id,)).fetchone()
    if row is None:
        raise ValueError(f"unknown Case: {spec.case_id}")
    conn.execute(
        """
        INSERT OR IGNORE INTO case_dispatches
            (case_id, stage, generation_id, task_id, status, regression, created_at)
        VALUES (?, ?, ?, ?, 'queued', ?, ?)
        """,
        (
            spec.case_id,
            spec.stage,
            spec.generation_id,
            task_id,
            1 if spec.regression else 0,
            int(row["last_seen_at"]),
        ),
    )
    conn.execute(
        "UPDATE cases SET lifecycle_state = 'implementing' WHERE case_id = ?",
        (spec.case_id,),
    )
    conn.commit()
