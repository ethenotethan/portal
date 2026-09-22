from __future__ import annotations

import json
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class ProductFactoryCLITests(unittest.TestCase):
    def test_topology_emits_supported_cron_update_payloads(self) -> None:
        result = subprocess.run(
            [sys.executable, "-m", "automation.product_factory.cli", "topology"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=30,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        document = json.loads(result.stdout)
        self.assertEqual(document["version"], 1)
        self.assertTrue(document["cron_updates"])
        self.assertTrue(
            all(update["action"] == "update" for update in document["cron_updates"])
        )

    def test_produce_reconciliation_persists_cases_but_cli_applies_no_actions(self) -> None:
        issue = {
            "repo": "ethenotethan/portal",
            "number": 260,
            "node_id": "I_260",
            "title": "Toolbar toggle",
            "body": "Fix it",
            "author": "ethenotethan",
            "labels": [
                "factory:product",
                "factory:ready",
                "state:ready",
                "priority:P1",
                "validation:interactive",
                "risk:bounded",
            ],
            "state": "open",
            "url": "https://github.com/ethenotethan/portal/issues/260",
            "updated_at": "2026-09-21T10:00:00Z",
            "parent_issue": None,
        }
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            source = tmp_path / "event.json"
            database = tmp_path / "factory.db"
            source.write_text(json.dumps([issue]))

            result = subprocess.run(
                [
                    sys.executable,
                    "-m",
                    "automation.product_factory.cli",
                    "reconcile",
                    "--input-json",
                    str(source),
                    "--db",
                    str(database),
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
                timeout=30,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            summary = json.loads(result.stdout)
            self.assertEqual(summary["rollout_stage"], "produce")
            self.assertEqual(summary["mirrored"], 1)
            self.assertEqual(summary["proposed_actions"], 1)
            self.assertEqual(summary["applied_actions"], 0)
            with sqlite3.connect(database) as conn:
                self.assertEqual(conn.execute("SELECT COUNT(*) FROM cases").fetchone()[0], 1)


if __name__ == "__main__":
    unittest.main()
