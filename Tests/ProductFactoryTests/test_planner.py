from __future__ import annotations

import sqlite3
import unittest

from automation.product_factory import planner, reconciler


BASE_LABELS = [
    "factory:product",
    "factory:ready",
    "state:ready",
    "validation:interactive",
    "risk:bounded",
]


def add_case(conn: sqlite3.Connection, number: int, priority: str, *, state: str = "ready") -> None:
    labels = BASE_LABELS + [f"priority:{priority}"]
    labels = [f"state:{state}" if label == "state:ready" else label for label in labels]
    reconciler.reconcile_issue(
        conn,
        {
            "repo": "ethenotethan/portal",
            "number": number,
            "node_id": f"I_{number}",
            "title": f"Issue {number}",
            "body": "Acceptance criteria",
            "author": "ethenotethan",
            "labels": labels,
            "state": "open",
            "url": f"https://github.com/ethenotethan/portal/issues/{number}",
            "updated_at": f"2026-09-21T10:{number % 60:02d}:00Z",
            "parent_issue": None,
        },
        observed_at=number,
    )


class ProductFactoryPlannerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.conn = sqlite3.connect(":memory:")
        self.conn.row_factory = sqlite3.Row
        reconciler.initialize(self.conn)

    def tearDown(self) -> None:
        self.conn.close()

    def test_selects_two_ordinary_cases_by_priority_then_age(self) -> None:
        add_case(self.conn, 10, "P2")
        add_case(self.conn, 11, "P1")
        add_case(self.conn, 12, "P1")

        specs = planner.plan_dispatches(
            self.conn,
            ordinary_limit=2,
            reserved_regression=1,
        )

        self.assertEqual([spec.issue_number for spec in specs], [11, 12])
        self.assertTrue(all(spec.stage == "implementation" for spec in specs))
        self.assertEqual(len({spec.generation_id for spec in specs}), 2)

    def test_regression_uses_reserved_slot_without_consuming_ordinary_capacity(self) -> None:
        add_case(self.conn, 20, "P0", state="regressed")
        add_case(self.conn, 21, "P1")
        add_case(self.conn, 22, "P2")

        specs = planner.plan_dispatches(
            self.conn,
            ordinary_limit=2,
            reserved_regression=1,
        )

        self.assertEqual([spec.issue_number for spec in specs], [20, 21, 22])
        self.assertTrue(specs[0].regression)

    def test_active_regression_does_not_consume_an_ordinary_slot(self) -> None:
        add_case(self.conn, 23, "P0", state="regressed")
        regression = planner.plan_dispatches(
            self.conn,
            ordinary_limit=2,
            reserved_regression=1,
        )[0]
        planner.record_dispatch(self.conn, regression, task_id="regression-task")
        add_case(self.conn, 24, "P1")
        add_case(self.conn, 25, "P2")

        specs = planner.plan_dispatches(
            self.conn,
            ordinary_limit=2,
            reserved_regression=1,
        )

        self.assertEqual([spec.issue_number for spec in specs], [24, 25])
        self.assertTrue(all(not spec.regression for spec in specs))

    def test_regressed_case_with_completed_original_dispatch_gets_remediation(self) -> None:
        add_case(self.conn, 26, "P0")
        original = planner.plan_dispatches(self.conn, ordinary_limit=2, reserved_regression=1)[0]
        planner.record_dispatch(self.conn, original, task_id="original-task")
        self.conn.execute(
            "UPDATE case_dispatches SET status = 'done' WHERE task_id = 'original-task'"
        )
        self.conn.execute(
            "UPDATE cases SET lifecycle_state = 'regressed' WHERE issue_number = 26"
        )
        self.conn.commit()

        specs = planner.plan_dispatches(self.conn, ordinary_limit=2, reserved_regression=1)

        self.assertEqual([spec.issue_number for spec in specs], [26])
        self.assertTrue(specs[0].regression)
        self.assertNotEqual(specs[0].generation_id, original.generation_id)

    def test_closed_ready_case_is_not_dispatched(self) -> None:
        add_case(self.conn, 27, "P1")
        self.conn.execute("UPDATE cases SET github_state = 'closed' WHERE issue_number = 27")
        self.conn.commit()

        specs = planner.plan_dispatches(self.conn, ordinary_limit=2, reserved_regression=1)

        self.assertEqual(specs, [])

    def test_existing_dispatch_is_not_issued_twice(self) -> None:
        add_case(self.conn, 30, "P1")
        first = planner.plan_dispatches(self.conn, ordinary_limit=2, reserved_regression=1)
        planner.record_dispatch(self.conn, first[0], task_id="task-1")

        second = planner.plan_dispatches(self.conn, ordinary_limit=2, reserved_regression=1)

        self.assertEqual(second, [])


if __name__ == "__main__":
    unittest.main()
