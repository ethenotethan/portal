import Foundation
import Testing
@testable import Portal

// The read side of the HTML artifact bridge, without a WebView or a gateway:
// the request URL contract, the manifest parser, the client-side parameter
// validator (a mirror of the gateway's, so the page gets a reason before a
// round trip), and the two scripts — what goes into the isolated world and
// what comes back out of it.

@Suite("HTML artifact query bridge")
internal struct ArtifactQueryBridgeTests {

    private static let sourcesRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // PortalTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("Sources/Portal")

    private static func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: sourcesRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    // MARK: - Request URL

    @Test("decodes only the narrow request URL contract")
    internal func decodesRequestURL() throws {
        let raw = "hermes-artifact-query://request?query_id=open-orders&params=%7B%22limit%22%3A50%7D&nonce=n1"
        let url = try #require(URL(string: raw))
        let request = try #require(HTMLArtifactQueryRequest(url: url, expectedNonce: "n1"))
        #expect(request == HTMLArtifactQueryRequest(queryID: "open-orders", rawParams: "{\"limit\":50}"))
        #expect(try request.parameters()["limit"] as? Int == 50)
    }

    @Test("rejects forged nonces, duplicate fields, unknown fields, and bad ids", arguments: [
        "https://example.com/?query_id=x&nonce=n1",
        "hermes-artifact-query://invoke?query_id=x&nonce=n1",
        "hermes-artifact-query://request?nonce=n1",
        "hermes-artifact-query://request?query_id=x",
        "hermes-artifact-query://request?query_id=x&nonce=wrong",
        "hermes-artifact-query://request?query_id=x&query_id=y&nonce=n1",
        "hermes-artifact-query://request?query_id=x&nonce=n1&handler=postgres.drop",
        "hermes-artifact-query://request?query_id=open%20orders&nonce=n1",
    ])
    internal func rejectsOutsideContract(_ raw: String) throws {
        let url = try #require(URL(string: raw))
        #expect(HTMLArtifactQueryRequest(url: url, expectedNonce: "n1") == nil)
    }

    @Test("parameters must be a JSON object; empty means none")
    internal func parametersMustBeAnObject() throws {
        #expect(try HTMLArtifactQueryRequest(queryID: "q", rawParams: "  ").parameters().isEmpty)
        #expect(throws: ArtifactQueryError.notJSONObject) {
            try HTMLArtifactQueryRequest(queryID: "q", rawParams: "[1,2]").parameters()
        }
        #expect(throws: ArtifactQueryError.notJSONObject) {
            try HTMLArtifactQueryRequest(queryID: "q", rawParams: "not json").parameters()
        }
    }

    // MARK: - Manifest

    private var manifest: [Any] {
        [
            [
                "id": "open-orders", "query": "postgres.orders.open",
                "bind": ["state": "open"],
                "params": ["limit": ["type": "int", "min": 1, "max": 200, "default": 100]],
                "live": ["mode": "poll", "interval_s": 30],
                "invalidated_by": ["archive-order"],
            ],
            ["id": "handlers-only", "query": "artifact.rows"],
            ["query": "no.id"],
            ["id": "no-handler"],
        ]
    }

    @Test("parses declarations and drops the malformed ones")
    internal func parsesManifest() {
        let queries = ArtifactQuery.parse(manifest)
        #expect(queries.map(\.id) == ["open-orders", "handlers-only"])
        let orders = queries[0]
        #expect(orders.handler == "postgres.orders.open")
        #expect(orders.bind == ["state": .string("open")])
        #expect(orders.params["limit"]?.kind == .int)
        #expect(orders.live == .poll(intervalSeconds: 30))
        #expect(orders.invalidatedBy == ["archive-order"])
        // No `params` object at all: the page's values go straight to the
        // handler's schema, which the gateway holds.
        #expect(queries[1].declaresParams == false)
        #expect(queries[1].isLive == false)
    }

    @Test("a LivingArtifact carries its queries off the gateway record")
    internal func livingArtifactCarriesQueries() {
        let artifact = LivingArtifact.from([
            "id": .string("dash"), "kind": .string("html"), "content": .string("<html/>"),
            "queries": .array([
                .dictionary(["id": .string("rows"), "query": .string("artifact.rows"),
                             "bind": .dictionary(["source": .string("orders")])]),
            ]),
        ])
        #expect(artifact?.queries.map(\.id) == ["rows"])
        #expect(artifact?.queries.first?.bind["source"] == .string("orders"))
    }

    @Test("every live artifact surface passes its query manifest to the renderer")
    internal func liveSurfacesCarryQueries() throws {
        // A live HTML page without this argument gets no observer script at all:
        // its static "Connecting…" copy then remains forever even though the
        // store record carries a valid query declaration.
        let chat = try Self.source("Views/ChatView.swift")
        #expect(chat.contains("queries: live?.queries ?? []"))

        let macPanel = try Self.source("Views/Blocks/ArtifactPanel.swift")
        #expect(macPanel.contains("queries: live?.queries ?? []"))

        let graphPanel = try Self.source("Views/ThoughtGraph/ArtifactsPanel.swift")
        #expect(graphPanel.components(separatedBy: "queries: artifact.queries").count - 1 == 2)
    }

    // MARK: - Validation

    private var orders: ArtifactQuery { ArtifactQuery.parse(manifest)[0] }

    @Test("defaults, coercion, and bound values fill in the way the gateway will")
    internal func validatesAndFillsIn() throws {
        #expect(try orders.validate([:]) == ["limit": .int(100), "state": .string("open")])
        #expect(try orders.validate(["limit": "25"]) == ["limit": .int(25), "state": .string("open")])
        // Repeating the bound value is harmless; changing it is not.
        #expect(try orders.validate(["state": "open"])["state"] == .string("open"))
    }

    @Test("refuses what the gateway would refuse, with the parameter named", arguments: [
        ("{\"limit\": 500}", "limit above maximum 200"),
        ("{\"limit\": true}", "limit expected an integer"),
        ("{\"state\": \"closed\"}", "state is bound by the artifact"),
        ("{\"where\": \"1=1\"}", "where is not a parameter"),
    ])
    internal func refusesBadParameters(_ rawParams: String, _ message: String) throws {
        // Through the same door the page uses: raw attribute text in.
        let supplied = try HTMLArtifactQueryRequest(queryID: "open-orders", rawParams: rawParams).parameters()
        do {
            _ = try orders.validate(supplied)
            Issue.record("expected \(message)")
        } catch {
            #expect(error.localizedDescription.contains(message), "\(error.localizedDescription)")
        }
    }

    @Test("every declared type coerces and bounds")
    internal func typesCoerce() throws {
        let query = ArtifactQuery.parse([[
            "id": "q", "query": "h",
            "params": [
                "flag": ["type": "bool"],
                "ratio": ["type": "number", "min": 0],
                "state": ["type": "enum", "values": ["a", "b"]],
                "name": ["type": "string", "max": 3, "required": true],
                "cursor": ["type": "cursor"],
            ],
        ]])[0]
        let out = try query.validate(["flag": "true", "ratio": 2, "state": "a", "name": "abc", "cursor": "7"])
        #expect(out == ["flag": .bool(true), "ratio": .double(2), "state": .string("a"),
                        "name": .string("abc"), "cursor": .string("7")])
        #expect(throws: ArtifactQueryError.badParameter("name", "is required")) { try query.validate([:]) }
        #expect(throws: ArtifactQueryError.badParameter("state", "must be one of a, b")) {
            try query.validate(["name": "x", "state": "z"])
        }
        #expect(throws: ArtifactQueryError.badParameter("name", "longer than 3 characters")) {
            try query.validate(["name": "abcd"])
        }
    }

    // MARK: - Scripts

    @Test("the observer script asks over the nonce'd scheme and nothing else")
    internal func observerScript() {
        let js = HTMLArtifactQueryBridge.userScriptSource(nonce: "n\"1")
        #expect(js.contains("MutationObserver"))
        #expect(js.contains("data-hermes-query"))
        #expect(js.contains("data-hermes-params"))
        #expect(js.contains("hermes-artifact-query://request?"))
        #expect(js.contains("\"n\\\"1\""))            // nonce JSON-encoded
        #expect(!js.contains("fetch("))
        #expect(!js.contains("webkit.messageHandlers"))
        #expect(!js.contains("eval("))
    }

    @Test("the result script writes text into a JSON sink and dispatches an event")
    internal func resultScriptWritesData() {
        let mark = HTMLArtifactQueryBridge.ResultMark(
            queryID: "open-orders", rawParams: "{\"limit\":50}", status: .ok,
            payload: "{\"rows\":[{\"id\":\"o1\"}]}")
        let js = HTMLArtifactQueryBridge.resultScript(mark)
        #expect(js.contains("application/json"))
        #expect(js.contains("data-hermes-sink"))
        #expect(js.contains("textContent = payload"))
        #expect(js.contains("new Event('hermes-data'"))
        #expect(js.contains("data-hermes-query-status"))
        #expect(js.contains("\"{\\\"limit\\\":50}\""))   // params matched verbatim, JSON-encoded
        #expect(js.contains("const error = null"))
        // Never a native→page execution surface.
        #expect(!js.contains("innerHTML"))
        #expect(!js.contains("eval("))
        #expect(!js.contains("fetch("))
    }

    @Test("errors are stamped bounded and control-free; a failure leaves the sink alone")
    internal func resultScriptErrors() {
        let noisy = String(repeating: "x", count: 300) + "\u{0007}tail"
        let mark = HTMLArtifactQueryBridge.ResultMark(
            queryID: "q", rawParams: "", status: .failed, error: noisy)
        #expect(mark.error?.count == HTMLArtifactQueryBridge.maxReasonLength)
        #expect(mark.error?.contains("\u{0007}") == false)
        let js = HTMLArtifactQueryBridge.resultScript(mark)
        #expect(js.contains("const payload = null"))
        #expect(js.contains("\"failed\""))
    }

    @Test("payload text is stable across key order")
    internal func payloadTextIsStable() {
        let first = HTMLArtifactQueryBridge.payloadText(.dictionary(["b": .int(1), "a": .int(2)]))
        let second = HTMLArtifactQueryBridge.payloadText(.dictionary(["a": .int(2), "b": .int(1)]))
        #expect(first == second)
        #expect(first == "{\"a\":2,\"b\":1}")
    }

    @Test("gateway results decode by status")
    internal func decodesResults() {
        let ok = ArtifactQueryResult.from([
            "status": .string("ok"), "data": .dictionary(["rows": .array([])]),
            "etag": .string("abc"), "subscription": .string("dash/rows/h"),
        ])
        #expect(ok.outcome == .ok(data: .dictionary(["rows": .array([])]), etag: "abc", nextCursor: nil))
        #expect(ok.subscription == "dash/rows/h")
        #expect(ArtifactQueryResult.from(["status": .string("failed"), "reason": .string("rate limited")]).outcome
                == .failed(reason: "rate limited"))
        #expect(ArtifactQueryResult.from(["status": .string("conflict")]).outcome == .conflict)
        #expect(ArtifactQueryResult.from(["status": .string("unsupported")]).outcome
                == .unsupported(reason: "Query not supported"))
    }
}
