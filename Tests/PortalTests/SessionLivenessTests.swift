import Testing
import Foundation
@testable import Portal

/// Regression coverage for "I'm clicking between two sessions that are live but
/// one of them I have to click into it for it to light up / be considered live
/// again."
///
/// The sidebar's live dot was driven off `ChatViewModel.$isStreaming`, which
/// describes the VISIBLE chat only. A background session's turn start and
/// finish therefore never reached its row: it read as idle until the user
/// clicked into it, which republished the flag under that session's ID. The fix
/// publishes the whole set of sessions with a turn in flight, and the sidebar
/// reconciles rows against it.
@Suite("Session liveness")
@MainActor
internal struct SessionLivenessTests {

    private func complete(_ text: String, status: String = "complete") -> GatewayEvent {
        .messageComplete(payload: MessageCompletePayload(
            text: text,
            status: status,
            usage: nil,
            reasoning: nil,
            rendered: nil,
            warning: nil
        ))
    }

    @Test("a background session's turn is published while another chat is visible")
    internal func backgroundTurnIsPublished() {
        let vm = ChatViewModel()
        _ = vm.beginSwitchToSession(key: "visible")

        vm.applyTestEvent(.messageStart, sessionID: "background")

        // The visible chat is untouched — but the sidebar still learns that the
        // other session is alive.
        #expect(vm.currentSessionID == "visible")
        #expect(vm.isStreaming == false)
        #expect(vm.streamingSessionIDs.contains("background"))
        #expect(!vm.streamingSessionIDs.contains("visible"))

        vm.applyTestEvent(complete("done"), sessionID: "background")
        #expect(!vm.streamingSessionIDs.contains("background"))
    }

    @Test("the visible session's own turn is published too")
    internal func visibleTurnIsPublished() {
        let vm = ChatViewModel()
        _ = vm.beginSwitchToSession(key: "visible")

        vm.applyTestEvent(.messageStart, sessionID: "visible")
        #expect(vm.isStreaming)
        #expect(vm.streamingSessionIDs.contains("visible"))

        vm.applyTestEvent(complete("done"), sessionID: "visible")
        #expect(!vm.streamingSessionIDs.contains("visible"))
    }

    @Test("two live sessions are published at once")
    internal func twoLiveSessionsBothPublished() {
        let vm = ChatViewModel()
        _ = vm.beginSwitchToSession(key: "session-a")
        vm.applyTestEvent(.messageStart, sessionID: "session-a")
        vm.applyTestEvent(.messageStart, sessionID: "session-b")

        // The exact user-visible case: click over to B, and BOTH rows must
        // still read as live without a second click.
        _ = vm.beginSwitchToSession(key: "session-b")
        #expect(vm.streamingSessionIDs == ["session-a", "session-b"])
    }

    @Test("a live session is published under its stable display ID")
    internal func liveSessionPublishedUnderDisplayID() {
        // Events carry the runtime short-hex ID; sidebar rows are keyed by the
        // stable database ID. Publishing the runtime ID alone left the row dark.
        let vm = ChatViewModel()
        _ = vm.beginSwitchToSession(key: "runtime-x")
        vm.applyTestEvent(.messageStart, sessionID: "runtime-x")
        vm.bindCurrentGatewaySession(toStableSessionID: "stable-x")

        _ = vm.beginSwitchToSession(key: "elsewhere")
        #expect(vm.streamingSessionIDs.contains("stable-x"))
        #expect(!vm.streamingSessionIDs.contains("runtime-x"))
    }
}

/// The sidebar half of the same fix: reconciling rows against the published set.
@Suite("Session list run state reconciliation")
@MainActor
internal struct SessionListStreamingReconciliationTests {

    private func session(
        _ id: String,
        gatewayID: String? = nil,
        runState: SessionRunState? = nil
    ) -> Session {
        Session(
            id: id,
            title: nil,
            preview: nil,
            source: nil,
            messageCount: 0,
            startedAt: nil,
            endedAt: nil,
            lastActive: nil,
            gatewayID: gatewayID,
            runState: runState
        )
    }

    @Test("a row matched by gateway ID lights up and later goes idle")
    internal func gatewayIDMatchLightsUpTheRow() {
        let list = SessionListViewModel()
        list.sessions = [session("db-a", gatewayID: "rt-a"), session("db-b")]

        list.applyStreamingSessions(["rt-a"])
        #expect(list.runState(for: "db-a") == .streaming)
        #expect(list.runState(for: "rt-a") == .streaming)
        #expect(list.runState(for: "db-b") != .streaming)

        list.applyStreamingSessions([])
        #expect(list.runState(for: "db-a") == .idle)
    }

    @Test("several live sessions light up together")
    internal func multipleLiveRows() {
        let list = SessionListViewModel()
        list.sessions = [session("db-a"), session("db-b"), session("db-c")]

        list.applyStreamingSessions(["db-a", "db-c"])
        #expect(list.runState(for: "db-a") == .streaming)
        #expect(list.runState(for: "db-c") == .streaming)
        #expect(list.runState(for: "db-b") != .streaming)

        // One finishes, the other keeps streaming.
        list.applyStreamingSessions(["db-c"])
        #expect(list.runState(for: "db-a") == .idle)
        #expect(list.runState(for: "db-c") == .streaming)
    }

    @Test("terminal run states are not downgraded to idle")
    internal func terminalStatesSurvive() {
        // A failed or canceled turn is a result, not a stale live dot — the
        // reconciliation may only clear rows that currently say `.streaming`.
        let list = SessionListViewModel()
        list.sessions = [
            session("db-failed", runState: .failed),
            session("db-canceled", runState: .canceled),
            session("db-waiting", runState: .waitingForUser)
        ]

        list.applyStreamingSessions([])
        #expect(list.runState(for: "db-failed") == .failed)
        #expect(list.runState(for: "db-canceled") == .canceled)
        #expect(list.runState(for: "db-waiting") == .waitingForUser)
    }
}
