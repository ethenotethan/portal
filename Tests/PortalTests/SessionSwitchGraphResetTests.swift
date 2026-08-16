import Foundation
import Testing
@testable import Portal

/// The turn-scoped graph integrators must follow the VISIBLE session (#stale
/// widgets). They were only reset when a turn started while its session was
/// visible — a session whose turn began in the background never got that
/// reset on switch, so the canvas widgets kept rendering the previous
/// session's graph: "when I click to another active session, it just shows
/// the widgets from the session before; there's some hanging false state."
@Suite("Session-switch graph reset")
@MainActor
internal struct SessionSwitchGraphResetTests {

    private func spawnEvent(id: String) -> GatewayEvent {
        .from(type: "subagent.start", payload: .dictionary([
            "subagent_id": AnyCodable(id),
            "label": AnyCodable("worker"),
        ]))
    }

    @Test("switching sessions clears the previous session's live graph")
    internal func switchClearsIntegrators() {
        let vm = ChatViewModel()
        let sessionA = "graph-reset-a-\(UUID().uuidString)"
        let sessionB = "graph-reset-b-\(UUID().uuidString)"

        _ = vm.beginSwitchToSession(key: sessionA)
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: sessionA)
        vm.receiveGatewayEventForTesting(spawnEvent(id: "agent-a"), sessionID: sessionA)
        #expect(!vm.subagentGraph.agentNodes.isEmpty, "A's live turn populates the graph")

        _ = vm.beginSwitchToSession(key: sessionB)
        #expect(
            vm.subagentGraph.agentNodes.isEmpty,
            "B must not inherit A's subagent lanes — that is the stale-widget bug"
        )
        #expect(vm.currentTurnCompactions.isEmpty)
    }

    @Test("re-selecting the same session does not wipe its live graph")
    internal func sameSessionRestoreKeepsGraph() {
        // The reset is guarded on an ACTUAL session change: restoreSessionState
        // also runs on same-session refreshes, and wiping there would blank a
        // live graph the user is watching.
        let vm = ChatViewModel()
        let session = "graph-reset-same-\(UUID().uuidString)"

        _ = vm.beginSwitchToSession(key: session)
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: session)
        vm.receiveGatewayEventForTesting(spawnEvent(id: "agent-1"), sessionID: session)
        #expect(!vm.subagentGraph.agentNodes.isEmpty)

        _ = vm.beginSwitchToSession(key: session)
        #expect(
            !vm.subagentGraph.agentNodes.isEmpty,
            "a same-session re-select is not a switch; the live graph must survive"
        )
    }

    @Test("a fresh turn in the newly-visible session starts a fresh graph")
    internal func newTurnAfterSwitchStartsClean() {
        let vm = ChatViewModel()
        let sessionA = "graph-reset-a2-\(UUID().uuidString)"
        let sessionB = "graph-reset-b2-\(UUID().uuidString)"

        _ = vm.beginSwitchToSession(key: sessionA)
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: sessionA)
        vm.receiveGatewayEventForTesting(spawnEvent(id: "agent-a"), sessionID: sessionA)

        _ = vm.beginSwitchToSession(key: sessionB)
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: sessionB)
        vm.receiveGatewayEventForTesting(spawnEvent(id: "agent-b"), sessionID: sessionB)

        #expect(vm.subagentGraph.agentNodes.count == 1, "only B's turn is in the graph")
    }
}
