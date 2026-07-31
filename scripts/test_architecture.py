#!/usr/bin/env python3
"""Tests for the deterministic architecture compiler."""

from __future__ import annotations

import importlib.util
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts/build_architecture.py"
SPEC = importlib.util.spec_from_file_location("build_architecture", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
architecture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(architecture)


class ArchitectureCompilerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.model, self.site_data = architecture.compile_architecture()

    def test_every_swift_file_is_assigned(self) -> None:
        self.assertEqual([], self.model["inventory"]["unassigned_files"])
        self.assertEqual(
            self.model["inventory"]["swift_files"],
            self.model["inventory"]["assigned_files"],
        )

    def test_graph_endpoints_and_evidence_are_valid(self) -> None:
        component_ids = {item["id"] for item in self.model["components"]}
        for edge in self.model["edges"]:
            self.assertIn(edge["source"], component_ids)
            self.assertIn(edge["target"], component_ids)
            self.assertTrue(edge["evidence"])
            for evidence in edge["evidence"]:
                self.assertTrue((ROOT / evidence).is_file(), evidence)

    def test_source_components_own_source(self) -> None:
        empty = [
            item["id"]
            for item in self.model["components"]
            if not item["external"] and item["file_count"] == 0
        ]
        self.assertEqual([], empty)

    def test_compilation_is_deterministic(self) -> None:
        second_model, second_site_data = architecture.compile_architecture()
        self.assertEqual(
            json.dumps(self.model, sort_keys=True),
            json.dumps(second_model, sort_keys=True),
        )
        self.assertEqual(
            json.dumps(self.site_data, sort_keys=True),
            json.dumps(second_site_data, sort_keys=True),
        )

    def test_specifications_are_human_authoritative(self) -> None:
        self.assertGreaterEqual(len(self.site_data["specifications"]), 3)
        self.assertTrue(
            all(item["authority"] == "specified" for item in self.site_data["specifications"])
        )

    def test_backend_contract_keeps_key_seam(self) -> None:
        backend = next(item for item in self.model["components"] if item["id"] == "backend-contract")
        self.assertIn("AgentBackend", backend["declarations"])
        self.assertIn("BackendCapabilities", backend["declarations"])


if __name__ == "__main__":
    unittest.main()
