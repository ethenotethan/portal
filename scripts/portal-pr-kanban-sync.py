#!/usr/bin/env python3
"""Synchronize Portal automation into a persistent agentic control center."""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

HERMES_HOME = Path(os.environ.get("HERMES_HOME", Path.home() / ".hermes")).expanduser()
HERMES_AGENT = HERMES_HOME / "hermes-agent"
if str(HERMES_AGENT) not in sys.path:
    sys.path.insert(0, str(HERMES_AGENT))
PORTAL_ROOT = Path(__file__).resolve().parents[1]
if str(PORTAL_ROOT) not in sys.path:
    sys.path.insert(0, str(PORTAL_ROOT))

from automation.product_factory.topology import model_projection  # noqa: E402


def _artifact_store() -> Any:
    """Load the Hermes store only for commands that read or write artifacts."""
    from tui_gateway import artifact_store

    return artifact_store

ARTIFACT_ID = "portal-pr-automation"
TITLE = "Portal Software Factories Control Center"
REPO = "ethenotethan/portal"
COLUMNS = ["Inbox", "Working", "CI / Review", "Ready to Merge", "Blocked", "Merged", "Human Hold"]
PRODUCT_DB = HERMES_HOME / "state" / "portal-product-factory.db"
PRODUCT_COLUMNS = [
    "intake", "triage", "design", "ready", "implementing", "review",
    "validation", "merge-ready", "post-merge-validation", "blocked",
    "regressed", "closed",
]
ENGINEERING_GOAL = (
    "Advance Portal toward a production-grade daily driver for supervising autonomous AI agents "
    "on macOS and iOS: reliable, legible, fast, and safe; source-backed across Hermes and Centaur; "
    "strict-concurrency-correct; and explicit about user authority, security boundaries, and failures. "
    "Make metric-ratchet progress the default engineering priority: continuously pay down accepted "
    "lint debt and source-proven dead code in the smallest independently shippable slices, with no "
    "metric-category regressions or weakened gates."
)
DEFAULT_HANDOFF_PROMPT = (
    "Read the shared Portal PR Automation board plus live GitHub, repository, lint-baseline, dead-code, "
    "and ratchet state. Continue the highest-leverage unfinished metric-ratchet slice that advances the "
    "engineering goal. Prefer one bounded lint rule/file cluster or one source-backed dead-code removal. "
    "Preserve prior evidence, user-moved cards, tombstones, and authority boundaries; do not duplicate "
    "landed or active work. Before changing code, identify the current metric, exact baseline, goal "
    "linkage, inherited evidence, and next smallest shippable reduction. Verify focused behavior, both "
    "platform builds when affected, baseline no-growth across every category, and the tightened ratchet "
    "without weakening tests, scanners, or policy. Before finishing, write a concise handoff containing "
    "before/after metrics, changed paths, commit/PR, real verification, remaining blocker, and the next "
    "recommended reduction."
)
WHY_WORK_ITEMS = (
    "Cards, issues, and pull requests are durable coordination contracts between independent agent "
    "runs—not a proxy for activity. Each one names one bounded, independently shippable change; carries "
    "its evidence and current gate; prevents duplicate work; and gives the human and deterministic merge "
    "policy a stable object to accept, block, repair, or supersede."
)
SHARED_STATE_SUMMARY = (
    "There is no hidden shared agent memory. Accepted product state lives in origin/main; candidate state "
    "lives in GitHub PRs and isolated worktrees; quality policy lives in committed metric baselines; queue "
    "and cooldown coordination live in bounded ~/.hermes/state JSON; handoffs and generation history live "
    "in cron outputs; and this artifact is the human-facing projection that also preserves manual card moves."
)

BRANCH_LANES = (
    ("cron/quality-escalation-", "quality-escalation"),
    ("cron/architecture-docs-", "architecture-docs"),
    ("fix/ci-pocket-", "ci-recovery"),
    ("cron/quality-ratchet-", "quality-ratchet"),
    ("cron/metric-ratchet-", "quality-ratchet"),
)
GENERATION_JOBS = {
    "quality-escalation": "6bfcef8dfe35",
    "architecture-docs": "583169d041fb",
    "ci-recovery": "cf0906b442ac",
}


def _gh_json(*args: str) -> list[dict[str, Any]]:
    env = os.environ.copy()
    # Cron/tool environments can inject stale variables that outrank the
    # verified gh keyring login. Remove both names without exposing either.
    env.pop("GITHUB_TOKEN", None)
    env.pop("GH_TOKEN", None)
    proc = subprocess.run(
        ["gh", *args], env=env, text=True, capture_output=True, timeout=90, check=False
    )
    if proc.returncode != 0:
        raise RuntimeError((proc.stderr or proc.stdout or "gh failed").strip())
    value = json.loads(proc.stdout or "[]")
    if not isinstance(value, list):
        raise RuntimeError("gh returned a non-list payload")
    return value


def _lane(branch: str) -> str | None:
    for prefix, lane in BRANCH_LANES:
        if branch.startswith(prefix):
            return lane
    return None


def _check_state(checks: list[dict[str, Any]]) -> tuple[str, str]:
    if not checks:
        return "PR Open", "checks not reported"
    pending = 0
    failed: list[str] = []
    passed = 0
    for check in checks:
        status = str(check.get("status") or "").upper()
        conclusion = str(check.get("conclusion") or "").upper()
        name = str(check.get("name") or "unnamed")
        if status not in {"COMPLETED", ""}:
            pending += 1
        elif conclusion not in {"SUCCESS", "NEUTRAL", "SKIPPED", ""}:
            failed.append(name)
        else:
            passed += 1
    if failed:
        return "Blocked", f"failed: {', '.join(failed[:3])}"
    if pending:
        return "CI / Review", f"{pending} pending; {passed} passed"
    return "Ready to Merge", f"{passed} checks passed"


def _load() -> tuple[dict[str, Any] | None, dict[str, Any]]:
    artifact = _artifact_store().get_artifact(ARTIFACT_ID)
    if not artifact:
        return None, {"id": ARTIFACT_ID, "title": TITLE, "columns": COLUMNS, "cards": []}
    try:
        stored = json.loads(artifact.get("content") or "{}")
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"existing artifact is invalid JSON: {exc}") from exc
    if not isinstance(stored, dict):
        raise RuntimeError("existing artifact content is not an object")

    # The synchronizer keeps a compact board-shaped working representation so
    # the existing reconciliation logic stays simple. Model artifacts are
    # losslessly projected back into that shape on every run.
    if isinstance(stored.get("entities"), dict):
        work = stored.get("entities", {}).get("work", {})
        cards = work.get("items", []) if isinstance(work, dict) else []
        spec = {
            key: value
            for key, value in stored.items()
            if key not in {"entities", "relations", "views", "actions"}
        }
        spec["cards"] = cards if isinstance(cards, list) else []
    else:
        spec = stored

    spec.setdefault("id", ARTIFACT_ID)
    spec.setdefault("title", TITLE)
    spec["columns"] = COLUMNS
    spec.setdefault("cards", [])
    return artifact, spec


def _product_cases() -> list[dict[str, Any]]:
    """Read the issue-driven factory ledger without taking execution authority."""
    if not PRODUCT_DB.exists():
        return []
    try:
        with sqlite3.connect(f"file:{PRODUCT_DB}?mode=ro", uri=True) as conn:
            conn.row_factory = sqlite3.Row
            rows = conn.execute(
                "SELECT case_id, issue_number, title, github_url, github_state, "
                "lifecycle_state, policy_valid, policy_reason, intent_changed, labels_json "
                "FROM cases ORDER BY issue_number"
            ).fetchall()
    except (OSError, sqlite3.Error):
        return []
    items: list[dict[str, Any]] = []
    for row in rows:
        try:
            labels = json.loads(row["labels_json"] or "[]")
        except json.JSONDecodeError:
            labels = []
        items.append({
            "case_id": row["case_id"],
            "issue_number": row["issue_number"],
            "title": row["title"],
            "issue_url": row["github_url"],
            "github_state": row["github_state"],
            "status": "closed" if row["github_state"] == "closed" else row["lifecycle_state"],
            "priority": next((label.removeprefix("priority:") for label in labels if label.startswith("priority:")), None),
            "validation": next((label.removeprefix("validation:") for label in labels if label.startswith("validation:")), None),
            "policy_valid": bool(row["policy_valid"]),
            "policy_reason": row["policy_reason"],
            "intent_changed": bool(row["intent_changed"]),
        })
    return items


def _model_document(spec: dict[str, Any]) -> dict[str, Any]:
    """Project the operational board into one explanatory model surface."""
    counts = spec.get("generation_runs") if isinstance(spec.get("generation_runs"), dict) else {}
    telemetry = {
        "id": "fleet",
        "completed_generations": int(counts.get("completed_generations") or 0),
        "run_attempts": int(counts.get("run_attempts") or 0),
        "active_code_lanes": len(counts.get("lanes") or {}),
    }
    product_cases = _product_cases()
    product_counts: dict[str, int] = {}
    for item in product_cases:
        status = str(item["status"])
        product_counts[status] = product_counts.get(status, 0) + 1
    product_summary = ", ".join(
        f"{count} {status}" for status, count in sorted(product_counts.items())
    ) or "No mirrored issues yet"
    architecture = model_projection()
    return {
        "id": ARTIFACT_ID,
        "title": TITLE,
        "engineering_goal": spec.get("engineering_goal", ENGINEERING_GOAL),
        "default_handoff_prompt": spec.get("default_handoff_prompt", DEFAULT_HANDOFF_PROMPT),
        "generation_runs": counts,
        "last_sync_at": spec.get("last_sync_at"),
        "last_sync_actor": spec.get("last_sync_actor"),
        "events": spec.get("events", []),
        "entities": {
            "work": {"key": "id", "items": spec.get("cards", [])},
            "product_cases": {"key": "case_id", "items": product_cases},
            "telemetry": {"key": "id", "items": [telemetry]},
            **architecture["entities"],
        },
        "relations": architecture["relations"],
        "views": [
            {"type": "markdown", "text": spec.get("overview", "")},
            {
                "type": "stats",
                "entities": ["telemetry"],
                "fields": ["completed_generations", "run_attempts", "active_code_lanes"],
            },
            {"type": "markdown", "text": "## Live Ratchet Improvement Factory\n\nMove cards to express human intent. Automation records its own computed lane separately as `automation_column`, so a manual move survives later syncs."},
            {"type": "kanban", "entities": ["work"], "column": "column", "columns": COLUMNS},
            {"type": "markdown", "text": f"## Product Factory\n\n{product_summary}. GitHub owns intent; the Case ledger owns execution state and evidence. Observe mode cannot dispatch or mutate GitHub."},
            {"type": "kanban", "entities": ["product_cases"], "column": "status", "columns": PRODUCT_COLUMNS},
            {"type": "table", "entities": ["product_cases"], "columns": ["issue_number", "title", "priority", "status", "validation", "policy_valid", "github_state"]},
            {"type": "markdown", "text": "## Multi-agent architecture\n\nThis graph is generated from the same cron declarations deployed to Hermes. Dataflow edge types match `cron.graph`; governance and scheduler boundaries remain explicit relationships."},
            {"type": "graph", "entities": ["factory_jobs", "factory_resources", "factory_authorities"]},
            {"type": "markdown", "text": "## Agent responsibilities"},
            {"type": "table", "entities": ["factory_jobs"], "columns": ["id", "name", "role"]},
            {"type": "markdown", "text": "## Shared resources"},
            {"type": "table", "entities": ["factory_resources"], "columns": ["id", "title", "scheme"]},
            {"type": "markdown", "text": "## Governance and scheduler authority"},
            {"type": "table", "entities": ["factory_authorities"], "columns": ["id", "title", "role"]},
        ],
        "actions": {
            "work": [{"field": "column", "type": "choice", "options": COLUMNS}],
        },
    }


def _preserved_column(existing: dict[str, Any] | None, automatic: str) -> str:
    if not existing:
        return automatic
    current = str(existing.get("column") or "")
    previous_automatic = str(existing.get("automation_column") or current)
    if current in COLUMNS and current != previous_automatic:
        return current
    return automatic


def _generation_counts(prior: dict[str, Any] | None = None) -> dict[str, Any]:
    """Advance monotonic counters from the retained cron-run window."""
    prior = prior if isinstance(prior, dict) else {}
    prior_lanes = prior.get("lanes") if isinstance(prior.get("lanes"), dict) else {}
    lanes: dict[str, dict[str, Any]] = {}
    for lane, job_id in GENERATION_JOBS.items():
        output_dir = HERMES_HOME / "cron" / "output" / job_id
        files = sorted(output_dir.glob("*.md")) if output_dir.exists() else []
        current_attempts = {path.name for path in files}
        current_completed: set[str] = set()
        last_completed_at = None
        for path in files:
            try:
                text = path.read_text(errors="replace")
            except OSError:
                continue
            if "## Response" in text:
                current_completed.add(path.name)
                last_completed_at = datetime.fromtimestamp(
                    path.stat().st_mtime, tz=timezone.utc
                ).isoformat()

        previous = prior_lanes.get(lane) if isinstance(prior_lanes.get(lane), dict) else {}
        previous_attempts = set(previous.get("seen_attempts") or [])
        previous_completed = set(previous.get("seen_completed") or [])
        prior_attempt_count = int(previous.get("run_attempts") or 0)
        prior_completed_count = int(previous.get("completed_generations") or 0)

        # Migration from the original snapshot counter: its totals already
        # include the whole retained window, so seed identities without adding.
        migrating = bool(previous) and "seen_attempts" not in previous
        if migrating:
            attempt_count = prior_attempt_count
            completed_count = prior_completed_count
        else:
            attempt_count = prior_attempt_count + len(current_attempts - previous_attempts)
            completed_count = prior_completed_count + len(current_completed - previous_completed)

        lanes[lane] = {
            "job_id": job_id,
            "run_attempts": attempt_count,
            "completed_generations": completed_count,
            "last_completed_at": last_completed_at or previous.get("last_completed_at"),
            # Output retention is bounded, so retaining only the current window
            # is sufficient to recognize the next unique run without unbounded
            # artifact growth.
            "seen_attempts": sorted(current_attempts),
            "seen_completed": sorted(current_completed),
        }
    return {
        "completed_generations": sum(item["completed_generations"] for item in lanes.values()),
        "run_attempts": sum(item["run_attempts"] for item in lanes.values()),
        "lanes": lanes,
    }


def _ensure_charter(spec: dict[str, Any]) -> None:
    """Install board-level context and generation telemetry, preserving work cards."""
    spec.setdefault("engineering_goal", ENGINEERING_GOAL)
    spec.setdefault("default_handoff_prompt", DEFAULT_HANDOFF_PROMPT)
    spec["overview"] = (
        "## North star\n\n"
        + str(spec["engineering_goal"])
        + "\n\n## Why cards, issues, and PRs exist\n\n"
        + WHY_WORK_ITEMS
        + "\n\n## How generations hand work forward\n\n"
        + str(spec["default_handoff_prompt"])
        + "\n\n## Where shared state lives\n\n"
        + SHARED_STATE_SUMMARY
        + "\n\n> **Authority boundary:** workers produce candidates; CI and deterministic policy qualify them; the merge queue accepts only green mergeable work; Ethen retains final authority."
    )
    counts = _generation_counts(spec.get("generation_runs"))
    spec["generation_runs"] = counts
    cards = [
        card for card in spec.get("cards", [])
        if isinstance(card, dict) and card.get("id") != "protocol-engineering-charter"
    ]
    by_id = {str(card.get("id")): card for card in cards if card.get("id")}
    managed: list[dict[str, Any]] = []

    counter_id = "metric-generation-runs"
    existing_counter = by_id.get(counter_id)
    if not (existing_counter and existing_counter.get("_deleted") is True):
        automatic = "Inbox"
        lane_lines = [
            f"{lane}: {item['completed_generations']} completed / {item['run_attempts']} attempts"
            for lane, item in counts["lanes"].items()
        ]
        managed.append({
            "id": counter_id,
            "title": f"Generational Runs: {counts['completed_generations']}",
            "column": _preserved_column(existing_counter, automatic),
            "automation_column": automatic,
            "tag": "telemetry",
            "note": (
                f"{counts['completed_generations']} completed generations across "
                f"{len(counts['lanes'])} code-producing lanes; {counts['run_attempts']} total attempts."
            ),
            "detail": "GENERATION COUNTS\n" + "\n".join(lane_lines),
            "completed_generations": counts["completed_generations"],
            "run_attempts": counts["run_attempts"],
            "managed_by": "portal-pr-kanban-sync",
        })

    managed_ids = {card["id"] for card in managed}
    spec["cards"] = managed + [card for card in cards if card.get("id") not in managed_ids]


def _pr_card(pr: dict[str, Any], existing: dict[str, Any] | None, merged: bool) -> dict[str, Any]:
    number = int(pr["number"])
    branch = str(pr.get("headRefName") or "")
    lane = _lane(branch) or "portal-automation"
    if merged:
        automatic, check_note = "Merged", "merged into main"
    else:
        automatic, check_note = _check_state(pr.get("statusCheckRollup") or [])
        if str(pr.get("mergeStateStatus") or "").upper() in {"DIRTY", "BEHIND"}:
            automatic = "Blocked"
            check_note = f"merge state: {pr.get('mergeStateStatus')}"
    column = _preserved_column(existing, automatic)
    updated = str(pr.get("updatedAt") or pr.get("mergedAt") or "")
    return {
        "id": f"pr-{number}",
        "title": f"#{number} {pr.get('title') or 'Untitled PR'}",
        "column": column,
        "automation_column": automatic,
        "tag": lane,
        "note": check_note,
        "detail": f"Branch: {branch}\nState: {pr.get('mergeStateStatus') or pr.get('state') or 'unknown'}\nUpdated: {updated}\n{pr.get('url') or ''}",
        "url": str(pr.get("url") or ""),
        "pr": number,
        "lane": lane,
        "updated_at": updated,
        "managed_by": "portal-pr-kanban-sync",
    }


def sync(actor: str) -> dict[str, Any]:
    fields = "number,title,headRefName,mergeStateStatus,statusCheckRollup,url,updatedAt,mergedAt,state"
    open_prs = _gh_json("pr", "list", "--repo", REPO, "--state", "open", "--limit", "100", "--json", fields)
    merged_prs = _gh_json(
        "pr", "list", "--repo", REPO, "--state", "merged", "--limit", "40", "--search", "merged:>=2026-08-22", "--json", fields
    )
    _, spec = _load()
    _ensure_charter(spec)
    existing_cards = {
        str(card.get("id")): card
        for card in spec.get("cards", [])
        if isinstance(card, dict) and card.get("id")
    }
    fresh: dict[str, dict[str, Any]] = {}
    for pr, merged in [(pr, False) for pr in open_prs] + [(pr, True) for pr in merged_prs]:
        branch = str(pr.get("headRefName") or "")
        if _lane(branch) is None:
            continue
        card_id = f"pr-{int(pr['number'])}"
        existing = existing_cards.get(card_id)
        if existing and existing.get("_deleted") is True:
            continue
        fresh[card_id] = _pr_card(pr, existing, merged)

    retained = []
    for card_id, card in existing_cards.items():
        if card_id == "protocol-engineering-charter":
            continue
        if card.get("_deleted") is True:
            retained.append(card)
        elif card_id.startswith("lane-") or card_id == "metric-generation-runs":
            retained.append(card)
        elif card.get("managed_by") != "portal-pr-kanban-sync":
            retained.append(card)
    spec["cards"] = retained + sorted(
        fresh.values(), key=lambda c: (COLUMNS.index(c["column"]), -int(c["pr"]))
    )
    spec["last_sync_at"] = datetime.now(timezone.utc).isoformat()
    spec["last_sync_actor"] = actor
    content = json.dumps(_model_document(spec), ensure_ascii=False, separators=(",", ":"))
    stored = _artifact_store().set_artifact(
        artifact_id=ARTIFACT_ID,
        kind="model",
        content=content,
        title=TITLE,
        updated_by=f"cron:{actor}",
        replace=True,
    )
    return {
        "id": ARTIFACT_ID,
        "rev": stored["rev"],
        "cards": len(spec["cards"]),
        "prs": len(fresh),
        "completed_generations": spec["generation_runs"]["completed_generations"],
        "run_attempts": spec["generation_runs"]["run_attempts"],
    }


def event(job: str, outcome: str, summary: str) -> dict[str, Any]:
    _, spec = _load()
    _ensure_charter(spec)
    cards = [card for card in spec.get("cards", []) if isinstance(card, dict)]
    card_id = f"lane-{job}"
    existing = next((card for card in cards if card.get("id") == card_id), None)
    automatic = {
        "PR_OPENED": "CI / Review",
        "REPAIRED": "CI / Review",
        "BLOCKED": "Blocked",
        "HUMAN_DECISION": "Human Hold",
        "ABORTED": "Blocked",
        "STALE": "Blocked",
        "WAITING": "Working",
        "RECONCILED": "Working",
        "NO_CHANGE": "Inbox",
        "NO ACTION": "Inbox",
        "SUPERSEDED": "Merged",
    }.get(outcome.upper(), "Inbox")
    column = _preserved_column(existing, automatic)
    card = {
        "id": card_id,
        "title": job.replace("-", " ").title(),
        "column": column,
        "automation_column": automatic,
        "tag": "worker",
        "note": summary[:240],
        "detail": f"Latest outcome: {outcome}\n{summary[:1000]}",
        "updated_at": datetime.now(timezone.utc).isoformat(),
        "managed_by": "portal-pr-kanban-sync",
    }
    if existing and existing.get("_deleted") is True:
        return {"id": ARTIFACT_ID, "skipped": "lane card deleted by user"}
    cards = [c for c in cards if c.get("id") != card_id]
    spec["cards"] = [card] + cards
    spec["columns"] = COLUMNS
    stored = _artifact_store().set_artifact(
        artifact_id=ARTIFACT_ID,
        kind="model",
        content=json.dumps(_model_document(spec), ensure_ascii=False, separators=(",", ":")),
        title=TITLE,
        updated_by=f"cron:{job}",
        replace=True,
    )
    return {"id": ARTIFACT_ID, "rev": stored["rev"], "event": outcome, "job": job}


def show() -> dict[str, Any]:
    artifact, spec = _load()
    _ensure_charter(spec)
    return {
        "id": ARTIFACT_ID,
        "rev": artifact.get("rev") if artifact else 0,
        "columns": spec.get("columns", []),
        "cards": spec.get("cards", []),
    }


def context() -> dict[str, Any]:
    artifact, spec = _load()
    _ensure_charter(spec)
    lanes = [
        {
            "id": card.get("id"),
            "column": card.get("column"),
            "note": card.get("note", ""),
        }
        for card in spec.get("cards", [])
        if isinstance(card, dict) and str(card.get("id", "")).startswith("lane-")
    ]
    return {
        "id": ARTIFACT_ID,
        "rev": artifact.get("rev") if artifact else 0,
        "engineering_goal": spec["engineering_goal"],
        "default_handoff_prompt": spec["default_handoff_prompt"],
        "generation_runs": spec["generation_runs"],
        "lane_handoffs": lanes,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    p_sync = sub.add_parser("sync")
    p_sync.add_argument("--actor", default="manual")
    p_event = sub.add_parser("event")
    p_event.add_argument("--job", required=True)
    p_event.add_argument("--outcome", required=True)
    p_event.add_argument("--summary", default="")
    sub.add_parser("show")
    sub.add_parser("context")
    args = parser.parse_args()
    try:
        if args.command == "sync":
            result = sync(args.actor)
        elif args.command == "event":
            result = event(args.job, args.outcome, args.summary)
        elif args.command == "context":
            result = context()
        else:
            result = show()
        print(json.dumps({"success": True, **result}, ensure_ascii=False))
        return 0
    except Exception as exc:  # noqa: BLE001
        print(json.dumps({"success": False, "error": str(exc)}, ensure_ascii=False))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
