#!/usr/bin/env python3
"""Tests for the interplay graph, its overlay gate, and the graph invariants."""

from __future__ import annotations

import copy
import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts/build_architecture.py"
SPEC = importlib.util.spec_from_file_location("build_architecture", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
architecture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(architecture)


class InterplayGraphTests(unittest.TestCase):
    def setUp(self) -> None:
        self.files, _ = architecture.read_sources(architecture.load_json(architecture.CONFIG_PATH))
        self.behavior = architecture.build_behavior_model(self.files)
        self.interplay = architecture.build_interplay_graph(self.files, self.behavior)
        self.overlay = architecture.load_json(architecture.INTERPLAY_OVERLAY_PATH)

    def _nodes(self, sub_kind: str) -> list[dict]:
        return [n for n in self.interplay["nodes"] if n.get("sub_kind") == sub_kind]

    def test_graph_is_deterministic(self) -> None:
        again = architecture.build_interplay_graph(self.files, architecture.build_behavior_model(self.files))
        self.assertEqual(self.interplay, again)

    def test_surfaces_connection_pool_and_on_device_engines(self) -> None:
        kinds = {n["sub_kind"] for n in self.interplay["nodes"] if n["kind"] == "resource"}
        self.assertIn("rpc_pool", kinds)
        self.assertIn("on_device_model", kinds)
        self.assertIn("speech_synth", kinds)
        # The AgentBackend seam and the ChatViewModel hub anchor the interplay.
        labels = {(n["kind"], n["label"]) for n in self.interplay["nodes"]}
        self.assertIn(("seam", "AgentBackend"), labels)
        self.assertIn(("hub", "ChatViewModel"), labels)
        self.assertTrue(any(e["class"] == "interplay" for e in self.interplay["edges"]))

    # Invariant (a): every on-device model load moves off the @MainActor owner.
    def test_every_on_device_model_load_runs_detached(self) -> None:
        loads = self._nodes("model_load")
        self.assertTrue(loads, "expected at least one model_load operation")
        self.assertTrue(all(node["detached_off_main"] for node in loads))

    # Invariant (b): every RPC pool is guarded by a lock owned by the same type.
    def test_every_rpc_pool_has_a_co_owned_lock(self) -> None:
        pools = self._nodes("rpc_pool")
        self.assertTrue(pools, "expected at least one rpc_pool resource")
        lock_owners = {(n["component"], n["owner_type"]) for n in self._nodes("lock")}
        for pool in pools:
            self.assertIn((pool["component"], pool["owner_type"]), lock_owners)

    def test_overlay_explains_every_gated_resource(self) -> None:
        # The committed overlay must clear the gate against the real source tree.
        architecture.validate_interplay(copy.deepcopy(self.interplay), copy.deepcopy(self.overlay))

    def test_gate_rejects_unexplained_source(self) -> None:
        tampered = copy.deepcopy(self.interplay)
        tampered["nodes"].append({
            "id": "resource:stray", "kind": "resource", "sub_kind": "on_device_model",
            "owner_type": "StrayEngine", "label": "model",
            "path": "Sources/Portal/Services/TTSService.swift", "line": 1,
        })
        with self.assertRaises(architecture.ArchitectureError):
            architecture.validate_interplay(tampered, copy.deepcopy(self.overlay))

    def test_gate_rejects_stale_prose(self) -> None:
        tampered = copy.deepcopy(self.overlay)
        tampered["entries"].append({
            "id": "rpc_pool:GhostClient:ghostPool", "kind": "rpc_pool",
            "owner_type": "GhostClient", "label": "ghostPool", "prose": "lingering prose",
            "sources": ["Sources/Portal/Services/GatewayClient.swift:1"],
        })
        with self.assertRaises(architecture.ArchitectureError):
            architecture.validate_interplay(copy.deepcopy(self.interplay), tampered)

    def test_gate_rejects_missing_source_file(self) -> None:
        tampered = copy.deepcopy(self.overlay)
        tampered["entries"][0]["sources"] = ["Sources/Portal/Services/DoesNotExist.swift:1"]
        with self.assertRaises(architecture.ArchitectureError):
            architecture.validate_interplay(copy.deepcopy(self.interplay), tampered)


if __name__ == "__main__":
    unittest.main()
