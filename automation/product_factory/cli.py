"""Product Factory reconciliation CLI.

The v1 command is intentionally observe-only: it persists the GitHub mirror and
prints proposed actions, but cannot mutate GitHub or dispatch workers.
"""

from __future__ import annotations

import argparse
import json
import sqlite3
import time
from pathlib import Path
from typing import Any

from .github import fetch_issues
from .projection import build_model
from .reconciler import initialize, reconcile_issue
from .topology import cron_updates, load_topology


PACKAGE_ROOT = Path(__file__).resolve().parent
DEFAULT_POLICY = PACKAGE_ROOT / "policy.v1.json"
DEFAULT_DB = Path.home() / ".hermes" / "state" / "portal-product-factory.db"
DEFAULT_MERGE_QUEUE = Path.home() / ".hermes" / "state" / "portal-merge-queue.json"
DEFAULT_RATCHET_STATE = Path.home() / ".hermes" / "state" / "portal-quality-ratchet.json"


def _load_optional_json(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    value = _load_json(path)
    if not isinstance(value, dict):
        raise RuntimeError(f"expected JSON object in {path}")
    return value


def _load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"cannot load JSON from {path}: {exc}") from exc


def reconcile_command(args: argparse.Namespace) -> dict[str, Any]:
    policy = _load_json(args.policy)
    stage = policy.get("rollout_stage")
    authorities = policy.get("authorities", {})
    if stage not in {"observe", "plan", "produce"}:
        raise RuntimeError("v1 reconciler supports observe, plan, and bounded produce stages")
    if stage == "observe" and any(authorities.values()):
        raise RuntimeError("observe policy must grant no mutation or dispatch authorities")
    if stage == "plan" and (
        not authorities.get("mutate_github")
        or authorities.get("dispatch_agents")
        or authorities.get("merge_pull_requests")
        or authorities.get("close_issues")
    ):
        raise RuntimeError("plan policy may grant GitHub labeling authority only")
    if stage == "produce" and (
        not authorities.get("mutate_github")
        or not authorities.get("dispatch_agents")
        or authorities.get("merge_pull_requests")
        or authorities.get("close_issues")
    ):
        raise RuntimeError("produce policy grants bounded dispatch, not merge or close authority")

    if args.input_json:
        raw = _load_json(args.input_json)
        issues = raw if isinstance(raw, list) else [raw]
    else:
        issues = fetch_issues(args.repo or policy["repository"])

    args.db.parent.mkdir(parents=True, exist_ok=True)
    proposed: list[dict[str, Any]] = []
    changed = 0
    with sqlite3.connect(args.db) as conn:
        conn.row_factory = sqlite3.Row
        initialize(conn)
        observed_at = int(time.time())
        for issue in issues:
            outcome = reconcile_issue(conn, issue, observed_at=observed_at)
            changed += int(outcome.changed)
            proposed.extend(
                {"case_id": outcome.case_id, **action}
                for action in outcome.proposed_actions
            )

    return {
        "rollout_stage": stage,
        "mirrored": len(issues),
        "changed": changed,
        "proposed_actions": len(proposed),
        "applied_actions": 0,
        "actions": proposed,
    }


def project_command(args: argparse.Namespace) -> dict[str, Any]:
    if not args.db.exists():
        raise RuntimeError(f"Case ledger does not exist: {args.db}")
    merge_queue = _load_optional_json(args.merge_queue)
    ratchet_state = _load_optional_json(args.ratchet_state)
    with sqlite3.connect(args.db) as conn:
        conn.row_factory = sqlite3.Row
        initialize(conn)
        return build_model(
            conn,
            merge_queue=merge_queue,
            ratchet_state=ratchet_state,
        )


def topology_command(args: argparse.Namespace) -> dict[str, Any]:
    """Emit the versioned topology and supported cron.update payloads."""
    del args
    topology = load_topology()
    return {
        "version": topology["version"],
        "cron_updates": cron_updates(topology),
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Portal Product Factory control plane")
    subparsers = parser.add_subparsers(dest="command", required=True)
    reconcile = subparsers.add_parser("reconcile", help="mirror GitHub Issues into the Case ledger")
    reconcile.add_argument("--repo")
    reconcile.add_argument("--input-json", type=Path)
    reconcile.add_argument("--db", type=Path, default=DEFAULT_DB)
    reconcile.add_argument("--policy", type=Path, default=DEFAULT_POLICY)
    reconcile.set_defaults(handler=reconcile_command)
    project = subparsers.add_parser("project", help="emit the shared two-board Portal software-factories model")
    project.add_argument("--db", type=Path, default=DEFAULT_DB)
    project.add_argument("--merge-queue", type=Path, default=DEFAULT_MERGE_QUEUE)
    project.add_argument("--ratchet-state", type=Path, default=DEFAULT_RATCHET_STATE)
    project.set_defaults(handler=project_command)
    topology = subparsers.add_parser(
        "topology",
        help="emit canonical cron.update payloads without applying them",
    )
    topology.set_defaults(handler=topology_command)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        result = args.handler(args)
    except Exception as exc:
        parser.exit(1, f"product-factory: {exc}\n")
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
