import Testing
import Foundation
@testable import Portal

/// Unit coverage for `GatewayClient.parseResumeResponse` — the pure decode of a
/// `session.resume` reply. The interesting logic is the in-flight-turn gating:
/// a session whose turn is still live must resume INTO a streaming shell, while
/// a retained failed turn (carries `inflight` with `streaming: false`) must not
/// reopen one. Split from the RPC round-trip so it's testable without a socket.
@Suite("Gateway resume-response parsing")
internal struct GatewayResumeParseTests {

    private func decode(_ json: String) throws -> JSONRPCResponse {
        try JSONDecoder().decode(JSONRPCResponse.self, from: Data(json.utf8))
    }

    @Test("a live turn surfaces the in-flight snapshot with its partial text")
    internal func liveTurnSurfacesInflight() throws {
        let response = try decode("""
        {"jsonrpc":"2.0","id":1,"result":{
            "session_id":"3f9a1c22",
            "running":true,
            "inflight":{"streaming":true,"assistant":"Here is the "},
            "messages":[{"role":"user","content":"hi"}]
        }}
        """)
        let resumed = try GatewayClient.parseResumeResponse(response)
        #expect(resumed.sessionID == "3f9a1c22")
        #expect(resumed.messages.count == 1)
        #expect(resumed.inflight?.isStreaming == true)
        #expect(resumed.inflight?.assistantPartial == "Here is the ")
    }

    @Test("a retained failed turn does not reopen a streaming shell")
    internal func failedTurnIsNotStreaming() throws {
        let response = try decode("""
        {"jsonrpc":"2.0","id":1,"result":{
            "session_id":"abc123",
            "running":true,
            "inflight":{"streaming":false,"assistant":"partial before failure"},
            "messages":[]
        }}
        """)
        let resumed = try GatewayClient.parseResumeResponse(response)
        #expect(resumed.inflight == nil)
    }

    @Test("running session with no live turn reports no in-flight turn")
    internal func runningButNotStreamingIsNil() throws {
        // `running: false` gates it off even when the turn snapshot says streaming.
        let response = try decode("""
        {"jsonrpc":"2.0","id":1,"result":{
            "session_id":"abc123",
            "running":false,
            "inflight":{"streaming":true,"assistant":"stale"}
        }}
        """)
        let resumed = try GatewayClient.parseResumeResponse(response)
        #expect(resumed.inflight == nil)
    }

    @Test("a settled session with no inflight key parses history only")
    internal func settledSessionHasNoInflight() throws {
        let response = try decode("""
        {"jsonrpc":"2.0","id":1,"result":{
            "session_id":"abc123",
            "messages":[{"role":"user","content":"a"},{"role":"assistant","content":"b"}]
        }}
        """)
        let resumed = try GatewayClient.parseResumeResponse(response)
        #expect(resumed.inflight == nil)
        #expect(resumed.messages.count == 2)
        // No `running` key is no verdict — distinct from an explicit false.
        #expect(resumed.running == .unknown)
    }

    @Test("the session-level running flag is surfaced verbatim")
    internal func runningFlagIsSurfaced() throws {
        let stopped = try GatewayClient.parseResumeResponse(decode("""
        {"jsonrpc":"2.0","id":1,"result":{"session_id":"abc123","running":false,"inflight":null,"messages":[]}}
        """))
        #expect(stopped.running == .stopped)
        #expect(stopped.inflight == nil)

        let live = try GatewayClient.parseResumeResponse(decode("""
        {"jsonrpc":"2.0","id":1,"result":{"session_id":"abc123","running":true,"messages":[]}}
        """))
        #expect(live.running == .running)
    }

    @Test("an RPC error surfaces as GatewayError.rpcError")
    internal func rpcErrorThrows() throws {
        let response = try decode("""
        {"jsonrpc":"2.0","id":1,"error":{"code":4001,"message":"session not found"}}
        """)
        #expect(throws: GatewayError.self) {
            _ = try GatewayClient.parseResumeResponse(response)
        }
    }

    @Test("a reply missing session_id is an invalid response")
    internal func missingSessionIDThrows() throws {
        let response = try decode("""
        {"jsonrpc":"2.0","id":1,"result":{"messages":[]}}
        """)
        #expect(throws: GatewayError.self) {
            _ = try GatewayClient.parseResumeResponse(response)
        }
    }
}

@Suite("JSON-RPC request encoding")
internal struct JSONRPCRequestEncodingTests {
    private func object(for request: JSONRPCRequest) throws -> [String: Any] {
        let data = try JSONEncoder().encode(request)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("an outbound request preserves its envelope and heterogeneous params")
    internal func encodesEnvelopeAndParams() throws {
        let object = try object(for: JSONRPCRequest(
            id: 42,
            method: "session.send",
            params: [
                "session_id": AnyCodable("abc123"),
                "stream": AnyCodable(true),
                "metadata": .dictionary(["attempt": AnyCodable(3)]),
            ]
        ))

        #expect(object["jsonrpc"] as? String == "2.0")
        #expect(object["id"] as? Int == 42)
        #expect(object["method"] as? String == "session.send")
        let params = try #require(object["params"] as? [String: Any])
        #expect(params["session_id"] as? String == "abc123")
        #expect(params["stream"] as? Bool == true)
        #expect((params["metadata"] as? [String: Any])?["attempt"] as? Int == 3)
    }

    @Test("a parameterless request omits params rather than sending null")
    internal func omitsAbsentParams() throws {
        let object = try object(for: JSONRPCRequest(id: 7, method: "system.ping"))

        #expect(object["jsonrpc"] as? String == "2.0")
        #expect(object["id"] as? Int == 7)
        #expect(object["method"] as? String == "system.ping")
        #expect(object["params"] == nil)
    }
}

@Suite("JSON-RPC value decoding")
internal struct AnyCodableDecodingTests {
    @Test("JSON null decodes as the explicit null case")
    internal func nullDecodesExplicitly() throws {
        let value = try JSONDecoder().decode(AnyCodable.self, from: Data("null".utf8))

        #expect(value == .null)
    }
}
