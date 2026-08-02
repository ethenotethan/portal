import Combine
import Foundation
import Testing
@testable import Portal

@MainActor
private final class VoiceBackendSpy: AgentBackend {
    private enum StubError: Error {
        case expected
    }

    internal let eventStream = PassthroughSubject<(GatewayEvent, String?), Never>()
    internal let connectionStatePublisher = Just(GatewayClient.ConnectionState.connected).eraseToAnyPublisher()
    internal let sessionInfoPublisher = Just<SessionInfo?>(nil).eraseToAnyPublisher()
    internal var connectionState: GatewayClient.ConnectionState = .connected
    internal var onReconnected: (() async -> Void)?
    internal let apiKey = ""
    internal var activeSessionID: String? = "voice-session"
    internal let capabilities = BackendCapabilities.hermes

    private(set) var voiceActions: [String] = []
    private(set) var recordActions: [String] = []
    private(set) var submittedPrompts: [(sessionID: String, text: String)] = []
    var failVoiceToggle = false
    var failVoiceRecord = false

    internal func createSession(cols: Int) async throws -> String { "voice-session" }
    internal func resumeSession(key: String) async throws -> (sessionID: String, messages: [[String: AnyCodable]]) {
        (key, [])
    }
    internal func sessionHistory(sessionID: String) async throws -> [[String: AnyCodable]] { [] }
    internal func interrupt(sessionID: String) async throws {}

    internal func submitPrompt(sessionID: String, text: String) async throws {
        submittedPrompts.append((sessionID, text))
    }
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

    internal func voiceToggle(action: String) async throws -> [String: AnyCodable]? {
        voiceActions.append(action)
        if failVoiceToggle { throw StubError.expected }
        return [:]
    }

    internal func voiceRecord(action: String) async throws {
        recordActions.append(action)
        if failVoiceRecord { throw StubError.expected }
    }

    internal func recordDroppedEvent(_ event: GatewayEvent, sessionID: String?, reason: String) {}
}

@Suite("Chat voice recording")
@MainActor
internal struct ChatVoiceRecordingTests {
    @Test("start and stop issue the expected voice RPCs")
    internal func startAndStopVoiceRecording() async {
        let backend = VoiceBackendSpy()
        let viewModel = ChatViewModel()
        viewModel.setGatewayClient(backend)
        _ = viewModel.beginSwitchToSession(key: "voice-start-stop")

        await viewModel.startVoiceRecording()
        #expect(backend.voiceActions == ["on"])
        #expect(backend.recordActions == ["start"])

        viewModel.receiveGatewayEventForTesting(
            .voiceStatus(state: "recording"),
            sessionID: "voice-start-stop"
        )
        #expect(viewModel.isVoiceRecording)

        await viewModel.stopVoiceRecording()
        #expect(backend.recordActions == ["start", "stop"])
        #expect(backend.voiceActions == ["on", "off"])
        #expect(!viewModel.isVoiceRecording)
    }

    @Test("transcript cleanup handles RPC failures and still submits speech")
    internal func transcriptCleanupHandlesFailures() async {
        let backend = VoiceBackendSpy()
        backend.failVoiceRecord = true
        backend.failVoiceToggle = true
        let viewModel = ChatViewModel()
        viewModel.setGatewayClient(backend)
        _ = viewModel.beginSwitchToSession(key: "voice-session")

        viewModel.receiveGatewayEventForTesting(
            .voiceTranscript(text: "send this", noSpeechLimit: false),
            sessionID: "voice-session"
        )

        for _ in 0..<100 where backend.submittedPrompts.isEmpty {
            await Task.yield()
        }

        #expect(backend.recordActions == ["stop"])
        #expect(backend.voiceActions == ["off"])
        #expect(backend.submittedPrompts.count == 1)
        #expect(backend.submittedPrompts.first?.sessionID == "voice-session")
        #expect(backend.submittedPrompts.first?.text == "send this")
    }
}
