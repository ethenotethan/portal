from __future__ import annotations

import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONTRACT = ROOT / "automation" / "product_factory" / "policy.v1.json"
SCHEMA = ROOT / "automation" / "product_factory" / "policy.schema.json"
LABELS = ROOT / "automation" / "product_factory" / "labels.v1.json"


class ProductFactoryContractTests(unittest.TestCase):
    def test_contract_enables_bounded_produce_dispatch_without_merge_authority(self) -> None:
        self.assertTrue(CONTRACT.exists(), "missing versioned product-factory contract")
        contract = json.loads(CONTRACT.read_text())

        self.assertEqual(contract["version"], 1)
        self.assertEqual(contract["rollout_stage"], "produce")
        self.assertEqual(contract["repository"], "ethenotethan/portal")
        self.assertTrue(contract["authorities"]["mutate_github"])
        self.assertTrue(contract["authorities"]["dispatch_agents"])
        self.assertFalse(contract["authorities"]["merge_pull_requests"])
        self.assertFalse(contract["authorities"]["close_issues"])

    def test_contract_encodes_factory_capacity_and_retry_bounds(self) -> None:
        contract = json.loads(CONTRACT.read_text())

        self.assertEqual(contract["capacity"]["ordinary_active"], 2)
        self.assertEqual(contract["capacity"]["reserved_regression"], 1)
        self.assertEqual(contract["decomposition"]["max_depth"], 1)
        self.assertEqual(contract["decomposition"]["max_active_children"], 5)
        self.assertEqual(contract["attempts"]["max_corrective"], 2)
        self.assertFalse(contract["attempts"]["transient_failures_consume_budget"])

    def test_schema_requires_authority_and_capacity_fields(self) -> None:
        self.assertTrue(SCHEMA.exists(), "missing policy JSON Schema")
        schema = json.loads(SCHEMA.read_text())

        self.assertEqual(schema["$schema"], "https://json-schema.org/draft/2020-12/schema")
        self.assertIn("authorities", schema["required"])
        self.assertIn("capacity", schema["required"])
        self.assertFalse(schema["additionalProperties"])

    def test_label_manifest_covers_every_control_label(self) -> None:
        contract = json.loads(CONTRACT.read_text())
        manifest = json.loads(LABELS.read_text())
        expected = {label for labels in contract["labels"].values() for label in labels}
        entries = manifest["labels"] if "labels" in manifest else [
            {"name": name, **metadata} for name, metadata in manifest.items()
        ]
        actual = {entry["name"] for entry in entries}

        self.assertEqual(actual, expected)
        self.assertTrue(all(entry["description"] for entry in entries))
        self.assertTrue(all(len(entry["color"]) == 6 for entry in entries))


if __name__ == "__main__":
    unittest.main()
