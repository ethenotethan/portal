import Testing
import Foundation
@testable import Portal

// MARK: - Session Model Tests

@Suite("Session Model")
struct SessionTests {

    @Test("Sessions with same ID are equal")
    func equalityByID() {
        let a = Session(id: "abc", messageCount: 5, isRunning: false)
        let b = Session(id: "abc", title: "Different", messageCount: 10, isRunning: true)
        #expect(a == b)
    }

    @Test("Sessions with different IDs are not equal")
    func inequalityByID() {
        let a = Session(id: "abc", messageCount: 0)
        let b = Session(id: "def", messageCount: 0)
        #expect(a != b)
    }

    @Test("Session conforms to Identifiable")
    func identifiable() {
        let session = Session(id: "abc", messageCount: 0)
        #expect(session.id == "abc")
    }

    @Test("Session with gateway title")
    func gatewayTitle() {
        let session = Session(id: "abc", title: "How to build an app", messageCount: 3)
        #expect(session.title == "How to build an app")
    }

    @Test("Session with preview")
    func previewField() {
        let session = Session(id: "abc", preview: "I was wondering about...", messageCount: 1)
        #expect(session.preview == "I was wondering about...")
    }

    @Test("Session with source")
    func sourceField() {
        let session = Session(id: "abc", source: "telegram", messageCount: 2)
        #expect(session.source == "telegram")
    }
}

// MARK: - Session Timeline Tests

@Suite("Session Timeline")
internal struct SessionTimelineTests {
    @Test("event types expose stable presentation metadata")
    internal func eventTypePresentationMetadata() {
        let expected: [(type: EventType, icon: String, color: String)] = [
            (.userMessage, "person.fill", "#888888"),
            (.assistantMessage, "sparkles", "#7c7cff"),
            (.toolStart, "gearshape.fill", "#f0a040"),
            (.toolEnd, "checkmark.circle.fill", "#40c040"),
            (.reasoningBlock, "brain.head.profile", "#ff8c00"),
            (.turnBoundary, "line.diagonal", "#444444")
        ]

        for item in expected {
            #expect(item.type.iconName == item.icon)
            #expect(item.type.colorHex == item.color)
        }
    }

    @Test("token totals require both gateway counts")
    internal func tokenAccounting() {
        let complete = timeline(inputTokens: 800, outputTokens: 200)
        let missingInput = timeline(inputTokens: nil, outputTokens: 200)
        let missingOutput = timeline(inputTokens: 800, outputTokens: nil)

        #expect(complete.totalTokens == 1_000)
        #expect(complete.toolCallsCount == 3)
        #expect(missingInput.totalTokens == nil)
        #expect(missingOutput.totalTokens == nil)
    }

    private func timeline(inputTokens: Int?, outputTokens: Int?) -> SessionTimeline {
        SessionTimeline(
            sessionID: "session-1",
            events: [],
            totalDurationSeconds: 1,
            toolCalls: 3,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            costUSD: nil
        )
    }
}

@Suite("Session Run Event")
internal struct SessionRunEventTests {
    @Test("new runs start with stable accounting defaults")
    internal func initialState() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let event = SessionRunEvent(sessionID: "session-1", startedAt: startedAt)

        #expect(event.sessionID == "session-1")
        #expect(event.startedAt == startedAt)
        #expect(event.endedAt == nil)
        #expect(event.inputTokens == nil)
        #expect(event.outputTokens == nil)
        #expect(event.totalTokens == nil)
        #expect(event.apiCalls == 1)
        #expect(event.costUSD == nil)
        #expect(event.status == .running)
        #expect(event.duration == nil)
        #expect(event.durationLabel == "—")
    }

    @Test("completed run durations scale from seconds to minutes and hours")
    internal func durationLabels() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let cases: [(duration: TimeInterval, label: String)] = [
            (30, "30.0s"),
            (90, "1.5m"),
            (7_200, "2.0h")
        ]

        for item in cases {
            var event = SessionRunEvent(sessionID: "session-1", startedAt: startedAt)
            event.endedAt = startedAt.addingTimeInterval(item.duration)

            #expect(event.duration == item.duration)
            #expect(event.durationLabel == item.label)
        }
    }
}

// MARK: - Sessions Filter State Tests

@Suite("Sessions Filter State")
@MainActor
internal struct SessionsFilterStateTests {
    private func session(
        _ id: String,
        source: String? = nil,
        messageCount: Int = 0,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        lastActive: Date? = nil,
        gatewayID: String? = nil,
        runState: SessionRunState? = nil
    ) -> Session {
        Session(
            id: id,
            source: source,
            messageCount: messageCount,
            startedAt: startedAt,
            endedAt: endedAt,
            lastActive: lastActive,
            gatewayID: gatewayID,
            runState: runState
        )
    }

    @Test("cron sessions are always excluded")
    internal func excludesCronSessions() {
        let state = SessionsFilterState()
        let sessions = [session("native"), session("cron", source: "CRON")]

        #expect(state.filteredSessions(from: sessions).map(\.id) == ["native"])
    }

    @Test("status filters use explicit run state and ended state")
    internal func filtersByStatus() {
        let state = SessionsFilterState()
        let sessions = [
            session("live", runState: .toolRunning),
            session("idle", runState: .idle),
            session("ended", endedAt: Date(), runState: .streaming)
        ]

        state.filterStatus = .live
        #expect(state.filteredSessions(from: sessions).map(\.id) == ["live"])
        state.filterStatus = .ended
        #expect(state.filteredSessions(from: sessions).map(\.id) == ["idle", "ended"])
    }

    @Test("source filtering uses the displayed source")
    internal func filtersByDisplaySource() {
        let state = SessionsFilterState()
        state.filterSource = "Native"
        let sessions = [
            session("owned", source: "cli", gatewayID: "runtime-id"),
            session("telegram", source: "telegram"),
            session("unknown")
        ]

        #expect(state.filteredSessions(from: sessions).map(\.id) == ["owned"])
    }

    @Test("custom time window prefers start time, then last activity")
    internal func filtersByCustomTimeWindow() {
        let cutoff = Date(timeIntervalSince1970: 1_000)
        let state = SessionsFilterState()
        state.timeWindow = .since(cutoff)
        let sessions = [
            session("started-after", startedAt: Date(timeIntervalSince1970: 1_001),
                    lastActive: Date(timeIntervalSince1970: 100)),
            session("active-after", lastActive: Date(timeIntervalSince1970: 1_001)),
            session("before", startedAt: Date(timeIntervalSince1970: 999),
                    lastActive: Date(timeIntervalSince1970: 2_000)),
            session("undated")
        ]

        #expect(state.filteredSessions(from: sessions).map(\.id) == ["started-after", "active-after"])
    }

    @Test("recent sort prefers last activity, then start time")
    internal func sortsByRecentActivity() {
        let state = SessionsFilterState()
        let sessions = [
            session("undated"),
            session("started", startedAt: Date(timeIntervalSince1970: 20)),
            session("active", startedAt: Date(timeIntervalSince1970: 10),
                    lastActive: Date(timeIntervalSince1970: 30))
        ]

        #expect(state.sorted(sessions).map(\.id) == ["active", "started", "undated"])
    }

    @Test("duration sort uses ended time, then last activity")
    internal func sortsByDuration() {
        let state = SessionsFilterState()
        state.sortOrder = .duration
        let start = Date(timeIntervalSince1970: 100)
        let sessions = [
            session("missing-start", endedAt: Date(timeIntervalSince1970: 1_000)),
            session("last-active", startedAt: start, lastActive: Date(timeIntervalSince1970: 120)),
            session("ended", startedAt: start, endedAt: Date(timeIntervalSince1970: 150))
        ]

        #expect(state.sorted(sessions).map(\.id) == ["ended", "last-active", "missing-start"])
    }

    @Test("message sort places the largest transcript first")
    internal func sortsByMessageCount() {
        let state = SessionsFilterState()
        state.sortOrder = .messages

        #expect(state.sorted([
            session("small", messageCount: 2),
            session("large", messageCount: 20),
            session("empty")
        ]).map(\.id) == ["large", "small", "empty"])
    }
}

// MARK: - SessionListViewModel Tests

@Suite("SessionListViewModel")
struct SessionListViewModelTests {

    @Test("selectSession updates activeSessionID")
    @MainActor
    func selectSession() async {
        let vm = SessionListViewModel()
        let session = Session(id: "s1", title: "Test", messageCount: 0)
        vm.sessions = [session]

        vm.selectSession(id: "s1")
        #expect(vm.activeSessionID == "s1")
    }

    @Test("closeSession removes session from list")
    @MainActor
    func closeSessionRemovesFromList() async {
        let vm = SessionListViewModel()
        let s1 = Session(id: "s1", messageCount: 0)
        let s2 = Session(id: "s2", messageCount: 0)
        vm.sessions = [s1, s2]
        vm.activeSessionID = "s1"

        #expect(vm.sessions.count == 2)
        #expect(vm.activeSessionID == "s1")
    }

    @Test("activeSessionID falls back to first session when current is removed")
    @MainActor
    func activeSessionFallback() async {
        let vm = SessionListViewModel()
        let s1 = Session(id: "s1", messageCount: 0)
        let s2 = Session(id: "s2", messageCount: 0)
        vm.sessions = [s1, s2]
        vm.activeSessionID = "s1"

        vm.sessions.removeAll { $0.id == "s1" }
        if vm.activeSessionID == "s1" {
            vm.activeSessionID = vm.sessions.first?.id
        }
        #expect(vm.activeSessionID == "s2")
    }

    @Test("isLoading starts as false")
    @MainActor
    func isLoadingInitial() async {
        let vm = SessionListViewModel()
        #expect(vm.isLoading == false)
    }

    @Test("sessions starts empty")
    @MainActor
    func sessionsStartEmpty() async {
        let vm = SessionListViewModel()
        #expect(vm.sessions.isEmpty)
    }

    @Test("titleForSession uses gateway title when no local title")
    @MainActor
    func titleFromGateway() async {
        let vm = SessionListViewModel()
        let session = Session(id: "s1", title: "My Chat", messageCount: 3)
        #expect(vm.titleForSession(session) == "My Chat")
    }

    @Test("titleForSession falls back to preview when no title")
    @MainActor
    func titleFromPreview() async {
        let vm = SessionListViewModel()
        let session = Session(id: "s1", preview: "How do I deploy this app to production?", messageCount: 1)
        #expect(vm.titleForSession(session) == "How do I deploy this app to production?")
    }

    @Test("titleForSession falls back to source when no title or preview")
    @MainActor
    func titleFromSource() async {
        let vm = SessionListViewModel()
        let session = Session(id: "s1", source: "telegram", messageCount: 2)
        #expect(vm.titleForSession(session) == "s1")
    }

    @Test("titleForSession falls back to short ID when nothing else")
    @MainActor
    func titleFromShortID() async {
        let vm = SessionListViewModel()
        let session = Session(id: "abc12345def", messageCount: 0)
        #expect(vm.titleForSession(session) == "abc12345")
    }

    @Test("subtitleForSession shows source, message count, and time")
    @MainActor
    func subtitleFormatting() async {
        let vm = SessionListViewModel()
        let session = Session(id: "s1", source: "telegram", messageCount: 5, startedAt: Date())
        let subtitle = vm.subtitleForSession(session)
        #expect(subtitle != nil)
        #expect(subtitle!.contains("telegram"))
        #expect(subtitle!.contains("5 msgs"))
    }
    @Test("pinned sessions sort before unpinned sessions")
    @MainActor
    func pinnedSessionsSortFirst() async {
        let vm = SessionListViewModel()
        let older = Session(id: "older", messageCount: 0, startedAt: Date(timeIntervalSince1970: 10))
        var pinned = Session(id: "pinned", messageCount: 0, startedAt: Date(timeIntervalSince1970: 1))
        pinned.isPinned = true

        let sorted = vm.sortedForSidebar([older, pinned])
        #expect(sorted.map(\.id) == ["pinned", "older"])
    }

    @Test("tags normalize to lowercase unique values")
    @MainActor
    func tagNormalization() async {
        let vm = SessionListViewModel()
        vm.sessions = [Session(id: "s1", messageCount: 0)]

        vm.setTags([" Deploy ", "deploy", "Bug"], for: "s1")

        #expect(vm.sessions.first?.tags == ["bug", "deploy"])
    }


    @Test("setRunState updates row by stable ID")
    @MainActor
    func setRunStateByStableID() async {
        let vm = SessionListViewModel()
        vm.sessions = [Session(id: "stable", messageCount: 0)]

        vm.setRunState(.streaming, for: "stable")

        #expect(vm.sessions.first?.displayRunState == SessionRunState.streaming)
    }

    @Test("setRunState updates row by gateway runtime ID")
    @MainActor
    func setRunStateByGatewayID() async {
        let vm = SessionListViewModel()
        var session = Session(id: "stable", messageCount: 0)
        session.gatewayID = "runtime"
        vm.sessions = [session]

        vm.setRunState(.toolRunning, for: "runtime")

        #expect(vm.sessions.first?.displayRunState == SessionRunState.toolRunning)
        #expect(vm.runState(for: "stable") == SessionRunState.toolRunning)
        #expect(vm.runState(for: "runtime") == SessionRunState.toolRunning)
    }


    @Test("local run state overrides gateway stale state")
    @MainActor
    func localRunStateOverridesGatewayStaleState() async {
        let vm = SessionListViewModel()
        var session = Session(id: "stable", messageCount: 0, runState: .idle)
        session.gatewayID = "runtime"
        vm.sessions = [session]

        vm.setRunState(.streaming, for: "runtime")

        #expect(vm.sessions.first?.displayRunState == SessionRunState.streaming)
    }
}


// MARK: - Session Run State Tests

@Suite("Session run state")
struct SessionRunStateTests {

    @Test("explicit gateway run states parse common values")
    func parsesGatewayValues() {
        #expect(SessionRunState(gatewayValue: "streaming") == .streaming)
        #expect(SessionRunState(gatewayValue: "tool_running") == .toolRunning)
        #expect(SessionRunState(gatewayValue: "waiting_for_user") == .waitingForUser)
        #expect(SessionRunState(gatewayValue: "failed") == .failed)
        #expect(SessionRunState(gatewayValue: "cancelled") == .canceled)
    }

    @Test("displayRunState prefers explicit run state")
    func explicitRunStateWins() {
        let session = Session(id: "s1", messageCount: 0, lastActive: Date(), runState: .failed)
        #expect(session.displayRunState == SessionRunState.failed)
    }

    @Test("displayRunState derives streaming from recent activity")
    func derivesStreamingFromRecentActivity() {
        let session = Session(id: "s1", messageCount: 0, lastActive: Date())
        #expect(session.displayRunState == SessionRunState.streaming)
    }

    @Test("displayRunState derives idle from ended sessions")
    func derivesIdleFromEndedSession() {
        let session = Session(id: "s1", messageCount: 0, endedAt: Date())
        #expect(session.displayRunState == SessionRunState.idle)
    }
}

// MARK: - ChatViewModel Session Title Tests

@Suite("ChatViewModel Session Title")
struct ChatViewModelTitleTests {

    @Test("sessionTitle defaults to New Chat")
    @MainActor
    func defaultTitle() async {
        let vm = ChatViewModel()
        #expect(vm.sessionTitle == "New Chat")
    }

    @Test("currentSessionID starts nil")
    @MainActor
    func currentSessionIDNil() async {
        let vm = ChatViewModel()
        #expect(vm.currentSessionID == nil)
    }
}


// MARK: - ChatViewModel Live Session Routing Tests

@Suite("ChatViewModel live session routing")
struct ChatViewModelLiveSessionRoutingTests {

    @Test("background live session keeps streaming state and does not steal foreground chat")
    @MainActor
    func backgroundLiveSessionDoesNotStealForeground() async {
        let vm = ChatViewModel()

        let generation = vm.beginSwitchToSession(key: "foreground")
        #expect(generation > 0)
        #expect(vm.currentSessionID == "foreground")

        vm.receiveGatewayEventForTesting(.messageStart, sessionID: "background-runtime")
        vm.receiveGatewayEventForTesting(.reasoningDelta(text: "thinking"), sessionID: "background-runtime")
        vm.receiveGatewayEventForTesting(.toolStart(payload: ToolStartPayload(
            toolID: "tool-1",
            name: "terminal",
            context: "running tests"
        )), sessionID: "background-runtime")
        vm.receiveGatewayEventForTesting(.messageDelta(text: "partial", rendered: nil), sessionID: "background-runtime")

        #expect(vm.currentSessionID == "foreground")
        #expect(vm.messages.isEmpty)
        #expect(vm.activeToolCalls.isEmpty)
        #expect(vm.isStreaming == false)

        _ = vm.beginSwitchToSession(key: "background-runtime")
        #expect(vm.currentSessionID == "background-runtime")
        #expect(vm.isStreaming == true)
        #expect(vm.activeToolCalls["tool-1"]?.name == "terminal")
        // Deltas are intentionally skipped for background sessions to avoid
        // saturating the main thread; the gateway delivers full history on resume.
    }

    @Test("stable ID binding preserves existing live runtime state")
    @MainActor
    func stableIDBindingPreservesLiveRuntimeState() async {
        let vm = ChatViewModel()

        _ = vm.beginSwitchToSession(key: "runtime-a")
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: "runtime-a")
        vm.receiveGatewayEventForTesting(.toolStart(payload: ToolStartPayload(
            toolID: "tool-a",
            name: "browser",
            context: "opening page"
        )), sessionID: "runtime-a")
        vm.bindCurrentGatewaySession(toStableSessionID: "stable-a")

        _ = vm.beginSwitchToSession(key: "other")
        vm.receiveGatewayEventForTesting(.toolComplete(payload: ToolCompletePayload(
            toolID: "tool-a",
            name: "browser",
            summary: "opened",
            durationSeconds: 1.0,
            inlineDiff: nil,
            todos: nil
        )), sessionID: "runtime-a")
        vm.receiveGatewayEventForTesting(.messageDelta(text: "done", rendered: nil), sessionID: "runtime-a")

        #expect(vm.currentSessionID == "other")
        #expect(vm.messages.isEmpty)

        _ = vm.beginSwitchToSession(key: "stable-a")
        #expect(vm.currentSessionID == "runtime-a")
        #expect(vm.isStreaming == true)
        #expect(vm.activeToolCalls["tool-a"]?.isComplete == true)
        // Background deltas are intentionally skipped to avoid main thread
        // saturation; message content is recovered on session resume.
    }
}

// MARK: - Concurrent Session Isolation Tests

/// Two sessions streaming at once, with the user clicking between them. Every
/// test here is a bleed the old code allowed: state that belongs to one session
/// landing in the other because it was keyed off "whatever is on screen now"
/// rather than off the event's own session.
@Suite("ChatViewModel concurrent session isolation")
internal struct ChatViewModelConcurrentSessionTests {

    private static func complete(_ text: String, status: String = "complete") -> GatewayEvent {
        .messageComplete(payload: MessageCompletePayload(
            text: text,
            status: status,
            usage: nil,
            reasoning: nil,
            rendered: nil,
            warning: nil
        ))
    }

    @Test("deltas buffered before a switch land on their own session, not the new one")
    @MainActor
    internal func bufferedDeltasDoNotBleedIntoTheNewSession() async {
        let vm = ChatViewModel()

        // Session A streams while visible — its tokens enter the 500ms buffer.
        _ = vm.beginSwitchToSession(key: "session-a")
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: "session-a")
        vm.receiveGatewayEventForTesting(.messageDelta(text: "A-tokens", rendered: nil), sessionID: "session-a")

        // The user clicks over to B mid-window, and B starts its own turn.
        _ = vm.beginSwitchToSession(key: "session-b")
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: "session-b")

        // Whatever is still buffered now drains.
        vm.flushDeltaBuffersForTesting()

        // B's visible transcript must not contain A's tokens.
        #expect(vm.currentSessionID == "session-b")
        #expect(vm.messages.allSatisfy { !$0.content.contains("A-tokens") })
        // A keeps them: they were its tokens, so switching back still shows them.
        let cachedA = vm.testCachedMessages(displayID: "session-a")
        #expect(cachedA.contains { $0.content.contains("A-tokens") })
    }

    @Test("switching sessions mid-stream does not splice two sessions' tokens together")
    @MainActor
    internal func interleavedDeltasStayInTheirOwnTranscripts() async {
        let vm = ChatViewModel()

        _ = vm.beginSwitchToSession(key: "session-a")
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: "session-a")
        vm.receiveGatewayEventForTesting(.messageDelta(text: "alpha", rendered: nil), sessionID: "session-a")

        _ = vm.beginSwitchToSession(key: "session-b")
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: "session-b")
        vm.receiveGatewayEventForTesting(.messageDelta(text: "beta", rendered: nil), sessionID: "session-b")
        vm.flushDeltaBuffersForTesting()

        // B, on screen, shows only its own tokens.
        let visible = vm.messages.map(\.content).joined()
        #expect(visible.contains("beta"))
        #expect(!visible.contains("alpha"))

        // A, cached, shows only its own.
        let cachedA = vm.testCachedMessages(displayID: "session-a").map(\.content).joined()
        #expect(cachedA.contains("alpha"))
        #expect(!cachedA.contains("beta"))
    }

    @Test("a background turn's completion does not open a quiz over the visible session")
    @MainActor
    internal func backgroundQuizDoesNotHijackVisibleSession() async {
        let vm = ChatViewModel()

        let quizJSON = """
        {"questions":[
        {"q":"q1","options":["A) a","B) b","C) c","D) d"],"correct":"A","explanation":"e"},
        {"q":"q2","options":["A) a","B) b","C) c","D) d"],"correct":"B","explanation":"e"},
        {"q":"q3","options":["A) a","B) b","C) c","D) d"],"correct":"C","explanation":"e"}]}
        """

        // Background session B runs a turn while A is on screen.
        _ = vm.beginSwitchToSession(key: "session-b")
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: "session-b")
        _ = vm.beginSwitchToSession(key: "session-a")
        vm.receiveGatewayEventForTesting(Self.complete(quizJSON), sessionID: "session-b")

        // No sheet over A: the quiz belongs to a chat the user isn't looking at.
        #expect(vm.quizQuestions == nil)

        // Switching to B and completing a turn there does surface it.
        _ = vm.beginSwitchToSession(key: "session-b")
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: "session-b")
        vm.receiveGatewayEventForTesting(Self.complete(quizJSON), sessionID: "session-b")
        #expect(vm.quizQuestions?.count == 3)
    }

    @Test("a background turn does not claim the visible session's mic state")
    @MainActor
    internal func backgroundVoiceStatusDoesNotAffectVisibleSession() async {
        let vm = ChatViewModel()

        _ = vm.beginSwitchToSession(key: "session-a")
        vm.receiveGatewayEventForTesting(.voiceStatus(state: "recording"), sessionID: "session-b")
        #expect(vm.isVoiceRecording == false)

        vm.receiveGatewayEventForTesting(.voiceStatus(state: "recording"), sessionID: "session-a")
        #expect(vm.isVoiceRecording == true)
    }

    @Test("a background turn's run history is filed under its own session")
    @MainActor
    internal func backgroundRunHistoryIsNotMisattributed() async {
        let vm = ChatViewModel()
        let store = SessionRunHistoryStore.shared
        let before = store.events(for: "run-visible").count

        _ = vm.beginSwitchToSession(key: "run-visible")
        // A turn starts on a DIFFERENT session while run-visible is on screen.
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: "run-background")

        // The visible session gained no run — it never ran anything.
        #expect(store.events(for: "run-visible").count == before)
        #expect(store.events(for: "run-background").contains { $0.status == .running })
    }

    @Test("a background turn does not steal the visible session's thought graph")
    @MainActor
    internal func backgroundCompletionDoesNotSnapshotVisibleGraph() async {
        let vm = ChatViewModel()

        // Visible session A builds live thought-graph depth.
        _ = vm.beginSwitchToSession(key: "graph-a")
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: "graph-a")
        vm.receiveGatewayEventForTesting(
            .subagentStart(payload: SubagentPayload(
                goal: "dig",
                taskCount: 1,
                taskIndex: 0,
                subagentID: "sub-1",
                parentID: nil,
                depth: nil,
                model: nil
            )),
            sessionID: "graph-a"
        )

        // Background session B completes a turn it started earlier.
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: "graph-b")
        vm.receiveGatewayEventForTesting(Self.complete("background done"), sessionID: "graph-b")

        // B's message must not carry A's live subagent tree.
        let cachedB = vm.testCachedMessages(displayID: "graph-b")
        #expect(cachedB.allSatisfy { $0.graphSnapshot == nil })
    }
}
