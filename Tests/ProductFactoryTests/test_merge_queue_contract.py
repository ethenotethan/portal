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


if __name__ == "__main__":
    unittest.main()
