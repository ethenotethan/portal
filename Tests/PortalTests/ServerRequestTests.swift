import Testing
import Foundation
@testable import Portal

@Suite("Server→client requests")
internal struct ServerRequestTests {

    private func frame(_ json: String) -> Data {
        Data(json.utf8)
    }

    private func decode(_ json: String) -> ServerRequest? {
        guard let object = try? JSONSerialization.jsonObject(with: frame(json)) as? [String: Any] else {
            Issue.record("fixture is not a JSON object")
            return nil
        }
        return ServerRequest.from(json: object)
    }

    // MARK: - Frame recognition

    @Test("a string id with a method is a server request; replies and events are not")
    internal func recognisesRequestFrames() {
        let request = decode(#"{"jsonrpc":"2.0","id":"srq-1","method":"sudo","params":{"session_id":"s1","command":"rm"}}"#)
        #expect(request?.id == "srq-1")
        #expect(request?.method == "sudo")
        #expect(request?.sessionID == "s1")
        #expect(decode(#"{"jsonrpc":"2.0","id":7,"result":{}}"#) == nil)
        #expect(decode(#"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready"}}"#) == nil)
        #expect(decode(#"{"jsonrpc":"2.0","id":"","method":"clarify"}"#) == nil)
    }

    // MARK: - Translation into the app's events

    @Test("clarify request becomes a clarify prompt that walks the batch one question at a time")
    internal func clarifyBatch() {
        let request = ServerRequest(id: "srq-c", method: "clarify", params: [
            "session_id": .string("s1"),
            "questions": .array([
                .dictionary(["qid": .string("q1"), "question": .string("Which env?"), "choices": .array([.string("dev"), .string("prod")])]),
                .dictionary(["qid": .string("q2"), "question": .string("Region?")]),
            ]),
        ])
        guard case .clarifyRequest(let payload) = request.event else {
            Issue.record("expected clarifyRequest, got \(String(describing: request.event?.debugName))")
            return
        }
        #expect(payload.requestID == "srq-c")
        #expect(payload.isServerRequest)
        #expect(payload.questionID == "q1")
        #expect(payload.question == "Which env?")
        #expect(payload.choices == ["dev", "prod"])
        #expect(payload.questions.count == 2)

        let next = payload.advanced(remaining: ["q2"])
        #expect(next?.questionID == "q2")
        #expect(next?.question == "Region?")
        #expect(next?.choices.isEmpty == true)
        #expect(payload.advanced(remaining: []) == nil)
    }

    @Test("a replayed clarify request skips the questions the gateway already holds locked")
    internal func clarifyReplaySkipsLockedQuestions() {
        let request = ServerRequest(id: "srq-r", method: "clarify", params: [
            "questions": .array([
                .dictionary(["qid": .string("q1"), "question": .string("First")]),
                .dictionary(["qid": .string("q2"), "question": .string("Second")]),
            ]),
            "answers": .dictionary(["q1": .string("done")]),
        ])
        guard case .clarifyRequest(let payload) = request.event else {
            Issue.record("expected clarifyRequest")
            return
        }
        #expect(payload.questionID == "q2")
        #expect(payload.questions.count == 1)
    }

    @Test("approval request carries its request id and the session hint")
    internal func approvalRequest() {
        let request = ServerRequest(id: "srq-a", method: "approval", params: [
            "session_id": .string("s1"), "request_id": .string("apr-9"), "command": .string("rm -rf build"),
            "choices": .array([.string("once"), .string("deny")]), "gateway_session_id": .string("20260101_abc"),
        ])
        guard case .approvalRequest(let payload) = request.event else {
            Issue.record("expected approvalRequest")
            return
        }
        #expect(payload.requestID == "srq-a")
        #expect(payload.approvalID == "apr-9")
        #expect(payload.command == "rm -rf build")
        #expect(payload.choices == ["once", "deny"])
        #expect(payload.sessionKey == "20260101_abc")
    }

    @Test("sudo and secret prompts surface as events and are answered as skipped")
    internal func sudoAndSecretAreSkipped() {
        let sudo = ServerRequest(id: "srq-s", method: "sudo", params: ["command": .string("apt install")])
        let secret = ServerRequest(id: "srq-k", method: "secret", params: ["env_var": .string("API_KEY"), "prompt": .string("Paste the key")])
        #expect(sudo.isAnsweredAsSkipped)
        #expect(secret.isAnsweredAsSkipped)
        guard case .secretRequest(let prompt, let envVar) = secret.event else {
            Issue.record("expected secretRequest")
            return
        }
        #expect(prompt == "Paste the key")
        #expect(envVar == "API_KEY")
        #expect(sudo.event?.debugName == "sudo.request")
    }

    @Test("methods Portal has no surface for translate to nothing")
    internal func unsupportedMethodsHaveNoEvent() {
        for method in ["terminal.read", "preview.read", "window.read", "preview.act", "tour", "theme.pick", "vault.unlock_prompt", "setup_beat"] {
            #expect(ServerRequest(id: "srq-x", method: method).event == nil, "\(method) should not map to an event")
            #expect(!ServerRequest(id: "srq-x", method: method).isAnsweredAsSkipped)
        }
    }

    // MARK: - Answer frames

    @Test("answer frames encode as bare JSON-RPC responses keyed by the request id")
    internal func answerFrameEncoding() throws {
        let ok = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(JSONRPCServerResponse.result(id: "srq-1", ["value": AnyCodable("")]))
        ) as? [String: Any]
        #expect(ok?["id"] as? String == "srq-1")
        #expect(ok?["jsonrpc"] as? String == "2.0")
        #expect(((ok?["result"] as? [String: Any])?["value"] as? String)?.isEmpty == true)
        #expect(ok?["error"] == nil)

        let declined = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(JSONRPCServerResponse.methodNotFound(id: "srq-2", method: "tour"))
        ) as? [String: Any]
        #expect(declined?["result"] == nil)
        #expect((declined?["error"] as? [String: Any])?["code"] as? Int == -32601)
        #expect(((declined?["error"] as? [String: Any])?["message"] as? String)?.contains("tour") == true)
    }

    // MARK: - Cancellation and capabilities

    @Test("request.cancel decodes into requestCancelled")
    internal func requestCancelEvent() {
        let event = GatewayEvent.from(type: "request.cancel", payload: .dictionary([
            "id": .string("srq-9"), "method": .string("clarify"), "reason": .string("interrupted"),
        ]))
        guard case .requestCancelled(let id, let method, let reason) = event else {
            Issue.record("expected requestCancelled, got \(event.debugName)")
            return
        }
        #expect(id == "srq-9")
        #expect(method == "clarify")
        #expect(reason == "interrupted")
        #expect(event.debugName == "request.cancel")
    }

    @Test("a cancelled approval leaves the queue wherever it sat")
    internal func approvalQueueRemovesCancelledEntry() {
        var queue = ApprovalQueue()
        queue.enqueue(ApprovalPayload(command: "first", sessionKey: "s", requestID: "srq-1"))
        queue.enqueue(ApprovalPayload(command: "second", sessionKey: "s", requestID: "srq-2"))
        queue.enqueue(ApprovalPayload(command: "third", sessionKey: "s", requestID: "srq-3"))
        queue.remove(requestID: "srq-2")
        #expect(queue.entries.map(\.command) == ["first", "third"])
        queue.remove(requestID: "srq-404")
        #expect(queue.count == 2)
    }

    @Test("the same request replayed by a resume is queued once; legacy entries never dedupe")
    internal func approvalQueueDedupesByRequestID() {
        var queue = ApprovalQueue()
        queue.enqueue(ApprovalPayload(command: "rm", sessionKey: "s", requestID: "srq-1", approvalID: "apr-1"))
        queue.enqueue(ApprovalPayload(command: "rm", sessionKey: "s", requestID: "srq-1", approvalID: "apr-1"))
        queue.enqueue(ApprovalPayload(command: "rm", sessionKey: "s"))
        queue.enqueue(ApprovalPayload(command: "rm", sessionKey: "s"))
        #expect(queue.count == 3)
        #expect(queue.head?.approvalID == "apr-1")
    }

    // MARK: - Resume replay

    @Test("session.resume open_requests become server requests on the resumed session")
    internal func resumeCarriesOpenRequests() throws {
        let json = """
        {"jsonrpc":"2.0","id":3,"result":{"session_id":"abc123","messages":[],"running":true,
         "open_requests":[{"id":"srq-5","method":"clarify","params":{"session_id":"abc123","questions":[{"qid":"q1","question":"Why?"}]}},
                          {"method":"broken"}]}}
        """
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: Data(json.utf8))
        let resumed = try GatewayClient.parseResumeResponse(response)
        #expect(resumed.openRequests.count == 1)
        #expect(resumed.openRequests.first?.id == "srq-5")
        #expect(resumed.openRequests.first?.sessionID == "abc123")
        guard case .clarifyRequest(let payload) = resumed.openRequests.first?.event else {
            Issue.record("expected the replayed request to render as a clarify prompt")
            return
        }
        #expect(payload.question == "Why?")
    }

    // MARK: - Client dispatch

    @Test("the client declines unknown requests, skips sudo, and forwards clarify as an event")
    @MainActor
    internal func clientDispatch() async throws {
        let client = GatewayClient(gatewayURL: URL(string: "ws://127.0.0.1:9/v1/ws")!, apiKey: "")
        var answers: [JSONRPCServerResponse] = []
        client.serverResponseRecorder = { answers.append($0) }
        var events: [(GatewayEvent, String?)] = []
        let subscription = client.eventStream.sink { events.append($0) }
        defer { subscription.cancel() }

        client.deliverFrameForTesting(frame(#"{"jsonrpc":"2.0","id":"srq-t","method":"tour","params":{"session_id":"s1"}}"#))
        client.deliverFrameForTesting(frame(#"{"jsonrpc":"2.0","id":"srq-s","method":"sudo","params":{"session_id":"s1","command":"ls"}}"#))
        client.deliverFrameForTesting(frame(
            #"{"jsonrpc":"2.0","id":"srq-c","method":"clarify","params":{"session_id":"s1","questions":[{"qid":"q1","question":"Go?"}]}}"#
        ))

        #expect(answers.map(\.id) == ["srq-t", "srq-s"])
        #expect(answers[0].error?.code == -32601)
        #expect(answers[1].result?["value"] == AnyCodable(""))
        #expect(events.map(\.0.debugName) == ["sudo.request", "clarify.request"])
        #expect(events.map(\.1) == ["s1", "s1"])
    }
}
