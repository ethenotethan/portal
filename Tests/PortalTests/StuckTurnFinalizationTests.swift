import Foundation
import Testing
@testable import Portal

/// The fourth stuck-turn latch, distinct from the three in
/// `StuckStreamRecoveryTests`: there the terminal frame arrived but was dropped
/// or unstampable. Here the terminal frame *never arrives at all*. When the
/// socket dies mid-turn — the resource-timeout boundary, a dropped or half-open
/// socket that `verifyLivenessOrReconnect` replaces, reconnect exhausted — the
/// live event stream is gone and the turn's `message.complete` is emitted into a
/// socket that no longer exists. Nothing later can settle the turn: it spins
/// forever, the sidebar live-dot stays lit, `SessionUsageBadge` stays blocked
/// behind its `guard !isStreaming` so no usage/model metadata refreshes, and
/// `submitPrompt`'s own `guard !isStreaming` bars any new prompt. The session is
/// wedged until relaunch — exactly the "no session metadata, just hanging" state
/// the user reported for two live sessions.
///
/// The fix gives the client three ways to force-settle such a turn without a
/// terminal frame, all funnelling through `finalizeStuckStreamingTurn` /
/// `finalizeAllStuckStreamingTurns`:
///   1. A terminal connection `error` settles every wedged turn at once.
///   2. A reconnect re-resumes the visible session, settling it if the gateway
///      reports the turn already finished.
///   3. That reconnect reconcile settles a session local state still believes is
///      streaming when the gateway reports no in-flight turn. This is gated to
///      the reconnect path (`settleOrphanedTurn`): an ordinary switch-back must
///      keep such a (mid-thought, empty-content) turn live, since its socket is
///      intact and a later frame will land (LiveSessionSwitchBackTests).
/// Force-settling is safe: a genuinely-live turn re-opens its stream on the next
/// live frame via `GatewayEvent.resumesLiveTurn`.
@Suite("Stuck turn finalization")
@MainActor
internal struct StuckTurnFinalizationTests {

    // MARK: - finalizeStuckStreamingTurn (background)

    /// A background session wedged on `isStreaming` must settle: flag cleared,
    /// avatar idle, and the in-flight shell stamped with the given status so the
    /// bubble stops spinning when the user clicks back to it.
    @Test("finalizing a background stuck turn clears it and stamps the message")
    internal func finalizeBackgroundStuckTurn() {
        let vm = ChatViewModel()
        let background = "stuck-bg-\(UUID().uuidString)"
        let visible = "visible-\(UUID().uuidString)"

        _ = vm.beginSwitchToSession(key: background)
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: background)
        _ = vm.beginSwitchToSession(key: visible)
        #expect(vm.streamingSessionIDsForTesting.contains(background))

        vm.finalizeStuckStreamingTurnForTesting(sessionID: background, status: "interrupted")

        #expect(vm.streamingSessionIDsForTesting.contains(background) == false)
        // Clicking back does not restore the wedge, and the shell is settled.
        _ = vm.beginSwitchToSession(key: background)
        #expect(!vm.isStreaming)
        #expect(vm.avatarState == .idle)
        let assistant = vm.messages.last { $0.role == .assistant }
        #expect(assistant?.isStreaming == false)
        #expect(assistant?.status == "interrupted")
    }

    /// Force-settling is a no-op on a session that isn't streaming — it must
    /// never fabricate a settle on an idle session or one already finished.
    @Test("finalizing a non-streaming session is a no-op")
    internal func finalizeNonStreamingIsNoOp() {
        let vm = ChatViewModel()
        let idle = "idle-\(UUID().uuidString)"
        _ = vm.beginSwitchToSession(key: idle)

        vm.finalizeStuckStreamingTurnForTesting(sessionID: idle, status: "interrupted")
        #expect(!vm.isStreaming)
        #expect(vm.streamingSessionIDsForTesting.isEmpty)
    }

    // MARK: - finalizeAllStuckStreamingTurns

    /// Settle-all covers both paths at once: the visible turn (through
    /// `finishStreaming`) and every background turn (through
    /// `finalizeStuckStreamingTurn`). After it, nothing is left streaming.
    @Test("finalizing all stuck turns settles the visible and background ones")
    internal func finalizeAllStuckTurns() {
        let vm = ChatViewModel()
        let background = "all-bg-\(UUID().uuidString)"
        let visible = "all-visible-\(UUID().uuidString)"

        _ = vm.beginSwitchToSession(key: background)
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: background)
        _ = vm.beginSwitchToSession(key: visible)
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: visible)
        #expect(vm.isStreaming)
        #expect(vm.streamingSessionIDsForTesting.count == 2)

        vm.finalizeAllStuckStreamingTurnsForTesting(status: "interrupted")

        #expect(!vm.isStreaming)
        #expect(vm.avatarState == .idle)
        #expect(vm.streamingSessionIDsForTesting.isEmpty)
    }

    // MARK: - connection state

    /// A terminal connection `error` while a turn is live settles the wedge and
    /// paints the error avatar. This is the direct fix for the reported hang:
    /// the socket died, reconnect is exhausted, and the turn can never complete.
    @Test("a terminal connection error settles a live turn and surfaces it")
    internal func connectionErrorSettlesLiveTurn() {
        let vm = ChatViewModel()
        let sid = "conn-err-\(UUID().uuidString)"
        _ = vm.beginSwitchToSession(key: sid)
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: sid)
        #expect(vm.isStreaming)

        vm.handleConnectionStateForTesting(.error("socket died"))

        #expect(vm.error == "socket died")
        #expect(!vm.isStreaming)
        #expect(vm.streamingSessionIDsForTesting.isEmpty)
        // A turn WAS in flight, so the error avatar is painted (and survives the
        // finalize, which would otherwise reset it to .idle).
        #expect(vm.avatarState == .error)
    }

    /// The error avatar is gated on a live turn: an idle session hit by a
    /// connection error surfaces the message but must not sprout an error face.
    @Test("a connection error on an idle session does not paint the error avatar")
    internal func connectionErrorIdleKeepsAvatar() {
        let vm = ChatViewModel()
        let sid = "conn-err-idle-\(UUID().uuidString)"
        _ = vm.beginSwitchToSession(key: sid)
        #expect(!vm.isStreaming)

        vm.handleConnectionStateForTesting(.error("socket died"))
        #expect(vm.error == "socket died")
        #expect(vm.avatarState == .idle)
    }

    /// A transient reconnect must NOT settle the turn — the gateway agent may
    /// still be running, so the flag is kept and only the avatar softens to
    /// "thinking". Clearing isStreaming here is exactly what made later frames
    /// look stale.
    @Test("a transient reconnect keeps the turn live")
    internal func reconnectingKeepsTurnLive() {
        let vm = ChatViewModel()
        let sid = "reconnecting-\(UUID().uuidString)"
        _ = vm.beginSwitchToSession(key: sid)
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: sid)

        vm.handleConnectionStateForTesting(.reconnecting(attempt: 1))
        #expect(vm.isStreaming)
        #expect(vm.avatarState == .thinking)
    }

    /// A successful (re)connect clears any surfaced error.
    @Test("connected clears a surfaced error")
    internal func connectedClearsError() {
        let vm = ChatViewModel()
        vm.handleConnectionStateForTesting(.error("boom"))
        #expect(vm.error == "boom")

        vm.handleConnectionStateForTesting(.connected)
        #expect(vm.error == nil)
    }

    // MARK: - reconnect reconciliation

    /// The synchronous reconnect handler must not crash or wedge when there is
    /// nothing to resume (no client, no session) — it takes the guard path.
    @Test("reconnect with nothing to resume is safe")
    internal func reconnectWithNothingToResume() {
        let vm = ChatViewModel()
        vm.handleGatewayReconnectedForTesting()
        #expect(!vm.isStreaming)
        #expect(vm.currentSessionID == nil)
    }

    /// The async reconcile with no wired client resolves without hanging:
    /// `resumeSession` returns false, and the handler still normalises
    /// readiness/error rather than leaving the session in limbo.
    @Test("reconnect reconcile with no client resolves cleanly")
    internal func reconnectReconcileWithNoClient() async {
        let vm = ChatViewModel()
        await vm.reconcileTurnAfterReconnectForTesting(displayID: "no-client-\(UUID().uuidString)")
        #expect(vm.isSessionReady)
        #expect(vm.error == nil)
    }
}
