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

    def test_task_state_loader_falls_back_to_completed_run_summary(self) -> None:
        board = sqlite3.connect(":memory:")
        board.row_factory = sqlite3.Row
        board.executescript(
            """
            CREATE TABLE tasks (id TEXT PRIMARY KEY, status TEXT, result TEXT, body TEXT);
            CREATE TABLE task_runs (
                id INTEGER PRIMARY KEY,
                task_id TEXT,
                status TEXT,
                outcome TEXT,
                summary TEXT
            );
            INSERT INTO tasks VALUES (
                'impl-510', 'done', NULL,
                'Pull request: https://github.com/ethenotethan/portal/pull/514'
            );
            INSERT INTO task_runs VALUES (
                1, 'impl-510', 'done', 'completed',
                'Opened https://github.com/ethenotethan/portal/pull/514'
            );
            """
        )

        states = followup.load_task_states(board)

        self.assertEqual(states["impl-510"]["status"], "done")
        self.assertIn("/pull/514", states["impl-510"]["result"])
        self.assertIn("/pull/514", states["impl-510"]["body"])
        board.close()

    def test_missing_pr_url_does_not_dispatch_validation(self) -> None:
        candidates = followup.plan_validation_dispatches(
            self.conn,
            task_states={"impl-510": {"status": "done", "result": "Tests passed but no PR"}},
        )
        self.assertEqual(candidates, [])

    def test_blocked_validation_plans_remediation_on_same_pr(self) -> None:
        validation = followup.plan_validation_dispatches(
            self.conn,
            task_states={
                "impl-510": {
                    "status": "done",
                    "result": "Opened https://github.com/ethenotethan/portal/pull/511",
                }
            },
        )[0]
        followup.record_validation_dispatch(self.conn, validation, task_id="validate-510")
        self.conn.execute(
            "UPDATE cases SET lifecycle_state = 'blocked' WHERE issue_number = 510"
        )
        self.conn.commit()

        candidates = followup.plan_remediation_dispatches(
            self.conn,
            task_states={
                "validate-510": {
                    "status": "done",
                    "body": "Pull request: https://github.com/ethenotethan/portal/pull/511",
                    "result": "Validation blocked: restore generated-project hygiene.",
                }
            },
        )

        self.assertEqual(len(candidates), 1)
        candidate = candidates[0]
        self.assertEqual(candidate.pr_url, "https://github.com/ethenotethan/portal/pull/511")
        self.assertEqual(candidate.validation_task_id, "validate-510")
        self.assertIn("generated-project hygiene", candidate.blocker)

    def test_record_remediation_closes_validation_and_reopens_implementation(self) -> None:
        validation = followup.plan_validation_dispatches(
            self.conn,
            task_states={
                "impl-510": {
                    "status": "done",
                    "result": "Opened https://github.com/ethenotethan/portal/pull/511",
                }
            },
        )[0]
        followup.record_validation_dispatch(self.conn, validation, task_id="validate-510")
        self.conn.execute(
            "UPDATE cases SET lifecycle_state = 'blocked' WHERE issue_number = 510"
        )
        self.conn.commit()
        remediation = followup.plan_remediation_dispatches(
            self.conn,
            task_states={
                "validate-510": {
                    "status": "done",
                    "body": "Pull request: https://github.com/ethenotethan/portal/pull/511",
                    "result": "Validation blocked: fix PBX churn.",
                }
            },
        )[0]

        followup.record_remediation_dispatch(self.conn, remediation, task_id="remediate-510")
        followup.record_remediation_dispatch(self.conn, remediation, task_id="remediate-510")

        lifecycle = self.conn.execute(
            "SELECT lifecycle_state FROM cases WHERE issue_number = 510"
        ).fetchone()[0]
        rows = self.conn.execute(
            "SELECT stage, task_id, status FROM case_dispatches WHERE case_id = ? ORDER BY id",
            (remediation.case_id,),
        ).fetchall()
        self.assertEqual(lifecycle, "implementing")
        self.assertEqual(
            [(row["stage"], row["task_id"], row["status"]) for row in rows],
            [
                ("implementation", "impl-510", "done"),
                ("validation", "validate-510", "done"),
                ("remediation", "remediate-510", "queued"),
            ],
        )

    def test_completed_remediation_plans_new_validation_generation(self) -> None:
        first_validation = followup.plan_validation_dispatches(
            self.conn,
            task_states={
                "impl-510": {
                    "status": "done",
                    "result": "Opened https://github.com/ethenotethan/portal/pull/511",
                }
            },
        )[0]
        followup.record_validation_dispatch(self.conn, first_validation, task_id="validate-510")
        self.conn.execute(
            "UPDATE cases SET lifecycle_state = 'blocked' WHERE issue_number = 510"
        )
        self.conn.commit()
        remediation = followup.plan_remediation_dispatches(
            self.conn,
            task_states={
                "validate-510": {
                    "status": "done",
                    "body": "Pull request: https://github.com/ethenotethan/portal/pull/511",
                    "result": "Validation blocked: fix PBX churn.",
                }
            },
        )[0]
        followup.record_remediation_dispatch(self.conn, remediation, task_id="remediate-510")

        candidates = followup.plan_validation_dispatches(
            self.conn,
            task_states={
                "impl-510": {
                    "status": "done",
                    "result": "Opened https://github.com/ethenotethan/portal/pull/511",
                },
                "remediate-510": {
                    "status": "done",
                    "result": "Updated https://github.com/ethenotethan/portal/pull/511 at def456",
                },
            },
        )

        self.assertEqual(len(candidates), 1)
        candidate = candidates[0]
        self.assertEqual(candidate.implementation_task_id, "remediate-510")
        self.assertNotEqual(candidate.generation_id, first_validation.generation_id)


if __name__ == "__main__":
    unittest.main()
