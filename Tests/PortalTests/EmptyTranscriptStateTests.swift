import Testing
@testable import Portal

/// Pins what an empty transcript says (#258) — the launch pane used to be
/// literally blank, which an external tester read as "broken". The view is
/// SwiftUI, but the decision of WHICH message to show is a pure function, so
/// the priority order is pinned here directly.
@Suite("Empty transcript launch state")
internal struct EmptyTranscriptStateTests {

    private typealias State = EmptyTranscriptStateView.LaunchPaneState

    @Test("a dial in flight reads as progress, not failure")
    internal func connectingOutranksDisconnected() {
        // isConnected is false while connecting — the naive check would show
        // "Not connected" with a retry button DURING the automatic dial,
        // inviting the user to fight the state machine.
        #expect(State.derive(
            isConnected: false, isConnecting: true, isSessionReady: false
        ) == .connecting)
    }

    @Test("a failed launch names itself instead of staying blank")
    internal func disconnectedIsExplicit() {
        // The load-bearing case from the report: a launch that dialed a wrong
        // address looked identical to one that worked.
        #expect(State.derive(
            isConnected: false, isConnecting: false, isSessionReady: false
        ) == .disconnected)
    }

    @Test("connected but no session yet reads as setup, not silence")
    internal func sessionSetupIsNarrated() {
        #expect(State.derive(
            isConnected: true, isConnecting: false, isSessionReady: false
        ) == .preparingSession)
    }

    @Test("fully ready states the first action")
    internal func readyStatesTheFirstAction() {
        #expect(State.derive(
            isConnected: true, isConnecting: false, isSessionReady: true
        ) == .readyToChat)
    }

    @Test("session readiness never outranks a missing transport")
    internal func sessionReadinessRequiresTransport() {
        // A stale isSessionReady from a previous connection must not paint
        // "type a message" over a dead transport — that is exactly the
        // "connected but nothing goes through" confusion this pane exists to
        // prevent.
        #expect(State.derive(
            isConnected: false, isConnecting: false, isSessionReady: true
        ) == .disconnected)
        #expect(State.derive(
            isConnected: false, isConnecting: true, isSessionReady: true
        ) == .connecting)
    }
}
