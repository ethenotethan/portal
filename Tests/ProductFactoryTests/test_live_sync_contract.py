from __future__ import annotations

import os
import runpy
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from automation.product_factory.topology import model_projection


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPOSITORY_ROOT / "scripts" / "portal-pr-kanban-sync.py"


class ProductFactoryLiveSyncContractTests(unittest.TestCase):
    def test_live_model_uses_canonical_architecture_and_preserves_cards(self) -> None:
        cards = [
            {
                "id": "pr-550",
                "column": "Human Hold",
                "automation_column": "CI / Review",
            },
            {"id": "pr-549", "_deleted": True},
        ]
        with tempfile.TemporaryDirectory() as hermes_home:
            with patch.dict(os.environ, {"HERMES_HOME": hermes_home}):
                namespace = runpy.run_path(str(SCRIPT))
                model = namespace["_model_document"](
                    {
                        "cards": cards,
                        "generation_runs": {},
                        "overview": "test",
                    }
                )

        canonical = model_projection()
        self.assertEqual(model["relations"], canonical["relations"])
        for name, entity_set in canonical["entities"].items():
            self.assertEqual(model["entities"][name], entity_set)
        self.assertEqual(model["entities"]["work"]["items"], cards)
        self.assertEqual(
            model["actions"]["work"][0]["field"],
            "column",
        )


if __name__ == "__main__":
    unittest.main()
