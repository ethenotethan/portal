from __future__ import annotations

import sqlite3
import unittest

from automation.product_factory import reconciler


READY_LABELS = [
    "factory:product",
    "factory:ready",
    "state:ready",
    "priority:P1",
    "validation:interactive",
    "risk:bounded",
]


def issue(*, body: str = "Fix it", labels: list[str] | None = None, updated_at: str = "2026-09-21T10:00:00Z") -> dict:
    return {
        "repo": "ethenotethan/portal",
        "number": 260,
        "node_id": "I_260",
        "title": "Toolbar toggle",
        "body": body,
        "author": "ethenotethan",
        "labels": labels if labels is not None else list(READY_LABELS),
        "state": "open",
        "url": "https://github.com/ethenotethan/portal/issues/260",
        "updated_at": updated_at,
        "parent_issue": None,
    }


class ProductFactoryReconcilerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.conn = sqlite3.connect(":memory:")
        self.conn.row_factory = sqlite3.Row
        reconciler.initialize(self.conn)

    def tearDown(self) -> None:
        self.conn.close()

    def test_mirrors_ready_issue_idempotently_and_binds_accepted_intent(self) -> None:
        first = reconciler.reconcile_issue(self.conn, issue(), observed_at=100)
        second = reconciler.reconcile_issue(self.conn, issue(), observed_at=101)

        rows = self.conn.execute("SELECT * FROM cases").fetchall()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["lifecycle_state"], "ready")
        self.assertIsNotNone(rows[0]["accepted_intent_digest"])
        self.assertEqual(first.case_id, second.case_id)
        self.assertTrue(first.changed)
        self.assertFalse(second.changed)

    def test_material_edit_after_ready_invalidates_digest_and_returns_to_triage(self) -> None:
        reconciler.reconcile_issue(self.conn, issue(), observed_at=100)

        outcome = reconciler.reconcile_issue(
            self.conn,
            issue(body="Fix it and redesign the toolbar", updated_at="2026-09-21T11:00:00Z"),
            observed_at=200,
        )

        row = self.conn.execute("SELECT * FROM cases WHERE issue_number = 260").fetchone()
        self.assertEqual(row["lifecycle_state"], "triage")
        self.assertEqual(row["intent_changed"], 1)
        self.assertIsNone(row["accepted_intent_digest"])
        self.assertIn("restore_labels", [action["type"] for action in outcome.proposed_actions])

    def test_material_edit_requires_explicit_reapproval_before_ready_can_rebind(self) -> None:
        reconciler.reconcile_issue(self.conn, issue(), observed_at=100)
        reconciler.reconcile_issue(
            self.conn,
            issue(body="Changed contract", updated_at="2026-09-21T11:00:00Z"),
            observed_at=200,
        )

        outcome = reconciler.reconcile_issue(
            self.conn,
            issue(body="Changed contract", updated_at="2026-09-21T12:00:00Z"),
            observed_at=300,
        )

        row = self.conn.execute("SELECT * FROM cases WHERE issue_number = 260").fetchone()
        self.assertEqual(row["lifecycle_state"], "triage")
        self.assertEqual(row["intent_changed"], 1)
        self.assertIsNone(row["accepted_intent_digest"])
        self.assertNotIn("dispatch", [action["type"] for action in outcome.proposed_actions])

    def test_material_edit_cannot_bypass_invalidation_by_removing_ready_label(self) -> None:
        reconciler.reconcile_issue(self.conn, issue(), observed_at=100)
        labels = [label for label in READY_LABELS if label != "factory:ready"]

        outcome = reconciler.reconcile_issue(
            self.conn,
            issue(body="Changed contract", labels=labels, updated_at="2026-09-21T11:00:00Z"),
            observed_at=200,
        )

        row = self.conn.execute("SELECT * FROM cases WHERE issue_number = 260").fetchone()
        self.assertEqual(row["lifecycle_state"], "triage")
        self.assertEqual(row["intent_changed"], 1)
        self.assertIsNone(row["accepted_intent_digest"])
        self.assertNotIn("dispatch", [action["type"] for action in outcome.proposed_actions])

    def test_older_snapshot_cannot_overwrite_newer_state(self) -> None:
        reconciler.reconcile_issue(self.conn, issue(body="Initial", updated_at="2026-09-21T12:00:00Z"), observed_at=100)
        reconciler.reconcile_issue(self.conn, issue(body="Newest", updated_at="2026-09-21T13:00:00Z"), observed_at=200)

        outcome = reconciler.reconcile_issue(
            self.conn,
            issue(body="Stale", updated_at="2026-09-21T11:00:00Z"),
            observed_at=300,
        )

        row = self.conn.execute("SELECT * FROM cases WHERE issue_number = 260").fetchone()
        self.assertEqual(row["body"], "Newest")
        self.assertEqual(row["github_updated_at"], "2026-09-21T13:00:00Z")
        self.assertFalse(outcome.changed)

    def test_non_control_label_does_not_change_accepted_intent(self) -> None:
        reconciler.reconcile_issue(self.conn, issue(), observed_at=100)
        before = self.conn.execute(
            "SELECT accepted_intent_digest FROM cases WHERE issue_number = 260"
        ).fetchone()[0]

        outcome = reconciler.reconcile_issue(
            self.conn,
            issue(labels=READY_LABELS + ["bug"], updated_at="2026-09-21T11:00:00Z"),
            observed_at=200,
        )
        after = self.conn.execute(
            "SELECT accepted_intent_digest FROM cases WHERE issue_number = 260"
        ).fetchone()[0]

        self.assertEqual(before, after)
        self.assertFalse(outcome.intent_changed)

    def test_invalid_label_request_fails_closed_with_explanation(self) -> None:
        bad = issue(labels=READY_LABELS + ["state:review"])

        outcome = reconciler.reconcile_issue(self.conn, bad, observed_at=100)

        row = self.conn.execute("SELECT * FROM cases WHERE issue_number = 260").fetchone()
        self.assertEqual(row["lifecycle_state"], "intake")
        self.assertEqual(row["policy_valid"], 0)
        self.assertEqual(
            [action["type"] for action in outcome.proposed_actions],
            ["comment", "restore_labels"],
        )

    def test_invalid_labels_on_existing_case_preserve_last_safe_state(self) -> None:
        reconciler.reconcile_issue(self.conn, issue(), observed_at=100)
        bad = issue(
            labels=READY_LABELS + ["state:review"],
            updated_at="2026-09-21T11:00:00Z",
        )

        outcome = reconciler.reconcile_issue(self.conn, bad, observed_at=200)

        row = self.conn.execute("SELECT * FROM cases WHERE issue_number = 260").fetchone()
        self.assertEqual(row["lifecycle_state"], "ready")
        self.assertEqual(row["policy_valid"], 0)
        restore = next(action for action in outcome.proposed_actions if action["type"] == "restore_labels")
        self.assertIn("state:ready", restore["labels"])

    def test_invalid_lifecycle_jump_restores_last_valid_state(self) -> None:
        reconciler.reconcile_issue(self.conn, issue(), observed_at=100)
        jumped = [label for label in READY_LABELS if label != "state:ready"] + ["state:merge-ready"]

        outcome = reconciler.reconcile_issue(
            self.conn,
            issue(labels=jumped, updated_at="2026-09-21T11:00:00Z"),
            observed_at=200,
        )

        row = self.conn.execute("SELECT * FROM cases WHERE issue_number = 260").fetchone()
        self.assertEqual(row["lifecycle_state"], "ready")
        self.assertEqual(row["policy_valid"], 0)
        restore = next(action for action in outcome.proposed_actions if action["type"] == "restore_labels")
        self.assertIn("state:ready", restore["labels"])
        self.assertNotIn("state:merge-ready", restore["labels"])


if __name__ == "__main__":
    unittest.main()
