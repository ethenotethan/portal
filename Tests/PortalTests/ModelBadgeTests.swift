import Testing
import Foundation
@testable import Portal

/// Regression coverage for "it just says No model after the first turn."
///
/// The user's report, verbatim shape: a session runs a turn with a model shown
/// in the top-left badge; they send another turn on the SAME session; the
/// badge flips to "No model" — while the backend routes the turn to a model
/// perfectly well.
///
/// The mechanism: `session.info` fires for many reasons (usage updates at turn
/// boundaries, workspace moves, the connect announcement), and a session whose
/// model is ROUTED per-turn reports `model: ""` — the field means "no pinned
/// override", not "no model". The desktop adopted it unconditionally, so the
/// first model-less info event after a turn wiped a badge that was correct a
/// moment earlier. The harness's own `_session_info` documents the identical
/// trap for `reasoning_effort` ("Reporting '' here made the desktop adopt the
/// empty value after the first turn").
@Suite("Model badge")
@MainActor
internal struct ModelBadgeTests {

    private func sessionInfo(model: String) -> GatewayEvent {
        .sessionInfo(SessionInfo(
            model: model,
            reasoningEffort: "",
            fast: false,
            tools: [:],
            skills: [:],
            cwd: "",
            version: "",
            usage: nil,
            mcpServers: nil
        ))
    }

    @Test("a model-less session.info does not wipe a known model")
    internal func emptyModelDoesNotWipeTheBadge() {
        let vm = ChatViewModel()
        let sid = "model-badge-\(UUID().uuidString)"
        _ = vm.beginSwitchToSession(key: sid)

        vm.receiveGatewayEventForTesting(sessionInfo(model: "claude-opus-5"), sessionID: sid)
        #expect(vm.currentModel == "claude-opus-5")

        // The next turn's usage-bearing info event on a routed session names
        // no model. The badge must keep saying what it knows.
        vm.receiveGatewayEventForTesting(sessionInfo(model: ""), sessionID: sid)
        #expect(vm.currentModel == "claude-opus-5")
    }

    @Test("a session.info that names a different model still updates")
    internal func namedModelStillUpdates() {
        // The guard must only reject silence, not change — or a real
        // server-side switch would never reach the badge.
        let vm = ChatViewModel()
        let sid = "model-badge-\(UUID().uuidString)"
        _ = vm.beginSwitchToSession(key: sid)

        vm.receiveGatewayEventForTesting(sessionInfo(model: "claude-opus-5"), sessionID: sid)
        vm.receiveGatewayEventForTesting(sessionInfo(model: "claude-sonnet-5"), sessionID: sid)
        #expect(vm.currentModel == "claude-sonnet-5")
    }

    @Test("the session-less connect announcement also refuses an empty model")
    internal func globalAnnouncementRefusesEmptyModel() {
        // The gateway's on-connect default announcement routes through the
        // global handler, not applySessionEvent — it has the same trap.
        let vm = ChatViewModel()
        let sid = "model-badge-\(UUID().uuidString)"
        _ = vm.beginSwitchToSession(key: sid)

        vm.receiveGatewayEventForTesting(sessionInfo(model: "claude-opus-5"), sessionID: sid)
        vm.receiveGatewayEventForTesting(sessionInfo(model: ""), sessionID: nil)
        #expect(vm.currentModel == "claude-opus-5")
    }

    @Test("the empty guard does not block the badge's first fill")
    internal func firstNamedModelFillsTheBadge() {
        // Starting empty and receiving a named model is the normal cold path —
        // the guard must not make "No model" sticky.
        let vm = ChatViewModel()
        let sid = "model-badge-\(UUID().uuidString)"
        _ = vm.beginSwitchToSession(key: sid)
        #expect(vm.currentModel.isEmpty)

        vm.receiveGatewayEventForTesting(sessionInfo(model: "claude-opus-5"), sessionID: sid)
        #expect(vm.currentModel == "claude-opus-5")
    }
}
