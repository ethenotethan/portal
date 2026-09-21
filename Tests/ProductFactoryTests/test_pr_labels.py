from __future__ import annotations

import unittest

from automation.product_factory import pr_labels


class ProductFactoryPRLabelTests(unittest.TestCase):
    def test_product_pr_inherits_factory_policy_and_lifecycle_dimensions(self) -> None:
        labels = pr_labels.for_product_pr(
            {
                "factory:product",
                "factory:ready",
                "state:ready",
                "priority:P1",
                "validation:interactive",
                "risk:bounded",
                "work:child",
                "bug",
            },
            lifecycle="review",
        )

        self.assertEqual(
            labels,
            {
                "factory:product",
                "state:review",
                "priority:P1",
                "validation:interactive",
                "risk:bounded",
                "work:child",
            },
        )

    def test_ratchet_pr_has_explicit_factory_and_state(self) -> None:
        self.assertEqual(
            pr_labels.for_ratchet_pr(lifecycle="review"),
            {"factory:ratchet", "state:review"},
        )


if __name__ == "__main__":
    unittest.main()
