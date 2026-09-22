from __future__ import annotations

import contextlib
import sys
import types
import unittest

from automation.product_factory import dispatcher, planner


class ProductFactoryDispatcherTests(unittest.TestCase):
    def test_builds_self_contained_idempotent_kanban_task(self) -> None:
        spec = planner.DispatchSpec(
            case_id="github:ethenotethan/portal#260",
            repo="ethenotethan/portal",
            issue_number=260,
            issue_url="https://github.com/ethenotethan/portal/issues/260",
            title="Toolbar toggle",
            intent_digest="digest-123",
            stage="implementation",
            generation_id="generation-1",
            regression=False,
        )
        captured: dict = {}

        def create_task(**kwargs):
            captured.update(kwargs)
            return "task-123"

        task_id = dispatcher.create_dispatch_task(
            spec,
            create_task=create_task,
            assignee="default",
            project_id="portal",
        )

        self.assertEqual(task_id, "task-123")
        self.assertEqual(captured["idempotency_key"], "product-factory:generation-1")
        self.assertEqual(captured["initial_status"], "running")
        self.assertEqual(captured["workspace_kind"], "worktree")
        self.assertEqual(captured["project_id"], "portal")
        self.assertIn("https://github.com/ethenotethan/portal/issues/260", captured["body"])
        self.assertIn("digest-123", captured["body"])
        self.assertIn("Closes #260", captured["body"])
        self.assertIn("push the branch", captured["body"])
        self.assertIn("factory:product", captured["body"])
        self.assertTrue(captured["goal_mode"])
        self.assertEqual(captured["goal_max_turns"], 8)
        self.assertIn("test-driven-development", captured["skills"])

    def test_validation_task_requires_inline_pr_screenshots_at_exact_sha(self) -> None:
        captured = {}

        def create_task(**kwargs):
            captured.update(kwargs)
            return "validation-510"

        task_id = dispatcher.create_validation_task(
            case_id="github:ethenotethan/portal#510",
            repo="ethenotethan/portal",
            issue_number=510,
            pr_url="https://github.com/ethenotethan/portal/pull/511",
            implementation_task_id="t_impl",
            generation_id="validation-generation-510",
            create_task=create_task,
            assignee="default",
            project_id="portal",
        )

        self.assertEqual(task_id, "validation-510")
        self.assertEqual(captured["parents"], ["t_impl"])
        self.assertEqual(
            captured["idempotency_key"],
            "product-factory:validation:validation-generation-510",
        )
        self.assertIn("exact PR head SHA", captured["body"])
        self.assertIn("computer_use", captured["body"])
        self.assertIn("reported target", captured["body"])
        self.assertIn("must never substitute", captured["body"])
        self.assertIn("PNG", captured["body"])
        self.assertIn("factory/evidence", captured["body"])
        self.assertIn("inline Markdown images", captured["body"])
        self.assertIn("state:merge-ready", captured["body"])
        self.assertIn("macos-computer-use", captured["skills"])
        self.assertTrue(captured["goal_mode"])

    def test_remediation_task_updates_existing_pr_then_returns_to_validation(self) -> None:
        captured = {}

        def create_task(**kwargs):
            captured.update(kwargs)
            return "remediation-510"

        task_id = dispatcher.create_remediation_task(
            case_id="github:ethenotethan/portal#510",
            repo="ethenotethan/portal",
            issue_number=510,
            pr_url="https://github.com/ethenotethan/portal/pull/511",
            validation_task_id="validate-510",
            blocker="Generated Xcode project leaked a worktree name.",
            generation_id="remediation-generation-510",
            create_task=create_task,
            assignee="default",
            project_id="portal",
        )

        self.assertEqual(task_id, "remediation-510")
        self.assertEqual(captured["parents"], ["validate-510"])
        self.assertEqual(
            captured["idempotency_key"],
            "product-factory:remediation:remediation-generation-510",
        )
        self.assertIn("existing PR", captured["body"])
        self.assertIn("same head branch", captured["body"])
        self.assertIn("must not force-push", captured["body"])
        self.assertIn("Generated Xcode project", captured["body"])
        self.assertIn("exact new head SHA", captured["body"])

    def test_production_adapter_addresses_board_by_keyword(self) -> None:
        spec = planner.DispatchSpec(
            case_id="github:ethenotethan/portal#510",
            repo="ethenotethan/portal",
            issue_number=510,
            issue_url="https://github.com/ethenotethan/portal/issues/510",
            title="Factory smoke",
            intent_digest="digest",
            stage="implementation",
            generation_id="generation-510",
            regression=False,
        )
        observed = {}

        @contextlib.contextmanager
        def connect_closing(*args, **kwargs):
            observed["args"] = args
            observed["kwargs"] = kwargs
            yield object()

        def create_task(_conn, **kwargs):
            observed["create"] = kwargs
            return "task-510"

        fake_db = types.ModuleType("hermes_cli.kanban_db")
        setattr(fake_db, "connect_closing", connect_closing)
        setattr(fake_db, "create_task", create_task)
        fake_package = types.ModuleType("hermes_cli")
        setattr(fake_package, "kanban_db", fake_db)
        prior = sys.modules.get("hermes_cli")
        sys.modules["hermes_cli"] = fake_package
        try:
            task_id = dispatcher.create_dispatch_task_on_board(spec, board="portal-product-factory")
        finally:
            if prior is None:
                sys.modules.pop("hermes_cli", None)
            else:
                sys.modules["hermes_cli"] = prior

        self.assertEqual(task_id, "task-510")
        self.assertEqual(observed["args"], ())
        self.assertEqual(observed["kwargs"], {"board": "portal-product-factory"})


if __name__ == "__main__":
    unittest.main()
