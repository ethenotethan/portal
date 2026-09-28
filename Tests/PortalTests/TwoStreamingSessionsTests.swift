import Combine
import Foundation
import Testing
@testable import Portal

/// Two sessions with live turns at the same time. Clicking between them must
/// show each session's own transcript — its prompt and the assistant text it
/// has streamed so far — and both turns must keep landing while the user
/// switches. The report: "streaming two sessions at the same time, I click
/// between them but it only shows the content for one session", with the log
/// full of `ignored late live event after stream ended: message.delta`.
@Suite("Two sessions streaming at once")
@MainActor
internal struct TwoStreamingSessionsTests {

    private func complete(_ text: String) -> GatewayEvent {
        .messageComplete(payload: MessageCompletePayload(
            text: text, status: "complete", usage: nil, reasoning: nil, rendered: nil, warning: nil
        ))
    }

    private func delta(_ text: String) -> GatewayEvent {
        .messageDelta(text: text, rendered: nil)
    }

    private func assistantText(_ vm: ChatViewModel) -> String? {
        vm.flushDeltaBuffersForTesting()
        return vm.messages.last { $0.role == .assistant }?.content
    }

    /// Both turns run; the user clicks A → B → A → B. After every switch the
    /// visible transcript is that session's, with everything it streamed so far.
    @Test("switching between two live sessions shows each one's own streaming transcript")
    internal func twoLiveSessionsKeepTheirOwnTranscripts() async {
        let backend = LiveSwitchBackendSpy()
        let vm = ChatViewModel()
        vm.setGatewayClient(backend)
        let sessionA = "a-\(UUID().uuidString)"
        let sessionB = "b-\(UUID().uuidString)"
        // Persisted history lags the live turn: only the prompts are on disk.
        backend.historyBySession[sessionA] = [["role": AnyCodable("user"), "text": AnyCodable("question a")]]
        backend.historyBySession[sessionB] = [["role": AnyCodable("user"), "text": AnyCodable("question b")]]

        // A: resume, turn starts, streams while visible.
        var generation = vm.beginSwitchToSession(key: sessionA)
        #expect(await vm.resumeSession(key: sessionA, generation: generation))
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: sessionA)
        vm.receiveGatewayEventForTesting(delta("a1 "), sessionID: sessionA)
        #expect(assistantText(vm) == "a1 ")

        // B: resume, its turn starts while A keeps streaming in the background.
        generation = vm.beginSwitchToSession(key: sessionB)
        #expect(await vm.resumeSession(key: sessionB, generation: generation))
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: sessionB)
        vm.receiveGatewayEventForTesting(delta("b1 "), sessionID: sessionB)
        vm.receiveGatewayEventForTesting(delta("a2 "), sessionID: sessionA)
        #expect(assistantText(vm) == "b1 ", "B is on screen; A's delta must not appear here")
        #expect(vm.isStreaming)

        // Back to A: its background text is there and it is still live.
        generation = vm.beginSwitchToSession(key: sessionA)
        #expect(await vm.resumeSession(key: sessionA, generation: generation))
        #expect(assistantText(vm) == "a1 a2 ")
        #expect(vm.isStreaming, "A is still streaming")
        #expect(vm.messages.contains { $0.role == .user && $0.content == "question a" })

        // A finishes while B streams on in the background.
        vm.receiveGatewayEventForTesting(delta("b2 "), sessionID: sessionB)
        vm.receiveGatewayEventForTesting(complete("a1 a2 done"), sessionID: sessionA)
        #expect(assistantText(vm) == "a1 a2 done")
        #expect(!vm.isStreaming)
        vm.receiveGatewayEventForTesting(delta("b3 "), sessionID: sessionB)

        // Back to B: nothing of its turn was dropped and it is still live.
        generation = vm.beginSwitchToSession(key: sessionB)
        #expect(await vm.resumeSession(key: sessionB, generation: generation))
        #expect(assistantText(vm) == "b1 b2 b3 ")
        #expect(vm.isStreaming, "B is still streaming")
        #expect(vm.messages.contains { $0.role == .user && $0.content == "question b" })

        // B keeps landing on screen and finishes.
        vm.receiveGatewayEventForTesting(delta("b4 "), sessionID: sessionB)
        #expect(assistantText(vm) == "b1 b2 b3 b4 ")
        vm.receiveGatewayEventForTesting(complete("b1 b2 b3 b4 done"), sessionID: sessionB)
        #expect(assistantText(vm) == "b1 b2 b3 b4 done")
        #expect(!vm.isStreaming)

        // And A's finished answer is intact when we return to it. The gateway has
        // persisted the completed turn by now, so its history carries the answer
        // (a finished session's transcript is reloaded, not kept warm).
        backend.historyBySession[sessionA] = [
            ["role": AnyCodable("user"), "text": AnyCodable("question a")],
            ["role": AnyCodable("assistant"), "text": AnyCodable("a1 a2 done")],
        ]
        generation = vm.beginSwitchToSession(key: sessionA)
        #expect(await vm.resumeSession(key: sessionA, generation: generation))
        #expect(assistantText(vm) == "a1 a2 done")
        #expect(!vm.isStreaming)
    }

    /// The way the user actually gets two live turns: typing a prompt in each.
    /// `submitPrompt` sets the visible session streaming and appends the shell
    /// BEFORE the gateway's `message.start`; that local head start must not make
    /// the other session's frames look late once the user switches away.
    @Test("prompts typed into two sessions stream side by side and survive switching")
    internal func promptsTypedIntoTwoSessions() async {
        let backend = LiveSwitchBackendSpy()
        let vm = ChatViewModel()
        vm.setGatewayClient(backend)
        let sessionA = "a-\(UUID().uuidString)"
        let sessionB = "b-\(UUID().uuidString)"

        var generation = vm.beginSwitchToSession(key: sessionA)
        #expect(await vm.resumeSession(key: sessionA, generation: generation))
        vm.inputText = "question a"
        await vm.submitPrompt()
        #expect(vm.isStreaming)
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: sessionA)
        vm.receiveGatewayEventForTesting(delta("a1 "), sessionID: sessionA)
        #expect(assistantText(vm) == "a1 ")

        generation = vm.beginSwitchToSession(key: sessionB)
        #expect(await vm.resumeSession(key: sessionB, generation: generation))
        #expect(!vm.isStreaming, "B has no turn yet")
        vm.inputText = "question b"
        await vm.submitPrompt()
        #expect(vm.isStreaming)
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: sessionB)
        vm.receiveGatewayEventForTesting(delta("b1 "), sessionID: sessionB)
        vm.receiveGatewayEventForTesting(delta("a2 "), sessionID: sessionA)
        #expect(assistantText(vm) == "b1 ")
        #expect(vm.streamingSessionIDsForTesting.count == 2, "both sessions are live")

        generation = vm.beginSwitchToSession(key: sessionA)
        #expect(await vm.resumeSession(key: sessionA, generation: generation))
        #expect(assistantText(vm) == "a1 a2 ")
        #expect(vm.isStreaming)
        vm.receiveGatewayEventForTesting(delta("b2 "), sessionID: sessionB)
        vm.receiveGatewayEventForTesting(complete("a1 a2 done"), sessionID: sessionA)
        #expect(!vm.isStreaming)
        vm.receiveGatewayEventForTesting(delta("b3 "), sessionID: sessionB)
        #expect(vm.retainedBackgroundTextForTesting(sessionID: sessionB)?.content == "b2 b3 ")

        generation = vm.beginSwitchToSession(key: sessionB)
        #expect(await vm.resumeSession(key: sessionB, generation: generation))
        #expect(assistantText(vm) == "b1 b2 b3 ")
        #expect(vm.isStreaming, "B's turn is still running")
        #expect(vm.messages.contains { $0.role == .user && $0.content == "question b" })
        vm.receiveGatewayEventForTesting(delta("b4 "), sessionID: sessionB)
        #expect(assistantText(vm) == "b1 b2 b3 b4 ")
        vm.receiveGatewayEventForTesting(complete("b1 b2 b3 b4 done"), sessionID: sessionB)
        #expect(!vm.isStreaming)
        #expect(assistantText(vm) == "b1 b2 b3 b4 done")
    }

    /// The mirror: the VISIBLE session finishes first, then the user switches
    /// into the one still running. Its later deltas must not be judged "late".
    @Test("a completed visible turn does not end the other session's live turn")
    internal func completingTheVisibleTurnLeavesTheOtherTurnLive() async {
        let backend = LiveSwitchBackendSpy()
        let vm = ChatViewModel()
        vm.setGatewayClient(backend)
        let sessionA = "a-\(UUID().uuidString)"
        let sessionB = "b-\(UUID().uuidString)"
        backend.historyBySession[sessionA] = [["role": AnyCodable("user"), "text": AnyCodable("question a")]]
        backend.historyBySession[sessionB] = [["role": AnyCodable("user"), "text": AnyCodable("question b")]]

        var generation = vm.beginSwitchToSession(key: sessionB)
        #expect(await vm.resumeSession(key: sessionB, generation: generation))
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: sessionB)
        vm.receiveGatewayEventForTesting(delta("b1 "), sessionID: sessionB)

        generation = vm.beginSwitchToSession(key: sessionA)
        #expect(await vm.resumeSession(key: sessionA, generation: generation))
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: sessionA)
        vm.receiveGatewayEventForTesting(delta("a1 "), sessionID: sessionA)
        vm.receiveGatewayEventForTesting(complete("a1 done"), sessionID: sessionA)
        #expect(assistantText(vm) == "a1 done")
        #expect(!vm.isStreaming)

        // B streams on after A finished; the visible session's end is not B's end.
        vm.receiveGatewayEventForTesting(delta("b2 "), sessionID: sessionB)
        vm.receiveGatewayEventForTesting(.thinkingDelta(text: "still thinking"), sessionID: sessionB)
        #expect(vm.retainedBackgroundTextForTesting(sessionID: sessionB) != nil, "B's deltas were retained, not dropped as late")

        generation = vm.beginSwitchToSession(key: sessionB)
        #expect(await vm.resumeSession(key: sessionB, generation: generation))
        #expect(assistantText(vm) == "b1 b2 ")
        #expect(vm.isStreaming)
        vm.receiveGatewayEventForTesting(delta("b3 "), sessionID: sessionB)
        #expect(assistantText(vm) == "b1 b2 b3 ")
        vm.receiveGatewayEventForTesting(complete("b1 b2 b3 done"), sessionID: sessionB)
        #expect(assistantText(vm) == "b1 b2 b3 done")
        #expect(!vm.isStreaming)
    }

    // MARK: - The log's sequence: a reconnect while both turns run

    /// (a) The socket dropped and came back while A (visible) and B (background)
    /// were both mid-turn. The reconnect reconcile re-resumes and, when the
    /// gateway's reply says nothing is running, force-settles the local shell.
    /// But deltas for BOTH sessions are arriving on the new socket while that
    /// resume is in flight — the turns are demonstrably alive — so settling is
    /// wrong: every later frame is then dropped as "late live event after
    /// stream ended", which is the 260-line signature in the report's log.
    @Test("a reconnect does not settle turns whose deltas are still arriving")
    internal func reconnectKeepsTurnsThatAreStillStreaming() async {
        let backend = LiveSwitchBackendSpy()
        let vm = ChatViewModel()
        vm.setGatewayClient(backend)
        let sessionA = "a-\(UUID().uuidString)"
        let sessionB = "b-\(UUID().uuidString)"
        backend.historyBySession[sessionA] = [["role": AnyCodable("user"), "text": AnyCodable("question a")]]
        backend.historyBySession[sessionB] = [["role": AnyCodable("user"), "text": AnyCodable("question b")]]

        var generation = vm.beginSwitchToSession(key: sessionB)
        #expect(await vm.resumeSession(key: sessionB, generation: generation))
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: sessionB)
        vm.receiveGatewayEventForTesting(delta("b1 "), sessionID: sessionB)

        generation = vm.beginSwitchToSession(key: sessionA)
        #expect(await vm.resumeSession(key: sessionA, generation: generation))
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: sessionA)
        vm.receiveGatewayEventForTesting(delta("a1 "), sessionID: sessionA)
        #expect(vm.streamingSessionIDsForTesting == [sessionA, sessionB])

        // The gateway's reply lags: it reports neither session running, while
        // both keep streaming on the fresh socket during their resume round trips.
        backend.runningBySession[sessionA] = false
        backend.runningBySession[sessionB] = false
        backend.onResume = { key in
            if key == sessionA {
                vm.receiveGatewayEventForTesting(delta("a2 "), sessionID: sessionA)
            }
            if key == sessionB {
                vm.receiveGatewayEventForTesting(delta("b2 "), sessionID: sessionB)
            }
        }
        vm.handleConnectionStateForTesting(.reconnecting(attempt: 1))
        vm.handleConnectionStateForTesting(.connected)
        await vm.reconcileAfterReconnectForTesting()
        backend.onResume = nil

        #expect(vm.isStreaming, "A's turn is still live — its deltas arrived after the reconnect")
        #expect(assistantText(vm) == "a1 a2 ")
        #expect(vm.streamingSessionIDsForTesting == [sessionA, sessionB], "B's background turn is live too")

        // Nothing after the reconnect is judged late.
        vm.receiveGatewayEventForTesting(delta("a3 "), sessionID: sessionA)
        #expect(assistantText(vm) == "a1 a2 a3 ")
        vm.receiveGatewayEventForTesting(delta("b3 "), sessionID: sessionB)
        vm.receiveGatewayEventForTesting(complete("a1 a2 a3 done"), sessionID: sessionA)
        #expect(assistantText(vm) == "a1 a2 a3 done")
        #expect(!vm.isStreaming)

        generation = vm.beginSwitchToSession(key: sessionB)
        #expect(await vm.resumeSession(key: sessionB, generation: generation))
        #expect(assistantText(vm) == "b1 b2 b3 ")
        #expect(vm.isStreaming)
        vm.receiveGatewayEventForTesting(delta("b4 "), sessionID: sessionB)
        #expect(assistantText(vm) == "b1 b2 b3 b4 ")
    }

    /// The reconcile reaches BACKGROUND turns as well as the visible one. B's
    /// socket-lost turn (nothing arrives for it after the reconnect, and the
    /// gateway says it is not running) is settled even though A is on screen;
    /// otherwise B's live dot spins until relaunch. A, which keeps streaming,
    /// is untouched. And the sidebar clicks that follow do not cross the wires:
    /// A's transcript stays A's, B's stays B's.
    @Test("a reconnect settles a background turn the gateway confirms has ended")
    internal func reconnectSettlesOnlyTheOrphanedBackgroundTurn() async {
        let backend = LiveSwitchBackendSpy()
        let vm = ChatViewModel()
        vm.setGatewayClient(backend)
        let sessionA = "a-\(UUID().uuidString)"
        let sessionB = "b-\(UUID().uuidString)"
        backend.historyBySession[sessionA] = [["role": AnyCodable("user"), "text": AnyCodable("question a")]]
        backend.historyBySession[sessionB] = [["role": AnyCodable("user"), "text": AnyCodable("question b")]]

        var generation = vm.beginSwitchToSession(key: sessionB)
        #expect(await vm.resumeSession(key: sessionB, generation: generation))
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: sessionB)
        vm.receiveGatewayEventForTesting(delta("b1 "), sessionID: sessionB)
        generation = vm.beginSwitchToSession(key: sessionA)
        #expect(await vm.resumeSession(key: sessionA, generation: generation))
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: sessionA)
        vm.receiveGatewayEventForTesting(delta("a1 "), sessionID: sessionA)

        backend.runningBySession[sessionA] = false
        backend.runningBySession[sessionB] = false
        backend.onResume = { key in
            if key == sessionA {
                vm.receiveGatewayEventForTesting(delta("a2 "), sessionID: sessionA)
            }
        }
        vm.handleConnectionStateForTesting(.reconnecting(attempt: 1))
        vm.handleConnectionStateForTesting(.connected)
        await vm.reconcileAfterReconnectForTesting()
        backend.onResume = nil

        #expect(Set(backend.resumedKeys.suffix(2)) == [sessionA, sessionB], "both live sessions were reconciled")
        #expect(vm.streamingSessionIDsForTesting == [sessionA])
        #expect(vm.isStreaming)
        #expect(assistantText(vm) == "a1 a2 ")
        // B's shell was stamped in its cache, not left spinning.
        let cachedB = vm.cachedMessagesForTesting(sessionID: sessionB)?.last { $0.role == .assistant }
        #expect(cachedB?.isStreaming == false)
        #expect(cachedB?.status == "interrupted")

        generation = vm.beginSwitchToSession(key: sessionB)
        #expect(await vm.resumeSession(key: sessionB, generation: generation))
        #expect(!vm.isStreaming)
        #expect(vm.messages.contains { $0.role == .user && $0.content == "question b" })
        #expect(vm.messages.contains { $0.content == "a1 a2 " } == false, "A's text must not leak into B")
    }

    // MARK: - Two resumes racing after the reconnect

    /// (b) Exactly the log: the reconnect reconcile resumes A (generation 66);
    /// before the reply lands the user clicks into B and its resume completes
    /// (generation 69); A's reply then comes back stale and is ignored. Three
    /// things must survive that "ignoring stale resume": the visible session
    /// stays B (the reconcile used to overwrite `sessionID` with the gateway's
    /// `activeSessionID`, which A's reply had just set — B's transcript was then
    /// keyed as A and every B delta went to the background), A's runtime↔display
    /// mapping is recorded even though the gateway renamed its runtime id across
    /// the reconnect, and A's later deltas route to A.
    @Test("a stale resume from the reconnect race keeps the visible session and A's routing")
    internal func staleReconnectResumeDoesNotHijackTheVisibleSession() async {
        let backend = LiveSwitchBackendSpy()
        let vm = ChatViewModel()
        vm.setGatewayClient(backend)
        let sessionA = "20260926_154522_13b97a"
        let sessionB = "20260928_000044_9650c7"
        backend.runtimeIDBySession[sessionA] = "rt-a-1"
        backend.runtimeIDBySession[sessionB] = "rt-b"
        backend.historyBySession[sessionA] = [["role": AnyCodable("user"), "text": AnyCodable("question a")]]
        backend.historyBySession[sessionB] = [["role": AnyCodable("user"), "text": AnyCodable("question b")]]

        var generation = vm.beginSwitchToSession(key: sessionA)
        #expect(await vm.resumeSession(key: sessionA, generation: generation))
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: "rt-a-1")
        vm.receiveGatewayEventForTesting(delta("a1 "), sessionID: "rt-a-1")
        #expect(assistantText(vm) == "a1 ")

        // Hold A's reconnect resume in flight.
        let gate = ResumeGate()
        backend.runningBySession[sessionA] = false
        backend.onResume = { key in
            if key == sessionA { await gate.wait() }
        }
        vm.handleConnectionStateForTesting(.reconnecting(attempt: 1))
        vm.handleConnectionStateForTesting(.connected)
        let reconcile = Task { await vm.reconcileAfterReconnectForTesting() }
        await gate.untilWaiting()

        // The user clicks B; its resume is not gated and lands first.
        backend.onResume = nil
        generation = vm.beginSwitchToSession(key: sessionB)
        #expect(await vm.resumeSession(key: sessionB, generation: generation))
        #expect(vm.currentSessionID == "rt-b")
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: "rt-b")
        vm.receiveGatewayEventForTesting(delta("b1 "), sessionID: "rt-b")
        #expect(assistantText(vm) == "b1 ")

        // A's reply arrives, stale, under a renamed runtime id — and A keeps streaming under it.
        backend.runtimeIDBySession[sessionA] = "rt-a-2"
        gate.release()
        await reconcile.value

        #expect(vm.currentSessionID == "rt-b", "the stale reconcile must not re-key the visible session")
        #expect(assistantText(vm) == "b1 ")
        vm.receiveGatewayEventForTesting(delta("b2 "), sessionID: "rt-b")
        #expect(assistantText(vm) == "b1 b2 ", "B is visible and its deltas land on screen")

        vm.receiveGatewayEventForTesting(delta("a2 "), sessionID: "rt-a-2")
        #expect(vm.retainedBackgroundTextForTesting(sessionID: sessionA)?.content == "a2 ", "A's renamed runtime id routes to A")
        #expect(vm.streamingSessionIDsForTesting == [sessionA, sessionB])

        generation = vm.beginSwitchToSession(key: sessionA)
        #expect(await vm.resumeSession(key: sessionA, generation: generation))
        #expect(assistantText(vm) == "a1 a2 ")
        #expect(vm.isStreaming)
        vm.receiveGatewayEventForTesting(complete("a1 a2 done"), sessionID: "rt-a-2")
        #expect(assistantText(vm) == "a1 a2 done")
        #expect(!vm.isStreaming)

        generation = vm.beginSwitchToSession(key: sessionB)
        #expect(await vm.resumeSession(key: sessionB, generation: generation))
        #expect(assistantText(vm) == "b1 b2 ")
        #expect(vm.isStreaming)
    }

    /// The synchronous half of the same race: the user switched sessions while
    /// the socket was down (that resume silently failed), so on reconnect the
    /// gateway's `activeSessionID` names the PREVIOUS session. Adopting it
    /// re-keyed the visible transcript under the other session and the next
    /// snapshot wrote B's messages into A's cache.
    @Test("reconnect does not adopt another session's runtime id as the visible one")
    internal func reconnectKeepsTheVisibleSessionsOwnRuntimeID() async {
        let backend = LiveSwitchBackendSpy()
        let vm = ChatViewModel()
        vm.setGatewayClient(backend)
        let sessionA = "a-\(UUID().uuidString)"
        let sessionB = "b-\(UUID().uuidString)"
        backend.runtimeIDBySession[sessionA] = "rt-a"
        backend.runtimeIDBySession[sessionB] = "rt-b"

        var generation = vm.beginSwitchToSession(key: sessionA)
        #expect(await vm.resumeSession(key: sessionA, generation: generation))
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: "rt-a")
        vm.receiveGatewayEventForTesting(delta("a1 "), sessionID: "rt-a")

        // Click B while the socket is down: the gateway never resumed it.
        backend.connectionState = .reconnecting(attempt: 1)
        vm.handleConnectionStateForTesting(.reconnecting(attempt: 1))
        generation = vm.beginSwitchToSession(key: sessionB)
        #expect(await vm.resumeSession(key: sessionB, generation: generation) == false)
        vm.inputText = "question b"
        backend.connectionState = .connected
        vm.handleConnectionStateForTesting(.connected)
        await vm.reconcileAfterReconnectForTesting()

        #expect(vm.currentSessionID != "rt-a", "B is on screen; A's runtime id must not be adopted")
        #expect(vm.messages.contains { $0.content == "a1 " } == false)
        vm.receiveGatewayEventForTesting(delta("a2 "), sessionID: "rt-a")
        #expect(vm.retainedBackgroundTextForTesting(sessionID: sessionA)?.content == "a2 ")

        generation = vm.beginSwitchToSession(key: sessionA)
        #expect(await vm.resumeSession(key: sessionA, generation: generation))
        #expect(assistantText(vm) == "a1 a2 ")
        #expect(vm.isStreaming)
    }

    // MARK: - message.start for a session whose runtime id is not yet mapped

    /// (c) A turn starts under a runtime id this client has not bound yet — the
    /// resume that would bind it is still in flight when `message.start` and
    /// the first delta arrive. They land in a state keyed by the bare runtime
    /// id. When the resume returns and records the mapping, that shell and its
    /// retained text must move under the display id: otherwise the display
    /// state says "not streaming", every later delta is dropped as late, and
    /// the transcript shows nothing for the running turn.
    @Test("a turn that started before its runtime id was mapped keeps its shell and text")
    internal func turnStartedBeforeMappingIsAdopted() async {
        let backend = LiveSwitchBackendSpy()
        let vm = ChatViewModel()
        vm.setGatewayClient(backend)
        let sessionX = "x-\(UUID().uuidString)"
        backend.runtimeIDBySession[sessionX] = "rt-x"
        backend.historyBySession[sessionX] = [["role": AnyCodable("user"), "text": AnyCodable("question x")]]
        let gate = ResumeGate()
        backend.onResume = { _ in await gate.wait() }

        let generation = vm.beginSwitchToSession(key: sessionX)
        let resume = Task { await vm.resumeSession(key: sessionX, generation: generation) }
        await gate.untilWaiting()
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: "rt-x")
        vm.receiveGatewayEventForTesting(delta("x1 "), sessionID: "rt-x")
        gate.release()
        #expect(await resume.value)

        #expect(vm.currentSessionID == "rt-x")
        #expect(vm.isStreaming, "the turn that began mid-resume is live on screen")
        #expect(assistantText(vm) == "x1 ")
        #expect(vm.messages.contains { $0.role == .user && $0.content == "question x" })
        #expect(vm.streamingSessionIDsForTesting == [sessionX], "no ghost state under the bare runtime id")

        vm.receiveGatewayEventForTesting(delta("x2 "), sessionID: "rt-x")
        #expect(assistantText(vm) == "x1 x2 ")
        vm.receiveGatewayEventForTesting(complete("x1 x2 done"), sessionID: "rt-x")
        #expect(assistantText(vm) == "x1 x2 done")
        #expect(!vm.isStreaming)
    }

    /// The same, but the turn started in the BACKGROUND before this client ever
    /// resumed the session (another device kicked it off). Clicking in resumes
    /// into the running turn; the shell built from the gateway's in-flight
    /// snapshot must be the one and only shell, and the deltas that arrived
    /// under the bare runtime id before the click must not leave a ghost live
    /// dot behind.
    @Test("a background turn started before its first resume is adopted on click-in")
    internal func backgroundTurnBeforeFirstResumeIsAdopted() async {
        let backend = LiveSwitchBackendSpy()
        let vm = ChatViewModel()
        vm.setGatewayClient(backend)
        let sessionX = "x-\(UUID().uuidString)"
        let elsewhere = "elsewhere-\(UUID().uuidString)"
        backend.runtimeIDBySession[sessionX] = "rt-x"
        backend.historyBySession[sessionX] = [["role": AnyCodable("user"), "text": AnyCodable("question x")]]

        var generation = vm.beginSwitchToSession(key: elsewhere)
        #expect(await vm.resumeSession(key: elsewhere, generation: generation))
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: "rt-x")
        vm.receiveGatewayEventForTesting(delta("x1 "), sessionID: "rt-x")

        backend.inflightBySession[sessionX] = InflightTurn(assistantPartial: "x1 ", isStreaming: true)
        generation = vm.beginSwitchToSession(key: sessionX)
        #expect(await vm.resumeSession(key: sessionX, generation: generation))

        #expect(vm.isStreaming)
        #expect(vm.messages.filter { $0.role == .assistant }.count == 1, "one shell, not one per id")
        #expect(assistantText(vm) == "x1 ")
        #expect(vm.streamingSessionIDsForTesting == [sessionX])
        vm.receiveGatewayEventForTesting(delta("x2 "), sessionID: "rt-x")
        #expect(assistantText(vm) == "x1 x2 ")
        vm.receiveGatewayEventForTesting(complete("x1 x2 done"), sessionID: "rt-x")
        #expect(!vm.isStreaming)
    }
}

/// Holds one resume in flight until released, so a test can interleave clicks
/// and live events with a pending `session.resume`.
@MainActor
private final class ResumeGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    internal func wait() async {
        if released { return }
        await withCheckedContinuation { self.continuation = $0 }
    }

    /// Spin the run loop until `wait()` has parked.
    internal func untilWaiting() async {
        while continuation == nil {
            await Task.yield()
        }
    }

    internal func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
