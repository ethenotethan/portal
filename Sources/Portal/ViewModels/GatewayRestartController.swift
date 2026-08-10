import Foundation

/// Sequences a user-triggered gateway restart and exposes one phase for the UI
/// to render.
///
/// The sequence is: ask → wait for the process to come back → re-read
/// capabilities. That last step is the point of restarting in the first place —
/// the usual reason is that new backend code was pulled onto the host, and the
/// app gates controls on `gateway.capabilities`. Skipping the refresh would
/// leave the app hiding features the freshly restarted gateway now has, until
/// something else happened to refresh.
@MainActor
internal final class GatewayRestartController: ObservableObject {
    @Published internal private(set) var phase: GatewayRestartPhase = .idle

    /// Guards against a second restart being launched while one is in flight —
    /// double-tapping the button would otherwise ask a mid-exec gateway to
    /// restart again.
    internal var isRestarting: Bool { phase.isBusy }

    private var task: Task<Void, Never>?

    internal func restart(
        client: GatewayClient,
        capabilities: GatewayCapabilitiesStore?,
        returnTimeout: Double = GatewayClient.restartReturnTimeout
    ) {
        guard !isRestarting else { return }
        phase = .requesting
        task?.cancel()
        task = Task { [weak self] in
            await self?.run(client: client, capabilities: capabilities, returnTimeout: returnTimeout)
        }
    }

    private func run(
        client: GatewayClient,
        capabilities: GatewayCapabilitiesStore?,
        returnTimeout: Double
    ) async {
        switch await client.requestGatewayRestart() {
        case .unsupported:
            phase = .unsupported
            return
        case .failed(let reason):
            phase = .failed(reason)
            return
        case .accepted:
            break
        }

        phase = .waitingForGateway
        guard await client.waitForGatewayReturn(timeout: returnTimeout) else {
            phase = .failed(
                "the gateway did not come back within "
                    + "\(Int(returnTimeout))s. It may still be starting."
            )
            return
        }

        // Back up, and possibly running different code than a moment ago.
        await capabilities?.refresh(using: client)
        phase = .succeeded
    }

    /// Return to idle so the status line stops asserting the result of a
    /// restart that is no longer the current news (e.g. the pane was closed and
    /// reopened, or the user is about to try again).
    internal func reset() {
        task?.cancel()
        task = nil
        phase = .idle
    }
}
