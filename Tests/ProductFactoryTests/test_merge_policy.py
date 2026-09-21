from __future__ import annotations

import unittest

from automation.product_factory import merge_policy


class ProductFactoryMergePolicyTests(unittest.TestCase):
    def test_product_profile_requires_independent_review_cua_and_exact_sha_ci(self) -> None:
        evidence = {
            "linked_issue": 260,
            "accepted_intent_digest": "abc",
            "head_sha": "deadbeef",
            "implementation_generation": "impl-1",
            "review": {"generation": "review-1", "outcome": "pass", "sha": "deadbeef"},
            "validation": {
                "mode": "interactive",
                "runner": "cua-driver",
                "generation": "review-1",
                "outcome": "pass",
                "sha": "deadbeef",
            },
            "ci": {"outcome": "pass", "sha": "deadbeef"},
        }

        result = merge_policy.evaluate("product", evidence)

        self.assertTrue(result.accepted)
        self.assertEqual(result.missing, ())

    def test_product_profile_rejects_self_review_and_stale_validation(self) -> None:
        evidence = {
            "linked_issue": 260,
            "accepted_intent_digest": "abc",
            "head_sha": "newsha",
            "implementation_generation": "same-agent",
            "review": {"generation": "same-agent", "outcome": "pass", "sha": "newsha"},
            "validation": {
                "mode": "interactive",
                "runner": "cua-driver",
                "generation": "validator-1",
                "outcome": "pass",
                "sha": "oldsha",
            },
            "ci": {"outcome": "pass", "sha": "newsha"},
        }

        result = merge_policy.evaluate("product", evidence)

        self.assertFalse(result.accepted)
        self.assertIn("independent review", result.missing)
        self.assertIn("exact-sha validation", result.missing)

    def test_noninteractive_exemption_is_revoked_by_interactive_surface_changes(self) -> None:
        evidence = {
            "linked_issue": 260,
            "accepted_intent_digest": "abc",
            "head_sha": "deadbeef",
            "implementation_generation": "impl-1",
            "review": {"generation": "review-1", "outcome": "pass", "sha": "deadbeef"},
            "validation": {
                "mode": "noninteractive",
                "policy_confirmed": True,
                "interactive_files_touched": True,
                "generation": "review-1",
                "outcome": "pass",
                "sha": "deadbeef",
            },
            "ci": {"outcome": "pass", "sha": "deadbeef"},
        }

        result = merge_policy.evaluate("product", evidence)

        self.assertFalse(result.accepted)
        self.assertIn("valid noninteractive exemption", result.missing)

    def test_ratchet_profile_requires_metric_delta_but_not_issue(self) -> None:
        evidence = {
            "head_sha": "deadbeef",
            "metric": {"committed": True, "delta": 2.0, "sha": "deadbeef"},
            "ci": {"outcome": "pass", "sha": "deadbeef"},
        }

        result = merge_policy.evaluate("ratchet", evidence)

        self.assertTrue(result.accepted)

    def test_issue_closure_requires_post_merge_validation_on_accepted_main(self) -> None:
        passed = merge_policy.evaluate_closure(
            {
                "accepted_main_sha": "mainsha",
                "post_merge_validation": {
                    "outcome": "pass",
                    "sha": "mainsha",
                    "generation": "post-merge-1",
                },
            }
        )
        stale = merge_policy.evaluate_closure(
            {
                "accepted_main_sha": "mainsha",
                "post_merge_validation": {"outcome": "pass", "sha": "oldsha"},
            }
        )

        self.assertTrue(passed.accepted)
        self.assertFalse(stale.accepted)


if __name__ == "__main__":
    unittest.main()
