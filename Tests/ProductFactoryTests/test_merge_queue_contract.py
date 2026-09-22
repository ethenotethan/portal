from __future__ import annotations

import unittest
from pathlib import Path


SCRIPT = Path.home() / ".hermes" / "scripts" / "portal-merge-queue.sh"


class ProductFactoryMergeQueueContractTests(unittest.TestCase):
    def test_product_prs_require_product_merge_ready_labels(self) -> None:
        text = SCRIPT.read_text()

        self.assertIn('factory:product', text)
        self.assertIn('state:merge-ready', text)
        self.assertIn('PRODUCT_FACTORY', text)

    def test_blocked_label_is_an_unconditional_merge_veto(self) -> None:
        text = SCRIPT.read_text()

        self.assertIn('state:blocked', text)
        self.assertIn('BLOCKED_LABEL', text)
        self.assertLess(text.index('BLOCKED_LABEL'), text.index('# Skip drafts'))


if __name__ == "__main__":
    unittest.main()
