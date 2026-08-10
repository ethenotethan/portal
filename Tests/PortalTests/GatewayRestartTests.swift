import Testing
import Foundation
@testable import Portal

/// The gateway has shipped a `gateway.restart` RPC since hermes-agent #35, but
/// the app never called it — so applying pulled backend code meant bouncing the
/// process on the host by hand. These pin the classification rules that make a
/// one-button restart trustworthy, the riskiest of which is that a *lost socket
/// is the success case*: the gateway answers and then re-execs, so the reply
/// frequently never lands.
@Suite("Gateway Restart Outcome")
internal struct GatewayRestartOutcomeTests {

    private func response(error: JSONRPCError?) -> JSONRPCResponse {
        let json: String
        if let error {
            json = #"{"jsonrpc":"2.0","id":1,"error":{"code":\#(error.code),"message":"\#(error.message)"}}"#
        } else {
            json = #"{"jsonrpc":"2.0","id":1,"result":{"status":"restarting"}}"#
        }
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(JSONRPCResponse.self, from: Data(json.utf8))
    }

    @Test("an acknowledged restart is accepted")
    internal func acknowledgedIsAccepted() {
        #expect(GatewayRestartRequestOutcome.from(response: response(error: nil)) == .accepted)
    }

    @Test("method-not-found reads as unsupported, not as a failure")
    internal func methodNotFoundIsUnsupported() {
        let outcome = GatewayRestartRequestOutcome.from(response: response(error: .methodNotFound))
        #expect(outcome == .unsupported)
    }

    @Test("any other RPC error is a real failure")
    internal func rpcErrorIsFailure() {
        let outcome = GatewayRestartRequestOutcome.from(
            response: response(error: JSONRPCError(code: 5218, message: "exec denied"))
        )
        #expect(outcome == .failed("exec denied"))
    }

    /// The load-bearing case. The gateway sleeps 0.15s and then `os.execv`s, so
    /// the socket dies right around the acknowledgement. Reporting that as a
    /// failure would tell the user the restart failed on the most common path
    /// where it actually worked.
    @Test("a socket that dies mid-restart is accepted, not failed", arguments: [
        GatewayError.timedOut(method: "gateway.restart", seconds: 6),
        GatewayError.disconnected,
        GatewayError.notConnected,
    ])
    internal func lostTransportIsAccepted(error: GatewayError) {
        #expect(GatewayRestartRequestOutcome.from(error: error) == .accepted)
    }

    @Test("a thrown method-not-found is still unsupported")
    internal func thrownMethodNotFoundIsUnsupported() {
        let error = GatewayError.rpcError(.methodNotFound)
        #expect(GatewayRestartRequestOutcome.from(error: error) == .unsupported)
    }

    @Test("an unrelated thrown error is a failure")
    internal func unrelatedThrowIsFailure() {
        let outcome = GatewayRestartRequestOutcome.from(
            error: GatewayError.invalidResponse("garbage")
        )
        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
    }
}

@Suite("Gateway Restart Phase")
internal struct GatewayRestartPhaseTests {

    @Test("only the in-flight phases are busy")
    internal func busyPhases() {
        #expect(GatewayRestartPhase.requesting.isBusy)
        #expect(GatewayRestartPhase.waitingForGateway.isBusy)
        #expect(!GatewayRestartPhase.idle.isBusy)
        #expect(!GatewayRestartPhase.succeeded.isBusy)
        #expect(!GatewayRestartPhase.failed("x").isBusy)
        #expect(!GatewayRestartPhase.unsupported.isBusy)
    }

    @Test("idle says nothing; every other phase explains itself")
    internal func statusText() {
        #expect(GatewayRestartPhase.idle.statusText == nil)
        for phase: GatewayRestartPhase in [
            .requesting, .waitingForGateway, .succeeded, .failed("boom"), .unsupported,
        ] {
            #expect(phase.statusText?.isEmpty == false, "\(phase) needs a status line")
        }
    }

    @Test("a failure names the reason so it is actionable")
    internal func failureNamesReason() {
        #expect(GatewayRestartPhase.failed("exec denied").statusText?.contains("exec denied") == true)
    }
}

@Suite("Gateway Restart Capability Gate")
internal struct GatewayRestartCapabilityTests {

    /// Restart is the recovery control, so an unknown gateway is offered it
    /// rather than hidden from it — the opposite default from the other
    /// capability gates. Hiding it on silence is how the user ends up back on
    /// the host with a terminal, which is the thing this replaces.
    @Test("a gateway that reports nothing is still offered the restart")
    internal func silentGatewayIsOffered() {
        #expect(GatewayCapabilities.conservativeDefaults.supportsGatewayRestart)
        #expect(GatewayCapabilities.fallback(reason: "no reply").supportsGatewayRestart)
    }

    @Test("a gateway advertising gateway.restart is offered it")
    internal func advertisedIsOffered() {
        let capabilities = GatewayCapabilities.from(
            value: .dictionary([
                "capability_names": .array([.string("artifact.set"), .string("gateway.restart")]),
            ]),
            method: "gateway.capabilities"
        )
        #expect(capabilities.supportsGatewayRestart)
    }

    /// A gateway that answered the capability question and left restart out is
    /// taken at its word — unlike silence, that is an actual answer.
    @Test("a gateway that lists capabilities without restart is taken at its word")
    internal func omittedIsNotOffered() {
        let capabilities = GatewayCapabilities.from(
            value: .dictionary([
                "capability_names": .array([.string("artifact.set"), .string("wiki.page")]),
            ]),
            method: "gateway.capabilities"
        )
        #expect(!capabilities.supportsGatewayRestart)
    }
}

@Suite("Gateway Restart Controller")
@MainActor
internal struct GatewayRestartControllerTests {

    private func makeClient() -> GatewayClient {
        // Port 9 (discard): never accepts, so `requestGatewayRestart` fails the
        // way an unreachable gateway does without needing a live server.
        GatewayClient(gatewayURL: URL(string: "ws://127.0.0.1:9/v1/ws")!, apiKey: "")
    }

    @Test("starts idle")
    internal func startsIdle() {
        #expect(GatewayRestartController().phase == .idle)
    }

    /// With no socket, `call` throws `.notConnected` — which classifies as
    /// `accepted`, so the controller proceeds to the wait. That is correct: it
    /// cannot distinguish "restarting" from "gone", and the wait is what
    /// decides. What matters here is that it moves off `.idle` and reports busy
    /// so the button can't be pressed twice.
    @Test("a launched restart is busy and refuses a second launch")
    internal func refusesConcurrentRestart() async {
        let controller = GatewayRestartController()
        let client = makeClient()

        controller.restart(client: client, capabilities: nil)
        #expect(controller.phase == .requesting)
        #expect(controller.isRestarting)

        // Second press while in flight must not re-ask a mid-exec gateway.
        controller.restart(client: client, capabilities: nil)
        #expect(controller.phase == .requesting)

        controller.reset()
        client.disconnect()
    }

    @Test("reset clears a finished result")
    internal func resetClearsResult() {
        let controller = GatewayRestartController()
        controller.reset()
        #expect(controller.phase == .idle)
        #expect(!controller.isRestarting)
    }
}
