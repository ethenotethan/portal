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
        self.assertEqual({"SEMANTIC_PATH"}, write_receivers)
        semantic_assignment = re.search(r'^SEMANTIC_PATH\s*=\s*(.+)$', agent, re.MULTILINE)
        self.assertIsNotNone(semantic_assignment)
        assert semantic_assignment is not None
        self.assertIn('"architecture/semantic/components.json"', semantic_assignment.group(1))
        self.assertNotIn("model.behavior", agent)

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
        # Invariants are selectable from a dropdown that opens a plain description
        # panel; the selection never touches the graph.
        self.assertIn('id="invariant-select"', index)
        self.assertIn('id="invariant-detail"', index)
        for renderer in ("renderInvariantSelect", "renderInvariantDetail"):
            self.assertRegex(app, rf"function\s+{renderer}\s*\(")
        self.assertNotIn("invariantFocus", app)
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
        self.assertEqual({"model.json", "data.js"}, set(first_hashes))


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
        # No external node floats: each one is the target of at least one boundary edge.
        self.assertEqual(set(externals), {edge["target"] for edge in boundary})
        for edge in boundary:
            self.assertIn(edge["source"], node_ids)
            self.assertIn(edge["target"], externals)
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

    def test_interplay_tags_nodes_with_the_navigation_page_that_reaches_them(self) -> None:
        interplay = self.model["interplay"]
        config = json.loads((ROOT / "architecture/config.json").read_text(encoding="utf-8"))
        self.assertEqual([p["id"] for p in config["pages"]["items"]], [p["id"] for p in interplay["pages"]])
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
            self.assertIn(trigger["kind"], {"user_action", "lifecycle"})
            self.assertTrue((ROOT / trigger["path"]).is_file())
            self.assertEqual("swift.trigger.surface_call", trigger["rule_id"])
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


if __name__ == "__main__":
    unittest.main()
