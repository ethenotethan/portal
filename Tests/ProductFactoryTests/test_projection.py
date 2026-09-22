from __future__ import annotations

import sqlite3
import unittest

from automation.product_factory import projection, reconciler


class ProductFactoryProjectionTests(unittest.TestCase):
    def test_projects_cases_into_existing_portal_model_and_kanban_views(self) -> None:
        conn = sqlite3.connect(":memory:")
        conn.row_factory = sqlite3.Row
        reconciler.initialize(conn)
        reconciler.reconcile_issue(
            conn,
            {
                "repo": "ethenotethan/portal",
                "number": 260,
                "node_id": "I_260",
                "title": "Toolbar toggle",
                "body": "Fix it",
                "author": "ethenotethan",
                "labels": [
                    "factory:product",
                    "state:triage",
                    "priority:P1",
                    "validation:interactive",
                    "risk:bounded",
                ],
                "state": "open",
                "url": "https://github.com/ethenotethan/portal/issues/260",
                "updated_at": "2026-09-21T10:00:00Z",
                "parent_issue": None,
            },
            observed_at=100,
        )

        merge_queue = {
            "checked_at": "2026-09-21T12:00:00Z",
            "open_prs": [
                {
                    "number": 311,
                    "title": "test: improve timeline coverage",
                    "url": "https://github.com/ethenotethan/portal/pull/311",
                    "head_branch": "cron/quality-ratchet-20260921",
                    "head_oid": "abc123",
                    "status": "ready",
                    "status_details": [],
                    "first_seen_at": "2026-09-21T11:00:00Z",
                },
                {
                    "number": 312,
                    "title": "unrelated human feature",
                    "url": "https://github.com/ethenotethan/portal/pull/312",
                    "head_branch": "feat/unrelated",
                    "head_oid": "def456",
                    "status": "pending",
                    "status_details": [],
                    "first_seen_at": "2026-09-21T11:30:00Z",
                },
            ],
        }
        ratchet_state = {
            "offers": {
                "offer-1": {
                    "kind": "focused_existing_behavior_test",
                    "target": "Sources/Portal/Timeline.swift",
                    "offered_at": "2026-09-21T10:00:00Z",
                    "head": "abc000",
                },
                "stale-offer": {
                    "kind": "focused_existing_behavior_test",
                    "target": "Sources/Portal/Stale.swift",
                    "offered_at": "2026-08-01T10:00:00Z",
                    "head": "old000",
                },
            }
        }

        model = projection.build_model(
            conn,
            merge_queue=merge_queue,
            ratchet_state=ratchet_state,
        )

        self.assertEqual(model["id"], "portal-software-factories")
        self.assertEqual(model["entities"]["product_cases"]["key"], "case_id")
        self.assertEqual(model["entities"]["product_cases"]["items"][0]["issue_number"], 260)
        self.assertEqual(model["entities"]["product_cases"]["items"][0]["status"], "triage")
        self.assertEqual(model["entities"]["ratchet_work"]["key"], "work_id")
        self.assertEqual(
            {item["work_id"] for item in model["entities"]["ratchet_work"]["items"]},
            {"pr:311", "offer:offer-1"},
        )
        kanban_views = [view for view in model["views"] if view["type"] == "kanban"]
        self.assertEqual(len(kanban_views), 2)
        self.assertEqual(kanban_views[0]["entities"], ["product_cases"])
        self.assertEqual(kanban_views[1]["entities"], ["ratchet_work"])
        self.assertIn("table", [view["type"] for view in model["views"]])
        self.assertTrue(model["relations"])
        endpoints = {
            f"{set_name}/{item[entity_set['key']]}"
            for set_name, entity_set in model["entities"].items()
            for item in entity_set["items"]
        }
        for relation in model["relations"]:
            self.assertIn(relation["from"], endpoints)
            self.assertIn(relation["to"], endpoints)
            self.assertTrue(relation["type"])
        conn.close()


if __name__ == "__main__":
    unittest.main()
