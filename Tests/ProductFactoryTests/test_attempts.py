from __future__ import annotations

import unittest

from automation.product_factory import attempts


class ProductFactoryAttemptTests(unittest.TestCase):
    def test_two_corrective_attempts_then_blocks_on_third_substantive_rejection(self) -> None:
        self.assertEqual(attempts.after_failure(0, transient=False, max_corrective=2).action, "retry")
        self.assertEqual(attempts.after_failure(1, transient=False, max_corrective=2).action, "retry")
        blocked = attempts.after_failure(2, transient=False, max_corrective=2)
        self.assertEqual(blocked.action, "block")
        self.assertEqual(blocked.substantive_failures, 3)

    def test_transient_failure_does_not_consume_corrective_budget(self) -> None:
        result = attempts.after_failure(2, transient=True, max_corrective=2)

        self.assertEqual(result.action, "retry")
        self.assertEqual(result.substantive_failures, 2)


if __name__ == "__main__":
    unittest.main()
