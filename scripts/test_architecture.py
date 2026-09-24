#!/usr/bin/env python3
"""Tests for the deterministic architecture compiler."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import re
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts/build_architecture.py"
SPEC = importlib.util.spec_from_file_location("build_architecture", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
architecture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(architecture)
HISTORY_MODULE_PATH = ROOT / "scripts/build_architecture_history.py"
HISTORY_SPEC = importlib.util.spec_from_file_location("build_architecture_history", HISTORY_MODULE_PATH)
assert HISTORY_SPEC is not None and HISTORY_SPEC.loader is not None
history = importlib.util.module_from_spec(HISTORY_SPEC)
sys.modules[HISTORY_SPEC.name] = history  # dataclasses resolve deferred annotations through sys.modules
HISTORY_SPEC.loader.exec_module(history)


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

    def test_backend_contract_keeps_key_seam(self) -> None:
        backend = next(item for item in self.model["components"] if item["id"] == "backend-contract")
        self.assertIn("AgentBackend", backend["declarations"])
        self.assertIn("GatewayEvent", backend["declarations"])

    def test_extracts_task_sites_handles_and_cancellation(self) -> None:
        source = """final class Loader {
    private var refreshTask: Task<Void, Never>?
    func refresh() {
        refreshTask = Task.detached { await fetch() }
    }
    func stop() { refreshTask?.cancel() }
}
"""
        behavior = architecture.extract_behavioral_source(
            "Sources/Portal/Loader.swift", source, "services"
        )

        self.assertEqual(
            ["stored_task_handle", "task_detached", "task_cancellation"],
            [item["kind"] for item in behavior["task_sites"]],
        )
        detached = next(item for item in behavior["task_sites"] if item["kind"] == "task_detached")
        self.assertEqual("Loader", detached["enclosing_type"])
        self.assertEqual("refresh", detached["enclosing_function"])
        self.assertEqual(4, detached["evidence"]["line"])

    def test_extracts_websocket_resource_and_lifecycle_operations(self) -> None:
        source = """final class SocketClient {
    private var socket: URLSessionWebSocketTask?
    func run() async throws {
        socket?.resume()
        _ = try await socket?.receive()
        try await socket?.send(.string("ping"))
        socket?.cancel(with: .goingAway, reason: nil)
    }
}
"""
        behavior = architecture.extract_behavioral_source(
            "Sources/Portal/SocketClient.swift", source, "gateway-client"
        )

        self.assertEqual(["websocket"], [item["kind"] for item in behavior["resources"]])
        resource = behavior["resources"][0]
        self.assertEqual("socket", resource["label"])
        self.assertEqual("SocketClient", resource["owner_type"])
        self.assertEqual("one stored optional field per owner instance", resource["cardinality"])
        self.assertEqual(
            ["start", "receive", "send", "close"],
            [item["kind"] for item in behavior["operations"]],
        )
        self.assertTrue(all(item["resource_id"] == resource["id"] for item in behavior["operations"]))

    def test_extracts_sse_boundary_and_replay_cursor_signal(self) -> None:
        source = """final class EventClient {
    private let session: URLSession
    private var lastEventID: String?
    func connect(_ request: inout URLRequest) async throws {
        request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID")
        let (bytes, response) = try await session.bytes(for: request)
        guard response.value(forHTTPHeaderField: "Content-Type") == "text/event-stream" else { return }
        for try await line in bytes.lines { print(line) }
    }
}
"""
        behavior = architecture.extract_behavioral_source(
            "Sources/Portal/EventClient.swift", source, "centaur-client"
        )

        self.assertEqual(["url_session", "sse_stream"], [item["kind"] for item in behavior["resources"]])
        self.assertEqual(["replay_cursor", "subscribe"], [item["kind"] for item in behavior["operations"]])
        replay = behavior["operations"][0]
        self.assertEqual(5, replay["evidence"]["line"])
        self.assertEqual("swift.lifecycle.sse_replay_cursor", replay["rule_id"])

    def test_extracts_combine_batching_scheduler_and_named_queue(self) -> None:
        source = """final class EventBuffer {
    private let queue = DispatchQueue(label: "events")
    private let subject = PassthroughSubject<Event, Never>()
    func publish(_ event: Event) {
        subject.send(event)
        _ = subject
            .collect(.byTime(queue, .seconds(1)))
            .receive(on: queue)
    }
}
"""
        behavior = architecture.extract_behavioral_source(
            "Sources/Portal/EventBuffer.swift", source, "event-pipeline"
        )

        self.assertEqual(["combine_subject"], [item["kind"] for item in behavior["resources"]])
        self.assertEqual(["publish", "batch", "hop"], [item["kind"] for item in behavior["operations"]])

    def test_ignores_behavior_tokens_in_comments_and_strings(self) -> None:
        source = '''final class Harmless {
    // Task.detached { work() }
    /* actor FakeActor {}
       private var socket: URLSessionWebSocketTask? */
    let example = "Task { socket?.receive() } @MainActor actor Nope {}"
    let marker = "text/event-stream"
}
'''
        behavior = architecture.extract_behavioral_source(
            "Sources/Portal/Harmless.swift", source, "shared-ui"
        )

        self.assertEqual([], behavior["task_sites"])
        self.assertEqual([], behavior["resources"])
        self.assertEqual([], behavior["operations"])

    def test_compiled_model_has_static_behavior_metadata_pockets_and_stable_evidence(self) -> None:
        behavior = self.model["behavior"]
        self.assertEqual("static_source", self.model["evidence_metadata"]["class"])
        self.assertTrue(self.model["evidence_metadata"]["limitations"])
        self.assertEqual(sorted(architecture.BEHAVIOR_RULES), sorted(self.model["evidence_metadata"]["rules"]))
        self.assertTrue(behavior["task_sites"])
        self.assertTrue(behavior["resources"])
        self.assertTrue(behavior["pockets"])
        self.assertTrue(all("static ownership/lifecycle cluster" in item["derivation"] for item in behavior["pockets"]))
        for collection in ("task_sites", "resources", "operations"):
            evidence = [
                (item["evidence"]["path"], item["evidence"]["line"], item["id"])
                for item in behavior[collection]
            ]
            self.assertEqual(sorted(evidence), evidence)
            self.assertTrue(all(item["evidence"]["line"] > 0 for item in behavior[collection]))

    def test_extracts_continuation_lock_timer_and_create_invalidate_lifecycle(self) -> None:
        source = """final class LifecycleOwner {
    private let session: URLSession
    private var continuation: AsyncStream<Event>.Continuation?
    private let lock = NSLock()
    private var timer: Timer?
    private var socket: URLSessionWebSocketTask?
    func start(_ request: URLRequest) {
        socket = session.webSocketTask(with: request)
        lock.lock()
        lock.unlock()
        continuation?.yield(Event())
        continuation?.finish()
        timer?.invalidate()
    }
}
"""
        behavior = architecture.extract_behavioral_source(
            "Sources/Portal/LifecycleOwner.swift", source, "local-services"
        )

        self.assertEqual(
            ["url_session", "continuation", "lock", "timer", "websocket"],
            [item["kind"] for item in behavior["resources"]],
        )
        self.assertEqual(
            ["create", "acquire", "release", "publish", "close", "invalidate"],
            [item["kind"] for item in behavior["operations"]],
        )
        resource_by_id = {item["id"]: item for item in behavior["resources"]}
        self.assertEqual(
            ["websocket", "lock", "lock", "continuation", "continuation", "timer"],
            [resource_by_id[item["resource_id"]]["kind"] for item in behavior["operations"]],
        )
        self.assertEqual(
            [8, 9, 10, 11, 12, 13],
            [item["evidence"]["line"] for item in behavior["operations"]],
        )
        self.assertEqual(
            [
                "swift.lifecycle.create",
                "swift.lifecycle.acquire",
                "swift.lifecycle.release",
                "swift.lifecycle.continuation_publish",
                "swift.lifecycle.continuation_close",
                "swift.lifecycle.invalidate",
            ],
            [item["rule_id"] for item in behavior["operations"]],
        )
        repeated = architecture.extract_behavioral_source(
            "Sources/Portal/LifecycleOwner.swift", source, "local-services"
        )
        for collection in ("resources", "operations"):
            self.assertEqual(
                [item["id"] for item in behavior[collection]],
                [item["id"] for item in repeated[collection]],
            )

    def test_behavior_site_has_navigation_and_semantic_view_sections(self) -> None:
        index = (ROOT / "architecture/site/index.html").read_text(encoding="utf-8")
        for view in ("connections",):
            self.assertRegex(index, rf'<button[^>]+data-view="{view}"')
            self.assertRegex(index, rf'<section[^>]+id="{view}-view"')
            self.assertRegex(index, rf'id="{view}-content"')

    def test_behavior_site_has_deterministic_renderers_and_line_provenance(self) -> None:
        app = (ROOT / "architecture/site/app.js").read_text(encoding="utf-8")
        for renderer in ("renderConnections",):
            self.assertRegex(app, rf"function\s+{renderer}\s*\(")
        self.assertRegex(app, r"function\s+sourceLink\s*\(")
        self.assertIn("#L${evidence.line}", app)
        self.assertIn("textContent", app)
        self.assertNotIn("innerHTML = item.", app)

    def test_architecture_agent_write_path_is_semantic_only(self) -> None:
        agent = (ROOT / "scripts/architecture_agent.py").read_text(encoding="utf-8")
        write_receivers = set(re.findall(r"\b([A-Z][A-Z0-9_]*)\.write_text\(", agent))
        self.assertEqual({"SEMANTIC_PATH", "CONSTRUCTS_PATH", "FLOWS_PATH"}, write_receivers)
        for name, expected in (("SEMANTIC_PATH", "components.json"), ("CONSTRUCTS_PATH", "constructs.json"), ("FLOWS_PATH", "flows.json")):
            assignment = re.search(rf'^{name}\s*=\s*(.+)$', agent, re.MULTILINE)
            self.assertIsNotNone(assignment)
            assert assignment is not None
            self.assertIn(f'"architecture/semantic/{expected}"', assignment.group(1))
        self.assertNotIn("model.behavior", agent)
        # Records are validated by the compiler's own validators, never the agent's.
        self.assertIn("compiler.validate_construct_record(", agent)
        self.assertIn("compiler.validate_flow(", agent)

    def test_system_map_is_the_interplay_graph_with_an_invariants_dropdown(self) -> None:
        index = (ROOT / "architecture/site/index.html").read_text(encoding="utf-8")
        app = (ROOT / "architecture/site/app.js").read_text(encoding="utf-8")
        # The layered component map is gone; the interplay graph is the System map.
        self.assertNotIn('id="graph-view"', index)
        self.assertNotIn('data-view="graph"', index)
        self.assertRegex(index, r'<button[^>]+data-view="systemmap"[^>]*>System map</button>')
        self.assertRegex(index, r'<section class="view active" id="systemmap-view"')
        self.assertIn('replace(/^(graph|interplay)$/, "systemmap")', app)
        for removed in ("renderGraph", "selectComponent", "applyGraphState", "codeGraphReference", "renderStats"):
            self.assertNotRegex(app, rf"function\s+{removed}\s*\(")
        # Invariants are plain text at the foot of the page: no control, no graph effect.
        self.assertIn('id="invariants-list"', index)
        self.assertNotIn('id="invariant-select"', index)
        self.assertNotIn('id="invariant-detail"', index)
        self.assertRegex(app, r"function\s+renderInvariants\s*\(")
        for removed in ("renderInvariantSelect", "renderInvariantDetail", "invariantFocus", "invariant-select"):
            self.assertNotIn(removed, app)
        kinds = {item["kind"] for item in self.model["interplay"]["invariants"]}
        for kind in kinds:
            self.assertIn(f"{kind}:", app)
        # Live objects holding stored resources have their own hull.
        self.assertIn('INTERPLAY_MEMORY_GROUP = "In-memory constructions"', app)
        # Stores, pool owners and page→surface trigger edges are drawn.
        self.assertIn('["trigger", "#9fd18b"', app)
        for renderer in ("drawTriggerEdges", "triggerProvenance", "surfaceNodeFor"):
            self.assertRegex(app, rf"function\s+{renderer}\s*\(")
        self.assertIn('rect.setAttribute("class", "store")', app)
        # Directed edges with highlight-only relation labels, request-path highlighting, closable side inspector.
        self.assertIn('"marker-end": `url(#arrow-${edgeClass})`', app)
        self.assertIn('class: "interplay-edge-label"', app)
        for renderer in ("flowEdgeKeys", "interplayLinkMidpoint"):
            self.assertRegex(app, rf"function\s+{renderer}\s*\(")
        self.assertIn('close.className = "inspector-close"', app)
        self.assertIn('workspace.classList.toggle("has-inspector"', app)
        # Radial layout: in-memory constructions in the centre, pages ringed around them.
        self.assertIn('const sideOrder = ["top", "right", "bottom", "left"];', app)
        self.assertIn("INTERPLAY_MEMORY_GROUP, kind: \"memory\"", app)
        # The transport is one construction with two legs: a collapsible core and the event stream.
        self.assertIn('TRANSPORT_NODE_ID = "transport:core"', app)
        self.assertIn("const expandedOwners = new Set()", app)
        self.assertIn("REQUEST LEG · TRANSPORT CORE", app)
        self.assertIn("PUSH LEG · EVENT STREAM", app)
        self.assertNotIn("INTERPLAY_BUS_GROUP", app)
        self.assertIn('["push", "#d16f86"', app)
        self.assertRegex(app, r"function\s+subscriptionLabel\s*\(")

    def test_serialized_generated_outputs_are_byte_deterministic(self) -> None:
        first = architecture.expected_outputs()
        second = architecture.expected_outputs()
        first_hashes = {
            path.name: hashlib.sha256(content.encode("utf-8")).hexdigest()
            for path, content in first.items()
        }
        second_hashes = {
            path.name: hashlib.sha256(content.encode("utf-8")).hexdigest()
            for path, content in second.items()
        }
        self.assertEqual(first_hashes, second_hashes)
        self.assertEqual({"model.json", "data.js", "ArchitectureObservatoryAssets.swift"}, set(first_hashes))


    def test_external_systems_are_declared_observed_and_evidenced(self) -> None:
        externals = self.model["externals"]
        config = json.loads((ROOT / "architecture/config.json").read_text(encoding="utf-8"))
        self.assertEqual(
            [item["id"] for item in config["external_systems"]],
            [item["id"] for item in externals["systems"]],
        )
        component_ids = {item["id"] for item in self.model["components"]}
        for system in externals["systems"]:
            self.assertEqual("specified", system["description_authority"])
            self.assertEqual("observed", system["authority"])
            self.assertGreater(system["hit_count"], 0, system["id"])
            self.assertTrue(system["component_ids"], system["id"])
            for usage in system["usage"]:
                for evidence in usage["evidence"]:
                    self.assertTrue((ROOT / evidence["path"]).is_file(), evidence["path"])
                    self.assertGreater(evidence["line"], 0)
                    self.assertEqual("swift.boundary.external_signature", evidence["rule_id"])
        for edge in externals["edges"]:
            self.assertIn(edge["source"], component_ids)
            self.assertEqual("observed", edge["authority"])
            self.assertTrue(edge["evidence"])
        mlx = next(item for item in externals["systems"] if item["id"] == "apple-mlx")
        self.assertEqual(["local-services"], mlx["component_ids"])
        self.assertIn("swift.boundary.external_signature", self.model["evidence_metadata"]["boundary_rules"])
        self.assertIn("swift.store.declaration", self.model["evidence_metadata"]["boundary_rules"])

    def test_external_signatures_ignore_comments_and_respect_string_scope(self) -> None:
        systems = [{
            "id": "svc",
            "signatures": ["\\bWKWebView\\b", {"pattern": "api\\.example\\.com", "scope": "strings"}],
        }]
        snippet = (
            "import WebKit\n"
            "// WKWebView mentioned in a comment, api.example.com too\n"
            "let host = \"api.example.com\" // api.example.com\n"
            "final class A { let view: WKWebView; let note = \"WKWebView in a string\" }\n"
        )
        hits = architecture.extract_external_usage("Sources/Portal/A.swift", snippet, "chat-ui", systems)
        self.assertEqual(
            [("WKWebView", 4), ("api.example.com", 3)],
            sorted((hit["label"], hit["evidence"]["line"]) for hit in hits),
        )
        self.assertTrue(all(hit["system"] == "svc" and hit["component"] == "chat-ui" for hit in hits))

    def test_store_extraction_observes_body_extensions_and_namesake_helpers(self) -> None:
        snippet = (
            "import Foundation\n"
            "// enum CommentStore { UserDefaults.standard }\n"
            "enum DemoStoreDisk {\n"
            "    static let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!\n"
            "        .appendingPathComponent(\"portal\", isDirectory: true)\n"
            "        .appendingPathComponent(\"demo-store.json\")\n"
            "}\n"
            "@MainActor\n"
            "final class DemoStore: ObservableObject {\n"
            "    let note = \"applicationSupportDirectory inside a string\"\n"
            "    func load() -> [Int] { [] }\n"
            "}\n"
            "extension DemoStore {\n"
            "    func flag() -> Bool { UserDefaults.standard.bool(forKey: \"x\") }\n"
            "}\n"
            "struct MemoryOnlyCache { var items: [String: Int] = [:] }\n"
        )
        stores = architecture.extract_store_declarations("Sources/Portal/Demo.swift", snippet, "local-services")
        by_name = {item["type_name"]: item for item in stores}
        self.assertEqual({"DemoStore", "MemoryOnlyCache"}, set(by_name))
        demo = by_name["DemoStore"]
        self.assertEqual(["defaults", "file"], demo["persistence"])
        self.assertEqual({"portal", "demo-store.json"}, {item["label"] for item in demo["artifacts"]})
        self.assertEqual(
            {"helper DemoStoreDisk", "extension DemoStore"},
            {item["via"] for item in demo["mechanisms"]},
        )
        self.assertEqual(["unobserved"], by_name["MemoryOnlyCache"]["persistence"])
        self.assertEqual(9, demo["evidence"]["line"])

    def test_compiled_stores_are_owned_and_persistence_is_attributed(self) -> None:
        items = {item["type_name"]: item for item in self.model["stores"]["items"]}
        self.assertGreaterEqual(len(items), 20)
        self.assertTrue(all(item["component"] for item in items.values()))
        self.assertIn("file", items["SkillStore"]["persistence"])
        self.assertIn("skill-store.json", [artifact["label"] for artifact in items["SkillStore"]["artifacts"]])
        self.assertEqual(["keychain"], items["KeychainStore"]["persistence"])
        for item in items.values():
            self.assertTrue((ROOT / item["evidence"]["path"]).is_file())
            self.assertEqual("swift.store.declaration", item["rule_id"])

    def test_interplay_carries_external_boundary_nodes_and_edges(self) -> None:
        interplay = self.model["interplay"]
        node_ids = {node["id"] for node in interplay["nodes"]}
        externals = {node["id"]: node for node in interplay["nodes"] if node["kind"] == "external"}
        declared = {f"external:{system['id']}" for system in self.model["externals"]["systems"]}
        self.assertTrue(set(externals) <= declared)
        self.assertIn("external:harness-gateway", externals)
        self.assertIn("external:apple-mlx", externals)
        boundary = [edge for edge in interplay["edges"] if edge["class"] == "boundary"]
        self.assertTrue(boundary)
        artifacts = {node["id"] for node in interplay["nodes"] if node["kind"] == "artifact"}
        # No external node floats: each one is the target of at least one boundary edge.
        # Artifacts are the other boundary targets: a store persists to a named file,
        # directory or defaults key, which is stored in its system.
        self.assertEqual(set(externals), {edge["target"] for edge in boundary} - artifacts)
        for edge in boundary:
            self.assertIn(edge["source"], node_ids)
            self.assertIn(edge["target"], set(externals) | artifacts)
        # Every JSON-RPC / REST endpoint box hangs off the gateway it is served by.
        endpoint_ids = {node["id"] for node in interplay["nodes"] if node["kind"] == "endpoint"}
        served = {
            edge["source"] for edge in boundary
            if edge["relation"] == "served-by" and edge["target"] == "external:harness-gateway"
        }
        self.assertTrue(endpoint_ids)
        self.assertEqual(endpoint_ids, served)
        runs_on = {edge["source"] for edge in boundary if edge["relation"] == "runs-on" and edge["target"] == "external:apple-mlx"}
        self.assertTrue(any("MLX" in source for source in runs_on), runs_on)
        self.assertTrue(any(edge["relation"] == "persists-to" for edge in boundary))
        clusters = {cluster["id"]: cluster for cluster in interplay["clusters"]}
        for node in externals.values():
            self.assertEqual("External systems", clusters[node["cluster"]]["owner_type"])
            self.assertEqual("specified", node["description_authority"])

    def test_stores_persist_to_named_artifacts_inside_boxed_storage_systems(self) -> None:
        interplay = self.model["interplay"]
        by_id = {node["id"]: node for node in interplay["nodes"]}
        artifacts = {node["id"]: node for node in interplay["nodes"] if node["kind"] == "artifact"}
        self.assertTrue(artifacts)
        relations = {(e["source"], e["target"], e["relation"]) for e in interplay["edges"]}
        # A file under its folder; a directory pair nested; a defaults key through a constant.
        self.assertIn("artifact:file-system:portal/artifacts.json", artifacts)
        self.assertEqual(["ArtifactStore"], artifacts["artifact:file-system:portal/artifacts.json"]["stores"])
        self.assertIn(("subscriber:ArtifactStore", "artifact:file-system:portal/artifacts.json", "persists-to"), relations)
        self.assertIn(("artifact:file-system:portal/artifacts.json", "external:file-system", "stored-in"), relations)
        self.assertNotIn(("subscriber:ArtifactStore", "external:file-system", "persists-to"), relations, "the artifact edge replaces the direct one")
        self.assertIn("artifact:file-system:portal/wiki-graph-cache", artifacts)
        self.assertNotIn("artifact:file-system:portal", artifacts, "a bare parent folder is not a leaf")
        self.assertIn("artifact:file-system:portal/sessions", artifacts)
        defaults_keys = [node for node in artifacts.values() if node["sub_kind"] == "defaults_key"]
        self.assertTrue(defaults_keys, "forKey: Self.storageKey resolves through the constant")
        self.assertTrue(all(node["system_id"] == "user-defaults" for node in defaults_keys))
        for node in artifacts.values():
            self.assertIn(node["sub_kind"], {"file", "directory", "defaults_key"})
            self.assertTrue(node["stores"] and node["evidence"])
            self.assertIn(f"external:{node['system_id']}", by_id)
            self.assertIn((node["id"], f"external:{node['system_id']}", "stored-in"), relations)
            self.assertEqual(by_id[f"external:{node['system_id']}"]["cluster"], node["cluster"])
        # The declared boundary groups box the storage and inference systems.
        groups = {group["id"]: group for group in interplay["boundary_groups"]}
        self.assertEqual({"platform-storage", "on-device-inference"}, set(groups))
        self.assertEqual({"external:file-system", "external:keychain", "external:user-defaults"}, set(groups["platform-storage"]["members"]))
        self.assertEqual({"external:apple-mlx", "external:speech-synthesis"}, set(groups["on-device-inference"]["members"]))
        self.assertIsNone(by_id["external:harness-gateway"].get("boundary_group"))
        self.assertEqual("platform-storage", by_id["external:keychain"]["boundary_group"])
        # Fail-closed declarations.
        config = json.loads((ROOT / "architecture/config.json").read_text(encoding="utf-8"))
        config["external_groups"].append({"id": "dup", "label": "Dup", "description": "x", "categories": ["ml-runtime"]})
        with self.assertRaisesRegex(architecture.ArchitectureError, "boxed by more than one"):
            architecture.validate_external_groups(config)
        config = json.loads((ROOT / "architecture/config.json").read_text(encoding="utf-8"))
        config["external_groups"][0]["categories"] = ["nope"]
        with self.assertRaisesRegex(architecture.ArchitectureError, "unknown category"):
            architecture.validate_external_groups(config)
        # Leaf rules on a synthetic store.
        leaves = architecture.store_leaf_artifacts({"artifacts": [
            {"kind": "directory", "label": "portal", "evidence": {"path": "a", "line": 1}},
            {"kind": "file", "label": "x.json", "evidence": {"path": "a", "line": 2}},
            {"kind": "defaults_key", "label": "portal.flag", "evidence": {"path": "a", "line": 3}},
        ]})
        self.assertEqual([("file", "portal/x.json"), ("defaults_key", "portal.flag")], [(l["kind"], l["label"]) for l in leaves])
        leaves = architecture.store_leaf_artifacts({"artifacts": [
            {"kind": "directory", "label": "portal", "evidence": {"path": "a", "line": 1}},
            {"kind": "directory", "label": "cache", "evidence": {"path": "a", "line": 2}},
        ]})
        self.assertEqual([("directory", "portal/cache")], [(l["kind"], l["label"]) for l in leaves])
        # The site draws storage systems as containers inside a boundary box.
        app = (ROOT / "architecture/site/app.js").read_text(encoding="utf-8")
        for needle in ("function isStorageContainer(", "function isContainmentEdge(", "interplay.boundary_groups", 'kind: "boundary"', 'rect.setAttribute("class", "artifact")', "Persisted artifact"):
            self.assertIn(needle, app)
        styles = (ROOT / "architecture/site/styles.css").read_text(encoding="utf-8")
        for rule in (".interplay-group.storage", ".interplay-group.boundary", ".interplay-node rect.artifact"):
            self.assertIn(rule, styles)

    def test_interplay_tags_nodes_with_the_navigation_page_that_reaches_them(self) -> None:
        interplay = self.model["interplay"]
        config = json.loads((ROOT / "architecture/config.json").read_text(encoding="utf-8"))
        # The launch zone is drawn first; the navigation pages follow in declared order.
        self.assertEqual(["launch"] + [p["id"] for p in config["pages"]["items"]], [p["id"] for p in interplay["pages"]])
        page_by_label = {n["label"]: n.get("page") for n in interplay["nodes"] if n["kind"] in {"caller", "hub", "owner", "subscriber"}}
        self.assertEqual("chat", page_by_label["ChatViewModel"])
        self.assertEqual("graphs", page_by_label["CronGraphViewModel"])
        self.assertEqual("graphs", page_by_label["WikiGraphViewModel"])
        # Reached at the same distance by several roots; resolved by the namespaces
        # and components the pages declare they own.
        self.assertEqual("cron", page_by_label["CronListViewModel"])
        self.assertEqual("sessions", page_by_label["SessionListViewModel"])
        self.assertEqual("artifacts", page_by_label["ArtifactStore"])
        self.assertEqual("skills", page_by_label["SkillStore"])
        # Started by the shell, reached by no page's view tree: placed by the namespace it invokes.
        self.assertEqual("cron", page_by_label["CronPoller"])
        resolutions = {n["label"]: n.get("page_resolution") for n in interplay["nodes"] if "page_resolution" in n}
        self.assertEqual("reachability", resolutions["ChatViewModel"])
        self.assertEqual("namespace", resolutions["CronListViewModel"])
        self.assertEqual("component", resolutions["ArtifactStore"])
        self.assertEqual("skills", page_by_label["SkillSummaryService"])
        self.assertEqual("feed", page_by_label["FeedViewModel"])
        self.assertEqual("files", page_by_label["FilesBrowserViewModel"])
        # The transport is reached from everywhere and never owned by a page.
        self.assertIn(page_by_label["GatewayClient"], {"shared", None})
        page_ids = {p["id"] for p in interplay["pages"]} | {"shared", None}
        for node in interplay["nodes"]:
            if "page" in node:
                self.assertIn(node["page"], page_ids)

    def test_page_assignment_prefers_the_closest_page_and_shares_ties(self) -> None:
        files = [
            {"path": "a/ChatView.swift", "declarations": ["ChatView"], "identifiers": ["ChatView", "ChatViewModel", "Shared"]},
            {"path": "a/ChatViewModel.swift", "declarations": ["ChatViewModel"], "identifiers": ["ChatViewModel", "Engine"]},
            {"path": "a/Engine.swift", "declarations": ["Engine"], "identifiers": ["Engine"]},
            {"path": "a/CronView.swift", "declarations": ["CronView"], "identifiers": ["CronView", "Shared", "ChatView"]},
            {"path": "a/Shared.swift", "declarations": ["Shared"], "identifiers": ["Shared"]},
            {"path": "a/ContentView.swift", "declarations": ["ContentView"], "identifiers": ["ContentView", "ChatView", "CronView", "Engine"]},
        ]
        config = {"pages": {"shell": ["ContentView"], "items": [
            {"id": "chat", "label": "Chat", "roots": ["ChatView"]},
            {"id": "cron", "label": "Cron", "roots": ["CronView"]},
        ]}}
        page_of, pages, ties = architecture.assign_pages(files, config)
        self.assertEqual({"Shared": ["chat", "cron"]}, ties)
        self.assertEqual("chat", page_of["ChatViewModel"])
        self.assertEqual("chat", page_of["Engine"])          # reached through ChatViewModel only
        self.assertEqual("shared", page_of["Shared"])        # both roots reach it at depth 1
        self.assertEqual("cron", page_of["CronView"])
        self.assertNotIn("ContentView", page_of)             # shell is never entered
        self.assertEqual("chat", page_of["ChatView"])        # another page's root is a boundary, not a member
        self.assertEqual([("chat", 3), ("cron", 1)], [(p["id"], p["type_count"]) for p in pages])

    def test_scope_resolution_handles_multi_line_signatures(self) -> None:
        snippet = (
            "final class Client {\n"
            "    internal func call(\n"
            "        _ method: String,\n"
            "        params: [String: Int]? = nil\n"
            "    ) async throws -> Int {\n"
            "        lock.lock()\n"
            "        return 1\n"
            "    }\n"
            "    func other() -> Bool { true }\n"
            "}\n"
            "protocol P { func requirement() -> Int; func again() }\n"
        )
        offset = snippet.index("lock.lock()")
        self.assertEqual(("Client", "call"), architecture.enclosing_context(snippet, offset))
        offset_other = snippet.index("true")
        self.assertEqual(("Client", "other"), architecture.enclosing_context(snippet, offset_other))
        # Body-less protocol requirements never swallow a later brace.
        blocks = {name: kind for _, _, kind, name in architecture.declaration_blocks(snippet)}
        self.assertNotIn("requirement", blocks)
        self.assertNotIn("again", blocks)

    def test_interplay_assembles_lock_guarded_critical_sections_and_holds_edges(self) -> None:
        interplay = self.model["interplay"]
        by_id = {node["id"]: node for node in interplay["nodes"]}
        sections = {node["label"]: node for node in interplay["nodes"] if node["kind"] == "section" and node["owner_type"] == "GatewayClient"}
        self.assertIn("call", sections)
        self.assertIn("fulfillRequest", sections)
        call = sections["call"]
        kinds = [step["kind"] for step in call["steps"]]
        self.assertEqual(["acquire", "pool_register", "release"], kinds[:3])
        self.assertIn("send", kinds)
        self.assertLess(kinds.index("release"), kinds.index("send"))  # the lock is not held across the socket write
        self.assertEqual(["pendingRequestsLock"], call["lock_labels"])
        self.assertEqual(["pendingRequests"], call["guarded_resources"])
        # Resolution happens outside the lock; the pool mutation happens inside it.
        fulfill = [step["kind"] for step in sections["fulfillRequest"]["steps"]]
        self.assertEqual(["acquire", "pool_remove", "release", "pool_resolve"], fulfill)
        self.assertEqual(["pendingRequests"], sections["fulfillRequest"]["guarded_resources"])
        self.assertIn("swift.lifecycle.pool_remove", self.model["evidence_metadata"]["rules"])
        self.assertTrue(call["steps"][1]["guarded"])
        self.assertFalse(call["steps"][kinds.index("send")]["guarded"])
        relations = {(e["relation"], by_id[e["target"]]["label"]) for e in interplay["edges"] if e["source"] == call["id"]}
        self.assertIn(("locks", "pendingRequestsLock"), relations)
        self.assertIn(("pool_register", "pendingRequests"), relations)
        self.assertIn(("send", "webSocketTask"), relations)
        # Every calling surface holds the one shared client.
        callers = {node["id"] for node in interplay["nodes"] if node["kind"] == "caller"}
        holders = {e["source"] for e in interplay["edges"] if e["relation"] == "holds" and by_id[e["target"]]["label"] == "GatewayClient"}
        self.assertEqual(callers, holders)
        # Covered pool operations are not drawn twice.
        self.assertFalse([n for n in interplay["nodes"] if n["kind"] == "operation" and n.get("owner_type") == "GatewayClient" and n["sub_kind"] in {"pool_register", "pool_resolve"}])

    def test_interplay_invariants_hold_and_are_published(self) -> None:
        results = self.model["interplay"]["invariants"]
        declared = json.loads((ROOT / "architecture/interplay/invariants.json").read_text(encoding="utf-8"))["invariants"]
        self.assertEqual([d["id"] for d in declared], [r["id"] for r in results])
        self.assertTrue(all(r["status"] == "holds" for r in results), results)
        self.assertTrue(all(r["why"] for r in results))

    def test_interplay_invariants_fail_when_the_construction_drifts(self) -> None:
        def graph(*, guarded: bool, holds: bool) -> tuple[dict, dict]:
            ev = {"path": "Sources/Portal/Services/GatewayClient.swift", "line": 10}
            nodes = [
                {"id": "owner:c:GatewayClient", "kind": "owner", "label": "GatewayClient", "component": "c", "roles": ["transport"], "page": "shared"},
                {"id": "seam:AgentBackend", "kind": "seam", "label": "AgentBackend", "component": "c"},
                {"id": "resource:pool", "kind": "resource", "sub_kind": "rpc_pool", "label": "pendingRequests", "owner_type": "GatewayClient"},
                {"id": "resource:lock", "kind": "resource", "sub_kind": "lock", "label": "pendingRequestsLock", "owner_type": "GatewayClient"},
                {"id": "caller:c:Page", "kind": "caller", "label": "Page", "component": "c", "page": "chat", "namespaces": ["wiki"]},
                {"id": "endpoint:1", "kind": "endpoint", "label": "wiki", "component": "c", "owner_type": "GatewayClient"},
                {"id": "section:c:GatewayClient:call", "kind": "section", "label": "call", "owner_type": "GatewayClient",
                 "lock_labels": ["pendingRequestsLock"], "steps": [
                     {"kind": "acquire", "line": 9, "guarded": False},
                     {"kind": "pool_register", "line": 10, "guarded": guarded},
                     {"kind": "release", "line": 11, "guarded": False}]},
            ]
            edges = [{"source": "owner:c:GatewayClient", "target": "endpoint:1", "class": "structure", "relation": "dispatches"}]
            if holds:
                edges.append({"source": "caller:c:Page", "target": "owner:c:GatewayClient", "class": "usage", "relation": "holds"})
            interplay = {"nodes": nodes, "edges": edges, "pages": [{"id": "chat", "label": "Chat"}]}
            behavior = {"operations": [
                {"kind": "pool_register", "owner_type": "GatewayClient", "resource_label": "pendingRequests", "enclosing_function": "call", "evidence": ev},
                {"kind": "pool_resolve", "owner_type": "GatewayClient", "resource_label": "pendingRequests", "enclosing_function": "fulfill", "evidence": {**ev, "line": 20}},
                {"kind": "pool_remove", "owner_type": "GatewayClient", "resource_label": "pendingRequests", "enclosing_function": "fulfill", "evidence": {**ev, "line": 19}},
            ]}
            return interplay, behavior
        invariants = json.loads((ROOT / "architecture/interplay/invariants.json").read_text(encoding="utf-8"))
        interplay, behavior = graph(guarded=True, holds=True)
        # The synthetic fulfil path has no section, so its remove is unguarded: that alone must be reported.
        with self.assertRaises(architecture.ArchitectureError) as caught:
            architecture.validate_interplay_invariants(interplay, behavior, invariants)
        self.assertIn("pool-guarded: pool mutation pool_remove outside pendingRequestsLock", str(caught.exception))
        # Drop the surface's reference to the core: a second, independent violation.
        interplay, behavior = graph(guarded=False, holds=False)
        with self.assertRaises(architecture.ArchitectureError) as caught:
            architecture.validate_interplay_invariants(interplay, behavior, invariants)
        message = str(caught.exception)
        self.assertIn("surfaces-hold-core: surfaces without a reference", message)
        self.assertIn("pool mutation pool_register outside pendingRequestsLock", message)
        self.assertIn("why:", message)

    def test_event_bus_subscriptions_record_batching_and_notify_the_hub(self) -> None:
        interplay = self.model["interplay"]
        by_id = {node["id"]: node for node in interplay["nodes"]}
        bus = next(node for node in interplay["nodes"] if node.get("sub_kind") == "event_bus")
        notified = {by_id[e["target"]]["label"]: by_id[e["target"]] for e in interplay["edges"] if e["source"] == bus["id"] and e["relation"] == "notifies"}
        self.assertIn("ChatViewModel", notified)          # the hub is notified, without a second box
        self.assertEqual("hub", notified["ChatViewModel"]["kind"])
        chat = notified["ChatViewModel"]["subscription"]
        self.assertEqual(("batched", 32, 30), (chat["mode"], chat["batch_ms"], chat["batch_count"]))
        spawn = notified["SpawnTreeStore"]["subscription"]
        self.assertEqual(("batched", 32, 30, "DispatchQueue.main"), (spawn["mode"], spawn["batch_ms"], spawn["batch_count"], spawn["scheduler"]))
        activity = notified["ActivityInboxViewModel"]["subscription"]
        self.assertEqual(("direct", "RunLoop.main"), (activity["mode"], activity["scheduler"]))
        for node in notified.values():
            self.assertTrue((ROOT / node["subscription"]["path"]).is_file())
            self.assertEqual("swift.resource.bus_subscription", node["subscription"]["rule_id"])
        self.assertIn("swift.resource.bus_subscription", self.model["evidence_metadata"]["rules"])

    def test_parse_bus_subscription_reads_the_operator_chain(self) -> None:
        code = "        client.eventStream\n            .collect(.byTimeOrCount(RunLoop.main, .milliseconds(32), 30))\n            .sink { batch in }\n        other.receive(on: DispatchQueue.main)\n"
        sub = architecture.parse_bus_subscription(code, code.index("eventStream") + len("eventStream"))
        self.assertEqual({"mode": "batched", "scheduler": "RunLoop.main", "batch_ms": 32, "batch_count": 30, "rule_id": "swift.resource.bus_subscription"}, sub)
        code = "        client.eventStream\n            .sink { event in }\n            .receive(on: RunLoop.main)\n"
        sub = architecture.parse_bus_subscription(code, code.index("eventStream") + len("eventStream"))
        self.assertEqual("direct", sub["mode"])
        self.assertIsNone(sub["scheduler"])  # the receive(on:) after the sink is not part of this binding

    def test_every_extracted_store_is_on_the_map_and_pool_owners_are_admitted(self) -> None:
        interplay = self.model["interplay"]
        labels = {node["label"] for node in interplay["nodes"]}
        for item in self.model["stores"]["items"]:
            self.assertIn(item["type_name"], labels, item["type_name"])
        by_label = {node["label"]: node for node in interplay["nodes"] if node["kind"] == "store"}
        self.assertIn("MarkdownParseCache", by_label)
        self.assertEqual(["unobserved"], by_label["MarkdownParseCache"]["store"]["persistence"])
        self.assertIn("ActivityStore", by_label)
        self.assertEqual("activity", by_label["ActivityStore"]["page"])
        # Stores that already appear as surfaces are annotated, not duplicated.
        annotated = [n for n in interplay["nodes"] if n["label"] == "ArtifactStore"]
        self.assertEqual(1, len(annotated))
        self.assertEqual("subscriber", annotated[0]["kind"])
        self.assertIn("file", annotated[0]["store"]["persistence"])
        owners = {n["label"]: n for n in interplay["nodes"] if n["kind"] == "owner"}
        self.assertIn("FileDownloadManager", owners)
        self.assertEqual(["pool"], owners["FileDownloadManager"]["roles"])
        self.assertNotIn("transport", owners["FileDownloadManager"]["roles"])

    def test_triggers_are_receiver_qualified_and_resolve_to_namespaces(self) -> None:
        interplay = self.model["interplay"]
        triggers = interplay["triggers"]
        self.assertGreaterEqual(len(triggers), 20)
        self.assertGreater(interplay["unattributed_triggers"], 0)  # local-state-only actions are counted, not attributed
        for trigger in triggers:
            self.assertIn(trigger["kind"], {"user_action", "lifecycle", "launch"})
            self.assertTrue((ROOT / trigger["path"]).is_file())
            self.assertEqual(
                "swift.trigger.launch_construction" if trigger["kind"] == "launch" else "swift.trigger.surface_call",
                trigger["rule_id"],
            )
        refresh = [t for t in triggers if t["surface"] == "ActivityInboxViewModel" and t["method"] == "refresh"]
        self.assertTrue(refresh)
        self.assertEqual(["activity"], refresh[0]["namespaces"])
        self.assertEqual("activity", refresh[0]["page"])
        learning = [t for t in triggers if t["surface"] == "LearningStore"]
        self.assertTrue(learning)   # a singleton-initialised store property is still a surface
        surfaces = {n["label"]: n for n in interplay["nodes"] if n.get("triggers")}
        self.assertGreater(surfaces["ChatViewModel"]["triggers"]["user_action"], 0)
        self.assertIn("swift.trigger.surface_call", self.model["evidence_metadata"]["rules"])

    def test_trigger_property_matcher_accepts_annotations_initialisers_and_singletons(self) -> None:
        code = (
            "    @EnvironmentObject var chatViewModel: ChatViewModel\n"
            "    @StateObject private var quizVM = QuizViewModel()\n"
            "    @ObservedObject private var learningStore = LearningStore.shared\n"
            "    @State private var count: Int = 0\n"
        )
        found = {m.group("name"): (m.group("annot") or m.group("init")) for m in architecture.TRIGGER_PROPERTY_RE.finditer(code)}
        self.assertEqual({"chatViewModel": "ChatViewModel", "quizVM": "QuizViewModel", "learningStore": "LearningStore", "count": "Int"}, found)

    def test_stores_have_reference_edges_and_reference_tie_break(self) -> None:
        interplay = self.model["interplay"]
        by_id = {node["id"]: node for node in interplay["nodes"]}
        uses = {(by_id[e["source"]]["label"], by_id[e["target"]]["label"]) for e in interplay["edges"]
                if e["relation"] == "uses" and by_id[e["target"]].get("store")}
        self.assertIn(("ChatViewModel", "ChatHistoryStore"), uses)
        self.assertIn(("ActivityInboxViewModel", "ActivityStore"), uses)
        self.assertGreaterEqual(len(uses), 12)
        resolutions = {n["label"]: (n.get("page"), n.get("page_resolution")) for n in interplay["nodes"] if n.get("store")}
        self.assertEqual(("chat", "reference"), resolutions["DelegationBatchHistoryStore"])
        # Referenced from two pages: stays shared rather than guessing.
        self.assertEqual("shared", resolutions["CronRunHistoryStore"][0])

    def test_interplay_records_owner_references_for_zone_placement(self) -> None:
        interplay = self.model["interplay"]
        by_id = {node["id"]: node for node in interplay["nodes"]}
        uses = {(by_id[e["source"]]["label"], by_id[e["target"]]["label"])
                for e in interplay["edges"] if e["relation"] == "uses"}
        self.assertIn(("SkillStore", "SkillSummaryService"), uses)
        self.assertIn(("ChatViewModel", "TTSService"), uses)
        # Transports are never `uses` targets: they are shared by construction.
        transports = {node["label"] for node in interplay["nodes"] if node["kind"] == "owner" and "transport" in node.get("roles", [])}
        self.assertFalse({target for _, target in uses} & transports)

    def test_interplay_routes_namespaces_through_client_extension_files(self) -> None:
        interplay = self.model["interplay"]
        clients = [node for node in interplay["nodes"] if node["kind"] == "client"]
        self.assertTrue(clients)
        for client in clients:
            self.assertTrue(client["path"].endswith(".swift"), client["path"])
            self.assertEqual(Path(client["path"]).stem, client["label"])
            self.assertTrue(client["namespaces"], client["id"])
            self.assertTrue((ROOT / client["path"]).is_file())
        endpoint_ids = {node["id"] for node in interplay["nodes"] if node["kind"] == "endpoint"}
        # The one core dispatches every namespace, whichever file hosts the wrapper.
        dispatched = {edge["target"] for edge in interplay["edges"] if edge["relation"] == "dispatches"}
        self.assertEqual(endpoint_ids, dispatched)
        # Every extension file routes through the core, and records what it implements.
        routed = {edge["source"] for edge in interplay["edges"] if edge["relation"] == "routes-through"}
        self.assertEqual({client["id"] for client in clients}, routed)
        implements = {edge["source"] for edge in interplay["edges"] if edge["relation"] == "implements"}
        self.assertEqual({client["id"] for client in clients}, implements)
        # A surface that invokes a namespace calls the extension file wrapping it.
        by_id = {node["id"]: node for node in interplay["nodes"]}
        for edge in interplay["edges"]:
            if edge["relation"] == "calls":
                self.assertEqual("caller", by_id[edge["source"]]["kind"])
                self.assertEqual("client", by_id[edge["target"]]["kind"])
                self.assertTrue(set(by_id[edge["source"]]["namespaces"]) & set(by_id[edge["target"]]["namespaces"]))
        for node in interplay["nodes"]:
            if node["kind"] == "endpoint":
                for entry in node["methods"]:
                    self.assertIn(entry["path"], node["files"])

    def test_boundary_site_views_and_renderers_exist(self) -> None:
        index = (ROOT / "architecture/site/index.html").read_text(encoding="utf-8")
        for view in ("externals", "stores"):
            self.assertRegex(index, rf'<button[^>]+data-view="{view}"')
            self.assertRegex(index, rf'<section[^>]+id="{view}-view"')
            self.assertRegex(index, rf'id="{view}-content"')
        app = (ROOT / "architecture/site/app.js").read_text(encoding="utf-8")
        for renderer in ("renderExternals", "renderStores"):
            self.assertRegex(app, rf"function\s+{renderer}\s*\(")
        self.assertIn("INTERPLAY_EXTERNAL_GROUP", app)
        self.assertIn("INTERPLAY_APP_GROUP", app)
        self.assertIn("interplay.pages", app)
        self.assertNotIn("INTERPLAY_FEATURE_NAMES", app)
        self.assertIn('["boundary", "#e0704f"', app)
        self.assertRegex(app, r"function\s+isInterplayBar\s*\(")
        # The legend lives in the empty inspector; the strip and the placeholder prose are gone.
        self.assertIn('id="interplay-legend-toggle"', index)
        self.assertIn('id="interplay-legend-items"', index)
        self.assertNotIn("Select a node", index)
        self.assertNotIn("Select a node", app)
        self.assertIn('"data-pipe"', app)
        self.assertIn("drawn as containment", app)

    # ---- Launch: what exists before any page -----------------------------------

    def test_launch_zone_admits_the_settings_provider_and_rezones_the_keychain(self) -> None:
        interplay = self.model["interplay"]
        pages = interplay["pages"]
        self.assertEqual("launch", pages[0]["id"], "the launch zone is drawn first")
        self.assertEqual({"PortalAppIOS", "PortalAppMac"}, set(pages[0]["roots"]))
        by_id = {node["id"]: node for node in interplay["nodes"]}
        provider = by_id["provider:operations-state:SettingsViewModel"]
        self.assertEqual("launch", provider["page"])
        self.assertEqual(["KeychainStore"], provider["loads"])
        self.assertTrue(any(entry["via"] == "GatewayClientWrapper" and entry["method"].startswith("connect") for entry in provider["configures"]))
        keychain = by_id["store:local-services:KeychainStore"]
        self.assertEqual("launch", keychain["page"])
        self.assertEqual("launch", keychain["page_resolution"])
        relations = {(e["source"], e["relation"], e["target"]) for e in interplay["edges"]}
        self.assertIn((provider["id"], "loads", keychain["id"]), relations)
        self.assertIn((provider["id"], "configures", "owner:hermes-services:GatewayClient"), relations)
        # An object already on the map keeps its page and still records what its init loads.
        self.assertIn(("subscriber:SpawnTreeStore", "loads", "store:domain-models:DelegationBatchHistoryStore"), relations)
        self.assertNotEqual("launch", by_id["subscriber:SpawnTreeStore"]["page"])
        # One launch trigger per (entry point, constructed object); both platforms are entry points.
        launch = [t for t in interplay["triggers"] if t["kind"] == "launch"]
        self.assertTrue(launch)
        self.assertTrue(all(t["page"] == "launch" and t["api"] == "StateObject" and t["method"] == "init" for t in launch))
        self.assertEqual({"PortalAppIOS", "PortalAppMac"}, {t["view"] for t in launch})
        self.assertIn("SettingsViewModel", {t["surface"] for t in launch})
        self.assertEqual(2, provider["triggers"]["launch"])
        # Objects constructed at launch that are not constructions on the map are stated, not hidden.
        self.assertIn("unmapped", interplay["launch"])
        self.assertEqual("holds", next(i["status"] for i in interplay["invariants"] if i["id"] == "launch-zoned"))
        # The extraction is bracket-aware: an App struct body yields exactly its @StateObject initialisers.
        code = (
            "struct DemoApp: App {\n    @StateObject private var settings = SettingsViewModel()\n"
            "    @StateObject var tts = TTSService.shared\n    @StateObject var noInit: Foo\n    var body: some Scene { WindowGroup { ContentView() } }\n}\n"
            "struct Other { @StateObject var x = Bar() }\n"
        )
        found = architecture.extract_launch_constructions([{"path": "App/Demo.swift", "_text": code}])
        self.assertEqual([("DemoApp", "settings", "SettingsViewModel", 2), ("DemoApp", "tts", "TTSService", 3)],
                         [(c["app"], c["property"], c["type"], c["line"]) for c in found])
        bodies = architecture.init_bodies("final class S { init() { let k = KeychainStore.shared } func f() { Other() } }\nextension S { convenience init(x: Int) { self.init(); OtherStore.shared } }", "S")
        self.assertEqual(2, len(bodies))
        self.assertIn("KeychainStore", bodies[0])
        self.assertIn("OtherStore", bodies[1])

    def test_launch_zone_is_rendered_by_the_site(self) -> None:
        app = (ROOT / "architecture/site/app.js").read_text(encoding="utf-8")
        for needle in ('if (node.kind === "provider") return "provider";', 'launch_zoned:', "PROVIDER · LAUNCH",
                       'rect.setAttribute("class", "provider")', '"Configures the transport"', "constructed at launch by"):
            self.assertIn(needle, app)
        self.assertIn(".interplay-node rect.provider", (ROOT / "architecture/site/styles.css").read_text(encoding="utf-8"))
        self.assertIn("App launch", (ROOT / "architecture/README.md").read_text(encoding="utf-8"))

    # ---- State machines ---------------------------------------------------------

    def test_state_machines_are_extracted_with_states_transitions_and_origins(self) -> None:
        interplay = self.model["interplay"]
        machines = {n["label"]: n for n in interplay["nodes"] if n["kind"] == "machine"}
        self.assertIn("GatewayClient.connectionState", machines)
        transport = machines["GatewayClient.connectionState"]["machine"]
        self.assertEqual(["disconnected", "connecting", "connected", "reconnecting", "error"], [c["name"] for c in transport["states"]])
        self.assertEqual("disconnected", transport["initial"])
        self.assertTrue(any(c["payload"] for c in transport["states"] if c["name"] == "reconnecting"))
        self.assertGreaterEqual(len(transport["transitions"]), 10)
        self.assertEqual([], transport["dead_states"])
        for t in transport["transitions"]:
            self.assertTrue((ROOT / t["path"]).is_file())
            self.assertEqual("swift.state.transition", t["rule_id"])
        # The owner drives its machine; the machine sits in the owner's zone.
        core = next(n for n in interplay["nodes"] if n["id"] == "owner:hermes-services:GatewayClient")
        self.assertIn(machines["GatewayClient.connectionState"]["id"], core["machines"])
        self.assertIn(("owner:hermes-services:GatewayClient", "drives", machines["GatewayClient.connectionState"]["id"]),
                      {(e["source"], e["relation"], e["target"]) for e in interplay["edges"]})
        self.assertEqual(core.get("page"), machines["GatewayClient.connectionState"].get("page"))
        # A derived state (a computed property switching on other fields) is not a machine.
        self.assertNotIn("ChatViewModel.conversationPhase", machines)
        self.assertEqual("holds", next(i["status"] for i in interplay["invariants"] if i["id"] == "machines-complete"))
        # Synthetic: from-states from switch / if case / guard case, ternary targets, no false machines.
        code = (
            "enum Mode { case idle, busy(Int), done }\n"
            "enum Flavour { case only }\n"
            "final class Worker {\n"
            "    @Published private(set) var mode: Mode = .idle\n"
            "    var flavour: Flavour = .only\n"
            "    var derived: Mode { mode }\n"
            "    func start() {\n"
            "        switch mode {\n"
            "        case .idle, .done:\n"
            "            mode = .busy(1)\n"
            "        case .busy:\n"
            "            return\n"
            "        }\n"
            "    }\n"
            "    func finish(ok: Bool) {\n"
            "        if case .busy = mode { mode = ok ? .done : .idle }\n"
            "    }\n"
            "    func reset() {\n"
            "        guard case .done = mode else { return }\n"
            "        mode = .idle\n"
            "    }\n"
            "}\n"
        )
        files = [{"path": "Sources/Portal/Demo/Worker.swift", "_text": code, "declarations": ["Mode", "Flavour", "Worker"], "component": "demo", "identifiers": [], "line_count": code.count("\n")}]
        fake = {"nodes": [{"id": "caller:demo:Worker", "kind": "caller", "label": "Worker", "component": "demo", "page": "chat"}], "edges": []}
        found = architecture.extract_state_machines(fake, files)
        self.assertEqual(["Worker.mode"], [m["label"] for m in found])
        machine = found[0]["machine"]
        self.assertEqual("idle", machine["initial"])
        self.assertEqual([("idle", "busy"), ("done", "busy"), ("busy", "done"), ("busy", "idle"), ("done", "idle")],
                         [(f, t["to"]) for t in machine["transitions"] for f in (t["from"] or [None])])
        self.assertEqual(["start", "finish", "finish", "reset"], [t["function"] for t in machine["transitions"]])
        self.assertEqual([], machine["dead_states"])
        self.assertEqual(0, machine["unknown_from"])
        app = (ROOT / "architecture/site/app.js").read_text(encoding="utf-8")
        for needle in ('if (node.kind === "machine") return "machine";', "function machineMermaid(", "stateDiagram-v2", 'rect.setAttribute("class", "machine")', "machines_complete:"):
            self.assertIn(needle, app)

    # ---- Semantic enrichment: described constructs and system flows ------------

    def _files(self):
        config = architecture.load_json(architecture.CONFIG_PATH)
        files, _digest = architecture.read_sources(config)
        launch, _launch_digest = architecture.read_launch_sources(config)
        return files + launch

    def test_construct_records_are_validated_against_the_map(self) -> None:
        interplay = self.model["interplay"]
        files = self._files()
        externals = self.model["externals"]
        keychain = next(n for n in interplay["nodes"] if n["label"] == "KeychainStore")
        good = {
            "key": keychain["history_key"], "kind": "store", "summary": "Wraps the Keychain.",
            "fields": {"medium": "keychain", "sensitive": True, "readers": ["provider:operations-state:SettingsViewModel"], "record_type": ["SavedGateway"], "written_when": ["on_change"]},
            "evidence": [{"path": keychain["path"], "line": 10}], "open_questions": [],
        }
        record = architecture.validate_construct_record(good, interplay, files, externals)
        self.assertEqual("store", record["kind"])
        self.assertFalse(record["stale"])
        self.assertEqual(["SavedGateway"], record["fields"]["record_type"])
        # A recorded hash that no longer matches the cited files marks the record stale.
        stale = architecture.validate_construct_record({**good, "cited_hash": "0" * 64}, interplay, files, externals)
        self.assertTrue(stale["stale"])
        bad_cases = [
            ({**good, "kind": "external"}, "kind"),
            ({**good, "key": "store:nowhere:Ghost"}, "not a construct"),
            ({**good, "fields": {"medium": "user_defaults"}}, "medium"),
            ({**good, "fields": {"sensitive": False}}, "sensitive"),
            ({**good, "fields": {"readers": ["hub:ChatViewModel"]}}, "edge"),
            ({**good, "fields": {"record_type": ["NoSuchType"]}}, "declared"),
            ({**good, "fields": {"retention": "eternal"}}, "must be one of"),
            ({**good, "fields": {"colour": "blue"}}, "schema does not define"),
            ({**good, "evidence": [{"path": "Sources/Portal/Views/ChatView.swift", "line": 1}]}, "bounded"),
            ({**good, "evidence": [{"path": keychain["path"], "line": 100000}]}, "not a line"),
            ({**good, "summary": "x" * 401}, "exceeds"),
        ]
        for raw, needle in bad_cases:
            with self.assertRaises(architecture.ArchitectureError, msg=needle) as caught:
                architecture.validate_construct_record(raw, interplay, files, externals)
            self.assertIn(needle, str(caught.exception))
        # Pages are constructs too; members must belong to the page.
        page = architecture.validate_construct_record(
            {"key": "page:launch", "kind": "page", "summary": "Launch.", "fields": {"owns_state_in": [keychain["history_key"]]},
             "evidence": [{"path": keychain["path"], "line": 1}]}, interplay, files, externals)
        self.assertEqual("page", page["kind"])
        with self.assertRaises(architecture.ArchitectureError):
            architecture.validate_construct_record(
                {"key": "page:chat", "kind": "page", "summary": "Chat.", "fields": {"owns_state_in": [keychain["history_key"]]},
                 "evidence": [{"path": keychain["path"], "line": 1}]}, interplay, files, externals)

    def test_flows_are_paths_over_edges_the_map_draws(self) -> None:
        interplay = self.model["interplay"]
        files = self._files()
        core = "owner:hermes-services:GatewayClient"
        bus = "resource:backend-contract:AgentBackend:event_bus:eventStream"
        good = {
            "id": "prompt-to-stream", "title": "Prompt to streamed reply", "summary": "A prompt rides the transport and returns on the stream.",
            "journey": "chat_turn", "interaction": "Send button",
            "steps": [
                {"from": "caller:chat-state:ChatViewModel", "to": core, "relation": "holds"},
                {"from": "caller:chat-state:ChatViewModel", "to": "endpoint:jsonrpc:prompt", "relation": "invokes"},
                {"from": core, "to": "endpoint:jsonrpc:prompt", "relation": "dispatches", "note": "correlated through the pool"},
                {"from": core, "to": bus, "relation": "provides"},
                {"from": bus, "to": "hub:ChatViewModel", "relation": "notifies"},
            ],
            "evidence": [{"path": "Sources/Portal/ViewModels/ChatViewModel.swift", "line": 1}],
        }
        flow = architecture.validate_flow(good, interplay, files)
        self.assertEqual("traceable", flow["status"])
        self.assertEqual([], flow["problems"])
        # A step over an edge the map does not draw is a recorded problem, not a schema error.
        broken = architecture.validate_flow({**good, "steps": good["steps"] + [{"from": "hub:ChatViewModel", "to": core, "relation": "teleports"}]}, interplay, files)
        self.assertEqual("broken", broken["status"])
        self.assertIn("teleports", broken["problems"][0])
        # Schema errors: disconnected steps, unknown nodes, bad ids, too few steps, evidence outside the path.
        for raw, needle in [
            ({**good, "journey": "sideways"}, "journey"),
            ({**good, "journey": "page", "page": "chat"}, "navigation page"),
            ({**good, "steps": [good["steps"][0], {"from": "hub:ChatViewModel", "to": core, "relation": "holds"}, good["steps"][2]]}, "no earlier step reached"),
            ({**good, "steps": [{"from": "caller:x:Y", "to": core, "relation": "holds"}] + good["steps"][1:]}, "not on the map"),
            ({**good, "id": "Bad Id"}, "kebab-case"),
            ({**good, "steps": good["steps"][:2]}, "between"),
            ({**good, "evidence": [{"path": "Sources/Portal/Services/KeychainStore.swift", "line": 1}]}, "bounded"),
        ]:
            with self.assertRaises(architecture.ArchitectureError, msg=needle) as caught:
                architecture.validate_flow(raw, interplay, files)
            self.assertIn(needle, str(caught.exception))
        # A trigger must fire the surface the flow starts from.
        trigger = next(t for t in interplay["triggers"] if t["surface"] == "ChatViewModel")
        with_trigger = architecture.validate_flow({**good, "trigger": trigger["id"]}, interplay, files)
        self.assertEqual(trigger["id"], with_trigger["trigger"])
        other = next(t for t in interplay["triggers"] if t["surface"] != "ChatViewModel" and t["kind"] != "launch")
        with self.assertRaises(architecture.ArchitectureError):
            architecture.validate_flow({**good, "trigger": other["id"]}, interplay, files)
        # Whatever is declared in the repository must trace today.
        for declared in interplay.get("flows", []):
            self.assertEqual("traceable", declared["status"], declared)
        self.assertEqual("holds", next(i["status"] for i in interplay["invariants"] if i["id"] == "flows-traceable"))

    def test_described_constructs_fold_onto_nodes_and_the_site_renders_them(self) -> None:
        interplay = self.model["interplay"]
        described = [n for n in interplay["nodes"] if n.get("semantic")]
        self.assertEqual(interplay["constructs"]["described"], len(described) + sum(1 for p in interplay["pages"] if p.get("semantic")))
        for node in described:
            self.assertEqual(architecture.construct_kind(node), node["semantic"]["kind"])
            self.assertTrue(node["semantic"]["evidence"])
        app = (ROOT / "architecture/site/app.js").read_text(encoding="utf-8")
        index = (ROOT / "architecture/site/index.html").read_text(encoding="utf-8")
        for needle in ("function describedSection(", "function renderFlows(", "function traceFlow(", "function renderFlowInspector(", "flowSteps.get(edge.dataset.hkey)", "let selectedFlowId = null",
                       "function flowMermaid(", "sequenceDiagram", 'JOURNEY_TITLES = { launch:', "mermaid-ready", 'element("ol", "flow-procedure")'):
            self.assertIn(needle, app)
        self.assertIn('id="flows-list"', index)
        self.assertIn("mermaid.esm.min.mjs", index)
        # Flows are user journeys: launch, a chat turn, then each page, in that order.
        journeys = [flow["journey"] for flow in interplay.get("flows", [])]
        order = {"launch": 0, "chat_turn": 1, "page": 2}
        self.assertEqual(journeys, sorted(journeys, key=order.__getitem__))
        for flow in interplay.get("flows", []):
            self.assertIn(flow["journey"], order)
            self.assertTrue(flow["page"])
        self.assertIn(".described-table", (ROOT / "architecture/site/styles.css").read_text(encoding="utf-8"))

    # ---- History: the same map at every commit ---------------------------------

    def test_history_keys_are_stable_and_unique_for_drawn_nodes(self) -> None:
        nodes = self.model["interplay"]["nodes"]
        drawn = [node for node in nodes if node["kind"] != "operation"]
        keys = [node["history_key"] for node in drawn]
        self.assertTrue(all(keys))
        self.assertEqual(len(keys), len(set(keys)), "history keys must be unique among drawn nodes")
        for node in drawn:
            if node["kind"] == "resource":
                # Re-keyed by what it is, never by the line-hashed id.
                self.assertNotIn(node["id"].split(":", 1)[1], node["history_key"])
                self.assertEqual(
                    node["history_key"],
                    f"resource:{node['component'] or 'unassigned'}:{node['owner_type'] or ''}:{node['sub_kind'] or ''}:{node['label']}",
                )
            elif node["kind"] == "endpoint":
                # A namespace survives its transport being renamed.
                self.assertEqual(node["history_key"], f"endpoint:{node['protocol']}:{node['label']}")
            elif node["kind"] == "endpoint":
                # A namespace survives its transport being renamed.
                self.assertEqual(node["history_key"], f"endpoint:{node['protocol']}:{node['label']}")
            else:
                self.assertEqual(node["history_key"], node["id"])
        with self.assertRaises(architecture.ArchitectureError):
            architecture.assign_history_keys({"nodes": [
                {"id": "resource:a", "kind": "resource", "component": "c", "owner_type": "O", "sub_kind": "lock", "label": "x"},
                {"id": "resource:b", "kind": "resource", "component": "c", "owner_type": "O", "sub_kind": "lock", "label": "x"},
            ]})

    def test_shape_of_carries_drawn_nodes_edges_and_aggregated_triggers(self) -> None:
        shape = architecture.shape_of(self.model)
        self.assertEqual(shape["tree"], self.model["source_tree_sha256"])
        keys = {meta["k"] for meta in shape["nodes"]}
        kinds = {meta["kind"] for meta in shape["nodes"]}
        self.assertNotIn("operation", kinds)
        self.assertIn("page", kinds)
        for source, target, relation, klass in shape["edges"]:
            self.assertIn(source, keys)
            self.assertIn(target, keys)
            self.assertTrue(relation and klass)
        triggers = [edge for edge in shape["edges"] if edge[2] == "triggers"]
        self.assertTrue(triggers)
        self.assertTrue(all(edge[0].startswith("page:") and edge[3] == "trigger" for edge in triggers))
        # Every drawn interplay edge between drawn nodes survives, re-keyed.
        key_of = {node["id"]: node["history_key"] for node in self.model["interplay"]["nodes"]}
        expected = {
            (key_of[e["source"]], key_of[e["target"]], e["relation"], e["class"])
            for e in self.model["interplay"]["edges"] if key_of[e["source"]] in keys and key_of[e["target"]] in keys
        }
        self.assertEqual(expected, {tuple(edge) for edge in shape["edges"] if edge[2] != "triggers"})
        # At the head, strict and lenient agree: nothing for fidelity to record.
        self.assertEqual({}, shape["fidelity"])
        self.assertEqual([], shape["invariants"]["violated"])

    def test_snapshot_mode_records_gaps_instead_of_failing(self) -> None:
        previous = architecture.LENIENT
        architecture.FIDELITY.clear()
        try:
            architecture.LENIENT = False
            with self.assertRaises(architecture.ArchitectureError):
                architecture.gate("externals_unmatched", "system x matched nothing")
            architecture.LENIENT = True
            architecture.gate("externals_unmatched", "system x matched nothing")
            architecture.gate("externals_unmatched", "system y matched nothing")
            architecture.gate("invariants_violated", "single-transport: two transports")
            self.assertEqual({"externals_unmatched": 2, "invariants_violated": 1},
                             {kind: len(items) for kind, items in architecture.FIDELITY.items()})
        finally:
            architecture.LENIENT = previous
            architecture.FIDELITY.clear()
        # The compiler's `--snapshot` at the head prints the same shape the model yields.
        run = subprocess.run([sys.executable, str(MODULE_PATH), "--snapshot"], capture_output=True, text=True, check=False, cwd=ROOT)
        self.assertEqual(0, run.returncode, run.stderr)
        printed = json.loads(run.stdout)
        self.assertEqual(architecture.shape_of(self.model), printed)

    def test_history_timeline_delta_encoding_round_trips(self) -> None:
        commits = [history.Commit(f"{index:040x}", f"2026-05-0{index + 1}", f"commit {index}") for index in range(3)]
        node = lambda key, **meta: {"k": key, "kind": "caller", "label": key.split(":")[-1], **meta}  # noqa: E731
        shapes = [
            {"tree": "t0", "nodes": [node("caller:a:A"), node("hub:H")], "edges": [["caller:a:A", "hub:H", "holds", "interplay"]],
             "fidelity": {"externals_unmatched": 2}, "invariants": {"holds": 1, "violated": ["x"]}},
            # A adds a page; B appears; the edge is unchanged.
            {"tree": "t1", "nodes": [node("caller:a:A", page="chat"), node("hub:H"), node("caller:b:B")],
             "edges": [["caller:a:A", "hub:H", "holds", "interplay"], ["caller:b:B", "hub:H", "holds", "interplay"]],
             "fidelity": {}, "invariants": {"holds": 2, "violated": []}},
            # A is deleted along with its edge.
            {"tree": "t2", "nodes": [node("hub:H"), node("caller:b:B")], "edges": [["caller:b:B", "hub:H", "holds", "interplay"]],
             "fidelity": {}, "invariants": {"holds": 2, "violated": []}},
        ]
        failed = [{"rev": "f" * 40, "date": "2026-05-02", "reason": "boom"}]
        timeline = history.encode_timeline("main", commits[-1].rev, "fp", list(zip(commits, shapes)), failed)
        self.assertEqual(3, len(timeline["snapshots"]))
        self.assertEqual({"nodes": 2, "edges": 1}, timeline["snapshots"][0]["counts"])
        self.assertEqual([2], timeline["snapshots"][1]["na"])       # B
        self.assertEqual([0], timeline["snapshots"][2]["nd"])       # A
        self.assertEqual([0], timeline["snapshots"][2]["ed"])       # A → H
        self.assertNotIn("ea", timeline["snapshots"][2])
        # The union describes a node as the newest snapshot saw it: A carries its page.
        self.assertEqual("chat", timeline["nodes"][0]["page"])
        self.assertEqual(failed, timeline["failed"])
        replayed = history.replay(timeline)
        self.assertEqual([commit.rev for commit in commits], [commit.rev for commit, _shape in replayed])
        for (_commit, original), (_again, restored) in zip(zip(commits, shapes), replayed):
            self.assertEqual({meta["k"] for meta in original["nodes"]}, {meta["k"] for meta in restored["nodes"]})
            self.assertEqual(sorted(original["edges"]), restored["edges"])
            self.assertEqual(original["tree"], restored["tree"])
            self.assertEqual(original["fidelity"], restored["fidelity"])
        # The artifact format the site reads is one assignment the walker can read back.
        text = history.serialize(timeline)
        self.assertTrue(text.startswith("window.PORTAL_ARCHITECTURE_HISTORY={"))
        self.assertTrue(text.endswith("};\n"))
        self.assertEqual(3, len(history.sample(commits, 1, 0)))
        self.assertEqual([commits[0].rev, commits[2].rev], [c.rev for c in history.sample(commits, 2, 0)])
        self.assertEqual([commits[2].rev], [c.rev for c in history.sample(commits, 1, 1)])

    def test_history_walk_derives_the_head_commit_exactly(self) -> None:
        # One real snapshot through the walker (git archive → scratch tree → --snapshot)
        # of the newest commit that touched the sources must reproduce the head shape
        # whenever the working tree's sources equal that commit's.
        commits = history.list_commits("HEAD")
        self.assertTrue(commits)
        with __import__("tempfile").TemporaryDirectory() as scratch:
            history.prepare_skeleton(Path(scratch))
            shape = history.snapshot(commits[-1], Path(scratch))
        dirty = subprocess.run(["git", "status", "--porcelain", "--", "Sources/Portal"], capture_output=True, text=True, cwd=ROOT).stdout.strip()
        if not dirty and subprocess.run(["git", "diff", "--quiet", commits[-1].rev, "HEAD", "--", "Sources/Portal"], cwd=ROOT).returncode == 0:
            self.assertEqual(architecture.shape_of(self.model), shape)
        else:
            self.assertTrue(shape["nodes"])

    def test_system_map_has_the_history_slider(self) -> None:
        index = (ROOT / "architecture/site/index.html").read_text(encoding="utf-8")
        app = (ROOT / "architecture/site/app.js").read_text(encoding="utf-8")
        styles = (ROOT / "architecture/site/styles.css").read_text(encoding="utf-8")
        self.assertIn('<script src="history.js"></script>', index)
        self.assertLess(index.index('src="history.js"'), index.index('src="app.js"'))
        for element_id in ("timeline", "timeline-range", "timeline-play", "timeline-now", "timeline-diff", "timeline-note", "timeline-spark"):
            self.assertIn(f'id="{element_id}"', index)
        self.assertIn("window.PORTAL_ARCHITECTURE_HISTORY", app)
        for renderer in ("renderTimeline", "timelineSync", "timelineDiff", "timelineNote", "wireTimeline", "timelineNodeState", "timelineEdgeState"):
            self.assertRegex(app, rf"function\s+{renderer}\s*\(")
        # Inert until touched; the union layout; keys on every drawn edge and trunk.
        self.assertIn("if (TL) TL.go(TL.last);", app)
        self.assertIn("const drawNodes = interplay.nodes.slice();", app)
        self.assertIn('"data-hkey": hkey', app)
        self.assertIn("hist: true", app)
        for rule in (".interplay-node.absent", ".interplay-edge.ghost", ".timeline-overlay"):
            self.assertIn(rule, styles)
        # The artifact is derived, never committed.
        self.assertIn("architecture/site/history.js", (ROOT / ".gitignore").read_text(encoding="utf-8"))
        self.assertIn("architecture-history:", (ROOT / "Makefile").read_text(encoding="utf-8"))
        workflow = (ROOT / ".github/workflows/architecture-pages.yml").read_text(encoding="utf-8")
        self.assertIn("build_architecture_history.py", workflow)
        self.assertIn("fetch-depth: 0", workflow)


    # ---- CI gates: the pipeline as a circuit ---------------------------------

    def test_yaml_subset_parser_matches_reference_semantics(self) -> None:
        text = (
            "name: Demo\n"
            "on:\n"
            "  push:\n"
            "    branches: [main]\n"
            "  workflow_dispatch:\n"
            "jobs:\n"
            "  one:\n"
            "    name: \"First: job\"  # trailing comment\n"
            "    runs-on: ubuntu-latest\n"
            "    env:\n"
            "      TOOL_VERSION: 1.2.3\n"
            "    steps:\n"
            "      - uses: actions/checkout@v4\n"
            "        with:\n"
            "          fetch-depth: 0\n"
            "      - name: Run\n"
            "        run: |\n"
            "          set -o pipefail\n"
            "          # a comment inside the block\n"
            "\n"
            "          python3 scripts/demo.py --check\n"
            "      - name: Folded\n"
            "        run: >-\n"
            "          one\n"
            "          two\n"
            "  two:\n"
            "    needs: one\n"
            "    if: github.event_name != 'pull_request'\n"
            "    steps: []\n"
        )
        document = architecture.parse_yaml_subset(text)
        self.assertEqual("Demo", document["name"])
        self.assertEqual({"push": {"branches": ["main"]}, "workflow_dispatch": None}, {k: (dict(v) if isinstance(v, dict) else v) for k, v in document["on"].items()})
        job = document["jobs"]["one"]
        self.assertEqual("First: job", job["name"])
        self.assertEqual("1.2.3", job["env"]["TOOL_VERSION"], "scalars stay strings")
        self.assertEqual("0", job["steps"][0]["with"]["fetch-depth"])
        self.assertEqual("set -o pipefail\n# a comment inside the block\n\npython3 scripts/demo.py --check\n", job["steps"][1]["run"])
        self.assertEqual("one two", job["steps"][2]["run"])
        self.assertEqual("one", document["jobs"]["two"]["needs"])
        self.assertEqual([], document["jobs"]["two"]["steps"])
        # Line provenance: the job keys remember where they were declared.
        self.assertEqual(7, document["jobs"].lines["one"])
        self.assertEqual(26, document["jobs"].lines["two"])
        self.assertEqual("python3 scripts/demo.py --check", architecture._first_command_line(job["steps"][1]["run"]))
        with self.assertRaises(architecture.YamlSubsetError):
            architecture.parse_yaml_subset("a:\n\tb: 1\n")

    def test_yaml_subset_parser_agrees_with_pyyaml_on_the_real_files(self) -> None:
        try:
            import yaml  # type: ignore
        except ImportError:  # pragma: no cover - PyYAML is optional locally
            self.skipTest("PyYAML not installed")

        def normalize(value):
            if isinstance(value, dict):
                return {("on" if key is True else str(key)): normalize(item) for key, item in value.items()}
            if isinstance(value, list):
                return [normalize(item) for item in value]
            if value is None:
                return None
            if isinstance(value, bool):
                return "true" if value else "false"
            return str(value)

        for path in sorted((ROOT / ".github/workflows").glob("*.yml")) + [ROOT / ".swiftlint.yml"]:
            text = path.read_text(encoding="utf-8")
            mine = normalize(json.loads(json.dumps(architecture.parse_yaml_subset(text))))
            self.assertEqual(normalize(yaml.safe_load(text)), mine, f"{path.name} parses differently")

    def test_ci_plane_reads_every_workflow_and_wires_the_pipeline(self) -> None:
        ci = self.model["ci"]
        files = sorted(path.stem for path in (ROOT / ".github/workflows").glob("*.yml"))
        self.assertEqual(files, sorted(workflow["id"] for workflow in ci["workflows"]))
        jobs = {job["id"]: job for job in ci["jobs"]}
        self.assertEqual(ci["summary"]["jobs"], len(jobs))
        # Every workflow carries its declared family; every job its provenance line.
        for workflow in ci["workflows"]:
            self.assertIn(workflow["family"], architecture.CI_FAMILIES)
            self.assertTrue(workflow["label"] and workflow["question"])
        for job in jobs.values():
            self.assertTrue(job["evidence"]["path"].startswith(".github/workflows/"))
            self.assertGreater(job["evidence"]["line"], 1)
            self.assertIn(job["role"], {"gate", "post-merge", "manual", "disabled"})
            for dependency in job["needs"]:
                self.assertIn(dependency, jobs)
        # The shared measurement feeds both posture jobs by `needs` and by artifact.
        relations = {(edge["kind"], edge["source"], edge["target"]) for edge in ci["edges"]}
        self.assertIn(("needs", "ratchet/measure", "ratchet/warnings"), relations)
        self.assertIn(("artifact", "ratchet/measure", "ratchet/coverage"), relations)
        self.assertEqual("metric-snapshots", next(e["label"] for e in ci["edges"] if e["kind"] == "artifact" and e["target"] == "ratchet/coverage"))
        # Every gate feeds the merge; the deploy is after it, still needing validate.
        gates = {job["id"] for job in jobs.values() if job["role"] == "gate"}
        self.assertEqual(gates, set(ci["merge"]["inputs"]))
        self.assertTrue(all(("gates", gate, "merge:main") in relations for gate in gates))
        self.assertEqual("post-merge", jobs["architecture-pages/deploy"]["role"])
        self.assertIn(("release", "merge:main", "architecture-pages/deploy"), relations)
        self.assertIn(("needs", "architecture-pages/validate", "architecture-pages/deploy"), relations)
        self.assertEqual("manual", jobs["snapshot-record/record"]["role"])
        self.assertIn(("trigger", "trigger:workflow_dispatch", "snapshot-record/record"), relations)
        self.assertEqual("disabled", jobs["testflight/notarize-macos"]["role"])
        # Root gates are fired by the pull request; nothing with `needs` is.
        for job in jobs.values():
            fired = ("trigger", "trigger:pull_request", job["id"]) in relations
            self.assertEqual(fired, job["role"] == "gate" and not job["needs"], job["id"])
        # Pins are versions interpolated into a download URL, not every *_VERSION.
        self.assertEqual([{"name": "SWIFTLINT_VERSION", "value": "0.65.0"}], jobs["tests/swift-lint"]["pins"])
        self.assertEqual([], jobs["testflight/testflight"]["pins"], "APP_VERSION is not a tool pin")
        self.assertIn("scripts/check-metrics-ratchet.py", jobs["ratchet/warnings"]["scripts"])
        self.assertTrue(all(step["command"] and not step["command"].startswith("set ") for job in jobs.values() for step in job["steps"] if "command" in step))
        self.assertEqual(ci["limitations"], architecture.CI_LIMITATIONS)

    def test_ci_ratchets_read_their_baselines_and_cover_every_posture_job(self) -> None:
        ci = self.model["ci"]
        jobs = {job["id"]: job for job in ci["jobs"]}
        metrics = json.loads((ROOT / "metrics-baseline.json").read_text(encoding="utf-8"))
        perf = json.loads((ROOT / "perf-baseline.json").read_text(encoding="utf-8"))
        lint = json.loads((ROOT / ".swiftlint-baseline").read_text(encoding="utf-8"))
        by_id = {ratchet["id"]: ratchet for ratchet in ci["ratchets"]}
        self.assertEqual(metrics["coverage"]["testable_pct"], by_id["coverage"]["current"]["percent"])
        self.assertEqual(metrics["warnings"]["total"], by_id["warnings"]["current"]["total"])
        self.assertEqual(metrics["deadcode"]["counts"], by_id["deadcode"]["current"]["counts"])
        self.assertEqual(perf["counts"], by_id["perf"]["current"]["counts"])
        self.assertEqual(len(lint), by_id["lint"]["current"]["total"])
        self.assertIsNone(by_id["perf"]["patch"], "op counts are floor-only")
        # The constraint ratchet guards the declarations themselves; its "current" is what it counts.
        constraints = by_id["constraints"]
        self.assertEqual("ratchet/constraints", constraints["job"])
        self.assertEqual("count", constraints["current"]["kind"])
        counts = constraints["current"]["counts"]
        self.assertEqual(len(json.loads((ROOT / "architecture/interplay/invariants.json").read_text(encoding="utf-8"))["invariants"]), counts["invariants"])
        self.assertEqual((ROOT / "Tests/PortalTests/ArchitectureTests.swift").read_text(encoding="utf-8").count("@Test("), counts["architecture_tests"])
        self.assertGreater(counts["lint_rules"], 10)
        self.assertEqual(len(list((ROOT / "architecture/specifications").glob("*.md"))), counts["specifications"])
        self.assertIsNone(constraints["patch"])
        self.assertTrue(by_id["coverage"]["patch"])
        for ratchet in ci["ratchets"]:
            self.assertIn(ratchet["job"], jobs)
            self.assertEqual("posture", jobs[ratchet["job"]]["family"])
            self.assertTrue(ratchet["source_path"] and (ROOT / ratchet["source_path"]).is_file())
        # One concern per job: every posture job is a declared ratchet or a shared measurement.
        declared = {ratchet["job"] for ratchet in ci["ratchets"]}
        needed = {dependency for job in jobs.values() for dependency in job["needs"]}
        for job in jobs.values():
            if job["family"] == "posture":
                self.assertTrue(job["id"] in declared or job["id"] in needed, job["id"])
        # ...and the compiler refuses an undeclared one.
        config = json.loads((ROOT / "architecture/config.json").read_text(encoding="utf-8"))
        config["ci"]["ratchets"] = [r for r in config["ci"]["ratchets"] if r["id"] != "warnings"]
        with self.assertRaisesRegex(architecture.ArchitectureError, "ratchet/warnings is a posture job that no ratchet declares"):
            architecture.build_ci_model(config, self.model["interplay"])
        config = json.loads((ROOT / "architecture/config.json").read_text(encoding="utf-8"))
        config["ci"]["ratchets"][0]["job"] = "ratchet/nope"
        with self.assertRaisesRegex(architecture.ArchitectureError, "names job ratchet/nope"):
            architecture.build_ci_model(config, self.model["interplay"])
        config = json.loads((ROOT / "architecture/config.json").read_text(encoding="utf-8"))
        config["ci"]["workflows"]["extra"] = {"family": "build", "label": "Extra"}
        with self.assertRaisesRegex(architecture.ArchitectureError, "extra"):
            architecture.build_ci_model(config, self.model["interplay"])
        config = json.loads((ROOT / "architecture/config.json").read_text(encoding="utf-8"))
        del config["ci"]["workflows"]["build"]
        with self.assertRaisesRegex(architecture.ArchitectureError, "build.yml has no entry"):
            architecture.build_ci_model(config, self.model["interplay"])

    def test_ci_architectural_and_static_checks_are_extracted_with_provenance(self) -> None:
        ci = self.model["ci"]
        architectural = ci["architectural"]
        lint_text = (ROOT / ".swiftlint.yml").read_text(encoding="utf-8")
        rule_ids = {rule["id"] for rule in architectural["lint_rules"]}
        for expected in ("no_direct_client_in_views", "no_new_singletons", "no_swiftui_in_services", "no_ordering_comparison_on_generation"):
            self.assertIn(expected, rule_ids)
        for rule in architectural["lint_rules"]:
            self.assertEqual(".swiftlint.yml", rule["evidence"]["path"])
            self.assertIn(f"  {rule['id']}:", lint_text.splitlines()[rule["evidence"]["line"] - 1])
            self.assertIn(rule["severity"], {"warning", "error"})
        swallowed = next(rule for rule in architectural["lint_rules"] if rule["id"] == "no_swallowed_try")
        self.assertGreater(swallowed["baselined"], 0)
        self.assertNotIn("\n", swallowed["message"], "folded messages are one line")
        tests_text = (ROOT / "Tests/PortalTests/ArchitectureTests.swift").read_text(encoding="utf-8")
        self.assertEqual(tests_text.count("@Test("), len(architectural["tests"]))
        for test in architectural["tests"]:
            self.assertIn("@Test(", tests_text.splitlines()[test["evidence"]["line"] - 1])
        self.assertEqual([i["id"] for i in self.model["interplay"]["invariants"]], [i["id"] for i in architectural["invariants"]])
        self.assertTrue(all(job in {j["id"] for j in ci["jobs"]} for job in architectural["runs_in"]))
        # Static checks: the validate job's script and --check steps, and nothing else.
        names = [check["name"] for check in ci["static_checks"]]
        self.assertIn("Verify generated architecture is current", names)
        self.assertIn("Test architecture compiler", names)
        self.assertIn("Check browser JavaScript", names)
        self.assertNotIn("Assemble Pages tree", names)
        self.assertNotIn("Upload validated site", names)
        for check in ci["static_checks"]:
            self.assertEqual("architecture-pages/validate", check["job"])
            self.assertTrue(check["scripts"] or "--check" in check["command"])
            self.assertEqual(".github/workflows/architecture-pages.yml", check["evidence"]["path"])

    def test_ci_gates_view_is_rendered_by_the_site(self) -> None:
        index = (ROOT / "architecture/site/index.html").read_text(encoding="utf-8")
        app = (ROOT / "architecture/site/app.js").read_text(encoding="utf-8")
        styles = (ROOT / "architecture/site/styles.css").read_text(encoding="utf-8")
        self.assertRegex(index, r'<button[^>]+data-view="gates"')
        self.assertRegex(index, r'<section[^>]+id="gates-view"')
        for element_id in ("gates-graph", "gates-inspector", "gates-content", "gates-stats", "gates-legend", "gates-search", "reset-gates"):
            self.assertIn(f'id="{element_id}"', index)
        for renderer in ("layoutGates", "renderGates", "gateNodeElement", "renderGateInspector", "renderGateSections", "applyGateState", "renderGateLegend"):
            self.assertRegex(app, rf"function\s+{renderer}\s*\(")
        self.assertIn("model.ci", app)
        self.assertIn('"merge:main"', app)
        self.assertIn("Ratchets", app)
        self.assertIn("Architectural checks", app)
        self.assertIn("Static compiler checks", app)
        self.assertIn("renderGates();", app)
        for rule in (".gate-node", ".gate-wire", ".gate-lane-rect", ".gates-table", ".gate-command"):
            self.assertIn(rule, styles)
        # The standalone metrics page is gone; the product site points at the tab.
        self.assertFalse((ROOT / "site/metrics.html").exists())
        self.assertFalse((ROOT / "scripts/build_metrics_page.py").exists())
        # The product site says Overview and Features; the gates are reached only
        # through the observatory.
        product = (ROOT / "site/index.html").read_text(encoding="utf-8")
        self.assertNotIn("metrics.html", product)
        self.assertNotIn("#gates", product)
        self.assertIn('href="architecture/"', product)
        workflow = (ROOT / ".github/workflows/architecture-pages.yml").read_text(encoding="utf-8")
        self.assertNotIn("build_metrics_page", workflow)
        for trigger_path in (".github/workflows/**", ".swiftlint.yml", "Tests/PortalTests/ArchitectureTests.swift", "metrics-baseline.json"):
            self.assertIn(trigger_path, workflow)
        self.assertNotIn("build_metrics_page", (ROOT / "Makefile").read_text(encoding="utf-8"))

    def test_observatory_renderer_is_embedded_for_the_app(self) -> None:
        outputs = architecture.expected_outputs()
        swift = outputs[architecture.OBSERVATORY_ASSETS_PATH]
        self.assertTrue(swift.startswith("// GENERATED"))
        self.assertIn("Sources/Portal/Models/ArchitectureObservatoryAssets.swift", (ROOT / ".swiftlint.yml").read_text(encoding="utf-8"), "the generated asset is excluded from lint")
        for name in ("indexHTML", "appJS", "stylesCSS"):
            self.assertIn(f"internal static let {name} = ", swift)
        for filename in ("index.html", "app.js", "styles.css"):
            content = (ROOT / "architecture/site" / filename).read_text(encoding="utf-8").rstrip("\n")
            self.assertIn(content, swift, f"{filename} is embedded verbatim")
        # The committed copy is current, and the page builder knows the tags it splices at.
        self.assertEqual(swift, architecture.OBSERVATORY_ASSETS_PATH.read_text(encoding="utf-8"))
        page = (ROOT / "Sources/Portal/Models/ArchitecturePanelPage.swift").read_text(encoding="utf-8")
        index = (ROOT / "architecture/site/index.html").read_text(encoding="utf-8")
        for tag in ('<link rel=\\"stylesheet\\" href=\\"styles.css\\">', '<script src=\\"data.js\\"></script>',
                    '<script src=\\"history.js\\"></script>', '<script src=\\"app.js\\"></script>'):
            self.assertIn(tag, page)
            self.assertIn(tag.replace("\\", ""), index, "the site still uses the tag the builder splices at")
        # Raw literals: the delimiter never collides with the content.
        self.assertEqual('#"""\nabc\n"""#', architecture.swift_raw_literal("abc"))
        self.assertTrue(architecture.swift_raw_literal('x """# y').startswith('##"""'))
        self.assertTrue(architecture.swift_raw_literal("\\#(x)").startswith('##"""'))


if __name__ == "__main__":
    unittest.main()
