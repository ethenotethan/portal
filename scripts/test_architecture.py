#!/usr/bin/env python3
"""Tests for the deterministic architecture compiler."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import re
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

    def test_extracts_main_actor_and_actor_execution_domains(self) -> None:
        source = """@MainActor
final class ScreenModel {}

actor MessagePump {}
"""
        behavior = architecture.extract_behavioral_source(
            "Sources/Portal/Fixture.swift", source, "orchestration"
        )

        self.assertEqual(
            [("main_actor", "ScreenModel", 1), ("actor", "MessagePump", 3)],
            [(item["kind"], item["label"], item["evidence"]["line"]) for item in behavior["execution_domains"]],
        )
        self.assertTrue(all(item["authority"] == "observed" for item in behavior["execution_domains"]))
        self.assertTrue(all(item["rule_id"].startswith("swift.execution.") for item in behavior["execution_domains"]))

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

        self.assertEqual(["dispatch_queue"], [item["kind"] for item in behavior["execution_domains"]])
        self.assertEqual(["combine_subject"], [item["kind"] for item in behavior["resources"]])
        self.assertEqual(["publish", "batch", "hop"], [item["kind"] for item in behavior["operations"]])
        self.assertEqual("events", behavior["execution_domains"][0]["runtime_label"])

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

        self.assertEqual([], behavior["execution_domains"])
        self.assertEqual([], behavior["task_sites"])
        self.assertEqual([], behavior["resources"])
        self.assertEqual([], behavior["operations"])

    def test_compiled_model_has_static_behavior_metadata_pockets_and_stable_evidence(self) -> None:
        behavior = self.model["behavior"]
        self.assertEqual("static_source", self.model["evidence_metadata"]["class"])
        self.assertTrue(self.model["evidence_metadata"]["limitations"])
        self.assertEqual(sorted(architecture.BEHAVIOR_RULES), sorted(self.model["evidence_metadata"]["rules"]))
        self.assertTrue(behavior["execution_domains"])
        self.assertTrue(behavior["task_sites"])
        self.assertTrue(behavior["resources"])
        self.assertTrue(behavior["pockets"])
        self.assertTrue(all("static ownership/lifecycle cluster" in item["derivation"] for item in behavior["pockets"]))
        for collection in ("execution_domains", "task_sites", "resources", "operations"):
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
        for view in ("execution", "connections", "scenarios"):
            self.assertRegex(index, rf'<button[^>]+data-view="{view}"')
            self.assertRegex(index, rf'<section[^>]+id="{view}-view"')
            self.assertRegex(index, rf'id="{view}-content"')

    def test_behavior_site_has_deterministic_renderers_and_line_provenance(self) -> None:
        app = (ROOT / "architecture/site/app.js").read_text(encoding="utf-8")
        for renderer in ("renderExecution", "renderConnections", "renderScenarios"):
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


if __name__ == "__main__":
    unittest.main()
