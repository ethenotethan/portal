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
