import Combine
import Foundation
import Testing
@testable import Portal

/// The RPC wrappers added for the server→client request protocol, exercised
/// without a socket: every one must build its params and fail fast through
/// `call`'s not-connected path rather than hang, and the parsers on the reply
/// side are pure functions of a decoded response.
@Suite("Gateway wire calls — request protocol wrappers")
@MainActor
internal struct GatewayClientWireCallsTests {

    private func client() -> GatewayClient {
        GatewayClient(gatewayURL: URL(string: "ws://127.0.0.1:9/v1/ws")!, apiKey: "")
    }

    private func expectNotConnected(_ body: () async throws -> Void) async {
        do {
            try await body()
            Issue.record("expected the call to fail without a socket")
        } catch GatewayError.notConnected {
            // the one acceptable outcome
        } catch {
            Issue.record("expected notConnected, got \(error)")
        }
    }

    @Test("approval answers, clarify locks, skill reads and writes, and history all fail fast without a socket")
    internal func wrappersFailFastWhenDisconnected() async {
        let client = client()
        await expectNotConnected { try await client.respondApproval(sessionID: "s", choice: "once", all: false, requestID: "apr-1") }
        await expectNotConnected { try await client.respondApproval(sessionID: "s", choice: "deny") }
        await expectNotConnected { _ = try await client.lockClarifyAnswer(requestID: "srq-1", questionID: "q1", answer: nil) }
        await expectNotConnected { _ = try await client.lockClarifyAnswer(requestID: "srq-1", questionID: "q1", answer: "yes") }
        await expectNotConnected { _ = try await client.readSkillMarkdown(name: "demo") }
        await expectNotConnected { _ = try await client.writeSkillMarkdown(name: "demo", content: "# demo") }
        await expectNotConnected { _ = try await client.architectureHistory(service: "arch:portal") }
    }

    @Test("advertising client capabilities without a socket is logged, never thrown")
    internal func advertiseWithoutSocketIsQuiet() async {
        await client().advertiseClientCapabilities()
    }

    @Test("an answer to a server request with no socket is dropped, not queued")
    internal func answerWithoutSocketIsDropped() {
        let client = client()
        var events: [GatewayEvent] = []
        let subscription = client.eventStream.sink { events.append($0.0) }
        defer { subscription.cancel() }
        client.deliverFrameForTesting(Data(#"{"jsonrpc":"2.0","id":"srq-s","method":"sudo","params":{"session_id":"s1"}}"#.utf8))
        client.deliverFrameForTesting(Data(#"{"jsonrpc":"2.0","id":"srq-t","method":"tour","params":{"session_id":"s1"}}"#.utf8))
        #expect(events.map(\.debugName) == ["sudo.request"])
    }

    @Test("the default backend answers approvals positionally and locks by answering the whole prompt")
    internal func backendDefaultsDelegate() async throws {
        let backend = LegacyBackendSpy()
        try await backend.respondApproval(sessionID: "s", choice: "once", all: false, requestID: "apr-9")
        #expect(backend.approvals.map { "\($0.0):\($0.1)" } == ["once:false"])
        let remaining = try await backend.lockClarifyAnswer(requestID: "r", questionID: "q", answer: nil)
        #expect(remaining.isEmpty)
        #expect(backend.clarifyAnswers == [""])
        let remainingAfterAnswer = try await backend.lockClarifyAnswer(requestID: "r", questionID: "q", answer: "yes")
        #expect(remainingAfterAnswer.isEmpty)
        #expect(backend.clarifyAnswers == ["", "yes"])
    }
}

/// A backend that predates request ids and per-question locking: it implements
/// only the original protocol surface, so the protocol's default extensions
/// carry the new calls to it.
private final class LegacyBackendSpy: AgentBackend {
    internal let eventStream = PassthroughSubject<(GatewayEvent, String?), Never>()
    internal let connectionStatePublisher = Just(GatewayClient.ConnectionState.connected).eraseToAnyPublisher()
    internal var connectionState: GatewayClient.ConnectionState = .connected
    internal var reconnectedPublisher: AnyPublisher<Void, Never> { Empty().eraseToAnyPublisher() }
    internal let apiKey = ""
    internal var activeSessionID: String?
    private(set) var approvals: [(String, Bool)] = []
    private(set) var clarifyAnswers: [String] = []

    internal func createSession(cols: Int) async throws -> String { "legacy" }
    internal func resumeSession(key: String) async throws -> (sessionID: String, messages: [[String: AnyCodable]]) { (key, []) }
    internal func sessionHistory(sessionID: String) async throws -> [[String: AnyCodable]] { [] }
    internal func interrupt(sessionID: String) async throws {}
    internal func submitPrompt(sessionID: String, text: String) async throws {}
    internal func respondApproval(sessionID: String, choice: String, all: Bool) async throws { approvals.append((choice, all)) }
    internal func respondClarify(requestID: String, answer: String) async throws { clarifyAnswers.append(answer) }
    internal func setConfig(key: String, value: String, sessionID: String?) async throws {}
    internal func setEphemeralPrompt(sessionID: String, prompt: String) async throws {}
    internal func setSessionSkills(sessionID: String, skillNames: [String]) async throws {}
    internal func modelOptions(sessionID: String?, refresh: Bool) async throws -> ModelCatalog? { nil }
    internal func uploadFile(data: Data, filename: String, mimeType: String, sessionID: String?) async throws -> String { filename }
    internal func downloadFile(from url: URL, token: String?) async throws -> Data { Data() }
    internal func attachImage(path: String, sessionID: String?) async throws {}
    internal func voiceToggle(action: String) async throws -> [String: AnyCodable]? { [:] }
    internal func voiceRecord(action: String) async throws {}
    internal func recordDroppedEvent(_ event: GatewayEvent, sessionID: String?, reason: String) {}
}
