import Combine
import Foundation
import Testing
@testable import Portal

/// Backend spy for the prompt-answer paths: records `clarify.lock` and
/// `approval.respond` calls and answers the lock with a scripted `remaining`.
private final class PromptBackendSpy: AgentBackend {
    internal let eventStream = PassthroughSubject<(GatewayEvent, String?), Never>()
    internal let connectionStatePublisher = Just(GatewayClient.ConnectionState.connected).eraseToAnyPublisher()
    internal let sessionInfoPublisher = Just<SessionInfo?>(nil).eraseToAnyPublisher()
    internal var connectionState: GatewayClient.ConnectionState = .connected
    internal let reconnected = PassthroughSubject<Void, Never>()
    internal var reconnectedPublisher: AnyPublisher<Void, Never> { reconnected.eraseToAnyPublisher() }
    internal let apiKey = ""
    internal var activeSessionID: String?

    internal var runtimeIDBySession: [String: String] = [:]
    internal var remainingAfterLock: [[String]] = []
    private(set) var locks: [(requestID: String, questionID: String, answer: String?)] = []
    private(set) var approvals: [(choice: String, all: Bool, requestID: String?)] = []
    private(set) var legacyClarifyAnswers: [String] = []

    internal func createSession(cols: Int) async throws -> String { "spy-session" }
    internal func resumeSession(key: String) async throws -> (sessionID: String, messages: [[String: AnyCodable]]) {
        let runtimeID = runtimeIDBySession[key] ?? key
        activeSessionID = runtimeID
        return (runtimeID, [])
    }
    internal func sessionHistory(sessionID: String) async throws -> [[String: AnyCodable]] { [] }
    internal func interrupt(sessionID: String) async throws {}
    internal func submitPrompt(sessionID: String, text: String) async throws {}
    internal func respondApproval(sessionID: String, choice: String, all: Bool) async throws {
        approvals.append((choice, all, nil))
    }
    internal func respondApproval(sessionID: String, choice: String, all: Bool, requestID: String?) async throws {
        approvals.append((choice, all, requestID))
    }
    internal func respondClarify(requestID: String, answer: String) async throws {
        legacyClarifyAnswers.append(answer)
    }
    /// When set, the lock parks until the test releases it, so the test can
    /// switch sessions while the answer is in flight. `onLockEntered` fires once
    /// the lock is parked.
    internal var lockParks = false
    internal var onLockEntered: (() -> Void)?
    private var releaseLock: CheckedContinuation<Void, Never>?

    internal func release() {
        releaseLock?.resume()
        releaseLock = nil
    }

    internal func lockClarifyAnswer(requestID: String, questionID: String, answer: String?) async throws -> [String] {
        locks.append((requestID, questionID, answer))
        if lockParks {
            await withCheckedContinuation { continuation in
                releaseLock = continuation
                onLockEntered?()
            }
        }
        return remainingAfterLock.isEmpty ? [] : remainingAfterLock.removeFirst()
    }
    internal func setConfig(key: String, value: String, sessionID: String?) async throws {}
    internal func setEphemeralPrompt(sessionID: String, prompt: String) async throws {}
    internal func setSessionSkills(sessionID: String, skillNames: [String]) async throws {}
    internal func modelOptions(sessionID: String?, refresh: Bool) async throws -> ModelCatalog? { nil }
    internal func uploadFile(data: Data, filename: String, mimeType: String, sessionID: String?) async throws -> String {
        filename
    }
    internal func downloadFile(from url: URL, token: String?) async throws -> Data { Data() }
    internal func attachImage(path: String, sessionID: String?) async throws {}
    internal func voiceToggle(action: String) async throws -> [String: AnyCodable]? { [:] }
    internal func voiceRecord(action: String) async throws {}
    internal func recordDroppedEvent(_ event: GatewayEvent, sessionID: String?, reason: String) {}
}

@Suite("Server→client requests through the chat view model")
@MainActor
internal struct ServerRequestViewModelTests {

    private func clarify(id: String, questions: [(String, String)]) -> ClarifyPayload {
        ClarifyPayload.from(serverRequest: ServerRequest(id: id, method: "clarify", params: [
            "questions": .array(questions.map { .dictionary(["qid": .string($0.0), "question": .string($0.1)]) }),
        ]))
    }

    private func liveSession(_ vm: ChatViewModel, _ backend: PromptBackendSpy, key: String) async -> String {
        let runtimeID = "rt-\(key)"
        backend.runtimeIDBySession[key] = runtimeID
        _ = vm.beginSwitchToSession(key: key)
        _ = await vm.resumeSession(key: key)
        return runtimeID
    }

    @Test("a clarify batch is answered one question at a time and settles when nothing remains")
    internal func clarifyBatchWalksQuestions() async {
        let backend = PromptBackendSpy()
        let vm = ChatViewModel()
        vm.setGatewayClient(backend)
        let runtimeID = await liveSession(vm, backend, key: "clarify-\(UUID().uuidString)")

        vm.receiveGatewayEventForTesting(
            .clarifyRequest(payload: clarify(id: "srq-c", questions: [("q1", "Env?"), ("q2", "Region?")])), sessionID: runtimeID
        )
        #expect(vm.pendingClarify?.questionID == "q1")

        backend.remainingAfterLock = [["q2"], []]
        await vm.respondClarify(answer: "prod")
        #expect(backend.locks.map(\.questionID) == ["q1"])
        #expect(backend.locks.first?.answer == "prod")
        #expect(vm.pendingClarify?.questionID == "q2")
        #expect(vm.pendingClarify?.question == "Region?")

        await vm.respondClarify(answer: "")
        #expect(backend.locks.last?.questionID == "q2")
        #expect(backend.locks.last?.answer == nil)
        #expect(vm.pendingClarify == nil)
        #expect(backend.legacyClarifyAnswers.isEmpty)
    }

    @Test("the next question lands in the session that asked, not the one on screen")
    internal func nextQuestionStaysWithItsSession() async {
        let backend = PromptBackendSpy()
        let vm = ChatViewModel()
        vm.setGatewayClient(backend)
        let asker = await liveSession(vm, backend, key: "asker-\(UUID().uuidString)")
        vm.receiveGatewayEventForTesting(
            .clarifyRequest(payload: clarify(id: "srq-c", questions: [("q1", "A?"), ("q2", "B?")])), sessionID: asker
        )
        backend.remainingAfterLock = [["q2"]]
        backend.lockParks = true
        var parked = false
        backend.onLockEntered = { parked = true }

        let answering = Task { await vm.respondClarify(answer: "yes") }
        while !parked {
            await Task.yield()
        }
        #expect(backend.locks.count == 1, "the answer is in flight before the switch")
        let other = await liveSession(vm, backend, key: "other-\(UUID().uuidString)")
        backend.release()
        await answering.value

        #expect(vm.pendingClarify == nil, "the other session has no question of its own")
        #expect(vm.currentSessionID == other)
        _ = await liveSession(vm, backend, key: String(asker.dropFirst(3)))
        #expect(vm.pendingClarify?.questionID == "q2")
    }

    @Test("request.cancel clears the clarify on screen and removes the approval wherever it sits")
    internal func cancellationClosesPrompts() async {
        let backend = PromptBackendSpy()
        let vm = ChatViewModel()
        vm.setGatewayClient(backend)
        let runtimeID = await liveSession(vm, backend, key: "cancel-\(UUID().uuidString)")

        vm.receiveGatewayEventForTesting(.clarifyRequest(payload: clarify(id: "srq-c", questions: [("q1", "A?")])), sessionID: runtimeID)
        vm.receiveGatewayEventForTesting(.approvalRequest(payload: ApprovalPayload(command: "one", sessionKey: "k", requestID: "srq-1")), sessionID: runtimeID)
        vm.receiveGatewayEventForTesting(.approvalRequest(payload: ApprovalPayload(command: "two", sessionKey: "k", requestID: "srq-2")), sessionID: runtimeID)
        #expect(vm.approvalQueue.count == 2)

        vm.receiveGatewayEventForTesting(.requestCancelled(id: "srq-2", method: "approval", reason: "resolved"), sessionID: runtimeID)
        vm.receiveGatewayEventForTesting(.requestCancelled(id: "srq-c", method: "clarify", reason: "interrupted"), sessionID: runtimeID)
        #expect(vm.approvalQueue.entries.map(\.command) == ["one"])
        #expect(vm.pendingClarify == nil)
    }

    @Test("an approval is answered by its own id, and the same request replayed is shown once")
    internal func approvalAnsweredExactly() async {
        let backend = PromptBackendSpy()
        let vm = ChatViewModel()
        vm.setGatewayClient(backend)
        let runtimeID = await liveSession(vm, backend, key: "approve-\(UUID().uuidString)")
        let payload = ApprovalPayload(command: "deploy", sessionKey: "k", requestID: "srq-a", approvalID: "apr-7")
        vm.receiveGatewayEventForTesting(.approvalRequest(payload: payload), sessionID: runtimeID)
        vm.receiveGatewayEventForTesting(.approvalRequest(payload: payload), sessionID: runtimeID)
        #expect(vm.approvalQueue.count == 1)

        await vm.respondApproval(choice: "once")
        #expect(backend.approvals.count == 1)
        #expect(backend.approvals.first?.requestID == "apr-7")
        #expect(backend.approvals.first?.all == false)
        #expect(vm.approvalQueue.isEmpty)
    }
}
