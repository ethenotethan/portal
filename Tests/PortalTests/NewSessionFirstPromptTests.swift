import Combine
import Testing
import Foundation
@testable import Portal

/// Regression coverage for "trying to create new sessions… starts with
/// *Creating session — connecting to the harness…* but then ends with *Session
/// connection lost. Please try again.*" — while the CRON graph (a plain RPC over
/// the very same socket) loaded fine.
///
/// The transport was never the problem. Two things stacked:
///
///  1. `needsGatewayResume` is armed by any `.reconnecting` transition, and the
///     gateway resets connections periodically. `createSession()` did not clear
///     it, so a brand-new session's FIRST prompt went through the auto-resume
///     gate in `submitPrompt`. That gate resumes by `displaySessionID`, which
///     for a fresh session is still the short runtime hex — not the
///     database-format ID `session.resume` expects (it only arrives later, on a
///     `session.title` event, which needs a turn to have run). The gateway
///     rejected the key, the prompt was dropped, and the failure was reported as
///     a lost connection.
///  2. A rejected resume on a LIVE socket was treated as terminal, so even
///     outside the fresh-session case the user's text never reached the gateway.
private final class FirstPromptBackendSpy: AgentBackend {
    internal let eventStream = PassthroughSubject<(GatewayEvent, String?), Never>()
    internal let stateSubject = CurrentValueSubject<GatewayClient.ConnectionState, Never>(.connected)
    internal var connectionStatePublisher: AnyPublisher<GatewayClient.ConnectionState, Never> {
        stateSubject.eraseToAnyPublisher()
    }
    internal let sessionInfoPublisher = Just<SessionInfo?>(nil).eraseToAnyPublisher()
    internal var connectionState: GatewayClient.ConnectionState = .connected
    internal var onReconnected: (() async -> Void)?
    internal let apiKey = ""
    internal var activeSessionID: String?
    internal let capabilities = BackendCapabilities.hermes

    /// Short runtime hex `session.create` hands back — exactly the shape a
    /// fresh session is keyed by before any `session.title` event.
    internal var createdSessionID = "a1b2c3"
    /// When true, `session.resume` rejects every key, the way the gateway
    /// rejects a session it can't look up by that ID.
    internal var resumeFails = false
    private(set) var resumeKeys: [String] = []
    private(set) var submittedPrompts: [(sessionID: String, text: String)] = []

    internal func createSession(cols: Int) async throws -> String {
        activeSessionID = createdSessionID
        return createdSessionID
    }

    internal func resumeSession(key: String) async throws -> (sessionID: String, messages: [[String: AnyCodable]]) {
        resumeKeys.append(key)
        if resumeFails {
            throw GatewayError.rpcError(JSONRPCError(code: -32602, message: "unknown session"))
        }
        activeSessionID = key
        return (key, [])
    }

    internal func submitPrompt(sessionID: String, text: String) async throws {
        submittedPrompts.append((sessionID: sessionID, text: text))
    }

    internal func modelOptions(sessionID: String?, refresh: Bool) async throws -> ModelCatalog? { nil }
    internal func sessionHistory(sessionID: String) async throws -> [[String: AnyCodable]] { [] }
    internal func interrupt(sessionID: String) async throws {}
    internal func respondApproval(sessionID: String, choice: String, all: Bool) async throws {}
    internal func respondClarify(requestID: String, answer: String) async throws {}
    internal func setConfig(key: String, value: String, sessionID: String?) async throws {}
    internal func setEphemeralPrompt(sessionID: String, prompt: String) async throws {}
    internal func setSessionSkills(sessionID: String, skillNames: [String]) async throws {}
    internal func uploadFile(data: Data, filename: String, mimeType: String, sessionID: String?) async throws -> String {
        filename
    }
    internal func downloadFile(from url: URL, token: String?) async throws -> Data { Data() }
    internal func attachImage(path: String, sessionID: String?) async throws {}
    internal func voiceToggle(action: String) async throws -> [String: AnyCodable]? { [:] }
    internal func voiceRecord(action: String) async throws {}
    internal func recordDroppedEvent(_ event: GatewayEvent, sessionID: String?, reason: String) {}
}

@Suite("First prompt on a newly created session")
@MainActor
internal struct NewSessionFirstPromptTests {

    /// The connection-state sink is `.receive(on: RunLoop.main)`, so the
    /// `.reconnecting` transition lands a turn of the runloop later.
    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    @Test("a session created after a reconnect sends its first prompt")
    internal func createdSessionSendsFirstPrompt() async {
        let backend = FirstPromptBackendSpy()
        // The gateway can't resume this session by its short runtime hex — the
        // condition that used to swallow the first prompt.
        backend.resumeFails = true
        let vm = ChatViewModel()
        vm.setGatewayClient(backend)

        // A periodic gateway connection reset arms the resume gate.
        backend.stateSubject.send(.reconnecting(attempt: 1))
        await settle()

        await vm.createSession()
        #expect(vm.currentSessionID == backend.createdSessionID)
        #expect(vm.error == nil)

        vm.inputText = "hello"
        await vm.submitPrompt()

        #expect(backend.submittedPrompts.count == 1)
        #expect(backend.submittedPrompts.first?.text.hasSuffix("hello") == true)
        // No resume was attempted: a session created on the live socket is
        // already registered with the gateway.
        #expect(backend.resumeKeys.isEmpty)
        #expect(vm.error == nil)
    }

    @Test("a rejected pre-submit resume on a live socket still sends the prompt")
    internal func rejectedResumeOnLiveSocketStillSends() async {
        let backend = FirstPromptBackendSpy()
        let vm = ChatViewModel()
        vm.setGatewayClient(backend)

        // An established session: resume works, which is what binds sessionID.
        let key = "20260501_112429_d91274"
        #expect(await vm.resumeSession(key: key))

        // Reconnect arms the gate, and this time the resume is rejected.
        backend.stateSubject.send(.reconnecting(attempt: 1))
        await settle()
        backend.resumeFails = true

        vm.inputText = "still send me"
        await vm.submitPrompt()

        #expect(backend.resumeKeys.count == 2)
        #expect(backend.submittedPrompts.count == 1)
        #expect(backend.submittedPrompts.first?.text.hasSuffix("still send me") == true)
        // "Session connection lost" would be a guess — the socket is live.
        #expect(vm.error == nil)
    }

    @Test("a rejected resume on a dead socket still reports the lost connection")
    internal func rejectedResumeOnDeadSocketReportsLoss() async {
        let backend = FirstPromptBackendSpy()
        let vm = ChatViewModel()
        vm.setGatewayClient(backend)

        let key = "20260501_112429_d91274"
        #expect(await vm.resumeSession(key: key))

        backend.stateSubject.send(.reconnecting(attempt: 1))
        await settle()
        backend.resumeFails = true
        backend.connectionState = .reconnecting(attempt: 1)

        vm.inputText = "held back"
        await vm.submitPrompt()

        #expect(backend.submittedPrompts.isEmpty)
        #expect(vm.error == "Session connection lost. Please try again.")
        // The text stays in the box so the user's prompt isn't lost.
        #expect(vm.inputText == "held back")
    }
}
