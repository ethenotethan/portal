from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "automation" / "product_factory" / "policy.py"


def load_policy_module():
    if not MODULE_PATH.exists():
        raise AssertionError(f"missing product-factory policy module: {MODULE_PATH}")
    spec = importlib.util.spec_from_file_location("product_factory_policy", MODULE_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ProductFactoryPolicyTests(unittest.TestCase):
    def test_rejects_conflicting_lifecycle_labels(self) -> None:
        policy = load_policy_module()

        result = policy.validate_labels(
            {"factory:product", "factory:ready", "state:triage", "state:ready", "priority:P1"}
        )

        self.assertFalse(result.accepted)
        self.assertEqual(result.reason, "conflicting state labels: state:ready, state:triage")

    def test_rejects_conflicts_in_every_exclusive_dimension(self) -> None:
        policy = load_policy_module()

        conflicts = [
            ({"factory:product", "factory:ratchet"}, "factory"),
            ({"validation:interactive", "validation:noninteractive"}, "validation"),
            ({"risk:bounded", "risk:human-approval"}, "risk"),
            ({"work:parent", "work:child"}, "work"),
            ({"priority:P0", "priority:P2"}, "priority"),
        ]

        for labels, dimension in conflicts:
            with self.subTest(dimension=dimension):
                result = policy.validate_labels(labels)
                self.assertFalse(result.accepted)
                self.assertTrue(result.reason.startswith(f"conflicting {dimension} labels:"))

    def test_ready_admission_requires_product_priority_validation_and_risk(self) -> None:
        policy = load_policy_module()

        result = policy.evaluate_admission({"factory:ready", "factory:product"})

        self.assertFalse(result.accepted)
        self.assertEqual(
            result.reason,
            "ready admission requires exactly one priority, validation, and risk label",
        )

    def test_human_risk_requires_human_design_approval(self) -> None:
        policy = load_policy_module()
        labels = {
            "factory:ready",
            "factory:product",
            "priority:P1",
            "validation:interactive",
            "risk:human-approval",
        }

        result = policy.evaluate_admission(labels)

        self.assertFalse(result.accepted)
        self.assertEqual(result.reason, "risk:human-approval requires factory:design-approved")

    def test_ready_product_with_complete_bounded_policy_is_admitted(self) -> None:
        policy = load_policy_module()
        labels = {
            "factory:ready",
            "factory:product",
            "priority:P2",
            "validation:interactive",
            "risk:bounded",
            "state:ready",
        }

        result = policy.evaluate_admission(labels)

        self.assertTrue(result.accepted)
        self.assertIsNone(result.reason)

    def test_intent_digest_is_order_independent_but_changes_with_material_intent(self) -> None:
        policy = load_policy_module()
        labels = ["priority:P1", "factory:product", "risk:bounded", "factory:ready"]

        original = policy.intent_digest("Fix the toolbar\n\n- toggles closed", labels, parent_issue=None)
        reordered = policy.intent_digest(
            "Fix the toolbar\n\n- toggles closed", reversed(labels), parent_issue=None
        )
        changed = policy.intent_digest(
            "Fix both toolbars\n\n- toggles closed", labels, parent_issue=None
        )

        self.assertEqual(original, reordered)
        self.assertNotEqual(original, changed)

    def test_lifecycle_transition_cannot_skip_validation(self) -> None:
        policy = load_policy_module()

        rejected = policy.validate_transition("review", "merge-ready")
        accepted = policy.validate_transition("review", "validation")

        self.assertFalse(rejected.accepted)
        self.assertEqual(rejected.reason, "invalid lifecycle transition: review -> merge-ready")
        self.assertTrue(accepted.accepted)

    def test_human_only_label_rejects_factory_bot_actor(self) -> None:
        policy = load_policy_module()

        bot = policy.validate_label_actor(
            actor="hankbobtheresearchoor",
            added={"factory:design-approved"},
            maintainers={"ethenotethan"},
            factory_bot="hankbobtheresearchoor",
        )
        human = policy.validate_label_actor(
            actor="ethenotethan",
            added={"factory:design-approved"},
            maintainers={"ethenotethan"},
            factory_bot="hankbobtheresearchoor",
        )

        self.assertFalse(bot.accepted)
        self.assertEqual(bot.reason, "factory:design-approved requires a maintainer actor")
        self.assertTrue(human.accepted)


if __name__ == "__main__":
    unittest.main()
