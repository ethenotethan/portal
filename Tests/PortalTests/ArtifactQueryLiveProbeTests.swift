import Combine
import Foundation
import XCTest
@testable import Portal

/// Live integration probe: drives the real `GatewayClient` decoder and the real
/// `ArtifactStore` query state machine against a running gateway, end to end.
///
/// Skipped unless the environment names a gateway:
///   PORTAL_PROBE_GATEWAY_URL   ws(s)://host/v1/ws
///   PORTAL_PROBE_API_KEY       bearer key
///   PORTAL_PROBE_ARTIFACT_ID   artifact whose manifest declares a live query
///   PORTAL_PROBE_QUERY_ID      (default "cluster-resources")
///   PORTAL_PROBE_PARAMS        (default {"window":30}) — the page's raw params
///   PORTAL_PROBE_MIN_PUSHES    (default 3) unsolicited pushes to wait for
///
/// Contract proven when it passes: connect → pull manifest → subscribe →
/// valid initial payload → unsolicited `artifact.query.changed` decoded and
/// routed → re-invoke → new payload/etag projected into `queryStates`, at least
/// N times → unsubscribe → disconnect. Nothing here touches the UI.
@MainActor
final class ArtifactQueryLiveProbeTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    func testLiveQueryReceivesUnsolicitedPushesAndReinvokes() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let urlString = env["PORTAL_PROBE_GATEWAY_URL"],
              let url = URL(string: urlString),
              let apiKey = env["PORTAL_PROBE_API_KEY"],
              let artifactID = env["PORTAL_PROBE_ARTIFACT_ID"] else {
            throw XCTSkip("set PORTAL_PROBE_GATEWAY_URL / PORTAL_PROBE_API_KEY / PORTAL_PROBE_ARTIFACT_ID to run")
        }
        let queryID = env["PORTAL_PROBE_QUERY_ID"] ?? "cluster-resources"
        let rawParams = env["PORTAL_PROBE_PARAMS"] ?? "{\"window\":30}"
        let minPushes = Int(env["PORTAL_PROBE_MIN_PUSHES"] ?? "") ?? 3
        let started = Date()
        func stamp() -> String { String(format: "%6.2fs", Date().timeIntervalSince(started)) }

        // 1. Connect with the real client.
        let client = GatewayClient(gatewayURL: url, apiKey: apiKey)
        var pushes: [(Date, String)] = []
        var unknownOrFailed: [String] = []
        client.eventStream
            .sink { event, _ in
                switch event {
                case .artifactQueryChanged(let id, let qid, let status, let reason):
                    if id == artifactID && qid == queryID { pushes.append((Date(), status)) }
                    if status != "ok" { unknownOrFailed.append("push status \(status): \(reason)") }
                case .unknown(let type):
                    unknownOrFailed.append("unknown event \(type)")
                default:
                    break
                }
            }
            .store(in: &cancellables)
        client.connect()
        defer { client.disconnect() }
        try await waitUntil("client connected", seconds: 20) {
            if case .connected = client.connectionState { return true }
            return false
        }
        print("[probe \(stamp())] connected")

        // 2. Pull the stored artifact through the real store (manifest included).
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ArtifactStore(fileURL: dir.appendingPathComponent("artifacts.json"))
        store.setClient(client)
        try await waitUntil("artifact \(artifactID) with a query manifest", seconds: 20) {
            !(store.artifacts[artifactID]?.queries.isEmpty ?? true)
        }
        let artifact = store.artifacts[artifactID]!
        let declaration = artifact.queries.first { $0.id == queryID }
        XCTAssertNotNil(declaration, "artifact declares no query \(queryID)")
        XCTAssertTrue(declaration?.isLive ?? false, "query \(queryID) is not live")
        XCTAssertTrue(artifact.content.contains("data-hermes-query=\"\(queryID)\""), "page lacks the declaration")
        XCTAssertTrue(artifact.content.contains("data-hermes-sink"), "page lacks a sink")
        print("[probe \(stamp())] rev=\(artifact.rev) queries=\(artifact.queries.map(\.id)) live=\(String(describing: declaration?.live))")

        // 3. Run the slot exactly as the HTML host does; observe the state machine.
        let slot = ArtifactStore.QuerySlot(artifactID: artifactID, queryID: queryID, rawParams: rawParams)
        var etags: [(Date, String)] = []
        var terminalFailures: [String] = []
        store.$queryStates
            .sink { states in
                guard let state = states[slot] else { return }
                switch state {
                case .ok(_, let etag):
                    if etags.last?.1 != etag { etags.append((Date(), etag)) }
                case .failed(let reason): terminalFailures.append("failed: \(reason)")
                case .unsupported(let reason): terminalFailures.append("unsupported: \(reason)")
                case .loading: break
                }
            }
            .store(in: &cancellables)
        store.runQuery(artifactID: artifactID, queryID: queryID, rawParams: rawParams)

        // 4. Valid initial payload.
        try await waitUntil("initial ok payload", seconds: 20) { !etags.isEmpty || !terminalFailures.isEmpty }
        XCTAssertTrue(terminalFailures.isEmpty, "slot failed before first payload: \(terminalFailures)")
        guard case .ok(let payload, let firstEtag) = store.queryStates[slot] else {
            return XCTFail("slot not ok after first run: \(String(describing: store.queryStates[slot]))")
        }
        let json = try JSONSerialization.jsonObject(with: Data(payload.utf8))
        XCTAssertTrue(json is [String: Any] || json is [Any], "initial payload is not a JSON container")
        print("[probe \(stamp())] initial etag=\(firstEtag) payloadBytes=\(payload.utf8.count)")

        // 5–7. Unsolicited pushes → re-invoke → advancing etags in the store.
        try await waitUntil("\(minPushes) unsolicited pushes and \(minPushes) new etags", seconds: 60) {
            pushes.count >= minPushes && etags.count >= minPushes + 1
        }
        for (i, entry) in etags.enumerated() {
            print("[probe] etag[\(i)] +\(String(format: "%.2f", entry.0.timeIntervalSince(started)))s \(entry.1)")
        }
        for (i, push) in pushes.enumerated() {
            print("[probe] push[\(i)] +\(String(format: "%.2f", push.0.timeIntervalSince(started)))s status=\(push.1)")
        }
        XCTAssertEqual(Set(etags.map(\.1)).count, etags.count, "etags did not advance: \(etags.map(\.1))")
        XCTAssertTrue(terminalFailures.isEmpty, "slot hit terminal states during live phase: \(terminalFailures)")
        XCTAssertTrue(unknownOrFailed.isEmpty, "decoder anomalies: \(unknownOrFailed)")

        // 8. Release → unsubscribe, then disconnect (defer).
        store.releaseQueries(artifactID: artifactID)
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(store.querySlots(artifactID: artifactID).isEmpty)
        print("[probe \(stamp())] released; pushes=\(pushes.count) etags=\(etags.count)")
    }

    private func waitUntil(
        _ what: String, seconds: Double, file: StaticString = #filePath, line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(150))
        }
        XCTFail("timed out after \(Int(seconds))s waiting for \(what)", file: file, line: line)
        throw XCTSkip("probe aborted: \(what)")
    }
}
