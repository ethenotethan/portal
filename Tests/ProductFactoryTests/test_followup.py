from __future__ import annotations

import sqlite3
import unittest

from automation.product_factory import followup, planner, reconciler


class ProductFactoryFollowupTests(unittest.TestCase):
    def setUp(self) -> None:
        self.conn = sqlite3.connect(":memory:")
        self.conn.row_factory = sqlite3.Row
        reconciler.initialize(self.conn)
        reconciler.reconcile_issue(
            self.conn,
            {
                "repo": "ethenotethan/portal",
                "number": 510,
                "node_id": "I_510",
                "title": "Rendered delegate completion",
                "body": "Acceptance criteria",
                "author": "ethenotethan",
                "labels": [
                    "factory:product",
                    "factory:ready",
                    "state:ready",
                    "validation:interactive",
                    "risk:bounded",
                    "priority:P2",
                ],
                "state": "open",
                "url": "https://github.com/ethenotethan/portal/issues/510",
                "updated_at": "2026-09-21T09:00:00Z",
                "parent_issue": None,
            },
            observed_at=510,
        )
        spec = planner.plan_dispatches(self.conn, ordinary_limit=2, reserved_regression=1)[0]
        planner.record_dispatch(self.conn, spec, task_id="impl-510")

    def tearDown(self) -> None:
        self.conn.close()

    def test_done_implementation_with_pr_url_plans_validation(self) -> None:
        candidates = followup.plan_validation_dispatches(
            self.conn,
            task_states={
                "impl-510": {
                    "status": "done",
                    "result": "Implemented and opened https://github.com/ethenotethan/portal/pull/511 at abc123",
                }
            },
        )

        self.assertEqual(len(candidates), 1)
        candidate = candidates[0]
        self.assertEqual(candidate.issue_number, 510)
        self.assertEqual(candidate.pr_url, "https://github.com/ethenotethan/portal/pull/511")
        self.assertEqual(candidate.implementation_task_id, "impl-510")

    def test_record_validation_is_idempotent_and_advances_lifecycle(self) -> None:
        candidate = followup.plan_validation_dispatches(
            self.conn,
            task_states={
                "impl-510": {
                    "status": "done",
                    "result": "PR: https://github.com/ethenotethan/portal/pull/511",
                }
            },
        )[0]

        followup.record_validation_dispatch(self.conn, candidate, task_id="validate-510")
        followup.record_validation_dispatch(self.conn, candidate, task_id="validate-510")

        lifecycle = self.conn.execute(
            "SELECT lifecycle_state FROM cases WHERE issue_number = 510"
        ).fetchone()[0]
        rows = self.conn.execute(
            "SELECT stage, task_id, status FROM case_dispatches WHERE case_id = ? ORDER BY stage",
            (candidate.case_id,),
        ).fetchall()
        self.assertEqual(lifecycle, "review")
        self.assertEqual([(row["stage"], row["task_id"], row["status"]) for row in rows], [
            ("implementation", "impl-510", "done"),
            ("validation", "validate-510", "queued"),
        ])

    def test_missing_pr_url_does_not_dispatch_validation(self) -> None:
        candidates = followup.plan_validation_dispatches(
            self.conn,
            task_states={"impl-510": {"status": "done", "result": "Tests passed but no PR"}},
        )
        self.assertEqual(candidates, [])


if __name__ == "__main__":
    unittest.main()
