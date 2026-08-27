import Combine
import Foundation
import Testing
@testable import Portal

/// Clicking away from a live session and back mid-turn lost the turn: the
/// thinking text and the streamed answer were gone, and everything the agent did
/// from that moment on never appeared either. It looked frozen on whatever
/// thought was on screen when the user left.
///
/// Two cuts, both in `ChatViewModel`, and they compound:
///
///  1. **Nothing kept the background text.** `applySessionEvent` drops
///     `messageDelta` / `reasoningDelta` / `thinkingDelta` for sessions that
///     aren't on screen, because appending to `state.messages[idx]` copy-on-write
///     clones the whole transcript per token. The comment said state is "re-synced
///     via the session.resume RPC" — but that RPC returns the gateway's PERSISTED
///     history, which by definition excludes the turn still running. So the
///     re-sync recovered only what had already been committed. Reasoning was
///     worse than stale: the gateway accumulates assistant message deltas for its
///     in-flight snapshot but not thinking, so a dropped thinking token was
///     unrecoverable anywhere. Deltas are now retained in a capped side buffer —
///     a String append per token, no array touch — and spliced in on switch-back.
///
///  2. **The resume then deleted the live shell.** Because (1) guaranteed the
///     cached assistant placeholder was empty, `resumeSession`'s staleness escape
///     hatch always fired and replaced the transcript with parsed history. That
///     dropped the message `streamingMessageID` names, and every remaining delta
///     plus the terminal `message.complete` finds its message by that id — so the
///     rest of the turn, its tool stamps and its final answer were all discarded.
///     This is the same family as the latches in `StuckStreamRecoveryTests`
///     (eviction destroying a live shell); here it was the resume that did it.
@Suite("Live session switch-back")
@MainActor
internal struct LiveSessionSwitchBackTests {

    private func complete(_ text: String, reasoning: String? = nil) -> GatewayEvent {
        .messageComplete(payload: MessageCompletePayload(
            text: text,
            status: "complete",
            usage: nil,
            reasoning: reasoning,
            rendered: nil,
            warning: nil
        ))
    }

    /// Start a turn on `live`, then leave for another session.
    private func startTurnAndLeave(_ vm: ChatViewModel, live: String) {
        _ = vm.beginSwitchToSession(key: live)
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: live)
        _ = vm.beginSwitchToSession(key: "elsewhere-\(UUID().uuidString)")
    }

    // MARK: - 1. Retaining what streamed off screen

    /// The user's report, end to end: the thinking and the partial answer that
    /// streamed while they were away are on screen when they come back.
    @Test("switching back mid-turn shows the thinking and answer streamed while away")
    internal func switchBackShowsBackgroundStream() {
        let vm = ChatViewModel()
        let live = "live-\(UUID().uuidString)"
        startTurnAndLeave(vm, live: live)

        vm.receiveGatewayEventForTesting(.thinkingDelta(text: "weighing the options"), sessionID: live)
        vm.receiveGatewayEventForTesting(.reasoningDelta(text: " then deciding"), sessionID: live)
        vm.receiveGatewayEventForTesting(
            .messageDelta(text: "Here is what I found", rendered: nil),
            sessionID: live
        )

        _ = vm.beginSwitchToSession(key: live)

        let assistant = vm.messages.last { $0.role == .assistant }
        #expect(assistant?.isStreaming == true)
        #expect(assistant?.content == "Here is what I found")
        #expect(assistant?.reasoning?.contains("weighing the options") == true)
        #expect(assistant?.reasoning?.contains("then deciding") == true)
        // Consumed, not merely copied: a second switch must not double it.
        #expect(vm.retainedBackgroundTextForTesting(sessionID: live) == nil)
    }

    /// The buffer only exists to bridge the gap, so it must be spliced onto the
    /// live shell rather than replacing it — the user may have watched the turn
    /// start, left mid-answer, and returned.
    @Test("retained text appends to what already streamed while visible")
    internal func retainedTextAppendsRatherThanReplaces() {
        let vm = ChatViewModel()
        let live = "live-append-\(UUID().uuidString)"
        _ = vm.beginSwitchToSession(key: live)
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: live)
        vm.receiveGatewayEventForTesting(.messageDelta(text: "first ", rendered: nil), sessionID: live)
        vm.flushDeltaBuffersForTesting()

        _ = vm.beginSwitchToSession(key: "elsewhere-\(UUID().uuidString)")
        vm.receiveGatewayEventForTesting(.messageDelta(text: "second", rendered: nil), sessionID: live)
        _ = vm.beginSwitchToSession(key: live)

        #expect(vm.messages.last { $0.role == .assistant }?.content == "first second")
    }

    /// Retention must not become a leak: a background turn can think for a very
    /// long time. The head is trimmed and the splice marks the gap — safe because
    /// `message.complete` still carries the full trace.
    @Test("retained thinking is capped and the trim is marked")
    internal func retainedThinkingIsCapped() {
        let vm = ChatViewModel()
        let live = "live-cap-\(UUID().uuidString)"
        startTurnAndLeave(vm, live: live)

        let chunk = String(repeating: "t", count: 4_000)
        for _ in 0..<40 {
            vm.receiveGatewayEventForTesting(.thinkingDelta(text: chunk), sessionID: live)
        }
        let retained = vm.retainedBackgroundTextForTesting(sessionID: live)
        #expect(retained != nil)
        #expect((retained?.thoughts.count ?? 0) <= 64_000)
        #expect((retained?.thoughts.count ?? 0) > 0)

        _ = vm.beginSwitchToSession(key: live)
        #expect(vm.messages.last { $0.role == .assistant }?.reasoning?.hasPrefix("…") == true)
    }

    /// The completion payload is the authoritative turn, so the retained text
    /// must not be added on top of it.
    @Test("the completion supersedes retained text instead of doubling it")
    internal func completionSupersedesRetainedText() {
        let vm = ChatViewModel()
        let live = "live-complete-\(UUID().uuidString)"
        startTurnAndLeave(vm, live: live)

        vm.receiveGatewayEventForTesting(.messageDelta(text: "Here is ", rendered: nil), sessionID: live)
        _ = vm.beginSwitchToSession(key: live)
        vm.receiveGatewayEventForTesting(complete("Here is the whole answer"), sessionID: live)

        #expect(vm.messages.last { $0.role == .assistant }?.content == "Here is the whole answer")
        #expect(vm.retainedBackgroundTextForTesting(sessionID: live) == nil)
    }

    /// A turn that dies without being adopted (an error, a stop) leaves text in
    /// the buffer. The next turn's fresh shell must not inherit it, or the
    /// previous answer's tail is grafted onto the new one.
    @Test("a new turn does not inherit the previous turn's retained text")
    internal func newTurnDoesNotInheritRetainedText() {
        let vm = ChatViewModel()
        let live = "live-stale-\(UUID().uuidString)"
        startTurnAndLeave(vm, live: live)

        vm.receiveGatewayEventForTesting(.messageDelta(text: "abandoned text", rendered: nil), sessionID: live)
        vm.receiveGatewayEventForTesting(.error(message: "upstream died"), sessionID: live)
        #expect(vm.retainedBackgroundTextForTesting(sessionID: live) != nil)

        vm.receiveGatewayEventForTesting(.messageStart, sessionID: live)
        #expect(vm.retainedBackgroundTextForTesting(sessionID: live) == nil)

        _ = vm.beginSwitchToSession(key: live)
        #expect(vm.messages.last { $0.role == .assistant }?.content.contains("abandoned") == false)
    }

    /// Retention is per session: two background turns must not pool their text.
    @Test("two background turns keep their text separate")
    internal func retentionIsPerSession() {
        let vm = ChatViewModel()
        let first = "live-a-\(UUID().uuidString)"
        let second = "live-b-\(UUID().uuidString)"
        _ = vm.beginSwitchToSession(key: first)
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: first)
        _ = vm.beginSwitchToSession(key: second)
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: second)
        _ = vm.beginSwitchToSession(key: "elsewhere-\(UUID().uuidString)")

        vm.receiveGatewayEventForTesting(.messageDelta(text: "from A", rendered: nil), sessionID: first)
        vm.receiveGatewayEventForTesting(.messageDelta(text: "from B", rendered: nil), sessionID: second)

        _ = vm.beginSwitchToSession(key: first)
        #expect(vm.messages.last { $0.role == .assistant }?.content == "from A")
        _ = vm.beginSwitchToSession(key: second)
        #expect(vm.messages.last { $0.role == .assistant }?.content == "from B")
    }

    /// Tool cards are driven by `activeToolCalls`, which a background turn does
    /// keep — but they render against a live turn, and the turn's final message
    /// is where they are stamped. Both must survive the round trip.
    @Test("tool calls started off screen are present on switch-back")
    internal func backgroundToolCallsSurviveSwitchBack() {
        let vm = ChatViewModel()
        let live = "live-tools-\(UUID().uuidString)"
        startTurnAndLeave(vm, live: live)

        vm.receiveGatewayEventForTesting(
            .toolStart(payload: ToolStartPayload(toolID: "t1", name: "bash", context: "ls")),
            sessionID: live
        )
        _ = vm.beginSwitchToSession(key: live)

        #expect(vm.isStreaming)
        #expect(vm.activeToolCalls["t1"]?.name == "bash")

        vm.receiveGatewayEventForTesting(complete("done"), sessionID: live)
        #expect(vm.messages.last { $0.role == .assistant }?.toolCalls.contains { $0.id == "t1" } == true)
    }

    // MARK: - 2. Carrying the live turn across the resume

    /// `resumeSession` splices this onto the gateway's persisted history. The
    /// shell must come back with a stable identity, or `streamingMessageID` is
    /// orphaned and the rest of the turn is dropped.
    @Test("the live turn tail keeps the streaming shell and its prompt")
    internal func liveTurnTailKeepsShellAndPrompt() {
        let shell = ChatMessage(role: .assistant, content: "", isStreaming: true)
        let cached = [
            ChatMessage(role: .user, content: "old question"),
            ChatMessage(role: .assistant, content: "old answer"),
            ChatMessage(role: .user, content: "new question"),
            shell
        ]

        let tail = ChatViewModel.liveTurnTail(of: cached, streamingID: shell.id)
        #expect(tail.count == 2)
        #expect(tail.first?.content == "new question")
        #expect(tail.last?.id == shell.id)
    }

    /// No shell means there is no live turn to carry, and the caller falls back
    /// to plain history.
    @Test("no streaming shell yields no tail")
    internal func noShellYieldsNoTail() {
        let messages = [ChatMessage(role: .user, content: "q"), ChatMessage(role: .assistant, content: "a")]
        #expect(ChatViewModel.liveTurnTail(of: messages, streamingID: nil).isEmpty)
        #expect(ChatViewModel.liveTurnTail(of: messages, streamingID: UUID()).isEmpty)
        #expect(ChatViewModel.liveTurnTail(of: [], streamingID: UUID()).isEmpty)
    }

    /// The whole point: after splicing, the id the deltas and the completion look
    /// up is still in the transcript.
    @Test("splicing the tail onto resumed history preserves the shell's identity")
    internal func splicedTailPreservesShellIdentity() {
        let shell = ChatMessage(role: .assistant, content: "", isStreaming: true)
        let cached = [ChatMessage(role: .user, content: "live question"), shell]
        let history = [
            ChatMessage(role: .user, content: "old question"),
            ChatMessage(role: .assistant, content: "old answer")
        ]

        let tail = ChatViewModel.liveTurnTail(of: cached, streamingID: shell.id)
        let merged = ChatViewModel.appendLiveTurnTail(tail, to: history)

        #expect(merged.count == 4)
        #expect(merged.contains { $0.id == shell.id })
        #expect(merged.last?.isStreaming == true)
    }

    /// The gateway usually persists the prompt as soon as the turn starts, so the
    /// tail's leading user bubble is often already history's last entry.
    @Test("a duplicated prompt is not shown twice")
    internal func duplicatedPromptIsDropped() {
        let shell = ChatMessage(role: .assistant, content: "", isStreaming: true)
        let prompt = ChatMessage(role: .user, content: "live question")
        let merged = ChatViewModel.appendLiveTurnTail(
            [prompt, shell],
            to: [ChatMessage(role: .user, content: "live question")]
        )

        #expect(merged.count == 2)
        #expect(merged.filter { $0.role == .user }.count == 1)
        #expect(merged.last?.id == shell.id)

        // A genuinely different prompt is kept.
        let distinct = ChatViewModel.appendLiveTurnTail(
            [prompt, shell],
            to: [ChatMessage(role: .user, content: "a different question")]
        )
        #expect(distinct.filter { $0.role == .user }.count == 2)
    }

    /// The two halves together, through the real switch-back path: a turn that
    /// has only been THINKING so far is the exact case that used to break, since
    /// an empty `content` is what made `resumeSession` judge the live state stale
    /// and overwrite it with history that cannot contain the running turn.
    @Test("a resume mid-thought keeps the live turn and the rest of it lands")
    internal func resumeMidThoughtKeepsTheLiveTurn() async {
        let backend = LiveSwitchBackendSpy()
        let vm = ChatViewModel()
        vm.setGatewayClient(backend)
        let live = "live-resume-\(UUID().uuidString)"
        // Persisted history: the previous turn only. The gateway cannot return
        // the turn still running.
        backend.historyBySession[live] = [
            ["role": AnyCodable("user"), "text": AnyCodable("earlier question")],
            ["role": AnyCodable("assistant"), "text": AnyCodable("earlier answer")]
        ]

        _ = vm.beginSwitchToSession(key: live)
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: live)
        _ = vm.beginSwitchToSession(key: "elsewhere-\(UUID().uuidString)")
        vm.receiveGatewayEventForTesting(.thinkingDelta(text: "still working it out"), sessionID: live)

        let generation = vm.beginSwitchToSession(key: live)
        let resumed = await vm.resumeSession(key: live, generation: generation)
        #expect(resumed)

        // History is there AND the live turn survived it.
        #expect(vm.messages.contains { $0.content == "earlier answer" })
        let shell = vm.messages.last { $0.role == .assistant }
        #expect(shell?.isStreaming == true)
        #expect(shell?.reasoning?.contains("still working it out") == true)

        // The real damage was downstream: with the shell gone, `streamingMessageID`
        // pointed at nothing and everything after the resume was dropped.
        vm.receiveGatewayEventForTesting(.messageDelta(text: "the answer", rendered: nil), sessionID: live)
        vm.flushDeltaBuffersForTesting()
        #expect(vm.messages.last { $0.role == .assistant }?.content == "the answer")

        vm.receiveGatewayEventForTesting(complete("the whole answer"), sessionID: live)
        #expect(vm.messages.last { $0.role == .assistant }?.content == "the whole answer")
        #expect(!vm.isStreaming)
    }
}

/// Minimal backend whose `session.resume` returns a persisted history that — like
/// the real gateway's — does not contain the turn still in flight.
@MainActor
private final class LiveSwitchBackendSpy: AgentBackend {
    internal let eventStream = PassthroughSubject<(GatewayEvent, String?), Never>()
    internal let connectionStatePublisher = Just(GatewayClient.ConnectionState.connected).eraseToAnyPublisher()
    internal let sessionInfoPublisher = Just<SessionInfo?>(nil).eraseToAnyPublisher()
    internal var connectionState: GatewayClient.ConnectionState = .connected
    internal var onReconnected: (() async -> Void)?
    internal let apiKey = ""
    internal var activeSessionID: String?
    internal let capabilities = BackendCapabilities.hermes

    internal var historyBySession: [String: [[String: AnyCodable]]] = [:]

    internal func modelOptions(sessionID: String?, refresh: Bool) async throws -> ModelCatalog? { nil }
    internal func createSession(cols: Int) async throws -> String { "spy-session" }
    internal func resumeSession(key: String) async throws -> (sessionID: String, messages: [[String: AnyCodable]]) {
        activeSessionID = key
        return (key, historyBySession[key] ?? [])
    }
    internal func sessionHistory(sessionID: String) async throws -> [[String: AnyCodable]] { [] }
    internal func interrupt(sessionID: String) async throws {}
    internal func submitPrompt(sessionID: String, text: String) async throws {}
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
