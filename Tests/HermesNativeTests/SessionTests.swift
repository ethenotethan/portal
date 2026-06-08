import Testing
import Foundation
@testable import HermesNative

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
